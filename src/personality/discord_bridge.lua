-- Bounded, opt-in bridge from direct Discord mentions to the existing LLM engine.
local Bridge = {}
Bridge.__index = Bridge

local function valid_id(value)
  return type(value) == "string" and value:match("^%d+$") ~= nil and #value <= 20
end

function Bridge.new(options)
  assert(type(options) == "table" and options.engine and type(options.engine.generate) == "function", "engine required")
  return setmetatable({ enabled = options.enabled == true, engine = options.engine,
    send = options.send, logger = options.logger, clock = options.clock or os.time,
    spawn = options.spawn or function(fn) coroutine.wrap(fn)() end,
    is_prefix_command = options.is_prefix_command,
    bot_id = options.bot_id, cooldown_seconds = options.cooldown_seconds or 30,
    max_parallel = options.max_parallel or 2, parallel = 0, cooldowns = {}, inflight = {},
    max_cooldown_entries = options.max_cooldown_entries or 2048 }, Bridge)
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
    -- If guild prefix settings cannot be checked, fail closed for this message.
    if not checked or is_command == nil or is_command then return false end
  end
  local rest = message.content:gsub("<@!?" .. id .. ">", "", 1):gsub("^%s+", "")
  -- Preserve conventional prefix commands even when Molly is mentioned first.
  if rest:match("^[.!/]%w+") then return false end
  return true
end

function Bridge:on_message(message)
  if not self:matches(message) then return false, "ignored" end
  local now = self.clock()
  local scope = message.guild_id .. ":" .. message.author.id
  if self.inflight[message.id] then return false, "duplicate" end
  if now - (self.cooldowns[scope] or 0) < self.cooldown_seconds then return false, "cooldown" end
  if self.parallel >= self.max_parallel then return false, "busy" end
  local count = 0
  for key, at in pairs(self.cooldowns) do
    if now - at >= self.cooldown_seconds then self.cooldowns[key] = nil else count = count + 1 end
  end
  if count >= self.max_cooldown_entries and not self.cooldowns[scope] then return false, "busy" end
  local content = message.content:gsub("<@!?" .. self.bot_id .. ">", "", 1):gsub("^%s+", "")
  if content == "" then return false, "empty" end
  self.inflight[message.id] = true
  self.parallel = self.parallel + 1
  self.cooldowns[scope] = now
  local spawned = pcall(self.spawn, function()
    local called, reply, generation_error = pcall(self.engine.generate, self.engine, { content = content })
    if called and type(reply) == "string" and reply ~= "" and self.send then
      local sent, accepted = pcall(self.send, message.channel_id, reply)
      if (not sent or accepted == false) and self.logger then
        pcall(self.logger.warn, self.logger, "personality_discord_send_failed", { detail = "send_failed" })
      end
    elseif (not called or reply == nil) and self.logger then
      local detail = "provider_unavailable"
      if not called then
        detail = "handler_error"
      elseif type(generation_error) == "table" and type(generation_error.code) == "string"
        and #generation_error.code <= 60 and generation_error.code:match("^[%w_%-]+$") then
        detail = generation_error.code
      end
      pcall(self.logger.warn, self.logger, "personality_discord_generation_failed", { detail = detail })
    end
    self.inflight[message.id] = nil
    self.parallel = math.max(0, self.parallel - 1)
  end)
  if not spawned then
    self.inflight[message.id] = nil
    self.parallel = math.max(0, self.parallel - 1)
    return false, "spawn_failed"
  end
  return true, "accepted"
end

function Bridge:set_bot_id(id)
  self.bot_id = valid_id(id) and id or nil
end

return Bridge
