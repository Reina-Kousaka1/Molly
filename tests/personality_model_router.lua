package.path = "./?.lua;./?/init.lua;" .. package.path

local Router = require("src.personality.model_router")
local passed, failed = 0, 0
local failures = {}
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    io.write("ok - " .. name .. "\n")
  else
    failed = failed + 1
    failures[#failures + 1] = name .. ": " .. tostring(err)
    io.write("not ok - " .. name .. ": " .. tostring(err) .. "\n")
  end
end

local function provider(name, behavior)
  local value = { model = name, calls = {}, control_calls = 0 }
  function value:generate(messages, options)
    self.calls[#self.calls + 1] = { messages = messages, options = options }
    if behavior then return behavior(self, messages, options) end
    return { content = "reply from " .. self.model, model = self.model, total_duration = 1000, load_duration = 200 }
  end
  function value:thinking_control()
    self.control_calls = self.control_calls + 1
    if self.controls == nil then return { supported = false } end
    return self.controls
  end
  function value:running_models()
    return {}
  end
  return value
end

local function new_router(text, vision, options)
  options = options or {}
  return assert(Router.new({
    text_provider = text, vision_provider = vision,
    thinking_enabled = options.thinking_enabled,
    clock = options.clock, logger = options.logger,
  }))
end

local function user(content, images)
  local message = { role = "user", content = content }
  if images then message.images = images end
  return { { role = "system", content = "persona" }, message }
end

test("ordinary direct-mention text routes to Qwen 2.5 by default", function()
  local text, vision = provider("qwen2.5:3b"), provider("qwen3.5:2b")
  local router = new_router(text, vision)
  local result = assert(router:generate(user("hi Molly")))
  assert(result.model == "qwen2.5:3b")
  assert(#text.calls == 1 and #vision.calls == 0)
  assert(text.calls[1].messages[2].content == "hi Molly")
end)

test("the explicit deep trigger routes selected complex text to Qwen 3.5", function()
  local text, vision = provider("qwen2.5:3b"), provider("qwen3.5:2b")
  local router = new_router(text, vision)
  assert(router:generate(user("deep: compare these two ideas carefully")))
  assert(#text.calls == 0 and #vision.calls == 1)
  assert(vision.calls[1].messages[2].content == "compare these two ideas carefully")
  assert(vision.calls[1].options.think == false, "confirmed thinking control stays off by default")
end)

test("one validated image routes only to the vision model", function()
  local text, vision = provider("qwen2.5:3b"), provider("qwen3.5:2b")
  vision.controls = { supported = true, value = "high" }
  local router = new_router(text, vision)
  local image = "AQIDBA=="
  assert(router:generate(user("what is this?", { image })))
  assert(#text.calls == 0 and #vision.calls == 1)
  assert(vision.calls[1].messages[2].images[1] == image)
  assert(vision.calls[1].options.think == false)
end)

test("vision failure on image never falls back to the text-only model", function()
  local text, vision = provider("qwen2.5:3b"), provider("qwen3.5:2b", function()
    return nil, { code = "model_not_found", status = 404 }
  end)
  local router = new_router(text, vision)
  local result, err = router:generate(user("describe", { "AQIDBA==" }))
  assert(result == nil and err.code == "model_not_found")
  assert(#vision.calls == 1 and #text.calls == 0)
end)

test("a missing text model may safely fall back for text-only requests", function()
  local text, vision = provider("qwen2.5:3b", function()
    return nil, { code = "model_not_found", status = 404 }
  end), provider("qwen3.5:2b")
  local router = new_router(text, vision)
  local result = assert(router:generate(user("hello")))
  assert(result.model == "qwen3.5:2b")
  assert(#text.calls == 1 and #vision.calls == 1)
  assert(vision.calls[1].options.think == false)
end)

test("timeouts and other model errors are not silently retried", function()
  for _, code in ipairs({ "timeout", "provider_error" }) do
    local text, vision = provider("qwen2.5:3b", function()
      return nil, { code = code, retryable = true }
    end), provider("qwen3.5:2b")
    local router = new_router(text, vision)
    local result, err = router:generate(user("hello"))
    assert(result == nil and err.code == code)
    assert(#text.calls == 1 and #vision.calls == 0)
  end
end)

test("thinking is requested only when explicitly enabled and reported by the API", function()
  local text, vision = provider("qwen2.5:3b"), provider("qwen3.5:2b")
  vision.controls = { supported = true, value = "high" }
  local now = 100
  local router = new_router(text, vision, { thinking_enabled = true, clock = function() return now end })
  assert(router:generate(user("think: solve this carefully")))
  assert(#text.calls == 0 and #vision.calls == 1)
  assert(vision.calls[1].messages[2].content == "solve this carefully")
  assert(vision.calls[1].options.think == "high")
  assert(vision.control_calls == 1)
  now = now + 2
  assert(router:generate(user("deep: another complex question")))
  assert(vision.calls[2].options.think == false)
  assert(vision.control_calls == 1, "capability result is cached")
end)

test("unsupported Thinking capability fails closed while complex text still works", function()
  local text, vision = provider("qwen2.5:3b"), provider("qwen3.5:2b")
  vision.controls = { supported = false }
  local router = new_router(text, vision, { thinking_enabled = true })
  assert(router:generate(user("think: reason this out")))
  assert(#text.calls == 0 and #vision.calls == 1)
  assert(vision.calls[1].messages[2].content == "reason this out")
  assert(vision.calls[1].options.think == nil)
end)

test("thinking-disabled trigger remains ordinary text on the default model", function()
  local text, vision = provider("qwen2.5:3b"), provider("qwen3.5:2b")
  local router = new_router(text, vision, { thinking_enabled = false })
  assert(router:generate(user("think: just a normal question")))
  assert(#text.calls == 1 and #vision.calls == 0)
  assert(text.calls[1].messages[2].content == "think: just a normal question")
end)

test("empty explicit routes and malformed image arrays fail before provider calls", function()
  local text, vision = provider("qwen2.5:3b"), provider("qwen3.5:2b")
  local router = new_router(text, vision)
  local result, err = router:generate(user("deep: "))
  assert(result == nil and err.code == "invalid_request")
  result, err = router:generate(user("photo", { "one", "two" }))
  assert(result == nil and err.code == "invalid_messages")
  assert(#text.calls == 0 and #vision.calls == 0)
end)

test("router rejects overlapping generation without invoking a second provider call", function()
  local router
  local text = provider("qwen2.5:3b", function()
    local second, err = router:generate(user("overlap"))
    assert(second == nil and err.code == "busy")
    return { content = "first response", model = "qwen2.5:3b" }
  end)
  local vision = provider("qwen3.5:2b")
  router = new_router(text, vision)
  local result = assert(router:generate(user("first request")))
  assert(result.content == "first response")
  assert(#text.calls == 1 and #vision.calls == 0 and router.active == false)
end)

test("model switch and latency fields are reported without prompts", function()
  local logs = {}
  local logger = { info = function(_, event, fields) logs[#logs + 1] = { event = event, fields = fields } end }
  local text, vision = provider("qwen2.5:3b"), provider("qwen3.5:2b")
  local router = new_router(text, vision, { logger = logger })
  assert(router:generate(user("hello")))
  assert(router:generate(user("deep: compare")))
  assert(#logs == 2 and logs[2].event == "personality_model_metrics")
  assert(logs[1].fields.model == "qwen2.5:3b" and logs[1].fields.model_switches == 0)
  assert(logs[2].fields.model == "qwen3.5:2b" and logs[2].fields.model_switches == 1)
  assert(logs[2].fields.total_duration_ns == 1000 and logs[2].fields.load_duration_ns == 200)
  assert(logs[2].fields.route == "complex")
  assert(logs[2].fields.prompt == nil and logs[2].fields.messages == nil)
end)

io.write(string.format("personality model router: %d tests, %d failures\n", passed + failed, failed))
if failed > 0 then
  for _, failure in ipairs(failures) do io.write(" - " .. failure .. "\n") end
  os.exit(1)
end
os.exit(0)
