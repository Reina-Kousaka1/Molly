package.path = "./?.lua;./?/init.lua;" .. package.path

local Economy = require("src.commands.economy")
local Prefix = require("src.commands.prefix")
local Router = require("src.commands.router")
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
  local economy = Economy.register(router, ledger)
  local prefix = Prefix.new(economy)
  return { store = store, router = router, ledger = ledger, economy = economy, prefix = prefix }
end

local function message(id, guild, author, content)
  local result = { id = id, guild_id = guild, author = { id = author, bot = false }, content = content, replies = {} }
  function result:reply(text) self.replies[#self.replies + 1] = text; return true end
  return result
end

local function slash(env, command, interaction_id, guild, user, arguments)
  local output
  local context = {
    guild = { id = guild }, author = { id = user }, interaction_id = interaction_id, interaction_token = "fixture",
    bot = { application_id = "1", rest = { create_interaction_response = function() return true end } },
    get_arg = function(_, key) return arguments and arguments[key] end,
    edit = function(_, _, options) output = options.embeds[1].description end,
    respond = function() error("slash command should defer") end,
  }
  context._molly_category, context._molly_command_name = "Economy", command
  Response.decorate(context)
  assert(env.router:dispatch(command, context))
  return output
end

test("money, daily, weekly, and work prefixes invoke existing economy handlers", function()
  local env = environment()
  local money = message("1000", "10", "20", ".money")
  assert(env.prefix:dispatch(money) and money.replies[1]:find("Wallet: 0 coins", 1, true))
  local daily = message("1001", "10", "20", ".daily")
  assert(env.prefix:dispatch(daily) and daily.replies[1]:find("daily: 100 coins", 1, true))
  assert(env.prefix:dispatch(daily) and #env.store.data["10"].journal == 1, "same message replay must not pay twice")
  local slash_daily = slash(env, "daily", "1002", "10", "20")
  assert(slash_daily == "That reward is not available yet.", "slash and prefix share the daily cooldown")
  local weekly = message("1003", "10", "20", ".weekly")
  assert(env.prefix:dispatch(weekly) and weekly.replies[1]:find("weekly: 500 coins", 1, true))
  assert(slash(env, "weekly", "1004", "10", "20") == "That reward is not available yet.")
  local work = message("1005", "10", "20", ".work")
  assert(env.prefix:dispatch(work) and work.replies[1]:find("work: 20 coins", 1, true))
  assert(slash(env, "work", "1006", "10", "20") == "That reward is not available yet.")
  assert(env.store.data["10"].accounts["20"].wallet == 620)
end)

test("deposit, withdraw, and pay parse arguments and use shared transfer logic", function()
  local env = environment()
  assert(env.prefix:dispatch(message("1100", "10", "20", ".daily")))
  local deposit = message("1101", "10", "20", ".deposit 40")
  assert(env.prefix:dispatch(deposit) and deposit.replies[1]:find("Wallet: 60; bank: 40", 1, true))
  local withdraw = message("1102", "10", "20", ".withdraw 15")
  assert(env.prefix:dispatch(withdraw) and withdraw.replies[1]:find("Wallet: 75; bank: 25", 1, true))
  local pay = message("1103", "10", "20", ".pay <@123> 30")
  assert(env.prefix:dispatch(pay) and pay.replies[1]:find("Wallet: 45; bank: 25", 1, true))
  assert(env.store.data["10"].accounts["123"].wallet == 30)
  assert(slash(env, "balance", "1104", "10", "20"):find("Wallet: 45 coins", 1, true))
end)

test("prefix message IDs are namespaced and replay without colliding with slash receipts", function()
  local env = environment()
  assert(env.prefix:dispatch(message("1200", "10", "20", ".daily")))
  assert(slash(env, "deposit", "5000", "10", "20", { amount = "10" }):find("Wallet: 90", 1, true))
  local prefix_deposit = message("5000", "10", "20", ".deposit 10")
  assert(env.prefix:dispatch(prefix_deposit))
  assert(env.prefix:dispatch(prefix_deposit))
  local data = env.store.data["10"]
  assert(data.accounts["20"].wallet == 80 and data.accounts["20"].bank == 20)
  assert(data.receipts["5000"].id == "E5000")
  assert(data.receipts["message:5000"].id == "EP5000")
  assert(#data.journal == 3)
  local slash_found, slash_record = env.ledger:transaction("10", "E5000")
  local prefix_found, prefix_record = env.ledger:transaction("10", "Mp-3uw")
  assert(slash_found and prefix_found and slash_record.id ~= prefix_record.id and slash_record.money_id ~= prefix_record.money_id)
end)

test("different prefix messages are different requests and same-user state stays guild-scoped", function()
  local env = environment()
  assert(env.prefix:dispatch(message("1300", "10", "20", ".daily")))
  assert(env.prefix:dispatch(message("1301", "10", "20", ".deposit 10")))
  assert(env.prefix:dispatch(message("1302", "10", "20", ".deposit 5")))
  assert(#env.store.data["10"].journal == 3)
  assert(env.prefix:dispatch(message("1300", "11", "20", ".daily")))
  assert(env.store.data["10"].accounts["20"].wallet == 85)
  assert(env.store.data["11"].accounts["20"].wallet == 100)
end)

test("a Discord reply failure after a committed message is safe to retry", function()
  local env = environment()
  local msg = message("1350", "10", "20", ".daily")
  function msg:reply() error("Discord REST failure") end
  assert(not env.prefix:dispatch(msg))
  assert(env.store.data["10"].accounts["20"].wallet == 100)
  assert(not env.prefix:dispatch(msg))
  assert(env.store.data["10"].accounts["20"].wallet == 100)
  assert(#env.store.data["10"].journal == 1)
end)

test("prefix router registers only one message handler", function()
  local env, handler, registrations = environment(), nil, 0
  local bot = { on_message = function(_, callback) registrations = registrations + 1; handler = callback end }
  assert(env.prefix:register(bot) and registrations == 1 and type(handler) == "function")
  local msg = message("1360", "10", "20", ".daily")
  handler(msg)
  assert(msg.replies[1]:find("daily: 100 coins", 1, true))
end)

test("bot messages, DMs, unknown commands, malformed arguments, and admin-only commands do not mutate economy", function()
  local env = environment()
  local bot_message = message("1400", "10", "20", ".daily"); bot_message.author.bot = true
  assert(not env.prefix:dispatch(bot_message) and #bot_message.replies == 0)
  local dm = message("1401", nil, "20", ".daily")
  assert(not env.prefix:dispatch(dm) and #dm.replies == 0)
  for _, content in ipairs({ ".unknown", ".daily extra", ".deposit", ".pay @not-a-user 2", ".transaction Mabc123", ".eval db", ".shutdown", ".restart", ".update", ".blacklist" }) do
    local msg = message("1402", "10", "20", content)
    env.prefix:dispatch(msg)
  end
  assert(not env.store.data["10"] or #env.store.data["10"].journal == 0)
end)

test("only existing economy commands and the requested money alias have prefix definitions", function()
  local env = environment()
  for _, name in ipairs({ "money", "balance", "bank", "daily", "weekly", "work", "deposit", "withdraw", "pay", "transactions", "leaderboard" }) do
    assert(env.economy and env.economy:definition(name), "missing existing prefix command " .. name)
  end
  assert(not env.prefix:dispatch(message("1500", "10", "20", ".crime")))
end)

io.write(string.format("%d tests, %d failures\n", total, failed))
os.exit(failed == 0 and 0 or 1)
