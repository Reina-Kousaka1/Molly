package.path = "./?.lua;./?/init.lua;" .. package.path
local Engine = require("src.personality.engine")
local Presence = require("src.presence.rotation")
local Config = require("src.config")

local total, failed = 0, 0
local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then print("ok - " .. name)
  else failed = failed + 1; io.stderr:write("not ok - " .. name .. ": " .. tostring(err) .. "\n") end
end
local function clone(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for key, item in pairs(value) do copy[key] = clone(item) end
  return copy
end
local function make_store()
  local store = { data = {}, unavailable = false, commits = 0 }
  function store:run(guild, fn)
    if self.unavailable then return false, "unavailable" end
    local data = clone(self.data[guild] or { molly_v2 = { schema_version = 1 } })
    local ok, result, changed = fn(data)
    if ok and changed then self.data[guild] = data; self.commits = self.commits + 1 end
    return ok, result
  end
  return store
end
local function message(id, user, content, guild, channel)
  return { id = tostring(id), guild_id = tostring(guild or "10"), channel_id = tostring(channel or "20"),
    author = { id = tostring(user), bot = false }, content = content, replies = {},
    reply = function(self, text) self.replies[#self.replies + 1] = text; return true end }
end
local function make_engine(store, clock, options)
  options = options or {}
  return Engine.new({ store = store, clock = clock, random = options.random or function(low) return low end,
    timezone_offset_minutes = options.offset or 0, presence = options.presence, logger = options.logger })
end
local function state_of(engine, guild)
  local ok, state = engine:inspect(guild)
  assert(ok)
  return state
end

test("message topic changes bounded FOMO, obsession, energy, and keeps data per guild", function()
  local store, now = make_store(), 200000
  local engine = make_engine(store, function() return now end)
  local msg = message(1, 101, "Have you seen that new lip oil?", "10", "20")
  assert(engine:handle_message(msg))
  local ok, state = engine:inspect("10"); assert(ok)
  assert(state.values.fomo >= 2 and state.values.fomo <= 100)
  assert(state.values.obsession >= 0 and state.interests.makeup == 1 and #state.event_ids == 1)
  local _, other = engine:inspect("11")
  assert(other.version == 1 and other.interests.makeup == nil)
end)

test("distinct active participants raise FOMO more than repeated posts from one person", function()
  local solo_store, group_store, now = make_store(), make_store(), 250000
  local solo = make_engine(solo_store, function() return now end)
  local group = make_engine(group_store, function() return now end)
  assert(solo:handle_message(message(1, 201, "new lip gloss color", "10", "20")))
  local solo_fomo = state_of(solo, "10").values.fomo
  assert(group:handle_message(message(1, 201, "new lip gloss color", "10", "20")))
  now = now + 9
  assert(group:handle_message(message(2, 202, "the lip oil packaging is so cute", "10", "20")))
  assert(state_of(group, "10").values.fomo > solo_fomo)
  local before = state_of(group, "10").values.fomo
  now = now + 9
  assert(group:handle_message(message(3, 202, "I need that lip gloss", "10", "20")))
  assert(state_of(group, "10").values.fomo <= before + 1)
end)

test("same message ID is idempotent and restart retains recent event identity", function()
  local store, now = make_store(), 300000
  local engine = make_engine(store, function() return now end)
  assert(engine:handle_message(message(77, 102, "new lip oil", "10", "20")))
  local before = state_of(engine, "10")
  assert(not engine:handle_message(message(77, 102, "new lip oil", "10", "20")))
  local after = state_of(engine, "10")
  assert(before.values.fomo == after.values.fomo and #after.event_ids == 1)
  local restarted = make_engine(store, function() return now + 2000 end)
  assert(not restarted:handle_message(message(77, 102, "new lip oil", "10", "20")))
  assert(#state_of(restarted, "10").event_ids == 1)
end)

test("duplicate text and rapid single-user posts are damped", function()
  local store, now = make_store(), 400000
  local engine = make_engine(store, function() return now end)
  assert(engine:handle_message(message(1, 103, "new skincare serum", "10", "20")))
  local current = state_of(engine, "10").values.fomo
  assert(not engine:handle_message(message(2, 104, "new skincare serum", "10", "20")))
  now = now + 1
  assert(not engine:handle_message(message(3, 103, "another serum I love", "10", "20")))
  assert(state_of(engine, "10").values.fomo == current)
end)

test("bots, webhooks, DMs, invalid payloads, and mass mentions are ignored", function()
  local store, now = make_store(), 500000
  local engine = make_engine(store, function() return now end)
  local bot = message(1, 105, "lip gloss", "10"); bot.author.bot = true
  local webhook = message(2, 106, "lip gloss", "10"); webhook.webhook_id = "99"
  local dm = message(3, 107, "lip gloss", nil); dm.guild_id = nil
  local mass = message(4, 108, "lip gloss @everyone", "10"); mass.mention_everyone = true
  assert(not engine:handle_message(bot) and not engine:handle_message(webhook) and not engine:handle_message(dm) and not engine:handle_message(mass))
  assert(store.data["10"] == nil)
end)

test("irrelevant messages do not open or write guild persistence", function()
  local store, now = make_store(), 550000
  local engine = make_engine(store, function() return now end)
  assert(not engine:handle_message(message(1, 108, "the weather is lovely", "10", "20")))
  assert(store.commits == 0 and store.data["10"] == nil)
end)

test("failed Discord sends reserve cooldown and do not retry into a reply loop", function()
  local store, now, sends = make_store(), 575000, 0
  local engine = Engine.new({ store = store, clock = function() return now end,
    random = function(low) return low end,
    send = function() sends = sends + 1; return nil, "missing_send_messages_permission" end })
  now = now + 2000
  local first = message(1, 108, "new lip oil", "10", "20")
  local ok, reason = engine:handle_message(first)
  assert(not ok and reason == "send_failed" and sends == 1)
  now = now + 10
  local second = message(2, 109, "new skincare serum", "10", "20")
  assert(engine:handle_message(second) and sends == 1)
  local state = state_of(engine, "10")
  assert(state.last_response_at > 0, "a denied send must keep the persisted guild cooldown")
  local bot_message = message(3, 999, "new lip oil", "10", "20")
  bot_message.author.bot = true
  assert(not engine:handle_message(bot_message) and sends == 1)
end)

test("status self-praise is user-triggered, bounded, and needs active presence", function()
  local store, now = make_store(), 600000
  local engine = make_engine(store, function() return now end)
  assert(engine:handle_message(message(1, 109, "what's up Molly?", "10")))
  local before = state_of(engine, "10").values
  assert(before.ego == 38 and before.self_esteem == 58)
  engine:set_status("Keeping the mod queue moving")
  now = now + 2000
  local msg = message(2, 110, "what's up Molly?", "10")
  assert(engine:handle_message(msg))
  local after = state_of(engine, "10").values
  assert(after.ego == 39 and after.self_esteem == 60)
  assert(#msg.replies == 1 and msg.replies[1]:find("status", 1, true))
  now = now + 2000
  assert(engine:handle_message(message(3, 111, "how are you?", "10")))
  local capped = state_of(engine, "10").values
  assert(capped.ego == after.ego and capped.self_esteem == after.self_esteem)
end)

test("compliments affect self-esteem without increasing FOMO", function()
  local store, now = make_store(), 700000
  local engine = make_engine(store, function() return now end)
  assert(engine:handle_message(message(1, 111, "you are amazing Molly", "10")))
  local state = state_of(engine, "10")
  assert(state.values.self_esteem == 60)
  local fomo = state.values.fomo
  now = now + 9
  assert(engine:handle_message(message(2, 112, "you are amazing Molly too", "10")))
  assert(state_of(engine, "10").values.fomo == fomo)
end)

test("response probability is bounded by cooldown and startup recovery", function()
  local store, now = make_store(), 800000
  local engine = make_engine(store, function() return now end)
  local during_recovery = message(1, 112, "new lip oil", "10", "20")
  assert(engine:handle_message(during_recovery) and #during_recovery.replies == 0)
  now = now + 2000
  local first = message(2, 113, "another lip oil discovery", "10", "20")
  assert(engine:handle_message(first) and #first.replies == 1)
  now = now + 10
  local second = message(3, 114, "new lip oil", "10", "21")
  assert(engine:handle_message(second) and #second.replies == 0)
end)

test("unavailable persistence fails closed without sending spontaneous replies", function()
  local store, now = make_store(), 900000
  store.unavailable = true
  local engine = make_engine(store, function() return now end)
  now = now + 2000
  local msg = message(1, 115, "new skincare serum", "10")
  local ok, reason = engine:handle_message(msg)
  assert(not ok and reason == "unavailable" and #msg.replies == 0)
end)

test("recovery resumes after reconnect without duplicate event registration", function()
  local store, now = make_store(), 1000000
  local engine = make_engine(store, function() return now end)
  local listeners = 0
  local bot
  bot = { on_message = function(_, callback) listeners = listeners + 1; bot.callback = callback end }
  assert(engine:register(bot) and not engine:register(bot) and listeners == 1)
  engine:on_disconnect(); now = now + 1; engine:on_reconnect()
  assert(engine.recovery_until == now + Engine.recovery_seconds)
end)

test("legacy or malformed persistence recovers with validated bounded values", function()
  local store = make_store()
  store.data["10"] = { molly_v2 = { schema_version = 1,
    personality = { version = 1, fomo = 900, ego = -8, mood = "oops", self_esteem = 70,
      interests = { makeup = 99999 }, topic = "unknown", event_ids = { string.rep("x", 300), "42" } } } }
  local engine = make_engine(store, function() return 1100000 end)
  local state = state_of(engine, "10")
  assert(state.version == 1 and state.values.fomo == 100 and state.values.ego == 0 and state.values.self_esteem == 70)
  assert(state.interests.makeup == 1000 and state.current_topic ~= "unknown" and #state.event_ids == 1)
end)

test("flat V1.2 personality fields remain readable", function()
  local store = make_store()
  store.data["10"] = { molly_v2 = { schema_version = 1, personality = {
    fomo = 73, ego = 61, self_esteem = 66, social_energy = 48, topic = "makeup", updated_at = 1500000,
  } } }
  local state = state_of(make_engine(store, function() return 1500100 end), "10")
  assert(state.values.fomo == 73 and state.values.ego == 61 and state.values.self_esteem == 66)
  assert(state.values.social_energy == 48 and state.current_topic == "makeup" and state.last_evolved_at == 1500000)
end)

test("unknown future personality schema fails safely without overwriting it", function()
  local store = make_store()
  store.data["10"] = { molly_v2 = { schema_version = 1, personality = { version = 2, fomo = 90 } } }
  local engine = make_engine(store, function() return 1500000 end)
  local ok, reason = engine:handle_message(message(1, 901, "lip oil is trending", "10", "20"))
  assert(not ok and reason == "unsupported_schema")
  assert(store.data["10"].molly_v2.personality.version == 2 and store.data["10"].molly_v2.personality.fomo == 90)
end)

test("dayparting respects an explicit UTC offset and late-night excitement is bounded", function()
  local state = Engine.normalize_state(nil)
  local fixed_random = function(low, high) if low == 1 and high == 100 then return 1 end; return low end
  Engine.evolve(state, 1793314800, 0, fixed_random)
  assert(state.values.fomo <= 40 and state.values.social_energy <= 29)
  local spike_at = state.last_fomo_spike_at
  Engine.evolve(state, 1793316000, 0, fixed_random)
  assert(state.last_fomo_spike_at == spike_at)
  local morning = Engine.normalize_state(nil)
  Engine.evolve(morning, 1793314800, -600, function(low) return low end)
  assert(morning.values.social_energy >= 60)
end)

test("conversation FOMO has a guild-level rolling gain cap", function()
  local store, now = make_store(), 1300000
  local engine = make_engine(store, function() return now end)
  for id = 1, 20 do
    assert(engine:handle_message(message(id, 500 + id, "lip oil trend " .. id, "10", "20")))
  end
  local state = state_of(engine, "10")
  assert(state.fomo_window_gain == 12 and state.values.fomo <= 42)
end)

test("personality UTC offset is optional, validated, and configurable", function()
  local config = assert(Config.load({ MOLLY_DISCORD_TOKEN = "fixture", MOLLY_PERSONALITY_UTC_OFFSET_MINUTES = "330" }))
  assert(config.personality.utc_offset_minutes == 330)
  local invalid, errors = Config.load({ MOLLY_DISCORD_TOKEN = "fixture", MOLLY_PERSONALITY_UTC_OFFSET_MINUTES = "900" })
  assert(not invalid and errors[1] == "MOLLY_PERSONALITY_UTC_OFFSET_MINUTES")
  local default = assert(Config.load({ MOLLY_DISCORD_TOKEN = "fixture" }))
  assert(default.personality.utc_offset_minutes == 0)
end)

test("persistent message-ID ring stays bounded under a burst", function()
  local store, now = make_store(), 1200000
  local engine = make_engine(store, function() return now end)
  for id = 1, 180 do
    now = now + 9
    engine:handle_message(message(id, 300 + id, "lip oil topic " .. id, "10", "20"))
  end
  assert(#state_of(engine, "10").event_ids == 128)
end)

test("ephemeral flood maps stay capped even when timestamps are identical", function()
  local store, now = make_store(), 1400000
  local engine = make_engine(store, function() return now end)
  for id = 1, 60 do
    local msg = message(id, 1000 + id, "lip oil channel topic " .. id, "10", 2000 + id)
    assert(engine:handle_message(msg))
  end
  local guild = engine.runtime_guilds["10"]
  local channels = 0
  for _ in pairs(guild.participants) do channels = channels + 1 end
  assert(channels <= 50)
  for id = 1, 305 do
    engine:handle_message(message(id, 3000 + id, "skincare topic " .. id, 5000 + id, 6000 + id))
  end
  local guilds = 0
  for _ in pairs(engine.runtime_guilds) do guilds = guilds + 1 end
  assert(guilds <= 300)
end)

test("runtime guild eviction preserves the guild currently handling an event", function()
  local store, now = make_store(), 1450000
  local engine = make_engine(store, function() return now end)
  for id = 1, 300 do
    engine.runtime_guilds[tostring(6000 + id)] = { last_seen = now, channels = {}, users = {},
      fingerprints = {}, participants = {} }
  end
  engine:_runtime("999999", now)
  assert(engine.runtime_guilds["999999"], "the active guild must not be evicted on a timestamp tie")
  local count = 0
  for _ in pairs(engine.runtime_guilds) do count = count + 1 end
  assert(count == 300)
end)

test("presence exposes only the last successfully applied status", function()
  local rotation = Presence.new({ write = function() return true end, schedule = function() return 1 end,
    cancel = function() end, clock = function() return 1793314800 end })
  assert(rotation:get_current() == nil)
  rotation:start()
  assert(type(rotation:get_current()) == "string" and rotation:get_current() ~= "")
  rotation:stop()
end)

io.write(string.format("%d tests, %d failures\n", total, failed))
os.exit(failed == 0 and 0 or 1)
