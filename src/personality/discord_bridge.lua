-- Bounded, opt-in bridge from direct Discord mentions to the shared LLM engine.
local Bridge = {}
Bridge.__index = Bridge

local function valid_id(value)
  return type(value) == "string" and value:match("^%d+$") ~= nil and #value <= 20
end

local function attachment_count(message)
  return type(message) == "table" and type(message.attachments) == "table" and #message.attachments or 0
end

local function prune_recent(self, now)
  for id, at in pairs(self.recent_messages) do
    if now - at >= self.recent_message_ttl then
      self.recent_messages[id] = nil
      self.recent_message_count = math.max(0, self.recent_message_count - 1)
    end
  end
end

function Bridge.new(options)
  assert(type(options) == "table" and options.engine and type(options.engine.generate) == "function", "engine required")
  return setmetatable({
    enabled = options.enabled == true,
    engine = options.engine,
    image_loader = options.image_loader,
    send = options.send,
    logger = options.logger,
    clock = options.clock or os.time,
    spawn = options.spawn or function(fn) coroutine.wrap(fn)() end,
    is_prefix_command = options.is_prefix_command,
    bot_id = options.bot_id,
    cooldown_seconds = options.cooldown_seconds or 30,
    max_parallel = options.max_parallel or 1,
    parallel = 0,
    cooldowns = {},
    inflight = {},
    max_cooldown_entries = options.max_cooldown_entries or 2048,
    recent_messages = {},
    recent_message_count = 0,
    recent_message_ttl = options.recent_message_ttl or 600,
    max_recent_messages = options.max_recent_messages or 4096,
  }, Bridge)
end

function Bridge:matches(message)
  if not self.enabled or type(message) ~= "table" or type(message.author) ~= "table"
    or not valid_id(self.bot_id) or not valid_id(message.author.id) or message.author.bot == true
    or message.webhook_id ~= nil or not valid_id(message.guild_id) or not valid_id(message.channel_id)
    or not valid_id(message.id) or type(message.content) ~= "string" or #message.content > 4000 then return false end
  local id = self.bot_id:gsub("([^%w])", "%%%1")
  local mention = "<@" .. id .. ">"
  local nickname_mention = "<@!" .. id .. ">"
  local start = message.content:find(mention, 1, true) or message.content:find(nickname_mention, 1, true)
  if not start then return false end
  if self.is_prefix_command then
    local checked, is_command = pcall(self.is_prefix_command, message)
    if not checked or is_command == nil or is_command then return false end
  end
  local rest = message.content:gsub("<@!?" .. id .. ">", "", 1):gsub("^%s+", "")
  if rest:match("^[.!/]%w+") then return false end
  return true
end

local function clean_detail(error_value)
  if type(error_value) == "table" and type(error_value.code) == "string"
    and #error_value.code <= 60 and error_value.code:match("^[%w_%-]+$") then
    return error_value.code
  end
  if type(error_value) == "string" then
    local lower = error_value:lower()
    if lower:find("yield", 1, true) then return "async_yield_error" end
    if lower:find("timeout", 1, true) then return "timeout" end
    if lower:find("module", 1, true) and lower:find("not found", 1, true) then
      return "dependency_unavailable"
    end
    if lower:find("attempt to call", 1, true) then return "lua_call_error" end
    if lower:find("attempt to index", 1, true) then return "lua_index_error" end
    if lower:find("bad argument", 1, true) then return "lua_argument_error" end
    return "runtime_error"
  end
  if error_value ~= nil then return "invalid_runtime_error" end
  return "provider_unavailable"
end

local function safe_error_location(error_value)
  if type(error_value) ~= "string" or #error_value > 4096 then return nil end
  local source, line = error_value:match("([%w%._/%-]+%.lua):(%d+)")
  local filename = source and source:match("([^/]+)$")
  local number = tonumber(line)
  if not filename or not filename:match("^[%w_.%-]+$") or not number or number < 1 or number > 100000 then
    return nil
  end
  return filename .. ":" .. line
end
local function send_text(self, channel_id, content)
  if not self.send then return end
  local sent, accepted = pcall(self.send, channel_id, content)
  if (not sent or accepted == false) and self.logger then
    pcall(self.logger.warn, self.logger, "personality_discord_send_failed", { detail = "send_failed" })
  end
