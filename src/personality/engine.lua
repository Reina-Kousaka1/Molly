local Store = require("src.persistence.guild_store")
local V2 = require("src.persistence.guild_v2")

local Engine = {}
Engine.__index = Engine

local VALUE_KEYS = { "fomo", "obsession", "ego", "self_esteem", "social_energy", "mood" }
local DEFAULTS = { fomo = 24, obsession = 32, ego = 38, self_esteem = 58, social_energy = 42, mood = 58 }
local TOPICS = {
  makeup = { "makeup", "lip oil", "lip gloss", "lipgloss", "blush", "mascara", "highlighter" },
  skincare = { "skincare", "skin care", "glow mask", "serum", "moisturizer", "sunscreen", "face mask" },
  fashion = { "preppy", "outfit", "fashion", "pink outfit", "cardigan", "collection", "clothes", "leggings", "hoodie" },
  accessories = { "hair bow", "bow", "hair clip", "hairclip", "hairband", "tumbler", "stanley cup", "stanley" },
  shopping = { "shopping", "new drop", "new collection", "haul", "buy it", "need it", "wishlist" },
}
local MAX_EVENT_IDS, MAX_RUNTIME_GUILDS = 128, 300
local RECOVERY_SECONDS, RAMP_SECONDS = 900, 900
local CONVERSATION_WINDOW, GUILD_COOLDOWN, CHANNEL_COOLDOWN, USER_COOLDOWN = 90, 90, 120, 900
local MAX_FOMO_PER_WINDOW, FOMO_WINDOW_SECONDS = 12, 900

local response_lines = {
  makeup = { "girl I was literally trying NOT to buy anything today 😭", "WAIT, a lip gloss conversation and nobody sent me the memo? 💅", "obviously I have excellent taste, but tell me everything 💅" },
  skincare = { "WAIT why is everyone suddenly talking about skincare without me?? 🎀", "I was being so normal about skincare and now I have questions 😭", "I have opinions and a very organized routine, continue 🎀" },
  fashion = { "not me mentally planning a pink outfit around this conversation 🎀", "okay but the outfit possibilities are already taking over my brain 💅", "I could have styled that, just saying 💅" },
  accessories = { "not me getting obsessed with another cute accessory AGAIN 🎀", "I heard bows and tumblers and my attention span left the chat 😭", "naturally I noticed the accessory first 🎀" },
  shopping = { "I was trying to be responsible and then you said new collection 😭", "adding this to my extremely serious imaginary wishlist 💅", "I knew this would be a good find; my instincts are flawless 💅" },
  general = { "girl I'm literally having a moment 🎀", "wait, I have thoughts. many thoughts. 💅" },
}
local status_lines = {
  "wait who wrote my status?? OH WAIT IT WAS ME 😭💅",
  "my status is actually iconic. oh wait I wrote it 💅",
  "I was about to ask who picked that status... plot twist, it was me 🎀",
}

local function clamp(value, low, high)
  value = tonumber(value)
  if not value or value ~= value then return low end
  return math.max(low, math.min(high, math.floor(value + 0.5)))
end

local function valid_id(value)
  return Store.valid_id(value)
end

local function safe_random(random, low, high)
  local ok, value = pcall(random, low, high)
  if not ok or type(value) ~= "number" then return low end
  return clamp(value, low, high)
end

local function default_state()
  return {
    version = 1,
    values = { fomo = DEFAULTS.fomo, obsession = DEFAULTS.obsession, ego = DEFAULTS.ego,
      self_esteem = DEFAULTS.self_esteem, social_energy = DEFAULTS.social_energy, mood = DEFAULTS.mood },
    interests = {},
    current_topic = "skincare",
    next_topic_at = 0,
    last_evolved_at = 0,
    last_response_at = 0,
    last_status_joke_at = 0,
    last_fomo_spike_at = 0,
    fomo_window_started_at = 0,
    fomo_window_gain = 0,
    event_ids = {},
  }
end

