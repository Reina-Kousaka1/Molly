local Store = require("src.persistence.guild_store")

local Engine = {}
Engine.__index = Engine

local VALUE_KEYS = { "fomo", "obsession", "ego", "self_esteem", "social_energy", "mood" }
local DEFAULTS = { fomo = 24, obsession = 32, ego = 38, self_esteem = 58, social_energy = 42, mood = 58 }
local MAX_EVENT_IDS, MAX_RUNTIME_GUILDS = 128, 300
local RECOVERY_SECONDS, RAMP_SECONDS = 15 * 60, 15 * 60
local CONVERSATION_WINDOW, GUILD_COOLDOWN, CHANNEL_COOLDOWN, USER_COOLDOWN = 90, 90, 120, 900

local topics = {
  makeup = { "makeup", "lip oil", "lip gloss", "lipgloss", "blush", "mascara", "highlighter" },
  skincare = { "skincare", "skin care", "glow mask", "serum", "moisturizer", "sunscreen", "face mask" },
  fashion = { "preppy", "outfit", "fashion", "pink outfit", "cardigan", "collection", "clothes" },
  accessories = { "hair bow", "bow", "hair clip", "hairclip", "hairband", "tumbler", "stanley cup" },
  shopping = { "shopping", "new drop", "new collection", "haul", "buy it", "need it", "wishlist" },
}

