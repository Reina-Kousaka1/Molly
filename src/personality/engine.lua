local Store = require("src.persistence.guild_store")
local V2 = require("src.persistence.guild_v2")
local Personality = {}
Personality.__index = Personality

local topics = {
  makeup = {"makeup", "lip oil", "lip gloss", "mascara", "blush"},
  skincare = {"skincare", "serum", "moisturizer", "glow mask"},
  fashion = {"outfit", "leggings", "hoodie", "bow", "fashion"},
  tumbler = {"tumbler", "stanley", "cup"},
}
local replies = {
  makeup = "waittt why are we talking about lip gloss without me 😭🎀",
  skincare = "girl my skincare routine is literally my personality rn 💗",
  fashion = "okay but the outfit HAS to be pink 🎀",
  tumbler = "not me thinking about another pink tumbler AGAIN 😭",
}
local function clamp(n) return math.max(0, math.min(100, n)) end
local function topic_of(s)
  s = s:lower()
  for _, name in ipairs({"makeup", "skincare", "fashion", "tumbler"}) do
    for _, term in ipairs(topics[name]) do
      if s:find(term, 1, true) then return name end
    end
  end
end
local function valid_message(m)
  return type(m) == "table" and Store.valid_id(m.guild_id)
    and Store.valid_id(m.channel_id) and Store.valid_id(m.id)
    and type(m.author) == "table" and Store.valid_id(m.author.id)
    and not m.author.bot and not m.webhook_id and type(m.content) == "string"
end
function Personality.new(store, options)
  options = options or {}
  return setmetatable({store=store, clock=options.clock or os.time,
    started=(options.clock or os.time)(), status="", cooldowns={}, last_seen={},
    recovery_seconds=options.recovery_seconds or 900, send=options.send,
    bot_id=options.bot_id}, Personality)
end
function Personality:set_status(status)
  if type(status) == "string" then self.status = status:sub(1, 120) end
end
function Personality:observe(m)
  if not valid_message(m) or #m.content > 1200 then return false, "ignored" end
  local now = self.clock()
  local key = m.guild_id .. ":" .. m.channel_id
  local lower = m.content:lower()
  if lower:match("^%s*[.!/]") or lower:find("https?://") then return false, "ignored" end
  local seen = self.last_seen[key]
  if seen and seen.author == m.author.id and seen.text == lower and now-seen.at < 120 then return false, "duplicate" end
  self.last_seen[key] = {author=m.author.id,text=lower:sub(1,250),at=now}
  local topic = topic_of(lower)
  local mentioned = self.bot_id and lower:find(self.bot_id, 1, true) ~= nil
  local name_mentioned = lower:find("molly", 1, true) ~= nil
  if not topic and not mentioned and not name_mentioned then return false, "unrelated" end
  local ok, result = self.store:run(m.guild_id, function(data)
    local state, err = V2.ensure_section(data, "personality")
    if not state then return false, err end
    local last = tonumber(state.updated_at) or now
    local elapsed = math.max(0, math.min(86400, now-last))
    state.fomo = clamp((tonumber(state.fomo) or 55) - math.floor(elapsed/1800))
    state.ego = clamp(tonumber(state.ego) or 50)
    state.self_esteem = clamp(tonumber(state.self_esteem) or 60)
    state.social_energy = clamp(tonumber(state.social_energy) or 60)
    state.topic = topic or state.topic
    if topic then state.fomo = clamp(state.fomo + (lower:find("love",1,true) and 3 or 2)) end
    state.updated_at = now
    local response
    local ready = now-self.started >= self.recovery_seconds
    local cooldown = now-(self.cooldowns[key] or 0) >= 600
    local interaction = mentioned or name_mentioned
    if ready and cooldown and interaction then
      if self.status ~= "" and (lower:find("status",1,true) or lower:find("what's up",1,true)) then
        response = 'wait who wrote "' .. self.status:gsub("[\r\n@]", " "):sub(1,80) .. '"?? OH WAIT IT WAS ME 😭💅'
        state.ego = clamp(state.ego + 1)
        state.self_esteem = clamp(state.self_esteem + 2)
      elseif topic then response = replies[topic]
      else response = "girl I'm literally having a moment 🎀" end
    elseif ready and cooldown and topic and state.fomo >= 85 and state.social_energy >= 60 then
      -- Low-volume, deterministic spontaneous reaction; never triggered by Molly's own messages.
      if tonumber(m.id:sub(-2)) and tonumber(m.id:sub(-2)) % 17 == 0 then response = replies[topic] end
    end
    return true, {reply=response, fomo=state.fomo, ego=state.ego}, true
  end)
  if not ok then return false, result end
  if result.reply and self.send then
    -- Reserve the cooldown before sending to avoid reply storms during gateway retries.
    self.cooldowns[key] = now
    local sent, accepted = pcall(self.send, m.channel_id, result.reply)
    if not sent or accepted == false then return false, "send_failed" end
  end
  return true, result
end
return Personality
