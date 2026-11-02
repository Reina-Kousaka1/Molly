package.path = "./?.lua;./?/init.lua;" .. package.path

local Economy = require("src.commands.economy")
local Prefix = require("src.commands.prefix")
local Router = require("src.commands.router")
local Settings = require("src.settings.guild")
local SettingsCommands = require("src.commands.settings")
local Information = require("src.commands.information")
local Smoke = require("src.commands.smoke")
local Response = require("src.discord.response")
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
  for key, child in pairs(value) do result[key] = clone(child) end
  return result
end

local function environment()
  local store = { data = {} }
  function store:run(guild, fn)
    local data = clone(self.data[guild] or { guild = guild, accounts = {}, journal = {}, receipts = {}, cases = {}, staff = {} })
    local ok, result, changed = fn(data)
    if ok and changed then self.data[guild] = data end
    return ok, result
  end
  local router = Router.new()
  local ledger = require("src.economy.ledger").new(store, function() return 100000 end)
  local settings = Settings.new(store)
  local prefix = Prefix.new(router, settings, { clock = function() return 100 end })
  Economy.register(router, ledger, { settings = settings })
  local app = { started_at = 10, health_message = function() return "Status: healthy" end }
  Information.register(router, app)
  Smoke.register(router, app)
  SettingsCommands.register(router, settings, { on_prefix_changed = function(guild, value) prefix:set_prefix(guild, value) end })
  return { store = store, router = router, ledger = ledger, settings = settings, prefix = prefix }
end

