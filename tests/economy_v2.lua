package.path = "./?.lua;./?/init.lua;" .. package.path

local Settings = require("src.settings.guild")
local UserSettings = require("src.settings.user")
local Modes = require("src.modes.registry")
local Sephora = require("src.modes.sephora")
local ContentPolicy = require("src.content.policy")
local Ledger = require("src.economy.ledger")
local Inventory = require("src.economy.inventory")
local InventoryData = require("src.economy.inventory_data")
local Shop = require("src.economy.shop")
local Mining = require("src.economy.mining")
local Fashion = require("src.economy.fashion")
local Schema = require("src.settings.schema")
local Router = require("src.commands.router")
local ShopCommands = require("src.commands.shop")
local InventoryCommands = require("src.commands.inventory")
local MiningCommands = require("src.commands.mining")
local FashionCommands = require("src.commands.fashion")
local ModeCommands = require("src.commands.mode")
local SephoraCommands = require("src.commands.sephora")
local ContentCommands = require("src.commands.content")
local UserSettingsCommands = require("src.commands.user_settings")

local total, failed = 0, 0
local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then io.stdout:write("ok - " .. name .. "\n")
  else failed = failed + 1; io.stderr:write("not ok - " .. name .. ": " .. tostring(err) .. "\n") end
end

