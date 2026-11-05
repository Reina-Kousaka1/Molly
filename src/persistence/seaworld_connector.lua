local Connector = {}
Connector.__index = Connector

local function state(status, detail, extra)
  local result = { status = status, detail = detail }
  for key, value in pairs(extra or {}) do
    result[key] = value
  end
  return result
end

local function copy(value)
  local result = {}
  for key, item in pairs(value) do
    result[key] = item
  end
  return result
end

function Connector.new(options)
  options = options or {}
  return setmetatable({
    driver = options.driver,
    expected_api_version = options.expected_api_version or "1.0.0",
    current = state(options.driver and "unavailable" or "not_configured", options.driver and "not_initialized" or "not_configured"),
  }, Connector)
end

function Connector:get_state()
  return copy(self.current)
end

function Connector:initialize()
  if not self.driver then
    self.current = state("not_configured", "not_configured")
    return self:get_state()
  end
  if type(self.driver.initialize) == "function" then
    local ok = pcall(self.driver.initialize, self.driver)
    if not ok then
      self.current = state("unavailable", "initialization_failed")
      return self:get_state()
    end
  end
  self.current = state("unavailable", "initialized")
  return self:get_state()
end

function Connector:connect()
  if not self.driver then
    self.current = state("not_configured", "not_configured")
    return false, "not_configured"
  end
  if type(self.driver.connect) ~= "function" then
    self.current = state("unavailable", "transport_unavailable")
    return false, "transport_unavailable"
  end
  local ok, connected = pcall(self.driver.connect, self.driver)
  if not ok or not connected then
    self.current = state("unavailable", "connect_failed")
    return false, "connect_failed"
  end
  return self:health().status == "healthy", self.current.detail
end

function Connector:health()
  if self.in_transaction then return state("unavailable", "transaction_active") end
  if not self.driver then
    self.current = state("not_configured", "not_configured")
    return self:get_state()
  end
  if type(self.driver.health) ~= "function" then
    self.current = state("unavailable", "transport_unavailable")
    return self:get_state()
  end
  local ok, result = pcall(self.driver.health, self.driver)
  if not ok or type(result) ~= "table" or result.status ~= "healthy" then
    self.current = state("unavailable", "health_failed")
    return self:get_state()
  end
  local major, minor, patch
  if type(result.api_version) == "string" then
    major, minor, patch = result.api_version:match("^(%d+)%.(%d+)%.(%d+)$")
  end
  if not major or tonumber(major) ~= 1 or not minor or not patch then
    self.current = state("incompatible_api", "api_version", { api_version = result.api_version })
    return self:get_state()
  end
  if type(result.capabilities) ~= "table" or result.capabilities.native_queries ~= true
    or result.capabilities.field_updates ~= true or result.capabilities.transactions ~= true then
    self.current = state("incompatible_api", "capabilities", { api_version = result.api_version })
    return self:get_state()
  end
  self.current = state("healthy", "ok", {
    api_version = result.api_version,
    capabilities = result.capabilities or {},
  })
  return self:get_state()
end

function Connector:check()
  return self:health()
end

-- A persistence operation owns an isolated connector/transport session. The
-- transaction state is connection-bound, so sharing this connector while a
-- request is suspended would let another request observe the wrong lifecycle.
function Connector:session()
  if not self.driver or type(self.driver.fork) ~= "function" then
    return nil, "capability_unavailable"
  end
  local ok, driver = pcall(self.driver.fork, self.driver)
  if not ok or not driver then return nil, "transport_unavailable" end
  local session = Connector.new({ driver = driver, expected_api_version = self.expected_api_version })
  local initialized = session:initialize()
  if initialized.detail == "initialization_failed" then
    session:close()
    return nil, "transport_unavailable"
  end
  return session
end

