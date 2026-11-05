local Store = require("src.persistence.guild_store")
local V2 = require("src.persistence.guild_v2")

local Starboard = {}
Starboard.__index = Starboard

local MAX_CACHE = 500
local MAX_USERS_PER_MESSAGE = 256
local MAX_POSTS = 5000
local CACHE_TTL = 120

local function safe(value, maximum)
  return tostring(value or ""):gsub("@", "@\226\128\139"):gsub("[\r\n]", " ")
    :gsub("[%z\1-\8\11\12\14-\31\127]", " "):sub(1, maximum or 1500)
end

local function emoji_matches(configured, emoji)
  if type(emoji) ~= "table" then return configured == emoji end
  local id = type(emoji.id) == "string" and emoji.id or nil
  local name = type(emoji.name) == "string" and emoji.name or nil
  local custom_id = configured:match("^<a?:[^:]+:(%d+)>$")
  local custom_name = configured:match("^<a?:([^:]+):%d+>$")
  if custom_id then return id == custom_id end
  if custom_name then return name == custom_name end
  if id then return configured == id end
  return configured == name
end

local function reaction_count(message, configured)
  for _, reaction in ipairs(message.reactions or {}) do
    if type(reaction) == "table" and emoji_matches(configured, reaction.emoji) then
      return type(reaction.count) == "number" and math.max(0, math.floor(reaction.count)) or 0
    end
  end
  return 0
end

local function ignored(config, channel_id)
  for _, value in ipairs(config.ignored_channels or {}) do if value == channel_id then return true end end
  return false
end

local function rest_succeeded(called, result)
  return called == true and result ~= nil and result ~= false
end

function Starboard.new(store, settings, options)
  options = options or {}
  assert(type(store) == "table" and type(store.run) == "function", "guild store is required")
  assert(type(settings) == "table" and type(settings.get_domain) == "function", "guild settings are required")
  return setmetatable({ store = store, settings = settings, rest = options.rest, bot_id = options.bot_id,
    content_policy = options.content_policy, clock = options.clock or os.time, cache = {}, logger = options.logger }, Starboard)
end

function Starboard:set_runtime(rest, bot_id)
  self.rest, self.bot_id = rest, bot_id
end

function Starboard:set_content_policy(policy)
  self.content_policy = policy
end

function Starboard:_cache_state(key, state)
  state.updated = self.clock()
  self.cache[key] = state
  local count = 0
  for _, item in pairs(self.cache) do
    count = count + 1
    if count > MAX_CACHE then
      local oldest_key, oldest_at
      for candidate, value in pairs(self.cache) do
        if not oldest_at or value.updated < oldest_at then oldest_key, oldest_at = candidate, value.updated end
      end
      if oldest_key then self.cache[oldest_key] = nil end
      break
    end
  end
end

function Starboard:_post(guild, origin_id)
  local ok, post = self.store:run(guild, function(data)
    local section, reason = V2.read_section(data, "starboard")
    if not section then return false, reason end
    local posts = section.posts or {}
    if type(posts) ~= "table" then return false, "invalid_store" end
    local value = posts[origin_id]
    if value ~= nil and (type(value) ~= "table" or type(value.state) ~= "string") then return false, "invalid_store" end
    return true, value and { state = value.state, channel_id = value.channel_id, message_id = value.message_id,
      timestamp = value.timestamp }, false
  end)
  return ok, post
end

function Starboard:_save_post(guild, origin_id, value)
  return self.store:run(guild, function(data)
    local section, reason = V2.ensure_section(data, "starboard")
    if not section then return false, reason end
    section.posts = section.posts or {}
    if type(section.posts) ~= "table" then return false, "invalid_store" end
    if value == nil then
      if section.posts[origin_id] == nil then return true, false, false end
      section.posts[origin_id] = nil
      return true, true, true
    end
    if section.posts[origin_id] == nil then
      local count = 0
      for _ in pairs(section.posts) do count = count + 1 end
      if count >= MAX_POSTS then return false, "capacity" end
    end
    section.posts[origin_id] = { state = value.state, channel_id = value.channel_id,
      message_id = value.message_id, timestamp = self.clock() }
    return true, true, true
  end)
end

function Starboard:_delete(guild, origin_id, post)
  if not post then return true end
  if post.state == "sent" and post.channel_id and post.message_id then
    if not self.rest or type(self.rest.delete_message) ~= "function" then return false, "discord_unavailable" end
    local called, result = pcall(self.rest.delete_message, self.rest, post.channel_id, post.message_id,
      "Starboard reaction count fell below threshold")
    if not rest_succeeded(called, result) then return false, "delete_failed" end
  end
  return self:_save_post(guild, origin_id, nil)
end

function Starboard:_nsfw_allowed(guild, source_id, target_id)
  if not self.rest or type(self.rest.get_channel) ~= "function" then return false end
  local source_ok, source = pcall(self.rest.get_channel, self.rest, source_id)
  local target_ok, target = pcall(self.rest.get_channel, self.rest, target_id)
  if not source_ok or type(source) ~= "table" or not target_ok or type(target) ~= "table"
    or source.guild_id ~= guild or target.guild_id ~= guild
    or type(source.nsfw) ~= "boolean" or type(target.nsfw) ~= "boolean" then return false end
  if source.nsfw then
    if not target.nsfw or not self.content_policy then return false end
    local checked, allowed = pcall(self.content_policy.allows, self.content_policy, guild, target_id)
    if not checked or not allowed then return false end
  end
  return true
end

