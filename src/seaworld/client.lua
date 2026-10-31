local Client = {}
Client.__index = Client

local function copy_state(state)
  return {
    status = state.status,
    detail = state.detail,
    checked = state.checked,
  }
end

local function health_status(body)
  if type(body) ~= "string" then
    return nil
  end

  -- The Phase-0 protocol is deliberately small: {"status":"ok"}.
  -- This is not a general JSON parser and must not be used for data access.
  return body:match('"status"%s*:%s*"([%w_%-]+)"')
end

function Client.new(options)
  assert(type(options) == "table", "options are required")
  assert(type(options.transport) == "function", "transport is required")

  local self = setmetatable({
    url = options.health_url,
    timeout_ms = options.timeout_ms or 1000,
    retry_attempts = options.retry_attempts or 1,
    transport = options.transport,
    clock = options.clock or os.time,
    state = {
      status = options.health_url and "unavailable" or "unavailable",
      detail = options.health_url and "not_checked" or "not_configured",
      checked = false,
    },
  }, Client)
  return self
end

function Client:get_state()
  return copy_state(self.state)
end

function Client:_set(status, detail)
  self.state = {
    status = status,
    detail = detail,
    checked = true,
    checked_at = self.clock(),
  }
  return self:get_state()
end

function Client:check()
  if not self.url then
    return self:_set("unavailable", "not_configured")
  end

  local detail = "request_failed"
  for _ = 1, self.retry_attempts do
    local ok, response, body = pcall(self.transport, "GET", self.url, {
      timeout_ms = self.timeout_ms,
      headers = { ["accept"] = "application/json" },
    })

    if not ok then
      detail = "request_failed"
    elseif not response then
      detail = body == "timeout" and "timeout" or "request_failed"
    elseif not tonumber(response.code) or tonumber(response.code) < 200 or tonumber(response.code) > 299 then
      detail = "unexpected_status"
    elseif health_status(body) ~= "ok" then
      detail = "invalid_response"
    else
      return self:_set("connected", "ok")
    end
  end

  return self:_set("unavailable", detail)
end

return Client
