package.path = "./?.lua;./?/init.lua;" .. package.path

local Metrics = require("src.observability.metrics")
local Router = require("src.commands.router")
local Developer = require("src.admin.developer")
local Admin = require("src.commands.admin")

local total, failed = 0, 0
local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then io.stdout:write("ok - " .. name .. "\n")
  else failed = failed + 1; io.stderr:write("not ok - " .. name .. ": " .. tostring(err) .. "\n") end
end

test("metrics are bounded, aggregate-only, and track command outcomes and timings", function()
  local now = 100
  local metrics = Metrics.new({ clock = function() return now end, max_commands = 2 })
  local started = metrics:start()
  now = 105; metrics:record("health", "succeeded", started)
  now = 112; metrics:record("ping", "denied", started)
  now = 118; metrics:record("unregistered", "failed", started)
  local snapshot = metrics:snapshot()
  assert(snapshot.totals.calls == 3 and snapshot.totals.succeeded == 1
    and snapshot.totals.denied == 1 and snapshot.totals.failed == 1)
  assert(snapshot.totals.duration_ms == 35 and snapshot.uptime_ms == 18)
  assert(snapshot.command_count == 2 and #snapshot.commands == 2)
  assert(snapshot.commands[1].name == "health" and snapshot.commands[1].metrics.max_duration_ms == 5)
  local encoded = table.concat({ snapshot.commands[1].name, snapshot.commands[2].name })
  assert(not encoded:find("100", 1, true), "metrics must not contain a guild/user ID or argument")
end)

test("router records successful, denied, and failed command dispatches without affecting behavior", function()
  local now = 0
  local metrics = Metrics.new({ clock = function() return now end })
  local router = Router.new()
  router:set_observability(metrics)
  router:register({ name = "ok", description = "ok", execute = function() now = now + 3 end })
  router:register({ name = "secured", description = "secured", permission = "manage_guild", execute = function() error("must not run") end })
  router:register({ name = "broken", description = "broken", execute = function() now = now + 7; error("fixture") end })
  local context = { member = { permissions = "0" }, respond = function() end }
  assert(router:dispatch("ok", context))
  local denied, reason = router:dispatch("secured", context)
  assert(not denied and reason == "permission_denied")
  local broken, failure = router:dispatch("broken", context)
  assert(not broken and failure == "handler_failed")
  local snapshot = metrics:snapshot()
  assert(snapshot.totals.calls == 3 and snapshot.totals.succeeded == 1
    and snapshot.totals.denied == 1 and snapshot.totals.failed == 1)
end)

test("developer observability output is available only through the owner-gated command", function()
  local now = 10
  local metrics = Metrics.new({ clock = function() return now end })
  metrics:start()
  local developer = Developer.new({ metrics = metrics })
  local ok, snapshot = developer:observability()
  assert(ok and snapshot.totals.calls == 0)
  local router = Router.new()
  Admin.register(router, { owners = { ["900"] = true }, blacklist = {}, developer = developer,
    lifecycle = {}, terminate = function() end })
  assert(router.commands.observe and router.commands.observe.admin)
  local response, edited = nil, nil
  local context = { author = { id = "901" }, respond = function(_, text, options) response = { text, options } end }
  assert(router:dispatch("observe", context))
  assert(response and response[2].ephemeral == true and response[1]:find("restricted", 1, true))
  local callback_count = 0
  context.author.id = "900"
  context.guild = nil
  context.molly_subcommand = "metrics"
  context.interaction_id, context.interaction_token = "1000", "fixture"
  context.bot = { application_id = "1001", rest = { create_interaction_response = function(_, _, _, payload)
    callback_count = callback_count + 1; assert(payload.type == 5); return true
  end } }
  context.edit = function(_, text) edited = text; return true end
  assert(router:dispatch("observe", context))
  assert(callback_count == 1 and edited and edited:find("Command metrics", 1, true))
  assert(not edited:find("901", 1, true))
end)

io.stdout:write(string.format("%d observability tests, %d failures\n", total, failed))
if failed > 0 then os.exit(1) end