local function clone(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do result[clone(key)] = clone(child) end
  return result
end

local function memory_guild_store()
  local store = { data = {}, busy = {} }
  function store:run(guild, fn)
    if self.busy[guild] then return false, "busy" end
    self.busy[guild] = true
    local data = clone(self.data[guild] or {
      guild = guild, accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {}, next_case = 1,
    })
    local called, ok, result, changed = pcall(fn, data)
    if not called then self.busy[guild] = nil; return false, "unavailable" end
    if ok and changed then self.data[guild] = data end
    self.busy[guild] = nil
    return ok, result
  end
  return store
end

local function memory_global_store()
  local store = { data = {}, busy = {} }
  function store:run(name, defaults, fn)
    if self.busy[name] then return false, "busy" end
    self.busy[name] = true
    local data = clone(self.data[name] or defaults)
    local called, ok, result, changed = pcall(fn, data)
    if not called then self.busy[name] = nil; return false, "unavailable" end
    if ok and changed then self.data[name] = data end
    self.busy[name] = nil
    return ok, result
  end
  return store
end

local now, random_values = 1000, {}
local store = memory_guild_store()
local global = memory_global_store()
local settings = Settings.new(store)
local user_settings = UserSettings.new(global)
local modes = Modes.new(settings)
local sephora = Sephora.new(store, modes, function() return now end)
local ledger = Ledger.new(store, function() return now end, function(minimum, maximum)
  local value = table.remove(random_values, 1)
  assert(type(value) == "number" and value >= minimum and value <= maximum, "unexpected random range/result")
  return value
end)
local inventory = Inventory.new(store)
local shop = Shop.new(settings, ledger, modes, sephora)
local mining = Mining.new(ledger, modes)
local fashion = Fashion.new(inventory, modes)

local rest = { channels = {
  ["100"] = { id = "100", guild_id = "10", type = 0, nsfw = true },
  ["101"] = { id = "101", guild_id = "10", type = 0, nsfw = false },
  ["200"] = { id = "200", guild_id = "20", type = 0, nsfw = true },
} }
function rest:get_channel(id) return self.channels[id] end
local policy = ContentPolicy.new(settings, { rest = rest, user_settings = user_settings })

-- Settings defaults and explicit NSFW-channel validation.
test("new mode, mature-content protection, and shop are additive and disabled by default", function()
  local ok, guild = settings:get_domain("10", "guild")
  assert(ok and guild.mode == "standard")
  ok, value = settings:get_domain("10", "content")
  assert(ok and value.mature_enabled == false and #value.mature_channels == 0)
  ok, value = settings:get_domain("10", "shop")
  assert(ok and value.enabled == false)
  assert(Schema.normalize("content", { mature_enabled = true, mature_channels = {} }) == nil)
  assert(not store.data["10"] or store.data["10"].settings == nil, "legacy settings must remain in place without a migration")
end)

test("mature content needs server opt-in, a verified NSFW channel, and a user opt-in", function()
  local ok, reason = policy:set_enabled("10", true)
  assert(not ok and reason == "channel_required")
  ok, reason = policy:add_channel("10", "101")
  assert(not ok and reason == "nsfw_channel_required")
  ok, reason = policy:add_channel("10", "200")
  assert(not ok and reason == "wrong_guild")
  ok = policy:add_channel("10", "100")
  assert(ok)
  ok = policy:set_enabled("10", true)
  assert(ok)
  local allowed, why = policy:authorize("10", "100", "mature", "200")
  assert(not allowed and why == "user_opt_in_required")
  local saved, preferences = user_settings:set_mature_opt_in("200", true)
  assert(saved and preferences.mature_opt_in)
  allowed = policy:authorize("10", "100", "mature", "200")
  assert(allowed)
  allowed, why = policy:authorize("10", "101", "mature", "200")
  assert(not allowed and why == "mature_disabled")
  allowed, why = policy:authorize("10", "100", "explicit", "200")
  assert(not allowed and why == "content_prohibited")
  allowed, why = policy:authorize("10", "100", "unclassified", "200")
  assert(not allowed and why == "unknown_category")
  allowed = policy:authorize("10", "100", "general", "200")
  assert(allowed)
  assert(policy:remove_channel("10", "100"))
  local read, content = settings:get_domain("10", "content")
  assert(read and not content.mature_enabled and #content.mature_channels == 0)
end)

test("user preferences are optional, default off, and reset removes their profile", function()
  local ok, value = user_settings:get("201")
  assert(ok and not value.mature_opt_in and not value.compact_replies)
  ok, value = user_settings:set_compact("201", true)
  assert(ok and value.compact_replies)
  ok, value = user_settings:set_mature_opt_in("201", true)
  assert(ok and value.mature_opt_in and value.compact_replies)
  ok, value = user_settings:reset("201")
  assert(ok and not value.mature_opt_in and not value.compact_replies)
  assert(global.data["user-settings"].profiles["201"] == nil)
end)

test("shop purchases are idempotent and commit wallet, inventory, and Money ID together", function()
  local ok, result = shop:list("10")
  assert(not ok and result == "shop_disabled")
  assert(shop:set_enabled("10", true))
  ok, result = ledger:change("10", "200", "301", "daily")
  assert(ok and result.wallet == 100)
  ok, result = shop:buy("10", "200", "302", "pickaxe", 1)
  assert(ok and result.charged == 100 and result.wallet == 0 and result.item_id == "pickaxe")
  local journal_count = #store.data["10"].journal
  local replay_ok, replay = shop:buy("10", "200", "302", "pickaxe", 1)
  assert(replay_ok and replay.item_id == "pickaxe" and #store.data["10"].journal == journal_count)
  local conflict, conflict_reason = shop:buy("10", "200", "302", "rose_crown", 1)
  assert(not conflict and conflict_reason == "replay_conflict", "a reused request ID must not alias a different purchase")
  local inv_ok, value = inventory:get("10", "200")
  assert(inv_ok and value.items.pickaxe == 1 and not value.items.rose_crown)
  local found, entry = ledger:transaction("10", result.money_id)
  assert(found and entry.kind == "purchase" and entry.counterparty == "pickaxe" and entry.amount == 100)
  assert(not ledger:purchase("10", "200", "303", "rose_crown", 250, 1))
  inv_ok, value = inventory:get("10", "200")
  assert(inv_ok and not value.items.rose_crown and #store.data["10"].journal == journal_count)
end)

test("ledger replays compare complete operation fingerprints before changing balances or inventory", function()
  local isolated = memory_guild_store()
  isolated.data["30"] = { guild = "30", accounts = {
    ["20"] = { wallet = 1000, bank = 0 }, ["21"] = { wallet = 0, bank = 0 }, ["99"] = { wallet = 0, bank = 0 },
  }, cases = {}, staff = {}, journal = {}, receipts = {}, next_case = 1,
    molly_v2 = { schema_version = 1, inventory = { items = { ["20"] = { copper_ore = 3 } }, equipped = {} } } }
  local service = Ledger.new(isolated, function() return 100000 end)
  local ok, result = service:change("30", "20", "901", "pay", "5", "21")
  assert(ok and result.amount == 5 and result.wallet == 995)
  local journal_count = #isolated.data["30"].journal
  local function conflict(run)
    local accounts_before, items_before = {}, clone(isolated.data["30"].molly_v2.inventory.items["20"])
    for id, account_data in pairs(isolated.data["30"].accounts) do accounts_before[id] = account_data.wallet end
    local count_before = #isolated.data["30"].journal
    local accepted, reason = run()
    assert(not accepted and reason == "replay_conflict")
    assert(#isolated.data["30"].journal == count_before)
    for id, wallet in pairs(accounts_before) do assert(isolated.data["30"].accounts[id].wallet == wallet) end
    for item, quantity in pairs(items_before) do assert(isolated.data["30"].molly_v2.inventory.items["20"][item] == quantity) end
  end
  ok, result = service:change("30", "20", "901", "pay", 5, "21")
  assert(ok and #isolated.data["30"].journal == journal_count, "numeric/string equivalent requests replay")
  conflict(function() return service:change("30", "20", "901", "pay", "500", "99") end)
  conflict(function() return service:change("30", "20", "901", "pay", "5", "99") end)
  conflict(function() return service:change("30", "21", "901", "pay", "5", "99") end)
  conflict(function() return service:change("30", "20", "901", "pay", "5", "20") end)
  conflict(function() return service:change("30", "20", "901", "deposit", "5") end)

  ok, result = service:purchase("30", "20", "902", "pickaxe", 100, 1)
  assert(ok and result.quantity == 1)
  journal_count = #isolated.data["30"].journal
  ok, result = service:purchase("30", "20", "902", "pickaxe", 100, 1)
  assert(ok and #isolated.data["30"].journal == journal_count)
  conflict(function() return service:purchase("30", "20", "902", "pickaxe", 100, 2) end)
  conflict(function() return service:purchase("30", "20", "902", "rose_crown", 100, 1) end)
  conflict(function() return service:purchase("30", "20", "902", "!invalid", 100, 1) end)
  conflict(function() return service:purchase("30", "20", "902", "pickaxe", 100, 0) end)
  conflict(function() return service:purchase("30", "20", "902", "pickaxe", 99, 1) end)
  conflict(function() return service:change("30", "20", "902", "daily") end)

  ok, result = service:sell("30", "20", "903", "copper_ore", 1)
  assert(ok and result.quantity == 1)
  journal_count = #isolated.data["30"].journal
  ok, result = service:sell("30", "20", "903", "copper_ore", 1)
  assert(ok and #isolated.data["30"].journal == journal_count)
  conflict(function() return service:sell("30", "20", "903", "copper_ore", 2) end)
  conflict(function() return service:sell("30", "20", "903", "copper_ore", 1000) end)
  conflict(function() return service:sell("30", "20", "903", "iron_ore", 1) end)
end)

test("mining requires a reusable pickaxe, is cooldown-limited, replay-safe, and yields sellable resources", function()
  local ok, result = mining:mine("10", "202", "401")
  assert(not ok and result == "pickaxe_required")
  random_values = { 95, 1 }
  ok, result = mining:mine("10", "200", "402")
  assert(ok and result.item_id == "crystal_shard" and result.quantity == 1)
  local count = #store.data["10"].journal
  local replay_ok, replay = mining:mine("10", "200", "402")
  assert(replay_ok and replay.item_id == result.item_id and #store.data["10"].journal == count)
  local rejected, reason = mining:mine("10", "200", "403")
  assert(not rejected and reason == "cooldown")
  local sold, sale = shop:sell("10", "200", "404", "crystal_shard", 1)
  assert(sold and sale.charged == 30 and sale.wallet == 30)
  local sale_count = #store.data["10"].journal
  sold, sale = shop:sell("10", "200", "404", "crystal_shard", 1)
  assert(sold and sale.wallet == 30 and #store.data["10"].journal == sale_count)
  local inv_ok, value = inventory:get("10", "200")
  assert(inv_ok and not value.items.crystal_shard and value.items.pickaxe == 1)
  now = now + Ledger.mining_cooldown
  random_values = { 65, 2 }
  ok, result = mining:mine("10", "200", "405")
  assert(ok and result.item_id == "iron_ore" and result.quantity == 2)
end)

test("journal rotation permits new writes after 1,000 records and survives reload", function()
  local function persistent_store(initial)
    local result = { data = initial or {} }
    function result:run(guild, fn)
      local data = self.data[guild] or { guild = guild, accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {}, next_case = 1 }
      local ok, value, changed = fn(data)
      if ok and changed then self.data[guild] = data end
      return ok, value
    end
    return result
  end
  local clock, state = 0, persistent_store()
  local first_id, first_money_id, last_id, last_result
  local service = Ledger.new(state, function() clock = clock + 86400; return clock end)
  for index = 1, Ledger.max_journal_records do
    local request_id = tostring(3000000000 + index)
    local ok, result = service:change("80", "70", request_id, "daily")
    assert(ok)
    if index == 1 then first_id, first_money_id = request_id, result.money_id end
  end
  assert(#state.data["80"].journal == Ledger.max_journal_records)
  local request_id = tostring(3000000000 + Ledger.max_journal_records + 1)
  local ok, result = service:change("80", "70", request_id, "daily")
  assert(ok, "the 1,001st ledger operation must succeed")
  last_id, last_result = request_id, result
  assert(#state.data["80"].journal == Ledger.max_journal_records)
  assert(state.data["80"].economy_receipt_count == math.min(Ledger.max_journal_records + 1,
    Ledger.max_economy_receipts))
  local found, lookup = service:transaction("80", first_money_id)
  assert(not found and lookup == "transaction_not_found", "lookup is guaranteed only while the row is retained")
  found, lookup = service:transaction("80", last_result.money_id)
  assert(found and lookup.id == "E" .. last_id)

  local reloaded = persistent_store({ ["80"] = clone(state.data["80"]) })
  local after_restart = Ledger.new(reloaded, function() clock = clock + 86400; return clock end)
  local journal_count, wallet = #reloaded.data["80"].journal, reloaded.data["80"].accounts["70"].wallet
  local replayed, replay = after_restart:change("80", "70", last_id, "daily")
  assert(replayed and replay.wallet == last_result.wallet)
  assert(#reloaded.data["80"].journal == journal_count and reloaded.data["80"].accounts["70"].wallet == wallet,
    "persisted retries after process reload cannot duplicate a reward")
end)

test("economy receipts stay bounded and expired request IDs fail closed after reload", function()
  local function persistent_store(initial)
    local result = { data = initial or {} }
    function result:run(guild, fn)
      local data = self.data[guild] or { guild = guild, accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {}, next_case = 1 }
      local ok, value, changed = fn(data)
      if ok and changed then self.data[guild] = data end
      return ok, value
    end
    return result
  end
  local clock, state = 0, persistent_store()
  local first_id, first_money_id, last_id, last_result
  local ok, result
  local service = Ledger.new(state, function() clock = clock + 86400; return clock end)
  for index = 1, Ledger.max_economy_receipts + 1 do
    local request_id = tostring(4000000000 + index)
    ok, result = service:change("81", "71", request_id, "daily")
    assert(ok, "new requests continue through receipt retention")
    if index == 1 then first_id, first_money_id = request_id, result.money_id end
    last_id, last_result = request_id, result
  end
  local data = state.data["81"]
  assert(data.economy_receipt_count == Ledger.max_economy_receipts)
  local retained = 0; for _ in pairs(data.economy_receipts) do retained = retained + 1 end
  assert(retained == Ledger.max_economy_receipts and data.economy_receipt_watermarks.interaction == first_id)
  assert(#data.journal == Ledger.max_journal_records)

  local reloaded = persistent_store({ ["81"] = clone(data) })
  local after_restart = Ledger.new(reloaded, function() clock = clock + 86400; return clock end)
  local wallet, journal_count = reloaded.data["81"].accounts["71"].wallet, #reloaded.data["81"].journal
  local ok, reason = after_restart:change("81", "71", first_id, "daily")
  assert(not ok and reason == "replay_expired", "a pruned ID must never execute again")
  assert(reloaded.data["81"].accounts["71"].wallet == wallet and #reloaded.data["81"].journal == journal_count)
  ok, result = after_restart:change("81", "71", last_id, "daily")
  assert(ok and result.wallet == last_result.wallet and #reloaded.data["81"].journal == journal_count)
  local found, lookup = after_restart:transaction("81", first_money_id)
  assert(not found and lookup == "transaction_not_found")
  found, lookup = after_restart:transaction("81", last_result.money_id)
  assert(found and lookup.id == "E" .. last_id)

  local new_id = tostring(4000000000 + Ledger.max_economy_receipts + 2)
  ok = after_restart:change("81", "71", new_id, "daily")
  assert(ok and reloaded.data["81"].economy_receipt_count == Ledger.max_economy_receipts)
  assert(#reloaded.data["81"].journal == Ledger.max_journal_records)
end)

test("ledger receipt index avoids rescanning its persisted map on every mutation", function()
  local data = { guild = "89", accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {}, next_case = 1 }
  local store = { run = function(_, _, fn)
    local ok, result, changed = fn(data)
    return ok, result, changed
  end }
  local now = 0
  local service = Ledger.new(store, function() now = now + 86400; return now end)
  for index = 1, 100 do
    local ok = service:change("89", "70", tostring(7000000 + index), "daily")
    assert(ok)
  end
  local receipt_map, visits, original_pairs = data.economy_receipts, 0, pairs
  pairs = function(value)
    if value == receipt_map then visits = visits + 1 end
    return original_pairs(value)
  end
  local ran, reason = pcall(function()
    for index = 101, 200 do
      local ok, result = service:change("89", "70", tostring(7000000 + index), "daily")
      assert(ok, tostring(result))
    end
  end)
  pairs = original_pairs
  assert(ran, reason)
  assert(visits == 0, "warm receipt checks and additions must use the bounded per-guild heap index")
  assert(data.economy_receipt_count == 200)
end)

test("ledger receipt index invalidates on generation changes and stays bounded across guilds", function()
  local isolated, now = memory_guild_store(), 0
  local clock = function() now = now + 86400; return now end
  local first = Ledger.new(isolated, clock)
  local second = Ledger.new(isolated, clock)
  assert(first:change("95", "70", "8000000001", "daily"))
  assert(second:change("95", "70", "8000000002", "daily"))
  assert(first:change("95", "70", "8000000003", "daily"))
  local data = isolated.data["95"]
  assert(data.economy_receipt_count == 3 and data.accounts["70"].wallet == 300,
    "a stale local index must rebuild after another Ledger instance commits")
  for index = 1, 12 do
    local guild = tostring(1000 + index)
    assert(first:change(guild, "71", tostring(9000000000 + index), "daily"))
  end
  local cached = 0; for _ in pairs(first.receipt_indexes) do cached = cached + 1 end
  assert(cached <= Ledger.max_cached_receipt_indexes and Ledger.max_cached_receipt_indexes == 8)
end)

test("economy balances and matching request IDs remain isolated across guilds", function()
  local isolated = memory_guild_store()
  local service = Ledger.new(isolated, function() return 200000 end)
  local first_ok = service:change("90", "70", "900", "daily")
  local second_ok = service:change("91", "70", "900", "daily")
  assert(first_ok and second_ok, "the same Discord request ID can independently exist in two guild ledgers")
  local replayed, result = service:change("90", "70", "900", "daily")
  assert(replayed and result.wallet == 100)
  local conflict, reason = service:change("91", "70", "900", "deposit", "all")
  assert(not conflict and reason == "replay_conflict")
  local first_balance, a = service:balance("90", "70")
  local second_balance, b = service:balance("91", "70")
  assert(first_balance and second_balance and a.wallet == 100 and b.wallet == 100)
  assert(isolated.data["90"].economy_receipts["interaction:900"]
    and isolated.data["91"].economy_receipts["interaction:900"])
  assert(isolated.data["90"] ~= isolated.data["91"])
end)

test("account creation has no permanent 200-account ceiling", function()
  local isolated = memory_guild_store()
  local accounts = {}
  for index = 1, 200 do accounts[tostring(index)] = { wallet = 0, bank = 0 } end
  isolated.data["82"] = { guild = "82", accounts = accounts, cases = {}, staff = {}, journal = {}, receipts = {}, next_case = 1 }
  local service = Ledger.new(isolated, function() return 200000 end)
  local ok, result = service:change("82", "201", "500000", "daily")
  assert(ok and result.wallet == 100)
  assert(isolated.data["82"].accounts["201"].wallet == 100)
  local count = 0; for _ in pairs(isolated.data["82"].accounts) do count = count + 1 end
  assert(count == 201 and isolated.data["82"].accounts["1"].wallet == 0)
end)

test("mining rejects invalid and non-finite clock state", function()
  local function attempt(last_mine, clock_value, request_id)
    local data = { accounts = { ["202"] = { wallet = 0, bank = 0, last_mine = last_mine } },
      journal = {}, receipts = {} }
    local isolated_store = { run = function(_, _, fn)
      local ok, result = fn(data)
      return ok, result
    end }
    local isolated_ledger = Ledger.new(isolated_store, function() return clock_value end)
    return isolated_ledger:mine("10", "202", request_id)
  end
  local ok, reason = attempt(-1, 100, "406")
  assert(not ok and reason == "invalid_store")
  ok, reason = attempt(math.huge, 100, "407")
  assert(not ok and reason == "invalid_store")
  ok, reason = attempt(nil, math.huge, "408")
  assert(not ok and reason == "invalid_store")
  ok, reason = attempt(101, 100, "409")
  assert(not ok and reason == "invalid_store")
end)

test("fashion is guild-isolated, requires ownership, and enforces the selected server mode", function()
  local ok, result = ledger:change("10", "201", "501", "weekly")
  assert(ok and result.wallet == 500)
  ok, result = shop:buy("10", "201", "502", "rose_crown", 1)
  assert(ok and result.wallet == 250)
  ok, result = fashion:equip("10", "201", "rose_crown")
  assert(ok and result.slot == "head")
  local found, data = fashion:get("10", "201")
  assert(found and data.equipped.head == "rose_crown")
  local other, empty = fashion:get("20", "201")
  assert(other and empty.equipped.head == nil and empty.items.rose_crown == nil)
  assert(modes:set("20", "sephora"))
  local no_fashion, reason = fashion:equip("20", "201", "rose_crown")
  assert(not no_fashion and reason == "virtual_mode")
  local shop_ok, book = shop:list("20")
  assert(shop_ok and book.mode == "sephora" and #book.items == 4)
  local account_before = store.data["20"] and store.data["20"].accounts["201"]
  local selected, look = shop:buy("20", "201", "503", "rose_glow", 1)
  assert(selected and look.charged == 0 and look.mode == "sephora")
  assert((store.data["20"] and store.data["20"].accounts["201"]) == account_before,
    "virtual Sephora must not touch the coin ledger")
  local fitting_ok, fitting = sephora:get("20", "201")
  assert(fitting_ok and fitting.look_id == "rose_glow")
  local conflict, conflict_reason = sephora:try_on("20", "201", "citrus_satin", "503")
  assert(not conflict and conflict_reason == "replay_conflict")
  assert(modes:set("20", "standard"))
  local disabled, reason = shop:list("20")
  assert(not disabled and reason == "shop_disabled")
  local unavailable, mode_reason = shop:buy("20", "201", "505", "citrus_satin", 1)
  assert(not unavailable and mode_reason == "virtual_mode")
end)

test("Sephora receipts migrate, rotate at 5,000, and remain replay-safe through 10,000 requests", function()
  local function sephora_data(guild)
    return { guild = guild, accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {}, next_case = 1,
      molly_v2 = { schema_version = 1, settings = { guild = { mode = "sephora" } },
        sephora = { fittings = {}, receipts = {} } } }
  end
  local state = { data = { ["92"] = sephora_data("92") } }
  function state:run(guild, fn)
    local data = self.data[guild]
    local ok, result, changed = fn(data)
    if ok and changed then self.data[guild] = data end
    return ok, result
  end
  local modes = { get = function() return true, { mode = "sephora" } end }
  local tick = 0
  local service = Sephora.new(state, modes, function() tick = tick + 1; return tick end)
  local function id(index) return "100000000000000" .. string.format("%05d", index) end
  local first_id, latest
  for index = 1, 5000 do
    local request = id(index)
    local ok, result = service:try_on("92", "7", "rose_glow", request)
    assert(ok and not result.replayed)
    if index == 1 then first_id = request end
    latest = request
  end
  local section = state.data["92"].molly_v2.sephora
  assert(section.receipt_count == Sephora.max_receipts and #section.receipt_order == Sephora.max_receipts)
  assert(section.receipt_watermark == "")
  local stamp = section.fittings["7"].timestamp
  local replayed, result = service:try_on("92", "7", "rose_glow", latest)
  assert(replayed and result.replayed and section.fittings["7"].timestamp == stamp)
  local conflict, conflict_reason = service:try_on("92", "7", "citrus_satin", latest)
  assert(not conflict and conflict_reason == "replay_conflict")

  for index = 5001, 10000 do
    local request = id(index)
    local ok = service:try_on("92", "7", index % 2 == 0 and "rose_glow" or "citrus_satin", request)
    assert(ok, "receipt rotation must not permanently lock fittings")
    latest = request
  end
  section = state.data["92"].molly_v2.sephora
  assert(section.receipt_count == Sephora.max_receipts and #section.receipt_order == Sephora.max_receipts)
  assert(section.receipts[first_id] == nil and section.receipt_watermark == id(5000))
  local fitting_before = section.fittings["7"].look_id
  local reloaded = { data = { ["92"] = clone(state.data["92"]) } }
  function reloaded:run(guild, fn)
    local data = self.data[guild]
    local ok, value, changed = fn(data)
    if ok and changed then self.data[guild] = data end
    return ok, value
  end
  local after_restart = Sephora.new(reloaded, modes, function() return 99999 end)
  local expired, expired_reason = after_restart:try_on("92", "7", "rose_glow", first_id)
  assert(not expired and expired_reason == "replay_expired")
  assert(reloaded.data["92"].molly_v2.sephora.fittings["7"].look_id == fitting_before)
  local retained, retained_result = after_restart:try_on("92", "7", fitting_before, latest)
  assert(retained and retained_result.replayed)
  local guild_two = sephora_data("93")
  reloaded.data["93"] = guild_two
  local other_guild = after_restart:try_on("93", "7", "rose_glow", first_id)
  assert(other_guild and guild_two.molly_v2.sephora.receipts[first_id],
    "a request ID in one guild must not leak receipts or fittings into another")
end)

test("inventory data rejects over-capacity and malformed mutations", function()
  local data = { guild = "30", accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {} }
  local ok, reason = InventoryData.add(data, "200", "Copper Ore", 1)
  assert(not ok and reason == "invalid_argument")
  for index = 1, InventoryData.MAX_ITEM_TYPES do
    local id = "item_" .. string.format("%02d", index)
    assert(InventoryData.add(data, "200", id, 1))
  end
  ok, reason = InventoryData.add(data, "200", "item_overflow", 1)
  assert(not ok and reason == "capacity")
  ok, reason = InventoryData.add(data, "201", "copper_ore", 1000)
  assert(not ok and reason == "capacity")

  local removable = { guild = "30", accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {} }
  assert(InventoryData.add(removable, "202", "rose_crown", 1))
  local section = removable.molly_v2.inventory
  section.equipped["202"] = { head = "rose_crown" }
  assert(InventoryData.remove(removable, "202", "rose_crown", 1))
  assert(section.items["202"] == nil and section.equipped["202"] == nil,
    "empty inventory owners should be released after the last item is sold")
  local malformed = { molly_v2 = { schema_version = 1, inventory = {
    items = { ["203"] = { pickaxe = 1 } }, equipped = { ["203"] = { head = "pickaxe" } },
  } } }
  local invalid = InventoryData.get(malformed, "203")
  assert(invalid == nil, "non-fashion items must not be accepted as equipped state")
end)

test("V2 command modules register safe guild/user-facing slash definitions", function()
  local router = Router.new()
  ShopCommands.register(router, shop, settings)
  InventoryCommands.register(router, inventory)
  MiningCommands.register(router, mining)
  FashionCommands.register(router, fashion)
  ModeCommands.register(router, modes)
  SephoraCommands.register(router, modes, sephora)
  ContentCommands.register(router, settings, policy)
  UserSettingsCommands.register(router, user_settings)
  for _, name in ipairs({ "shop", "inventory", "mine", "fashion", "mode", "sephora", "content", "user-settings" }) do
    assert(router.commands[name] and router.commands[name].slash, "missing /" .. name)
  end
  assert(router.commands.mode.permission == "manage_guild" and router.commands.content.permission == "manage_guild")
  assert(not router.commands.shop.admin and not router.commands["user-settings"].admin)
  local shop_options = router.commands.shop.options
  assert(#shop_options == 6 and shop_options[1].name == "status" and shop_options[6].name == "disable")
  local options = router.commands["user-settings"].options
  assert(#options == 6 and options[1].name == "show")
end)

io.stdout:write(string.format("%d V2 economy/mode tests, %d failures\n", total, failed))
if failed > 0 then os.exit(1) end
