local Store = require("src.persistence.guild_store")
local Permissions = require("src.discord.permissions")
local RolePolicy = require("src.discord.role_policy")

local Purge = {}
Purge.__index = Purge
local MAX_SLASH = 100
local MAX_PREFIX = 99
local MAX_AGE = 14 * 24 * 60 * 60

local function recent(timestamp, cutoff)
  if type(timestamp) ~= "string" or #timestamp < 19 then return false end
  return timestamp:sub(1, 19) >= cutoff
end

function Purge.new(options)
  options = options or {}
  return setmetatable({ clock = options.clock or os.time }, Purge)
end

local function bot_can(ctx, permission)
  if ctx.app_permissions ~= nil then return Permissions.has(ctx.app_permissions, permission) end
  local bot = ctx.bot
  local bot_id = bot and bot.user and bot.user.id
  if not bot or not bot.rest or not Store.valid_id(bot_id) then return false end
  local allowed = RolePolicy.member_has_permission(bot.rest, ctx.guild.id, bot_id, permission)
  return allowed == true
end

function Purge:run(ctx, requested)
  if type(requested) == "string" then requested = tonumber(requested) end
  local maximum = ctx and ctx.source == "message" and MAX_PREFIX or MAX_SLASH
  if type(requested) ~= "number" or requested % 1 ~= 0 or requested < 1 or requested > maximum then
    return false, "invalid_count"
  end
  local guild = ctx and ctx.guild and ctx.guild.id
  local channel = (ctx and ctx.channel and ctx.channel.id) or (ctx and ctx.channel_id)
  local rest = ctx and ctx.bot and ctx.bot.rest
  if not Store.valid_id(guild) or not Store.valid_id(channel) or not rest
    or type(rest.get_channel) ~= "function" or type(rest.get_channel_messages) ~= "function" then
    return false, "discord_unavailable"
  end
  local channel_ok, channel_data = pcall(rest.get_channel, rest, channel)
  if not channel_ok or type(channel_data) ~= "table" or channel_data.guild_id ~= guild
    or (channel_data.type ~= 0 and channel_data.type ~= 5) then return false, "invalid_channel" end
  if not bot_can(ctx, "manage_messages") then return false, "bot_permission_denied" end

  local limit = math.min(100, requested + (ctx.source == "message" and 1 or 0))
  local fetched, messages = pcall(rest.get_channel_messages, rest, channel, { limit = limit })
  if not fetched or type(messages) ~= "table" then return false, "fetch_failed" end
  local cutoff = os.date("!%Y-%m-%dT%H:%M:%S", self.clock() - MAX_AGE)
  local ids = {}
  for _, message in ipairs(messages) do
    if type(message) == "table" and Store.valid_id(message.id)
      and not (ctx.source == "message" and ctx.message and message.id == ctx.message.id)
      and recent(message.timestamp, cutoff) then
      ids[#ids + 1] = message.id
      if #ids >= requested then break end
    end
  end
  if #ids == 0 then return true, 0 end
  local called, result
  if #ids == 1 then
    if type(rest.delete_message) ~= "function" then return false, "delete_unavailable" end
    called, result = pcall(rest.delete_message, rest, channel, ids[1], "Moderation purge")
  else
    if type(rest.bulk_delete_messages) ~= "function" then return false, "delete_unavailable" end
    called, result = pcall(rest.bulk_delete_messages, rest, channel, ids, "Moderation purge")
  end
  if not called or result == false then return false, "delete_failed" end
  return true, #ids
end

Purge.max_slash = MAX_SLASH
Purge.max_prefix = MAX_PREFIX
return Purge
