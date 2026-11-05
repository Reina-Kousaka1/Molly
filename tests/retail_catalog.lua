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

local rate = { usd_per_eur_x10000 = 11221, as_of = "2026-11-05",
  source = "https://www.ecb.europa.eu/stats/policy_and_exchange_rates/euro_reference_exchange_rates/html/index.en.html" }

test("retail price uses integer arithmetic and documented half-up rounding", function()
  local price, snapshot = Pricing.snapshot(5200, 5600, rate, "2026-11-05")
  assert(price == 13409)
  assert(snapshot.eu_cents == 5200 and snapshot.us_cents == 5600)
  assert(snapshot.fx_usd_per_eur_x10000 == 11221 and snapshot.coin_price == price)
  assert(Pricing.valid_snapshot(snapshot, price))
end)

test("price calculator rejects missing, negative, malformed and overflowing inputs", function()
  assert(select(2, Pricing.calculate(-1, 100, rate)) == "invalid_price")
  assert(select(2, Pricing.calculate(100, nil, rate)) == "invalid_price")
  assert(select(2, Pricing.calculate(100, 100, { usd_per_eur_x10000 = 0, as_of = rate.as_of, source = rate.source })) == "invalid_fx_rate")
  assert(select(2, Pricing.snapshot(100, 100, rate, "not-a-date")) == "invalid_snapshot_date")
  assert(not Pricing.valid_snapshot({ eu_cents = 100 }, 10))
end)

test("curated catalog is bounded, versioned, and contains only listed product variants", function()
  assert(Catalog.VERSION == 1 and #Catalog.list() == 6)
  local variants, seen = Catalog.variants(), {}
  assert(#variants == 20)
  for _, item in ipairs(variants) do
    assert(not seen[item.id] and #item.id <= 32)
    seen[item.id] = true
    assert(item.price >= 1 and Pricing.valid_snapshot(item.price_snapshot, item.price))
    assert(item.source_eu:match("^https://") and item.source_us:match("^https://"))
    assert(item.catalog_version == Catalog.VERSION and item.available == true)
  end
end)

test("catalog filters departments and searches as literal case-insensitive text", function()
  assert(#Catalog.list("pandora") == 3)
  assert(#Catalog.search("DRUNK ELEPHANT") == 1)
  assert(#Catalog.search(".") == 0)
  assert(#Catalog.search(string.rep("x", 81)) == 0)
  assert(#Catalog.list("unknown") == 0)
end)

test("catalog results are defensive copies", function()
  local product = Catalog.get_product("pandora_heart")
  product.variants[1].price = 1
  assert(Catalog.get("heartneck").price ~= 1)
end)

io.stdout:write(string.format("%d retail catalog tests, %d failures\n", total, failed))
if failed > 0 then os.exit(1) end
