-- Bounded Ollama API adapter used by the opt-in Personality Engine.
-- Text/image payloads are in-memory only; the adapter has no persistence or tools.
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
Ollama.MAX_IMAGE_BYTES = 4 * 1024 * 1024
Ollama.MAX_MESSAGES = 16
Ollama.MAX_MESSAGE_CHARS = 4200
Ollama.MAX_TOTAL_CHARS = 16000
Ollama.MAX_MODEL_CHARS = 100
Ollama.MAX_REQUEST_BYTES = 6 * 1024 * 1024

local function err(code, status, retryable)
  return { code = code, status = status, retryable = retryable == true }
end

local function is_origin_url(value)
  return type(value) == "string" and value:match("^https?://[^/%s@?#]+/?$") ~= nil
end

local function is_valid_model(value)
  return type(value) == "string" and #value >= 1 and #value <= Ollama.MAX_MODEL_CHARS
    and value:find("[%s%z\1-\31\127]") == nil
end

local function positive_integer(value, default, minimum, maximum)
  if value == nil then return default end
  local number = tonumber(value)
  if not number or number % 1 ~= 0 or number < minimum or number > maximum then return nil end
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

local function valid_base64(value)
  if type(value) ~= "string" or #value < 4 or #value > 4 * math.ceil(Ollama.MAX_IMAGE_BYTES / 3)
    or #value % 4 ~= 0 or value:find("[^%w%+/=]") then return false end
  if value:find("=", 1, true) and not value:match("^[%w%+/]+=?=?$") then return false end
  if value:match("=%w") or value:match("=%+") or value:match("=/") then return false end
  return true
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
    if message.images ~= nil then
      if message.role ~= "user" or type(message.images) ~= "table" or #message.images ~= 1 then
        return nil, err("invalid_messages")
      end
      if not valid_base64(message.images[1]) then return nil, err("invalid_messages") end
    end
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

local function decode_response(self, response, raw, max_bytes)
  if type(response) ~= "table" then return nil, classify_transport_error(raw) end
  local code = tonumber(response.code)
  if not code then return nil, err("invalid_response") end
  if code < 200 or code > 299 then return nil, classify_status(code) end
  if type(raw) ~= "string" or raw == "" then return nil, err("invalid_response") end
  if #raw > max_bytes then return nil, err("response_too_large") end
  if not json then return nil, err("serialization_unavailable") end
  local decoded_ok, data = pcall(json.decode, raw)
  if not decoded_ok or type(data) ~= "table" then return nil, err("invalid_response") end
  return data
end

local function api_request(self, method, path, payload, max_bytes, timeout_ms)
  if not json then return nil, err("serialization_unavailable") end
  local body
  if payload then
    local encoded_ok
    encoded_ok, body = pcall(json.encode, payload)
    if not encoded_ok or type(body) ~= "string" then return nil, err("serialization_unavailable") end
    if #body > Ollama.MAX_REQUEST_BYTES then return nil, err("request_too_large") end
  end
  local called, response, raw = pcall(self.transport, method, self.url .. path, {
    timeout_ms = timeout_ms or self.timeout_ms,
    headers = {
      ["Content-Type"] = "application/json",
      ["Accept"] = "application/json",
      ["Accept-Encoding"] = "identity",
    },
    body = body,
    max_response_bytes = max_bytes,
  })
  if not called then return nil, err("request_failed", nil, true) end
  return decode_response(self, response, raw, max_bytes)
end

