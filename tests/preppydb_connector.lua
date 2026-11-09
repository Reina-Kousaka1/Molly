package.path = "./?.lua;./?/init.lua;" .. package.path

local Connector = require("src.preppydb.connector")

local calls = {}
local client = {
  health = function() return { status = "ok" } end,
  version = function() return { version = "0.1.0" } end,
  get_envelope = function(_, collection, key)
    calls[#calls + 1] = { "get", collection, key }
    return { key = key, value = { active = true }, version = 4 }
  end,
  put = function(_, collection, key, value, expected)
    calls[#calls + 1] = { "put", collection, key, value, expected }
    return 5
  end,
  batch = function(_, collection, operations)
    calls[#calls + 1] = { "batch", collection, operations }
    return { applied = #operations }
  end,
  call = function(_, method, path, body)
    calls[#calls + 1] = { "call", method, path, body }
    return { operations = #body.operations, seq = 11 }
  end,
  delete = function() return nil, { code = "conflict", status = 409 } end,
  call_async = function(_, method, path, body, callback)
    calls[#calls + 1] = { "request", method, path, body }
    callback({ version = "0.1.0" }, nil)
  end,
}

local connector = assert(Connector.new({ client = client }))
assert(connector:health().status == "ok")
assert(connector:version().version == "0.1.0")
assert(connector:get("items", "one").version == 4)
assert(connector:put("items", "one", { active = false }, 4) == 5)
assert(calls[2][5] == 4)
assert(connector:batch("items", { { op = "delete", key = "one" } }).applied == 1)
assert(connector:transaction({ { op = "put", collection = "items", key = "one", expected_version = 4, value = {} } }).seq == 11)
assert(calls[4][2] == "POST" and calls[4][3] == "/v1/transactions")
local result, err = connector:delete("items", "one", 4)
assert(result == nil and err.code == "conflict" and err.status == 409)
result, err = connector:find("items", "missing", "x")
assert(result == nil and err.code == "unsupported_operation")

local library = {
  new = function(options)
    assert(options.retries == 0)
    assert(options.url == "http://127.0.0.1:7077")
    return client
  end,
  json = { encode = function(value) return value == "size" and '"size"' or tostring(value) end },
}
local library_connector = assert(Connector.new({ library = library, url = "http://127.0.0.1:7077" }))
assert(library_connector:encoded_size("size") == 6)
local observed
connector:request("GET", "/v1/version", nil, function(value, request_err)
  assert(request_err == nil)
  observed = value.version
end)
assert(observed == "0.1.0")

local wire = {}
local real = assert(Connector.new({
  url = "http://127.0.0.1:7077",
  token = "test-token",
  transport = function(request, callback)
    wire[#wire + 1] = request
    if request.method == "POST" then
      callback(200, '{"data":{"version":7}}', {})
    else
      callback(200, '{"data":{"key":"one","value":{"active":true},"version":7}}', {})
    end
  end,
}))
assert(real:put("items", "one", { active = true }) == 7)
assert(wire[1].url == "http://127.0.0.1:7077/v1/collections/items/documents")
assert(wire[1].headers.Authorization == "Bearer test-token")
assert(wire[1].body:find('"active":true', 1, true))
assert(real:get("items", "one").version == 7)
print("PreppyDB connector: pass")
