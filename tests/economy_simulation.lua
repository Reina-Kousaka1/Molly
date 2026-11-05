package.path = "./?.lua;./?/init.lua;" .. package.path

local Ledger = require("src.economy.ledger")
local Catalog = require("src.economy.retail_catalog")
local function clone(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = clone(child) end
  return result
end
local store = { data = {} }
function store:run(guild, callback)
  local data = clone(self.data[guild] or { guild = guild, accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {} })
  local ok, result, changed = callback(data)
  if ok and changed then self.data[guild] = data end
  return ok, result
end

local profiles = { casual = 1, regular = 3, very_active = 4 }
local balances, first_affordable = {}, {}
local product_ids = { "bhydra50", "blushhope", "heartneck", "bracelet16", "define6" }
for _, product_id in ipairs(product_ids) do first_affordable[product_id] = {} end
local coin_prices = {}
for _, product_id in ipairs(product_ids) do coin_prices[product_id] = Catalog.get(product_id).price end

local serial = 5000000000
for profile, works_per_day in pairs(profiles) do
  local clock = 86400
  local ledger = Ledger.new(store, function() return clock end, function(minimum, maximum)
    return math.floor((minimum + maximum) / 2)
  end)
  local user = profile == "casual" and "710" or profile == "regular" and "711" or "712"
  balances[user] = 0
  for day = 0, 29 do
    clock = 86400 + day * 86400
    serial = serial + 1
    local ok, result = ledger:change("700", user, tostring(serial), "daily")
    assert(ok); balances[user] = result.wallet
    if day % 7 == 0 then
      serial = serial + 1
      ok, result = ledger:change("700", user, tostring(serial), "weekly")
      assert(ok); balances[user] = result.wallet
    end
    for work = 1, works_per_day do
      clock = 86400 + day * 86400 + (work - 1) * 21600
      serial = serial + 1
      ok, result = ledger:change("700", user, tostring(serial), "work")
      assert(ok); balances[user] = result.wallet
    end
    for _, product_id in ipairs(product_ids) do
      if first_affordable[product_id][profile] == nil and balances[user] >= coin_prices[product_id] then
        first_affordable[product_id][profile] = day + 1
      end
    end
  end
  io.stdout:write(string.format("30-day %s: %d coins (daily 1/day, weekly 1/7 days, work %d/day at midpoint rewards)\n",
    profile, balances[user], works_per_day))
end

for _, product_id in ipairs(product_ids) do
  local product = Catalog.get(product_id)
  local values = first_affordable[product_id]
  io.stdout:write(string.format("First affordable %s (%d coins): casual=%s days, regular=%s days, very_active=%s days\n",
    product.name .. " " .. product.variant, coin_prices[product_id], tostring(values.casual or "not in 30 days"),
    tostring(values.regular or "not in 30 days"), tostring(values.very_active or "not in 30 days")))
end
io.stdout:write("Simulation is a deterministic model using current midpoint rewards and claim cadence; it is not observed player behavior.\n")