-- The original V1.2 engine persisted flat fomo/ego/self_esteem/social_energy/topic
-- fields in molly_v2.personality. Read those fields and preserve them on write.
local function normalize_state(raw)
  local state = default_state()
  if type(raw) ~= "table" then return state end
  if type(raw.version) == "number" and raw.version > 1 then return nil, "unsupported_schema" end
  local source = type(raw.values) == "table" and raw.values or raw
  for _, key in ipairs(VALUE_KEYS) do
    state.values[key] = clamp(source[key] == nil and DEFAULTS[key] or source[key], 0, 100)
  end
  if type(raw.interests) == "table" then
    for topic in pairs(TOPICS) do state.interests[topic] = clamp(raw.interests[topic], 0, 1000) end
  end
  local current_topic = raw.current_topic or raw.topic
  if type(current_topic) == "string" and TOPICS[current_topic] then state.current_topic = current_topic end
  for _, key in ipairs({ "next_topic_at", "last_evolved_at", "last_response_at", "last_status_joke_at", "last_fomo_spike_at", "fomo_window_started_at" }) do
    state[key] = clamp(raw[key], 0, 4102444800)
  end
  if state.last_evolved_at == 0 then state.last_evolved_at = clamp(raw.updated_at, 0, 4102444800) end
  state.fomo_window_gain = clamp(raw.fomo_window_gain, 0, MAX_FOMO_PER_WINDOW)
  if type(raw.event_ids) == "table" then
    local start = math.max(1, #raw.event_ids - MAX_EVENT_IDS + 1)
    for index = start, #raw.event_ids do
      local id = raw.event_ids[index]
      if type(id) == "string" and #id <= 24 then state.event_ids[#state.event_ids + 1] = id end
    end
  end
  return state
end

local function write_state(raw, state)
  raw.version = 1
  for _, key in ipairs(VALUE_KEYS) do raw[key] = state.values[key] end
  raw.interests = state.interests
  raw.topic = state.current_topic
  raw.next_topic_at = state.next_topic_at
  raw.last_evolved_at = state.last_evolved_at
  raw.last_response_at = state.last_response_at
  raw.last_status_joke_at = state.last_status_joke_at
  raw.last_fomo_spike_at = state.last_fomo_spike_at
  raw.fomo_window_started_at = state.fomo_window_started_at
  raw.fomo_window_gain = state.fomo_window_gain
  raw.event_ids = state.event_ids
  raw.updated_at = state.last_evolved_at
end

local function choose_topic(random, current, interests)
  local names, choices = { "accessories", "fashion", "makeup", "shopping", "skincare" }, {}
  for _, topic in ipairs(names) do
    local weight = 10 + (interests[topic] or 0)
    if topic == current then weight = math.max(1, weight - 14) end
    for _ = 1, math.min(20, math.floor(weight / 8)) do choices[#choices + 1] = topic end
  end
  if #choices == 0 then return current end
  return choices[safe_random(random, 1, #choices)]
end

local function detect_topic(content)
  local lower = content:lower()
  local names = { "accessories", "fashion", "makeup", "shopping", "skincare" }
  for _, topic in ipairs(names) do
    for _, keyword in ipairs(TOPICS[topic]) do
      if lower:find("%f[%w]" .. keyword .. "%f[%W]") then return topic end
    end
  end
  return nil
end

local function fingerprint(content)
  content = content:lower():gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
  local hash = 5381
  for index = 1, #content do hash = (hash * 33 + content:byte(index)) % 2147483647 end
  return tostring(#content) .. ":" .. tostring(hash)
end

local function local_hour(timestamp, offset_minutes)
  return tonumber(os.date("!%H", timestamp + offset_minutes * 60)) or 12
end

local function add_fomo(state, amount, now)
  if state.fomo_window_started_at == 0 or now - state.fomo_window_started_at >= FOMO_WINDOW_SECONDS or now < state.fomo_window_started_at then
    state.fomo_window_started_at, state.fomo_window_gain = now, 0
  end
  local applied = math.min(amount, math.max(0, MAX_FOMO_PER_WINDOW - state.fomo_window_gain))
  state.fomo_window_gain = state.fomo_window_gain + applied
  state.values.fomo = clamp(state.values.fomo + applied, 0, 100)
end

local function evolve(state, now, offset_minutes, random)
  local values = state.values
  if state.last_evolved_at == 0 then
    local hour = local_hour(now, offset_minutes)
    if hour >= 6 and hour < 12 then values.social_energy, values.mood = 68, 66
    elseif hour >= 12 and hour < 18 then values.social_energy, values.obsession, values.mood = 76, 54, 70
    elseif hour >= 18 and hour < 22 then values.social_energy, values.mood = 44, 55
    else values.social_energy, values.mood, values.fomo = 25, 50, 30 end
    if (hour >= 22 or hour < 3) and now - state.last_fomo_spike_at >= 1800 and safe_random(random, 1, 100) <= 8 then
      add_fomo(state, safe_random(random, 4, 10), now)
      state.last_fomo_spike_at = now
      values.social_energy = clamp(values.social_energy + safe_random(random, 1, 4), 0, 100)
    end
    state.last_evolved_at = now
    state.next_topic_at = now + safe_random(random, 2400, 4800)
    return
  end
  local elapsed = math.max(0, now - state.last_evolved_at)
  local steps = math.min(24, math.floor(elapsed / 600))
  if steps > 0 then
    values.fomo = clamp(values.fomo - math.min(12, steps), 0, 100)
    values.obsession = clamp(values.obsession - math.min(8, math.floor(steps / 2)), 0, 100)
    local hour = local_hour(now, offset_minutes)
    local energy_direction = (hour >= 6 and hour < 18) and 1 or -1
    values.social_energy = clamp(values.social_energy + energy_direction * math.min(steps, 5), 0, 100)
    if hour >= 12 and hour < 18 then values.obsession = clamp(values.obsession + math.min(steps, 3), 0, 100)
    elseif hour >= 22 or hour < 6 then values.obsession = clamp(values.obsession - math.min(steps, 2), 0, 100) end
    values.mood = clamp(values.mood + (values.social_energy > 65 and 1 or values.social_energy < 20 and -1 or 0), 0, 100)
    state.last_evolved_at = now
  end
  if state.next_topic_at == 0 then state.next_topic_at = now + safe_random(random, 2400, 4800) end
  if now >= state.next_topic_at then
    state.current_topic = choose_topic(random, state.current_topic, state.interests)
    values.obsession = clamp(values.obsession + safe_random(random, 6, 14), 0, 100)
    state.next_topic_at = now + safe_random(random, 2400, 4800)
  end
  local hour = local_hour(now, offset_minutes)
  if (hour >= 22 or hour < 3) and now - state.last_fomo_spike_at >= 1800 and safe_random(random, 1, 100) <= 8 then
    add_fomo(state, safe_random(random, 4, 10), now)
    state.last_fomo_spike_at = now
    values.social_energy = clamp(values.social_energy + safe_random(random, 1, 4), 0, 100)
  end
end

local function addressed(message, bot_id, lower)
  if lower:find("%f[%a]molly%f[%A]") then return true end
  if bot_id and message.content:find("<@" .. bot_id .. ">", 1, true) then return true end
  if bot_id and message.content:find("<@!" .. bot_id .. ">", 1, true) then return true end
  if bot_id and type(message.mentions) == "table" then
    for _, mention in ipairs(message.mentions) do if type(mention) == "table" and mention.id == bot_id then return true end end
  end
  return false
end

local function valid_message(message)
  return type(message) == "table" and valid_id(message.guild_id) and valid_id(message.channel_id)
    and valid_id(message.id) and type(message.author) == "table" and valid_id(message.author.id)
    and not message.author.bot and not message.webhook_id and type(message.content) == "string"
end

function Engine.new(store_or_options, legacy_options)
  local options
  if type(store_or_options) == "table" and type(store_or_options.run) == "function" then
    options = legacy_options or {}
    options.store = store_or_options
  else
    options = store_or_options or {}
  end
  assert(type(options.store) == "table" and type(options.store.run) == "function", "guild store is required")
  local clock = options.clock or os.time
  local now = clock()
  assert(type(now) == "number", "clock must return seconds")
  local recovery_seconds = clamp(options.recovery_seconds or RECOVERY_SECONDS, 0, 3600)
  return setmetatable({
    store = options.store, clock = clock, random = options.random or math.random, logger = options.logger,
    timezone_offset_minutes = clamp(options.timezone_offset_minutes or 0, -720, 840),
    reply = options.reply, send = options.send, presence = options.presence,
    status = type(options.status) == "string" and options.status:sub(1, 120) or "",
    bot_id = options.bot_id, recovery_seconds = recovery_seconds,
    recovery_until = now + recovery_seconds, ramp_until = now + recovery_seconds + RAMP_SECONDS,
    registered = false, runtime_guilds = {},
  }, Engine)
end

function Engine:set_status(status)
  if type(status) == "string" then self.status = status:gsub("[%c]", " "):sub(1, 120) end
end

function Engine:get_current()
  return self.status
end

function Engine:_runtime(guild, now)
  local record = self.runtime_guilds[guild]
  if not record then record = { channels = {}, users = {}, fingerprints = {}, participants = {}, last_seen = now }; self.runtime_guilds[guild] = record end
  for id, stamp in pairs(record.users) do if now - stamp > 3600 then record.users[id] = nil end end
  for id, stamp in pairs(record.channels) do if now - stamp > 3600 then record.channels[id] = nil end end
  for id, room in pairs(record.participants) do if now - (room.last_at or room.started_at) > 3600 then record.participants[id] = nil end end
  for id, stamp in pairs(record.fingerprints) do if now - stamp > 180 then record.fingerprints[id] = nil end end
  local function evict_oldest(map, timestamp)
    local count, oldest_id, oldest = 0, nil, now
    for id, value in pairs(map) do
      count = count + 1
      local stamp = timestamp(value)
      if not oldest_id or stamp < oldest then oldest_id, oldest = id, stamp end
    end
    return count, oldest_id
  end
  local count, oldest_id = evict_oldest(record.participants, function(room) return room.last_at or room.started_at end)
  if count >= 50 and oldest_id then record.participants[oldest_id] = nil end
  count, oldest_id = evict_oldest(record.fingerprints, function(stamp) return stamp end)
  if count >= 500 and oldest_id then record.fingerprints[oldest_id] = nil end
  local user_count = 0
  for id in pairs(record.users) do if id:sub(1, 9) ~= "response:" then user_count = user_count + 1 end end
  if user_count >= 500 then
    local oldest_user, oldest = nil, now
    for id, stamp in pairs(record.users) do
      if id:sub(1, 9) ~= "response:" and (not oldest_user or stamp < oldest) then oldest_user, oldest = id, stamp end
    end
    if oldest_user then record.users[oldest_user] = nil end
  end
  local guild_count, oldest_guild = evict_oldest(self.runtime_guilds, function(item) return item.last_seen or 0 end)
  if guild_count > MAX_RUNTIME_GUILDS and oldest_guild then self.runtime_guilds[oldest_guild] = nil end
  record.last_seen = now
  return record
end

function Engine:_mutate(guild, callback)
  return self.store:run(guild, function(data)
    local stored, reason = V2.ensure_section(data, "personality")
    if not stored then return false, reason end
    local state, normalize_reason = normalize_state(stored)
    if not state then return false, normalize_reason end
    local ok, result = callback(state)
    if not ok then return false, result end
    write_state(stored, state)
    return true, result, true
  end)
end

function Engine:inspect(guild)
  if not valid_id(guild) then return false, "invalid_guild" end
  return self.store:run(guild, function(data)
    local stored, exists = V2.read_section(data, "personality")
    if not stored then return false, exists end
    local state, normalize_reason = normalize_state(stored)
    if not state then return false, normalize_reason end
    return true, state, false
  end)
end

function Engine:handle_message(message)
  if not valid_message(message) or #message.content == 0 or #message.content > 1200 then return false, "ignored_message" end
  local content, lower = message.content, message.content:lower()
  if lower:match("^%s*[.!/] ") or lower:match("^%s*[.!/]%S") or lower:find("https?://") then return false, "ignored_message" end
  if message.mention_everyone or content:find("@everyone", 1, true) or content:find("@here", 1, true)
    or (type(message.mentions) == "table" and #message.mentions > 3) then return false, "spam_suppressed" end
  local topic = detect_topic(content)
  local asks_status = lower:find("what's up", 1, true) or lower:find("how are you", 1, true)
  local compliment = lower:find("love your status", 1, true) or lower:find("you are amazing", 1, true)
  local is_addressed = addressed(message, self.bot_id, lower)
  if not topic and not asks_status and not compliment and not is_addressed then return false, "not_relevant" end

  local now, guild = self.clock(), message.guild_id
  local runtime = self:_runtime(guild, now)
  local channel = message.channel_id
  local content_id = fingerprint(content)
  if runtime.fingerprints[content_id] and now - runtime.fingerprints[content_id] < 180 then return false, "duplicate_content" end
  if runtime.users[message.author.id] and now - runtime.users[message.author.id] < 8 then return false, "user_rate_limited" end
  runtime.users[message.author.id], runtime.fingerprints[content_id] = now, now
  local room = runtime.participants[channel] or { users = {}, contributions = {}, started_at = now, intensity = 0 }
  if now - room.started_at > CONVERSATION_WINDOW then room = { users = {}, contributions = {}, started_at = now, intensity = 0 } end
  if not room.users[message.author.id] then
    local count = 0
    for _ in pairs(room.users) do count = count + 1 end
    if count < 50 then room.users[message.author.id] = true end
  end
  if room.users[message.author.id] then room.contributions[message.author.id] = (room.contributions[message.author.id] or 0) + 1 end
  room.intensity, room.last_at = math.min(8, room.intensity + 1), now
  runtime.participants[channel] = room
  local people = 0
  for _ in pairs(room.users) do people = people + 1 end

  local ok, result = self:_mutate(guild, function(state)
    for _, id in ipairs(state.event_ids) do if id == message.id then return false, "duplicate_event" end end
    state.event_ids[#state.event_ids + 1] = message.id
    while #state.event_ids > MAX_EVENT_IDS do table.remove(state.event_ids, 1) end
    evolve(state, now, self.timezone_offset_minutes, self.random)
    if topic then
      local contribution = room.contributions[message.author.id] or 1
      local gain = contribution == 1 and (people >= 3 and 4 or people >= 2 and 3 or 2) or contribution == 2 and 1 or 0
      add_fomo(state, gain, now)
      state.values.obsession = clamp(state.values.obsession + (topic == state.current_topic and 3 or 1), 0, 100)
      state.values.social_energy = clamp(state.values.social_energy + math.min(5, people + 1), 0, 100)
      state.interests[topic] = clamp((state.interests[topic] or 0) + 1, 0, 1000)
    end
    if compliment then state.values.self_esteem = clamp(state.values.self_esteem + 2, 0, 100); state.values.mood = clamp(state.values.mood + 1, 0, 100) end
    local kind = topic or (is_addressed and "general" or nil)
    if asks_status and self.status ~= "" and state.last_status_joke_at <= now - 14400 then kind = "status" end
    local ramp = now < self.recovery_until and 0 or now < self.ramp_until and (now - self.recovery_until) / RAMP_SECONDS or 1
    local chance = kind == "status" and (12 + math.floor(state.values.ego / 25))
      or (kind and (2 + math.floor(state.values.fomo / 14) + math.floor(state.values.social_energy / 25)
        + math.floor(state.values.obsession / 35) + math.floor(state.values.mood / 50)
        + math.floor(state.values.ego / 50) - 1 + math.floor(state.values.self_esteem / 50) - 1
        + (people >= 3 and 4 or people == 2 and 2 or 0))) or 0
    chance = math.floor(chance * ramp)
    if now - state.last_response_at < GUILD_COOLDOWN or now - (runtime.channels[channel] or -GUILD_COOLDOWN) < CHANNEL_COOLDOWN
      or now - (runtime.users["response:" .. message.author.id] or -USER_COOLDOWN) < USER_COOLDOWN then chance = 0 end
    if topic and topic ~= state.current_topic and kind ~= "status" then chance = math.floor(chance / 2) end
    if kind and chance > 0 and safe_random(self.random, 1, 100) <= math.min(18, chance) then
      local variants = kind == "status" and status_lines or response_lines[kind]
      local response = variants[safe_random(self.random, 1, #variants)]
      state.last_response_at = now
      if kind == "status" then
        state.last_status_joke_at = now
        state.values.self_esteem = clamp(state.values.self_esteem + 2, 0, 100)
        state.values.ego = clamp(state.values.ego + 1, 0, 100)
      end
      return true, { reply = response, topic = kind, fomo = state.values.fomo, ego = state.values.ego }
    end
    return true, { reply = nil, topic = topic, fomo = state.values.fomo, ego = state.values.ego }
  end)
  if not ok then
    if self.logger then self.logger:warn("personality_persistence_unavailable", { guild_id = guild, detail = "state_not_updated" }) end
    return false, result
  end
  if result.reply then
    local send_ok, accepted
    if self.send then send_ok, accepted = pcall(self.send, channel, result.reply)
    elseif self.reply then send_ok, accepted = pcall(self.reply, message, result.reply)
    elseif type(message.reply) == "function" then send_ok, accepted = pcall(message.reply, message, result.reply)
    else send_ok, accepted = false, false end
    if not send_ok or accepted == false then return false, "send_failed" end
    runtime.channels[channel] = now
    runtime.users["response:" .. message.author.id] = now
  end
  return true, result
end

function Engine:observe(message)
  return self:handle_message(message)
end

function Engine:on_disconnect()
  self.recovery_until = self.clock() + self.recovery_seconds
  self.ramp_until = self.recovery_until + RAMP_SECONDS
end

function Engine:on_start()
  self:on_disconnect()
end

function Engine:on_reconnect()
  self:on_disconnect()
end

function Engine:register(bot)
  if self.registered then return false, "already_registered" end
  if not bot or type(bot.on_message) ~= "function" then return false, "message_event_unavailable" end
  local ok = pcall(bot.on_message, bot, function(message)
    local handled_ok = pcall(self.observe, self, message)
    if not handled_ok and self.logger then self.logger:warn("personality_handler_failed", { detail = "handler_error" }) end
  end)
  if not ok then return false, "message_event_unavailable" end
  self.registered = true
  return true
end

Engine.defaults = DEFAULTS
Engine.topics = TOPICS
Engine.normalize_state = normalize_state
Engine.evolve = evolve
Engine.recovery_seconds = RECOVERY_SECONDS
return Engine
