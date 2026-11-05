-- Prices are imported snapshots. This module deliberately performs no network
-- requests; catalog maintainers refresh source data through a reviewed import.
local Pricing = {}

-- 1 coin = 38/10,000 EUR. In euro-cents this is 0.38 cents per coin.
Pricing.COIN_EUR_NUMERATOR = 38
Pricing.COIN_EUR_DENOMINATOR = 10000
Pricing.FX_SCALE = 10000
Pricing.ROUNDING = "half_up"

local function integer(value, minimum, maximum)
  return type(value) == "number" and value == value and value % 1 == 0
    and value >= minimum and value <= maximum
end

local function rounded_divide(numerator, denominator)
  return math.floor((numerator * 2 + denominator) / (denominator * 2))
end

function Pricing.validate_rate(rate)
  if type(rate) ~= "table" or not integer(rate.usd_per_eur_x10000, 5000, 20000)
    or type(rate.as_of) ~= "string" or not rate.as_of:match("^%d%d%d%d%-%d%d%-%d%d$")
    or type(rate.source) ~= "string" or not rate.source:match("^https://www%.ecb%.europa%.eu/") then
    return false, "invalid_fx_rate"
  end
  return true
end

function Pricing.calculate(eu_cents, us_cents, rate)
  local rate_ok, rate_reason = Pricing.validate_rate(rate)
  if not rate_ok then return nil, rate_reason end
  if not integer(eu_cents, 1, 100000000) or not integer(us_cents, 1, 100000000) then
    return nil, "invalid_price"
  end

  -- USD cents / (USD per EUR) = EUR cents. Keep all intermediate values
  -- integer and below Lua 5.1's exact-integer range.
  local converted_us_cents = rounded_divide(us_cents * Pricing.FX_SCALE, rate.usd_per_eur_x10000)
  local combined_eur_cents = eu_cents + converted_us_cents
  local coin_price = rounded_divide(combined_eur_cents * 25, 19)
  if not integer(coin_price, 1, 1000000000) then return nil, "price_overflow" end

  return coin_price, {
    eu_cents = eu_cents,
    us_cents = us_cents,
    fx_usd_per_eur_x10000 = rate.usd_per_eur_x10000,
    fx_as_of = rate.as_of,
    fx_source = rate.source,
    rounding = Pricing.ROUNDING,
    coin_price = coin_price,
  }
end

function Pricing.snapshot(eu_cents, us_cents, rate, checked_at)
  local coin_price, value = Pricing.calculate(eu_cents, us_cents, rate)
  if not coin_price then return nil, value end
  if type(checked_at) ~= "string" or not checked_at:match("^%d%d%d%d%-%d%d%-%d%d$") then
    return nil, "invalid_snapshot_date"
  end
  value.checked_at = checked_at
  return coin_price, value
end

function Pricing.valid_snapshot(value, expected_coin_price)
  if type(value) ~= "table" or not integer(value.eu_cents, 1, 100000000)
    or not integer(value.us_cents, 1, 100000000)
    or not integer(value.fx_usd_per_eur_x10000, 5000, 20000)
    or type(value.fx_as_of) ~= "string" or not value.fx_as_of:match("^%d%d%d%d%-%d%d%-%d%d$")
    or type(value.fx_source) ~= "string" or not value.fx_source:match("^https://www%.ecb%.europa%.eu/")
    or type(value.checked_at) ~= "string" or not value.checked_at:match("^%d%d%d%d%-%d%d%-%d%d$")
    or value.rounding ~= Pricing.ROUNDING or not integer(value.coin_price, 1, 1000000000)
    or value.coin_price ~= expected_coin_price then return false end
  local rate = { usd_per_eur_x10000 = value.fx_usd_per_eur_x10000, as_of = value.fx_as_of, source = value.fx_source }
  local calculated = Pricing.calculate(value.eu_cents, value.us_cents, rate)
  return calculated == expected_coin_price
end

return Pricing