function Starboard:_content(guild, source_channel, message, count)
  local url = "https://discord.com/channels/" .. guild .. "/" .. source_channel .. "/" .. message.id
  local author = type(message.author) == "table" and (message.author.global_name or message.author.username) or "Unknown member"
  local body = safe(message.content, 1500)
  if body == "" then body = "(No text content; attachments are not copied.)" end
  return "⭐ **" .. tostring(count) .. "** · <" .. url .. ">\n" .. safe(author, 100) .. ": " .. body
end

function Starboard:_publish(guild, channel, origin_id, count, config, existing)
  if not self.rest or type(self.rest.get_message) ~= "function" or type(self.rest.send_message) ~= "function" then
    return false, "discord_unavailable"
  end
  local fetched, message = pcall(self.rest.get_message, self.rest, channel, origin_id)
  if not fetched or type(message) ~= "table" or type(message.author) ~= "table" or message.author.bot
    or (message.guild_id and message.guild_id ~= guild) or (message.channel_id and message.channel_id ~= channel) then
    self:_delete(guild, origin_id, existing)
    return false, "message_unavailable"
  end
  if existing and existing.state == "sent" and existing.channel_id ~= config.channel_id then
    if not self:_delete(guild, origin_id, existing) then return false, "relocation_failed" end
    existing = nil
  end
  if not self:_nsfw_allowed(guild, channel, config.channel_id) then
    if existing then self:_delete(guild, origin_id, existing) end
    return false, "channel_safety_check_failed"
  end
  local content = self:_content(guild, channel, message, count)
  local payload = { content = content, allowed_mentions = { parse = {} } }
  if existing and existing.state == "sent" and existing.message_id then
    if type(self.rest.edit_message) ~= "function" then return false, "discord_unavailable" end
    local called, result = pcall(self.rest.edit_message, self.rest, existing.channel_id, existing.message_id, payload)
    if not rest_succeeded(called, result) then return false, "edit_failed" end
    local saved, reason = self:_save_post(guild, origin_id,
      { state = "sent", channel_id = existing.channel_id, message_id = existing.message_id })
    if not saved then return false, reason end
    return true, "updated"
  end

  if not existing then
    local stored, reason = self:_save_post(guild, origin_id,
      { state = "pending", channel_id = config.channel_id, message_id = "" })
    if not stored then return false, reason end
  elseif existing.state == "pending" then
    return false, "post_pending"
  end
  local called, posted = pcall(self.rest.send_message, self.rest, config.channel_id, payload)
  local posted_id = called and type(posted) == "table" and posted.id or nil
  if not called or not Store.valid_id(posted_id) then return false, "send_failed" end
  local saved, reason = self:_save_post(guild, origin_id,
    { state = "sent", channel_id = config.channel_id, message_id = posted_id })
  if not saved then return false, reason end
  return true, "posted"
end

function Starboard:on_reaction(reaction, added)
  if type(reaction) ~= "table" or type(added) ~= "boolean" then return false, "invalid_reaction" end
  local guild, channel, origin, user = reaction.guild_id, reaction.channel_id, reaction.message_id, reaction.user_id
  if not Store.valid_id(guild) or not Store.valid_id(channel) or not Store.valid_id(origin) or not Store.valid_id(user) then
    return false, "invalid_reaction"
  end
  if self.bot_id and user == self.bot_id then return true, "ignored_bot" end
  local ok, config = self.settings:get_domain(guild, "starboard")
  if not ok then return false, config end
  if not config.enabled or not Store.valid_id(config.channel_id) or ignored(config, channel)
    or config.channel_id == channel or not emoji_matches(config.emoji, reaction.emoji) then
    return true, "ignored"
  end

  local cache_key = guild .. ":" .. origin .. ":" .. config.emoji
  local state = self.cache[cache_key]
  local first = not state or self.clock() - state.updated > CACHE_TTL
  if first then
    if not self.rest or type(self.rest.get_message) ~= "function" then return false, "discord_unavailable" end
    local called, message = pcall(self.rest.get_message, self.rest, channel, origin)
    if not called or type(message) ~= "table" then return false, "message_unavailable" end
    state = { count = reaction_count(message, config.emoji), users = {}, channel_id = channel }
    state.users[user] = added
    self:_cache_state(cache_key, state)
  else
    if state.channel_id ~= channel then return false, "channel_mismatch" end
    local previous = state.users[user]
    if previous == added then return true, "duplicate_reaction" end
    if previous == nil then
      local tracked = 0
      for _ in pairs(state.users) do tracked = tracked + 1 end
      if tracked >= MAX_USERS_PER_MESSAGE then
        local called, message = pcall(self.rest.get_message, self.rest, channel, origin)
        if not called or type(message) ~= "table" then return false, "message_unavailable" end
        state = { count = reaction_count(message, config.emoji), users = { [user] = added }, channel_id = channel }
      else
        state.count = math.max(0, state.count + (added and 1 or -1))
        state.users[user] = added
      end
    else
      state.count = math.max(0, state.count + (added and 1 or -1))
      state.users[user] = added
    end
    self:_cache_state(cache_key, state)
  end

  local saved, post = self:_post(guild, origin)
  if not saved then return false, post end
  if state.count >= config.threshold then
    local now = self.clock()
    if state.last_publish and now - state.last_publish < 2 then return true, "update_rate_limited" end
    local published, result = self:_publish(guild, channel, origin, state.count, config, post)
    if published then state.last_publish = now; self:_cache_state(cache_key, state) end
    return published, result
  end
  if post then return self:_delete(guild, origin, post) end
  return true, "below_threshold"
end

return Starboard
