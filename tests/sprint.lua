package.path = "./?.lua;./?/init.lua;" .. package.path
local Router = require("src.commands.router")
local Info = require("src.commands.information")
local EconomyCommands = require("src.commands.economy")
local Moderation = require("src.commands.moderation")
local Staff = require("src.commands.staff")
local Permissions = require("src.discord.permissions")
local Hierarchy = require("src.moderation.hierarchy")
local Ledger = require("src.economy.ledger")
local Cases = require("src.moderation.cases")
local Directory = require("src.staff.directory")
local Presence = require("src.presence.rotation")
local Seasonal = require("src.seasonal")
local SafeSync = require("src.discord.safe_sync")
local total, failed = 0, 0
local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then print("ok - " .. name) else failed = failed + 1; io.stderr:write("not ok - " .. name .. ": " .. tostring(err) .. "\n") end
end
local function clone(value)
  if type(value) ~= "table" then return value end
  local result = {}; for k, v in pairs(value) do result[k] = clone(v) end; return result
end
local function memory_store()
  local store = { data = {}, unavailable = false }
  function store:run(guild, fn)
    if self.unavailable then return false, "unavailable" end
    local data = clone(self.data[guild] or { guild = guild, accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {}, next_case = 1 })
    local ok, result, changed = fn(data)
    if ok and changed then self.data[guild] = data end
    return ok, result
  end
  return store
