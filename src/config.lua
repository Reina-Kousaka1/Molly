local Config = {}

local function trim(value)
  if type(value) ~= "string" then return nil end
  local result = value:match("^%s*(.-)%s*$")
  if result == "" then return nil end
  return result
end
local function read(env, name) if type(env) == "function" then return env(name) end return env[name] end
local function positive_integer(value, default, minimum, maximum, errors, name)
  value = trim(value); if not value then return default end
  local number = tonumber(value)
  if not number or number % 1 ~= 0 or number < minimum or number > maximum then errors[#errors + 1] = name; return default end
  return number
end
local function boolean(value, default, errors, name)
  value = trim(value)
  if not value then return default end
  if value:lower() == "true" then return true end
  if value:lower() == "false" then return false end
  errors[#errors + 1] = name
  return default
end
local function valid_http_url(value) return value and value:match("^https?://[^/%s]+") and not value:match("^https?://[^/]*@") end
local function ids(value, errors)
  local result = {}; value = trim(value)
  if not value then return result end
  for item in value:gmatch("[^,]+") do
    local id = trim(item)
    if not id or not id:match("^%d+$") or #id > 20 then errors[#errors + 1] = "MOLLY_DEVELOPER_IDS"; return {} end
    result[id] = true
  end
  return result
end
local function local_updater_url(value)
  return not value or value:match("^http://127%.0%.0%.1:%d+/[%w%-%._/]+$") or value:match("^http://localhost:%d+/[%w%-%._/]+$")
end

function Config.load(env)
  env = env or os.getenv
  local errors = {}
  local token = trim(read(env, "MOLLY_DISCORD_TOKEN")); if not token then errors[#errors + 1] = "MOLLY_DISCORD_TOKEN" end
  local sea_world_url = trim(read(env, "SEAWORLD_HEALTH_URL")); local sea_world_socket = trim(read(env, "MOLLY_SEAWORLD_SOCKET"))
  if sea_world_socket and (sea_world_socket:sub(1, 1) ~= "/" or sea_world_socket:find("%z")) then errors[#errors + 1] = "MOLLY_SEAWORLD_SOCKET" end
  if sea_world_url and not valid_http_url(sea_world_url) then errors[#errors + 1] = "SEAWORLD_HEALTH_URL" end
  local timeout_ms = positive_integer(read(env, "SEAWORLD_TIMEOUT_MS"), 1000, 100, 30000, errors, "SEAWORLD_TIMEOUT_MS")
  local retry_attempts = positive_integer(read(env, "SEAWORLD_RETRY_ATTEMPTS"), 1, 1, 3, errors, "SEAWORLD_RETRY_ATTEMPTS")
  local lavalink_url = trim(read(env, "MOLLY_LAVALINK_URL")); local lavalink_password = trim(read(env, "MOLLY_LAVALINK_PASSWORD")); local music_errors = {}
  if lavalink_url and not valid_http_url(lavalink_url) then music_errors[#music_errors + 1] = "MOLLY_LAVALINK_URL" end
  if lavalink_url and not lavalink_password then music_errors[#music_errors + 1] = "MOLLY_LAVALINK_PASSWORD" elseif lavalink_password and not lavalink_url then music_errors[#music_errors + 1] = "MOLLY_LAVALINK_URL" end
  local lavalink_timeout_ms = positive_integer(read(env, "MOLLY_LAVALINK_TIMEOUT_MS"), 1000, 100, 30000, music_errors, "MOLLY_LAVALINK_TIMEOUT_MS")
  local developers = ids(read(env, "MOLLY_DEVELOPER_IDS"), errors)
  local guild_members_intent = boolean(read(env, "MOLLY_GUILD_MEMBERS_INTENT"), false, errors, "MOLLY_GUILD_MEMBERS_INTENT")
  local updater_url, updater_token = trim(read(env, "MOLLY_UPDATER_URL")), trim(read(env, "MOLLY_UPDATER_TOKEN"))
  if not local_updater_url(updater_url) then errors[#errors + 1] = "MOLLY_UPDATER_URL" end
  if (updater_url and not updater_token) or (updater_token and not updater_url) then errors[#errors + 1] = updater_url and "MOLLY_UPDATER_TOKEN" or "MOLLY_UPDATER_URL" end
  if #errors > 0 then return nil, errors end
  return {
    discord = { token = token, guild_members_intent = guild_members_intent }, developers = developers,
    integrations = { spotify_client_id = trim(read(env, "MOLLY_SPOTIFY_CLIENT_ID")), spotify_client_secret = trim(read(env, "MOLLY_SPOTIFY_CLIENT_SECRET")), youtube_api_key = trim(read(env, "MOLLY_YOUTUBE_API_KEY")) },
    music = { lavalink_url = lavalink_url, lavalink_password = lavalink_password, lavalink_timeout_ms = lavalink_timeout_ms, configuration_errors = music_errors },
    seaworld = { socket = sea_world_socket, health_url = sea_world_url, timeout_ms = timeout_ms, retry_attempts = retry_attempts },
    updater = { url = updater_url, token = updater_token },
    build = { version = trim(read(env, "MOLLY_VERSION")) or "1.2", commit = trim(read(env, "MOLLY_COMMIT")) },
  }
end

return Config
