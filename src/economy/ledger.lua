local Store = require("src.persistence.guild_store")
local InventoryData = require("src.economy.inventory_data")
local Ledger = {}
Ledger.__index = Ledger
local MAX = 1000000000000
local MAX_JOURNAL_RECORDS = 1000
local MAX_ECONOMY_RECEIPTS = 1000
local MAX_HISTORY = 20
local MINING_COOLDOWN = 30
local MAX_CACHED_RECEIPT_INDEXES = 8
local MAX_RECEIPT_GENERATION = 9007199254740991
local BASE36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local REWARDS = {
  daily = { minimum = 1500, maximum = 3500, cooldown = 86400, streak_window = 172800,
    milestones = { { streak = 5, bonus = 250 }, { streak = 10, bonus = 500 }, { streak = 25, bonus = 750 } } },
  weekly = { minimum = 6000, maximum = 12000, cooldown = 604800, streak_window = 1209600,
    milestones = { { streak = 4, bonus = 1500 }, { streak = 12, bonus = 3000 } } },
  work = { minimum = 400, maximum = 1800, cooldown = 21600 },
}

local function streak_bonus(spec, streak)
  local bonus = 0
  for _, milestone in ipairs(spec.milestones or {}) do
    if streak >= milestone.streak then bonus = milestone.bonus end
  end
  return bonus
end

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
    -- Account balances are live financial state, not disposable history. Do not
    -- hard-cap guild accounts: evicting them loses money and refusing new IDs
    -- permanently blocks later participants.
    a = { wallet = 0, bank = 0, daily = 0, weekly = 0, work = 0, daily_claimed = false,
      weekly_claimed = false, work_claimed = false, daily_streak = 0, weekly_streak = 0 }
    data.accounts[id] = a
  end
  if not a then return { wallet = 0, bank = 0, daily = 0, weekly = 0, work = 0 } end
  if type(a.wallet) ~= "number" or type(a.bank) ~= "number" or a.wallet < 0 or a.bank < 0
    or a.wallet > MAX or a.bank > MAX or a.wallet % 1 ~= 0 or a.bank % 1 ~= 0 then return nil end
  return a
end

local function normalize_decimal(value)
  if type(value) ~= "string" or not value:match("^%d+$") then return nil end
  local result = value:gsub("^0+", "")
  return result == "" and "0" or result
end

local function compare_decimal(left, right)
  left, right = normalize_decimal(left), normalize_decimal(right)
  if not left or not right then return nil end
  if #left < #right then return -1 end
  if #left > #right then return 1 end
  if left < right then return -1 end
  if left > right then return 1 end
  return 0
end

local function receipt_key(request_type, request_id)
  return request_type .. ":" .. request_id
end

local function parse_receipt_key(key)
  if type(key) ~= "string" then return nil end
  local id = key:match("^interaction:(%d+)$")
  if id and Store.valid_id(id) then return "interaction", id end
  id = key:match("^message:(%d+)$")
  if id and Store.valid_id(id) then return "message", id end
  return nil
end

local function receipt_item_less(left, right)
  local compared = compare_decimal(left.request_id, right.request_id)
  if compared ~= 0 then return compared < 0 end
  if left.request_type ~= right.request_type then return left.request_type < right.request_type end
  return left.request_id < right.request_id
end

local function advance_watermark(watermarks, request_type, request_id)
  local current = watermarks[request_type]
  if not current or current == "" or compare_decimal(request_id, current) > 0 then
    watermarks[request_type] = normalize_decimal(request_id)
  end
end

