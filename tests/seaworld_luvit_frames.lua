package.path = "./?.lua;./?/init.lua;" .. package.path

local json = require("json")
local active_mock
local net = { connect = function(options)
  assert(options.path == "mock-seaworld")
  local mock = assert(active_mock)
  mock.connects = mock.connects + 1
  local queued, closed
  local function read()
    if queued then local value = queued; queued = nil; return value end
  end
  local function write(frame)
    local operation = frame:match('"operation":"([^"]+)"')
    local request_id = frame:match('"request_id":"([^"]+)"')
    assert(operation and request_id and frame:sub(-1) == "\n")
    mock.writes[#mock.writes + 1] = { operation = operation, request_id = request_id, frame = frame }
    local response = mock.response(operation, request_id)
    queued = json.encode(response) .. "\n"
    return true
  end
  local function close()
    if not closed then closed = true; mock.closes = mock.closes + 1 end
  end
  return read, write, {}, nil, nil, close
end }

package.preload["coro-net"] = function() return net end
package.preload["uv"] = function()
  return { new_timer = function()
    local timer = {}
    function timer:start() return true end
    function timer:stop() return true end
    function timer:close() return true end
    return timer
  end }
end

local Driver = require("src.seaworld.socket_driver")
local function object(value) return setmetatable(value, { __jsontype = "object" }) end
local function envelope(request_id, result)
  return { protocol_version = "1.0.0", request_id = request_id, ok = true, result = result }
end
local function payload(size)
  return { collection = "fixture", id = "doc", set = { data = { blob = string.rep("x", size) } } }
end
local function find_exact_size(target, size_for)
  local low, high = 0, target
  while low <= high do
    local middle = math.floor((low + high) / 2)
    local size = size_for(middle)
    if size == target then return middle end
    if size < target then low = middle + 1 else high = middle - 1 end
  end
  error("unable to construct exact Luvit JSON frame")
end
local function new_mock(response)
  return { writes = {}, connects = 0, closes = 0,
    response = response or function(_, request_id) return envelope(request_id, {}) end }
end

local maximum = Driver.max_frame_bytes
assert(maximum == 1024 * 1024)
local exact_payload_size = find_exact_size(maximum, function(length)
  return assert(Driver.measure_request("update", payload(length), "1"))
end)
assert(Driver.measure_request("update", payload(exact_payload_size), "1") == maximum)
active_mock = new_mock()
local exact_driver = Driver.new({ path = "mock-seaworld", timeout_ms = 100 })
local accepted = exact_driver:_call("update", payload(exact_payload_size), false)
assert(accepted and #active_mock.writes == 1 and #active_mock.writes[1].frame == maximum)

active_mock = new_mock()
local oversized_driver = Driver.new({ path = "mock-seaworld", timeout_ms = 100 })
local too_large, reason = oversized_driver:_call("update", payload(exact_payload_size + 1), false)
assert(not too_large and reason == "resource_limit" and #active_mock.writes == 0)

local exact_response_mock = new_mock()
exact_response_mock.response = function(_, request_id)
  local pad_length = find_exact_size(maximum, function(length)
    return #json.encode(envelope(request_id, { pad = string.rep("r", length) })) + 1
  end)
  return envelope(request_id, { pad = string.rep("r", pad_length) })
end
active_mock = exact_response_mock
local exact_response_driver = Driver.new({ path = "mock-seaworld", timeout_ms = 100 })
local response_ok, result = exact_response_driver:_call("health", {}, false)
assert(response_ok and type(result.pad) == "string")

local oversized_response_mock = new_mock()
oversized_response_mock.response = function(_, request_id)
  local pad_length = find_exact_size(maximum, function(length)
    return #json.encode(envelope(request_id, { pad = string.rep("r", length) })) + 1
  end)
  return envelope(request_id, { pad = string.rep("r", pad_length + 1) })
end
active_mock = oversized_response_mock
local oversized_response_driver = Driver.new({ path = "mock-seaworld", timeout_ms = 100 })
local response_too_large, response_reason = oversized_response_driver:_call("health", {}, false)
assert(not response_too_large and response_reason == "resource_limit")

print("Luvit JSON frame checks passed at 1,048,576 bytes including newline; +1 byte rejected")
