local Store = require("src.persistence.guild_store")
local Ledger = {}
Ledger.__index = Ledger
local MAX = 1000000000000
local MAX_RECORDS = 1000
local MAX_ACCOUNTS = 200
local BASE36 = "0123456789abcdefghijklmnopqrstuvwxyz"

local function base36(decimal)
  local output = ""
  repeat
    local quotient, remainder, started = {}, 0, false
    for digit in decimal:gmatch("%d") do
      local value = remainder * 10 + tonumber(digit)
      local next_digit = math.floor(value / 36)
      remainder = value % 36
      if next_digit ~= 0 or started then
        quotient[#quotient + 1] = tostring(next_digit)
        started = true
      end
    end
    output = BASE36:sub(remainder + 1, remainder + 1) .. output
    decimal = table.concat(quotient)
  until decimal == ""
  return output
end

local function money_id(internal_id)
  if type(internal_id) ~= "string" or not internal_id:match("^E%d+$") then return nil end
  return "M" .. base36(internal_id:sub(2))
end

local function public_record(entry)
  local copy = {}
  for key, value in pairs(entry) do copy[key] = value end
  copy.money_id = copy.money_id or money_id(copy.id)
  return copy
end

local function amount(value, available)
  if value == "all" or value == "max" then value = available end
  if type(value) == "string" and value:match("^%d+$") and #value <= 13 then value = tonumber(value) end
  if type(value) ~= "number" or value ~= value or value % 1 ~= 0 or value < 1 or value > MAX then return nil end
  return value
end

local function account(data, id, create)
  local a = data.accounts[id]
  if not a and create then
    local count = 0; for _ in pairs(data.accounts) do count = count + 1 end
    if count >= MAX_ACCOUNTS then return nil end
    a = { wallet = 0, bank = 0, daily = 0, weekly = 0, work = 0 }
    data.accounts[id] = a
  end
  if not a then return { wallet = 0, bank = 0, daily = 0, weekly = 0, work = 0 } end
  if type(a.wallet) ~= "number" or type(a.bank) ~= "number" or a.wallet < 0 or a.bank < 0
    or a.wallet > MAX or a.bank > MAX or a.wallet % 1 ~= 0 or a.bank % 1 ~= 0 then return nil end
  return a
end

function Ledger.new(store, clock) return setmetatable({ store = store, clock = clock or os.time }, Ledger) end

function Ledger:balance(guild, user)
  if not Store.valid_id(user) then return false, "invalid_user" end
  return self.store:run(guild, function(data)
    local a = account(data, user, false)
    if not a then return false, "invalid_store" end
    return true, { wallet = a.wallet, bank = a.bank }, false
  end)
end

function Ledger:history(guild, user)
  if not Store.valid_id(user) then return false, "invalid_user" end
  return self.store:run(guild, function(data)
    local entries = {}
    for i = #data.journal, 1, -1 do
      local entry = data.journal[i]
      if entry.user == user or entry.counterparty == user then entries[#entries + 1] = public_record(entry) end
      if #entries == 10 then break end
    end
    return true, entries, false
  end)
end

-- The persisted E-prefixed journal ID remains canonical. A deterministic base-36
-- alias is exposed as the shorter Money ID; legacy journal rows need no migration.
function Ledger:transaction(guild, id)
  if type(id) ~= "string" or #id < 2 or #id > 21 then
    return false, "invalid_transaction"
  end
  local lookup = id:match("^[Ee]%d+$") and id:sub(1, 1):upper() .. id:sub(2) or id
  if not lookup:match("^E%d+$") and not lookup:match("^[Mm][%da-zA-Z]+$") then return false, "invalid_transaction" end
  lookup = lookup:sub(1, 1):upper() .. lookup:sub(2):lower()
  return self.store:run(guild, function(data)
    for i = #data.journal, 1, -1 do
      local entry = data.journal[i]
      if type(entry) == "table" and (entry.id == lookup or money_id(entry.id) == lookup) then
        return true, public_record(entry), false
      end
    end
    return false, "transaction_not_found"
  end)
end

function Ledger:leaderboard(guild)
  return self.store:run(guild, function(data)
    local entries = {}
    for id in pairs(data.accounts) do
      local a = account(data, id, false)
      if not a then return false, "invalid_store" end
      entries[#entries + 1] = { user = id, total = a.wallet + a.bank }
    end
    table.sort(entries, function(a, b) if a.total == b.total then return a.user < b.user end return a.total > b.total end)
    while #entries > 10 do table.remove(entries) end
    return true, entries, false
  end)
end

function Ledger:change(guild, user, interaction, kind, input, other)
  if not Store.valid_id(user) or not Store.valid_id(interaction) then return false, "invalid_user" end
  if kind == "pay" and (not Store.valid_id(other) or other == user) then return false, "invalid_target" end
  return self.store:run(guild, function(data)
    if data.receipts[interaction] then
      local previous = public_record(data.receipts[interaction])
      previous.money_id = previous.money_id or money_id("E" .. interaction)
      return true, previous, false
    end
    if #data.journal >= MAX_RECORDS then return false, "capacity" end
    local a = account(data, user, true)
    if not a then return false, "capacity" end
    local value, now = nil, self.clock()
    if kind == "deposit" then
      value = amount(input, a.wallet)
      if not value then return false, "invalid_amount" end
      if value > a.wallet then return false, "insufficient" end
      if a.bank + value > MAX then return false, "overflow" end
      a.wallet, a.bank = a.wallet - value, a.bank + value
    elseif kind == "withdraw" then
      value = amount(input, a.bank)
      if not value then return false, "invalid_amount" end
      if value > a.bank then return false, "insufficient" end
      if a.wallet + value > MAX then return false, "overflow" end
      a.bank, a.wallet = a.bank - value, a.wallet + value
    elseif kind == "pay" then
      value = amount(input, a.wallet)
      if not value then return false, "invalid_amount" end
      if value > a.wallet then return false, "insufficient" end
      local b = account(data, other, true)
      if not b then return false, "capacity" end
      if b.wallet + value > MAX then return false, "overflow" end
      a.wallet, b.wallet = a.wallet - value, b.wallet + value
    else
      local rewards = { daily = { 100, 86400 }, weekly = { 500, 604800 }, work = { 20, 3600 } }
      local spec = rewards[kind]
      if not spec then return false, "invalid_action" end
      local last = a[kind] or 0
      if type(last) ~= "number" or last < 0 or now < last or (last > 0 and now - last < spec[2]) then return false, "cooldown" end
      value = spec[1]
      if a.wallet + value > MAX then return false, "overflow" end
      a.wallet, a[kind] = a.wallet + value, now
    end
    local record = { id = "E" .. interaction, guild = guild, user = user, kind = kind,
      amount = value, counterparty = other or "", timestamp = now, status = "committed" }
    data.journal[#data.journal + 1] = record
    local result = { id = record.id, money_id = money_id(record.id), amount = value, wallet = a.wallet, bank = a.bank }
    data.receipts[interaction] = result
    return true, result, true
  end)
end

return Ledger
