local test_deps = os.getenv("MOLLY_TEST_DEPS_DIR")
if type(test_deps) == "string" and test_deps ~= "" then
  local separator = package.config:sub(1, 1)
  test_deps = test_deps:gsub("[/\\]$", "")
  package.path = test_deps .. separator .. "?.lua;" .. test_deps .. separator .. "?"
    .. separator .. "init.lua;" .. package.path
end
package.path = "./?.lua;./?/init.lua;./deps/?.lua;./deps/?/init.lua;" .. package.path

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
local function payload(size_or_text)
  local blob = type(size_or_text) == "number" and string.rep("x", size_or_text) or size_or_text
  return { collection = "fixture", id = "doc", set = { data = { blob = blob } } }
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
assert(Driver.measure_request("update", payload(exact_payload_size - 1), "1") == maximum - 1)
assert(Driver.measure_request("update", payload(exact_payload_size), "1") == maximum)
local unicode_payload = payload("ä")
local unicode_size = assert(Driver.measure_request("update", unicode_payload, "1"))
active_mock = new_mock()
local unicode_driver = Driver.new({ path = "mock-seaworld", timeout_ms = 100 })
local unicode_ok = unicode_driver:_call("update", unicode_payload, false)
assert(unicode_ok and #active_mock.writes[1].frame == unicode_size,
  "frame size must match the encoder's UTF-8 byte string length")

active_mock = new_mock()
local below_driver = Driver.new({ path = "mock-seaworld", timeout_ms = 100 })
local below_accepted = below_driver:_call("update", payload(exact_payload_size - 1), false)
assert(below_accepted and #active_mock.writes == 1 and #active_mock.writes[1].frame == maximum - 1)

active_mock = new_mock()
local exact_driver = Driver.new({ path = "mock-seaworld", timeout_ms = 100 })
local accepted = exact_driver:_call("update", payload(exact_payload_size), false)
assert(accepted and #active_mock.writes == 1 and #active_mock.writes[1].frame == maximum)

active_mock = new_mock()
local oversized_driver = Driver.new({ path = "mock-seaworld", timeout_ms = 100 })
local too_large, reason = oversized_driver:_call("update", payload(exact_payload_size + 1), false)
assert(not too_large and reason == "resource_limit" and #active_mock.writes == 0)
assert(active_mock.connects == 0 and active_mock.closes == 0 and oversized_driver.request_sequence == 0,
  "oversized requests must be rejected before connection or sequence allocation")

local function response_for_frame(target, request_id)
  local pad_length = find_exact_size(target, function(length)
    return #json.encode(envelope(request_id, { pad = string.rep("r", length) })) + 1
  end)
  return envelope(request_id, { pad = string.rep("r", pad_length) })
end

local below_response_mock = new_mock()
below_response_mock.response = function(_, request_id) return response_for_frame(maximum - 1, request_id) end
active_mock = below_response_mock
local below_response_driver = Driver.new({ path = "mock-seaworld", timeout_ms = 100 })
local below_response_ok = below_response_driver:_call("health", {}, false)
assert(below_response_ok)
assert(#json.encode(response_for_frame(maximum - 1, "1")) + 1 == maximum - 1)

local exact_response_mock = new_mock()
exact_response_mock.response = function(_, request_id) return response_for_frame(maximum, request_id) end
active_mock = exact_response_mock
local exact_response_driver = Driver.new({ path = "mock-seaworld", timeout_ms = 100 })
local response_ok, result = exact_response_driver:_call("health", {}, false)
assert(response_ok and type(result.pad) == "string")
assert(#json.encode(response_for_frame(maximum, "1")) + 1 == maximum)

local oversized_response_mock = new_mock()
oversized_response_mock.response = function(_, request_id)
  local exact = response_for_frame(maximum, request_id)
  local response = envelope(request_id, { pad = exact.result.pad .. "r" })
  assert(#json.encode(response) + 1 == maximum + 1)
  return response
end
active_mock = oversized_response_mock
local oversized_response_driver = Driver.new({ path = "mock-seaworld", timeout_ms = 100 })
local response_too_large, response_reason = oversized_response_driver:_call("health", {}, false)
assert(not response_too_large and response_reason == "resource_limit")

print("Luvit JSON frame checks passed at 1,048,575; 1,048,576; and 1,048,577 bytes")
