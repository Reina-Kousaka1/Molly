local MoneyResponder = {}

local REPLY = "For your coins, try `/balance`, `/daily`, or `/transactions`."

function MoneyResponder.normalize(content)
  if type(content) ~= "string" then return nil end
  local normalized = content:match("^%s*(.-)%s*$") or ""
  normalized = normalized:lower():gsub("[.!?]+$", "")
  return normalized:match("^%s*(.-)%s*$")
end

function MoneyResponder.matches(content)
  return MoneyResponder.normalize(content) == "money"
end

function MoneyResponder.gateway_intents(discord)
  local enums = discord and discord.enums
  if not enums or type(enums.combine_intents) ~= "function" or type(enums.default_intents) ~= "function"
    or type(enums.INTENTS) ~= "table" or type(enums.INTENTS.MESSAGE_CONTENT) ~= "number" then
    return nil, "gateway_intents_unavailable"
  end
  return enums.combine_intents(enums.default_intents(), enums.INTENTS.MESSAGE_CONTENT)
end

function MoneyResponder.register(bot, logger)
  if not bot or type(bot.on_message) ~= "function" then return false, "message_event_unavailable" end
  bot:on_message(function(message)
    if type(message) ~= "table" or type(message.author) ~= "table" or message.author.bot then return end
    if type(message.guild_id) ~= "string" or not message.guild_id:match("^%d+$") then return end
    if not MoneyResponder.matches(message.content) then return end
    local ok, result = pcall(message.reply, message, REPLY)
    if not ok and logger then logger:warn("money_responder_reply_failed", { detail = "discord_rest_error" }) end
    return ok and result or nil
  end)
  return true
end

MoneyResponder.reply = REPLY
return MoneyResponder
