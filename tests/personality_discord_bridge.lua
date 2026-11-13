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
  local engine = { calls = 0, requests = {}, generate = function(self, request)
    self.calls = self.calls + 1
    self.requests[#self.requests + 1] = request
    if options.failure then error("mock timeout") end
    if options.invalid then return nil, { code = "invalid_response" } end
    return "A safe Molly reply 💗"
  end }
  local bridge = Bridge.new({ enabled = options.enabled ~= false, bot_id = "99", engine = engine,
    clock = options.clock or function() return options.now or 100 end,
    is_prefix_command = options.is_prefix_command,
    image_loader = options.image_loader,
    spawn = options.spawn or function(fn) queue[#queue + 1] = fn end,
    send = function(channel, content) sent[#sent + 1] = { channel = channel, content = content }; return true end,
    cooldown_seconds = 30, max_parallel = options.max_parallel or 1, max_cooldown_entries = 10,
    recent_message_ttl = options.recent_message_ttl, max_recent_messages = options.max_recent_messages })
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
  local dm = message("hi <@99>"); dm.guild_id = nil
  assert(not bridge:on_message(dm))
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
test("completed Discord message IDs remain deduplicated after the user cooldown", function()
  local now = 100
  local bridge, engine, queue = setup({ clock = function() return now end })
  local original = message("<@99> hello", { id = "1001" })
  assert(bridge:on_message(original)); queue[1]()
  now = now + 31
  local handled, reason = bridge:on_message(original)
  assert(not handled and reason == "duplicate")
  assert(engine.calls == 1 and #queue == 1)
end)
test("message deduplication expires and its cache remains bounded", function()
  local now = 100
  local bridge, _, queue = setup({ clock = function() return now end,
    recent_message_ttl = 60, max_recent_messages = 1 })
  assert(bridge:on_message(message("<@99> first", { id = "1001", author = { id = "30" } })))
  queue[1]()
  local handled, reason = bridge:on_message(message("<@99> second", { id = "1002", author = { id = "31" } }))
  assert(not handled and reason == "busy" and bridge.recent_message_count == 1)
  now = now + 61
  assert(bridge:on_message(message("<@99> second", { id = "1002", author = { id = "31" } })))
  assert(bridge.recent_message_count == 1)
end)
test("only one request is accepted by default", function()
  local bridge, _, queue = setup()
  assert(bridge:on_message(message("<@99> one", { id = "1001", author = { id = "30" } })))
  local accepted, reason = bridge:on_message(message("<@99> two", { id = "1002", author = { id = "31" } }))
  assert(not accepted and reason == "busy")
  assert(bridge.parallel == 1 and #queue == 1)
  queue[1](); assert(bridge.parallel == 0)
  local duplicate, duplicate_reason = bridge:on_message(message("<@99> two", { id = "1002", author = { id = "31" } }))
  assert(not duplicate and duplicate_reason == "duplicate", "a busy gateway event must not become a delayed generation on replay")
end)
test("prefix commands after an explicit mention are left to command handling", function()
  local bridge = setup()
  assert(not bridge:on_message(message("<@99> .daily")))
end)
test("a configured prefix command containing a Molly mention is not sent to Ollama", function()
  local bridge, engine, queue = setup({ is_prefix_command = function(msg)
    return msg.content:sub(1, 1) == "!"
  end })
  assert(not bridge:on_message(message("!pay <@99> 5")))
  assert(engine.calls == 0 and #queue == 0)
  assert(bridge:on_message(message("hello <@99>", { id = "1002" })))
end)
test("timeout and malformed provider results are swallowed without Discord sends", function()
  for _, mode in ipairs({ "failure", "invalid" }) do
    local bridge, _, queue, sent = setup({ [mode] = true })
    local request = message("<@99> hello")
    assert(bridge:on_message(request))
    local duplicate, reason = bridge:on_message(request)
    assert(not duplicate and reason == "duplicate" and bridge.parallel == 1)
    queue[1]()
    assert(#sent == 0 and bridge.parallel == 0)
  end
end)
test("generation diagnostics keep safe provider error codes without request content", function()
  local queue, warnings = {}, {}
  local bridge = Bridge.new({ enabled = true, bot_id = "99",
    engine = { generate = function() return nil, { code = "timeout", detail = "never log request text" } end },
    spawn = function(fn) queue[#queue + 1] = fn end,
    logger = { warn = function(_, event, fields) warnings[#warnings + 1] = { event = event, fields = fields } end } })
  assert(bridge:on_message(message("<@99> private content")))
  queue[1]()
  assert(#warnings == 1 and warnings[1].event == "personality_discord_generation_failed")
  assert(warnings[1].fields.detail == "timeout")
  assert(not warnings[1].fields.detail:find("private", 1, true))
  assert(bridge.parallel == 0)
end)
test("thrown async runtime errors are classified without leaking raw details", function()
  local queue, warnings = {}, {}
  local bridge = Bridge.new({ enabled = true, bot_id = "99",
    engine = { generate = function() error("attempt to yield across C boundary /private/path") end },
    spawn = function(fn) queue[#queue + 1] = fn end,
    logger = { warn = function(_, event, fields) warnings[#warnings + 1] = { event = event, fields = fields } end } })
  assert(bridge:on_message(message("<@99> safe test")))
  queue[1]()
  assert(#warnings == 1 and warnings[1].fields.detail == "async_yield_error")
  assert(not tostring(warnings[1].fields.detail):find("private", 1, true))
  assert(bridge.parallel == 0)
end)
test("a failed Ollama call does not poison subsequent requests from other users", function()
  local now, calls, queue = 100, 0, {}
  local engine = { generate = function()
    calls = calls + 1
    if calls == 1 then return nil, { code = "request_failed" } end
    return "Recovered reply"
  end }
  local sent = {}
  local bridge = Bridge.new({ enabled = true, bot_id = "99", engine = engine,
    clock = function() return now end, spawn = function(fn) queue[#queue + 1] = fn end,
    send = function(channel, content) sent[#sent + 1] = { channel = channel, content = content }; return true end })
  assert(bridge:on_message(message("<@99> first", { author = { id = "30" } })))
  queue[1]()
  now = now + 1
  assert(bridge:on_message(message("<@99> second", { id = "1002", author = { id = "31" } })))
  queue[2]()
  assert(calls == 2 and #sent == 1 and sent[1].content == "Recovered reply")
  assert(bridge.parallel == 0)
end)
test("successful mock response sends one bounded reply", function()
  local bridge, _, queue, sent = setup()
  assert(bridge:on_message(message("<@99> hi")))
  queue[1]()
  assert(#sent == 1 and sent[1].channel == "20" and #sent[1].content <= 600)
end)

test("image attachments are passed only after the image loader validates them", function()
  local loader = { prepare = function(_, attachments)
    assert(#attachments == 1)
    return { "AQIDBA==" }
  end }
  local bridge, engine, queue, sent = setup({ image_loader = loader })
  local request = message("<@99> what is this?", {
    attachments = { { filename = "image.png" } },
  })
  assert(bridge:on_message(request))
  queue[1]()
  assert(engine.calls == 1 and engine.requests[1].images[1] == "AQIDBA==")
  assert(engine.requests[1].content == "what is this?")
  assert(#sent == 1)
end)

test("a direct mention with an image and no caption is accepted", function()
  local loader = { prepare = function() return { "AQIDBA==" } end }
  local bridge, engine, queue = setup({ image_loader = loader })
  assert(bridge:on_message(message("<@99>", { attachments = { { filename = "image.png" } } })))
  queue[1]()
  assert(engine.calls == 1 and engine.requests[1].images[1] == "AQIDBA==")
  assert(engine.requests[1].content == "Please describe the image I attached.")
end)

test("invalid or unavailable images never reach the text model and receive a safe fallback", function()
  local invalid = { prepare = function() return nil, "image_content_mismatch" end }
  local bridge, engine, queue, sent = setup({ image_loader = invalid })
  assert(bridge:on_message(message("<@99> describe this", { attachments = { { filename = "bad.png" } } })))
  queue[1]()
  assert(engine.calls == 0 and #sent == 1)
  assert(sent[1].content:find("couldn't safely read", 1, true))

  bridge, engine, queue, sent = setup()
  assert(bridge:on_message(message("<@99> describe this", { attachments = { { filename = "photo.png" } } })))
  queue[1]()
  assert(engine.calls == 0 and #sent == 1)
  assert(sent[1].content:find("couldn't safely read", 1, true))
end)

test("vision model failure never retries a request as text", function()
  local queue, calls, sent = {}, 0, {}
  local bridge = Bridge.new({ enabled = true, bot_id = "99",
    image_loader = { prepare = function() return { "AQIDBA==" } end },
    engine = { generate = function(_, request)
      calls = calls + 1
      assert(request.images ~= nil)
      return nil, { code = "model_not_found" }
    end },
    spawn = function(fn) queue[#queue + 1] = fn end,
    send = function(_, content) sent[#sent + 1] = content; return true end })
  assert(bridge:on_message(message("<@99> what is here?", { attachments = { { filename = "photo.jpg" } } })))
  queue[1]()
  assert(calls == 1 and #sent == 1 and sent[1]:find("couldn't safely read", 1, true))
end)
test("Discord send failures release capacity and do not escape the bridge", function()
  local queue, warnings = {}, 0
  local bridge = Bridge.new({ enabled = true, bot_id = "99", engine = { generate = function() return "reply" end },
    spawn = function(fn) queue[#queue + 1] = fn end, send = function() return false end,
    logger = { warn = function() warnings = warnings + 1 end } })
  assert(bridge:on_message(message("<@99> hello")))
  queue[1]()
  assert(bridge.parallel == 0 and warnings == 1)
end)
test("scheduler failure releases cooldown and message reservations", function()
  local queue, attempts = {}, 0
  local bridge = Bridge.new({ enabled = true, bot_id = "99",
    engine = { generate = function() return "reply" end },
    spawn = function(fn)
      attempts = attempts + 1
      if attempts == 1 then error("scheduler unavailable") end
      queue[#queue + 1] = fn
    end,
    send = function() return true end })
  local request = message("<@99> hello")
  local accepted, reason = bridge:on_message(request)
  assert(not accepted and reason == "spawn_failed")
  assert(bridge.parallel == 0 and bridge.recent_message_count == 0)
  assert(bridge.inflight[request.id] == nil and bridge.cooldowns["10:30"] == nil)
  assert(bridge:on_message(request))
  queue[1]()
  assert(bridge.parallel == 0)
end)
io.write(string.format("personality Discord bridge: %d tests, %d failures\n", passed + failed, failed))
os.exit(failed == 0 and 0 or 1)
