-- Versioned persistence adapter for Molly's existing GuildStore/GlobalStore
-- callback contract. One guild/global state document is replaced with a
-- conditional PreppyDB transaction; no partial set of fields is published.
local Store = {}
Store.__index = Store
local MigrationWriteGate = require("src.persistence.migration_write_gate")
local shared_write_gate = MigrationWriteGate.shared

local DEFAULT_GUILD_COLLECTION = "molly_guild_state"
local DEFAULT_GUILD_REGISTRY_COLLECTION = "molly_guild_registry"
local DEFAULT_GLOBAL_COLLECTION = "molly_global_state"
local DEFAULT_MAX_DOCUMENT_BYTES = 3 * 1024 * 1024
local GUILD_STATE_MARKER = "_molly_preppydb_state"

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
  local marker = type(data) == "table" and data[GUILD_STATE_MARKER]
  return type(data) == "table" and data.guild == guild_id
    and type(data.accounts) == "table" and type(data.cases) == "table"
    and type(data.staff) == "table" and type(data.journal) == "table"
    and type(data.receipts) == "table" and type(marker) == "table"
    and marker.version == 1 and (marker.origin == "migrated" or marker.origin == "new_guild")
end

local function valid_registry(data, guild_id)
  return type(data) == "table" and data.guild == guild_id and data.version == 1
    and (data.status == "migrated" or data.status == "new_guild")
end

local function guild_marker(origin)
  return { version = 1, origin = origin }
end

local function registry_entry(guild_id, status)
  return { guild = guild_id, version = 1, status = status }
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
    guild_registry_collection = options.guild_registry_collection or DEFAULT_GUILD_REGISTRY_COLLECTION,
    global_collection = options.global_collection or DEFAULT_GLOBAL_COLLECTION,
    max_document_bytes = max_bytes,
    busy = {},
    write_gate = shared_write_gate,
  }, Store)
end

function Store:_run(collection, key, initial, validate, fn, registry_status)
  local lease, gate_error = self.write_gate:enter()
  if not lease then return false, gate_error end
  local lock_key = collection .. "\0" .. key
  if self.busy[lock_key] then self.write_gate:leave(lease, false); return false, "busy" end
  self.busy[lock_key] = true
  local may_have_written = false

  local called, success, result = pcall(function()
    local registry
    if registry_status then
      local registry_error
      registry, registry_error = self.connector:get(self.guild_registry_collection, key)
      if not registry then
        if type(registry_error) == "table" and registry_error.code == "not_found" then
          return false, "not_migrated"
        end
        return false, failure(registry_error, false)
      end
      if type(registry) ~= "table" or type(registry.version) ~= "number"
        or registry.version < 1 or registry.version % 1 ~= 0
        or not valid_registry(registry.value, key) then
        return false, "invalid_store"
      end
    end
    local envelope, read_error = self.connector:get(collection, key)
    local missing = envelope == nil and type(read_error) == "table" and read_error.code == "not_found"
    if envelope == nil and not missing then return false, failure(read_error, false) end
    if missing and initial == nil then
      return false, registry_status and "missing_document" or "not_migrated"
    end

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
    if registry_status and data[GUILD_STATE_MARKER].origin ~= registry.value.status then
      return false, "invalid_store"
    end

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
    may_have_written = true
    local committed, commit_error = self.connector:transaction({ operation })
    if not committed then return false, failure(commit_error, true) end
    return true, value
  end)

  self.busy[lock_key] = nil
  self.write_gate:leave(lease, may_have_written)
  if not called then return false, "unavailable" end
  return success, result
end

function Store:run(guild_id, defaults_or_fn, maybe_fn)
  if type(defaults_or_fn) == "function" and maybe_fn == nil then
    if not valid_guild(guild_id) then return false, "invalid_guild" end
    return self:_run(self.guild_collection, guild_id, nil,
      function(data) return valid_guild_state(data, guild_id) end, defaults_or_fn, true)
  end

  local name, defaults, fn = guild_id, defaults_or_fn, maybe_fn
  if not valid_global(name) or type(defaults) ~= "table" or type(fn) ~= "function" then
    return false, "invalid_argument"
  end
  return self:_run(self.global_collection, name, function() return copy_defaults(defaults) end,
    function(data) return type(data) == "table" end, fn)
end

-- Create state only after a trusted caller has independently established that this
-- guild is newly onboarded. Ordinary reads/writes never infer that from a missing key.
-- The registry and state are one CAS transaction so a partial registration is impossible.
function Store:provision_new_guild(guild_id)
  if not valid_guild(guild_id) then return false, "invalid_guild" end
  local lease, gate_error = self.write_gate:enter()
  if not lease then return false, gate_error end
  local lock_key = self.guild_collection .. "\0" .. guild_id
  if self.busy[lock_key] then self.write_gate:leave(lease, false); return false, "busy" end
  self.busy[lock_key] = true
  local may_have_written = false
  local called, success, result = pcall(function()
    local state, state_error = self.connector:get(self.guild_collection, guild_id)
    local registry, registry_error = self.connector:get(self.guild_registry_collection, guild_id)
    local state_missing = not state and type(state_error) == "table" and state_error.code == "not_found"
    local registry_missing = not registry and type(registry_error) == "table" and registry_error.code == "not_found"
    if not state_missing and not state then return false, failure(state_error, false) end
    if not registry_missing and not registry then return false, failure(registry_error, false) end
    if not state_missing or not registry_missing then
      if state and registry and valid_guild_state(state.value, guild_id)
        and valid_registry(registry.value, guild_id)
        and state.value[GUILD_STATE_MARKER].origin == registry.value.status then
        return false, "already_initialized"
      end
      return false, "inconsistent_store"
    end

    local data = {
      guild = guild_id, accounts = {}, cases = {}, staff = {}, journal = {},
      receipts = {}, next_case = 1,
      [GUILD_STATE_MARKER] = guild_marker("new_guild"),
    }
    local size, size_error = self.connector:encoded_size(data)
    if type(size) ~= "number" or size < 0 or size % 1 ~= 0 then
      return false, size_error or "serialization_failed"
    end
    if size > self.max_document_bytes then return false, "resource_limit" end
    may_have_written = true
    local committed, commit_error = self.connector:transaction({
      { op = "put", collection = self.guild_collection, key = guild_id, expected_version = 0, value = data },
      { op = "put", collection = self.guild_registry_collection, key = guild_id, expected_version = 0,
        value = registry_entry(guild_id, "new_guild") },
    })
    if not committed then return false, failure(commit_error, true) end
    local stored, stored_error = self.connector:get(self.guild_collection, guild_id)
    local registered, registry_read_error = self.connector:get(self.guild_registry_collection, guild_id)
    if not stored or not registered or not valid_guild_state(stored.value, guild_id)
      or not valid_registry(registered.value, guild_id)
      or registered.value.status ~= "new_guild"
      or stored.value[GUILD_STATE_MARKER].origin ~= "new_guild" then
      return false, "verification_failed"
    end
    return true, "created"
  end)
  self.busy[lock_key] = nil
  self.write_gate:leave(lease, may_have_written)
  if not called then return false, "unavailable" end
  return success, result
end

Store.default_guild_collection = DEFAULT_GUILD_COLLECTION
Store.default_guild_registry_collection = DEFAULT_GUILD_REGISTRY_COLLECTION
Store.default_global_collection = DEFAULT_GLOBAL_COLLECTION
Store.default_max_document_bytes = DEFAULT_MAX_DOCUMENT_BYTES
return Store
