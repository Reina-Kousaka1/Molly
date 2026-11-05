local Store = require("src.persistence.guild_store")

local UserSettings = {}
UserSettings.__index = UserSettings
UserSettings.MAX_USERS = 1000

local DEFAULTS = { compact_replies = false, mature_opt_in = false }

local function valid_profile(value)
  return type(value) == "table" and type(value.compact_replies) == "boolean"
    and type(value.mature_opt_in) == "boolean"
end

local function validate(data)
  if type(data.profiles) ~= "table" then return false end
  local count = 0
  for user, profile in pairs(data.profiles) do
    if not Store.valid_id(user) or not valid_profile(profile) then return false end
    count = count + 1
  end
  return count <= UserSettings.MAX_USERS
end

local function copy(value)
  return { compact_replies = value.compact_replies, mature_opt_in = value.mature_opt_in }
end

function UserSettings.new(store)
  assert(type(store) == "table" and type(store.run) == "function", "global store is required")
  return setmetatable({ store = store }, UserSettings)
end

function UserSettings:get(user)
  if not Store.valid_id(user) then return false, "invalid_user" end
  return self.store:run("user-settings", { profiles = {} }, function(data)
    if not validate(data) then return false, "invalid_store" end
    local value = data.profiles[user]
    return true, copy(value or DEFAULTS), false
  end)
end

function UserSettings:_set(user, field, value)
  if not Store.valid_id(user) or DEFAULTS[field] == nil or type(value) ~= "boolean" then
    return false, "invalid_argument"
  end
  return self.store:run("user-settings", { profiles = {} }, function(data)
    if not validate(data) then return false, "invalid_store" end
    local current = data.profiles[user]
    if not current then
      if value == DEFAULTS[field] then return true, copy(DEFAULTS), false end
      local count = 0; for _ in pairs(data.profiles) do count = count + 1 end
      if count >= UserSettings.MAX_USERS then return false, "capacity" end
      current = copy(DEFAULTS)
    end
    if current[field] == value then return true, copy(current), false end
    current[field] = value
    if current.compact_replies == DEFAULTS.compact_replies and current.mature_opt_in == DEFAULTS.mature_opt_in then
      data.profiles[user] = nil
      return true, copy(DEFAULTS), true
    end
    data.profiles[user] = current
    return true, copy(current), true
  end)
end

function UserSettings:set_compact(user, enabled)
  return self:_set(user, "compact_replies", enabled)
end

function UserSettings:set_mature_opt_in(user, enabled)
  return self:_set(user, "mature_opt_in", enabled)
end

function UserSettings:reset(user)
  if not Store.valid_id(user) then return false, "invalid_user" end
  return self.store:run("user-settings", { profiles = {} }, function(data)
    if not validate(data) then return false, "invalid_store" end
    if data.profiles[user] == nil then return true, copy(DEFAULTS), false end
    data.profiles[user] = nil
    return true, copy(DEFAULTS), true
  end)
end

UserSettings.defaults = copy(DEFAULTS)
return UserSettings