end
test("permissions preserve low bits in large Discord decimal masks", function()
  assert(Permissions.has("9007199254740996", "ban_members"))
  assert(not Permissions.has("9007199254740992", "ban_members"))
  assert(Permissions.has("8", "ban_members"))
  assert(not Permissions.has("garbage", "manage_guild"))
end)
test("role hierarchy checks actor and bot, including missing roles", function()
  local roles = { { id = "1", position = 0 }, { id = "2", position = 2 }, { id = "3", position = 3 } }
  local ctx = { guild = { id = "1" }, author = { id = "10" }, bot = { user = { id = "11" }, rest = {} } }
  function ctx.bot.rest:get_guild() return { owner_id = "99" } end
  function ctx.bot.rest:get_roles() return roles end
  function ctx.bot.rest:get_member(_, id)
    if id == "10" or id == "11" then return { roles = { "3" } } end
    return { roles = { "2" } }
  end
  assert(Hierarchy.check(ctx, "12"))
  roles[2].position = 4
  assert(not Hierarchy.check(ctx, "12"))
  assert(not Hierarchy.check(ctx, "10"))
end)
test("KiddyyMolly keeps one preppy identity all year", function()
  local first = Seasonal.current(1793314800)
  assert(first.id == "preppy" and first.personality == "preppy")
  assert(#first.presence == 25)
  assert(Seasonal.current(1793574000) == first)
  assert(Seasonal.current(1793314799) == first)
end)
test("presence writes immediately, rotates every two minutes, and reconnect adds no timer", function()
  local ticks, schedules, cancelled, callback = {}, 0, 0
  local rotation = Presence.new({ write = function(t) ticks[#ticks + 1] = t; return true end,
    clock = function() return 1793314800 end,
    schedule = function(ms, cb) assert(ms == 120000); schedules = schedules + 1; callback = cb; return 1 end,
    cancel = function() cancelled = cancelled + 1 end })
  assert(rotation:start() and not rotation:start())
  assert(schedules == 1 and #ticks == 2 and ticks[1] ~= ticks[2])
  callback()
  assert(#ticks == 3 and ticks[2] ~= ticks[3])
  assert(rotation:stop() and not rotation:stop()); callback()
  assert(#ticks == 3 and cancelled == 1)
end)
test("presence stays preppy across dates without another writer", function()
  local ticks, schedules, callback, now = {}, 0, nil, 1793314800
  local rotation = Presence.new({ write = function(t) ticks[#ticks + 1] = t; return true end,
    clock = function() return now end,
    schedule = function(_, cb) schedules = schedules + 1; callback = cb; return 1 end,
    cancel = function() end })
  rotation:start()
  local previous_text = ticks[#ticks]
  now = 1793574000
  callback()
  assert(ticks[#ticks] ~= previous_text and rotation.season_id == "preppy" and schedules == 1)
end)
test("presence failures are contained and a failed scheduler does not leave rotation running", function()
  local rotation = Presence.new({ write = function() error("private writer detail") end,
    schedule = function() error("private timer detail") end, cancel = function() end })
  assert(rotation:start() == false) -- scheduler/write failures never escape after constructor
  assert(not rotation.running)
end)
test("ledger validation, atomic transfer, cooldown, replay and rollback", function()
  local store = memory_store(); local ledger = Ledger.new(store, function() return 100000 end)
  local ok, result = ledger:change("1", "2", "100", "daily")
  assert(ok and result.wallet == 100)
  assert(ledger:change("1", "2", "100", "daily"))
  ok, result = ledger:change("1", "2", "101", "daily"); assert(not ok and result == "cooldown")
  ok, result = ledger:change("1", "2", "102", "deposit", "50"); assert(ok and result.wallet == 50 and result.bank == 50)
  ok, result = ledger:change("1", "2", "103", "withdraw", "all"); assert(ok and result.wallet == 100)
  for _, a in ipairs({ "0", "-1", "NaN", "1000000000001" }) do assert(not ledger:change("1", "2", "104", "pay", a, "3")) end
  assert(not ledger:change("1", "2", "105", "pay", "1", "2"))
  assert(not ledger:change("1", "2", "106", "pay", "101", "3"))
  assert(ledger:change("1", "2", "107", "pay", "30", "3"))
  ok, result = ledger:balance("1", "3"); assert(ok and result.wallet == 30)
  store.unavailable = true; assert(not ledger:change("1", "2", "108", "pay", "10", "3"))
  store.unavailable = false; ok, result = ledger:balance("1", "2"); assert(ok and result.wallet == 70)
end)
test("economy rejects overflow without publishing partial changes", function()
  local store = memory_store()
  store.data["1"] = { guild = "1", accounts = { ["2"] = { wallet = 100, bank = 1000000000000 }, ["3"] = { wallet = 1000000000000, bank = 0 } },
    cases = {}, staff = {}, journal = {}, receipts = {}, next_case = 1 }
  local ledger = Ledger.new(store, function() return 100000 end)
  local ok, reason = ledger:change("1", "2", "40", "deposit", "1")
  assert(not ok and reason == "overflow" and store.data["1"].accounts["2"].wallet == 100)
  ok, reason = ledger:change("1", "2", "41", "pay", "1", "3")
  assert(not ok and reason == "overflow" and store.data["1"].accounts["2"].wallet == 100)
end)
test("case creation, reason edit, removal and missing modlog", function()
  local cases = Cases.new(memory_store(), function() return 100 end)
  local ok, item = cases:warn("1", "2", "3", "first", "4"); assert(ok and item.id == "C1")
  ok, item = cases:edit("1", "C1", "2", "reason", "changed"); assert(ok and item.reason == "changed")
  ok, item = cases:edit("1", "C1", "2", "remove"); assert(ok and not item.active)
  ok, item = cases:modlog("1", "status"); assert(ok and item == "")
end)
test("case receipts compact duplicate case documents and migrate legacy replay values", function()
  local store = memory_store()
  local cases = Cases.new(store, function() return 100 end)
  local ok, item = cases:warn("8", "2", "3", "reason", "900")
  assert(ok and item.id == "C1")
  assert(store.data["8"].receipts["900"].case_id == "C1")
  ok, item = cases:warn("8", "2", "3", "different retry payload", "900")
  assert(ok and item.id == "C1" and item.reason == "reason")

  local legacy = { id = "C9", guild = "9", action = "warn", target = "4", moderator = "2",
    reason = "old record", timestamp = 90, active = true }
  store.data["9"] = { guild = "9", accounts = {}, cases = { clone(legacy) }, staff = {}, journal = {},
    receipts = { ["901"] = clone(legacy) }, next_case = 10 }
  local replayed, saved = cases:warn("9", "2", "4", "old retry", "901")
  assert(replayed and saved.id == "C9" and saved.reason == "old record")
  assert(store.data["9"].receipts["901"].case_id == "C9", "legacy receipts compact only after a matching case is found")
end)

test("staff notes are private and invalid staff actions fail", function()
  local directory = Directory.new(memory_store(), function() return 100 end)
  assert(not directory:apply("1", "2", "3", "promote"))
  assert(not directory:apply("1", "2", "3", "note", "note"))
  assert(directory:apply("1", "2", "3", "add"))
  assert(directory:apply("1", "2", "3", "note", "private", "55"))
  assert(directory:apply("1", "2", "3", "note", "private", "55"))
  local ok, entry = directory:apply("1", "2", "3", "notes"); assert(ok and entry.notes[1].text == "private")
  assert(#entry.notes == 1)
  local router = Router.new(); Staff.register(router, directory)
  local reply, ephemeral
  local ctx = { guild = { id = "1" }, author = { id = "2" }, member = { permissions = "0" },
    respond = function(_, message, options) reply, ephemeral = message, options.ephemeral end }
  local allowed, reason = router:dispatch("staffinfo", ctx)
  assert(not allowed and reason == "permission_denied" and ephemeral and reply:find("permission"))
end)
test("staff receipt migration preserves legacy replays and unrelated receipts", function()
  local store = memory_store()
  local data = { guild = "42", accounts = {}, cases = {}, staff = {
    ["3"] = { id = "3", active = true, notes = { { author = "2", text = "legacy note", timestamp = 1 } } },
  }, journal = {}, receipts = { ["700"] = { id = "C1", action = "warn", target = "4" } }, next_case = 2 }
  local legacy_ids = {}
  for index = 1005, 1, -1 do
    local id = "200000000000000" .. string.format("%04d", index)
    legacy_ids[index] = id
    data.receipts[id] = { staff_id = "3" }
  end
  store.data["42"] = data
  local directory = Directory.new(store)
  local ok, entry = directory:apply("42", "2", "3", "info", nil, "3000000000000000000")
  assert(ok and entry.id == "3")
  data = store.data["42"]
  assert(data.staff_receipts_migrated and data.staff_receipt_count == Directory.max_receipts)
  assert(data.staff_receipt_watermark == legacy_ids[5])
  assert(data.receipts[legacy_ids[1]] == nil and data.receipts[legacy_ids[1005]] == nil)
  assert(data.receipts["700"].id == "C1", "moderation receipts must remain in their legacy namespace")
  local note_count = #data.staff["3"].notes
  local expired, reason = directory:apply("42", "2", "3", "note", "should not run", legacy_ids[1])
  assert(not expired and reason == "replay_expired" and #data.staff["3"].notes == note_count)
  local replayed, same_entry = directory:apply("42", "2", "3", "note", "legacy retry", legacy_ids[6])
  assert(replayed and same_entry.id == "3" and #data.staff["3"].notes == note_count,
    "opaque V1.2 receipts replay without repeating a staff mutation")
  local restarted = Directory.new(memory_store())
  restarted.store.data["42"] = clone(data)
  local after_restart = restarted:apply("42", "2", "3", "info", nil, "3000000000000000000")
  assert(after_restart and restarted.store.data["42"].staff_receipt_count == Directory.max_receipts)
end)

test("staff receipts stay bounded, detect request conflicts, and expire safely after reload", function()
  local store = memory_store()
  store.data["43"] = { guild = "43", accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {}, next_case = 1 }
  local directory = Directory.new(store, function() return 100 end)
  local first_id, last_id
  for index = 1, Directory.max_receipts + 1 do
    local request = "100000000000000" .. string.format("%04d", index)
    local action = index % 2 == 1 and "add" or "remove"
    local ok = directory:apply("43", "2", "3", action, nil, request)
    assert(ok, "new staff operations must continue after receipt rotation")
    if index == 1 then first_id = request end
    last_id = request
  end
  local data = store.data["43"]
  assert(data.staff_receipt_count == Directory.max_receipts and #data.staff_receipt_order == Directory.max_receipts)
  assert(data.staff_receipts[first_id] == nil and data.staff_receipt_watermark == first_id)
  local note_count = #data.staff["3"].notes
  local expired, reason = directory:apply("43", "2", "3", "add", nil, first_id)
  assert(not expired and reason == "replay_expired" and #data.staff["3"].notes == note_count)
  local conflict, conflict_reason = directory:apply("43", "99", "3", "remove", nil, last_id)
  assert(not conflict and conflict_reason == "replay_conflict")
  local replayed = directory:apply("43", "2", "3", "add", nil, last_id)
  assert(replayed and data.staff["3"].active, "retained requests replay without reapplying")
  local reloaded_store = memory_store(); reloaded_store.data["43"] = clone(data)
  local after_restart = Directory.new(reloaded_store, function() return 101 end)
  local old_again, old_reason = after_restart:apply("43", "2", "3", "add", nil, first_id)
  assert(not old_again and old_reason == "replay_expired")
  local newest_again = after_restart:apply("43", "2", "3", "add", nil, last_id)
  assert(newest_again and reloaded_store.data["43"].staff_receipt_count == Directory.max_receipts)
end)

test("hackban validates, checks permissions, stores a case and never replays", function()
  local store = memory_store(); local cases = Cases.new(store, function() return 100 end)
  local router = Router.new(); Moderation.register(router, cases)
  local calls, output, reply = 0, nil, nil
  local ctx = { guild = { id = "1" }, author = { id = "2" }, member = { permissions = "4" }, app_permissions = "4",
    interaction_id = "10", interaction_token = "fixture", bot = { application_id = "3", user = { id = "3" }, rest = {} }, args = {
      user_id = "12345678901234567", reason = "reason", confirm = true },
    get_arg = function(self, key) return self.args[key] end,
    respond = function(_, msg) reply = msg end, edit = function(_, msg) output = msg end }
  function ctx.bot.rest:create_interaction_response() end
  function ctx.bot.rest:get_original_interaction_response() return { id = "42", flags = 64 } end
  function ctx.bot.rest:get_guild() return { owner_id = "9" } end
  function ctx.bot.rest:get_member() error({ code = 10007 }) end
  function ctx.bot.rest:ban(_, user) assert(user == ctx.args.user_id); calls = calls + 1 end
  function ctx.bot.rest:get_ban(_, user) return { user = { id = user } } end
  assert(router:dispatch("hackban", ctx)); assert(calls == 1 and output:find("C1") and output:find("not configured"))
  assert(router:dispatch("hackban", ctx)); assert(calls == 1 and output:find("no ban was repeated"))
  ctx.args.user_id = "invalid"; assert(router:dispatch("hackban", ctx)); assert(calls == 1 and output:find("Invalid"))
  ctx.member.permissions = "0"
  local denied, denial_reason = router:dispatch("hackban", ctx)
  assert(not denied and denial_reason == "permission_denied" and reply:find("permission") and calls == 1)
  ctx.member.permissions, ctx.app_permissions, ctx.args.user_id = "4", "0", "12345678901234567"
  assert(router:dispatch("hackban", ctx)); assert(calls == 1 and output:find("lacks"))
  ctx.app_permissions = "4"
  function ctx.bot.rest:get_roles() return { { id = "1", position = 0 }, { id = "8", position = 1 }, { id = "7", position = 2 } } end
  function ctx.bot.rest:get_member(_, id)
    if id == ctx.args.user_id then return { roles = { "7" } } end
    return { roles = { "8" } }
  end
  assert(router:dispatch("hackban", ctx)); assert(calls == 1 and output:find("hierarchy"))
  function ctx.bot.rest:get_member() error({ code = 10007 }) end
  function ctx.bot.rest:ban() calls = calls + 1; error("ambiguous failure") end
  ctx.interaction_id = "11"
  assert(router:dispatch("hackban", ctx)); assert(calls == 2 and output:find("unknown"))
  assert(router:dispatch("hackban", ctx)); assert(calls == 2 and output:find("no ban was repeated"))
  function ctx.bot.rest:ban() calls = calls + 1 end
  function ctx.bot.rest:get_ban() return {} end
  ctx.interaction_id = "12"
  assert(router:dispatch("hackban", ctx)); assert(calls == 3 and output:find("unknown"))
  ctx.interaction_id = "13"
  assert(router:dispatch("hackban", ctx)); assert(calls == 4 and output:find("unknown"))
end)
test("registry rejects duplicates and help only lists registered commands", function()
  local router = Router.new()
  router:register({ name = "ping", description = "ping", execute = function() end })
  assert(not pcall(router.register, router, { name = "ping", description = "x", execute = function() end }))
  Info.register(router, { started_at = os.time(), health_message = function() return "ok" end })
  local answer; assert(router:dispatch("help", { respond = function(_, text) answer = text end }))
  assert(answer:find("/ping", 1, true) and not answer:find("/ban", 1, true))
end)
test("ordinary information command output does not opt into ephemeral mode", function()
  local router, options = Router.new(), nil
  Info.register(router, { started_at = os.time(), health_message = function() return "ok" end })
  assert(router:dispatch("uptime", { respond = function(_, _, opts) options = opts end }))
  assert(options == nil or options.ephemeral ~= true)
end)
test("command sync keeps unknown commands, patches description-only drift, and rejects schema conflicts", function()
  local posts, patches, remote = 0, 0, { { id = "5", name = "foreign", type = 1, description = "other" } }
  local bot = { client = { get_application_id = function() return "9" end }, http = {}, command_tree = { commands = {
    { to_dict = function() return { name = "ping", type = 1, description = "ping" } end },
    { to_dict = function() return { name = "help", type = 1, description = "help" } end },
  } } }
  function bot.http:get() return remote end
  function bot.http:post(_, spec) posts = posts + 1; return { name = spec.name, id = "8" } end
  function bot.http:patch(path, spec)
    patches = patches + 1
    assert(path == "/applications/9/commands/6")
    return { id = "6", name = spec.name, type = spec.type, description = spec.description, options = spec.options }
  end
  remote[2] = { id = "6", name = "ping", type = 1, description = "stale description" }
  local ok, outcome = SafeSync.run(bot)
  assert(ok and outcome.updated == 1 and outcome.created == 1 and patches == 1 and posts == 1 and #remote == 2)

  patches, posts = 0, 0
  remote[2].default_member_permissions = "1"
  local conflict, reason, details = SafeSync.run(bot)
  assert(not conflict and reason == "command_conflict" and details.command == "ping"
    and details.field == "default_member_permissions" and patches == 0 and posts == 0)
end)
test("command exceptions do not expose internals", function()
  local router = Router.new()
  router:register({ name = "failure", description = "test", execute = function() error("private fixture") end })
  local output, ephemeral
  local ok = router:dispatch("failure", { respond = function(_, message, options) output, ephemeral = message, options.ephemeral end })
  assert(not ok and ephemeral and not output:find("private fixture", 1, true))
end)
io.write(string.format("%d tests, %d failures\n", total, failed))
os.exit(failed == 0 and 0 or 1)
