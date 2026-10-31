package.path = "./?.lua;./?/init.lua;./deps/?.lua;./deps/?/init.lua;" .. package.path

local Manager = require("src.music.manager")
local Dynamic = require("src.voice.dynamic_channels")
local Panel = require("src.music.panel")
local Personality = require("src.personality")

local total, failed = 0, 0
local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then io.stdout:write("ok - " .. name .. "\n")
  else failed = failed + 1; io.stderr:write("not ok - " .. name .. ": " .. tostring(err) .. "\n") end
end
local function equal(actual, expected) assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual)) end
local function mock_store()
  local store = { data = {} }
  function store:run(guild_id, fn)
    if self.fail then return false, "unavailable" end
    local data = self.data[guild_id] or { guild = guild_id, accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {}, next_case = 1 }
    local ok, result, changed = fn(data)
    if ok and changed then self.data[guild_id] = data elseif ok and not self.data[guild_id] then self.data[guild_id] = data end
    return ok, result
  end
  return store
end

local function music_adapter()
  local adapter = { calls = {}, source_tracks = {
    { encoded = "enc-one", info = { title = "Track One", author = "Artist", length = 90000 } },
    { encoded = "enc-two", info = { title = "Track Two", author = "Artist", length = 100000 } },
  } }
  function adapter:start() return true end
  function adapter:resolve() return true, { self.source_tracks[1], self.source_tracks[2] } end
  function adapter:update_player(guild_id, payload) self.calls[#self.calls + 1] = { guild = guild_id, payload = payload }; return true end
  function adapter:stop_player(guild_id) self.calls[#self.calls + 1] = { guild = guild_id, stop = true }; return true end
  function adapter:destroy_player(guild_id) self.calls[#self.calls + 1] = { guild = guild_id, destroy = true }; return true end
  return adapter
end

test("music playback queues until the Discord voice handshake, then starts in that guild", function()
  local adapter, joins = music_adapter(), {}
  local manager = Manager.new(adapter)
  manager:set_discord_client({ voice_state_update = function(_, guild, channel) joins[#joins + 1] = { guild, channel }; return true end }, "999")
  local ok, result = manager:play("100", "200", "query", "300")
  assert(ok and result.connecting and result.count == 2)
  equal(#joins, 1); equal(joins[1][1], "100"); equal(joins[1][2], "200")
  manager:on_voice_state({ user_id = "999", guild_id = "100", channel_id = "200", session_id = "session" })
  assert(not manager:state("100").voice_ready)
  manager:on_voice_server({ guild_id = "100", endpoint = "voice.example", token = "voice-token" })
  assert(manager:state("100").voice_ready)
  equal(manager:state("100").current.encoded, "enc-one")
  equal(#manager:state("100").queue, 1)
  equal(adapter.calls[1].payload.voice.channelId, "200")
  equal(adapter.calls[2].payload.track.encoded, "enc-one")
  equal(adapter.calls[2].payload.volume, 1000)
end)

test("music state is guild isolated and controls validate and update state", function()
  local adapter = music_adapter()
  local manager = Manager.new(adapter)
  manager:set_discord_client({ voice_state_update = function() return true end }, "999")
  assert(manager:play("100", "200", "query", "300"))
  manager:on_voice_state({ user_id = "999", guild_id = "100", channel_id = "200", session_id = "s1" })
  manager:on_voice_server({ guild_id = "100", endpoint = "voice.example", token = "t1" })
  assert(manager:play("101", "201", "query", "301"))
  equal(manager:state("101").queue[1].requester, "301")
  equal(manager:state("100").current.requester, "300")
  assert(manager:play("100", "200", "query", "300"))
  local ok, reason = manager:control("100", "999", "pause")
  assert(not ok); equal(reason, "not_in_session_voice")
  assert(manager:control("100", "200", "pause")); assert(manager:state("100").paused)
  assert(manager:control("100", "200", "resume")); assert(not manager:state("100").paused)
  assert(manager:control("100", "200", "volume", 73)); equal(manager:state("100").volume, 73)
  assert(manager:control("100", "200", "loop", "queue")); equal(manager:state("100").loop, "queue")
  assert(manager:control("100", "200", "move", { from = 2, to = 1 }))
  equal(manager:state("100").queue[1].encoded, "enc-one")
  assert(manager:control("100", "200", "remove", 1)); equal(#manager:state("100").queue, 2)
  assert(manager:control("100", "200", "skip")); equal(manager:state("100").current.encoded, "enc-two")
  assert(manager:control("100", "200", "replay"))
  assert(manager:control("100", "200", "shuffle"))
  assert(manager:control("100", "200", "clear")); equal(#manager:state("100").queue, 0)
  assert(not manager:control("100", "200", "volume", 101))
  assert(manager:control("100", "200", "disconnect")); assert(manager:state("100") == nil)
  assert(manager:state("101") ~= nil)
end)

test("stale Lavalink track-end events do not skip the replacement track", function()
  local adapter = music_adapter()
  local manager = Manager.new(adapter)
  manager:set_discord_client({ voice_state_update = function() return true end }, "999")
  assert(manager:play("100", "200", "query", "300"))
  manager:on_voice_state({ user_id = "999", guild_id = "100", channel_id = "200", session_id = "s" })
  manager:on_voice_server({ guild_id = "100", endpoint = "v", token = "t" })
  manager:control("100", "200", "skip")
  equal(manager:state("100").current.encoded, "enc-two")
  manager:on_lavalink_event({ op = "event", type = "TrackEndEvent", guildId = "100", reason = "stopped", track = { encoded = "enc-one" } })
  equal(manager:state("100").current.encoded, "enc-two")
end)

test("Lavalink reconnect restores voice and requeues the current track when its session did not resume", function()
  local adapter = music_adapter()
  local manager = Manager.new(adapter)
  manager:set_discord_client({ voice_state_update = function() return true end }, "999")
  assert(manager:play("100", "200", "query", "300"))
  manager:on_voice_state({ user_id = "999", guild_id = "100", channel_id = "200", session_id = "s" })
  manager:on_voice_server({ guild_id = "100", endpoint = "v", token = "t" })
  manager:on_lavalink_event({ type = "disconnected" })
  assert(not manager:state("100").voice_ready)
  local before = #adapter.calls
  manager:on_lavalink_event({ type = "ready", resumed = false })
  assert(manager:state("100").voice_ready)
  equal(manager:state("100").current.encoded, "enc-one")
  assert(#adapter.calls >= before + 2)
end)

local function mock_rest()
  local rest = { next_id = 500, created = {}, deleted = {}, moved = {}, edits = {}, overwrites = {}, channels = {} }
  function rest:create_guild_channel(guild, payload)
    self.next_id = self.next_id + 1
    local channel = { id = tostring(self.next_id), guild_id = guild, type = payload.type, name = payload.name, parent_id = payload.parent_id }
    self.created[#self.created + 1] = channel; self.channels[channel.id] = channel; return channel
  end
  function rest:edit_member(guild, user, payload) self.moved[#self.moved + 1] = { guild, user, payload.channel_id }; return {} end
  function rest:delete_channel(id) self.deleted[#self.deleted + 1] = id; self.channels[id] = nil; return {} end
  function rest:edit_channel(id, payload) self.edits[#self.edits + 1] = { id, payload }; for k, v in pairs(payload) do self.channels[id][k] = v end; return {} end
  function rest:get_channel(id) return self.channels[id] or { id = id, permission_overwrites = self.overwrites[id] or {} } end
  function rest:edit_channel_permissions(id, target, payload)
    self.overwrites[id] = self.overwrites[id] or {}
    self.overwrites[id][target] = payload
    return {}
  end
  return rest
end

local function seed_trigger_category(rest, guild, trigger, category)
  guild, trigger, category = guild or "100", trigger or "200", category or "201"
  rest.channels[trigger] = { id = trigger, guild_id = guild, type = 2, parent_id = category }
  rest.channels[category] = { id = category, guild_id = guild, type = 4 }
end

test("Join-to-Create makes a persisted room, moves the user, transfers ownership, and cleans up", function()
  local store, rest, cleanups = mock_store(), mock_rest(), 0
  seed_trigger_category(rest)
  local dynamic = Dynamic.new(store, { music = { cleanup_guild = function() cleanups = cleanups + 1 end } })
  dynamic:set_runtime(rest, nil, "999")
  assert(dynamic:configure("100", "200"))
  assert(dynamic:on_guild_create({ id = "100", channels = { { id = "200", type = 2 } }, voice_states = {} }))
  dynamic:on_voice_state({ guild_id = "100", user_id = "300", channel_id = "200" })
  equal(#rest.created, 1); equal(#rest.moved, 1)
  local room = rest.created[1].id
  equal(rest.created[1].parent_id, "201")
  equal(rest.moved[1][3], room)
  equal(store.data["100"].voice_system.temporary[room].owner_id, "300")
  dynamic:on_voice_state({ guild_id = "100", user_id = "301", channel_id = room })
  dynamic:on_voice_state({ guild_id = "100", user_id = "300", channel_id = nil })
  equal(store.data["100"].voice_system.temporary[room].owner_id, "301")
  local denied, why = dynamic:owner_action("100", room, "300", "rename", "Not yours", false)
  assert(not denied); equal(why, "permission_denied")
  assert(dynamic:owner_action("100", room, "301", "rename", "Moon Room", false))
  assert(dynamic:owner_action("100", room, "301", "limit", 8, false))
  equal(rest.channels[room].user_limit, 8)
  dynamic:on_voice_state({ guild_id = "100", user_id = "301", channel_id = nil })
  assert(store.data["100"].voice_system.temporary[room] == nil)
  assert(rest.channels[room] == nil)
  equal(cleanups, 1)
end)

test("temporary voice permissions preserve other overwrite bits and enforce owner access", function()
  local store, rest = mock_store(), mock_rest()
  local dynamic = Dynamic.new(store, { rest = rest, bot_id = "999" })
  dynamic.temporary["100"] = { ["600"] = { guild_id = "100", channel_id = "600", owner_id = "300", created_at = 1, user_limit = 0, locked = false } }
  assert(dynamic:owner_action("100", "600", "300", "lock", nil, false))
  equal(rest.overwrites["600"]["100"].deny, "1048576")
  local denied, reason = dynamic:owner_action("100", "600", "301", "unlock", nil, false)
  assert(not denied); equal(reason, "permission_denied")
  assert(dynamic:owner_action("100", "600", "300", "unlock", nil, false))
  equal(rest.overwrites["600"]["100"].deny, "0")
  assert(dynamic:owner_action("100", "600", "300", "permit", "301", false))
  equal(rest.overwrites["600"]["301"].allow, "1048576")
  assert(dynamic:owner_action("100", "600", "300", "reject", "301", false))
  equal(rest.overwrites["600"]["301"].deny, "1048576")
  assert(dynamic:owner_action("100", "600", "300", "transfer", "301", true) == false)
end)

test("restart recovery only removes empty channels recorded by Molly", function()
  local store, rest = mock_store(), mock_rest()
  seed_trigger_category(rest)
  store.data["100"] = { guild = "100", accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {}, next_case = 1,
    voice_system = { trigger_channel_id = "200", temporary = { ["600"] = { owner_id = "300" }, ["601"] = { owner_id = "301" } } } }
  rest.channels["600"] = { id = "600", type = 2 }
  rest.channels["601"] = { id = "601", type = 2 }
  rest.channels["700"] = { id = "700", type = 2 }
  local dynamic = Dynamic.new(store, { rest = rest, bot_id = "999" })
  assert(dynamic:on_guild_create({ id = "100", channels = { { id = "600", type = 2 }, { id = "601", type = 2 }, { id = "700", type = 2 } },
    voice_states = { { user_id = "302", channel_id = "600" }, { user_id = "999", channel_id = "601" } } }))
  assert(rest.channels["600"] ~= nil)
  assert(rest.channels["600"].parent_id == "201")
  assert(rest.channels["601"] == nil)
  assert(rest.channels["700"] ~= nil)
  assert(store.data["100"].voice_system.temporary["600"] ~= nil)
  assert(store.data["100"].voice_system.temporary["601"] == nil)
  assert(store.data["100"].voice_system.temporary["700"] == nil)
end)

test("other bots do not trigger rooms or keep abandoned rooms alive", function()
  local store, rest = mock_store(), mock_rest()
  seed_trigger_category(rest)
  local dynamic = Dynamic.new(store, { rest = rest, bot_id = "999", client = {
    get_user = function(_, id) return id == "998" and { id = id, bot = true } or nil end,
  } })
  assert(dynamic:configure("100", "200"))
  assert(dynamic:on_guild_create({ id = "100", channels = { { id = "200", type = 2 } }, voice_states = {} }))
  dynamic:on_voice_state({ guild_id = "100", user_id = "998", channel_id = "200" })
  equal(#rest.created, 0)
  store.data["100"].voice_system.temporary["600"] = { owner_id = "300" }
  rest.channels["600"] = { id = "600", type = 2 }
  assert(dynamic:on_guild_create({ id = "100", channels = { { id = "600", type = 2 } },
    voice_states = { { user_id = "998", channel_id = "600" } } }))
  assert(rest.channels["600"] == nil)
end)

test("Join-to-Create reports sanitized permission failures for live diagnosis", function()
  local store, events, rest = mock_store(), {}, mock_rest()
  seed_trigger_category(rest)
  function rest:create_guild_channel() error({ code = 50013 }) end
  local dynamic = Dynamic.new(store, { bot_id = "999", logger = {
    info = function(_, event, fields) events[#events + 1] = { event = event, fields = fields } end,
    warn = function(_, event, fields) events[#events + 1] = { event = event, fields = fields } end,
  }, rest = rest })
  assert(dynamic:configure("100", "200"))
  assert(dynamic:on_guild_create({ id = "100", channels = { { id = "200", type = 2 } }, voice_states = {} }))
  assert(dynamic:on_voice_state({ guild_id = "100", user_id = "300", channel_id = "200" }))
  local failure
  for _, item in ipairs(events) do if item.event == "dynamic_voice_create_failed" then failure = item end end
  assert(failure and failure.fields.detail == "channel_create_failed" and failure.fields.discord_code == 50013)
end)

test("Join-to-Create refuses a trigger outside a voice category", function()
  local store, rest = mock_store(), mock_rest()
  rest.channels["200"] = { id = "200", guild_id = "100", type = 2 }
  local dynamic = Dynamic.new(store, { rest = rest })
  local ok, reason = dynamic:configure("100", "200")
  assert(not ok and reason == "trigger_category_missing")
  assert(store.data["100"] == nil)
end)

test("music panel persists one message, reuses it, and recreates only a confirmed missing message", function()
  local store, rest = mock_store(), mock_rest()
  local sends, edits = 0, 0
  rest.send_message = function(_, channel, payload) sends = sends + 1; rest.next_id = rest.next_id + 1; return { id = tostring(rest.next_id), channel_id = channel, payload = payload } end
  rest.edit_message = function(_, channel, message, payload)
    edits = edits + 1
    if rest.not_found then error({ status_code = 404, code = 10008 }) end
    return { id = message, channel_id = channel, payload = payload }
  end
  rest.get_message = function(_, channel, message) return { id = message, channel_id = channel } end
  local panel = Panel.new(store, { bot = { rest = rest } })
  local ok = panel:configure("100", "200")
  assert(ok); equal(sends, 1)
  local old_id = store.data["100"].music_panel.message_id
  assert(panel:refresh("100", nil, true)); equal(edits, 1)
  assert(panel:recover("100"))
  rest.not_found = true
  assert(panel:refresh("100", nil, true)); equal(sends, 2)
  assert(store.data["100"].music_panel.message_id ~= old_id)
end)

test("panel controls require the caller to share Molly's voice channel", function()
  local rest = mock_rest()
  local store = mock_store()
  local state = { voice_channel_id = "200", queue = {}, loop = "off", volume = 100, paused = false }
  local calls = 0
  local manager = {
    state = function() return state end,
    control = function(_, _, _, action, _, options) assert(options.suppress_panel); calls = calls + 1; return true end,
    queue = function() return {}, state end,
  }
  local panel = Panel.new(store, { bot = { rest = rest }, manager = manager })
  local handlers = {}
  local client = { user = { id = "999" }, get_voice_channel_id = function(_, _, user) return user == "300" and "200" or "201" end }
  local wrapper = { client = client, interaction = function(_, custom, callback) handlers[custom] = callback end }
  panel:register_interactions(wrapper, manager)
  local updated
  handlers["molly_music:pause"]({ guild_id = "100", member = { user = { id = "300" }, permissions = "0" }, bot = client,
    defer = function() return true end, update = function(_, text) updated = text end })
  equal(calls, 1); assert(updated)
  local denied
  handlers["molly_music:pause"]({ guild_id = "100", member = { user = { id = "301" }, permissions = "0" }, bot = client,
    respond = function(_, _, opts) denied = opts.ephemeral end })
  equal(calls, 1); assert(denied)
end)

test("personality variants retain their required track information", function()
  for i = 1, 10 do
    local line = Personality.render("music_added", { title = "Track One" }, function() return i % 2 + 1 end)
    assert(line:find("Track One", 1, true))
  end
  assert(Personality.about(1793314800):find("shoes", 1, true))
  local standard = Personality.about(1793574000)
  assert(standard:find("moderation", 1, true) and not standard:find("shoes", 1, true))
  assert(Personality.profile(1793314800) == "succubus")
  assert(Personality.profile(1793574000) == "default")
end)

io.stdout:write(string.format("%d tests, %d failures\n", total, failed))
os.exit(failed == 0 and 0 or 1)
