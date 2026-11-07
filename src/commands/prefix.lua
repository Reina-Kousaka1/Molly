local Store = require("src.persistence.guild_store")
local Personality = require("src.personality")

local Prefix = {}
Prefix.__index = Prefix

local usage_argument = { user = "<@user>", amount = "<amount>", reason = "<reason>" }

local function words(text)
  local result = {}
  for word in text:gmatch("%S+") do result[#result + 1] = word end
  return result
end

local function user_argument(value)
  local id = value:match("^<@!?([1-9]%d+)>$") or value:match("^([1-9]%d+)$")
  if not Store.valid_id(id) then return nil end
  return { id = id }
end

function Prefix.new(router, settings, options)
  options = options or {}
  assert(type(router) == "table" and type(router.prefix_definition) == "function"
    and type(router.dispatch_prefix) == "function", "command router is required")
  assert(type(settings) == "table" and type(settings.get) == "function", "guild settings are required")
  local prefix = options.prefix or "."
  return setmetatable({ router = router, settings = settings, default_prefix = prefix,
    logger = options.logger, clock = options.clock or os.time, cache_ttl = options.cache_ttl or 30,
    prefixes = {}, bot = nil }, Prefix)
end

function Prefix:_reply(message, text, command)
  local ok = pcall(message.reply, message, Personality.prefix_response(text))
  if not ok and self.logger then
    self.logger:warn("prefix_command_reply_failed", { command = command or "unknown", detail = "discord_rest_error" })
  end
  return ok
end

function Prefix:set_prefix(guild, prefix)
  if not Store.valid_id(guild) or type(prefix) ~= "string" then return false end
  self.prefixes[guild] = { value = prefix, expires = self.clock() + self.cache_ttl }
  return true
end

function Prefix:invalidate(guild)
  self.prefixes[guild] = nil
end

function Prefix:_prefix_for(guild)
  local now = self.clock()
  local cached = self.prefixes[guild]
  if cached and cached.expires >= now then return cached.value end
  local ok, value = self.settings:get(guild)
  if not ok or type(value) ~= "table" or type(value.prefix) ~= "string" then
    if self.logger then self.logger:warn("prefix_settings_unavailable", { detail = "guild_settings_unavailable" }) end
    self.prefixes[guild] = nil
    return nil
  end
  local prefix = value.prefix or self.default_prefix
  self.prefixes[guild] = { value = prefix, expires = now + self.cache_ttl }
  return prefix
end

function Prefix:dispatch(message)
  if type(message) ~= "table" or type(message.author) ~= "table" or message.author.bot or message.webhook_id then
    return false, "ignored_message"
  end
  if not Store.valid_id(message.guild_id) then return false, "not_a_guild_message" end
  if not Store.valid_id(message.author.id) or not Store.valid_id(message.id) then return false, "invalid_message" end
  if type(message.content) ~= "string" then return false, "not_a_prefix_command" end

  local prefix = self:_prefix_for(message.guild_id)
  if not prefix or message.content:sub(1, #prefix) ~= prefix then return false, "not_a_prefix_command" end
  local body = message.content:sub(#prefix + 1)
  local command, raw_arguments = body:match("^([%w_%-]+)%s*(.*)$")
  if not command then return false, "malformed_prefix_command" end
  command = command:lower()
  local definition = self.router:prefix_definition(command)
  if not definition then return false, "unknown_command" end

  local argument_names = definition.prefix.arguments or {}
  local arguments = words(raw_arguments or "")
  local has_reason_tail = argument_names[#argument_names] == "reason"
  if (has_reason_tail and #arguments < #argument_names) or (not has_reason_tail and #arguments ~= #argument_names) then
    local usage = prefix .. command
    for _, name in ipairs(argument_names) do usage = usage .. " " .. (usage_argument[name] or ("<" .. name .. ">")) end
    self:_reply(message, "Usage: " .. usage, command)
    return false, "invalid_arguments"
  end

  local parsed = {}
  for index, name in ipairs(argument_names) do
    local value = name == "reason" and index == #argument_names and table.concat(arguments, " ", index) or arguments[index]
    if name == "user" then
      value = user_argument(value)
      if not value then
        self:_reply(message, "Mention a valid server user. Usage: " .. prefix .. "pay <@user> <amount>", command)
        return false, "invalid_user_argument"
      end
    end
    parsed[name] = value
  end

  local context = {
    source = "message", transport = "message", message = message, guild = { id = message.guild_id },
    author = { id = message.author.id }, member = message.member,
    bot = self.bot and (self.bot.client or self.bot) or nil,
    channel = message.channel or { id = message.channel_id, name = message.channel_name, type = message.channel_type },
    channel_id = message.channel_id, request_id = message.id, request_type = "message", command_prefix = prefix,
    get_arg = function(_, name) return parsed[name] end,
  }
  local response_ok = true
  context.respond = function(_, text)
    response_ok = self:_reply(message, type(text) == "string" and text or "Molly could not complete the request.", command)
    return response_ok
  end
  context.edit = context.respond

  local handled, reason = self.router:dispatch_prefix(command, context)
  if not response_ok then return false, "reply_failed" end
  return handled, reason
end

function Prefix:register(bot)
  if not bot or type(bot.on_message) ~= "function" then return false, "message_event_unavailable" end
  self.bot = bot
  bot:on_message(function(message) self:dispatch(message) end)
  return true
end

return Prefix
