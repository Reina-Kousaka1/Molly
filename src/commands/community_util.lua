local Store = require("src.persistence.guild_store")
local Permissions = require("src.discord.permissions")

local Util = {}

function Util.arg(ctx, name)
  if ctx.args and ctx.args[name] ~= nil then return ctx.args[name] end
  if type(ctx.get_arg) == "function" then return ctx:get_arg(name) end
end

function Util.id(value)
  if type(value) == "table" then return value.id end
  return value
end

function Util.option(name, description, option_type, required, maximum)
  local item = { type = option_type or 3, name = name, description = description, required = required == true }
  if maximum then item.max_length = maximum end
  if item.type == 3 then item.min_length = 1 end
  return item
end

function Util.reply(ctx, text)
  if ctx._molly_deferred then return ctx:edit(text) end
  return ctx:respond(text, { ephemeral = ctx._molly_public_reply ~= true })
end

-- Existing sensitive commands remain private unless they explicitly opt in.
-- Discord locks visibility at the initial acknowledgement, so the public
-- choice must be made before the deferred response is sent.
function Util.defer(ctx, options)
  local Response = require("src.discord.response")
  local public = options and options.public == true
  local ok = Response.defer(ctx, { ephemeral = not public })
  if ok then ctx._molly_public_reply = public end
  return ok
end

function Util.is_manager(ctx)
  return Permissions.has(ctx.member and ctx.member.permissions, "manage_guild")
end

function Util.validate_text_channel(rest, guild, channel_id)
  if not Store.valid_id(guild) or not Store.valid_id(channel_id) or not rest
    or type(rest.get_channel) ~= "function" then return false, "invalid_channel" end
  local ok, channel = pcall(rest.get_channel, rest, channel_id)
  if not ok or type(channel) ~= "table" then return false, "channel_unavailable" end
  if channel.guild_id ~= guild then return false, "wrong_guild" end
  if channel.type ~= 0 and channel.type ~= 5 then return false, "not_text_channel" end
  return true, channel
end

function Util.safe(value, maximum)
  return tostring(value or ""):gsub("@", "@\226\128\139"):gsub("[\r\n]", " ")
    :gsub("[%z\1-\8\11\12\14-\31\127]", " "):sub(1, maximum or 180)
end

return Util
