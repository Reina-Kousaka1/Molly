package.path = "./?.lua;./?/init.lua;" .. package.path

local function escape(value)
  return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
    local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b',
      ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
    return escapes[char] or string.format('\\u%04x', char:byte())
  end) .. '"'
end

local json = { null = {} }
local function encode(value)
  local kind = type(value)
  if value == json.null then return "null" end
  if kind == "nil" then return "null" end
  if kind == "boolean" or kind == "number" then return tostring(value) end
  if kind == "string" then return escape(value) end
  assert(kind == "table", "unsupported JSON fixture value")
  local metatable = getmetatable(value)
  local is_array = not (metatable and metatable.__jsontype == "object")
  local length, count = #value, 0
  for key in pairs(value) do
    count = count + 1
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then is_array = false end
  end
  if count == 0 then is_array = false end
  if is_array then
    assert(length == count, "sparse arrays are not supported by this fixture encoder")
    local parts = {}
    for index = 1, length do parts[index] = encode(value[index]) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for key in pairs(value) do
    assert(type(key) == "string", "JSON object keys must be strings")
    keys[#keys + 1] = key
  end
  table.sort(keys)
  local parts = {}
  for _, key in ipairs(keys) do parts[#parts + 1] = escape(key) .. ":" .. encode(value[key]) end
  return "{" .. table.concat(parts, ",") .. "}"
end
json.encode = encode
json.decode = function(line)
  assert(type(line) == "string" and line ~= "", "empty response frame")
  assert(json.next_response, "mock response was not staged")
  local response = json.next_response
  json.next_response = nil
  return response, #line + 1, nil
end

local active_mock
local socket_net = { connect = function(options)
  assert(options.path == "mock-seaworld")
  local mock = assert(active_mock)
  mock.connects = mock.connects + 1
  local queued, closed
  local function read()
    if queued then local value = queued; queued = nil; return value end
    return nil
  end
  local function write(frame)
    local operation = frame:match('"operation":"([^"]+)"')
    local request_id = frame:match('"request_id":"([^"]+)"')
    assert(operation and request_id and frame:sub(-1) == "\n", "invalid request frame")
    mock.writes[#mock.writes + 1] = { operation = operation, request_id = request_id, frame = frame }
    local response = mock.handler(operation, request_id, frame)
    if mock.drop_response_for == operation then return true end
    json.next_response = response
    local body = mock.response_body and mock.response_body(operation, request_id, response) or json.encode(response)
    queued = body .. "\n"
    return true
  end
  local socket = {}
  local function close()
    if not closed then
      closed = true
      mock.closes = mock.closes + 1
      if mock.on_close then mock.on_close() end
    end
  end
  mock.sessions[#mock.sessions + 1] = { read = read, write = write, close = close }
  return read, write, socket, nil, nil, close
end }

package.preload["json"] = function() return json end
package.preload["coro-net"] = function() return socket_net end
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
local Connector = require("src.persistence.seaworld_connector")
local GuildStore = require("src.persistence.guild_store")

local function clone(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = clone(item) end
  return result
end

local function new_mock()
  return {
    writes = {}, sessions = {}, connects = 0, closes = 0,
    handler = function(_, request_id)
      return { protocol_version = "1.0.0", request_id = request_id, ok = true, result = {} }
    end,
  }
end

local function find_exact_size(target, size_for)
  local low, high = 0, target
  while low <= high do
    local middle = math.floor((low + high) / 2)
    local size = size_for(middle)
    if size == target then return middle end
    if size < target then low = middle + 1 else high = middle - 1 end
  end
  error("could not construct fixture with exact frame size " .. tostring(target))
end

local function envelope(request_id, result)
  return { protocol_version = "1.0.0", request_id = request_id, ok = true, result = result }
end

local function update_payload(blob)
  return { collection = "fixture", id = "document", set = { data = { blob = blob } } }
end

local total, failed = 0, 0
local function test(name, fn)
  total = total + 1
  local ok, reason = pcall(fn)
  if ok then print("ok - " .. name)
  else failed = failed + 1; io.stderr:write("not ok - " .. name .. ": " .. tostring(reason) .. "\n") end
end

test("encoded JSON requests accept exactly one MiB including the newline", function()
  local maximum = Driver.max_frame_bytes
  assert(maximum == 1024 * 1024)
  local length = find_exact_size(maximum, function(size)
    return assert(Driver.measure_request("update", update_payload(string.rep("a", size)), "1"))
  end)
  local payload = update_payload(string.rep("a", length))
  assert(Driver.measure_request("update", update_payload(string.rep("a", length - 1)), "1") == maximum - 1)
  assert(Driver.measure_request("update", payload, "1") == maximum)
  local baseline = Driver.measure_request("update", update_payload("a"), "1")
  assert(Driver.measure_request("update", update_payload("ä"), "1") == baseline + 1,
    "frame limits count UTF-8 bytes rather than Unicode code points")

  local below_mock = new_mock(); active_mock = below_mock
  local below_driver = Driver.new({ path = "mock-seaworld", timeout_ms = 100 })
  local below_ok = below_driver:_call("update", update_payload(string.rep("a", length - 1)), false)
  assert(below_ok and #below_mock.writes == 1 and #below_mock.writes[1].frame == maximum - 1)

  local mock = new_mock(); active_mock = mock
  local driver = Driver.new({ path = "mock-seaworld", timeout_ms = 100 })
  local ok = driver:_call("update", payload, false)
  assert(ok and #mock.writes == 1 and #mock.writes[1].frame == maximum)
  assert(mock.writes[1].frame:sub(-1) == "\n")
end)

test("serialization failures return serialization_failed before opening a transport", function()
  local mock = new_mock(); active_mock = mock
  local original_encode = json.encode
  json.encode = function() error("fixture encode failure") end
  local called, ok, reason = pcall(function()
    local driver = Driver.new({ path = "mock-seaworld", timeout_ms = 100 })
    return driver:_call("update", update_payload("small"), false)
  end)
  json.encode = original_encode
  assert(called and not ok and reason == "serialization_failed")
  assert(mock.connects == 0 and #mock.writes == 0)
end)

test("one-byte-oversized JSON requests return resource_limit before opening a transport", function()
  local maximum = Driver.max_frame_bytes
  local length = find_exact_size(maximum, function(size)
    return assert(Driver.measure_request("update", update_payload(string.rep("a", size)), "1"))
  end)
  local mock = new_mock(); active_mock = mock
  local driver = Driver.new({ path = "mock-seaworld", timeout_ms = 100 })
  local ok, reason = driver:_call("update", update_payload(string.rep("a", length + 1)), false)
  assert(not ok and reason == "resource_limit")
  assert(#mock.writes == 0 and mock.connects == 0 and mock.closes == 0)
  assert(driver.request_sequence == 0, "a frame rejected before transport must not consume a request ID")
end)

test("response JSON frames accept limit minus one and exact limit, and reject one byte over", function()
  local maximum = Driver.max_frame_bytes
  local below_mock = new_mock(); active_mock = below_mock
  below_mock.response_body = function(_, request_id)
    local length = find_exact_size(maximum, function(size)
      return #json.encode(envelope(request_id, { pad = string.rep("r", size) })) + 1
    end)
    local response = envelope(request_id, { pad = string.rep("r", length - 1) })
    json.next_response = response
    local body = json.encode(response)
    below_mock.response_bytes = #body + 1
    return body
  end
  local below_driver = Driver.new({ path = "mock-seaworld", timeout_ms = 100 })
  local below_ok, below_result = below_driver:_call("health", {}, false)
  assert(below_ok and #below_result.pad > maximum - 257)
  assert(below_mock.response_bytes == maximum - 1)

  local exact_mock = new_mock(); active_mock = exact_mock
  exact_mock.response_body = function(_, request_id)
    local length = find_exact_size(maximum, function(size)
      return #json.encode(envelope(request_id, { pad = string.rep("r", size) })) + 1
    end)
    local response = envelope(request_id, { pad = string.rep("r", length) })
    json.next_response = response
    local body = json.encode(response)
    exact_mock.response_bytes = #body + 1
    return body
  end
  local exact_driver = Driver.new({ path = "mock-seaworld", timeout_ms = 100 })
  local accepted, result = exact_driver:_call("health", {}, false)
  assert(accepted and #result.pad > maximum - 256)
  assert(exact_mock.response_bytes == maximum)

  local oversized_mock = new_mock(); active_mock = oversized_mock
  oversized_mock.response_body = function(_, request_id)
    local length = find_exact_size(maximum, function(size)
      return #json.encode(envelope(request_id, { pad = string.rep("r", size) })) + 1
    end)
    local body = json.encode(envelope(request_id, { pad = string.rep("r", length + 1) }))
    oversized_mock.response_bytes = #body + 1
    return body
  end
  local oversized_driver = Driver.new({ path = "mock-seaworld", timeout_ms = 100 })
  local ok, reason = oversized_driver:_call("health", {}, false)
  assert(not ok and reason == "resource_limit")
  assert(oversized_mock.response_bytes == maximum + 1)
end)

test("transaction rollback follows a preflight resource_limit and discards earlier mock writes", function()
  local mock = new_mock(); active_mock = mock
  mock.document = { marker = "original" }
  mock.handler = function(operation, request_id)
    local result = {}
    if operation == "health" then
      result = { status = "healthy", api_version = "1.0.0", capabilities = {
        native_queries = true, field_updates = true, transactions = true } }
    elseif operation == "begin" then
      mock.snapshot = clone(mock.document)
      mock.transaction_active = true
    elseif operation == "update" then
      mock.document.marker = "changed"
      result = { updated = true }
    elseif operation == "rollback" then
      assert(mock.transaction_active and mock.snapshot, "rollback must follow a live transaction")
      mock.document = mock.snapshot
      mock.snapshot, mock.transaction_active = nil, false
    end
    return envelope(request_id, result)
  end
  local connector = Connector.new({ driver = Driver.new({ path = "mock-seaworld", timeout_ms = 100 }) })
  assert(connector:begin())
  assert(connector:update({ collection = "fixture", id = "document", set = { data = { marker = "changed" } } }))
  assert(mock.document.marker == "changed")
  local blob_length = find_exact_size(Driver.max_frame_bytes + 1, function(size)
    return assert(Driver.measure_request("update", update_payload(string.rep("x", size)), "4"))
  end)
  local too_large, reason = connector:update(update_payload(string.rep("x", blob_length)))
  assert(not too_large and reason == "resource_limit")
  assert(connector.in_transaction and connector.driver.in_transaction,
    "resource_limit must leave the active transaction usable for rollback")
  assert(connector:rollback())
  assert(not connector.in_transaction and not connector.driver.in_transaction and not mock.transaction_active)
  assert(mock.document.marker == "original" and mock.snapshot == nil)
  local updates, rollbacks = 0, 0
  for _, request in ipairs(mock.writes) do
    if request.operation == "update" then updates = updates + 1 end
    if request.operation == "rollback" then rollbacks = rollbacks + 1 end
  end
  assert(updates == 1 and rollbacks == 1, "the oversized second update must never be written")
end)

test("lost write acknowledgement returns outcome_unknown without retry or commit", function()
  local mock = new_mock(); active_mock = mock
  mock.drop_response_for = "update"
  mock.handler = function(operation, request_id)
    if operation == "health" then
      return envelope(request_id, { status = "healthy", api_version = "1.0.0", capabilities = {
        native_queries = true, field_updates = true, transactions = true } })
    elseif operation == "query" then
      return envelope(request_id, { rows = { { id = "doc-1" } } })
    elseif operation == "get" then
      return envelope(request_id, { document = { data = clone(mock.document) } })
    elseif operation == "begin" then
      mock.snapshot = clone(mock.document); mock.transaction_active = true
    elseif operation == "update" then
      mock.staged_updates = (mock.staged_updates or 0) + 1
    end
    return envelope(request_id, {})
  end
  mock.document = { guild = "10", accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {}, next_case = 1 }
  mock.on_close = function()
    if mock.transaction_active then
      mock.document = mock.snapshot
      mock.snapshot, mock.transaction_active = nil, false
    end
  end

  local root = Connector.new({ driver = Driver.new({ path = "mock-seaworld", timeout_ms = 100 }) })
  local store = GuildStore.new(root)
  local ok, reason = store:run("10", function(data)
    data.accounts["101"] = { wallet = 10 }
    return true, "updated", true
  end)
  assert(not ok and reason == "outcome_unknown")
  local update_count, commit_count, rollback_count = 0, 0, 0
  for _, request in ipairs(mock.writes) do
    if request.operation == "update" then update_count = update_count + 1 end
    if request.operation == "commit" then commit_count = commit_count + 1 end
    if request.operation == "rollback" then rollback_count = rollback_count + 1 end
  end
  assert(update_count == 1 and commit_count == 0 and rollback_count == 0)
  assert(mock.document.accounts["101"] == nil and not mock.transaction_active)
  assert(not store.busy_guilds["10"])
end)

test("server resource_limit rejection retains the transaction for explicit rollback", function()
  local mock = new_mock(); active_mock = mock
  mock.document = { guild = "10", accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {}, next_case = 1 }
  mock.handler = function(operation, request_id)
    if operation == "health" then
      return envelope(request_id, { status = "healthy", api_version = "1.0.0", capabilities = {
        native_queries = true, field_updates = true, transactions = true } })
    elseif operation == "query" then
      return envelope(request_id, { rows = { { id = "doc-1" } } })
    elseif operation == "get" then
      return envelope(request_id, { document = { data = clone(mock.document) } })
    elseif operation == "begin" then
      mock.snapshot = clone(mock.document); mock.transaction_active = true
    elseif operation == "update" then
      return { protocol_version = "1.0.0", request_id = request_id, ok = false,
        error = { code = "resource_limit" } }
    elseif operation == "rollback" then
      assert(mock.transaction_active and mock.snapshot)
      mock.document = mock.snapshot; mock.snapshot = nil; mock.transaction_active = false
    elseif operation == "commit" then
      error("a rejected update must never be committed")
    end
    return envelope(request_id, {})
  end

  local root = Connector.new({ driver = Driver.new({ path = "mock-seaworld", timeout_ms = 100 }) })
  local original_session = root.session
  function root:session()
    local session, reason = original_session(self)
    self.last_session = session
    return session, reason
  end
  local store = GuildStore.new(root)
  local ok, reason = store:run("10", function(data)
    data.accounts["101"] = { wallet = 10 }
    return true, "updated", true
  end)
  assert(not ok and reason == "resource_limit")
  assert(mock.document.accounts["101"] == nil and not mock.transaction_active)
  local updates, rollbacks, commits = 0, 0, 0
  for _, request in ipairs(mock.writes) do
    if request.operation == "update" then updates = updates + 1 end
    if request.operation == "rollback" then rollbacks = rollbacks + 1 end
    if request.operation == "commit" then commits = commits + 1 end
  end
  assert(updates == 1 and rollbacks == 1 and commits == 0)
  assert(root.last_session and not root.last_session.in_transaction)
end)

test("GuildStore propagates oversized-update resource_limit and rolls back the live mock transaction", function()
  local mock = new_mock(); active_mock = mock
  mock.document = { guild = "10", accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {}, next_case = 1 }
  mock.handler = function(operation, request_id)
    local result = {}
    if operation == "health" then
      result = { status = "healthy", api_version = "1.0.0", capabilities = {
        native_queries = true, field_updates = true, transactions = true } }
    elseif operation == "query" then
      result = { rows = { { id = "doc-1" } } }
    elseif operation == "get" then
      result = { document = { data = clone(mock.document) } }
    elseif operation == "update" then
      result = { updated = true }
    end
    return envelope(request_id, result)
  end

  local root_driver = Driver.new({ path = "mock-seaworld", timeout_ms = 100 })
  local connector = Connector.new({ driver = root_driver })
  local original_session = connector.session
  function connector:session()
    local session, reason = original_session(self)
    self.last_session = session
    return session, reason
  end
  local store = GuildStore.new(connector)
  local request_id = "6"
  local maximum = Driver.max_frame_bytes
  local blob_size = find_exact_size(maximum + 1, function(size)
    local data = clone(mock.document)
    data.blob = string.rep("x", size)
    local payload = { collection = "molly_g_10", id = "doc-1", set = { data = data } }
    return assert(Driver.measure_request("update", payload, request_id))
  end)
  local ok, reason = store:run("10", function(data)
    data.blob = string.rep("x", blob_size)
    return true, "updated", true
  end)
  assert(not ok and reason == "resource_limit")
  local operations, updates, rollbacks, commits = {}, 0, 0, 0
  for _, request in ipairs(mock.writes) do
    operations[#operations + 1] = request.operation
    if request.operation == "update" then updates = updates + 1 end
    if request.operation == "rollback" then rollbacks = rollbacks + 1 end
    if request.operation == "commit" then commits = commits + 1 end
  end
  assert(updates == 0 and rollbacks == 1 and commits == 0,
    "the oversized frame must not reach the socket and the open transaction must roll back")
  assert(mock.document.blob == nil and not mock.document.economy_receipts)
  assert(connector.last_session and connector.last_session.in_transaction == false)
  assert(connector.last_session.driver.in_transaction == false)
  assert(operations[#operations] == "rollback")
end)

print(string.format("%d tests, %d failures", total, failed))
if failed > 0 then os.exit(1) end
