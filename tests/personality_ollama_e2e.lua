-- End-to-end test: direct Discord mention -> bridge -> shared engine -> dual
-- model router -> Ollama adapters -> real Luvit HTTP transport -> loopback mock.
-- No Discord client, Ollama installation, database, or external network is used.

local deps = os.getenv("MOLLY_TEST_DEPS_DIR") or "./deps"
local separator = package.config:sub(1, 1)
deps = deps:gsub("[/\\]$", "")
package.path = deps .. separator .. "?.lua;" .. deps .. separator .. "?" .. separator .. "init.lua;"
  .. "./?.lua;./?/init.lua;" .. package.path

local url = os.getenv("MOLLY_TEST_OLLAMA_URL")
assert(type(url) == "string" and url:match("^http://127%.0%.0%.1:%d+$"),
  "mock runner must supply an ephemeral loopback Ollama URL")

local Transport = require("src.personality.luvit_transport")
local Ollama = require("src.personality.ollama")
local Engine = require("src.personality.llm_engine")
local ModelRouter = require("src.personality.model_router")
local Bridge = require("src.personality.discord_bridge")
local uv = require("uv")

local function check(condition, description)
  if not condition then
    io.stderr:write("not ok - " .. description .. "\n")
    os.exit(1)
  end
end

local function transport(method, target, options)
  return Transport.request(method, target, options)
end

local text_provider, text_error = Ollama.new({
  url = url,
  model = "molly-e2e-text",
  timeout_ms = 300,
  max_response_bytes = 8192,
  transport = transport,
})
assert(text_provider, "could not create text adapter: " .. tostring(text_error))
local vision_provider, vision_error = Ollama.new({
  url = url,
  model = "molly-e2e-vision",
  timeout_ms = 300,
  max_response_bytes = 8192,
  transport = transport,
})
assert(vision_provider, "could not create vision adapter: " .. tostring(vision_error))
local router = assert(ModelRouter.new({
  text_provider = text_provider,
  vision_provider = vision_provider,
  thinking_enabled = true,
}))

local engine = Engine.new({ enabled = true, provider = router, provider_name = "ollama_dual" })
local sent, warnings = {}, {}
local bridge = Bridge.new({
  enabled = true,
  bot_id = "999999",
  engine = engine,
  image_loader = { prepare = function(attachments)
    assert(type(attachments) == "table" and #attachments == 1)
    return { "AQIDBA==" }
  end },
  send = function(channel_id, content)
    sent[#sent + 1] = { channel_id = channel_id, content = content }
    return true
  end,
  logger = { warn = function(_, event, fields)
    warnings[#warnings + 1] = { event = event, detail = fields and fields.detail }
  end },
  cooldown_seconds = 30,
  max_parallel = 1,
})

local function message(id, user_id, content, overrides)
  local value = {
    id = tostring(id), guild_id = "700001", channel_id = "700002",
    content = content, author = { id = tostring(user_id), bot = false },
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

local function accept(id, user_id, text)
  local accepted, reason = bridge:on_message(message(id, user_id, "<@999999> " .. text))
  check(accepted == true, "bridge accepted " .. text .. " (" .. tostring(reason) .. ")")
end

local function accept_image(id, user_id, text)
  local accepted, reason = bridge:on_message(message(id, user_id, "<@999999> " .. text, {
    attachments = { { filename = "fixture.png" } },
  }))
  check(accepted == true, "bridge accepted image request (" .. tostring(reason) .. ")")
end

-- These must never reach the mock server; Python verifies the total request
-- count and exact order after this process exits.
check(not bridge:on_message(message("1001", "10", "<@999999> ignored", {
  author = { id = "10", bot = true },
})), "bot messages are ignored")
local direct_message = message("1002", "11", "<@999999> ignored")
direct_message.guild_id = nil
check(not bridge:on_message(direct_message), "DM messages are ignored")
check(not bridge:on_message(message("1003", "12", "ordinary text")), "non-mentions are ignored")

local first = message("2001", "20", "<@999999> say hello")
check(bridge:on_message(first) == true, "direct mention is accepted")
local duplicate, duplicate_reason = bridge:on_message(first)
check(not duplicate and duplicate_reason == "duplicate", "duplicate in-flight message is denied")

local phase = 1
local poll = uv.new_timer()
local watchdog = uv.new_timer()

local function shutdown(code)
  poll:stop()
  watchdog:stop()
  poll:close()
  watchdog:close()
  if code == 0 then io.write("personality Ollama/Discord E2E: pass (real Luvit HTTP transport)\n") end
  if code ~= 0 then os.exit(code) end
end

watchdog:start(12000, 0, function()
  local details = {}
  for _, warning in ipairs(warnings) do
    local detail = type(warning.detail) == "string" and warning.detail or "unknown"
    details[#details + 1] = detail .. (type(warning.location) == "string" and "@" .. warning.location or "")
  end
  io.stderr:write("not ok - E2E timed out; current phase " .. tostring(phase)
    .. "; replies=" .. tostring(#sent) .. "; bridge_parallel=" .. tostring(bridge.parallel)
    .. "; warnings=" .. table.concat(details, ",") .. "\n")
  shutdown(1)
end)

poll:start(10, 10, function()
  if phase == 1 and #sent == 1 then
    check(sent[1].channel_id == "700002", "reply uses the source channel")
    check(sent[1].content == "bestie @\226\128\139everyone <\226\128\139@123> here's a real transport check 💗",
      "model output is sanitized and delivered once")
    phase = 2
    accept("2002", "21", "deep: compare this carefully")
  elseif phase == 2 and #sent == 2 then
    check(sent[2].content == "Molly used the vision route 🎀", "explicit deep route returns one reply")
    phase = 3
    accept_image("2003", "22", "what is in this picture?")
  elseif phase == 3 and #sent == 3 then
    check(sent[3].content == "Molly checked the picture 🎀", "image route returns one reply")
    phase = 4
    accept("2004", "23", "simulate header timeout")
  elseif phase == 4 and bridge.parallel == 0 then
    check(#sent == 3, "timed-out provider request sends no reply")
    check(#warnings == 1 and warnings[1].detail == "timeout", "transport timeout is diagnosed safely")
    phase = 5
    accept("2005", "24", "simulate body timeout")
  elseif phase == 5 and bridge.parallel == 0 then
    check(#sent == 3, "body timeout sends no reply")
    check(#warnings == 2 and warnings[2].detail == "timeout", "body timeout releases the bridge slot")
    phase = 6
    accept("2006", "25", "simulate provider error")
  elseif phase == 6 and bridge.parallel == 0 then
    check(#sent == 3, "provider HTTP failure sends no reply")
    check(#warnings == 3 and warnings[3].detail == "provider_error", "provider status is diagnosed safely")
    phase = 7
    accept("2007", "26", "recover please")
  elseif phase == 7 and #sent == 4 then
    check(sent[4].content == "Molly recovered after a provider failure 🎀", "later request recovers normally")
    check(bridge.parallel == 0, "all bridge concurrency reservations are released")
    shutdown(0)
  end
end)
