local Store = require("src.persistence.guild_store")

local ActionLog = {}
ActionLog.__index = ActionLog

local function safe(value, maximum)
  return tostring(value or ""):gsub("@", "@\226\128\139"):gsub("[\r\n]", " ")
    :gsub("[%z\1-\8\11\12\14-\31\127]", " "):sub(1, maximum or 160)
end

function ActionLog.new(settings, options)
  options = options or {}
  assert(type(settings) == "table" and type(settings.get_domain) == "function", "guild settings are required")
  return setmetatable({ settings = settings, send = options.send, logger = options.logger }, ActionLog)
end

function ActionLog:set_sender(send)
  self.send = send
end

function ActionLog:record(guild, event, message)
  if not Store.valid_id(guild) or type(event) ~= "string" then return false, "invalid_argument" end
  local ok, config = self.settings:get_domain(guild, "logs")
  if not ok then return false, config end
  if not config.enabled or not Store.valid_id(config.channel_id) or config.events[event] ~= true then
    return true, "disabled"
  end
  if not self.send then return false, "discord_unavailable" end
  local content = safe(message, 1800)
  if content == "" then return false, "empty_message" end
  local called, response = pcall(self.send, config.channel_id,
    { content = content, allowed_mentions = { parse = {} } })
  if not called or response == false then
    if self.logger then self.logger:warn("action_log_delivery_failed", { event = event, detail = "discord_unavailable" }) end
    return false, "delivery_failed"
  end
  return true, "sent"
end

return ActionLog