local function heap_insert(heap, item)
  heap[#heap + 1] = item
  local index = #heap
  while index > 1 do
    local parent = math.floor(index / 2)
    if not receipt_item_less(heap[index], heap[parent]) then break end
    heap[index], heap[parent] = heap[parent], heap[index]
    index = parent
  end
end

local function heap_push_retained(heap, item, watermarks)
  if #heap < MAX_ECONOMY_RECEIPTS then
    heap_insert(heap, item)
    return
  end
  if not receipt_item_less(heap[1], item) then
    advance_watermark(watermarks, item.request_type, item.request_id)
    return
  end
  advance_watermark(watermarks, heap[1].request_type, heap[1].request_id)
  heap[1] = item
  local index = 1
  while true do
    local left, right = index * 2, index * 2 + 1
    local smallest = index
    if left <= #heap and receipt_item_less(heap[left], heap[smallest]) then smallest = left end
    if right <= #heap and receipt_item_less(heap[right], heap[smallest]) then smallest = right end
    if smallest == index then break end
    heap[index], heap[smallest] = heap[smallest], heap[index]
    index = smallest
  end
end

local function heap_pop_min(heap)
  if #heap == 0 then return nil end
  local first, last = heap[1], heap[#heap]
  heap[#heap] = nil
  if #heap > 0 then
    heap[1] = last
    local index = 1
    while true do
      local left, right = index * 2, index * 2 + 1
      local smallest = index
      if left <= #heap and receipt_item_less(heap[left], heap[smallest]) then smallest = left end
      if right <= #heap and receipt_item_less(heap[right], heap[smallest]) then smallest = right end
      if smallest == index then break end
      heap[index], heap[smallest] = heap[smallest], heap[index]
      index = smallest
    end
  end
  return first
end

local function valid_generation(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= MAX_RECEIPT_GENERATION
end

local function valid_receipt_count(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= MAX_ECONOMY_RECEIPTS
end

local function legacy_receipt_identity(key, receipt)
  if type(key) ~= "string" or type(receipt) ~= "table" or type(receipt.id) ~= "string" then return nil end
  local request_type, request_id
  request_id = key:match("^message:(%d+)$")
  if request_id then
    request_type = "message"
    if receipt.id ~= "EP" .. request_id then return nil end
  else
    request_id = key:match("^(%d+)$")
    if not request_id then return nil end
    request_type = "interaction"
    if receipt.id ~= "E" .. request_id then return nil end
  end
  if not Store.valid_id(request_id) then return nil end
  return request_type, request_id
end

local function journal_record(data, transaction_id)
  for index = #data.journal, 1, -1 do
    local entry = data.journal[index]
    if type(entry) == "table" and entry.id == transaction_id then return entry end
  end
end

local function legacy_fingerprint(data, guild, request_type, request_id, receipt)
  local operation = receipt.operation
  local source = receipt.user
  local fingerprint = { guild = guild, request_id = request_id, request_type = request_type,
    operation = operation, source = source }
  if operation == "purchase" or operation == "sale" then
    if not Store.valid_id(source) or type(receipt.item_id) ~= "string"
      or type(receipt.quantity) ~= "number" or type(receipt.amount) ~= "number" then
      fingerprint.operation = "legacy_opaque"
    else
      fingerprint.item_id, fingerprint.quantity, fingerprint.amount = receipt.item_id, receipt.quantity, receipt.amount
    end
    return fingerprint
  elseif operation == "mine" then
    if not Store.valid_id(source) then fingerprint.operation = "legacy_opaque" end
    return fingerprint
  end

  local entry = journal_record(data, receipt.id)
  if type(entry) ~= "table" or entry.guild ~= guild or not Store.valid_id(entry.user) then
    fingerprint.operation = "legacy_opaque"
    return fingerprint
  end
  operation, source = entry.kind, entry.user
  fingerprint.operation, fingerprint.source = operation, source
  if operation == "pay" then fingerprint.target = entry.counterparty end
  if operation == "pay" or operation == "deposit" or operation == "withdraw" then
    fingerprint.amount, fingerprint.legacy_effective_amount = entry.amount, true
  elseif operation ~= "daily" and operation ~= "weekly" and operation ~= "work" then
    fingerprint.operation = "legacy_opaque"
  end
  return fingerprint
end

local function legacy_envelope(data, guild, request_type, request_id, receipt)
  return { request_type = request_type, request_id = request_id,
    fingerprint = legacy_fingerprint(data, guild, request_type, request_id, receipt),
    result = public_record(receipt) }
end

local function valid_envelope(key, envelope)
  local request_type, request_id = parse_receipt_key(key)
  if not request_type or type(envelope) ~= "table" or envelope.request_type ~= request_type
    or envelope.request_id ~= request_id or type(envelope.fingerprint) ~= "table"
    or type(envelope.result) ~= "table" then return false end
  local expected_id = request_type == "message" and ("EP" .. request_id) or ("E" .. request_id)
  return envelope.result.id == expected_id
end

local function valid_watermarks(value)
  if type(value) ~= "table" then return false end
  for key, item in pairs(value) do
    if (key ~= "interaction" and key ~= "message")
      or type(item) ~= "string" or (item ~= "" and not normalize_decimal(item)) then return false end
  end
  return true
end

local function prepare_receipts(data, guild, cached)
  if type(data.receipts) ~= "table" then return nil, "invalid_store" end
  if data.economy_receipts ~= nil and type(data.economy_receipts) ~= "table" then return nil, "invalid_store" end
  if data.economy_receipt_watermarks ~= nil and not valid_watermarks(data.economy_receipt_watermarks) then
    return nil, "invalid_store"
  end
  if data.economy_receipts_migrated ~= nil and type(data.economy_receipts_migrated) ~= "boolean" then
    return nil, "invalid_store"
  end

  local changed = false
  local receipts = data.economy_receipts or {}
  local watermarks = data.economy_receipt_watermarks or {}
  if data.economy_receipts == nil or data.economy_receipt_watermarks == nil then changed = true end
  if watermarks.interaction == nil or watermarks.message == nil then changed = true end
  watermarks.interaction, watermarks.message = watermarks.interaction or "", watermarks.message or ""

  local generation = data.economy_receipt_generation
  local generation_present = generation ~= nil
  if generation == nil then
    generation = 0
    changed = true
  elseif not valid_generation(generation) then
    return nil, "invalid_store"
  end

  local count = data.economy_receipt_count
  local cache_valid = generation_present and data.economy_receipts_migrated == true and valid_receipt_count(count)
    and type(cached) == "table" and cached.generation == generation and cached.count == count
    and type(cached.heap) == "table" and #cached.heap == count
  if cache_valid and count > 0 then
    local oldest = cached.heap[1]
    cache_valid = type(oldest) == "table" and type(oldest.key) == "string"
      and valid_envelope(oldest.key, receipts[oldest.key])
  end
  if cache_valid then
    data.economy_receipts, data.economy_receipt_count = receipts, count
    data.economy_receipt_watermarks, data.economy_receipt_generation = watermarks, generation
    return changed, cached
  end

  local heap, actual_count = {}, 0
  for key, envelope in pairs(receipts) do
    local request_type, request_id = parse_receipt_key(key)
    if not request_type or not valid_envelope(key, envelope) then return nil, "invalid_store" end
    actual_count = actual_count + 1
    heap_push_retained(heap, { key = key, request_type = request_type, request_id = request_id, envelope = envelope }, watermarks)
  end

  if data.economy_receipts_migrated ~= true then
    for key, receipt in pairs(data.receipts) do
      local request_type, request_id = legacy_receipt_identity(key, receipt)
      if request_type then
        local new_key = receipt_key(request_type, request_id)
        if receipts[new_key] == nil then
          heap_push_retained(heap, { key = new_key, request_type = request_type, request_id = request_id,
            envelope = legacy_envelope(data, guild, request_type, request_id, receipt) }, watermarks)
          actual_count = actual_count + 1
        end
        data.receipts[key] = nil
        changed = true
      end
    end
    data.economy_receipts_migrated = true
    changed = true
  end

  if actual_count > MAX_ECONOMY_RECEIPTS or not valid_receipt_count(count) or count ~= actual_count then
    changed = true
  end
  local retained = {}
  for _, item in ipairs(heap) do retained[item.key] = item.envelope end
  if changed then
    data.economy_receipts = retained
  else
    data.economy_receipts = receipts
  end
  data.economy_receipt_count = #heap
  data.economy_receipt_watermarks = watermarks
  data.economy_receipt_generation = generation
  local index = { heap = heap, generation = generation, count = #heap }
  return changed, index
end

local function fingerprint_matches(stored, requested)
  if type(stored) ~= "table" or stored.operation == "legacy_opaque" then return false end
  local keys = { "guild", "request_id", "request_type", "operation", "source", "target",
    "amount", "item_id", "quantity" }
  for _, key in ipairs(keys) do
    if key == "amount" and stored.legacy_effective_amount then
      if type(requested.amount) ~= "number" or requested.amount ~= stored.amount then return false end
    elseif stored[key] ~= requested[key] then return false end
  end
  local left, right = stored.price_snapshot, requested.price_snapshot
  if (left == nil) ~= (right == nil) then return false end
  if left then
    for _, key in ipairs({ "eu_cents", "us_cents", "fx_usd_per_eur_x10000", "fx_as_of",
      "fx_source", "rounding", "coin_price", "checked_at" }) do
      if left[key] ~= right[key] then return false end
    end
  end
  return true
end

local function check_request(data, guild, request_type, request_id, fingerprint, cached)
  local changed, index = prepare_receipts(data, guild, cached)
  if changed == nil then return false, index end
  local key = receipt_key(request_type, request_id)
  local receipt = data.economy_receipts[key]
  if receipt then
    if not valid_envelope(key, receipt) then return false, "invalid_store", changed, nil, index end
    if not fingerprint_matches(receipt.fingerprint, fingerprint) then
      return false, "replay_conflict", changed, nil, index
    end
    local result = public_record(receipt.result)
    return true, result, changed, nil, index
  end
  local watermark = data.economy_receipt_watermarks[request_type]
  if watermark ~= "" and compare_decimal(request_id, watermark) <= 0 then
    return false, "replay_expired", changed, nil, index
  end
  local oldest
  if index.count >= MAX_ECONOMY_RECEIPTS then
    oldest = index.heap[1]
    if not oldest or not valid_envelope(oldest.key, data.economy_receipts[oldest.key]) then
      return false, "invalid_store", changed, nil, index
    end
    local candidate = { request_type = request_type, request_id = request_id }
    if not receipt_item_less(oldest, candidate) then
      return false, "replay_expired", changed, nil, index
    end
  end
  return nil, nil, changed, oldest, index
end

local function save_receipt(data, request_type, request_id, fingerprint, result, oldest, index)
  if type(index) ~= "table" or type(index.heap) ~= "table" or index.count ~= #index.heap
    or not valid_generation(index.generation) or index.generation >= MAX_RECEIPT_GENERATION then
    return false
  end
  local count, evicted = index.count, nil
  if count >= MAX_ECONOMY_RECEIPTS then
    oldest = oldest or index.heap[1]
    if not oldest or not valid_envelope(oldest.key, data.economy_receipts[oldest.key]) then return false end
    if not index.heap[1] or index.heap[1].key ~= oldest.key then return false end
    data.economy_receipts[oldest.key] = nil
    advance_watermark(data.economy_receipt_watermarks, oldest.request_type, oldest.request_id)
    evicted = { key = oldest.key, request_type = oldest.request_type, request_id = oldest.request_id }
    count = count - 1
  end
  local key = receipt_key(request_type, request_id)
  data.economy_receipts[key] = { request_type = request_type, request_id = request_id,
    fingerprint = fingerprint, result = public_record(result) }
  count = count + 1
  data.economy_receipt_count = count
  data.economy_receipt_generation = index.generation + 1
  return true, {
    base_generation = index.generation, base_count = index.count, evicted = evicted,
    item = { key = key, request_type = request_type, request_id = request_id },
    generation = index.generation + 1, count = count,
  }
end

local function apply_receipt_delta(index, delta)
  if type(index) ~= "table" or type(delta) ~= "table"
    or index.generation ~= delta.base_generation or index.count ~= delta.base_count
    or #index.heap ~= index.count then return false end
  if delta.evicted then
    local removed = heap_pop_min(index.heap)
    if not removed or removed.key ~= delta.evicted.key then return false end
  elseif index.count >= MAX_ECONOMY_RECEIPTS then
    return false
  end
  heap_insert(index.heap, delta.item)
  index.generation, index.count = delta.generation, delta.count
  return #index.heap == index.count
end

local function append_journal(data, record)
  data.journal[#data.journal + 1] = record
  while #data.journal > MAX_JOURNAL_RECORDS do table.remove(data.journal, 1) end
end

local function request_amount(value)
  if value == "all" or value == "max" then return "all" end
  if type(value) == "number" and value % 1 == 0 and value >= 1 and value <= MAX then return value end
  if type(value) == "string" and #value <= 13 and value:match("^%d+$") then
    local number = tonumber(value)
    if number and number >= 1 and number <= MAX and number % 1 == 0 then return number end
  end
  return "<invalid>"
end

function Ledger.new(store, clock, random)
  return setmetatable({ store = store, clock = clock or os.time, random = random or math.random,
    receipt_indexes = {}, receipt_index_clock = 0 }, Ledger)
end

function Ledger:_remember_receipt_index(guild, index)
  if type(index) ~= "table" then return end
  self.receipt_index_clock = self.receipt_index_clock + 1
  local current = self.receipt_indexes[guild]
  if not current then
    local count, oldest_guild, oldest_used = 0, nil, math.huge
    for key, cached in pairs(self.receipt_indexes) do
      count = count + 1
      if cached.last_used < oldest_used then oldest_guild, oldest_used = key, cached.last_used end
    end
    if count >= MAX_CACHED_RECEIPT_INDEXES then self.receipt_indexes[oldest_guild] = nil end
  end
  index.last_used = self.receipt_index_clock
  self.receipt_indexes[guild] = index
end

function Ledger:_run_with_receipts(guild, callback)
  local candidate, candidate_safe, candidate_delta
  local ok, result = self.store:run(guild, function(data)
    return callback(data, self.receipt_indexes[guild], function(index, safe_without_commit, delta)
      if index then candidate, candidate_safe, candidate_delta = index, safe_without_commit, delta end
    end)
  end)
  if candidate and ok then
    if not candidate_delta or apply_receipt_delta(candidate, candidate_delta) then
      self:_remember_receipt_index(guild, candidate)
    elseif self.receipt_indexes[guild] == candidate then
      self.receipt_indexes[guild] = nil
    end
  elseif candidate and candidate_safe then
    self:_remember_receipt_index(guild, candidate)
  end
  return ok, result
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
  request_type = request_type or "interaction"
  if request_type ~= "interaction" and request_type ~= "message" then return false, "invalid_request" end
  local record_id = (request_type == "message" and "EP" or "E") .. interaction
  local base_reward_result, streak_result, streak_bonus_result
  local fingerprint = { guild = guild, request_id = interaction, request_type = request_type,
    operation = kind, source = user, target = kind == "pay" and other or nil,
    amount = (kind == "pay" or kind == "deposit" or kind == "withdraw") and request_amount(input) or nil }
  return self:_run_with_receipts(guild, function(data, cached, remember)
    local request_state, prior, changed, oldest, index = check_request(data, guild, request_type, interaction, fingerprint, cached)
    remember(index, not changed)
    if request_state ~= nil then return request_state, prior, changed end
    if kind == "pay" and (not Store.valid_id(other) or other == user) then return false, "invalid_target" end
    local a = account(data, user, true)
    if not a then return false, "invalid_store" end
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
      if not b then return false, "invalid_store" end
      if b.wallet + value > MAX then return false, "overflow" end
      a.wallet, b.wallet = a.wallet - value, b.wallet + value
    else
      local spec = REWARDS[kind]
      if not spec then return false, "invalid_action" end
      local last = a[kind] or 0
      local claim_key = kind .. "_claimed"
      local claimed = a[claim_key]
      if claimed ~= nil and type(claimed) ~= "boolean" then return false, "invalid_store" end
      if claimed == nil then claimed = last > 0 end
      if type(now) ~= "number" or now ~= now or now == math.huge or now == -math.huge
        or type(last) ~= "number" or last ~= last or last < 0 or now < last
        or (claimed and now - last < spec.cooldown) then return false, "cooldown" end
      local random_ok, reward = pcall(self.random, spec.minimum, spec.maximum)
      if not random_ok or type(reward) ~= "number" or reward % 1 ~= 0
        or reward < spec.minimum or reward > spec.maximum then return false, "random_unavailable" end
      value = reward
      base_reward_result = reward
      local streak, bonus = nil, 0
      if spec.milestones then
        local streak_key = kind .. "_streak"
        local previous_streak = a[streak_key]
        if previous_streak ~= nil and (type(previous_streak) ~= "number" or previous_streak % 1 ~= 0
          or previous_streak < 0 or previous_streak > 1000000) then return false, "invalid_store" end
        previous_streak = previous_streak or (claimed and 1 or 0)
        streak = claimed and now - last <= spec.streak_window and previous_streak + 1 or 1
        bonus = streak_bonus(spec, streak)
        value = value + bonus
        a[streak_key] = streak
        streak_result, streak_bonus_result = streak, bonus
      end
      if a.wallet + value > MAX then return false, "overflow" end
      a.wallet, a[kind] = a.wallet + value, now
      a[claim_key] = true
    end
    local record = { id = record_id, guild = guild, user = user, kind = kind,
      amount = value, counterparty = other or "", timestamp = now, status = "committed" }
    append_journal(data, record)
    local result = { id = record.id, money_id = money_id(record.id), amount = value, wallet = a.wallet, bank = a.bank }
    if kind == "daily" or kind == "weekly" then
      result.base_reward, result.streak, result.streak_bonus = base_reward_result, streak_result, streak_bonus_result or 0
    end
    local saved, receipt_delta = save_receipt(data, request_type, interaction, fingerprint, result, oldest, index)
    if not saved then return false, "invalid_store" end
    remember(index, false, receipt_delta)
    return true, result, true
  end)
end

-- A shop purchase moves coins, writes the canonical Money-ID journal row,
-- records its retry receipt, and grants inventory in the same guild transaction.
function Ledger:purchase(guild, user, interaction, item_id, price, quantity, request_type, price_snapshot)
  if not Store.valid_id(user) or not Store.valid_id(interaction) then return false, "invalid_argument" end
  request_type = request_type or "interaction"
  if request_type ~= "interaction" and request_type ~= "message" then return false, "invalid_request" end
  local total
  if type(price) == "number" and price % 1 == 0 and price >= 1 and price <= MAX
    and type(quantity) == "number" and quantity % 1 == 0 and quantity >= 1 and quantity <= 99
    and price <= math.floor(MAX / quantity) then total = price * quantity end
  local record_id = (request_type == "message" and "EP" or "E") .. interaction
  if price_snapshot ~= nil then
    local RetailPricing = require("src.economy.retail_pricing")
    if not RetailPricing.valid_snapshot(price_snapshot, price) then return false, "invalid_price_snapshot" end
  end
  local fingerprint = { guild = guild, request_id = interaction, request_type = request_type,
    operation = "purchase", source = user, amount = total, item_id = item_id, quantity = quantity,
    price_snapshot = price_snapshot }
  return self:_run_with_receipts(guild, function(data, cached, remember)
    local request_state, prior, changed, oldest, index = check_request(data, guild, request_type, interaction, fingerprint, cached)
    remember(index, not changed)
    if request_state ~= nil then return request_state, prior, changed end
    if not InventoryData.valid_item(item_id) then return false, "invalid_argument" end
    if not total then return false, "invalid_amount" end
    local a = account(data, user, true)
    if not a then return false, "invalid_store" end
    if a.wallet < total then return false, "insufficient" end
    local added, inventory = InventoryData.add(data, user, item_id, quantity)
    if not added then return false, inventory end
    local now = self.clock()
    a.wallet = a.wallet - total
    local record = { id = record_id, guild = guild, user = user, kind = "purchase",
      amount = total, counterparty = item_id, timestamp = now, status = "committed",
      price_snapshot = price_snapshot }
    append_journal(data, record)
    local result = { id = record.id, money_id = money_id(record.id), amount = total, wallet = a.wallet,
      bank = a.bank, operation = "purchase", user = user, item_id = item_id, quantity = quantity,
      price_snapshot = price_snapshot }
    local saved, receipt_delta = save_receipt(data, request_type, interaction, fingerprint, result, oldest, index)
    if not saved then return false, "invalid_store" end
    remember(index, false, receipt_delta)
    return true, result, true
  end)
end

function Ledger:sell(guild, user, interaction, item_id, quantity, request_type)
  local Catalog = require("src.economy.catalog")
  if not Store.valid_id(user) or not Store.valid_id(interaction) then return false, "invalid_argument" end
  request_type = request_type or "interaction"
  if request_type ~= "interaction" and request_type ~= "message" then return false, "invalid_request" end
  local item = Catalog.get_resource(item_id)
  local total
  if item and type(quantity) == "number" and quantity % 1 == 0 and quantity >= 1 and quantity <= 99
    and item.sell_price <= math.floor(MAX / quantity) then total = item.sell_price * quantity end
  local record_id = (request_type == "message" and "EP" or "E") .. interaction
  local fingerprint = { guild = guild, request_id = interaction, request_type = request_type,
    operation = "sale", source = user, amount = total, item_id = item_id, quantity = quantity }
  return self:_run_with_receipts(guild, function(data, cached, remember)
    local request_state, prior, changed, oldest, index = check_request(data, guild, request_type, interaction, fingerprint, cached)
    remember(index, not changed)
    if request_state ~= nil then return request_state, prior, changed end
    if not item or not total then return false, "invalid_amount" end
    local a = account(data, user, true)
    if not a then return false, "invalid_store" end
    if a.wallet + total > MAX then return false, "overflow" end
    local removed, inventory = InventoryData.remove(data, user, item_id, quantity)
    if not removed then return false, inventory end
    local now = self.clock()
    a.wallet = a.wallet + total
    local record = { id = record_id, guild = guild, user = user, kind = "sale",
      amount = total, counterparty = item_id, timestamp = now, status = "committed" }
    append_journal(data, record)
    local result = { id = record.id, money_id = money_id(record.id), amount = total, wallet = a.wallet,
      bank = a.bank, operation = "sale", user = user, item_id = item_id,
      quantity = quantity, price_each = item.sell_price }
    local saved, receipt_delta = save_receipt(data, request_type, interaction, fingerprint, result, oldest, index)
    if not saved then return false, "invalid_store" end
    remember(index, false, receipt_delta)
    return true, result, true
  end)
end

function Ledger:mine(guild, user, interaction, request_type)
  if not Store.valid_id(user) or not Store.valid_id(interaction) then return false, "invalid_argument" end
  request_type = request_type or "interaction"
  if request_type ~= "interaction" and request_type ~= "message" then return false, "invalid_request" end
  local record_id = (request_type == "message" and "EP" or "E") .. interaction
  local fingerprint = { guild = guild, request_id = interaction, request_type = request_type,
    operation = "mine", source = user }
  return self:_run_with_receipts(guild, function(data, cached, remember)
    local request_state, prior, changed, oldest, index = check_request(data, guild, request_type, interaction, fingerprint, cached)
    remember(index, not changed)
    if request_state ~= nil then return request_state, prior, changed end
    local a = account(data, user, true)
    if not a then return false, "invalid_store" end
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
    append_journal(data, record)
    local result = { id = record.id, money_id = money_id(record.id), amount = 0, wallet = a.wallet,
      bank = a.bank, operation = "mine", user = user, item_id = item_id,
      quantity = quantity, cooldown_seconds = MINING_COOLDOWN }
    local saved, receipt_delta = save_receipt(data, request_type, interaction, fingerprint, result, oldest, index)
    if not saved then return false, "invalid_store" end
    remember(index, false, receipt_delta)
    return true, result, true
  end)
end

Ledger.mining_cooldown = MINING_COOLDOWN
Ledger.max_journal_records = MAX_JOURNAL_RECORDS
Ledger.max_economy_receipts = MAX_ECONOMY_RECEIPTS
Ledger.max_cached_receipt_indexes = MAX_CACHED_RECEIPT_INDEXES
Ledger.rewards = REWARDS
return Ledger
