local Store = require("src.persistence.guild_store")
local InventoryData = require("src.economy.inventory_data")
local Ledger = {}
Ledger.__index = Ledger
local MAX = 1000000000000
local MAX_RECORDS = 1000
local MAX_ACCOUNTS = 200
local MAX_HISTORY = 20
local MINING_COOLDOWN = 30
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
  if type(internal_id) ~= "string" then return nil end
  local interaction_id = internal_id:match("^E(%d+)$")
  if interaction_id then return "M" .. base36(interaction_id) end
  local message_id = internal_id:match("^EP(%d+)$")
  if message_id then return "Mp-" .. base36(message_id) end
  return nil
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

function Ledger.new(store, clock, random)
  return setmetatable({ store = store, clock = clock or os.time, random = random or math.random }, Ledger)
end

function Ledger:balance(guild, user)
  if not Store.valid_id(user) then return false, "invalid_user" end
  return self.store:run(guild, function(data)
    local a = account(data, user, false)
    if not a then return false, "invalid_store" end
    return true, { wallet = a.wallet, bank = a.bank }, false
  end)
end

function Ledger:history(guild, user, limit)
  if not Store.valid_id(user) then return false, "invalid_user" end
  limit = tonumber(limit) or 10
  limit = math.max(1, math.min(MAX_HISTORY, math.floor(limit)))
  return self.store:run(guild, function(data)
    local entries = {}
    for i = #data.journal, 1, -1 do
      local entry = data.journal[i]
      if entry.user == user or entry.counterparty == user then entries[#entries + 1] = public_record(entry) end
      if #entries == limit then break end
    end
    return true, entries, false
  end)
end

-- The persisted E-prefixed journal ID remains canonical. A deterministic base-36
-- alias is exposed as the shorter Money ID; legacy journal rows need no migration.
function Ledger:transaction(guild, id)
  if type(id) ~= "string" or #id < 2 or #id > 32 then
    return false, "invalid_transaction"
  end
  local lookup = id
  if id:match("^[Ee][Pp]%d+$") then
    lookup = "EP" .. id:sub(3)
  elseif id:match("^[Ee]%d+$") then
    lookup = "E" .. id:sub(2)
  elseif id:match("^[Mm][%da-zA-Z%-]+$") then
    local prefix_id = id:sub(2):lower()
    lookup = "M" .. prefix_id
  else
    return false, "invalid_transaction"
  end
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

function Ledger:change(guild, user, interaction, kind, input, other, request_type)
  if not Store.valid_id(user) or not Store.valid_id(interaction) then return false, "invalid_user" end
  if kind == "pay" and (not Store.valid_id(other) or other == user) then return false, "invalid_target" end
  request_type = request_type or "interaction"
  if request_type ~= "interaction" and request_type ~= "message" then return false, "invalid_request" end
  local receipt_key = request_type == "message" and ("message:" .. interaction) or interaction
  local record_id = (request_type == "message" and "EP" or "E") .. interaction
  return self.store:run(guild, function(data)
    if data.receipts[receipt_key] then
      local receipt = data.receipts[receipt_key]
      if type(receipt) ~= "table" then return false, "invalid_store" end
      if receipt.operation then return false, "replay_conflict" end
      local previous = public_record(receipt)
      previous.money_id = previous.money_id or money_id(record_id)
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
    local record = { id = record_id, guild = guild, user = user, kind = kind,
      amount = value, counterparty = other or "", timestamp = now, status = "committed" }
    data.journal[#data.journal + 1] = record
    local result = { id = record.id, money_id = money_id(record.id), amount = value, wallet = a.wallet, bank = a.bank }
    data.receipts[receipt_key] = result
    return true, result, true
  end)
end

-- A shop purchase moves coins, writes the canonical Money-ID journal row,
-- records its retry receipt, and grants inventory in the same guild transaction.
function Ledger:purchase(guild, user, interaction, item_id, price, quantity, request_type)
  if not Store.valid_id(user) or not Store.valid_id(interaction) or not InventoryData.valid_item(item_id) then
    return false, "invalid_argument"
  end
  if type(price) ~= "number" or price % 1 ~= 0 or price < 1 or price > MAX
    or type(quantity) ~= "number" or quantity % 1 ~= 0 or quantity < 1 or quantity > 99
    or price > math.floor(MAX / quantity) then return false, "invalid_amount" end
  request_type = request_type or "interaction"
  if request_type ~= "interaction" and request_type ~= "message" then return false, "invalid_request" end
  local receipt_key = request_type == "message" and ("message:" .. interaction) or interaction
  local record_id = (request_type == "message" and "EP" or "E") .. interaction
  local total = price * quantity
  return self.store:run(guild, function(data)
    if data.receipts[receipt_key] then
      local receipt = data.receipts[receipt_key]
      if type(receipt) ~= "table" then return false, "invalid_store" end
      if receipt.operation ~= "purchase" or receipt.user ~= user or receipt.item_id ~= item_id or receipt.quantity ~= quantity then
        return false, "replay_conflict"
      end
      local previous = public_record(receipt)
      previous.money_id = previous.money_id or money_id(record_id)
      return true, previous, false
    end
    if #data.journal >= MAX_RECORDS then return false, "capacity" end
    local a = account(data, user, true)
    if not a then return false, "capacity" end
    if a.wallet < total then return false, "insufficient" end
    local added, inventory = InventoryData.add(data, user, item_id, quantity)
    if not added then return false, inventory end
    local now = self.clock()
    a.wallet = a.wallet - total
    local record = { id = record_id, guild = guild, user = user, kind = "purchase",
      amount = total, counterparty = item_id, timestamp = now, status = "committed" }
    data.journal[#data.journal + 1] = record
    local result = { id = record.id, money_id = money_id(record.id), amount = total, wallet = a.wallet,
      bank = a.bank, operation = "purchase", user = user, item_id = item_id, quantity = quantity }
    data.receipts[receipt_key] = result
    return true, result, true
  end)
end

function Ledger:sell(guild, user, interaction, item_id, quantity, request_type)
  local Catalog = require("src.economy.catalog")
  if not Store.valid_id(user) or not Store.valid_id(interaction) then return false, "invalid_argument" end
  local item = Catalog.get_resource(item_id)
  if not item or type(quantity) ~= "number" or quantity % 1 ~= 0 or quantity < 1 or quantity > 99
    or item.sell_price > math.floor(MAX / quantity) then return false, "invalid_amount" end
  request_type = request_type or "interaction"
  if request_type ~= "interaction" and request_type ~= "message" then return false, "invalid_request" end
  local receipt_key = request_type == "message" and ("message:" .. interaction) or interaction
  local record_id = (request_type == "message" and "EP" or "E") .. interaction
  local total = item.sell_price * quantity
  return self.store:run(guild, function(data)
    if data.receipts[receipt_key] then
      local receipt = data.receipts[receipt_key]
      if type(receipt) ~= "table" then return false, "invalid_store" end
      if receipt.operation ~= "sale" or receipt.user ~= user or receipt.item_id ~= item_id or receipt.quantity ~= quantity then
        return false, "replay_conflict"
      end
      local previous = public_record(receipt)
      previous.money_id = previous.money_id or money_id(record_id)
      return true, previous, false
    end
    if #data.journal >= MAX_RECORDS then return false, "capacity" end
    local a = account(data, user, true)
    if not a then return false, "capacity" end
    if a.wallet + total > MAX then return false, "overflow" end
    local removed, inventory = InventoryData.remove(data, user, item_id, quantity)
    if not removed then return false, inventory end
    local now = self.clock()
    a.wallet = a.wallet + total
    local record = { id = record_id, guild = guild, user = user, kind = "sale",
      amount = total, counterparty = item_id, timestamp = now, status = "committed" }
    data.journal[#data.journal + 1] = record
    local result = { id = record.id, money_id = money_id(record.id), amount = total, wallet = a.wallet,
      bank = a.bank, operation = "sale", user = user, item_id = item_id,
      quantity = quantity, price_each = item.sell_price }
    data.receipts[receipt_key] = result
    return true, result, true
  end)
end

function Ledger:mine(guild, user, interaction, request_type)
  if not Store.valid_id(user) or not Store.valid_id(interaction) then return false, "invalid_argument" end
  request_type = request_type or "interaction"
  if request_type ~= "interaction" and request_type ~= "message" then return false, "invalid_request" end
  local receipt_key = request_type == "message" and ("message:" .. interaction) or interaction
  local record_id = (request_type == "message" and "EP" or "E") .. interaction
  return self.store:run(guild, function(data)
    if data.receipts[receipt_key] then
      local receipt = data.receipts[receipt_key]
      if type(receipt) ~= "table" then return false, "invalid_store" end
      if receipt.operation ~= "mine" or receipt.user ~= user then return false, "replay_conflict" end
      local previous = public_record(receipt)
      previous.money_id = previous.money_id or money_id(record_id)
      return true, previous, false
    end
    if #data.journal >= MAX_RECORDS then return false, "capacity" end
    local a = account(data, user, true)
    if not a then return false, "capacity" end
    local now = self.clock()
    local last = a.last_mine
    if last == nil then last = 0 end
    if type(now) ~= "number" or now ~= now or now == math.huge or now == -math.huge or now < 0
      or type(last) ~= "number" or last ~= last or last == math.huge or last == -math.huge or last < 0 or now < last then
      return false, "invalid_store"
    end
    if last > 0 and now - last < MINING_COOLDOWN then return false, "cooldown" end
    local inventory, reason = InventoryData.get(data, user)
    if not inventory then return false, reason end
    if (inventory.items.pickaxe or 0) < 1 then return false, "pickaxe_required" end
    local called, roll = pcall(self.random, 1, 100)
    if not called or type(roll) ~= "number" or roll % 1 ~= 0 or roll < 1 or roll > 100 then
      return false, "random_unavailable"
    end
    local item_id = roll <= 60 and "copper_ore" or (roll <= 90 and "iron_ore" or "crystal_shard")
    called, roll = pcall(self.random, 1, item_id == "crystal_shard" and 1 or 3)
    if not called or type(roll) ~= "number" or roll % 1 ~= 0 or roll < 1
      or roll > (item_id == "crystal_shard" and 1 or 3) then return false, "random_unavailable" end
    local quantity = roll
    local added, add_reason = InventoryData.add(data, user, item_id, quantity)
    if not added then return false, add_reason end
    a.last_mine = now
    local record = { id = record_id, guild = guild, user = user, kind = "mine",
      amount = 0, counterparty = item_id, timestamp = now, status = "committed" }
    data.journal[#data.journal + 1] = record
    local result = { id = record.id, money_id = money_id(record.id), amount = 0, wallet = a.wallet,
      bank = a.bank, operation = "mine", user = user, item_id = item_id,
      quantity = quantity, cooldown_seconds = MINING_COOLDOWN }
    data.receipts[receipt_key] = result
    return true, result, true
  end)
end

Ledger.mining_cooldown = MINING_COOLDOWN
return Ledger
