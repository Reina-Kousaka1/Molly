package.path = "./?.lua;./?/init.lua;" .. package.path
local Router = require("src.commands.router")
local Blacklist = require("src.admin.blacklist")
local Lifecycle = require("src.admin.lifecycle")
local Updater = require("src.admin.updater")
local Admin = require("src.commands.admin")

local total, failed = 0, 0
local function test(name, fn) total = total + 1; local ok, err = pcall(fn); if ok then print("ok - " .. name) else failed = failed + 1; io.stderr:write("not ok - " .. name .. ": " .. tostring(err) .. "\n") end end
local function memory_store()
  local buckets = {}
  return { run = function(_, name, defaults, fn)
    if not buckets[name] then buckets[name] = {}; for k, v in pairs(defaults) do buckets[name][k] = v end end
    local ok, result = fn(buckets[name]); return ok, result
  end, buckets = buckets }
end

test("blacklist add check remove is persistent and idempotent", function()
  local store, blacklist = memory_store(), nil; blacklist = Blacklist.new(store, function() return 100 end)
  assert(blacklist:add("10", "abuse", "99", "1000"))
  local ok, entry = blacklist:check("10"); assert(ok and entry.reason == "abuse" and entry.actor == "99" and entry.created_at == 100)
  assert(blacklist:add("10", "changed", "99", "1000")); ok, entry = blacklist:check("10"); assert(entry.reason == "abuse")
  assert(blacklist:remove("10", "99", "1001")); ok, entry = blacklist:check("10"); assert(ok and entry == nil)
end)

test("central command gate blocks blacklisted users but admin definitions bypass it", function()
  local router, ran = Router.new(), false
  router:set_gate(function(ctx) return ctx.author.id ~= "10", "blacklisted" end)
  router:register({ name = "normal", description = "normal", execute = function() ran = true end })
  router:register({ name = "admin", description = "admin", admin = true, execute = function() ran = true end })
  local response
  local ctx = { author = { id = "10" }, respond = function(_, text) response = text end }
  local ok, reason = router:dispatch("normal", ctx); assert(not ok and reason == "blacklisted" and not ran and response:find("blacklisted", 1, true))
  assert(router:dispatch("admin", ctx) and ran)
end)

test("developer eval rejects Discord admins not explicitly configured", function()
  local router = Router.new()
  local noop = { add = function() end, remove = function() end, check = function() return true end }
  Admin.register(router, { owners = { ["99"] = true }, blacklist = noop, developer = {}, lifecycle = {}, terminate = function() error("must not terminate") end })
  local response
  local ctx = { author = { id = "10" }, guild = { id = "1" }, member = { permissions = "administrator" }, molly_subcommand = "runtime",
    respond = function(_, text) response = text end, get_arg = function() return nil end }
  assert(router:dispatch("eval", ctx)); assert(response:find("restricted", 1, true))
end)

test("lifecycle markers deduplicate requests and clear exactly once", function()
  local lifecycle = Lifecycle.new(memory_store(), { clock = function() return 200 end, version = "1.2" })
  local request = { interaction_id = "100", guild_id = "1", channel_id = "2", requester_id = "3" }
  local ok, marker = lifecycle:request("restart", request); assert(ok and marker.kind == "restart")
  local again, receipt = lifecycle:request("restart", request); assert(again and receipt.accepted)
  local pending_ok, pending = lifecycle:pending(); assert(pending_ok and pending.interaction_id == "100")
  assert(lifecycle:complete("100")); local _, empty = lifecycle:pending(); assert(empty == false)
  local complete_again = lifecycle:complete("100"); assert(not complete_again)
  assert(Lifecycle.EXIT_SHUTDOWN == 0 and Lifecycle.EXIT_RESTART ~= 0 and Lifecycle.EXIT_UPDATE ~= Lifecycle.EXIT_RESTART)
end)

test("normal lifecycle state has no post-restart marker", function()
  local lifecycle = Lifecycle.new(memory_store())
  local ok, pending = lifecycle:pending(); assert(ok and pending == false)
end)

test("updater is loopback-only and never exposes its token in result", function()
  assert(Updater.new({ url = "http://example.com/update", token = "secret", transport = function() end }) == nil)
  local seen
  local updater = assert(Updater.new({ url = "http://127.0.0.1:9188/update", token = "secret", transport = function(_, _, options) seen = options.headers.authorization; return { code = 202 }, "" end }))
  assert(updater:request({ interaction_id = "1", guild_id = "2", channel_id = "3" })); assert(seen == "Bearer secret")
end)

test("transaction list limit contract is capped at twenty", function()
  local Developer = require("src.admin.developer")
  local requested
  local dev = Developer.new({ ledger = { history = function(_, _, _, limit) requested = limit; return true, {} end }, store = {}, seaworld = {} })
  assert(dev:transactions("1", "2", 999)); assert(requested == 20)
end)

print(string.format("%d developer/lifecycle tests, %d failures", total, failed))
os.exit(failed == 0 and 0 or 1)
