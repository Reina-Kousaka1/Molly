package.path = "./?.lua;./?/init.lua;" .. package.path

local Settings = require("src.settings.guild")
local Schema = require("src.settings.schema")
local GuildV2 = require("src.persistence.guild_v2")
local Engine = require("src.permissions.engine")
local Router = require("src.commands.router")

local total, failed = 0, 0
local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then print("ok - " .. name) else
    failed = failed + 1
    io.stderr:write("not ok - " .. name .. ": " .. tostring(err) .. "\n")
  end
end

local function clone(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = clone(child) end
  return result
end

local function memory_store()
  local store = { data = {}, busy = {} }
  function store:run(guild, fn)
    if self.busy[guild] then return false, "busy" end
    self.busy[guild] = true
    local data = clone(self.data[guild] or {
      guild = guild, accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {}, next_case = 1,
    })
    local ok, result, changed = fn(data)
    if ok and changed then self.data[guild] = data end
    self.busy[guild] = nil
    return ok, result
  end
  return store
end

local store = memory_store()
store.data["10"] = {
  guild = "10", accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {}, next_case = 1,
  settings = { prefix = "!", currency_name = "credits", currency_symbol = "C" }, modlog = "123",
}
store.data["20"] = {
  guild = "20", accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {}, next_case = 1,
}
local settings = Settings.new(store)

local function base_context(guild, user, roles, channel)
  return {
    guild = { id = guild }, author = { id = user },
    member = { roles = roles or {}, permissions = "0" }, channel = { id = channel or "90" },
  }
end

test("legacy guild settings receive defaults without a persistence migration", function()
  local ok, legacy = settings:get("20")
  assert(ok and legacy.prefix == "." and legacy.currency_name == "coins" and legacy.currency_symbol == "")
  ok, legacy = settings:get("10")
  assert(ok and legacy.prefix == "!" and legacy.currency_name == "credits" and legacy.currency_symbol == "C")
  ok, local_default = settings:get_domain("20", "welcome")
  assert(ok and not local_default.enabled and local_default.channel_id == "")
  assert(store.data["20"].molly_v2 == nil, "reading defaults must not mutate a legacy document")
end)

test("modular settings are additive, guild-scoped, and preserve V1.2 fields", function()
  local ok, saved = settings:update_domain("10", "welcome", function(value)
    value.enabled, value.channel_id, value.message = true, "456", "Hi {mention}, welcome to {server}!"
    return true
  end)
  assert(ok and saved.enabled and saved.channel_id == "456")
  ok, saved = settings:update_domain("20", "welcome", function(value)
    value.enabled = true
    return true
  end)
  assert(ok and saved.channel_id == "")
  local read_a, a = settings:get_domain("10", "welcome")
  local read_b, b = settings:get_domain("20", "welcome")
  assert(read_a and read_b and a.message:find("{server}", 1, true) and b.message == Schema.defaults.welcome.message)
  local legacy_ok, legacy = settings:get("10")
  assert(legacy_ok and legacy.prefix == "!" and legacy.currency_name == "credits" and legacy.currency_symbol == "C")
  assert(store.data["10"].molly_v2.schema_version == GuildV2.version)
  assert(store.data["20"].molly_v2.settings.welcome.enabled == true)
  assert(store.data["10"].modlog == "123")
end)

test("settings schema rejects unsafe template expressions and malformed IDs", function()
  local ok, reason = settings:update_domain("10", "welcome", function(value)
    value.message = "Hello {os.execute}"
    return true
  end)
  assert(not ok and reason == "invalid_setting")
  ok, reason = settings:update_domain("10", "welcome", function(value)
    value.channel_id = "javascript:bad"
    return true
  end)
  assert(not ok and reason == "invalid_setting")
  local partial = assert(Schema.normalize("welcome", { embed = { enabled = true } }))
  assert(partial.embed.enabled and partial.embed.title == "" and partial.embed.description == "")
  local read, value = settings:get_domain("10", "welcome")
  assert(read and value.message == "Hi {mention}, welcome to {server}!" and value.channel_id == "456")
end)

test("legacy moderation and dynamic voice settings retain their original persistence keys", function()
  local ok, moderation = settings:get_domain("10", "moderation")
  assert(ok and moderation.modlog_channel_id == "123")
  assert(settings:update_domain("10", "moderation", function(value)
    value.modlog_channel_id = ""
    return true
  end))
  assert(store.data["10"].modlog == "")
  assert(settings:update_domain("10", "voice", function(value)
    value.trigger_channel_id = "789"
    return true
  end))
  assert(store.data["10"].voice_system.trigger_channel_id == "789")
  assert(store.data["10"].molly_v2.settings.voice == nil, "voice configuration must not be duplicated")
end)

local rules_store = memory_store()
local engine = Engine.new(rules_store, { clock = function() return 100 end })
local registry = { commands = {
  inspect = { name = "inspect" },
  secured = { name = "secured", permission = "manage_guild", permission_override = true },
  locked = { name = "locked", admin = true, category = "Developer" },
  protected = { name = "protected", molly_permission = false },
} }
engine:set_router(registry)

local function apply(guild, command, selector, effect)
  local ok, reason = engine:set_rule(guild, command, selector or {}, effect)
  assert(ok, reason)
end

test("permission rules follow user+channel > role+channel > user > role > channel > guild", function()
  apply("10", "inspect", nil, "deny")
  apply("10", "inspect", { channel_id = "90" }, "allow")
  apply("10", "inspect", { role_id = "70" }, "deny")
  apply("10", "inspect", { user_id = "50" }, "allow")
  apply("10", "inspect", { role_id = "70", channel_id = "90" }, "deny")
  apply("10", "inspect", { role_id = "70", channel_id = "91" }, "deny")
  apply("10", "inspect", { channel_id = "92" }, "allow")
  apply("10", "inspect", { user_id = "50", channel_id = "90" }, "allow")
  local ctx = base_context("10", "50", { "70" }, "90")
  local ok, rule = engine:resolve(ctx, "inspect")
  assert(ok and rule.effect == "allow" and rule.scope == "user_channel")
  ctx.channel.id = "92"
  ok, rule = engine:resolve(ctx, "inspect")
  assert(ok and rule.effect == "allow" and rule.scope == "user", "user beats role")
  ctx.channel.id = "91"
  ok, rule = engine:resolve(ctx, "inspect")
  assert(ok and rule.effect == "deny" and rule.scope == "role_channel", "role+channel beats a user-only allow")
  ctx.author.id = "51"
  ctx.channel.id = "92"
  ok, rule = engine:resolve(ctx, "inspect")
  assert(ok and rule.effect == "deny" and rule.scope == "role", "role beats channel")
  ctx.member.roles = {}
  ctx.channel.id = "90"
  ok, rule = engine:resolve(ctx, "inspect")
  assert(ok and rule.effect == "allow" and rule.scope == "channel", "channel beats guild")
  ctx.channel.id = "91"
  ok, rule = engine:resolve(ctx, "inspect")
  assert(ok and rule.effect == "deny" and rule.scope == "guild")
end)

test("same-specificity role conflicts deterministically deny regardless of role order", function()
  apply("20", "inspect", { role_id = "71", channel_id = "90" }, "allow")
  apply("20", "inspect", { role_id = "72", channel_id = "90" }, "deny")
  local ctx = base_context("20", "50", { "71", "72" }, "90")
  local ok, first = engine:resolve(ctx, "inspect")
  ctx.member.roles = { "72", "71" }
  local again, second = engine:resolve(ctx, "inspect")
  assert(ok and again and first.effect == "deny" and second.effect == "deny" and first.key == second.key)
end)

test("reset removes one scope or all command rules without crossing guilds", function()
  apply("10", "inspect", { role_id = "70" }, "deny")
  apply("20", "inspect", { role_id = "70" }, "allow")
  assert(engine:reset("10", "inspect", { role_id = "70" }))
  local ok, rules = engine:list("10", "inspect")
  assert(ok)
  for _, rule in ipairs(rules) do assert(rule.scope ~= "r:70") end
  ok, rules = engine:list("20", "inspect")
  assert(ok and #rules == 3)
  assert(engine:reset("20", "inspect"))
  ok, rules = engine:list("20", "inspect")
  assert(ok and #rules == 0, "after reset count=" .. tostring(#rules))
end)

test("protected developer commands cannot receive or resolve guild overrides", function()
  local ok, reason = engine:set_rule("10", "locked", {}, "allow")
  assert(not ok and reason == "protected_command")
  ok, reason = engine:set_rule("10", "protected", {}, "deny")
  assert(not ok and reason == "protected_command")
  ok, reason = engine:set_rule("10", "blacklist", {}, "allow")
  assert(not ok and reason == "protected_command")
  ok, reason = engine:reset("10", "locked")
  assert(not ok and reason == "protected_command")
  local allowed = engine:authorize(base_context("10", "50"), registry.commands.locked, true)
  assert(allowed == true)
end)

test("router applies explicit denies and only grants marked permission overrides", function()
  local router, engine2 = Router.new(), Engine.new(memory_store())
  router:set_permission_engine(engine2)
  local ran = 0
  router:register({ name = "inspect", description = "inspect", execute = function() ran = ran + 1 end })
  router:register({ name = "secured", description = "secured", permission = "manage_guild",
    permission_override = true, execute = function(ctx) assert(ctx._molly_permission_override); ran = ran + 1 end })
  router:register({ name = "locked", description = "locked", admin = true, category = "Developer",
    execute = function() ran = ran + 1 end })
  assert(engine2:set_rule("10", "inspect", { user_id = "50" }, "deny"))
  local response
  local ctx = base_context("10", "50")
  ctx.respond = function(_, text) response = text end
  local ok, reason = router:dispatch("inspect", ctx)
  assert(not ok and reason == "permission_denied" and ran == 0 and response:find("permission", 1, true))
  assert(engine2:set_rule("10", "secured", { user_id = "50" }, "allow"))
  ctx.member.permissions = "0"
  assert(router:dispatch("secured", ctx) and ran == 1)
  assert(router:dispatch("locked", ctx) and ran == 2)
end)

test("guild owner permission overrides remain isolated from developer authorization", function()
  apply("10", "inspect", { user_id = "50" }, "deny")
  local ok, rule = engine:resolve(base_context("20", "50"), "inspect")
  assert(ok and rule == nil)
  assert(not engine:set_rule("10", "locked", { user_id = "50" }, "allow"))
end)

test("prefix permission checks resolve live roles and fail closed without them", function()
  local router = Router.new()
  local ran = false
  router:register({ name = "bancheck", description = "permission probe", permission = "ban_members",
    execute = function() ran = true end })
  local rest = {
    get_guild = function() return { owner_id = "99" } end,
    get_roles = function() return { { id = "10", permissions = "0" }, { id = "20", permissions = "4" } } end,
    get_member = function() return { roles = { "20" } } end,
  }
  local ctx = base_context("10", "50")
  ctx.member, ctx.source, ctx.bot = nil, "message", { rest = rest }
  assert(router:dispatch("bancheck", ctx) and ran)
  ran = false
  ctx.bot.rest.get_roles = function() error("unavailable") end
  local response
  ctx.respond = function(_, text) response = text end
  local ok, reason = router:dispatch("bancheck", ctx)
  assert(not ok and reason == "access_unavailable" and not ran and response:find("verify", 1, true))
end)

print(string.format("%d V2 foundation tests, %d failures", total, failed))
os.exit(failed == 0 and 0 or 1)
