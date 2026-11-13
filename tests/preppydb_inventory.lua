package.path = "./?.lua;./?/init.lua;" .. package.path

local preppydb = require("src.preppydb.client")
local requests = {}
local client = assert(preppydb.new({
  url = "http://127.0.0.1:7077",
  token = "fixture-admin-token",
  retries = 0,
  transport = function(request, callback)
    requests[#requests + 1] = request
    if request.url:find("/v1/inventory/", 1, true) then
      callback(200, '{"data":{"sequence":"9007199254740993","generation":"2","collection":"profiles","count":"1","next_cursor":null,"records":[{"key":"guild/1","serialized_bytes":"41","sha256":"' .. string.rep("a", 64) .. '"}]}}', {})
    else
      callback(200, '{"data":{"snapshot_id":"preppydb:2:9007199254740993:root","sequence":"9007199254740993","generation":"2","complete":true,"collection_count":"1","document_count":"1","serialized_bytes":"100","sha256":"' .. string.rep("b", 64) .. '","collections":[{"name":"profiles","documents":"1","metadata_bytes":"40","document_bytes":"60","metadata_sha256":"' .. string.rep("c", 64) .. '","documents_sha256":"' .. string.rep("d", 64) .. '"}]}}', {})
    end
  end,
}))

local inventory, err = client:inventory()
assert(inventory and not err)
assert(inventory.sequence == "9007199254740993", "64-bit sequence must remain exact")
assert(inventory.collections[1].documents == "1")
assert(requests[1].method == "GET" and requests[1].url == "http://127.0.0.1:7077/v1/inventory")
assert(requests[1].headers.Authorization == "Bearer fixture-admin-token")

local page = assert(client:inventory_page("profiles", inventory.sequence, inventory.generation, {
  limit = 10,
  after = "guild/0",
}))
assert(page.records[1].key == "guild/1")
assert(page.records[1].serialized_bytes == "41")
assert(requests[2].url:find("sequence=9007199254740993", 1, true))
assert(requests[2].url:find("generation=2", 1, true))
assert(requests[2].url:find("after=guild%2F0", 1, true))

local before = #requests
local invalid, invalid_error = client:inventory_page("profiles", 9007199254740993, "2")
assert(invalid == nil and invalid_error.code == "invalid_inventory_request")
invalid, invalid_error = client:inventory_page("profiles", "01", "2")
assert(invalid == nil and invalid_error.code == "invalid_inventory_request")
invalid, invalid_error = client:inventory_page("profiles", "1", "2", { limit = 501 })
assert(invalid == nil and invalid_error.code == "invalid_inventory_request")
assert(#requests == before, "invalid inventory requests must not reach the transport")

local oversized_count = assert(preppydb.new({
  url = "http://127.0.0.1:7077",
  transport = function(_, callback)
    callback(200, '{"data":{"complete":true,"sequence":"1","generation":"0","collection_count":"9007199254740993","document_count":"0","serialized_bytes":"0","sha256":"' .. string.rep("a", 64) .. '","snapshot_id":"x","collections":[{"name":"profiles","documents":"0","metadata_bytes":"0","document_bytes":"0","metadata_sha256":"' .. string.rep("b", 64) .. '","documents_sha256":"' .. string.rep("c", 64) .. '"}]}}', {})
  end,
}))
local oversized_result, oversized_error = oversized_count:inventory()
assert(oversized_result == nil and oversized_error.code == "invalid_inventory",
  "collection count must be compared without lossy numeric conversion")
local malformed = assert(preppydb.new({
  url = "http://127.0.0.1:7077",
  transport = function(_, callback)
    callback(200, '{"data":{"complete":true,"sequence":"1","generation":"0","collection_count":"0","document_count":"0","serialized_bytes":"0","sha256":"bad","snapshot_id":"x","collections":[]}}', {})
  end,
}))
local result, malformed_error = malformed:inventory()
assert(result == nil and malformed_error.code == "invalid_inventory")

print("PreppyDB inventory client: pass")
