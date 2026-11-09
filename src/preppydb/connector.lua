-- Molly's transport boundary for the official PreppyDB Lua/Luvit client.
-- No Molly feature is routed here until its owner explicitly opts in.
local Connector = {}
Connector.__index = Connector

function Connector.new(options)
  options = options or {}
  local client = options.client
  local encoder = options.encode
  local library = options.library
  if not client then
    if not library then
      local loaded, result = pcall(require, "src.preppydb.client")
      if not loaded then return nil, "client_unavailable" end
      library = result
    end
    if type(library) ~= "table" or type(library.new) ~= "function" then
      return nil, "client_unavailable"
    end
    local created, result, err = pcall(library.new, {
      url = options.url,
      token = options.token,
      timeout = options.timeout_ms,
      max_response_bytes = options.max_response_bytes,
      retries = 0,
      transport = options.transport,
      wait = options.wait,
    })
    if not created then return nil, "client_unavailable" end
    if not result then return nil, err or "client_unavailable" end
    client = result
    encoder = encoder or library.encode
  end
  if not encoder and type(library) == "table" then
    encoder = library.encode or (type(library.json) == "table" and library.json.encode)
  end
  return setmetatable({ client = client, encoder = encoder, async_bridge = options.async_bridge == true }, Connector)
end

local function path_part(value)
  return (tostring(value):gsub("[^%w%-%._~]", function(char)
    return string.format("%%%02X", char:byte())
  end))
end

function Connector:_await(method, path, body)
  if not self.async_bridge or type(self.client.call_async) ~= "function" then
    return nil, { code = "unsupported_operation", retryable = false }
  end
  local thread, is_main = coroutine.running()
  if not thread or is_main then
    return nil, { code = "async_context_required", retryable = false }
  end
  local finished, waiting, result, err = false, false, nil, nil
  local started, start_error = pcall(self.client.call_async, self.client, method, path, body, function(value, failure)
    if finished then return end
    finished, result, err = true, value, failure
    if waiting then coroutine.resume(thread) end
  end)
  if not started then return nil, { code = "client_error", retryable = false } end
  if finished then return result, err end
  waiting = true
  if finished then return result, err end
  coroutine.yield()
  return result, err
end

