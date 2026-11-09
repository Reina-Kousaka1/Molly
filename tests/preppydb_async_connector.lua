package.path = "./?.lua;./?/init.lua;" .. package.path

local Connector = require("src.preppydb.connector")
local requests, pending = {}, nil
local client = {
  call_async = function(_, method, path, body, callback)
    requests[#requests + 1] = { method = method, path = path, body = body }
    if path == "/readyz" then callback({ ready = true }, nil)
    elseif path == "/v1/collections" then callback({ collections = { { name = "molly_guild_state" } } }, nil)
    else pending = callback end
  end,
}
local connector = assert(Connector.new({
  client = client,
  async_bridge = true,
  encode = function(value) return tostring(value) end,
}))

local result
local co = coroutine.create(function()
  result = connector:get("items", "key/with space")
end)
local resumed, reason = coroutine.resume(co)
assert(resumed and reason == nil and coroutine.status(co) == "suspended")
assert(requests[1].method == "GET")
assert(requests[1].path == "/v1/collections/items/documents/key%2Fwith%20space")
pending({ key = "key/with space", value = { n = 4 }, version = 7 }, nil)
assert(coroutine.status(co) == "dead")
assert(result.version == 7 and result.value.n == 4)

local committed
co = coroutine.create(function()
  committed = connector:transaction({ {
    op = "put", collection = "molly_guild_state", key = "42", expected_version = 7, value = { ok = true },
  } })
end)
resumed = coroutine.resume(co)
assert(resumed and coroutine.status(co) == "suspended")
local request = requests[2]
assert(request.method == "POST" and request.path == "/v1/transactions")
assert(request.body.operations[1].expected_version == 7)
pending({ operations = 1, seq = 8 }, nil)
assert(coroutine.status(co) == "dead" and committed.seq == 8)

local ready
co = coroutine.create(function() ready = connector:ready() end)
assert(coroutine.resume(co) and coroutine.status(co) == "dead" and ready.ready == true)
local names
co = coroutine.create(function() names = connector:collections() end)
assert(coroutine.resume(co) and coroutine.status(co) == "dead")
assert(names[1] == "molly_guild_state")

local indexed
co = coroutine.create(function() indexed = connector:find("items", "by_name", "blue") end)
assert(coroutine.resume(co) and coroutine.status(co) == "suspended")
assert(requests[5].method == "GET")
assert(requests[5].path == "/v1/collections/items/indexes/by_name?value=blue")
pending({ documents = { { key = "blue" } } }, nil)
assert(coroutine.status(co) == "dead" and indexed[1].key == "blue")

local ranged
co = coroutine.create(function() ranged = connector:range("items", "by_score", 2, 9) end)
assert(coroutine.resume(co) and coroutine.status(co) == "suspended")
assert(requests[6].method == "GET")
assert(requests[6].path == "/v1/collections/items/indexes/by_score?from=2&to=9")
pending({ rows = { { key = "mid" } } }, nil)
assert(coroutine.status(co) == "dead" and ranged[1].key == "mid")

local outside, outside_error = connector:get("items", "key")
assert(outside == nil and outside_error.code == "async_context_required")
print("PreppyDB coroutine bridge: pass")
