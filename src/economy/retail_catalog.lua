-- Reviewed, curated retail data. No network requests or automatic price refresh.
-- The source URLs and price snapshot date are intentionally shipped with each item.
local Pricing = require("src.economy.retail_pricing")

local Catalog = { VERSION = 1, PRICE_CHECKED_AT = "2026-11-05" }
local rate = { usd_per_eur_x10000 = 11221, as_of = "2026-11-05",
  source = "https://www.ecb.europa.eu/stats/policy_and_exchange_rates/euro_reference_exchange_rates/html/index.en.html" }

local products = {
  { id = "de_bhydra", department = "sephora", brand = "Drunk Elephant",
    name = "B-Hydra™ Intensive Hydration Serum", sku = "1785856", category = "skincare/serum",
    description = "50 ml hydration serum; description paraphrased from the retailer listing.",
    eu_cents = 5200, us_cents = 5600, slot = nil, source_eu = "https://www.sephora.fr/p/b-hydra-intensive-hydration---serum-P10013690.html",
    source_us = "https://www.sephora.com/product/b-hydra-intensive-hydration-gel-P406712?country_switch=us",
    variants = { { id = "bhydra50", label = "50 ml" } } },
  { id = "rare_softpinch", department = "sephora", brand = "Rare Beauty",
    name = "Soft Pinch Liquid Blush", sku = "Sephora item 651745 (shade-specific item references are listed by Sephora)",
    category = "makeup/blush", description = "7.5 ml liquid blush; short original catalog description.",
    eu_cents = 2900, us_cents = 2500, source_eu = "https://www.sephora.fr/p/soft-pinch---liquid-blush-651745.html",
    source_us = "https://www.sephora.com/buy/blush-under-30",
    variants = { { id = "blushhope", label = "Hope" }, { id = "blushjoy", label = "Joy" },
      { id = "blushhappy", label = "Happy" }, { id = "blushgrateful", label = "Grateful" },
      { id = "blushgrace", label = "Grace" }, { id = "blushlove", label = "Love" } } },
  { id = "lulu_define", department = "lululemon", brand = "lululemon",
    name = "Define Jacket Nulu", sku = "159403005 (Pink Pearl/Gold/Gold EU product reference)",
    category = "fashion/jacket", description = "Define Jacket Nulu in Pink Pearl/Gold/Gold; item details summarized in original words.",
    color = "Pink Pearl/Gold/Gold", eu_cents = 12800, us_cents = 12800, slot = "outfit",
    source_eu = "https://www.lululemon.de/de-de/p/define-jacke-nulu/159403005.html",
    source_us = "https://shop.lululemon.com/p/define-jacket-nulu/hnsjuvo8dn?color=76033",
    variants = { { id = "define0", label = "US 0" }, { id = "define2", label = "US 2" },
      { id = "define4", label = "US 4" }, { id = "define6", label = "US 6" },
      { id = "define8", label = "US 8" }, { id = "define10", label = "US 10" },
      { id = "define12", label = "US 12" }, { id = "define14", label = "US 14" } } },
  { id = "pandora_heart", department = "pandora", brand = "Pandora",
    name = "Entwined Heart & Butterfly Pendant Necklace", sku = "394477C01", category = "jewelry/necklace",
    description = "Sterling silver heart-and-butterfly pendant with clear cubic zirconia stones.",
    eu_cents = 7500, us_cents = 9800, slot = "necklace",
    source_eu = "https://de.pandora.net/de/ketten/ketten-mit-anhanger/verschlungenes-herz-und-schmetterling-anhanger-halskette-/394477C01.html",
    source_us = "https://us.pandora.net/en/necklaces/pendant-necklaces/entwined-heart-butterfly-pendant-necklace/394477C01.html",
    variants = { { id = "heartneck", label = "One size" } } },
  { id = "pandora_rainbow", department = "pandora", brand = "Pandora",
    name = "Rainbow Tennis Necklace", sku = "394648C01", category = "jewelry/necklace",
    description = "Sterling silver tennis necklace set with multicoloured stones.",
    eu_cents = 13900, us_cents = 19000, slot = "necklace",
    source_eu = "https://at.pandora.net/de/ketten/gliederketten/regenbogenfarbene-tennishalskette/394648C01.html",
    source_us = "https://us.pandora.net/en/necklaces/chain-necklaces/rainbow-tennis-necklace/394648C01.html",
    variants = { { id = "rainbowneck", label = "One size" } } },
  { id = "pandora_moments", department = "pandora", brand = "Pandora",
    name = "Pandora Moments Heart Closure Snake Chain Bracelet", sku = "582257C00", category = "jewelry/bracelet",
    description = "14k rose-gold-plated Pandora Moments snake-chain bracelet with heart closure.",
    eu_cents = 11900, us_cents = 20000, price_note = "US source lists a regular price of $200 and a temporary sale price; the reference uses the regular price.",
    slot = "bracelet", source_eu = "https://de.pandora.net/de/armbander/charm-armbander/pandora-moments-herzverschluss-schlangen-gliederarmband/582257C00.html",
    source_us = "https://us.pandora.net/en/charms-bracelets/bracelets/charm-bracelets/pandora-moments-heart-closure-snake-chain-bracelet/582257C00.html",
    variants = { { id = "bracelet16", label = "16 cm" }, { id = "bracelet21", label = "21 cm" },
      { id = "bracelet23", label = "23 cm" } } },
}

local by_id, by_product, public_products = {}, {}, {}
for _, source in ipairs(products) do
  local product = {}
  for key, value in pairs(source) do if key ~= "variants" then product[key] = value end end
  product.variants = {}
  by_product[source.id] = product
  public_products[#public_products + 1] = product
  for _, option in ipairs(source.variants) do
    local price, snapshot = Pricing.snapshot(source.eu_cents, source.us_cents, rate, Catalog.PRICE_CHECKED_AT)
    assert(price, "invalid curated retail price data")
    local item = { id = option.id, product_id = source.id, department = source.department,
      brand = source.brand, name = source.name, variant = option.label, sku = source.sku,
      category = source.category, description = source.description, color = source.color,
      kind = source.slot and "fashion" or "collectible", slot = source.slot, price = price,
      price_snapshot = snapshot, price_note = source.price_note, source_eu = source.source_eu,
      source_us = source.source_us, catalog_version = Catalog.VERSION, available = true }
    by_id[option.id] = item
    product.variants[#product.variants + 1] = item
  end
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
end

function Catalog.get(id) return by_id[id] and copy(by_id[id]) or nil end
function Catalog.get_product(id) return by_product[id] and copy(by_product[id]) or nil end
function Catalog.list(department)
  local result = {}
  for _, product in ipairs(public_products) do
    if department == nil or department == product.department then result[#result + 1] = copy(product) end
  end
  return result
end
function Catalog.variants()
  local result = {}
  for _, product in ipairs(public_products) do
    for _, variant in ipairs(product.variants) do result[#result + 1] = copy(variant) end
  end
  return result
end
function Catalog.search(query, department)
  if type(query) ~= "string" then return {} end
  local needle, result = query:lower(), {}
  if #needle == 0 or #needle > 80 then return result end
  for _, product in ipairs(public_products) do
    if (department == nil or department == product.department)
      and (product.name:lower():find(needle, 1, true) or product.brand:lower():find(needle, 1, true)
        or product.category:lower():find(needle, 1, true)) then result[#result + 1] = copy(product) end
  end
  return result
end
function Catalog.departments() return { "sephora", "lululemon", "pandora" } end
return Catalog
