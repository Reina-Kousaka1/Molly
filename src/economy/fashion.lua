local Store = require("src.persistence.guild_store")
local Catalog = require("src.economy.catalog")

local Fashion = {}
Fashion.__index = Fashion

function Fashion.new(inventory, modes)
  assert(type(inventory) == "table" and type(inventory.get) == "function"
    and type(inventory.equip) == "function" and type(inventory.unequip) == "function", "inventory service is required")
  assert(type(modes) == "table" and type(modes.get) == "function", "mode registry is required")
  return setmetatable({ inventory = inventory, modes = modes }, Fashion)
end

function Fashion:_mode(guild)
  if not Store.valid_id(guild) then return false, "invalid_guild" end
  local ok, mode = self.modes:get(guild)
  if not ok then return false, mode end
  if mode.fashion ~= "inventory" then return false, "virtual_mode" end
  return true
end

function Fashion:get(guild, user)
  if not Store.valid_id(user) then return false, "invalid_user" end
  local ok, reason = self:_mode(guild)
  if not ok then return false, reason end
  return self.inventory:get(guild, user)
end

function Fashion:equip(guild, user, item_id)
  local ok, reason = self:_mode(guild)
  if not ok then return false, reason end
  local item = Catalog.get(item_id)
  if not item or item.kind ~= "fashion" then return false, "not_fashion" end
  return self.inventory:equip(guild, user, item_id)
end

function Fashion:unequip(guild, user, slot)
  local ok, reason = self:_mode(guild)
  if not ok then return false, reason end
  return self.inventory:unequip(guild, user, slot)
end

return Fashion
