local Catalog = {}

local items = {
  { id = "pickaxe", name = "Sturdy pickaxe", description = "A reusable tool for virtual mining.", price = 100, kind = "tool" },
  { id = "rose_crown", name = "Rose crown", description = "A virtual fashion accessory.", price = 250, kind = "fashion", slot = "head" },
  { id = "silver_cape", name = "Silver cape", description = "A virtual outfit accessory.", price = 350, kind = "fashion", slot = "outfit" },
  { id = "crystal_ring", name = "Crystal ring", description = "A virtual jewelry accessory.", price = 180, kind = "fashion", slot = "accessory" },
}

local resources = {
  copper_ore = { id = "copper_ore", name = "Copper ore", description = "Common mining ore.", sell_price = 5 },
  iron_ore = { id = "iron_ore", name = "Iron ore", description = "Uncommon mining ore.", sell_price = 12 },
  crystal_shard = { id = "crystal_shard", name = "Crystal shard", description = "Rare mining find.", sell_price = 30 },
}

local by_id = {}
for _, item in ipairs(items) do by_id[item.id] = item end

function Catalog.get(id)
  local item = by_id[id]
  if not item then return nil end
  local copy = {}
  for key, value in pairs(item) do copy[key] = value end
  return copy
end

function Catalog.list()
  local result = {}
  for _, item in ipairs(items) do result[#result + 1] = Catalog.get(item.id) end
  return result
end

function Catalog.get_resource(id)
  local item = resources[id]
  if not item then return nil end
  local copy = {}
  for key, value in pairs(item) do copy[key] = value end
  return copy
end

function Catalog.resources()
  local result = {}
  for _, id in ipairs({ "copper_ore", "iron_ore", "crystal_shard" }) do result[#result + 1] = Catalog.get_resource(id) end
  return result
end

function Catalog.slot(slot)
  return slot == "head" or slot == "outfit" or slot == "accessory"
end

return Catalog
