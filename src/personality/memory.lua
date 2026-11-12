-- PreppyDB memory provider for the Personality Engine V1 (integration phase).
--
-- PREPARED, NOT WIRED. This module is intentionally not referenced by
-- molly.lua, not constructed at startup and not called by any Discord event.
-- It only prepares the storage seam so a later, explicitly approved change can
-- opt in. It never creates collections and never migrates data.
--
-- Storage model (when someone wires it up):
--   one document per scope in an explicitly provisioned collection
--   (default name: molly_personality_memory)
--   key   = "memory/<guild_id>/<channel_id>/<user_id|shared>"
--   value = { version = 1, entries = { { role, content, at }, ... } }
--   Ring buffer: at most MAX_ENTRIES entries, each at most MAX_ENTRY_CHARS
--   bytes; recall additionally bounds the total returned text.
--
-- Writes use connector:put(..., expected_version) optimistic concurrency; a
-- conflict is returned to the caller and never blindly replayed. Reads treat
-- a missing document as empty history, not as an error.
--
-- The engine only ever READS from this provider (best effort). Nothing in
-- this repository writes conversation data to PreppyDB today; append exists
-- for the future explicit enablement step and is covered by synthetic tests.

local Memory = {}
Memory.__index = Memory

Memory.DEFAULT_COLLECTION = "molly_personality_memory"
Memory.MAX_ENTRIES = 20          -- ring capacity per scope document
Memory.MAX_ENTRY_CHARS = 300     -- per stored entry
Memory.MAX_FETCH = 8             -- per recall call
Memory.MAX_TOTAL_CHARS = 1800    -- across one recall result
Memory.DOCUMENT_VERSION = 1

local function error_value(code, retryable)
  return { code = code, retryable = retryable == true }
end

local function valid_id(value)
  return type(value) == "string" and #value >= 1 and #value <= 20 and value:match("^%d+$") ~= nil
end

local function valid_scope(scope)
  if type(scope) ~= "table" then return nil end
  if not valid_id(scope.guild_id) or not valid_id(scope.channel_id) then return nil end
  if scope.user_id ~= nil and not valid_id(scope.user_id) then return nil end
  return scope
end

local function sanitize(text)
  text = tostring(text)
  text = text:gsub("[%z\1-\8\11\12\14-\31\127]", "")
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function scope_key(scope)
  return table.concat({ "memory", scope.guild_id, scope.channel_id, scope.user_id or "shared" }, "/")
end

local function normalize_entry(entry, clock)
  if type(entry) ~= "table" then return nil end
  if entry.role ~= "user" and entry.role ~= "assistant" then return nil end
  if type(entry.content) ~= "string" then return nil end
  local content = sanitize(entry.content)
  if content == "" or #content > Memory.MAX_ENTRY_CHARS then return nil end
  local at = tonumber(entry.at)
  if not at or at ~= at or at < 0 then at = clock() end
  return { role = entry.role, content = content, at = math.floor(at) }
end

local function fetch_document(self, key)
  local called, envelope, read_error = pcall(self.connector.get, self.connector, self.collection, key)
  if not called then return nil, error_value("unavailable", true) end
  if envelope == nil then
    if type(read_error) == "table" and read_error.code == "not_found" then
      return { value = { version = Memory.DOCUMENT_VERSION, entries = {} }, version = 0 }
    end
    local code = type(read_error) == "table" and type(read_error.code) == "string" and read_error.code or "unavailable"
    local retryable = type(read_error) == "table" and read_error.retryable == true
    return nil, error_value(code, retryable)
  end
  if type(envelope) ~= "table" or type(envelope.version) ~= "number"
    or envelope.version < 1 or envelope.version % 1 ~= 0 or type(envelope.value) ~= "table" then
    return nil, error_value("invalid_store", false)
  end
  local entries = type(envelope.value.entries) == "table" and envelope.value.entries or {}
  return { value = { version = Memory.DOCUMENT_VERSION, entries = entries }, version = envelope.version }
end

function Memory.new(options)
  options = type(options) == "table" and options or {}
  local connector = options.connector
  if type(connector) ~= "table" or type(connector.get) ~= "function" or type(connector.put) ~= "function" then
    return nil, "connector_required"
  end
  local collection = options.collection or Memory.DEFAULT_COLLECTION
  if type(collection) ~= "string" or #collection < 1 or #collection > 120
    or collection:find("[^%w%-%._]") then
    return nil, "invalid_collection"
  end
  return setmetatable({
    connector = connector,
    collection = collection,
    clock = options.clock or os.time,
  }, Memory)
end

-- Returns: entries (array, possibly empty), meta | nil, err
function Memory:recall(scope, limit)
  scope = valid_scope(scope)
  if not scope then return nil, error_value("invalid_scope", false) end
  limit = tonumber(limit) or 5
  if limit ~= limit or limit < 1 then limit = 1 end
  limit = math.min(Memory.MAX_FETCH, math.floor(limit))

  local document, err = fetch_document(self, scope_key(scope))
  if not document then return nil, err end

  local entries, total = {}, 0
  local list = document.value.entries
  for index = #list, 1, -1 do
    if #entries >= limit then break end
    local entry = normalize_entry(list[index], self.clock)
    if entry then
      local cost = #entry.content + 8
      if total + cost > Memory.MAX_TOTAL_CHARS then break end
      total = total + cost
      table.insert(entries, 1, entry)
    end
  end
  return entries, { stored = #list, returned = #entries, key_scope = scope.user_id and "user" or "shared" }
end

-- Returns: true, version | nil, err.  Never blindly retries on conflict.
function Memory:append(scope, entry)
  scope = valid_scope(scope)
  if not scope then return nil, error_value("invalid_scope", false) end
  entry = normalize_entry(entry, self.clock)
  if not entry then return nil, error_value("invalid_entry", false) end

  local key = scope_key(scope)
  local document, err = fetch_document(self, key)
  if not document then return nil, err end

  local list = document.value.entries
  list[#list + 1] = entry
  while #list > Memory.MAX_ENTRIES do
    table.remove(list, 1)
  end

  local value = { version = Memory.DOCUMENT_VERSION, entries = list }
  local called, result, write_error = pcall(self.connector.put, self.connector,
    self.collection, key, value, document.version)
  if not called then return nil, error_value("unavailable", true) end
  if result == nil then
    if type(write_error) == "table" and write_error.code == "conflict" then
      return nil, error_value("conflict", true)
    end
    local code = type(write_error) == "table" and type(write_error.code) == "string" and write_error.code or "write_failed"
    local retryable = type(write_error) == "table" and write_error.retryable == true
    return nil, error_value(code, retryable)
  end
  if type(result) ~= "number" then return nil, error_value("write_failed", true) end
  return true, result
end

return Memory
