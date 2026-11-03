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

return RolePolicy
