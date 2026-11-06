local Store = require("src.persistence.guild_store")

local Registry = {}
Registry.__index = Registry

local definitions = {
  standard = { id = "standard", label = "Standard", commerce = "ledger", fashion = "inventory", mining = true },
  sephora = { id = "sephora", label = "Virtual Sephora", commerce = "try_on", fashion = "virtual_looks", mining = false },
}

function Registry.new(settings)
  assert(type(settings) == "table" and type(settings.get_domain) == "function"
    and type(settings.update_domain) == "function", "guild settings are required")
  return setmetatable({ settings = settings }, Registry)
end

function Registry:get(guild)
  if not Store.valid_id(guild) then return false, "invalid_guild" end
  local ok, value = self.settings:get_domain(guild, "guild")
  if not ok then return false, value end
  local definition = definitions[value.mode or "standard"]
  if not definition then return false, "invalid_mode" end
  local result = {}
  for key, child in pairs(definition) do result[key] = child end
  return true, result
end

function Registry:set(guild, mode)
  if not Store.valid_id(guild) or not definitions[mode] then return false, "invalid_mode" end
  return self.settings:update_domain(guild, "guild", function(value)
    if value.mode == mode then return false end
    value.mode = mode
    return true
  end)
end

function Registry:is(guild, mode)
  local ok, value = self:get(guild)
  if not ok then return false, value end
  return true, value.id == mode
end

function Registry:list()
  return { { id = "standard", label = definitions.standard.label },
    { id = "sephora", label = definitions.sephora.label } }
end

Registry.definitions = definitions
return Registry
