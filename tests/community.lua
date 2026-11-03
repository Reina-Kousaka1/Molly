package.path = "./?.lua;./?/init.lua;" .. package.path

local Store = require("src.persistence.guild_store")
local Settings = require("src.settings.guild")
local AFK = require("src.community.afk")
local Greetings = require("src.community.greetings")
local ActionLog = require("src.community.action_log")
local SelfRoles = require("src.community.self_roles")
local Starboard = require("src.community.starboard")
local CommunityEvents = require("src.community.events")
local Permissions = require("src.discord.permissions")
local Router = require("src.commands.router")
local AFKCommands = require("src.commands.afk")
local GreetingCommands = require("src.commands.greetings")
local ActionLogCommands = require("src.commands.action_logs")
local SelfRoleCommands = require("src.commands.self_roles")
local StarboardCommands = require("src.commands.starboard")

local total, failed = 0, 0
local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then print("ok - " .. name)
  else failed = failed + 1; io.stderr:write("not ok - " .. name .. ": " .. tostring(err) .. "\n") end
end

local function clone(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = clone(item) end
  return result
end

local function memory_store()
  local store = { data = {} }
  function store:run(guild, callback)
    local data = clone(self.data[guild] or { guild = guild, accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {}, next_case = 1 })
    local ok, result, changed = callback(data)
    if ok and changed then self.data[guild] = data end
    return ok, result
  end
  return store
end

local function setup()
  local store = memory_store()
  return store, Settings.new(store)
end

local function reaction(guild, channel, message, user, added)
  return { guild_id = guild, channel_id = channel, message_id = message, user_id = user,
    emoji = { name = "⭐" }, added = added }
end

test("AFK records are per-guild, bounded, idempotent, and clear on return", function()
  local store = memory_store()
  local now, sent = 100, {}
  local afk = AFK.new(store, { clock = function() return now end,
    send = function(channel, payload) sent[#sent + 1] = { channel = channel, payload = payload }; return true end })
  assert(afk:set("1", "20", "in a meeting"))
  assert(afk:set("2", "20", "different guild"))
  local ok, rows = afk:get("1", "20")
  assert(ok and rows["20"].message == "in a meeting")
  local timestamp = rows["20"].timestamp
  assert(afk:set("1", "20", "in a meeting"))
  ok, rows = afk:get("1", "20")
  assert(ok and rows["20"].timestamp == timestamp)

  local msg = { id = "1000", guild_id = "1", channel_id = "30", author = { id = "10" }, mentions = { { id = "20" } } }
  assert(afk:on_message(msg) and #sent == 1)
  assert(sent[1].payload.content:find("in a meeting", 1, true))
  assert(sent[1].payload.allowed_mentions.parse and #sent[1].payload.allowed_mentions.parse == 0)
  assert(not afk:on_message(msg) and #sent == 1)
  now = now + 31
  msg.id = "1001"
  assert(afk:on_message(msg) and #sent == 2)
  msg.id, msg.author, msg.mentions = "1002", { id = "20" }, {}
  assert(afk:on_message(msg) and #sent == 3)
  ok, rows = afk:get("1", "20")
  assert(ok and rows["20"] == nil)
  ok, rows = afk:get("2", "20")
  assert(ok and rows["20"] and rows["20"].message == "different guild")
  assert(not afk:on_message({ guild_id = "1", channel_id = "30", author = { id = "40", bot = true } }))
end)

test("AFK status storage has a per-guild capacity limit", function()
  local afk = AFK.new(memory_store())
  for index = 1, 200 do assert(afk:set("1", tostring(1000 + index), "away")) end
  local ok, reason = afk:set("1", "99999", "away")
  assert(not ok and reason == "capacity")
  assert(afk:set("2", "99999", "away"))
end)

test("greeting templates use bounded variables, private previews, and isolated channel delivery", function()
  local store, settings = setup()
  local sent = {}
  local rest = {
    get_guild = function(_, id) return { id = id, name = id == "1" and "Guild One" or "Guild Two" } end,
    send_message = function(_, channel, payload) sent[#sent + 1] = { channel = channel, payload = payload }; return { id = "900" } end,
  }
  local greetings = Greetings.new(settings, { rest = rest })
  greetings:set_guild("1", "Guild One", 42)
  assert(settings:update_domain("1", "welcome", function(value)
    value.enabled, value.channel_id = true, "200"
    value.message = "Hello {mention}, welcome to {server}; member {member_count}."
    return true
  end))
  local ok, payload = greetings:preview("1", "welcome", { user = { id = "10", username = "@everyone" } })
  assert(ok and payload.content:find("Guild One", 1, true) and payload.content:find("42", 1, true))
  assert(payload.allowed_mentions.parse and payload.allowed_mentions.users[1] == "10")
  assert(greetings:send_event("1", "welcome", { user = { id = "10", username = "@everyone" } }, 43))
  assert(#sent == 1 and sent[1].channel == "200" and sent[1].payload.content:find("43", 1, true))
  local two = greetings:send_event("2", "welcome", { user = { id = "11", username = "Other" } }, 1)
  assert(two and #sent == 1)
  assert(settings:update_domain("1", "welcome", function(value) value.embed.enabled = true; value.embed.title = "Welcome {user}"; return true end))
  ok, payload = greetings:preview("1", "welcome", { user = { id = "12", username = "Preview" } })
  assert(ok and payload.embeds[1].title == "Welcome Preview")
end)

test("action logs honor per-guild event settings and suppress mentions", function()
  local _, settings = setup()
  local sent = {}
  local logs = ActionLog.new(settings, { send = function(channel, payload) sent[#sent + 1] = { channel = channel, payload = payload }; return true end })
  assert(logs:record("1", "ban", "A ban"))
  assert(#sent == 0)
  assert(settings:update_domain("1", "logs", function(value) value.enabled, value.channel_id = true, "300"; return true end))
  assert(logs:record("1", "ban", "@everyone action"))
  assert(#sent == 1 and sent[1].channel == "300")
  assert(sent[1].payload.allowed_mentions.parse and #sent[1].payload.allowed_mentions.parse == 0)
  assert(sent[1].payload.content:find("@", 1, true))
  assert(settings:update_domain("1", "logs", function(value) value.events.ban = false; return true end))
  assert(logs:record("1", "ban", "filtered") and #sent == 1)
  assert(logs:record("2", "ban", "other guild") and #sent == 1)
end)

test("self-roles enforce allowlists, safe role permissions, and bot/actor hierarchy", function()
  local _, settings = setup()
  local members = { ["10"] = { roles = {} }, ["30"] = { roles = { "30" } }, ["999"] = { roles = { "50" } } }
  local roles = {
    { id = "1", position = 0, permissions = "0" },
    { id = "20", position = 2, permissions = "0" },
    { id = "21", position = 1, permissions = tostring(Permissions.flags.manage_roles) },
    { id = "30", position = 4, permissions = "0" },
    { id = "50", position = 5, permissions = tostring(Permissions.flags.manage_roles) },
  }
  local rest = {
    get_guild = function() return { owner_id = "90" } end,
    get_roles = function() return roles end,
    get_member = function(_, _, user) return members[user] end,
    add_role = function(_, _, user, role) members[user].roles[#members[user].roles + 1] = role; return true end,
    remove_role = function(_, _, user, role)
      for i = #members[user].roles, 1, -1 do if members[user].roles[i] == role then table.remove(members[user].roles, i) end end
      return true
    end,
  }
  local service = SelfRoles.new(settings, { rest = rest })
  assert(service:set_allowed("1", "30", "20", true, "999"))
  local ok, result = service:assign("1", "10", "20", true, "999")
  assert(ok and result == "role_added" and members["10"].roles[1] == "20")
  ok, result = service:assign("1", "10", "20", false, "999")
  assert(ok and result == "role_removed" and #members["10"].roles == 0)
  ok, result = service:set_allowed("1", "30", "21", true, "999")
  assert(not ok and result == "dangerous_role")
  ok, result = service:set_allowed("1", "30", "1", true, "999")
  assert(not ok and result == "everyone_role")
  assert(service:set_allowed("1", "30", "20", false, "999"))
  members["10"].roles = { "20" }
  ok, result = service:assign("1", "10", "20", false, "999")
  assert(ok and result == "role_removed", "users can remove a role after an admin disallows it")
  members["10"].roles = {}
  ok, result = service:assign("1", "10", "20", true, "999")
  assert(not ok and result == "role_not_available")
  roles[5].permissions = "0"
  ok, result = service:set_allowed("1", "30", "20", true, "999")
  assert(not ok and result == "bot_missing_manage_roles")
end)

test("starboard edits posts idempotently and removes them below threshold", function()
  local store, settings = setup()
  local counts, now = { ["200"] = 1 }, 100
  local sent, edited, deleted = {}, {}, {}
  local message = { id = "200", guild_id = "1", channel_id = "100", author = { id = "40", username = "Starred" },
    content = "A useful message", attachments = { { url = "https://example.invalid/image.png" } },
    reactions = { { emoji = { name = "⭐" }, count = 1 } } }
  local rest = {
    get_message = function(_, _, id)
      local result = clone(message); result.id = id
      result.reactions[1].count = counts[id] or 0
      return result
    end,
    get_channel = function(_, id) return { id = id, guild_id = "1", nsfw = false } end,
    send_message = function(_, channel, payload) sent[#sent + 1] = { channel = channel, payload = payload }; return { id = "700" } end,
    edit_message = function(_, channel, id, payload) edited[#edited + 1] = { channel = channel, id = id, payload = payload }; return { id = id } end,
    delete_message = function(_, channel, id) deleted[#deleted + 1] = { channel = channel, id = id }; return true end,
  }
  local starboard = Starboard.new(store, settings, { rest = rest, clock = function() return now end })
  assert(settings:update_domain("1", "starboard", function(value)
    value.enabled, value.channel_id, value.threshold = true, "500", 2
    return true
  end))
  local ok, reason = starboard:on_reaction(reaction("1", "100", "200", "10"), true)
  assert(ok and reason == "below_threshold" and #sent == 0)
  counts["200"] = 2
  ok, reason = starboard:on_reaction(reaction("1", "100", "200", "11"), true)
  assert(ok and reason == "posted" and #sent == 1 and sent[1].channel == "500")
  assert(sent[1].payload.allowed_mentions.parse and #sent[1].payload.allowed_mentions.parse == 0)
  assert(sent[1].payload.content:find("Attachments are not copied", 1, true) == nil)
  ok, reason = starboard:on_reaction(reaction("1", "100", "200", "11"), true)
  assert(ok and reason == "duplicate_reaction" and #sent == 1)
  ok, reason = starboard:on_reaction(reaction("1", "100", "200", "12"), true)
  assert(ok and reason == "update_rate_limited" and #edited == 0)
  now = now + 3
  ok, reason = starboard:on_reaction(reaction("1", "100", "200", "13"), true)
  assert(ok and reason == "updated" and #edited == 1 and edited[1].payload.content:find("4", 1, true))
  now = now + 3
  ok, reason = starboard:on_reaction(reaction("1", "100", "200", "13"), false)
  assert(ok and reason == "updated" and #edited == 2)
  now = now + 3
  ok, reason = starboard:on_reaction(reaction("1", "100", "200", "11"), false)
  assert(ok and reason == "updated" and #edited == 3)
  now = now + 3
  ok, reason = starboard:on_reaction(reaction("1", "100", "200", "10"), false)
  assert(ok and #deleted == 1 and deleted[1].id == "700")
end)

test("starboard blocks NSFW source channels from normal destinations", function()
  local store, settings = setup()
  local sent = 0
  local rest = {
    get_message = function(_, channel, id) return { id = id, channel_id = channel, guild_id = "1", author = { id = "50" }, content = "private", reactions = { { emoji = { name = "⭐" }, count = 1 } } } end,
    get_channel = function(_, id) return { id = id, guild_id = "1", nsfw = id == "100" } end,
    send_message = function() sent = sent + 1; return { id = "800" } end,
  }
  assert(settings:update_domain("1", "starboard", function(value) value.enabled, value.channel_id, value.threshold = true, "500", 1; return true end))
  local starboard = Starboard.new(store, settings, { rest = rest })
  local ok, reason = starboard:on_reaction(reaction("1", "100", "201", "10"), true)
  assert(not ok and reason == "channel_safety_check_failed" and sent == 0)
end)

test("community event wiring uses per-guild settings and bounds callbacks", function()
  local store, settings = setup()
  assert(settings:update_domain("1", "welcome", function(value) value.enabled, value.channel_id = true, "200"; return true end))
  assert(settings:update_domain("1", "logs", function(value) value.enabled, value.channel_id = true, "300"; return true end))
  local sent, client_listeners, bot_listeners = {}, {}, {}
  local rest = { send_message = function(_, channel, payload) sent[#sent + 1] = { channel = channel, payload = payload }; return { id = tostring(900 + #sent) } end }
  local client = { rest = rest }
  function client:on(name, callback) client_listeners[name] = client_listeners[name] or {}; client_listeners[name][#client_listeners[name] + 1] = callback end
  local bot = { rest = rest, user = { id = "999" } }
  function bot:on(name, callback) bot_listeners[name] = callback end
  function bot:on_message(callback) self.message_callback = callback end
  local greetings = Greetings.new(settings)
  local logs = ActionLog.new(settings)
  local afk = AFK.new(store)
  local events = CommunityEvents.new({ greetings = greetings, logs = logs, afk = afk })
  assert(events:bind(client, bot) and events:bind(client, bot))
  client_listeners.guild_create[1]({ id = "1", name = "Guild One", member_count = 5 })
  client_listeners.guild_member_add[1]({ guild_id = "1", user = { id = "50", username = "Member" } })
  assert(#sent == 2 and sent[1].channel == "200" and sent[2].channel == "300")
  assert(sent[1].payload.content:find("Guild One", 1, true))
  assert(type(bot.message_callback) == "function" and type(bot_listeners.ready) == "function")
  client_listeners.guild_member_update[1](nil, { guild_id = "1", user = { id = "51" }, roles = { "77" } })
  assert(#sent == 3 and sent[3].channel == "300")
  client_listeners.guild_member_add[1]({ guild_id = "2", user = { id = "60", username = "Other" } })
  assert(#sent == 3)
end)

test("community commands register without configurable aliases", function()
  local store, settings = setup()
  local router = Router.new()
  local greetings = Greetings.new(settings)
  local logs = ActionLog.new(settings)
  local afk = AFK.new(store)
  AFKCommands.register(router, afk)
  GreetingCommands.register(router, settings, greetings, { logs = logs })
  ActionLogCommands.register(router, settings, logs)
  SelfRoleCommands.register(router, SelfRoles.new(settings), { logs = logs })
  StarboardCommands.register(router, settings, { logs = logs })
  for _, name in ipairs({ "afk", "welcome", "goodbye", "logs", "selfroles", "starboard" }) do
    assert(router.commands[name] and router.commands[name].slash)
  end
  assert(router.commands.welcome.default_member_permissions == Permissions.flags.manage_guild)
  assert(router.commands.starboard.default_member_permissions == Permissions.flags.manage_guild)
  assert(router.commands.afk.prefix == nil and router.commands.selfroles.prefix == nil)
end)

print(string.format("%d community tests, %d failures", total, failed))
if failed > 0 then os.exit(1) end
