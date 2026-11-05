package.path = "./?.lua;./?/init.lua;" .. package.path

local Pricing = require("src.economy.retail_pricing")
local Catalog = require("src.economy.retail_catalog")
local total, failed = 0, 0
local function test(name, callback)
  total = total + 1
  local ok, reason = pcall(callback)
  if ok then io.stdout:write("ok - " .. name .. "\n")
  else failed = failed + 1; io.stderr:write("not ok - " .. name .. ": " .. tostring(reason) .. "\n") end
end

local rate = { usd_per_eur_x10000 = 11224, as_of = "2026-11-05",
  source = "https://www.ecb.europa.eu/stats/policy_and_exchange_rates/euro_reference_exchange_rates/html/index.en.html" }

test("retail price uses integer arithmetic and documented half-up rounding", function()
  local price, snapshot = Pricing.snapshot(5200, 5600, rate, "2026-11-05")
  assert(price == 13407)
  assert(snapshot.eu_cents == 5200 and snapshot.us_cents == 5600)
  assert(snapshot.fx_usd_per_eur_x10000 == 11224 and snapshot.coin_price == price)
  assert(Pricing.valid_snapshot(snapshot, price))
end)

test("price calculator rejects missing, negative, malformed and overflowing inputs", function()
  assert(select(2, Pricing.calculate(-1, 100, rate)) == "invalid_price")
  assert(select(2, Pricing.calculate(100, nil, rate)) == "invalid_price")
  assert(select(2, Pricing.calculate(100, 100, { usd_per_eur_x10000 = 0, as_of = rate.as_of, source = rate.source })) == "invalid_fx_rate")
  assert(select(2, Pricing.snapshot(100, 100, rate, "not-a-date")) == "invalid_snapshot_date")
  assert(not Pricing.valid_snapshot({ eu_cents = 100 }, 10))
end)

test("catalog is versioned outside Lua and keeps every established product and variant ID", function()
  assert(Catalog.VERSION == 4 and Catalog.SCHEMA_VERSION == 3 and #Catalog.list() == 10)
  local variants, seen = Catalog.variants(), {}
  assert(#variants == 30)
  for _, item in ipairs(variants) do
    assert(not seen[item.id] and #item.id <= 32)
    seen[item.id] = true
    assert(item.price >= 1 and Pricing.valid_snapshot(item.price_snapshot, item.price))
    assert(item.source_eu:match("^https://") and item.source_us:match("^https://"))
    assert(item.catalog_version == Catalog.VERSION and item.available == true)
  end
end)

test("catalog filters departments and searches as literal case-insensitive text", function()
  assert(#Catalog.list("pandora") == 5)
  assert(#Catalog.list("sephora") == 3)
  assert(#Catalog.list("lululemon") == 2)
  assert(#Catalog.search("DRUNK ELEPHANT") == 1)
  assert(#Catalog.search(".") == 0)
  assert(#Catalog.search(string.rep("x", 81)) == 0)
  assert(#Catalog.list("unknown") == 0)
end)

test("catalog pagination and multi-filter search stay bounded", function()
  local first = assert(Catalog.page({}, 1, 3))
  local second = assert(Catalog.page({}, 2, 3))
  assert(#first.items == 3 and #second.items == 3 and first.total == 10 and first.pages == 4)
  assert(first.items[1].id ~= second.items[1].id)
  local found = assert(Catalog.search_page("serum", { department = "sephora", brand = "Drunk", category = "skincare" }, 1, 2))
  assert(found.total == 1 and #found.items == 1 and found.items[1].id == "de_bhydra")
  local ring_page = Catalog.get_product("pandora_elevated_heart_ring", 2, 2)
  assert(ring_page and ring_page.variant_count == 7 and #ring_page.variants == 2)
  assert(ring_page.variants[1].id == "ring52" and ring_page.page == 2 and ring_page.pages == 4)
end)

test("new retail facts retain exact regional references, prices, and checked snapshots", function()
  local gloss = Catalog.get_product("rare_positive_light_gloss")
  assert(gloss and gloss.brand == "Rare Beauty" and gloss.name == "Positive Light Luminizing Lip Gloss")
  assert(gloss.product_ref_eu == "763943" and gloss.product_ref_us == "P516855")
  local blaze = Catalog.get("rare_gloss_blaze")
  assert(blaze and blaze.color == "Blaze" and blaze.variant == "Blaze; 3.3 ml")
  assert(blaze.price_snapshot.eu_cents == 2200 and blaze.price_snapshot.us_cents == 2000)
  assert(blaze.price == 5239 and Pricing.valid_snapshot(blaze.price_snapshot, blaze.price))

  local leggings = Catalog.get_product("lulu_align25")
  assert(leggings and leggings.name == 'lululemon Align™ High-Rise Pant 25"')
  assert(leggings.product_ref_eu == "prod2020012" and leggings.product_ref_us == "i4goprzy85")
  local size = Catalog.get("align25_us8")
  assert(size and size.variant == "US size 8, 25 in" and size.price_snapshot.eu_cents == 9800)
  assert(size.price_snapshot.us_cents == 9800 and size.price == 24383)

  local charm = Catalog.get_product("pandora_snowflake_charm")
  assert(charm and charm.name == "Snowflake Charm" and charm.product_ref_eu == "764249C01")
  assert(charm.product_ref_us == "764249C01")
  local one_size = Catalog.get("snowflake_one")
  assert(one_size and one_size.variant == "One size" and one_size.price_snapshot.eu_cents == 4500)
  assert(one_size.price_snapshot.us_cents == 5800 and one_size.price == 12720)
end)

test("Pandora heart ring uses the verified silver product and has size variants", function()
  local product = Catalog.get_product("pandora_elevated_heart_ring")
  assert(product and product.sku == "198421C01" and product.slot == "ring")
  assert(product.product_ref_eu == "198421C01" and product.product_ref_us == "198421C01")
  assert(#product.variants == 7 and product.variants[1].id == "ring48"
    and product.variants[7].id == "ring60")
  local ring = Catalog.get("ring56")
  assert(ring.price_snapshot.eu_cents == 6900 and ring.price_snapshot.us_cents == 9800)
  assert(ring.price == 20567 and Pricing.valid_snapshot(ring.price_snapshot, ring.price))
end)

test("Sephora references are regional and never substituted for an unverified SKU", function()
  local blush = Catalog.get_product("rare_softpinch")
  assert(blush and blush.product_ref_eu == "P10017094" and blush.product_ref_us == "P97989778")
  assert(blush.sku == nil)
  local variant = Catalog.get("blushhappy")
  assert(variant.sku == nil and variant.sku_eu == "-" and variant.sku_us == "-")
end)

test("Define Jacket regional source and SKU fields identify the same verified product", function()
  local jacket = Catalog.get_product("lulu_define")
  assert(jacket)
  assert(jacket.product_ref_eu == "158547109" and jacket.product_ref_us == "hnsjuvo8dn")
  assert(jacket.source_eu:find("eu%.lululemon%.com", 1) ~= nil)
  local variant = Catalog.get("define0")
  assert(variant.sku_eu == "158547109" and variant.sku_us == "158547109")
end)

test("catalog results are defensive copies", function()
  local product = Catalog.get_product("pandora_heart")
  product.variants[1].price = 1
  assert(Catalog.get("heartneck").price ~= 1)
end)

io.stdout:write(string.format("%d retail catalog tests, %d failures\n", total, failed))
if failed > 0 then os.exit(1) end