function Connector:_request(name, payload)
  if not self.in_transaction then
    local health = self:health()
    if health.status ~= "healthy" then return false, health.status end
  end
  if not self.driver or type(self.driver.operation) ~= "function" then return false, "capability_unavailable" end
  local ok, success, result = pcall(self.driver.operation, self.driver, name, payload)
  if not ok or not success then
    local reason = ok and result or "operation_failed"
    if self.in_transaction and self.driver.in_transaction ~= true then
      self.in_transaction = false
    end
    self.current = state("unavailable", reason or "operation_failed")
    return false, reason or "operation_failed"
  end
  return true, result
end

function Connector:create_collection(payload) return self:_request("create_collection", payload) end
function Connector:insert(payload) return self:_request("insert", payload) end
function Connector:get(payload) return self:_request("get", payload) end
function Connector:query(payload) return self:_request("query", payload) end
function Connector:update(payload) return self:_request("update", payload) end
function Connector:delete(payload) return self:_request("delete", payload) end
function Connector:upsert(payload) return self:_request("upsert", payload) end

function Connector:begin()
  if self.in_transaction then return false, "transaction_state" end
  local health = self:health()
  if health.status ~= "healthy" then return false, health.status end
  if not health.capabilities.transactions or not self.driver.begin then return false, "capability_unavailable" end
  local ok, success, result = pcall(self.driver.begin, self.driver)
  if not ok or not success then return false, ok and result or "operation_failed" end
  self.in_transaction = true
  return true, result
end

function Connector:_finish(name)
  if not self.in_transaction then return false, "transaction_state" end
  local ok, success, result = pcall(self.driver[name], self.driver)
  self.in_transaction = false
  if not ok or not success then
    local reason = ok and result or "operation_failed"
    self.current = state("unavailable", reason or "operation_failed")
    return false, reason or "operation_failed"
  end
  return true, result
end

function Connector:commit() return self:_finish("commit") end
function Connector:rollback() return self:_finish("rollback") end

function Connector:capabilities()
  local health = self:health()
  if health.status ~= "healthy" then
    return nil, health.detail
  end
  return copy(health.capabilities)
end

function Connector:read(payload)
  if self.driver and self.driver.operation then
    return self:_request(payload and payload.id and "get" or "query", payload)
  end
  return self:_operation("read", payload)
end

function Connector:write(payload)
  if self.driver and self.driver.operation then
    local operation = type(payload) == "table" and payload.operation
    if operation ~= "insert" and operation ~= "update" and operation ~= "delete" and operation ~= "upsert" then
      return false, "invalid_argument"
    end
    return self:_request(operation, payload.payload)
  end
  return self:_operation("write", payload)
end

function Connector:transaction(fn)
  if not self.driver or not self.driver.operation then return self:_operation("transaction", fn) end
  if type(fn) ~= "function" then return false, "invalid_argument" end
  local started, reason = self:begin()
  if not started then return false, reason end
  local ok, result, detail = pcall(fn, self)
  if not ok or not result then
    if self.in_transaction then
      local rolled_back = self:rollback()
      if not rolled_back then return false, "outcome_unknown" end
    end
    return false, ok and (detail or "transaction_aborted") or "transaction_aborted"
  end
  local committed = self:commit()
  if not committed then return false, "outcome_unknown" end
  return true, result
end

function Connector:close()
  if self.driver and type(self.driver.close) == "function" then
    pcall(self.driver.close, self.driver)
  end
  self.in_transaction = false
  self.current = state(self.driver and "unavailable" or "not_configured", "closed")
  return true
end

function Connector:_operation(name, ...)
  local health = self:health()
  if health.status ~= "healthy" then
    return false, health.status
  end
  if type(self.driver[name]) ~= "function" then
    return false, "capability_unavailable"
  end
  local ok, first, second = pcall(self.driver[name], self.driver, ...)
  if not ok then
    return false, "operation_failed"
  end
  if not first then
    return false, second or "operation_failed"
  end
  return first, second
end

return Connector
