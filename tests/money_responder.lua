package.path = "./?.lua;./?/init.lua;" .. package.path

local MoneyResponder = require("src.responders.money")
local total, failed = 0, 0
local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then io.stdout:write("ok - " .. name .. "\n")
  else failed = failed + 1; io.stderr:write("not ok - " .. name .. ": " .. tostring(err) .. "\n") end
end

test("money matches exact case-insensitive words with sentence punctuation", function()
  for _, content in ipairs({ "money", "money.", "money!", "money?", "Money", "MONEY!", " money?  ", "money!!!" }) do
    assert(MoneyResponder.matches(content), "should match: " .. content)
  end
end)

test("money does not match substrings, longer sentences, or non-text content", function()
  for _, content in ipairs({ "my money", "money matters", "moneybags", "monetary", "not money!", "", 7, nil }) do
    assert(not MoneyResponder.matches(content), "should not match: " .. tostring(content))
  end
end)

test("gateway integration replies once to guild users and ignores bots, DMs, and other text", function()
  local handler, warnings, replies = nil, 0, {}
  local bot = { on_message = function(_, fn) handler = fn end }
  local logger = { warn = function() warnings = warnings + 1 end }
  assert(MoneyResponder.register(bot, logger) and type(handler) == "function")
  local function dispatch(content, guild_id, author, fail)
    handler({ content = content, guild_id = guild_id, author = author,
      reply = function(_, text) if fail then error("REST failure") end; replies[#replies + 1] = text end })
  end
  for _, content in ipairs({ "money", "money.", "money!", "money?", "Money", "MONEY!" }) do
    dispatch(content, "100", { bot = false })
  end
  dispatch("money", "100", { bot = true })
  dispatch("money", nil, { bot = false })
  dispatch("some money please", "100", { bot = false })
  assert(#replies == 6 and replies[1] == MoneyResponder.reply and warnings == 0)
  dispatch("money", "100", { bot = false }, true)
  assert(#replies == 6 and warnings == 1)
end)

test("registration reports when the gateway wrapper has no message event", function()
  local ok, reason = MoneyResponder.register({}, nil)
  assert(not ok and reason == "message_event_unavailable")
end)

test("gateway intent keeps normal defaults and opts into message content", function()
  local requested
  local intents = assert(MoneyResponder.gateway_intents({ enums = {
    default_intents = function() return 513 end,
    combine_intents = function(...) requested = { ... }; return requested[1] + requested[2] end,
    INTENTS = { MESSAGE_CONTENT = 32768 },
  } }))
  assert(intents == 33281 and requested[1] == 513 and requested[2] == 32768)
end)

io.write(string.format("%d tests, %d failures\n", total, failed))
os.exit(failed == 0 and 0 or 1)