local function message(id, guild, author, content)
  local result = { id = id, guild_id = guild, author = { id = author, bot = false }, content = content, replies = {} }
  function result:reply(text) self.replies[#self.replies + 1] = text; return true end
  return result
end

local function slash(env, command, interaction_id, guild, user, arguments, settings_group, settings_action, permissions)
  local output
  local context = {
    guild = { id = guild }, author = { id = user }, member = { permissions = permissions or "0" },
    interaction_id = interaction_id, interaction_token = "fixture",
    bot = { application_id = "1", rest = { create_interaction_response = function() return true end } },
    molly_subcommand = settings_group, molly_subcommand_action = settings_action,
    get_arg = function(_, key) return arguments and arguments[key] end,
    edit = function(_, _, options) output = options.embeds[1].description end,
    respond = function(_, text, options)
      output = options and options.embeds and options.embeds[1].description or text
    end,
  }
  context._molly_category, context._molly_command_name = "Economy", command
  Response.decorate(context)
  local dispatched = env.router:dispatch(command, context)
  return output, dispatched
end

test("default prefix and default currency preserve the existing coins display", function()
  local env = environment()
  assert(env.prefix:dispatch(message("1000", "10", "20", ".money")))
  local msg = message("1001", "10", "20", ".daily")
  assert(env.prefix:dispatch(msg) and msg.replies[1]:find("daily: 100 coins", 1, true))
  assert(env.prefix:dispatch(message("1002", "10", "20", ".balance")))
  assert(msg.replies[1]:find("100 coins", 1, true))
end)

test("general router exposes suitable existing information commands through shared handlers", function()
  local env = environment()
  for _, name in ipairs({ "about", "uptime", "botinfo", "channelinfo", "help" }) do
    local msg = message("1010", "10", "20", "." .. name)
    assert(env.prefix:dispatch(msg), "missing message command " .. name)
    assert(#msg.replies == 1)
  end
  for _, name in ipairs({ "serverinfo", "membercount", "userinfo", "avatar", "roles", "permissions", "roleinfo", "ping", "health" }) do
    assert(not env.router:prefix_definition(name), "unexpected prefix command " .. name)
  end
end)

test("economy prefixes reuse the slash handlers and shared cooldowns in both directions", function()
  local env = environment()
  local daily = message("1100", "10", "20", ".daily")
  assert(env.prefix:dispatch(daily) and daily.replies[1]:find("daily: 100 coins", 1, true))
  assert(env.prefix:dispatch(daily) and #env.store.data["10"].journal == 1)
  assert(slash(env, "daily", "1101", "10", "20") == "That reward is not available yet.")
  assert(slash(env, "weekly", "1102", "10", "20"):find("weekly: 500 coins", 1, true))
  local weekly = message("1103", "10", "20", ".weekly")
  assert(env.prefix:dispatch(weekly) and weekly.replies[1] == "That reward is not available yet.")
  local work = message("1104", "10", "20", ".work")
  assert(env.prefix:dispatch(work) and work.replies[1]:find("work: 20 coins", 1, true))
  assert(slash(env, "work", "1105", "10", "20") == "That reward is not available yet.")
  assert(env.store.data["10"].accounts["20"].wallet == 620)
end)

test("slash daily also blocks an immediate message retry", function()
  local env = environment()
  assert(slash(env, "daily", "1150", "10", "20"):find("daily: 100 coins", 1, true))
  local msg = message("1151", "10", "20", ".daily")
  assert(env.prefix:dispatch(msg) and msg.replies[1] == "That reward is not available yet.")
  assert(#env.store.data["10"].journal == 1)
end)

test("argument-bearing prefixes use shared deposit, withdraw, and pay logic", function()
  local env = environment()
  assert(env.prefix:dispatch(message("1200", "10", "20", ".daily")))
  local deposit = message("1201", "10", "20", ".deposit 40")
  assert(env.prefix:dispatch(deposit) and deposit.replies[1]:find("Wallet: 60 coins; bank: 40 coins", 1, true))
  local withdraw = message("1202", "10", "20", ".withdraw 15")
  assert(env.prefix:dispatch(withdraw) and withdraw.replies[1]:find("Wallet: 75 coins; bank: 25 coins", 1, true))
  local pay = message("1203", "10", "20", ".pay <@123> 30")
  assert(env.prefix:dispatch(pay) and pay.replies[1]:find("Wallet: 45 coins; bank: 25 coins", 1, true))
  assert(env.store.data["10"].accounts["123"].wallet == 30)
  assert(slash(env, "balance", "1204", "10", "20"):find("Wallet: 45 coins", 1, true))
end)

test("message and interaction identities remain namespaced and replay-safe", function()
  local env = environment()
  assert(env.prefix:dispatch(message("1300", "10", "20", ".daily")))
  slash(env, "deposit", "5000", "10", "20", { amount = "10" })
  local msg = message("5000", "10", "20", ".deposit 10")
  assert(env.prefix:dispatch(msg) and env.prefix:dispatch(msg))
  local data = env.store.data["10"]
  assert(data.accounts["20"].wallet == 80 and data.accounts["20"].bank == 20 and #data.journal == 3)
  assert(data.receipts["5000"].id == "E5000" and data.receipts["message:5000"].id == "EP5000")
  local slash_found, slash_record = env.ledger:transaction("10", "E5000")
  local prefix_found, prefix_record = env.ledger:transaction("10", "Mp-3uw")
  assert(slash_found and prefix_found and slash_record.id ~= prefix_record.id and slash_record.money_id ~= prefix_record.money_id)
  local second = message("5001", "10", "20", ".deposit 1")
  assert(env.prefix:dispatch(second) and #data.journal == 4)
end)

test("prefix changes persist per guild and reset to dot without cross-guild effects", function()
  local env = environment()
  local changed = slash(env, "settings", "1400", "11", "20", { value = "!" }, "prefix", "set", "32")
  assert(changed:find("prefix set to `!`", 1, true))
  assert(slash(env, "settings", "1406", "11", "20", nil, "prefix", "show", "32"):find("prefix: `!`", 1, true))
  assert(env.prefix:dispatch(message("1401", "10", "20", ".daily")))
  assert(env.prefix:dispatch(message("1402", "11", "20", "!daily")))
  assert(not env.prefix:dispatch(message("1403", "11", "20", ".work")))
  local ok, settings_a = env.settings:get("10")
  local ok_b, settings_b = env.settings:get("11")
  assert(ok and ok_b and settings_a.prefix == "." and settings_b.prefix == "!")
  slash(env, "settings", "1404", "11", "20", nil, "prefix", "reset", "32")
  assert(env.prefix:dispatch(message("1405", "11", "20", ".work")))
end)

test("prefix validation rejects whitespace, controls, empty, and long values while metacharacters are literal", function()
  local env = environment()
  for _, value in ipairs({ "", "   ", "\n", "a\rb", "123456789" }) do
    local ok, reason = env.settings:set_prefix("10", value)
    assert(not ok and reason == "invalid_prefix")
  end
  assert(env.settings:set_prefix("10", ".*"))
  assert(env.prefix:dispatch(message("1500", "10", "20", ".*daily")))
  assert(not env.prefix:dispatch(message("1501", "10", "20", "!daily")))
  assert(not env.prefix:dispatch(message("1502", "10", "20", "xx.daily")))
end)

test("settings are guild-scoped and currency formatting never changes wallet, bank, or ledger amounts", function()
  local env = environment()
  env.prefix:dispatch(message("1600", "10", "20", ".daily"))
  env.prefix:dispatch(message("1601", "11", "20", ".daily"))
  env.prefix:dispatch(message("1602", "10", "20", ".deposit 25"))
  local account_before = clone(env.store.data["10"].accounts["20"])
  local journal_before = clone(env.store.data["10"].journal)
  assert(env.settings:set_currency_name("10", "Berries"))
  assert(env.settings:set_currency_symbol("10", "🍓"))
  local money = message("1603", "10", "20", ".balance")
  assert(env.prefix:dispatch(money) and money.replies[1]:find("🍓75 Berries", 1, true))
  local other = message("1604", "11", "20", ".balance")
  assert(env.prefix:dispatch(other) and other.replies[1]:find("100 coins", 1, true))
  assert(env.store.data["10"].accounts["20"].wallet == account_before.wallet)
  assert(env.store.data["10"].accounts["20"].bank == account_before.bank)
  assert(#env.store.data["10"].journal == #journal_before)
  for index, entry in ipairs(journal_before) do assert(entry.amount == env.store.data["10"].journal[index].amount) end
  for index, entry in ipairs(journal_before) do assert(entry.id == env.store.data["10"].journal[index].id) end
  local shown = slash(env, "settings", "1605", "10", "20", nil, "economy", "show", "32")
  assert(shown:find("🍓 Berries", 1, true) and shown:find("unchanged", 1, true))
  slash(env, "settings", "1606", "10", "20", nil, "economy", "reset", "32")
  local reset = message("1607", "10", "20", ".balance")
  assert(env.prefix:dispatch(reset) and reset.replies[1]:find("75 coins", 1, true))
end)

test("settings commands require guild-management permission and are slash-only", function()
  local env = environment()
  local denied, dispatched = slash(env, "settings", "1700", "10", "20", { value = "!" }, "prefix", "set", "0")
  assert(not dispatched and denied:find("do not have permission", 1, true))
  assert(not env.prefix:dispatch(message("1701", "10", "20", ".settings prefix set !")))
  assert(not env.prefix:dispatch(message("1702", "10", "20", ".eval db transaction E1")))
  for _, name in ipairs({ "settings", "transaction", "shutdown", "restart", "update", "blacklist", "eval" }) do
    assert(not env.router:prefix_definition(name))
  end
end)

test("legacy guilds receive defaults and additive updates preserve unrelated settings", function()
  local env = environment()
  env.store.data["10"] = { guild = "10", accounts = {}, journal = {}, receipts = {}, cases = {}, staff = {}, settings = { other = "preserved" } }
  local ok, before = env.settings:get("10")
  assert(ok and before.prefix == "." and before.currency_name == "coins" and before.other == "preserved")
  assert(env.settings:set_prefix("10", "m!"))
  assert(env.store.data["10"].settings.other == "preserved")
end)

test("bot messages, DMs, unknown commands, malformed arguments, and REST failures do not duplicate writes", function()
  local env = environment()
  local bot = message("1800", "10", "20", ".daily"); bot.author.bot = true
  assert(not env.prefix:dispatch(bot) and #bot.replies == 0)
  assert(not env.prefix:dispatch(message("1801", nil, "20", ".daily")))
  for _, content in ipairs({ ".unknown", ".daily extra", ".deposit", ".pay @invalid 2" }) do
    env.prefix:dispatch(message("1802", "10", "20", content))
  end
  assert(not env.store.data["10"] or #env.store.data["10"].journal == 0)
  local fail = message("1803", "10", "20", ".daily")
  function fail:reply() error("Discord REST failure") end
  assert(not env.prefix:dispatch(fail))
  assert(not env.prefix:dispatch(fail))
  assert(env.store.data["10"].accounts["20"].wallet == 100 and #env.store.data["10"].journal == 1)
end)

test("global blacklist gate applies to prefix commands through the shared router", function()
  local env = environment()
  local checked = {}
  env.router:set_gate(function(_, definition) checked[#checked + 1] = definition.name; return false, "blacklisted" end)
  local msg = message("1900", "10", "20", ".daily")
  local ok, reason = env.prefix:dispatch(msg)
  assert(not ok and reason == "blacklisted" and msg.replies[1] == "You are globally blacklisted from using Molly.")
  assert(not env.store.data["10"] or #env.store.data["10"].journal == 0)
  assert(not env.prefix:dispatch(message("1901", "10", "20", ".money")) and checked[2] == "balance")
  local response, dispatched = slash(env, "daily", "1902", "10", "20")
  assert(not dispatched and response == "You are globally blacklisted from using Molly.")
end)

test("the generalized prefix router registers one shared Discord message handler", function()
  local env = environment()
  local registered, handler = false, nil
  local client = { on_message = function(_, callback) registered = true; handler = callback end }
  assert(env.prefix:register(client) and registered)
  local msg = message("2000", "10", "20", ".about")
  handler(msg)
  assert(msg.replies[1] and msg.replies[1]:find("Molly", 1, true))
end)

io.write(string.format("%d tests, %d failures\n", total, failed))
os.exit(failed == 0 and 0 or 1)
