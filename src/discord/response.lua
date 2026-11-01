local Response = {}
local Embeds = require("src.discord.embeds")

local function copy_options(options)
  local copied = {}
  for key, value in pairs(options or {}) do copied[key] = value end
  return copied
end

local function render_options(ctx, content, options)
  options = copy_options(options)
  if options.embeds or type(content) ~= "string" or content == "" then return content, options end
  local spec = ctx._molly_embed_spec
  ctx._molly_embed_spec = nil
  if spec then
    options.embeds = { Embeds.create(spec.kind or "info", spec.title or "Molly", spec.description or content, spec) }
  else
    options.embeds = Embeds.for_command(ctx._molly_category, ctx._molly_command_name, content)
  end
  return nil, options
end

-- Decorate the actual installed discord.lua interaction context so existing
-- command handlers keep their response and defer behavior. The library's
-- respond/edit APIs accept raw Discord embed payloads through opts.embeds.
function Response.decorate(ctx)
  if type(ctx) ~= "table" or ctx._molly_embed_wrapped then return ctx end
  ctx._molly_embed_wrapped = true
  for _, method in ipairs({ "respond", "edit", "update" }) do
    local response_method = method
    local original = ctx[method]
    if type(original) == "function" then
      ctx["_molly_original_" .. response_method] = original
      ctx[method] = function(self, content, options)
        local body, decorated = render_options(self, content, options)
        local result = original(self, body, decorated)
        if response_method == "respond" then self._molly_initial_response_sent = true end
        return result
      end
    end
  end
  return ctx
end

function Response.set_embed(ctx, spec)
  if type(ctx) ~= "table" or type(spec) ~= "table" then return false end
  ctx._molly_embed_spec = spec
  return true
end

-- A normal Discord interaction callback returns 204 with no body. The
-- installed discord.lua exposes only the body, so nil is a valid success after
-- a non-throwing call. Reject thrown failures and explicit error/status results.
local function callback_result(call_ok, result)
  if not call_ok then return false, "request_failed" end
  if result == nil then return true end
  if result == false then return false, "request_rejected" end
  if type(result) ~= "table" then return true end
  if result.ok == false or result.success == false or result.error ~= nil then
    return false, "request_rejected"
  end
  for _, field in ipairs({ "status", "status_code", "http_status" }) do
    if result[field] ~= nil then
      local status = tonumber(result[field])
      if not status or status < 200 or status > 299 then
        return false, status and ("http_" .. tostring(math.floor(status))) or "invalid_status"
      end
    end
  end
  if result.code ~= nil then
    local code = tonumber(result.code)
    if not code then return false, "invalid_status" end
    if code < 200 or code > 299 then
      if code >= 100 and code <= 599 then
        return false, "http_" .. tostring(math.floor(code))
      end
      -- Discord API error codes (for example 10062) are not HTTP status codes.
      return false, "request_rejected"
    end
  end
  return true
end

local function send_defer(ctx, options, require_application_id)
  if type(ctx) ~= "table" then return false, "invalid_context" end
  if ctx._molly_deferred then return true end
  if ctx._molly_initial_response_sent then return false, "already_responded" end
  local bot = ctx.bot
  if not bot or not bot.rest or type(bot.rest.create_interaction_response) ~= "function" then
    return false, "missing_rest_client"
  end
  if require_application_id and not bot.application_id then return false, "missing_application_id" end
  if not ctx.interaction_id then return false, "missing_interaction_id" end
  if not ctx.interaction_token then return false, "missing_interaction_token" end

  -- A public defer has no data object. Keeping it absent also avoids encoders
  -- serializing an empty Lua table as [] where Discord expects an object.
  local payload = { type = 5 }
  if options and options.ephemeral == true then payload.data = { flags = 64 } end
  local call_ok, result = pcall(bot.rest.create_interaction_response,
    bot.rest, ctx.interaction_id, ctx.interaction_token, payload)
  local accepted, detail = callback_result(call_ok, result)
  if not accepted then
    local logger = ctx._molly_logger
    if logger and type(logger.error) == "function" then
      pcall(logger.error, logger, "discord_interaction_ack_failed", {
        command = ctx._molly_command_name, reason = detail,
      })
    end
    return false, "request_failed"
  end
  ctx._molly_deferred = true
  return true
end

-- Some REST adapters return status objects; validate those when present.
-- The installed discord.lua returns only the response body (nil on HTTP 204).
-- Deferred responses are public by default, matching ordinary Discord
-- command responses. Pass { ephemeral = true } only for private workflows.
function Response.defer(ctx, options)
  return send_defer(ctx, options, true)
end

-- Acknowledge a public, deferred response for lightweight diagnostic commands.
-- The installed discord.lua API has no SlashCommandContext:defer method, but
-- its REST client exposes the same official interaction callback endpoint.
function Response.acknowledge(ctx)
  local acknowledged = send_defer(ctx, nil, false)
  return acknowledged == true
end

return Response
