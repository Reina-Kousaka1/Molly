-- Explicit two-model router. It contains no Discord, database or command actions.
local Router = {}
Router.__index = Router

local function failure(code, retryable)
  return nil, { code = code, retryable = retryable == true }
end

local function clone_messages(messages)
  local copy = {}
  for index, message in ipairs(messages) do
    local entry = { role = message.role, content = message.content }
    if type(message.images) == "table" then
      entry.images = {}
      for image_index, image in ipairs(message.images) do entry.images[image_index] = image end
    end
    copy[index] = entry
  end
  return copy
end

local function last_user_message(messages)
  for index = #messages, 1, -1 do
    if messages[index].role == "user" then return messages[index], index end
  end
  return nil
end

-- Routing is intentionally explicit and inspectable. "deep:" opts into the
-- vision model for text; "think:" does so only when the feature setting is on.
local function parse_trigger(content, allow_thinking)
  local trimmed = content:gsub("^%s+", "")
  local lower = trimmed:lower()
  if lower:sub(1, 5) == "deep:" then
    local body = trimmed:sub(6):gsub("^%s+", "")
    if body == "" then return nil, nil, false, "invalid_request" end
    return body, "complex", false
  end
  if lower:sub(1, 6) == "think:" and allow_thinking then
    local body = trimmed:sub(7):gsub("^%s+", "")
    if body == "" then return nil, nil, false, "invalid_request" end
    return body, "thinking", true
  end
  return content, "text", false
end

local function valid_model_name(value)
  return type(value) == "string" and #value > 0 and #value <= 100
    and value:find("[%z\1-\31\127]") == nil
end

function Router.new(options)
  if type(options) ~= "table" or type(options.text_provider) ~= "table"
    or type(options.text_provider.generate) ~= "function"
    or type(options.vision_provider) ~= "table"
    or type(options.vision_provider.generate) ~= "function" then
    return nil, "providers_required"
  end
  local uv_ok, uv = pcall(require, "uv")
  if not uv_ok then uv = nil end
  return setmetatable({
    text_provider = options.text_provider,
    vision_provider = options.vision_provider,
    thinking_enabled = options.thinking_enabled == true,
    logger = options.logger,
    clock = options.clock or os.time,
    spawn = options.spawn or function(fn) coroutine.wrap(fn)() end,
    uv = uv,
    memory_sample_interval_ms = options.memory_sample_interval_ms or 750,
    thinking_cache_seconds = options.thinking_cache_seconds or 300,
    thinking_checked_at = nil,
    thinking_controls = nil,
    active = false,
    last_model = nil,
    model_switches = 0,
  }, Router)
end

function Router:ready()
  return type(self.text_provider) == "table" and type(self.text_provider.generate) == "function"
    and type(self.vision_provider) == "table" and type(self.vision_provider.generate) == "function"
end

function Router:_thinking_controls()
  local now = self.clock()
  if self.thinking_checked_at and now - self.thinking_checked_at < self.thinking_cache_seconds then
    return self.thinking_controls
  end
  self.thinking_checked_at = now
  self.thinking_controls = { supported = false }
  if type(self.vision_provider.thinking_control) ~= "function" then
    return self.thinking_controls
  end
  local ok, controls = pcall(self.vision_provider.thinking_control, self.vision_provider)
  if ok and type(controls) == "table" and controls.supported == true
    and (controls.value == true or (type(controls.value) == "string"
      and #controls.value > 0 and #controls.value <= 32
      and controls.value:match("^[%w_%-]+$"))) then
    self.thinking_controls = { supported = true, value = controls.value }
  end
  return self.thinking_controls
end

function Router:_start_memory_sampling(provider)
  if not self.uv or type(self.uv.new_timer) ~= "function"
    or type(provider.running_models) ~= "function" then return nil end
  local ok, timer = pcall(self.uv.new_timer)
  if not ok or not timer then return nil end
  local state = { stopped = false, pending = false, peak_vram_bytes = nil, samples = 0 }
  local started = pcall(timer.start, timer, self.memory_sample_interval_ms,
    self.memory_sample_interval_ms, function()
      if state.stopped or state.pending then return end
      state.pending = true
      local spawned = pcall(self.spawn, function()
        local called, models = pcall(provider.running_models, provider)
        if not state.stopped and called and type(models) == "table" then
          local total = 0
          for _, model in ipairs(models) do
            local bytes = type(model) == "table" and tonumber(model.size_vram) or nil
            if bytes and bytes >= 0 and bytes < 1024 * 1024 * 1024 * 1024 then total = total + bytes end
          end
          state.samples = state.samples + 1
          if state.peak_vram_bytes == nil or total > state.peak_vram_bytes then
            state.peak_vram_bytes = total
          end
        end
        state.pending = false
      end)
      if not spawned then state.pending = false end
    end)
  if not started then
    pcall(timer.close, timer)
    return nil
  end
  return function()
    state.stopped = true
    pcall(timer.stop, timer)
    pcall(timer.close, timer)
    return state.peak_vram_bytes, state.samples
  end
end

local function invoke(provider, messages, think_value)
  local options = {}
  if think_value ~= nil then options.think = think_value end
  local called, result, provider_error = pcall(provider.generate, provider, messages, options)
  if not called then return nil, { code = "request_failed", retryable = true } end
  if type(result) ~= "table" or type(result.content) ~= "string" then
    if type(provider_error) == "table" then return nil, provider_error end
    return nil, { code = "invalid_response", retryable = false }
  end
  return result