local response_lines = {
  makeup = { "girl I was literally trying NOT to buy anything today 😭", "WAIT, a lip gloss conversation and nobody sent me the memo? 💅", "obviously I have excellent taste, but tell me everything 💅" },
  skincare = { "WAIT why is everyone suddenly talking about skincare without me?? 🎀", "I was being so normal about skincare and now I have questions 😭", "I have opinions and a very organized routine, continue 🎀" },
  fashion = { "not me mentally planning a pink outfit around this conversation 🎀", "okay but the outfit possibilities are already taking over my brain 💅", "I could have styled that, just saying 💅" },
  accessories = { "not me getting obsessed with another cute accessory AGAIN 🎀", "I heard bows and tumblers and my attention span left the chat 😭", "naturally I noticed the accessory first 🎀" },
  shopping = { "I was trying to be responsible and then you said new collection 😭", "adding this to my extremely serious imaginary wishlist 💅", "I knew this would be a good find; my instincts are flawless 💅" },
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

local function normalize_state(raw)
  local state = default_state()
  if type(raw) ~= "table" then return state end
  state.version = 1
  if type(raw.values) == "table" then
    for _, key in ipairs(VALUE_KEYS) do state.values[key] = clamp(raw.values[key] == nil and DEFAULTS[key] or raw.values[key], 0, 100) end
  end
  if type(raw.interests) == "table" then
    for topic in pairs(topics) do state.interests[topic] = clamp(raw.interests[topic], 0, 1000) end
  end
  if type(raw.current_topic) == "string" and topics[raw.current_topic] then state.current_topic = raw.current_topic end
  for _, key in ipairs({ "next_topic_at", "last_evolved_at", "last_response_at", "last_status_joke_at", "last_fomo_spike_at", "fomo_window_started_at" }) do
    state[key] = clamp(raw[key], 0, 4102444800)
  end
  state.fomo_window_gain = clamp(raw.fomo_window_gain, 0, 12)
  if type(raw.event_ids) == "table" then
    local start = math.max(1, #raw.event_ids - MAX_EVENT_IDS + 1)
    for index = start, #raw.event_ids do
      local id = raw.event_ids[index]
      if type(id) == "string" and #id <= 24 then state.event_ids[#state.event_ids + 1] = id end
    end
  end
  return state
end

local function choose_topic(random, current, interests)
  local choices = {}
  for topic in pairs(topics) do
    local weight = 10 + (interests[topic] or 0)
    if topic == current then weight = math.max(1, weight - 14) end
    for _ = 1, math.min(20, math.floor(weight / 8)) do choices[#choices + 1] = topic end
  end
  if #choices == 0 then return current end
  return choices[safe_random(random, 1, #choices)]
end

local function detect_topic(content)
  local lower = content:lower()
  for topic, keywords in pairs(topics) do
    for _, keyword in ipairs(keywords) do
      local pattern = "%f[%w]" .. keyword .. "%f[%W]"
      if lower:find(pattern) then return topic end
    end
  end
  return nil
end

local function message_fingerprint(content)
  -- Ephemeral bounded duplicate detector; the source text is never retained.
  content = content:lower():gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
  local hash = 5381
  for index = 1, #content do hash = (hash * 33 + content:byte(index)) % 2147483647 end
  return tostring(#content) .. ":" .. tostring(hash)
end

local function contains_spam_marker(message, content)
  if message.mention_everyone then return true end
  local mentions = type(message.mentions) == "table" and #message.mentions or 0
  if mentions > 3 then return true end
  return content:find("@everyone", 1, true) ~= nil or content:find("@here", 1, true) ~= nil
end

local function local_hour(timestamp, offset_minutes)
  return tonumber(os.date("!%H", timestamp + offset_minutes * 60)) or 12
end

local function add_fomo(state, amount, now)
  if state.fomo_window_started_at == 0 or now - state.fomo_window_started_at >= 900 or now < state.fomo_window_started_at then
    state.fomo_window_started_at, state.fomo_window_gain = now, 0
  end
  local applied = math.min(amount, math.max(0, 12 - state.fomo_window_gain))
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
  local elapsed = now - state.last_evolved_at
  if elapsed < 0 then elapsed = 0 end
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

function Engine.new(options)
  assert(type(options) == "table" and type(options.store) == "table" and type(options.store.run) == "function", "guild store is required")
  local clock = options.clock or os.time
  local now = clock()
  assert(type(now) == "number", "clock must return seconds")
  return setmetatable({
    store = options.store,
    clock = clock,
    random = options.random or math.random,
    logger = options.logger,
    timezone_offset_minutes = clamp(options.timezone_offset_minutes or 0, -720, 840),
    reply = options.reply,
    presence = options.presence,
    recovery_until = now + RECOVERY_SECONDS,
    ramp_until = now + RECOVERY_SECONDS + RAMP_SECONDS,
    registered = false,
    runtime_guilds = {},
  }, Engine)
end

function Engine:_runtime(guild, now)
  local record = self.runtime_guilds[guild]
  if not record then
    record = { channels = {}, users = {}, fingerprints = {}, participants = {}, last_seen = now }
    self.runtime_guilds[guild] = record
  end
  record.last_seen = now
  for id, stamp in pairs(record.users) do if now - stamp > 3600 then record.users[id] = nil end end
  for id, stamp in pairs(record.channels) do if now - stamp > 3600 then record.channels[id] = nil end end
  for id, room in pairs(record.participants) do if now - (room.last_at or room.started_at) > 3600 then record.participants[id] = nil end end
  for id, stamp in pairs(record.fingerprints) do if now - stamp > 180 then record.fingerprints[id] = nil end end
  local channel_count = 0
  for _ in pairs(record.participants) do channel_count = channel_count + 1 end
  if channel_count >= 50 then
    local oldest_id, oldest = nil, now
    for id, room in pairs(record.participants) do if (room.last_at or room.started_at) < oldest then oldest_id, oldest = id, room.last_at or room.started_at end end
    if oldest_id then record.participants[oldest_id] = nil end
  end
  local fingerprint_count, oldest_fingerprint, oldest_fingerprint_at = 0, nil, now
  for id, stamp in pairs(record.fingerprints) do
    fingerprint_count = fingerprint_count + 1
    if stamp < oldest_fingerprint_at then oldest_fingerprint, oldest_fingerprint_at = id, stamp end
  end
  if fingerprint_count >= 500 and oldest_fingerprint then record.fingerprints[oldest_fingerprint] = nil end
  local user_count = 0
  for id in pairs(record.users) do if id:sub(1, 9) ~= "response:" then user_count = user_count + 1 end end
  if user_count >= 500 then
    local oldest_id, oldest = nil, now
    for id, stamp in pairs(record.users) do if id:sub(1, 9) ~= "response:" and stamp < oldest then oldest_id, oldest = id, stamp end end
    if oldest_id then record.users[oldest_id] = nil end
  end
  local count = 0
  for id in pairs(self.runtime_guilds) do count = count + 1; if count > MAX_RUNTIME_GUILDS then self.runtime_guilds[id] = nil end end
  return record
end

function Engine:_mutate(guild, fn)
  return self.store:run(guild, function(data)
    local state = normalize_state(data.personality)
    local ok, result = fn(state)
    if not ok then return false, result end
    data.personality = state
    return true, result, true
  end)
end

function Engine:inspect(guild)
  if not valid_id(guild) then return false, "invalid_guild" end
  return self.store:run(guild, function(data)
    local state = normalize_state(data.personality)
    return true, state, false
  end)
end

function Engine:handle_message(message)
  if type(message) ~= "table" or type(message.author) ~= "table" or message.author.bot or message.webhook_id then return false, "ignored_message" end
  local guild = message.guild_id
  if not valid_id(guild) or not valid_id(message.author.id) or not valid_id(message.id) then return false, "invalid_message" end
  if type(message.content) ~= "string" or #message.content == 0 or #message.content > 2000 then return false, "ignored_message" end
  local content = message.content
  if contains_spam_marker(message, content) then return false, "spam_suppressed" end
  local topic = detect_topic(content)
  local asks_status = content:lower():find("what's up", 1, true) or content:lower():find("how are you", 1, true)
  local compliment = content:lower():find("love your status", 1, true) or content:lower():find("you are amazing", 1, true)
  if not topic and not asks_status and not compliment then return false, "not_relevant" end

  local now = self.clock()
  local runtime = self:_runtime(guild, now)
  local channel_id = valid_id(message.channel_id) and message.channel_id or "unknown"
  local fingerprint = message_fingerprint(content)
  if runtime.fingerprints[fingerprint] and now - runtime.fingerprints[fingerprint] < 180 then return false, "duplicate_content" end
  if runtime.users[message.author.id] and now - runtime.users[message.author.id] < 8 then return false, "user_rate_limited" end
  runtime.users[message.author.id] = now
  runtime.fingerprints[fingerprint] = now
  for key, stamp in pairs(runtime.fingerprints) do if now - stamp > 180 then runtime.fingerprints[key] = nil end end
  local room = runtime.participants[channel_id] or { users = {}, contributions = {}, started_at = now, intensity = 0 }
  if now - room.started_at > CONVERSATION_WINDOW then room = { users = {}, contributions = {}, started_at = now, intensity = 0 } end
  if not room.users[message.author.id] then
    local participants = 0
    for _ in pairs(room.users) do participants = participants + 1 end
    if participants < 50 then room.users[message.author.id] = true end
  end
  if room.users[message.author.id] then room.contributions[message.author.id] = (room.contributions[message.author.id] or 0) + 1 end
  room.intensity = math.min(8, room.intensity + 1)
  room.last_at = now
  runtime.participants[channel_id] = room
  local people = 0
  for _ in pairs(room.users) do people = people + 1 end

  local ok, result = self:_mutate(guild, function(state)
    for _, id in ipairs(state.event_ids) do if id == message.id then return false, "duplicate_event" end end
    state.event_ids[#state.event_ids + 1] = message.id
    while #state.event_ids > MAX_EVENT_IDS do table.remove(state.event_ids, 1) end
    evolve(state, now, self.timezone_offset_minutes, self.random)
    if topic then
      local contribution = room.contributions[message.author.id] or 1
      local fomo_gain = contribution == 1 and (people >= 3 and 4 or people >= 2 and 3 or 2) or contribution == 2 and 1 or 0
      add_fomo(state, fomo_gain, now)
      state.values.obsession = clamp(state.values.obsession + (topic == state.current_topic and 3 or 1), 0, 100)
      state.values.social_energy = clamp(state.values.social_energy + math.min(5, people + 1), 0, 100)
      state.interests[topic] = clamp((state.interests[topic] or 0) + 1, 0, 1000)
    end
    if compliment then
      state.values.self_esteem = clamp(state.values.self_esteem + 2, 0, 100)
      state.values.mood = clamp(state.values.mood + 1, 0, 100)
    end
    local response_kind = topic
    if asks_status and state.last_status_joke_at <= now - 14400 and self.presence and self.presence:get_current() then
      response_kind = "status"
    end
    local recovery_factor = now < self.recovery_until and 0 or now < self.ramp_until and (now - self.recovery_until) / RAMP_SECONDS or 1
    local chance = response_kind == "status" and (12 + math.floor(state.values.ego / 25))
      or (response_kind and (2 + math.floor(state.values.fomo / 14) + math.floor(state.values.social_energy / 25)
        + math.floor(state.values.obsession / 35) + math.floor(state.values.mood / 50)
        + math.floor(state.values.ego / 50) - 1 + math.floor(state.values.self_esteem / 50) - 1
        + (people >= 3 and 4 or people == 2 and 2 or 0))) or 0
    chance = math.floor(chance * recovery_factor)
    if now - state.last_response_at < GUILD_COOLDOWN or now - (runtime.channels[channel_id] or -GUILD_COOLDOWN) < CHANNEL_COOLDOWN
      or now - (runtime.users["response:" .. message.author.id] or -USER_COOLDOWN) < USER_COOLDOWN then chance = 0 end
    if topic ~= state.current_topic and response_kind ~= "status" then chance = math.floor(chance / 2) end
    if chance > 0 and safe_random(self.random, 1, 100) <= math.min(18, chance) then
      local lines = response_kind == "status" and status_lines or response_lines[response_kind]
      local line = lines[safe_random(self.random, 1, #lines)]
      state.last_response_at = now
      if response_kind == "status" then
        state.last_status_joke_at = now
        state.values.self_esteem = clamp(state.values.self_esteem + 2, 0, 100)
        state.values.ego = clamp(state.values.ego + 1, 0, 100)
      end
      result = { response = line, channel_id = channel_id, topic = response_kind }
    else
      result = { topic = topic, people = people }
    end
    return true, result
  end)
  if not ok then
    if self.logger then self.logger:warn("personality_persistence_unavailable", { guild_id = guild, detail = "state_not_updated" }) end
    return false, "persistence_unavailable"
  end
  if result and result.response then
    local sent = false
    local send = self.reply
    if not send and type(message.reply) == "function" then send = function(target, text) return target:reply(text) end end
    if send then
      local call_ok, accepted = pcall(send, message, result.response)
      sent = call_ok and accepted ~= false
    end
    if sent then
      runtime.channels[channel_id] = now
      runtime.users["response:" .. message.author.id] = now
      return true, "responded"
    end
    if self.logger then self.logger:warn("personality_reply_failed", { guild_id = guild, detail = "discord_rest_error" }) end
    return false, "reply_failed"
  end
  return true, "state_updated"
end

function Engine:on_disconnect()
  self.recovery_until = self.clock() + RECOVERY_SECONDS
  self.ramp_until = self.recovery_until + RAMP_SECONDS
end

function Engine:on_reconnect()
  self:on_disconnect()
end

function Engine:register(bot)
  if self.registered then return false, "already_registered" end
  if not bot or type(bot.on_message) ~= "function" then return false, "message_event_unavailable" end
  local ok = pcall(bot.on_message, bot, function(message) self:handle_message(message) end)
  if not ok then return false, "message_event_unavailable" end
  self.registered = true
  return true
end

Engine.defaults = DEFAULTS
Engine.topics = topics
Engine.normalize_state = normalize_state
Engine.evolve = evolve
Engine.recovery_seconds = RECOVERY_SECONDS
return Engine
