local Preview = {}

local ASSET_ROOT = "https://raw.githubusercontent.com/Reina-Kousaka1/Molly/feature/personality-engine-v12/assets/shop/"
local ASSETS = {
  beauty = "molly-beauty-preview.png",
  fashion = "molly-fashion-preview.png",
  accessories = "molly-accessories-preview.png",
}

local legacy_categories = {
  rose_glow = "beauty", citrus_satin = "beauty", lilac_moon = "beauty", soft_gold = "beauty",
  lulu_align_leggings = "fashion", lulu_scuba_hoodie = "fashion", lulu_define_jacket = "fashion",
  lulu_belt_bag = "accessories", lulu_headband = "accessories", pink_stanley = "accessories",
  glow_mask = "beauty", bow_clips = "accessories", lip_gloss = "beauty", skincare_bag = "accessories",
  sephora_tote = "accessories", crystal_ring = "accessories", rose_crown = "accessories",
  silver_cape = "fashion",
}

local function category_for(item)
  if type(item) ~= "table" then return nil end
  local department = type(item.department) == "string" and item.department:lower() or ""
  if department == "lululemon" then return "fashion" end
  if department == "pandora" then return "accessories" end
  if department == "sephora" then return "beauty" end

  local category = type(item.category) == "string" and item.category:lower() or ""
  if category:find("fashion", 1, true) or category:find("studio", 1, true) then return "fashion" end
  if category:find("jewel", 1, true) or category:find("hair", 1, true)
    or category:find("accessor", 1, true) or category:find("beauty-tool", 1, true) then return "accessories" end
  if category:find("beauty", 1, true) or category:find("skin", 1, true)
    or category:find("makeup", 1, true) or category:find("lip", 1, true)
    or category:find("body", 1, true) then return "beauty" end

  return legacy_categories[item.id] or (item.kind == "fashion" and "fashion" or nil)
end

function Preview.allowed_url(url)
  if type(url) ~= "string" then return false end
  for _, filename in pairs(ASSETS) do
    if url == ASSET_ROOT .. filename then return true end
  end
  return false
end

function Preview.category_label(category)
  local labels = { beauty = "Beauty & self-care", fashion = "Fashion", accessories = "Accessories & jewelry" }
  return labels[category] or "Boutique"
end

function Preview.for_item(item)
  if type(item) ~= "table" then return nil end
  local category = category_for(item)
  local filename = category and ASSETS[category]
  if not filename then return { category = category, image_url = nil, fallback = item.emoji or "🎀" } end

  local image_url = ASSET_ROOT .. filename
  if not Preview.allowed_url(image_url) then return { category = category, image_url = nil, fallback = item.emoji or "🎀" } end
  return {
    category = category,
    image_url = image_url,
    image_alt = "Original Molly virtual boutique " .. category .. " preview artwork",
    fallback = item.emoji or "🎀",
  }
end

return Preview
