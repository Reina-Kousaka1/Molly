package.path = "./?.lua;./?/init.lua;" .. package.path

local Router = require("src.commands.router")
local Economy = require("src.commands.economy")
local Response = require("src.discord.response")
local Ledger = require("src.economy.ledger")

local total, failed = 0, 0
local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then io.stdout:write("ok - " .. name .. "\n")
  else failed = failed + 1; io.stderr:write("not ok - " .. name .. ": " .. tostring(err) .. "\n") end
end

local function invoke(ledger, rest, fail_edit)
  local router, order, edits, responses = Router.new(), {}, {}, {}
  local logger = { error = function(_, event, fields) order[#order + 1] = { event = event, fields = fields } end,
    warn = function(_, event, fields) order[#order + 1] = { event = event, fields = fields } end }
  Economy.register(router, ledger, { logger = logger })
  local context = {
    guild = { id = "100" }, author = { id = "200" }, interaction_id = "300", interaction_token = "fixture",
    bot = { application_id = "400", rest = rest or { create_interaction_response = function() end } },
    get_arg = function() return nil end,
    respond = function(_, content, options) responses[#responses + 1] = { content = content, options = options }; return true end,
    edit = function(_, content, options)
      edits[#edits + 1] = { content = content, options = options }
      if fail_edit and #edits == 1 then error("transport failure") end
      return true
    end,
  }
  context._molly_category, context._molly_command_name = "Economy", "daily"
  Response.decorate(context)
  local ok = router:dispatch("daily", context)
  return ok, order, edits, responses, context
end

test("daily acknowledges first and replies once with the public economy embed", function()
  local callback_count, result = 0, nil
  local rest = { create_interaction_response = function(_, _, _, payload)
    callback_count = callback_count + 1
    assert(payload.type == 5 and payload.data == nil, "public defer omits optional callback data")
    return true
  end }
  local ledger = { change = function(_, guild, user, interaction, kind)
    assert(callback_count == 1, "reward I/O must start only after acknowledgement")
    assert(guild == "100" and user == "200" and interaction == "300" and kind == "daily")
    return true, { amount = 100, wallet = 100, bank = 0, id = "E300" }
  end }
  local ok, order, edits, responses, context = invoke(ledger, rest)
  assert(ok and callback_count == 1 and #edits == 1 and #responses == 0 and context._molly_deferred)
  assert(edits[1].content == nil and edits[1].options.embeds[1].description:find("100 coins", 1, true))
  assert(not edits[1].options.embeds[1].description:find("E300", 1, true))
  assert(not edits[1].options.embeds[1].description:find("Reference:", 1, true))
end)

test("ledger keeps the E transaction ID, supports replay, and looks up legacy journal rows", function()
  local store = { data = {} }
  function store:run(guild, fn)
    local data = self.data[guild] or { guild = guild, accounts = {}, journal = {}, receipts = {}, cases = {}, staff = {} }
    local ok, result, changed = fn(data)
    if ok and changed then self.data[guild] = data end
    return ok, result
  end
  local ledger = Ledger.new(store, function() return 12345 end)
  local ok, result = ledger:change("100", "200", "1566678233296928798", "daily")
  assert(ok and result.id == "E1566678233296928798" and result.money_id == "Mbwi530hzprtq")
  ok, result = ledger:change("100", "200", "1566678233296928798", "daily")
  assert(ok and result.id == "E1566678233296928798" and result.money_id == "Mbwi530hzprtq" and #store.data["100"].journal == 1)
  local found, entry = ledger:transaction("100", "Mbwi530hzprtq")
  assert(found and entry.id == "E1566678233296928798" and entry.money_id == "Mbwi530hzprtq" and entry.user == "200" and entry.guild == "100")
  assert(entry.kind == "daily" and entry.amount >= 1500 and entry.amount <= 3500 and entry.timestamp == 12345 and entry.status == "committed")
  found, entry = ledger:transaction("101", "Mbwi530hzprtq")
  assert(not found and entry == "transaction_not_found")
  found, entry = ledger:transaction("100", "E0000000000000000000")
  assert(not found and entry == "transaction_not_found")
  found, entry = ledger:transaction("100", "unknown")
  assert(not found and entry == "invalid_transaction")
  found, entry = ledger:transaction("100", "MBWI530HZPRTQ")
  assert(found and entry.id == "E1566678233296928798", "Money ID lookup ignores case")
  local history_ok, history = ledger:history("100", "200")
  assert(history_ok and history[1].id == "E1566678233296928798" and history[1].money_id == "Mbwi530hzprtq")
  store.data["100"].journal[#store.data["100"].journal + 1] = {
    id = "E9999999999999999999", guild = "100", user = "201", kind = "pay", amount = 5,
    counterparty = "200", timestamp = 12346, status = "committed",
  }
  found, entry = ledger:transaction("100", "E9999999999999999999")
  assert(found and entry.money_id, "legacy E references remain readable")
  local old_money_id = entry.money_id
  found, entry = ledger:transaction("100", old_money_id)
  assert(found and entry.id == "E9999999999999999999", "legacy rows resolve by their derived Money ID")
  store.data["100"].receipts["888"] = { id = "E888", amount = 2, wallet = 2, bank = 0 }
  store.data["100"].journal[#store.data["100"].journal + 1] = {
    id = "E888", guild = "100", user = "201", kind = "pay", amount = 2,
    counterparty = "200", timestamp = 12344, status = "committed",
  }
  store.data["100"].economy_receipts_migrated = nil -- exercise a one-time upgrade from a legacy store
  local journal_count = #store.data["100"].journal
  ok, result = ledger:change("100", "201", "888", "pay", "2", "200")
  assert(ok and result.id == "E888" and result.money_id == "Moo" and #store.data["100"].journal == journal_count,
    "legacy receipt replay keeps its canonical ID and does not duplicate the journal row")
end)

test("transaction history shows the public Money ID instead of the internal E ID", function()
  local router, acknowledged, edited = Router.new(), false, nil
  Economy.register(router, { history = function()
    return true, { { id = "E600", money_id = "Mgo", kind = "daily", amount = 100, timestamp = 12345 } }
  end })
  local context = { guild = { id = "100" }, author = { id = "200" }, interaction_id = "400", interaction_token = "fixture",
    bot = { application_id = "500", rest = { create_interaction_response = function(_, _, _, payload)
      acknowledged = payload.type == 5; return true
    end } }, edit = function(_, _, options) edited = options.embeds[1].description end }
  context._molly_category, context._molly_command_name = "Economy", "transactions"
  Response.decorate(context)
  assert(router:dispatch("transactions", context) and acknowledged)
  assert(edited:find("Mgo", 1, true) and not edited:find("E600", 1, true))
end)

test("transaction lookup is an ephemeral Manage Server command with journal fields", function()
  local router, acknowledged, edited, lookup = Router.new(), nil, nil, nil
  local ledger = { transaction = function(_, guild, id)
    lookup = { guild = guild, id = id }
    return true, { id = id, money_id = "Mxyz", user = "200", guild = guild, kind = "pay", amount = 25,
      counterparty = "201", timestamp = 12345, status = "committed" }
  end }
  Economy.register(router, ledger)
  assert(router.commands.transaction.default_member_permissions == 32)
  local context = { guild = { id = "100" }, author = { id = "300" }, member = { permissions = "32" },
    interaction_id = "400", interaction_token = "fixture", bot = { application_id = "500", rest = {
      create_interaction_response = function(_, _, _, payload) acknowledged = payload; return true end,
    } }, get_arg = function(_, name) return name == "id" and "Mxyz" or nil end,
    respond = function() error("must defer") end, edit = function(_, text, options)
      edited = text or options.embeds[1].description
    end }
  Response.decorate(context)
  assert(router:dispatch("transaction", context))
  assert(acknowledged.type == 5 and acknowledged.data.flags == 64)
  assert(lookup.guild == "100" and lookup.id == "Mxyz")
  for _, field in ipairs({ "Money ID: Mxyz", "User ID: 200", "Guild ID: 100", "Type: pay",
    "Amount: 25 coins", "Counterparty: 201", "Timestamp: 1970-01-01 03:25 UTC", "Status: committed" }) do
    assert(edited:find(field, 1, true), "missing lookup field: " .. field)
  end
end)

test("transaction lookup rejects members without Manage Server and handles unknown IDs", function()
  local calls = 0
  local router = Router.new()
  Economy.register(router, { transaction = function() calls = calls + 1; return false, "transaction_not_found" end })
  local response
  local denied = { guild = { id = "100" }, author = { id = "200" }, member = { permissions = "0" },
    respond = function(_, text, options) response = { text = text, options = options } end }
  assert(router:dispatch("transaction", denied))
  assert(calls == 0 and response.options.ephemeral and response.text:find("permission", 1, true))
  local acknowledged, edited
  local allowed = { guild = { id = "100" }, author = { id = "200" }, member = { permissions = "32" },
    interaction_id = "400", interaction_token = "fixture", bot = { application_id = "500", rest = {
      create_interaction_response = function(_, _, _, payload) acknowledged = payload; return true end,
    } }, get_arg = function() return "E999" end, edit = function(_, text, options)
      edited = text or options.embeds[1].description
    end }
  Response.decorate(allowed)
  assert(router:dispatch("transaction", allowed))
  assert(acknowledged.data.flags == 64 and edited == "No matching transaction was found in this server.")
end)

test("daily cooldown replies once without claiming or duplicating a reward", function()
  local calls = 0
  local ledger = { change = function() calls = calls + 1; return false, "cooldown" end }
  local ok, _, edits, responses = invoke(ledger)
  assert(ok and calls == 1 and #edits == 1 and #responses == 0)
  assert(edits[1].options.embeds[1].description == "That reward is not available yet.")
end)

test("persistence and invalid-store failures are controlled deferred replies", function()
  for _, reason in ipairs({ "unavailable", "invalid_store" }) do
    local ledger = { change = function() return false, reason end }
    local ok, _, edits, responses = invoke(ledger)
    assert(ok and #edits == 1 and #responses == 0)
    assert(edits[1].options.embeds[1].description ~= "Molly could not complete the request.")
  end
end)

test("unexpected daily handler errors become a controlled reply", function()
  local ledger = { change = function() error("private failure detail") end }
  local ok, order, edits, responses = invoke(ledger)
  assert(ok and #edits == 1 and #responses == 0)
  assert(edits[1].options.embeds[1].description == "Molly could not complete the request.")
  assert(order[1].event == "economy_operation_failed" and order[1].fields.command == "daily")
end)

test("failed initial defer attempts one private fallback response", function()
  local responds = 0
  local rest = { create_interaction_response = function() error("Discord rejected defer") end }
  local ledger = { change = function() error("should not run") end }
  local router = Router.new()
  Economy.register(router, ledger)
  router:register({ name = "probe", description = "not used", execute = function() end })
  local context = { guild = { id = "100" }, author = { id = "200" }, bot = { application_id = "400", rest = rest },
    respond = function(_, _, options) responds = responds + 1; assert(options.ephemeral) end,
    get_arg = function() end }
  -- Dispatching the registered daily command must answer even if defer fails.
  assert(router:dispatch("daily", context))
  assert(responds == 1)
end)

test("a post-defer edit exception uses the router's deferred error edit", function()
  local ledger = { change = function() return true, { amount = 100, wallet = 100, bank = 0, id = "E300" } end }
  local ok, _, edits, responses = invoke(ledger, { create_interaction_response = function() return true end }, true)
  assert(not ok and #edits == 2 and #responses == 0)
  assert(edits[2].options.embeds[1].description == "Molly could not complete that command.")
end)

io.write(string.format("%d tests, %d failures\n", total, failed))
os.exit(failed == 0 and 0 or 1)