end

function Bridge:on_message(message)
  if not self:matches(message) then return false, "ignored" end
  local now = self.clock()
  local scope = message.guild_id .. ":" .. message.author.id
  if self.inflight[message.id] then return false, "duplicate" end
  local recent_at = self.recent_messages[message.id]
  if recent_at then
    if now - recent_at < self.recent_message_ttl then return false, "duplicate" end
    self.recent_messages[message.id] = nil
    self.recent_message_count = math.max(0, self.recent_message_count - 1)
  end
  if now - (self.cooldowns[scope] or 0) < self.cooldown_seconds then return false, "cooldown" end
  if self.parallel >= self.max_parallel then
    -- Remember a delivery rejected for concurrency so a gateway replay after
    -- the current generation does not unexpectedly produce a delayed reply.
    prune_recent(self, now)
    if self.recent_message_count < self.max_recent_messages then
      self.recent_messages[message.id] = now
      self.recent_message_count = self.recent_message_count + 1
    end
    return false, "busy"
  end
  local count = 0
  for key, at in pairs(self.cooldowns) do
    if now - at >= self.cooldown_seconds then self.cooldowns[key] = nil else count = count + 1 end
  end
  if count >= self.max_cooldown_entries and not self.cooldowns[scope] then return false, "busy" end
  if self.recent_message_count >= self.max_recent_messages then
    prune_recent(self, now)
    if self.recent_message_count >= self.max_recent_messages then return false, "busy" end
  end

  local content = message.content:gsub("<@!?" .. self.bot_id .. ">", "", 1):gsub("^%s+", "")
  local has_attachments = attachment_count(message) > 0
  if content == "" and not has_attachments then return false, "empty" end

  self.inflight[message.id] = true
  self.recent_messages[message.id] = now
  self.recent_message_count = self.recent_message_count + 1
  self.parallel = self.parallel + 1
  self.cooldowns[scope] = now

  local function release()
    self.inflight[message.id] = nil
    self.parallel = math.max(0, self.parallel - 1)
  end

  local spawned = pcall(self.spawn, function()
    local called, reply, generation_error = pcall(function()
      local images = {}
      if self.image_loader then
        local prepared, prepare_error = self.image_loader:prepare(message.attachments)
        if type(prepared) ~= "table" then
          return nil, { code = type(prepare_error) == "string" and prepare_error or "invalid_attachment" }
        end
        images = prepared
      elseif has_attachments then
        return nil, { code = "image_download_unavailable" }
      end

      local prompt = content
      if prompt == "" and #images > 0 then prompt = "Please describe the image I attached." end
      local request = {
        content = prompt,
        scope = { guild_id = message.guild_id, channel_id = message.channel_id, user_id = message.author.id },
      }
      if #images > 0 then request.images = images end
      return self.engine:generate(request)
    end)

    if called and type(reply) == "string" and reply ~= "" and self.send then
      send_text(self, message.channel_id, reply)
    elseif has_attachments then
      -- Keep vision failures visible without ever downgrading the attachment
      -- to a text-only model. The response contains no provider or URL detail.
      local text = called
        and "I couldn't safely read that picture just now, bestie. Try one clear JPG, PNG, or WebP image 🎀"
        or "I couldn't open that picture safely, bestie. Try one clear JPG, PNG, or WebP image 🎀"
      send_text(self, message.channel_id, text)
      if self.logger then
        local detail = clean_detail(not called and reply or generation_error)
        local fields = { detail = detail }
        if not called then fields.location = safe_error_location(reply) end
        pcall(self.logger.warn, self.logger, "personality_discord_vision_failed", fields)
      end
    elseif self.logger then
      local detail = clean_detail(not called and reply or generation_error)
      local fields = { detail = detail }
      if not called then fields.location = safe_error_location(reply) end
      pcall(self.logger.warn, self.logger, "personality_discord_generation_failed", fields)
    end
    release()
  end)

  if not spawned then
    release()
    self.recent_messages[message.id] = nil
    self.recent_message_count = math.max(0, self.recent_message_count - 1)
    self.cooldowns[scope] = nil
    return false, "spawn_failed"
  end
  return true, "accepted"
end

function Bridge:set_bot_id(id)
  self.bot_id = valid_id(id) and id or nil
end

return Bridge