local function async_invoke(self, method, ...)
  local a, b, c = ...
  if method == "call" then return self:_await(a, b, c) end
  if method == "health" then return self:_await("GET", "/healthz") end
  if method == "ready" then return self:_await("GET", "/readyz") end
  if method == "version" then return self:_await("GET", "/v1/version") end
  if method == "whoami" then return self:_await("GET", "/v1/auth/whoami") end
  if method == "collections" then
    local data, err = self:_await("GET", "/v1/collections")
    if not data then return nil, err end
    local names = {}
    for _, entry in ipairs(data.collections or {}) do
      names[#names + 1] = type(entry) == "table" and entry.name or entry
    end
    return names
  end
  if method == "collection" then return self:_await("GET", "/v1/collections/" .. path_part(a)) end
  if method == "create_collection" then
    local body = { name = a }; if b ~= nil then body.schema = b end
    return self:_await("POST", "/v1/collections", body)
  end
  if method == "get_envelope" then
    return self:_await("GET", "/v1/collections/" .. path_part(a) .. "/documents/" .. path_part(b))
  end
  if method == "put" then
    local data, err
    local expected = select(4, ...)
    if expected ~= nil then
      data, err = self:_await("PUT", "/v1/collections/" .. path_part(a) .. "/documents/" .. path_part(b),
        { value = c, expected_version = expected })
    else
      data, err = self:_await("POST", "/v1/collections/" .. path_part(a) .. "/documents", { key = b, value = c })
    end
    if not data then return nil, err end
    return data.version
  end
  if method == "delete" then
    local path = "/v1/collections/" .. path_part(a) .. "/documents/" .. path_part(b)
    local expected = select(3, ...)
    if expected ~= nil then path = path .. "?expected_version=" .. tostring(expected) end
    local data, err = self:_await("DELETE", path)
    if not data then return nil, err end
    return true
  end
  if method == "scan" then
    local options = b or {}
    local query = { "limit=" .. tostring(options.limit or 100) }
    if options.prefix then query[#query + 1] = "prefix=" .. path_part(options.prefix) end
    if options.offset then query[#query + 1] = "offset=" .. tostring(options.offset) end
    if options.reverse then query[#query + 1] = "reverse=true" end
    local data, err = self:_await("GET", "/v1/collections/" .. path_part(a) .. "/documents?" .. table.concat(query, "&"))
    if not data then return nil, err end
    return data.documents or {}
  end
  if method == "find" then
    if type(self.encoder) ~= "function" then
      return nil, { code = "serialization_unavailable", retryable = false }
    end
    local ok, encoded = pcall(self.encoder, c)
    if not ok or type(encoded) ~= "string" then
      return nil, { code = "serialization_failed", retryable = false }
    end
    local path = "/v1/collections/" .. path_part(a) .. "/indexes/" .. path_part(b)
      .. "?value=" .. path_part(encoded)
    local data, err = self:_await("GET", path)
    if not data then return nil, err end
    return data.documents or {}
  end
  if method == "range" then
    if type(self.encoder) ~= "function" then
      return nil, { code = "serialization_unavailable", retryable = false }
    end
    local from_value, to_value = select(3, ...)
    local query = {}
    local function append_bound(name, value)
      if value == nil then return true end
      local ok, encoded = pcall(self.encoder, value)
      if not ok or type(encoded) ~= "string" then return false end
      query[#query + 1] = name .. "=" .. path_part(encoded)
      return true
    end
    if not append_bound("from", from_value) or not append_bound("to", to_value) then
      return nil, { code = "serialization_failed", retryable = false }
    end
    local path = "/v1/collections/" .. path_part(a) .. "/indexes/" .. path_part(b)
      .. "?" .. table.concat(query, "&")
    local data, err = self:_await("GET", path)
    if not data then return nil, err end
    return data.rows or data.documents or {}
  end
  if method == "batch" then
    return self:_await("POST", "/v1/collections/" .. path_part(a) .. "/batch", { operations = b })
  end
  return nil, { code = "unsupported_operation", retryable = false }
end

local function invoke(self, method, ...)
  if self.async_bridge then return async_invoke(self, method, ...) end
  local fn = self.client[method]
  if type(fn) ~= "function" then return nil, { code = "unsupported_operation" } end
  local ok, result, err = pcall(fn, self.client, ...)
  if not ok then return nil, { code = "client_error" } end
  return result, err
end

function Connector:health() return invoke(self, "health") end
function Connector:ready() return invoke(self, "ready") end
function Connector:version() return invoke(self, "version") end
function Connector:whoami() return invoke(self, "whoami") end
function Connector:collections() return invoke(self, "collections") end
function Connector:collection(name) return invoke(self, "collection", name) end
function Connector:create_collection(name, schema) return invoke(self, "create_collection", name, schema) end
function Connector:get(collection, key) return invoke(self, "get_envelope", collection, key) end
function Connector:put(collection, key, value, expected_version)
  return invoke(self, "put", collection, key, value, expected_version)
end
function Connector:delete(collection, key, expected_version)
  return invoke(self, "delete", collection, key, expected_version)
end
function Connector:scan(collection, options) return invoke(self, "scan", collection, options) end
function Connector:find(collection, index, value) return invoke(self, "find", collection, index, value) end
function Connector:range(collection, index, from_value, to_value)
  return invoke(self, "range", collection, index, from_value, to_value)
end
function Connector:batch(collection, operations)
  return invoke(self, "batch", collection, operations)
end

-- PreppyDB's HTTP transaction endpoint publishes all checked document changes
-- as one WAL record. It is deliberately a single request: the connector never
-- retries a write whose response may have been lost.
function Connector:transaction(operations)
  if type(operations) ~= "table" or #operations == 0 then
    return nil, { code = "invalid_argument", retryable = false }
  end
  return invoke(self, "call", "POST", "/v1/transactions", { operations = operations })
end

function Connector:encoded_size(value)
  if type(self.encoder) ~= "function" then return nil, "serialization_unavailable" end
  local ok, encoded = pcall(self.encoder, value)
  if not ok or type(encoded) ~= "string" then return nil, "serialization_failed" end
  return #encoded
end

-- Use this entry point from Luvit's event loop. The client enforces response
-- limits and invokes callback(result, err); no write is retried automatically.
function Connector:request(method, path, body, callback)
  if type(callback) ~= "function" then return nil, { code = "invalid_argument" } end
  if type(self.client.call_async) ~= "function" then
    callback(nil, { code = "unsupported_operation" })
    return
  end
  local delivered = false
  local function once(result, err)
    if delivered then return end
    delivered = true
    callback(result, err)
  end
  local ok = pcall(self.client.call_async, self.client, method, path, body, once)
  if not ok and not delivered then once(nil, { code = "client_error" }) end
end

return Connector
