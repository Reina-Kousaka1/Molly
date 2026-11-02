local Updater = {}
Updater.__index = Updater

local function local_url(value)
  return type(value) == "string" and (value:match("^http://127%.0%.0%.1:%d+/[%w%-%._/]+$") or value:match("^http://localhost:%d+/[%w%-%._/]+$")) ~= nil
end

function Updater.new(options)
  options = options or {}
  if not local_url(options.url) or type(options.token) ~= "string" or options.token == "" or type(options.transport) ~= "function" then return nil, "not_configured" end
  return setmetatable({ url = options.url, token = options.token, transport = options.transport }, Updater)
end

function Updater:request(marker)
  local body = string.format('{"action":"update","interaction_id":"%s","guild_id":"%s","channel_id":"%s"}', marker.interaction_id, marker.guild_id, marker.channel_id)
  local ok, response = pcall(self.transport, "POST", self.url, { headers = { authorization = "Bearer " .. self.token,
    ["content-type"] = "application/json" }, body = body })
  if not ok or type(response) ~= "table" or tonumber(response.code) ~= 202 then return false, "updater_unavailable" end
  return true
end

return Updater
