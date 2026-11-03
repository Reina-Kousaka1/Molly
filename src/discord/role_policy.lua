local Store = require("src.persistence.guild_store")
local Permissions = require("src.discord.permissions")

local RolePolicy = {}

-- discord.lua message-create models do not expose effective member permissions.
-- Prefix commands that declare a Discord permission therefore resolve it from
-- the current guild roles/member rather than treating an absent field as allow.
function RolePolicy.member_has_permission(rest, guild_id, user_id, permission)
  if not rest or not Store.valid_id(guild_id) or not Store.valid_id(user_id) then return nil, "unavailable" end
  local ok, guild = pcall(rest.get_guild, rest, guild_id)
  if not ok or type(guild) ~= "table" or not Store.valid_id(guild.owner_id) then return nil, "unavailable" end
  if guild.owner_id == user_id then return true end
  local roles_ok, roles = pcall(rest.get_roles, rest, guild_id)
  local member_ok, member = pcall(rest.get_member, rest, guild_id, user_id)
  if not roles_ok or type(roles) ~= "table" or not member_ok or type(member) ~= "table" then return nil, "unavailable" end
  local wanted = {}
  for _, id in ipairs(member.roles or {}) do
    if type(id) == "table" then id = id.id end
    if Store.valid_id(id) then wanted[id] = true end
  end
  wanted[guild_id] = true
  for _, role in ipairs(roles) do
    if type(role) == "table" and wanted[role.id] and Permissions.has(role.permissions, permission) then return true end
  end
  return false
end

function RolePolicy.highest_role(member, roles, guild_id)
  if type(member) ~= "table" or type(roles) ~= "table" then return nil end
  local map = {}
  for _, role in ipairs(roles) do
    if type(role) == "table" and Store.valid_id(role.id) and type(role.position) == "number" then map[role.id] = role end
  end
  local best = map[guild_id]
  if not best then return nil end
  for _, value in ipairs(member.roles or {}) do
    local id = type(value) == "table" and value.id or value
    local role = map[id]
    if not role then return nil end
    if role.position > best.position or (role.position == best.position and #role.id < #best.id)
      or (role.position == best.position and #role.id == #best.id and role.id < best.id) then best = role end
  end
  return best
end

function RolePolicy.compare(a, b)
  if not a or not b then return nil end
  if a.position ~= b.position then return a.position > b.position end
  if a.id == b.id then return false end
  if #a.id ~= #b.id then return #a.id < #b.id end
  return a.id < b.id
end

local DANGEROUS_PERMISSIONS = {
  "administrator", "manage_guild", "manage_roles", "manage_channels", "manage_webhooks",
  "manage_nicknames", "manage_emojis_and_stickers", "manage_events", "view_audit_log",
  "kick_members", "ban_members", "moderate_members", "manage_messages", "mention_everyone",
  "mute_members", "deafen_members", "move_members",
}

function RolePolicy.validate_assignable(rest, guild_id, role_id, actor_id, bot_id, require_actor_hierarchy, allow_dangerous)
  if not rest or not Store.valid_id(guild_id) or not Store.valid_id(role_id) or not Store.valid_id(bot_id) then
    return nil, "invalid_argument"
  end
  local guild_ok, guild = pcall(rest.get_guild, rest, guild_id)
  local roles_ok, roles = pcall(rest.get_roles, rest, guild_id)
  local bot_ok, bot_member = pcall(rest.get_member, rest, guild_id, bot_id)
  if not guild_ok or type(guild) ~= "table" or not roles_ok or type(roles) ~= "table"
    or not bot_ok or type(bot_member) ~= "table" then return nil, "discord_unavailable" end
  local role
  for _, item in ipairs(roles) do if type(item) == "table" and item.id == role_id then role = item; break end end
  if not role then return nil, "unknown_role" end
  if role_id == guild_id then return nil, "everyone_role" end
  if role.managed == true then return nil, "managed_role" end
  if not allow_dangerous then
    for _, permission in ipairs(DANGEROUS_PERMISSIONS) do
      if Permissions.has(role.permissions, permission) then return nil, "dangerous_role" end
    end
  end
  local bot_top = RolePolicy.highest_role(bot_member, roles, guild_id)
  if not bot_top or not RolePolicy.compare(bot_top, role) then return nil, "bot_hierarchy" end
  local bot_roles = { [guild_id] = true }
  for _, id in ipairs(bot_member.roles or {}) do
    if type(id) == "table" then id = id.id end
    if Store.valid_id(id) then bot_roles[id] = true end
  end
  local can_manage = false
  for _, item in ipairs(roles) do
    if type(item) == "table" and bot_roles[item.id] and Permissions.has(item.permissions, "manage_roles") then
      can_manage = true; break
    end
  end
  if not can_manage then return nil, "bot_missing_manage_roles" end

  if require_actor_hierarchy and actor_id ~= guild.owner_id then
    if not Store.valid_id(actor_id) then return nil, "invalid_actor" end
    local actor_ok, actor = pcall(rest.get_member, rest, guild_id, actor_id)
    if not actor_ok or type(actor) ~= "table" then return nil, "discord_unavailable" end
    local actor_top = RolePolicy.highest_role(actor, roles, guild_id)
    if not actor_top or not RolePolicy.compare(actor_top, role) then return nil, "actor_hierarchy" end
  end
  return role
end

return RolePolicy
