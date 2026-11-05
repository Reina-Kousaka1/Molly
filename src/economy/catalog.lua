local Catalog = {}

local items = {
  { id = "rose_glow", name = "Rose Glow beauty look", description = "Permanent unlockable virtual beauty look.", price = 350, kind = "fashion", slot = "outfit" },
  { id = "citrus_satin", name = "Citrus Satin beauty look", description = "Permanent unlockable virtual beauty look.", price = 420, kind = "fashion", slot = "outfit" },
  { id = "lilac_moon", name = "Lilac Moon beauty look", description = "Permanent unlockable virtual beauty look.", price = 550, kind = "fashion", slot = "outfit" },
  { id = "soft_gold", name = "Soft Gold beauty look", description = "Permanent unlockable virtual beauty look.", price = 700, kind = "fashion", slot = "outfit" },
  { id = "pickaxe", name = "Sturdy pickaxe", description = "A reusable tool for virtual mining.", price = 100, kind = "tool" },
  { id = "rose_crown", name = "Rose crown", description = "A virtual fashion accessory.", price = 250, kind = "fashion", slot = "head" },
  { id = "silver_cape", name = "Silver cape", description = "A virtual outfit accessory.", price = 350, kind = "fashion", slot = "outfit" },
  { id = "crystal_ring", name = "Crystal ring", description = "A virtual jewelry accessory.", price = 180, kind = "fashion", slot = "accessory" },
  { id = "lulu_align_leggings", name = "Lululemon-inspired Align leggings", description = "Soft pink virtual yoga leggings. Fictional in-game item; not an official product.", price = 420, kind = "fashion", slot = "outfit" },
  { id = "lulu_scuba_hoodie", name = "Lululemon-inspired Scuba hoodie", description = "Oversized strawberry-milk hoodie. Fictional in-game item; not an official product.", price = 490, kind = "fashion", slot = "outfit" },
  { id = "lulu_belt_bag", name = "Lululemon-inspired belt bag", description = "Pastel pink everyday belt bag. Fictional in-game item; not an official product.", price = 290, kind = "fashion", slot = "accessory" },
  { id = "lulu_define_jacket", name = "Lululemon-inspired Define jacket", description = "Fitted blush workout jacket. Fictional in-game item; not an official product.", price = 520, kind = "fashion", slot = "outfit" },
  { id = "lulu_headband", name = "Lululemon-inspired headband", description = "Pink workout hairband. Fictional in-game item; not an official product.", price = 160, kind = "fashion", slot = "head" },
  { id = "pink_stanley", name = "Pink tumbler", description = "Oversized virtual pink tumbler. Fictional in-game item; not an official product.", price = 240, kind = "fashion", slot = "accessory" },
  { id = "glow_mask", name = "Glow skincare mask", description = "Cute virtual skincare mask. Fictional in-game item; not an official product.", price = 180, kind = "fashion", slot = "accessory" },
  { id = "bow_clips", name = "Bow hair clips", description = "A pair of baby-pink hair bows. Fictional in-game item; not an official product.", price = 130, kind = "fashion", slot = "head" },
  { id = "lip_gloss", name = "Strawberry lip gloss", description = "Glossy virtual beauty accessory. Fictional in-game item; not an official product.", price = 110, kind = "fashion", slot = "accessory" },
  { id = "skincare_bag", name = "Preppy skincare bag", description = "Pastel beauty essentials pouch. Fictional in-game item; not an official product.", price = 260, kind = "fashion", slot = "accessory" },
  { id = "sephora_tote", name = "Beauty haul tote", description = "Pink virtual shopping tote. Fictional in-game item; not an official product.", price = 230, kind = "fashion", slot = "accessory" },
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
  if not item then return require("src.economy.retail_catalog").get(id) end
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
    or slot == "ring" or slot == "necklace" or slot == "bracelet"
end

return Catalog
