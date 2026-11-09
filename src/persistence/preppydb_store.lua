-- Versioned persistence adapter for Molly's existing GuildStore/GlobalStore
-- callback contract. One guild/global state document is replaced with a
-- conditional PreppyDB transaction; no partial set of fields is published.
local Store = {}
Store.__index = Store

local DEFAULT_GUILD_COLLECTION = "molly_guild_state"
local DEFAULT_GLOBAL_COLLECTION = "molly_global_state"
local DEFAULT_MAX_DOCUMENT_BYTES = 3 * 1024 * 1024

local function valid_guild(value)
  return type(value) == "string" and #value >= 1 and #value <= 20 and value:match("^%d+$") ~= nil
end

local function valid_global(value)
  return type(value) == "string" and #value <= 48 and value:match("^[a-z][a-z0-9_%-]*$") ~= nil
end

local function copy_defaults(defaults)
  local result = {}
  for key, value in pairs(defaults) do result[key] = value end
  return result
end

local function failure(err, after_write)
  if type(err) ~= "table" then return after_write and "outcome_unknown" or "unavailable" end
  if err.code == "conflict" then return "conflict" end
  if err.code == "resource_limit" then return "resource_limit" end
  if err.code == "invalid_argument" or err.code == "malformed_document" then return "invalid_store" end
  if after_write and (err.status == nil or err.status >= 500
    or err.code == "transport_error" or err.code == "invalid_response") then
    return "outcome_unknown"
  end
  return "unavailable"
end

local function valid_guild_state(data, guild_id)
  return type(data) == "table" and data.guild == guild_id
    and type(data.accounts) == "table" and type(data.cases) == "table"
    and type(data.staff) == "table" and type(data.journal) == "table"
    and type(data.receipts) == "table"
end

function Store.new(connector, options)
  options = options or {}
  local max_bytes = options.max_document_bytes or DEFAULT_MAX_DOCUMENT_BYTES
  assert(type(connector) == "table" and type(connector.get) == "function"
    and type(connector.transaction) == "function" and type(connector.encoded_size) == "function",
    "PreppyDB transaction connector with bounded serialization is required")
  assert(type(max_bytes) == "number" and max_bytes >= 1024 and max_bytes <= 4 * 1024 * 1024
    and max_bytes % 1 == 0, "max_document_bytes must be between 1024 and 4194304")
  return setmetatable({
    connector = connector,
    guild_collection = options.guild_collection or DEFAULT_GUILD_COLLECTION,
    global_collection = options.global_collection or DEFAULT_GLOBAL_COLLECTION,
    max_document_bytes = max_bytes,
    busy = {},
  }, Store)
end

function Store:_run(collection, key, initial, validate, fn)
  local lock_key = collection .. "\0" .. key
  if self.busy[lock_key] then return false, "busy" end
  self.busy[lock_key] = true

  local called, success, result = pcall(function()
    local envelope, read_error = self.connector:get(collection, key)
    local missing = envelope == nil and type(read_error) == "table" and read_error.code == "not_found"
    if envelope == nil and not missing then return false, failure(read_error, false) end

    local version, data
    if missing then
      version = 0
      data = initial()
    else
      if type(envelope) ~= "table" or type(envelope.version) ~= "number"
        or envelope.version < 1 or envelope.version % 1 ~= 0 then
        return false, "invalid_store"
      end
      version = envelope.version
      data = envelope.value
    end
    if not validate(data) then return false, "invalid_store" end

    local ok, value, changed = fn(data)
    if not ok then return false, value end
    if changed ~= true then return true, value end

    local size, size_error = self.connector:encoded_size(data)
    if type(size) ~= "number" or size < 0 or size % 1 ~= 0 then
      return false, size_error or "serialization_failed"
    end
    if size > self.max_document_bytes then return false, "resource_limit" end

    local operation = {
      op = "put", collection = collection, key = key,
      expected_version = version, value = data,
    }
    local committed, commit_error = self.connector:transaction({ operation })
    if not committed then return false, failure(commit_error, true) end
    return true, value
  end)

  self.busy[lock_key] = nil
  if not called then return false, "unavailable" end
  return success, result
end

function Store:run(guild_id, defaults_or_fn, maybe_fn)
  if type(defaults_or_fn) == "function" and maybe_fn == nil then
    if not valid_guild(guild_id) then return false, "invalid_guild" end
    local function initial()
      return { guild = guild_id, accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {}, next_case = 1 }
    end
    return self:_run(self.guild_collection, guild_id, initial,
      function(data) return valid_guild_state(data, guild_id) end, defaults_or_fn)
  end

  local name, defaults, fn = guild_id, defaults_or_fn, maybe_fn
  if not valid_global(name) or type(defaults) ~= "table" or type(fn) ~= "function" then
    return false, "invalid_argument"
  end
  return self:_run(self.global_collection, name, function() return copy_defaults(defaults) end,
    function(data) return type(data) == "table" end, fn)
end

Store.default_guild_collection = DEFAULT_GUILD_COLLECTION
Store.default_global_collection = DEFAULT_GLOBAL_COLLECTION
Store.default_max_document_bytes = DEFAULT_MAX_DOCUMENT_BYTES
return Store
