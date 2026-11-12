package.path = "./?.lua;./?/init.lua;" .. package.path
local Bridge = require("src.personality.discord_bridge")
local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1; io.write("ok - " .. name .. "\n")
  else failed = failed + 1; io.write("not ok - " .. name .. ": " .. tostring(err) .. "\n") end
end
local function message(content, overrides)
  local result = { id = "1001", guild_id = "10", channel_id = "20", content = content,
    author = { id = "30", bot = false } }
  for k, v in pairs(overrides or {}) do result[k] = v end
  return result
end
local function setup(options)
  options = options or {}
  local queue, sent = {}, {}
  local engine = { calls = 0, generate = function(self, request)
    self.calls = self.calls + 1
    if options.failure then error("mock timeout") end
    if options.invalid then return nil, { code = "invalid_response" } end
    return "A safe Molly reply 💗"
  end }
  local bridge = Bridge.new({ enabled = options.enabled ~= false, bot_id = "99", engine = engine,
    clock = function() return options.now or 100 end,
    spawn = options.spawn or function(fn) queue[#queue + 1] = fn end,
    send = function(channel, content) sent[#sent + 1] = { channel = channel, content = content }; return true end,
    cooldown_seconds = 30, max_parallel = 2, max_cooldown_entries = 10 })
  return bridge, engine, queue, sent
end

test("disabled feature ignores direct mentions", function()
  local bridge, engine = setup({ enabled = false })
  assert(not bridge:on_message(message("hi <@99>")))
  assert(engine.calls == 0)
end)
test("only direct user mentions are accepted; bots and webhooks ignored", function()
  local bridge = setup()
  assert(not bridge:on_message(message("hello Molly")))
  assert(not bridge:on_message(message("hi <@99>", { author = { id = "31", bot = true } })))
  assert(not bridge:on_message(message("hi <@99>", { webhook_id = "44" })))
  assert(not bridge:on_message(message("hi <@99>", { guild_id = nil })))
  assert(bridge:on_message(message("hi <@!99>")))
end)
test("cooldown and duplicate in-flight IDs constrain repeated requests", function()
  local bridge, engine, queue = setup()
  local first = message("<@99> say hi")
  assert(bridge:on_message(first))
  assert(not bridge:on_message(first))
  assert(not bridge:on_message(message("<@99> again", { id = "1002" })))
  assert(engine.calls == 0 and #queue == 1)
  queue[1]()
  assert(bridge.parallel == 0)
end)
test("parallel work is bounded", function()
  local bridge, _, queue = setup()
  assert(bridge:on_message(message("<@99> one", { id = "1001", author = { id = "30" } })))
  assert(bridge:on_message(message("<@99> two", { id = "1002", author = { id = "31" } })))
  assert(not bridge:on_message(message("<@99> three", { id = "1003", author = { id = "32" } })))
  assert(bridge.parallel == 2 and #queue == 2)
  queue[1](); queue[2](); assert(bridge.parallel == 0)
end)
test("prefix commands after an explicit mention are left to command handling", function()
  local bridge = setup()
  assert(not bridge:on_message(message("<@99> .daily")))
end)
test("timeout and malformed provider results are swallowed without Discord sends", function()
  for _, mode in ipairs({ "failure", "invalid" }) do
    local bridge, _, queue, sent = setup({ [mode] = true })
    assert(bridge:on_message(message("<@99> hello")))
    queue[1]()
    assert(#sent == 0 and bridge.parallel == 0)
  end
end)
test("successful mock response sends one bounded reply", function()
  local bridge, _, queue, sent = setup()
  assert(bridge:on_message(message("<@99> hi")))
  queue[1]()
  assert(#sent == 1 and sent[1].channel == "20" and #sent[1].content <= 600)
end)
io.write(string.format("personality Discord bridge: %d tests, %d failures\n", passed + failed, failed))
os.exit(failed == 0 and 0 or 1)
