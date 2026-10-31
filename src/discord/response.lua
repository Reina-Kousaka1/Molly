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

-- discord.lua returns only the body, not the HTTP status. Verify the deferred
-- original exists before starting any persistent or moderation work.
-- Deferred responses are public by default, matching ordinary Discord
-- command responses. Pass { ephemeral = true } only for private workflows.
function Response.defer(ctx, options)
  if type(ctx) ~= "table" then return false end
  if ctx._molly_deferred then return true end
  if ctx._molly_initial_response_sent then return false end
  local bot = ctx.bot
  if not bot or not bot.rest or not bot.application_id or not ctx.interaction_id or not ctx.interaction_token then return false end
  local data = {}
  if options and options.ephemeral == true then data.flags = 64 end
  local sent = pcall(bot.rest.create_interaction_response, bot.rest, ctx.interaction_id, ctx.interaction_token,
    { type = 5, data = data })
  if not sent then return false end
  -- A successful callback request is Discord's acknowledgement. Fetching the
  -- original response here adds a second network dependency after the ack and
  -- can cause callers to return without ever editing the deferred response.
  ctx._molly_deferred = true
  return true
end

-- Acknowledge a public, deferred response for lightweight diagnostic commands.
-- The installed discord.lua API has no SlashCommandContext:defer method, but
-- its REST client exposes the same official interaction callback endpoint.
function Response.acknowledge(ctx)
  if type(ctx) ~= "table" then return false end
  if ctx._molly_deferred then return true end
  if ctx._molly_initial_response_sent then return false end
  local bot = ctx.bot
  if not bot or not bot.rest or not ctx.interaction_id or not ctx.interaction_token then return false end
  local sent = pcall(bot.rest.create_interaction_response, bot.rest, ctx.interaction_id, ctx.interaction_token, { type = 5 })
  if not sent then return false end
  ctx._molly_deferred = true
  return true
end

return Response