end

function Router:_invoke_measured(provider, messages, think_value)
  local started_ns
  if self.uv and type(self.uv.hrtime) == "function" then
    local ok, value = pcall(self.uv.hrtime)
    if ok then started_ns = value end
  end
  local stop_sampling = self:_start_memory_sampling(provider)
  local result, provider_error = invoke(provider, messages, think_value)
  local peak_vram_bytes, vram_samples
  if stop_sampling then peak_vram_bytes, vram_samples = stop_sampling() end
  local duration_ms
  if started_ns and self.uv and type(self.uv.hrtime) == "function" then
    local ok, ended_ns = pcall(self.uv.hrtime)
    if ok and type(ended_ns) == "number" and ended_ns >= started_ns then
      duration_ms = (ended_ns - started_ns) / 1000000
    end
  end
  return result, provider_error, peak_vram_bytes, vram_samples or 0, duration_ms
end

function Router:_record(route, result, fallback, vram_peak, vram_samples, duration_ms, cause)
  local model = valid_model_name(result.model) and result.model or nil
  local switched = model ~= nil and self.last_model ~= nil and model ~= self.last_model
  if switched then self.model_switches = self.model_switches + 1 end
  if model then self.last_model = model end
  if self.logger and type(self.logger.info) == "function" then
    pcall(self.logger.info, self.logger, "personality_model_metrics", {
      route = route,
      model = model,
      fallback = fallback == true,
      fallback_cause = type(cause) == "string" and cause or nil,
      switched = switched,
      model_switches = self.model_switches,
      request_duration_ms = duration_ms,
      total_duration_ns = tonumber(result.total_duration),
      load_duration_ns = tonumber(result.load_duration),
      vram_peak_bytes = vram_peak,
      vram_samples = vram_samples or 0,
    })
  end
end

function Router:_record_failure(route, provider_error, duration_ms)
  if self.logger and type(self.logger.info) == "function" then
    local code = type(provider_error) == "table" and provider_error.code or nil
    if type(code) ~= "string" or #code > 60 or not code:match("^[%w_%-]+$") then code = "provider_failed" end
    pcall(self.logger.info, self.logger, "personality_model_failure_metrics", {
      route = route, error = code, request_duration_ms = duration_ms,
    })
  end
end

function Router:_generate(messages)
  if type(messages) ~= "table" or #messages < 1 then return failure("invalid_messages") end
  local last, index = last_user_message(messages)
  if not last or type(last.content) ~= "string" then return failure("invalid_messages") end
  local image_count = type(last.images) == "table" and #last.images or 0
  if last.images ~= nil and (type(last.images) ~= "table" or image_count ~= 1
    or type(last.images[1]) ~= "string") then
    return failure("invalid_messages")
  end

  local content, explicit_route, wants_thinking, trigger_error =
    parse_trigger(last.content, self.thinking_enabled)
  if not content then return failure(trigger_error or "invalid_request") end
  local has_image = image_count == 1
  local route = has_image and "image" or explicit_route
  local primary = (has_image or explicit_route == "complex" or explicit_route == "thinking")
    and self.vision_provider or self.text_provider
  local routed_messages = clone_messages(messages)
  routed_messages[index].content = content

  local think_value
  if has_image or explicit_route == "complex" or explicit_route == "thinking" then
    local controls = self:_thinking_controls()
    if controls and controls.supported then
      if wants_thinking and self.thinking_enabled then
        think_value = controls.value
      else
        -- The model's default may enable hidden reasoning. When the installed
        -- API confirms the control exists, keep it off unless explicitly asked.
        think_value = false
      end
    end
  end

  local result, provider_error, peak, samples, duration_ms =
    self:_invoke_measured(primary, routed_messages, think_value)
  if result then
    self:_record(route, result, false, peak, samples, duration_ms)
    return result
  end

  -- Model-missing fallback is safe only for text-only requests. Never route
  -- image bytes to the text model, and never transparently retry timeouts.
  if not has_image and type(provider_error) == "table" and provider_error.code == "model_not_found" then
    local fallback = primary == self.text_provider and self.vision_provider or self.text_provider
    local fallback_think
    if fallback == self.vision_provider then
      local controls = self:_thinking_controls()
      if controls and controls.supported then fallback_think = false end
    end
    local fallback_result, fallback_error, fallback_peak, fallback_samples, fallback_duration =
      self:_invoke_measured(fallback, routed_messages, fallback_think)
    if fallback_result then
      self:_record(route .. "_fallback", fallback_result, true, fallback_peak,
        fallback_samples, fallback_duration, "model_not_found")
      return fallback_result
    end
    provider_error = fallback_error
    duration_ms = (duration_ms or 0) + (fallback_duration or 0)
  end

  self:_record_failure(route, provider_error, duration_ms)
  return nil, provider_error
end

-- Exactly one model generation may be active, even if a caller bypasses the
-- Discord bridge. No generation failure triggers an implicit request retry.
function Router:generate(messages)
  if not self:ready() then return failure("provider_unavailable") end
  if self.active then return failure("busy", true) end
  self.active = true
  local called, result, provider_error = pcall(self._generate, self, messages)
  self.active = false
  if not called then return failure("provider_failed", true) end
  return result, provider_error
end

return Router
