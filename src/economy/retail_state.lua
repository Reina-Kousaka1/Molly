local Store = require("src.persistence.guild_store")
local V2 = require("src.persistence.guild_v2")
local Catalog = require("src.economy.retail_catalog")

local RetailState = {}
RetailState.__index = RetailState
RetailState.MAX_USERS = 200
RetailState.MAX_CART_TYPES = 20
RetailState.MAX_SAVED_IDS = 50
RetailState.MAX_QUANTITY = 99

local collections = { cart = true, wishlist = true, favorites = true }

local function valid_list(value, name)
  if type(value) ~= "table" then return false end
  if name == "cart" then
    local count = 0
    for id, quantity in pairs(value) do
      if not Catalog.get(id) or type(quantity) ~= "number" or quantity % 1 ~= 0
        or quantity < 1 or quantity > RetailState.MAX_QUANTITY then return false end
      count = count + 1
    end
    return count <= RetailState.MAX_CART_TYPES
  end
  local count, seen = 0, {}
  for index, id in ipairs(value) do
    if type(id) ~= "string" or not Catalog.get(id) or seen[id] or index > RetailState.MAX_SAVED_IDS then return false end
    seen[id], count = true, count + 1
  end
  for key in pairs(value) do if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > count then return false end end
  return count <= RetailState.MAX_SAVED_IDS
end

local function normalize_user(value)
  if type(value) ~= "table" then return nil end
  local result = { cart = value.cart or {}, wishlist = value.wishlist or {}, favorites = value.favorites or {} }
  for name in pairs(collections) do if not valid_list(result[name], name) then return nil end end
  return result
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
end

function RetailState.new(store)
  assert(type(store) == "table" and type(store.run) == "function", "guild store is required")
  return setmetatable({ store = store }, RetailState)
end

function RetailState:get(guild, user)
  if not Store.valid_id(guild) or not Store.valid_id(user) then return false, "invalid_argument" end
  return self.store:run(guild, function(data)
    local section, reason = V2.read_section(data, "retail")
    if not section then return false, reason end
    local users = section.users or {}
    if type(users) ~= "table" then return false, "invalid_store" end
    local value = users[user]
    if value == nil then return true, { cart = {}, wishlist = {}, favorites = {} }, false end
    value = normalize_user(value)
    if not value then return false, "invalid_store" end
    return true, copy(value), false
  end)
end

function RetailState:update(guild, user, collection, action, item_id, quantity)
  local item = Catalog.get(item_id)
  if not Store.valid_id(guild) or not Store.valid_id(user) or not collections[collection]
    or (action ~= "add" and action ~= "remove") or not item then return false, "invalid_argument" end
  if action == "add" and item.product_id and not item.available then return false, "item_unavailable" end
  if collection == "cart" then
    quantity = quantity or 1
    if type(quantity) ~= "number" or quantity % 1 ~= 0 or quantity < 1 or quantity > RetailState.MAX_QUANTITY then
      return false, "invalid_quantity"
    end
  end
  return self.store:run(guild, function(data)
    local section, reason = V2.ensure_section(data, "retail")
    if not section then return false, reason end
    section.users = section.users or {}
    if type(section.users) ~= "table" then return false, "invalid_store" end
    local state = section.users[user]
    if state == nil then
      local count = 0; for _ in pairs(section.users) do count = count + 1 end
      if count >= RetailState.MAX_USERS then return false, "capacity" end
      state = { cart = {}, wishlist = {}, favorites = {} }
    else
      state = normalize_user(state)
      if not state then return false, "invalid_store" end
    end
    local list = state[collection]
    if collection == "cart" then
      local current = list[item_id] or 0
      if action == "add" then
        if current == 0 then
          local count = 0; for _ in pairs(list) do count = count + 1 end
          if count >= RetailState.MAX_CART_TYPES then return false, "capacity" end
        end
        if current + quantity > RetailState.MAX_QUANTITY then return false, "capacity" end
        list[item_id] = current + quantity
      else
        if current == 0 then return false, "not_saved" end
        list[item_id] = nil
      end
    else
      local found
      for index, existing in ipairs(list) do if existing == item_id then found = index; break end end
      if action == "add" then
        if found then return true, { collection = collection, item_id = item_id, already_saved = true }, false end
        if #list >= RetailState.MAX_SAVED_IDS then return false, "capacity" end
        list[#list + 1] = item_id
      else
        if not found then return false, "not_saved" end
        table.remove(list, found)
      end
    end
    section.users[user] = state
    return true, { collection = collection, item_id = item_id, action = action }, true
  end)
end

return RetailState
