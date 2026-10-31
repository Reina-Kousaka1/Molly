package.path = "./?.lua;./?/init.lua;" .. package.path

local Router = require("src.commands.router")
local Economy = require("src.commands.economy")
local Response = require("src.discord.response")

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
  assert(edits[1].options.embeds[1].description:find("E300", 1, true))
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
