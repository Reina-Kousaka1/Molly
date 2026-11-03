package.path = "./?.lua;./?/init.lua;" .. package.path

local Ledger = require("src.economy.ledger")

local full_stress = os.getenv("MOLLY_STRESS_FULL") == "1"
local rotation_milestones = { 100, 1000, 10000, 100000 }
local ledger_milestones = full_stress and { 100, 500, 1000, 5000, 10000, 100000 }
  or { 100, 500, 1000, 5000, 10000 }
local CAPACITY = Ledger.max_journal_records
io.stdout:setvbuf("line")
local function percentile(values, fraction)
  if #values == 0 then return 0 end
  table.sort(values)
  return values[math.max(1, math.ceil(#values * fraction))]
end

local function benchmark_rotation(total, ring)
  local entries, head, count = {}, 1, 0
  local latencies = {}
  local started = os.clock()
  for index = 1, total do
    local before = os.clock()
    if ring then
      if count < CAPACITY then
        local slot = ((head + count - 1) % CAPACITY) + 1
        entries[slot], count = index, count + 1
      else
        entries[head] = index
        head = head % CAPACITY + 1
      end
    else
      entries[#entries + 1] = index
      while #entries > CAPACITY do table.remove(entries, 1) end
    end
    latencies[index] = os.clock() - before
  end
  local elapsed = os.clock() - started
  local first = ring and entries[head] or entries[1]
  local last = ring and entries[((head + count - 2) % CAPACITY) + 1] or entries[#entries]
  assert(count == math.min(total, CAPACITY) or #entries == math.min(total, CAPACITY))
  assert(last == total and first == math.max(1, total - CAPACITY + 1), "rotation order changed")
  return elapsed, latencies
end

local function rotation_suite()
  io.write("rotation: implementation=table.remove|ring-index capacity=", CAPACITY, "\n")
  for _, total in ipairs(rotation_milestones) do
    for _, ring in ipairs({ false, true }) do
      collectgarbage("collect")
      local before_kb = collectgarbage("count")
      local elapsed, latencies = benchmark_rotation(total, ring)
      local after_kb = collectgarbage("count")
      io.write(string.format(
        "rotation total=%d implementation=%s seconds=%.6f avg_us=%.3f p95_us=%.3f p99_us=%.3f gc_delta_kb=%.1f retained=%d\n",
        total, ring and "ring-index" or "table.remove", elapsed, elapsed * 1000000 / total,
        percentile(latencies, 0.95) * 1000000, percentile(latencies, 0.99) * 1000000,
        after_kb - before_kb, math.min(total, CAPACITY)))
    end
  end
end

local function receipt_retention_checks()
  local data = { guild = "700000000000000002", accounts = {}, cases = {}, staff = {},
    journal = {}, receipts = {}, next_case = 1 }
  local store = {}
  function store:run(_, callback)
    local ok, result, changed = callback(data)
    if ok and changed then self.persisted = data end
    return ok, result
  end
  store.persisted = data
  local ledger = Ledger.new(store, function() return 2000000000 end)

  for index = 1, 4000 do
    local ok = ledger:change(data.guild, tostring(30000000000 + index), tostring(10000000000 + index), "daily")
    assert(ok)
  end
  for index = 1, 1000 do
    local ok = ledger:change(data.guild, tostring(40000000000 + index), tostring(20000000000 + index),
      "daily", nil, nil, "message")
    assert(ok)
  end
  local ok, newest_message = ledger:change(data.guild, "41000000000", "30000000000", "daily", nil, nil, "message")
  assert(ok and data.economy_receipt_count == Ledger.max_economy_receipts)
  assert(data.economy_receipt_watermarks.interaction == "10000000001")
  assert(data.economy_receipt_watermarks.message == "")

  local function clone(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[clone(key)] = clone(child) end
    return result
  end
  data = clone(data)
  store.persisted = data
  ledger = Ledger.new(store, function() return 2000000000 end)

  local old_wallet = data.accounts["30000000001"].wallet
  ok, local_reason = ledger:change(data.guild, "30000000001", "10000000001", "daily")
  assert(not ok and local_reason == "replay_expired", "interaction watermark must survive faster message growth")
  local old_message_ok, old_message = ledger:change(data.guild, "40000000001", "20000000001", "daily", nil, nil, "message")
  assert(old_message_ok and old_message.wallet == 100, "a still-retained message receipt should replay")
  assert(data.accounts["30000000001"].wallet == old_wallet)
  local conflict, conflict_reason = ledger:change(data.guild, "41000000000", "30000000000", "work", nil, nil, "message")
  assert(not conflict and conflict_reason == "replay_conflict", "retained receipts must compare operation fingerprints")
  assert(data.accounts["41000000000"].wallet == newest_message.wallet)

  local legacy_data = { guild = data.guild, accounts = { ["71"] = { wallet = 100, bank = 0, daily = 100 } },
    cases = {}, staff = {}, journal = { { id = "E123", guild = data.guild, user = "71", kind = "daily",
      amount = 100, counterparty = "", timestamp = 100, status = "committed" } },
    receipts = { ["123"] = { id = "E123", operation = "daily", user = "71", amount = 100, wallet = 100, bank = 0 } },
    next_case = 1 }
  local legacy_store = {}
  function legacy_store:run(_, callback)
    local called, result, changed = callback(legacy_data)
    if called and changed then self.persisted = legacy_data end
    return called, result
  end
  local legacy_ledger = Ledger.new(legacy_store, function() return 2000000000 end)
  local replay_ok, replay = legacy_ledger:change(data.guild, "71", "123", "daily")
  assert(replay_ok and replay.wallet == 100 and legacy_data.receipts["123"] == nil,
    "legacy receipt migration should preserve the prior outcome and remove its duplicate source")
  legacy_data.economy_receipts_migrated = false
  legacy_data.economy_receipt_count = nil
  legacy_data.receipts["123"] = { id = "E123", operation = "daily", user = "71", amount = 100, wallet = 100, bank = 0 }
  replay_ok, replay = legacy_ledger:change(data.guild, "71", "123", "daily")
  assert(replay_ok and replay.wallet == 100 and legacy_data.receipts["123"] == nil
      and legacy_data.economy_receipt_count == 1,
    "an overlapping current and legacy receipt should deterministically retain one prior result")
  io.write("receipt checks: separate message/interaction watermarks, post-reload expiry, retained replay/conflict, legacy migration/overlap passed\n")
end

local function benchmark_ledger()
  local data = { guild = "700000000000000001", accounts = {}, cases = {}, staff = {},
    journal = {}, receipts = {}, next_case = 1 }
  local store = {}
  function store:run(guild, callback)
    assert(guild == data.guild)
    local ok, result, changed = callback(data)
    if ok and changed then self.persisted = data end
    return ok, result
  end
  store.persisted = data
  local now = 2000000000
  local ledger = Ledger.new(store, function() return now end)
  local latencies, elapsed_at, memory_at = {}, {}, {}
  local overall_start = os.clock()
  local before_kb = collectgarbage("count")
  local milestone_index = 1

  for index = 1, ledger_milestones[#ledger_milestones] do
    local started = os.clock()
    local ok, result = ledger:change(data.guild, tostring(20000000000 + index),
      tostring(10000000000 + index), "daily")
    local elapsed = os.clock() - started
    assert(ok and result.wallet == 100, "synthetic ledger operation failed at " .. index)
    latencies[index] = elapsed
    if index == ledger_milestones[milestone_index] then
      local elapsed_total = os.clock() - overall_start
      local sample = {}
      for sample_index = 1, index do sample[sample_index] = latencies[sample_index] end
      local p95, p99 = percentile(sample, 0.95), percentile(sample, 0.99)
      local max_latency = 0
      for sample_index = 1, index do
        if latencies[sample_index] > max_latency then max_latency = latencies[sample_index] end
      end
      elapsed_at[index], memory_at[index] = elapsed_total, collectgarbage("count")
      io.write(string.format(
        "ledger bookings=%d seconds=%.3f ops_per_second=%.1f avg_ms=%.3f p95_ms=%.3f p99_ms=%.3f max_ms=%.3f gc_kb=%.1f accounts=%d journal=%d receipts=%d\n",
        index, elapsed_total, index / elapsed_total, elapsed_total * 1000 / index,
        p95 * 1000, p99 * 1000, max_latency * 1000, memory_at[index] - before_kb,
        (function() local n = 0; for _ in pairs(data.accounts) do n = n + 1 end; return n end)(),
        #data.journal, data.economy_receipt_count or 0))
      milestone_index = milestone_index + 1
    end
  end
  assert(store.persisted == data and #data.journal == CAPACITY)
  assert(data.economy_receipt_count == Ledger.max_economy_receipts)
  io.write("ledger state remained in a synthetic in-memory store; this is not a SeaWorld persistence measurement\n")
end

io.write("stress profile: ", full_stress and "full (through 100000)" or "CI (through 10000)", "\n")
rotation_suite()
receipt_retention_checks()
benchmark_ledger()
