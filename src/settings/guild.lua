local Store = require("src.persistence.guild_store")

local Settings = {}
Settings.__index = Settings

Settings.defaults = { prefix = ".", currency_name = "coins", currency_symbol = "" }

local function valid_prefix(value)
  if type(value) ~= "string" or #value < 1 or #value > 8 then return false end
  for index = 1, #value do
    local byte = value:byte(index)
    if byte < 33 or byte > 126 then return false end
  end
  return true
end

local function valid_currency_name(value)
  if type(value) ~= "string" or #value < 1 or #value > 32 or not value:match("%S") then return false end
  for index = 1, #value do
    local byte = value:byte(index)
    if byte < 32 or byte == 127 then return false end
  end
  return true
end

local function valid_currency_symbol(value)
  if type(value) ~= "string" or #value < 1 or #value > 16 or not value:match("%S") then return false end
  for index = 1, #value do
    local byte = value:byte(index)
    if byte < 33 or byte == 127 then return false end
  end
  return true
end

local function normalized(data)
  if data.settings == nil then
    return { prefix = Settings.defaults.prefix, currency_name = Settings.defaults.currency_name,
      currency_symbol = Settings.defaults.currency_symbol }
  end
  if type(data.settings) ~= "table" then return nil end
  local saved = data.settings
  local result = {}
  for key, value in pairs(saved) do result[key] = value end
  result.prefix = saved.prefix == nil and Settings.defaults.prefix or saved.prefix
  result.currency_name = saved.currency_name == nil and Settings.defaults.currency_name or saved.currency_name
  result.currency_symbol = saved.currency_symbol == nil and Settings.defaults.currency_symbol or saved.currency_symbol
  if not valid_prefix(result.prefix) or not valid_currency_name(result.currency_name)
    or (result.currency_symbol ~= "" and not valid_currency_symbol(result.currency_symbol)) then return nil end
  return result
end

local function copy(value)
  local result = {}
  for key, child in pairs(value) do result[key] = child end
  return result
end

function Settings.new(store)
  assert(type(store) == "table" and type(store.run) == "function", "guild store is required")
  return setmetatable({ store = store }, Settings)
end

function Settings:get(guild)
  if not Store.valid_id(guild) then return false, "invalid_guild" end
  return self.store:run(guild, function(data)
    local value = normalized(data)
    if not value then return false, "invalid_store" end
    return true, value, false
  end)
end

function Settings:_update(guild, mutate)
  if not Store.valid_id(guild) then return false, "invalid_guild" end
  return self.store:run(guild, function(data)
    local value = normalized(data)
    if not value then return false, "invalid_store" end
    local changed, reason = mutate(value)
    if changed == nil then return false, reason end
    if not changed then return true, copy(value), false end
    data.settings = copy(value)
    return true, copy(value), true
  end)
end

function Settings:set_prefix(guild, value)
  if not valid_prefix(value) then return false, "invalid_prefix" end
  return self:_update(guild, function(current)
    if current.prefix == value then return false end
    current.prefix = value
    return true
  end)
end

function Settings:reset_prefix(guild)
  return self:set_prefix(guild, Settings.defaults.prefix)
end

function Settings:set_currency_name(guild, value)
  if not valid_currency_name(value) then return false, "invalid_currency_name" end
  return self:_update(guild, function(current)
    if current.currency_name == value then return false end
    current.currency_name = value
    return true
  end)
end

function Settings:set_currency_symbol(guild, value)
  if not valid_currency_symbol(value) then return false, "invalid_currency_symbol" end
  return self:_update(guild, function(current)
    if current.currency_symbol == value then return false end
    current.currency_symbol = value
    return true
  end)
end

function Settings:reset_economy(guild)
  return self:_update(guild, function(current)
    if current.currency_name == Settings.defaults.currency_name
      and current.currency_symbol == Settings.defaults.currency_symbol then return false end
    current.currency_name, current.currency_symbol = Settings.defaults.currency_name, Settings.defaults.currency_symbol
    return true
  end)
end

Settings.valid_prefix = valid_prefix
Settings.valid_currency_name = valid_currency_name
Settings.valid_currency_symbol = valid_currency_symbol

return Settings
