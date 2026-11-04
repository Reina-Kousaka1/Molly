local Store = require("src.persistence.guild_store")
local V2 = require("src.persistence.guild_v2")
local Schema = require("src.settings.schema")

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

local function equal(left, right)
  if type(left) ~= type(right) then return false end
  if type(left) ~= "table" then return left == right end
  for key, value in pairs(left) do if not equal(value, right[key]) then return false end end
  for key in pairs(right) do if left[key] == nil then return false end end
  return true
end

local function domain_value(data, domain)
  if domain == "moderation" then
    local channel = data.modlog or ""
    if not Schema.valid_id(channel, true) then return nil, "invalid_store" end
    return { modlog_channel_id = channel }
  elseif domain == "voice" then
    local voice = data.voice_system or {}
    if type(voice) ~= "table" then return nil, "invalid_store" end
    local channel = voice.trigger_channel_id or ""
    if not Schema.valid_id(channel, true) then return nil, "invalid_store" end
    return { trigger_channel_id = channel }
  end
  local root, reason = V2.read(data)
  if not root then return nil, reason end
  local sections = root.settings or {}
  if type(sections) ~= "table" then return nil, "invalid_store" end
  return Schema.normalize(domain, sections[domain])
end

-- Read a module setting without migrating older guild documents. Legacy prefix,
-- economy, modlog and dynamic-voice fields are read from their original keys.
function Settings:get_domain(guild, domain)
  if not Store.valid_id(guild) then return false, "invalid_guild" end
  if domain == "prefix" or domain == "economy" then
    local ok, current = self:get(guild)
    if not ok then return false, current end
    if domain == "prefix" then return true, { prefix = current.prefix } end
    return true, { currency_name = current.currency_name, currency_symbol = current.currency_symbol }
  end
  if domain ~= "moderation" and domain ~= "voice" and not Schema.defaults[domain] then
    return false, "invalid_domain"
  end
  return self.store:run(guild, function(data)
    local value, reason = domain_value(data, domain)
    if not value then return false, reason or "invalid_store" end
    return true, Schema.copy(value), false
  end)
end

-- Module updates run through the same guild transaction as the V1.2 settings.
-- Existing fields are not moved or rewritten; new sections live under the
-- additive data.molly_v2.settings object.
function Settings:update_domain(guild, domain, mutate)
  if not Store.valid_id(guild) or type(mutate) ~= "function" then return false, "invalid_argument" end
  if domain == "prefix" or domain == "economy" then
    return self:_update(guild, function(current)
      local value = domain == "prefix" and { prefix = current.prefix }
        or { currency_name = current.currency_name, currency_symbol = current.currency_symbol }
      local changed, reason = mutate(value)
      if changed == nil then return nil, reason end
      if not changed then return false end
      if domain == "prefix" then
        if not valid_prefix(value.prefix) then return nil, "invalid_prefix" end
        current.prefix = value.prefix
      else
        if not valid_currency_name(value.currency_name) then return nil, "invalid_currency_name" end
        if value.currency_symbol ~= "" and not valid_currency_symbol(value.currency_symbol) then return nil, "invalid_currency_symbol" end
        current.currency_name, current.currency_symbol = value.currency_name, value.currency_symbol
      end
      return true
    end)
  end
  if domain ~= "moderation" and domain ~= "voice" and not Schema.defaults[domain] then return false, "invalid_domain" end
  return self.store:run(guild, function(data)
    local current, reason = domain_value(data, domain)
    if not current then return false, reason or "invalid_store" end
    local next_value = Schema.copy(current)
    local changed, mutation_reason = mutate(next_value)
    if changed == nil then return false, mutation_reason end
    if not changed then return true, Schema.copy(current), false end
    local normalized
    if domain == "moderation" then
      if not Schema.valid_id(next_value.modlog_channel_id, true) then return false, "invalid_setting" end
      normalized = { modlog_channel_id = next_value.modlog_channel_id }
    elseif domain == "voice" then
      if not Schema.valid_id(next_value.trigger_channel_id, true) then return false, "invalid_setting" end
      normalized = { trigger_channel_id = next_value.trigger_channel_id }
    else
      normalized, mutation_reason = Schema.normalize(domain, next_value)
      if not normalized then return false, mutation_reason or "invalid_setting" end
    end
    if equal(current, normalized) then return true, Schema.copy(current), false end
    if domain == "moderation" then
      data.modlog = normalized.modlog_channel_id
    elseif domain == "voice" then
      if data.voice_system == nil then data.voice_system = { temporary = {} } end
      if type(data.voice_system) ~= "table" then return false, "invalid_store" end
      data.voice_system.trigger_channel_id = normalized.trigger_channel_id ~= "" and normalized.trigger_channel_id or nil
    else
      local root, root_reason = V2.ensure(data)
      if not root then return false, root_reason end
      root.settings = root.settings or {}
      if type(root.settings) ~= "table" then return false, "invalid_store" end
      root.settings[domain] = normalized
    end
    return true, Schema.copy(normalized), true
  end)
end

Settings.valid_prefix = valid_prefix
Settings.valid_currency_name = valid_currency_name
Settings.valid_currency_symbol = valid_currency_symbol

return Settings
