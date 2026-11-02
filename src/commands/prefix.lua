local Store = require("src.persistence.guild_store")

local Prefix = {}
Prefix.__index = Prefix

local usage_argument = { user = "<@user>", amount = "<amount>" }

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

function Prefix.new(economy, options)
  options = options or {}
  assert(type(economy) == "table" and type(economy.definition) == "function" and type(economy.execute) == "function",
    "economy prefix handlers are required")
  local prefix = options.prefix or "."
  assert(type(prefix) == "string" and #prefix == 1, "prefix must be one character")
  return setmetatable({ economy = economy, prefix = prefix, logger = options.logger }, Prefix)
end

function Prefix:_reply(message, text, command)
  local ok = pcall(message.reply, message, text)
  if not ok and self.logger then
    self.logger:warn("prefix_command_reply_failed", { command = command or "unknown", detail = "discord_rest_error" })
  end
  return ok
end

function Prefix:dispatch(message)
  if type(message) ~= "table" or type(message.author) ~= "table" or message.author.bot or message.webhook_id then
    return false, "ignored_message"
  end
  if not Store.valid_id(message.guild_id) then return false, "not_a_guild_message" end
  if not Store.valid_id(message.author.id) or not Store.valid_id(message.id) then return false, "invalid_message" end
  if type(message.content) ~= "string" or message.content:sub(1, #self.prefix) ~= self.prefix then
    return false, "not_a_prefix_command"
  end

  local body = message.content:sub(#self.prefix + 1)
  local command, raw_arguments = body:match("^([%w_%-]+)%s*(.*)$")
  if not command then return false, "malformed_prefix_command" end
  command = command:lower()
  local definition = self.economy:definition(command)
  if not definition then return false, "unknown_command" end

  local arguments = words(raw_arguments or "")
  if #arguments ~= #definition.arguments then
    local usage = self.prefix .. command
    for _, name in ipairs(definition.arguments) do usage = usage .. " " .. (usage_argument[name] or ("<" .. name .. ">")) end
    self:_reply(message, "Usage: " .. usage, command)
    return false, "invalid_arguments"
  end

  local parsed = {}
  for index, name in ipairs(definition.arguments) do
    local value = arguments[index]
    if name == "user" then
      value = user_argument(value)
      if not value then
        self:_reply(message, "Mention a valid server user. Usage: " .. self.prefix .. "pay <@user> <amount>", command)
        return false, "invalid_user_argument"
      end
    end
    parsed[name] = value
  end

  local context = {
    guild = { id = message.guild_id },
    author = { id = message.author.id },
    request_id = message.id,
    request_type = "message",
    get_arg = function(_, name) return parsed[name] end,
  }
  local success, response = self.economy:execute(command, context)
  if type(response) ~= "string" then response = "Molly could not complete the request." end
  local replied = self:_reply(message, response, command)
  if not replied then return false, "reply_failed" end
  return success, response
end

function Prefix:register(bot)
  if not bot or type(bot.on_message) ~= "function" then return false, "message_event_unavailable" end
  bot:on_message(function(message) self:dispatch(message) end)
  return true
end

return Prefix
