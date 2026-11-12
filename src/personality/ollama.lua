-- Optional Ollama HTTP adapter for the Personality Engine V1 (integration phase).
--
-- Talks to a local Ollama server over its HTTP API (POST {url}/api/chat,
-- GET {url}/api/version). The transport is injected so tests can simulate the
-- server and Luvit can provide a bounded single-request implementation
-- (src/personality/luvit_transport.lua). The adapter performs no retries: a
-- timed-out local write must surface to the caller, never be replayed silently.
--
-- Transport contract:  transport(method, url, options) -> response | nil, err
--   options  = { timeout_ms = number, headers = table, body = string|nil,
--                max_response_bytes = number }
--   response = { code = number }
--   body is returned as a second return value on success.
--   err is a short string code: "timeout", "response_too_large",
--   "connection_failed", "invalid_response" or "request_failed".
--
-- Error model: methods return nil, err where err is a table
--   { code = string, status = number|nil, retryable = boolean }
-- Codes: serialization_unavailable, invalid_messages, request_failed, timeout,
--   response_too_large, provider_error (5xx), rate_limited (429),
--   model_not_found (404), http_error (other non-2xx), invalid_response,
--   empty_response.

local json_ok, json = pcall(require, "json")
if not json_ok then
  local client_ok, client = pcall(require, "src.preppydb.client")
  if client_ok and type(client) == "table" then
    json = { encode = client.encode, decode = client.decode }
  else
    json = nil
  end
end

local Ollama = {}
Ollama.__index = Ollama

Ollama.DEFAULT_URL = "http://127.0.0.1:11434"
Ollama.DEFAULT_TIMEOUT_MS = 15000
Ollama.DEFAULT_MAX_RESPONSE_BYTES = 256 * 1024
Ollama.MAX_RESPONSE_BYTES_LIMIT = 4 * 1024 * 1024
Ollama.MAX_MESSAGES = 16
Ollama.MAX_MESSAGE_CHARS = 4200
Ollama.MAX_TOTAL_CHARS = 16000
Ollama.MAX_MODEL_CHARS = 100

local function err(code, status, retryable)
  return { code = code, status = status, retryable = retryable == true }
end

local function is_origin_url(value)
  if type(value) ~= "string" then return false end
  -- http(s) origin only: no userinfo, path, query or fragment.
  return value:match("^https?://[^/%s@?#]+/?$") ~= nil
end

local function is_valid_model(value)
  return type(value) == "string" and #value >= 1 and #value <= Ollama.MAX_MODEL_CHARS
    and value:find("[%s%z\1-\31\127]") == nil
end

local function positive_integer(value, default, minimum, maximum)
  if value == nil then return default end
  local number = tonumber(value)
  if not number or number % 1 ~= 0 or number < minimum or number > maximum then
    return nil
  end
  return number
end

function Ollama.new(options)
  if type(options) ~= "table" then return nil, "options_required" end
  if type(options.transport) ~= "function" then return nil, "transport_required" end
  local url = options.url or Ollama.DEFAULT_URL
  if not is_origin_url(url) then return nil, "invalid_url" end
  url = url:gsub("/$", "")
  if not is_valid_model(options.model) then return nil, "invalid_model" end
  local timeout_ms = positive_integer(options.timeout_ms, Ollama.DEFAULT_TIMEOUT_MS, 100, 120000)
  if not timeout_ms then return nil, "invalid_timeout_ms" end
  local max_response_bytes = positive_integer(options.max_response_bytes,
    Ollama.DEFAULT_MAX_RESPONSE_BYTES, 1024, Ollama.MAX_RESPONSE_BYTES_LIMIT)
  if not max_response_bytes then return nil, "invalid_max_response_bytes" end
  local temperature = tonumber(options.temperature) or 0.6
  if temperature < 0 or temperature > 2 then return nil, "invalid_temperature" end
  local num_predict = positive_integer(options.num_predict, 256, 1, 1024)
  if not num_predict then return nil, "invalid_num_predict" end
  return setmetatable({
    url = url,
    model = options.model,
    timeout_ms = timeout_ms,
    max_response_bytes = max_response_bytes,
    temperature = temperature,
    num_predict = num_predict,
    transport = options.transport,
  }, Ollama)
