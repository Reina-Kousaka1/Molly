local Store = require("src.persistence.guild_store")
local Hierarchy = {}

local function lower_id(a, b)
  if #a ~= #b then return #a < #b end
  return a < b
end

local function top(ids, roles, guild)
  if type(ids) ~= "table" then return nil end
  local best = roles[guild]
  if not best then return nil end
  for _, id in ipairs(ids) do
    local role = roles[id]
    if not role or type(role.position) ~= "number" or not Store.valid_id(id) then return nil end
    if role.position > best.position or (role.position == best.position and lower_id(id, best.id)) then best = role end
  end
  return best
end

local function higher(a, b)
  return a.position > b.position or (a.position == b.position and a.id ~= b.id and lower_id(a.id, b.id))
end

function Hierarchy.check(ctx, target)
  if not ctx.guild or not ctx.author or not ctx.bot or not ctx.bot.rest
    or not Store.valid_id(target) or target == ctx.author.id then return false end
  local bot_id = ctx.bot.user and ctx.bot.user.id
  if not Store.valid_id(bot_id) or target == bot_id then return false end
  local ok, result = pcall(function()
    local rest, guild_id = ctx.bot.rest, ctx.guild.id
    local guild, roles = rest:get_guild(guild_id), rest:get_roles(guild_id)
    if not guild or not Store.valid_id(guild.owner_id) or target == guild.owner_id or type(roles) ~= "table" then return false end
    local actor = rest:get_member(guild_id, ctx.author.id)
    local bot = rest:get_member(guild_id, bot_id)
    local member = rest:get_member(guild_id, target)
    if type(actor) ~= "table" or type(bot) ~= "table" or type(member) ~= "table" then return false end
    local map = {}
    for _, role in ipairs(roles) do
      if Store.valid_id(role.id) and type(role.position) == "number" then map[role.id] = role end
    end
    local target_top, actor_top, bot_top = top(member.roles, map, guild_id), top(actor.roles, map, guild_id), top(bot.roles, map, guild_id)
    if not target_top or not actor_top or not bot_top then return false end
    return (ctx.author.id == guild.owner_id or higher(actor_top, target_top)) and higher(bot_top, target_top)
  end)
  return ok and result == true
end

return Hierarchy
