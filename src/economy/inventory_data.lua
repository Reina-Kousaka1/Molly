local Store = require("src.persistence.guild_store")
local V2 = require("src.persistence.guild_v2")

local Catalog = require("src.economy.catalog")
local InventoryData = {}
InventoryData.MAX_USERS = 200
InventoryData.MAX_ITEM_TYPES = 50
InventoryData.MAX_QUANTITY = 999

local function valid_item(item)
  return type(item) == "string" and #item >= 1 and #item <= 32 and item:match("^[a-z][a-z0-9_%-]*$") ~= nil
end

local function validate_items(items)
  local count = 0
  for item, quantity in pairs(items) do
    if not valid_item(item) or type(quantity) ~= "number" or quantity % 1 ~= 0
      or quantity < 1 or quantity > InventoryData.MAX_QUANTITY then return nil end
    count = count + 1
  end
  if count > InventoryData.MAX_ITEM_TYPES then return nil end
  return count
end

local function valid_slot(slot)
  return Catalog.slot(slot)
end

local function validate_section(section)
  if type(section.items) ~= "table" or type(section.equipped) ~= "table" then return false end
  local users = 0
  for user, items in pairs(section.items) do
    if not Store.valid_id(user) or type(items) ~= "table" or validate_items(items) == nil then return false end
    users = users + 1
  end
  if users > InventoryData.MAX_USERS then return false end
  users = 0
  for user, equipped in pairs(section.equipped) do
    if not Store.valid_id(user) or type(equipped) ~= "table" then return false end
    users = users + 1
    local owned = section.items[user] or {}
    local slots = 0
    for slot, item in pairs(equipped) do
      local definition = Catalog.get(item)
      if not valid_slot(slot) or not valid_item(item) or not definition or definition.slot ~= slot
        or (owned[item] or 0) < 1 then return false end
      slots = slots + 1
    end
    if slots > 6 then return false end
  end
  return users <= InventoryData.MAX_USERS
end

local function ensure(data)
  local section, reason = V2.ensure_section(data, "inventory")
  if not section then return nil, reason end
  section.items, section.equipped = section.items or {}, section.equipped or {}
  if not validate_section(section) then return nil, "invalid_store" end
  return section
end

local function read(data)
  local section, reason = V2.read_section(data, "inventory")
  if not section then return nil, reason end
  section.items, section.equipped = section.items or {}, section.equipped or {}
  if not validate_section(section) then return nil, "invalid_store" end
  return section
end

function InventoryData.add(data, user, item, quantity)
  if not Store.valid_id(user) or not valid_item(item) or type(quantity) ~= "number"
    or quantity % 1 ~= 0 or quantity < 1 then return false, "invalid_argument" end
  local section, reason = ensure(data)
  if not section then return false, reason end
  local items = section.items[user]
  if items == nil then
    local users = 0; for _ in pairs(section.items) do users = users + 1 end
    if users >= InventoryData.MAX_USERS then return false, "capacity" end
    items = {}
  elseif type(items) ~= "table" then return false, "invalid_store" end
  local types = validate_items(items)
  if types == nil then return false, "invalid_store" end
  local current = items[item] or 0
  if current == 0 and types >= InventoryData.MAX_ITEM_TYPES then return false, "capacity" end
  if current + quantity > InventoryData.MAX_QUANTITY then return false, "capacity" end
  items[item] = current + quantity
  section.items[user] = items
  return true, { item_id = item, quantity = items[item] }
end

function InventoryData.remove(data, user, item, quantity)
  if not Store.valid_id(user) or not valid_item(item) or type(quantity) ~= "number"
    or quantity % 1 ~= 0 or quantity < 1 then return false, "invalid_argument" end
  local section, reason = ensure(data)
  if not section then return false, reason end
  local items = section.items[user] or {}
  local current = items[item] or 0
  if current < quantity then return false, "not_owned" end
  if current == quantity then
    items[item] = nil
    local equipped = section.equipped[user]
    if equipped then
      for slot, equipped_item in pairs(equipped) do if equipped_item == item then equipped[slot] = nil end end
    end
  else
    items[item] = current - quantity
  end
  if next(items) == nil then
    section.items[user], section.equipped[user] = nil, nil
  else
    section.items[user] = items
  end
  return true, { item_id = item, quantity = current - quantity }
end

function InventoryData.get(data, user)
  if not Store.valid_id(user) then return nil, "invalid_user" end
  local section, reason = read(data)
  if not section then return nil, reason end
  local items = section.items[user] or {}
  local equipped = section.equipped[user] or {}
  if type(items) ~= "table" or type(equipped) ~= "table" then return nil, "invalid_store" end
  local copied_items, copied_equipped = {}, {}
  for item, quantity in pairs(items) do
    if not valid_item(item) or type(quantity) ~= "number" or quantity % 1 ~= 0 or quantity < 1
      or quantity > InventoryData.MAX_QUANTITY then return nil, "invalid_store" end
    copied_items[item] = quantity
  end
  for slot, item in pairs(equipped) do
    if type(slot) ~= "string" or #slot > 24 or not valid_item(item) then return nil, "invalid_store" end
    copied_equipped[slot] = item
  end
  return { items = copied_items, equipped = copied_equipped }
end

function InventoryData.ensure(data)
  return ensure(data)
end

function InventoryData.read(data)
  return read(data)
end

function InventoryData.valid_item(item)
  return valid_item(item)
end

return InventoryData
