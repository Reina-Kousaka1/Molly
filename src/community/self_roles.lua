local Store = require("src.persistence.guild_store")
local RolePolicy = require("src.discord.role_policy")

local SelfRoles = {}
SelfRoles.__index = SelfRoles

local function includes(list, value)
  for _, item in ipairs(list or {}) do
    if type(item) == "table" then item = item.id end
    if item == value then return true end
  end
  return false
end

function SelfRoles.new(settings, options)
  options = options or {}
  assert(type(settings) == "table" and type(settings.get_domain) == "function"
    and type(settings.update_domain) == "function", "guild settings are required")
  return setmetatable({ settings = settings, rest = options.rest, logger = options.logger }, SelfRoles)
end

function SelfRoles:set_runtime(rest)
  self.rest = rest
end

function SelfRoles:list(guild)
  return self.settings:get_domain(guild, "roles")
end

function SelfRoles:set_allowed(guild, actor, role_id, enabled, bot_id)
  if not Store.valid_id(guild) or not Store.valid_id(actor) or not Store.valid_id(role_id)
    or type(enabled) ~= "boolean" or not Store.valid_id(bot_id) then return false, "invalid_argument" end
  if enabled then
    local role, reason = RolePolicy.validate_assignable(self.rest, guild, role_id, actor, bot_id, true)
    if not role then return false, reason end
  end
  return self.settings:update_domain(guild, "roles", function(value)
    local roles = value.self_assignable
    local has = includes(roles, role_id)
    if enabled == has then return false end
    if enabled then
      if #roles >= 100 then return nil, "capacity" end
      roles[#roles + 1] = role_id
      table.sort(roles)
    else
      for i = #roles, 1, -1 do if roles[i] == role_id then table.remove(roles, i) end end
    end
    return true
  end)
end

function SelfRoles:assign(guild, user, role_id, add, bot_id)
  if not Store.valid_id(guild) or not Store.valid_id(user) or not Store.valid_id(role_id)
    or type(add) ~= "boolean" or not Store.valid_id(bot_id) then return false, "invalid_argument" end
  local ok, value = self.settings:get_domain(guild, "roles")
  if not ok then return false, value end
  local is_allowed = includes(value.self_assignable, role_id)
  local member_ok, member = pcall(self.rest.get_member, self.rest, guild, user)
  if not member_ok or type(member) ~= "table" or type(member.roles) ~= "table" then return false, "discord_unavailable" end
  local current = includes(member.roles, role_id)
  if current == add then return true, add and "already_has_role" or "already_removed" end
  if add and not is_allowed then return false, "role_not_available" end
  if not add and not current then return true, "already_removed" end
  local role, reason = RolePolicy.validate_assignable(self.rest, guild, role_id, nil, bot_id, false, not add)
  if not role then return false, reason end
  -- Re-read the allowlist immediately before mutation so a concurrent admin
  -- removal cannot leave a stale self-service grant window.
  local check_ok, fresh = self.settings:get_domain(guild, "roles")
  if not check_ok then return false, fresh end
  if add and not includes(fresh.self_assignable, role_id) then return false, "role_not_available" end
  local method = add and self.rest.add_role or self.rest.remove_role
  if type(method) ~= "function" then return false, "discord_unavailable" end
  local called, result = pcall(method, self.rest, guild, user, role_id, "Self-service role request")
  if not called or result == false then return false, "role_update_failed" end
  return true, add and "role_added" or "role_removed"
end

return SelfRoles
