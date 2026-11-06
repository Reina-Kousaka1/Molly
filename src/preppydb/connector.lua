-- Molly's transport boundary for the official PreppyDB Lua/Luvit client.
-- No Molly feature is routed here until its owner explicitly opts in.
local Connector = {}
Connector.__index = Connector

function Connector.new(options)
  options = options or {}
  local client = options.client
  if not client then
    local library = options.library
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
  end
  return setmetatable({ client = client }, Connector)
end

local function invoke(self, method, ...)
  local fn = self.client[method]
  if type(fn) ~= "function" then return nil, { code = "unsupported_operation" } end
  local ok, result, err = pcall(fn, self.client, ...)
  if not ok then return nil, { code = "client_error" } end
  return result, err
end

function Connector:health() return invoke(self, "health") end
function Connector:ready() return invoke(self, "ready") end
function Connector:version() return invoke(self, "version") end
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
