local Extensions = {}

local function coins(eur_cents)
  -- Fictional EUR anchors, using the established €0.0038 per Molly Coin rate.
  return math.floor((eur_cents * 100 + 19) / 38)
end

local additions = {
  { id = "molly_berryglass_lip_oil", name = "Berryglass Lip Oil",
    description = "A fictional sheer berry gloss with a glassy, cushion-soft finish.",
    category = "makeup/lip-care", collection = "Molly Glossy Era", rarity = "Everyday",
    price = coins(2200), virtual_value_eur_cents = 2200, kind = "collectible", preview_category = "beauty" },
  { id = "molly_cloudberry_sleep_mask", name = "Cloudberry Sleep Mask",
    description = "A fictional overnight face mask for Molly's cozy wind-down ritual.",
    category = "skincare/mask", collection = "Pink Cloud Skincare", rarity = "Everyday",
    price = coins(2600), virtual_value_eur_cents = 2600, kind = "collectible", preview_category = "beauty" },
  { id = "molly_petal_veil_blush", name = "Petal Veil Cream Blush",
    description = "A fictional whipped cheek tint in a soft, rosy-petal shade.",
    category = "makeup/blush", collection = "Molly Glossy Era", rarity = "Signature",
    price = coins(2800), virtual_value_eur_cents = 2800, kind = "collectible", preview_category = "beauty" },
  { id = "molly_pink_cloud_mist", name = "Pink Cloud Hydration Mist",
    description = "A fictional fine face mist for a fresh-feeling, dewy routine.",
    category = "skincare/mist", collection = "Pink Cloud Skincare", rarity = "Everyday",
    price = coins(2400), virtual_value_eur_cents = 2400, kind = "collectible", preview_category = "beauty" },
  { id = "molly_satin_bow_claw", name = "Satin Bow Claw Clip",
    description = "A fictional glossy hair clip finished with a removable satin bow.",
    category = "accessories/hair", collection = "Preppy Essentials", rarity = "Signature",
    price = coins(1800), virtual_value_eur_cents = 1800, kind = "fashion", slot = "head", preview_category = "accessories" },
}

local by_id = {}
for _, item in ipairs(additions) do by_id[item.id] = item end

local function copy(item)
  local result = {}
  for key, value in pairs(item) do result[key] = value end
  return result
end

function Extensions.install(catalog)
  assert(type(catalog) == "table" and type(catalog.get) == "function" and type(catalog.list) == "function",
    "catalog module is required")
  if catalog._molly_collection_v1 then return false end

  local original_get, original_list = catalog.get, catalog.list
  catalog.get = function(id)
    local item = by_id[id]
    return item and copy(item) or original_get(id)
  end
  catalog.list = function(category)
    local result = original_list(category)
    for _, item in ipairs(additions) do
      if category == nil or item.category == category then result[#result + 1] = copy(item) end
    end
    return result
  end
  catalog.page = function(page, page_size, category)
    page, page_size = tonumber(page) or 1, tonumber(page_size) or 8
    if page ~= page or page == math.huge or page == -math.huge then page = 1 end
    if page_size ~= page_size or page_size == math.huge or page_size == -math.huge then page_size = 8 end
    page, page_size = math.max(1, math.min(1000000, math.floor(page))), math.max(1, math.min(10, math.floor(page_size)))
    local all, result = catalog.list(category), {}
    local first = (page - 1) * page_size + 1
    for index = first, math.min(#all, first + page_size - 1) do result[#result + 1] = all[index] end
    local pages = math.max(1, math.ceil(#all / page_size))
    return { items = result, total = #all, page = page, page_size = page_size, pages = pages }
  end
  catalog._molly_collection_v1 = true
  return true
end

return Extensions