local function strip_thinking_markup(content)
  local lower, out, cursor = content:lower(), {}, 1
  while true do
    local start_at = lower:find("<think>", cursor, true)
    local stray_end = lower:find("</think>", cursor, true)
    if not start_at then
      if stray_end then
        out[#out + 1] = content:sub(cursor, stray_end - 1)
        cursor = stray_end + 8
        lower = content:lower()
      else
        out[#out + 1] = content:sub(cursor)
        break
      end
    elseif stray_end and stray_end < start_at then
      out[#out + 1] = content:sub(cursor, stray_end - 1)
      cursor = stray_end + 8
    else
      out[#out + 1] = content:sub(cursor, start_at - 1)
      local end_at = lower:find("</think>", start_at + 7, true)
      if not end_at then break end
      cursor = end_at + 8
    end
  end
  return table.concat(out)
end

function Ollama:generate(messages, options)
  options = type(options) == "table" and options or {}
  local ok, validation_error = validate_messages(messages)
  if not ok then return nil, validation_error end
  local think = options.think
  if think ~= nil and think ~= true and think ~= false
    and (type(think) ~= "string" or #think > 32 or not think:match("^[%w_%-]+$")) then
    return nil, err("invalid_options")
  end
  if think ~= nil then
    local supported = self.thinking_controls
    if type(supported) ~= "table" or supported.supported ~= true then
      return nil, err("thinking_unsupported")
    end
    if type(think) == "string" and supported.values[think] ~= true then
      return nil, err("thinking_unsupported")
    end
  end

  local payload = {
    model = self.model,
    messages = messages,
    stream = false,
    keep_alive = "0",
    options = { temperature = self.temperature, num_predict = self.num_predict },
  }
  if think ~= nil then payload.think = think end
  local data, request_error = api_request(self, "POST", "/api/chat", payload, self.max_response_bytes)
  if not data then return nil, request_error end

  local message = type(data.message) == "table" and data.message or nil
  local content = message and type(message.content) == "string" and message.content or nil
  if not content then return nil, err("invalid_response") end
  content = strip_thinking_markup(content)
  content = content:gsub("^%s+", ""):gsub("%s+$", "")
  if content == "" then return nil, err("empty_response") end

  return {
    content = content,
    model = type(data.model) == "string" and data.model or self.model,
    total_duration = tonumber(data.total_duration),
    load_duration = tonumber(data.load_duration),
    prompt_eval_duration = tonumber(data.prompt_eval_duration),
    eval_duration = tonumber(data.eval_duration),
    prompt_eval_count = tonumber(data.prompt_eval_count),
    eval_count = tonumber(data.eval_count),
  }
end

-- Discover model-specific thinking values. Unknown/older API shapes fail closed.
function Ollama:thinking_control()
  local data, request_error = api_request(self, "POST", "/api/show",
    { model = self.model, verbose = false }, 64 * 1024, math.min(self.timeout_ms, 2000))
  if not data then return nil, request_error end
  local thinking = data.thinking
  if type(thinking) ~= "table" or type(thinking.values) ~= "table" then
    self.thinking_controls = { supported = false, values = {} }
    return { supported = false }
  end
  local values = {}
  for _, value in ipairs(thinking.values) do
    if value == true then values.true_value = true
    elseif type(value) == "string" and #value > 0 and #value <= 32 and value:match("^[%w_%-]+$") then
      values[value] = true
      values.first = values.first or value
    end
  end
  local selected
  if values.true_value then selected = true
  elseif type(thinking.default) == "string" and values[thinking.default] then selected = thinking.default
  else selected = values.first end
  local controls = { supported = selected ~= nil, values = values, value = selected }
  self.thinking_controls = controls
  return controls
end

-- Ollama reports size_vram for currently running models via /api/ps.
function Ollama:running_models()
  local data, request_error = api_request(self, "GET", "/api/ps", nil, 64 * 1024, math.min(self.timeout_ms, 1500))
  if not data then return nil, request_error end
  if type(data.models) ~= "table" then return nil, err("invalid_response") end
  local models = {}
  for _, model in ipairs(data.models) do
    if type(model) == "table" then
      models[#models + 1] = {
        name = type(model.name) == "string" and model.name:sub(1, Ollama.MAX_MODEL_CHARS) or nil,
        size_vram = tonumber(model.size_vram),
        size = tonumber(model.size),
      }
    end
  end
  return models
end

-- Liveness probe; no command or Discord route exposes it.
function Ollama:version()
  local data, request_error = api_request(self, "GET", "/api/version", nil, 4096, self.timeout_ms)
  if not data then
    return { status = "unavailable", detail = request_error and request_error.code or "request_failed" }
  end
  if type(data.version) == "string" then
    return { status = "connected", detail = data.version:sub(1, 60) }
  end
  return { status = "connected", detail = "ok" }
end

return Ollama