end

local function validate_messages(messages)
  if type(messages) ~= "table" or #messages < 1 or #messages > Ollama.MAX_MESSAGES then
    return nil, err("invalid_messages")
  end
  local total = 0
  for _, message in ipairs(messages) do
    if type(message) ~= "table"
      or (message.role ~= "system" and message.role ~= "user" and message.role ~= "assistant")
      or type(message.content) ~= "string"
      or #message.content < 1 or #message.content > Ollama.MAX_MESSAGE_CHARS then
      return nil, err("invalid_messages")
    end
    total = total + #message.content
    if total > Ollama.MAX_TOTAL_CHARS then return nil, err("invalid_messages") end
  end
  return true
end

local function classify_transport_error(transport_err)
  if type(transport_err) == "string" then
    if transport_err == "timeout" then return err("timeout", nil, true) end
    if transport_err == "response_too_large" then return err("response_too_large", nil, false) end
    if transport_err == "connection_failed" then return err("request_failed", nil, true) end
  end
  return err("request_failed", nil, true)
end

local function classify_status(code)
  if code == 404 then return err("model_not_found", code, false) end
  if code == 429 then return err("rate_limited", code, true) end
  if code >= 500 then return err("provider_error", code, true) end
  return err("http_error", code, false)
end

function Ollama:generate(messages, _options)
  if not json then return nil, err("serialization_unavailable") end
  local ok, validation_error = validate_messages(messages)
  if not ok then return nil, validation_error end

  local encoded_ok, body = pcall(json.encode, {
    model = self.model,
    messages = messages,
    stream = false,
    options = { temperature = self.temperature, num_predict = self.num_predict },
  })
  if not encoded_ok or type(body) ~= "string" then return nil, err("serialization_unavailable") end

  local called, response, raw = pcall(self.transport, "POST", self.url .. "/api/chat", {
    timeout_ms = self.timeout_ms,
    headers = { ["Content-Type"] = "application/json", ["Accept"] = "application/json" },
    body = body,
    max_response_bytes = self.max_response_bytes,
  })
  if not called then return nil, err("request_failed", nil, true) end
  if type(response) ~= "table" then return nil, classify_transport_error(raw) end
  local code = tonumber(response.code)
  if not code then return nil, err("invalid_response") end
  if code < 200 or code > 299 then return nil, classify_status(code) end
  if type(raw) ~= "string" or raw == "" then return nil, err("invalid_response") end
  if #raw > self.max_response_bytes then return nil, err("response_too_large") end

  local decoded_ok, data = pcall(json.decode, raw)
  if not decoded_ok or type(data) ~= "table" then return nil, err("invalid_response") end
  local message = type(data.message) == "table" and data.message or nil
  local content = message and type(message.content) == "string" and message.content or nil
  if not content then return nil, err("invalid_response") end
  content = (content:gsub("^%s+", ""):gsub("%s+$", ""))
  if content == "" then return nil, err("empty_response") end

  return {
    content = content,
    model = type(data.model) == "string" and data.model or self.model,
    total_duration = tonumber(data.total_duration),
  }
end

-- Liveness probe for future operator tooling. Not wired to any command.
function Ollama:version()
  local called, response, raw = pcall(self.transport, "GET", self.url .. "/api/version", {
    timeout_ms = self.timeout_ms,
    headers = { ["Accept"] = "application/json" },
    max_response_bytes = 4096,
  })
  if not called or type(response) ~= "table" then
    return { status = "unavailable", detail = "request_failed" }
  end
  local code = tonumber(response.code)
  if not code or code < 200 or code > 299 then
    return { status = "unavailable", detail = "unexpected_status" }
  end
  if json and type(raw) == "string" then
    local decoded_ok, data = pcall(json.decode, raw)
    if decoded_ok and type(data) == "table" and type(data.version) == "string" then
      return { status = "connected", detail = data.version:sub(1, 60) }
    end
  end
  return { status = "connected", detail = "ok" }
end

return Ollama
