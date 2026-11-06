local Store = require("src.persistence.guild_store")
local InventoryData = require("src.economy.inventory_data")
local Catalog = require("src.economy.catalog")

local Inventory = {}
Inventory.__index = Inventory

function Inventory.new(store)
  assert(type(store) == "table" and type(store.run) == "function", "guild store is required")
  return setmetatable({ store = store }, Inventory)
end

function Inventory:get(guild, user)
  if not Store.valid_id(guild) or not Store.valid_id(user) then return false, "invalid_argument" end
  return self.store:run(guild, function(data)
    local value, reason = InventoryData.get(data, user)
    if not value then return false, reason end
    return true, value, false
  end)
end

function Inventory:equip(guild, user, item_id)
  if not Store.valid_id(guild) or not Store.valid_id(user) then return false, "invalid_argument" end
  local item = Catalog.get(item_id)
  if not item or not item.slot then return false, "not_fashion" end
  return self.store:run(guild, function(data)
    local section, reason = InventoryData.ensure(data)
    if not section then return false, reason end
    local owned = section.items[user] or {}
    if type(owned) ~= "table" then return false, "invalid_store" end
    if type(owned[item_id]) ~= "number" or owned[item_id] < 1 then return false, "not_owned" end
    section.equipped[user] = section.equipped[user] or {}
    if type(section.equipped[user]) ~= "table" then return false, "invalid_store" end
    if section.equipped[user][item.slot] == item_id then return true, item, false end
    section.equipped[user][item.slot] = item_id
    return true, item, true
  end)
end

function Inventory:unequip(guild, user, slot)
  if not Store.valid_id(guild) or not Store.valid_id(user) or not Catalog.slot(slot) then return false, "invalid_argument" end
  return self.store:run(guild, function(data)
    local section, reason = InventoryData.ensure(data)
    if not section then return false, reason end
    local equipped = section.equipped[user] or {}
    if type(equipped) ~= "table" then return false, "invalid_store" end
    local current = equipped[slot]
    if current == nil then return true, false, false end
    equipped[slot] = nil
    section.equipped[user] = equipped
    return true, current, true
  end)
end

return Inventory
