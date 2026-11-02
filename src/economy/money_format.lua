local Store = require("src.persistence.guild_store")
local GuildSettings = require("src.settings.guild")

local Money = {}

function Money.format(settings, amount)
  local value = type(settings) == "table" and settings or GuildSettings.defaults
  if type(amount) ~= "number" or amount ~= amount then return "0 " .. GuildSettings.defaults.currency_name end
  local rendered = string.format("%.0f", amount)
  local symbol = value.currency_symbol or ""
  local name = value.currency_name or GuildSettings.defaults.currency_name
  return (symbol ~= "" and (symbol .. rendered .. " " .. name)) or (rendered .. " " .. name)
end

function Money.formatter(settings_service, guild)
  local settings
  if type(settings_service) ~= "table" or type(settings_service.get) ~= "function" or not Store.valid_id(guild) then
    return function(amount) return Money.format(nil, amount) end
  end
  local ok, value = settings_service:get(guild)
  if ok then settings = value end
  return function(amount) return Money.format(settings, amount) end
end

function Money.for_guild(settings_service, guild, amount)
  return Money.formatter(settings_service, guild)(amount)
end

return Money
