local net = require("coro-net")
local json = require("json")
local uv = require("uv")

local Driver = {}
Driver.__index = Driver
local MAX_FRAME = 1024 * 1024

local function object_copy(value)
  local copy = {}
  for key, item in pairs(value or {}) do copy[key] = item end
  return setmetatable(copy, { __jsontype = "object" })
end

local function numbers_safe(value, seen, depth)
  if depth > 32 then return false end
  if type(value) == "number" then
    return value == value and math.abs(value) <= 99999999999999 and tonumber(tostring(value)) == value
  end
  if type(value) ~= "table" or value == json.null then return true end
  if seen[value] then return false end
  seen[value] = true
  for _, child in pairs(value) do
    if not numbers_safe(child, seen, depth + 1) then return false end
  end
  seen[value] = nil
  return true
end

local function encode_request(operation, payload, request_id)
  if not numbers_safe(payload, {}, 0) then return nil, "invalid_argument" end
  local body = object_copy(payload)
  if type(body.document) == "table" and body.document ~= json.null then body.document = object_copy(body.document) end
  if type(body.set) == "table" and body.set ~= json.null then body.set = object_copy(body.set) end
  local ok, request = pcall(json.encode, {
    protocol_version = "1.0.0", request_id = request_id, operation = operation, payload = body,
  })
  if not ok or type(request) ~= "string" then return nil, "serialization_failed" end
  return request .. "\n"
end

local function close_handle(handle)
  if handle and not handle:is_closing() then handle:close() end
end

local function may_mutate(operation)
  return operation == "create_collection" or operation == "insert" or operation == "update"
    or operation == "delete" or operation == "upsert"
end

function Driver.new(options)
  assert(type(options.path) == "string" and options.path ~= "", "socket path required")
  return setmetatable({ path = options.path, timeout = options.timeout_ms or 1000, request_sequence = 0 }, Driver)
end

-- A fork has no socket, buffer, request, or transaction state in common with
-- its parent. Each persistence operation therefore owns one SeaWorld session.
function Driver:fork()
  return Driver.new({ path = self.path, timeout_ms = self.timeout })
end

function Driver:initialize() return true end
function Driver:connect() return true end

function Driver.measure_request(operation, payload, request_id)
  local frame, reason = encode_request(operation, payload, request_id)
  if not frame then return nil, reason end
  return #frame
end

Driver.max_frame_bytes = MAX_FRAME

function Driver:close()
  if self.closer then self.closer() else close_handle(self.socket) end
  self.socket, self.read, self.write, self.closer, self.in_transaction = nil, nil, nil, nil, false
  self.buffer = ""
  return true
end

function Driver:_open(timeout)
  if self.socket then return true end
  local read, write, socket, _, _, closer = net.connect({ path = self.path, timeout = timeout or self.timeout })
  if not read then return false, "transport_unavailable" end
  self.read, self.write, self.socket, self.closer, self.buffer = read, write, socket, closer, ""
  return true
end

function Driver:_call(operation, payload, keep, timeout)
  if self.busy then return false, "transport_busy" end
  self.busy = true
  local transaction_at_start = self.in_transaction == true
  local preflight_failure = false
  local application_error = false
  local request_attempted = false
  local ok, first, second = pcall(function()
    local call_timeout = timeout or self.timeout
    local id = tostring(self.request_sequence + 1)
    local request, encode_reason = encode_request(operation, payload, id)
    if not request then
      preflight_failure = true
      return false, encode_reason
    end
    if #request > MAX_FRAME then
      preflight_failure = true
      return false, "resource_limit"
    end
    local connected, reason = self:_open(call_timeout)
    if not connected then return false, reason end
    self.request_sequence = self.request_sequence + 1
    local timer = uv.new_timer()
    timer:start(call_timeout, 0, function() if self.closer then self.closer() end end)
    local success, response, err = pcall(function()
      request_attempted = true
      local written = self.write(request)
      if not written then return nil, "transport_unavailable" end
      while true do
        local newline = self.buffer:find("\n", 1, true)
        if newline then
          if newline > MAX_FRAME then return nil, "resource_limit" end
          if newline < #self.buffer then return nil, "invalid_response" end
          local line = self.buffer:sub(1, newline - 1)
          self.buffer = ""
          local value, pos, decode_err = json.decode(line, 1, json.null)
          if decode_err or not value or line:sub(pos):find("%S") then return nil, "invalid_response" end
          return value
        end
        local chunk = self.read()
        if type(chunk) ~= "string" or chunk == "" then return nil, "transport_unavailable" end
        local chunk_newline = chunk:find("\n", 1, true)
        if chunk_newline then
          if #self.buffer + chunk_newline > MAX_FRAME then return nil, "resource_limit" end
          if chunk_newline < #chunk then return nil, "invalid_response" end
        elseif #self.buffer + #chunk > MAX_FRAME then
          return nil, "resource_limit"
        end
        self.buffer = self.buffer .. chunk
      end
    end)
    timer:stop(); timer:close()
    if not success or not response then
      local failure_reason = err or "transport_unavailable"
      if request_attempted and (transaction_at_start or may_mutate(operation)) then
        return false, "outcome_unknown"
      end
      return false, failure_reason
    end
    if type(response) ~= "table" or response.protocol_version ~= "1.0.0" or response.request_id ~= id or type(response.ok) ~= "boolean" then
      if request_attempted and (transaction_at_start or may_mutate(operation)) then return false, "outcome_unknown" end
      return false, "invalid_response"
    end
    if not response.ok then
      application_error = true
      return false, type(response.error) == "table" and response.error.code or "operation_failed"
    end
    if type(response.result) ~= "table" then
      if request_attempted and (transaction_at_start or may_mutate(operation)) then return false, "outcome_unknown" end
      return false, "invalid_response"
    end
    return true, response.result
  end)
  self.busy = false
  local preserve_transaction = keep and transaction_at_start and (preflight_failure or application_error)
  if (not ok or not first or not keep) and not preserve_transaction then self:close() end
  if not ok then
    if request_attempted and (transaction_at_start or may_mutate(operation)) then return false, "outcome_unknown" end
    return false, "transport_unavailable"
  end
  return first, second
end

function Driver:health()
  -- A configured persistence timeout may be generous for normal operations.
  -- Health is an interaction-facing read and must stay within one second.
  local ok, result = self:_call("health", {}, false, math.min(self.timeout, 1000))
  if not ok then return { status = "unavailable", detail = result } end
  return result
end

function Driver:operation(name, payload)
  return self:_call(name, payload, self.in_transaction)
end

function Driver:begin()
  if self.in_transaction then return false, "transaction_state" end
  local ok, result = self:_call("begin", {}, true)
  if ok then self.in_transaction = true end
  return ok, result
end

function Driver:commit()
  if not self.in_transaction then return false, "transaction_state" end
  return self:_call("commit", {}, false)
end

function Driver:rollback()
  if not self.in_transaction then return false, "transaction_state" end
  return self:_call("rollback", {}, false)
end

return Driver
