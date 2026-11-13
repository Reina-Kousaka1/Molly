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
local function valid_preppydb_url(value)
  return value and value:match("^http://[^/%s]+") and not value:match("^http://[^/]*@")
end
local function origin_url(value)
  -- Built-in Luvit transport is HTTP-only; require an origin, not a URL path.
  return type(value) == "string" and value:match("^http://[^/%s@?#]+/?$") ~= nil
end
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
  local persistence_backend = (trim(read(env, "MOLLY_PERSISTENCE_BACKEND")) or "seaworld"):lower()
  if persistence_backend ~= "seaworld" and persistence_backend ~= "preppydb" then
    errors[#errors + 1] = "MOLLY_PERSISTENCE_BACKEND"
    persistence_backend = "seaworld"
  end
  local preppydb_url = trim(read(env, "MOLLY_PREPPYDB_URL"))
  local preppydb_token = trim(read(env, "MOLLY_PREPPYDB_TOKEN"))
  local preppydb_timeout_ms = positive_integer(read(env, "MOLLY_PREPPYDB_TIMEOUT_MS"), 3000, 100, 30000, errors, "MOLLY_PREPPYDB_TIMEOUT_MS")
  local preppydb_max_response_bytes = positive_integer(read(env, "MOLLY_PREPPYDB_MAX_RESPONSE_BYTES"), 4 * 1024 * 1024, 1024, 16 * 1024 * 1024, errors, "MOLLY_PREPPYDB_MAX_RESPONSE_BYTES")
  if preppydb_url and not valid_preppydb_url(preppydb_url) then errors[#errors + 1] = "MOLLY_PREPPYDB_URL" end
  if preppydb_token and preppydb_token:find("[%z\1-\31\127]") then errors[#errors + 1] = "MOLLY_PREPPYDB_TOKEN" end
  if persistence_backend == "preppydb" then
    if not preppydb_url then errors[#errors + 1] = "MOLLY_PREPPYDB_URL" end
    if not preppydb_token then errors[#errors + 1] = "MOLLY_PREPPYDB_TOKEN" end
  end
  local lavalink_url = trim(read(env, "MOLLY_LAVALINK_URL")); local lavalink_password = trim(read(env, "MOLLY_LAVALINK_PASSWORD")); local music_errors = {}
  if lavalink_url and not valid_http_url(lavalink_url) then music_errors[#music_errors + 1] = "MOLLY_LAVALINK_URL" end
  if lavalink_url and not lavalink_password then music_errors[#music_errors + 1] = "MOLLY_LAVALINK_PASSWORD" elseif lavalink_password and not lavalink_url then music_errors[#music_errors + 1] = "MOLLY_LAVALINK_URL" end
  local lavalink_timeout_ms = positive_integer(read(env, "MOLLY_LAVALINK_TIMEOUT_MS"), 1000, 100, 30000, music_errors, "MOLLY_LAVALINK_TIMEOUT_MS")
  local developers = ids(read(env, "MOLLY_DEVELOPER_IDS"), errors)
  -- Personality Engine V1 (integration phase): opt-in and disabled by default.
  -- Misconfiguration here must never block a production boot, so these errors
  -- are reported separately (like music) and only keep the engine disabled.
  local personality_errors = {}
  local engine_enabled = boolean(read(env, "MOLLY_PERSONALITY_ENGINE_ENABLED"), false, personality_errors, "MOLLY_PERSONALITY_ENGINE_ENABLED")
  local ollama_url = trim(read(env, "MOLLY_OLLAMA_URL")) or "http://127.0.0.1:11434"
  if not origin_url(ollama_url) then personality_errors[#personality_errors + 1] = "MOLLY_OLLAMA_URL"; ollama_url = "http://127.0.0.1:11434" end
  local ollama_text_model = trim(read(env, "MOLLY_OLLAMA_TEXT_MODEL"))
  local legacy_ollama_model = trim(read(env, "MOLLY_OLLAMA_MODEL"))
  local text_model_variable = "MOLLY_OLLAMA_TEXT_MODEL"
  if not ollama_text_model and legacy_ollama_model then
    ollama_text_model = legacy_ollama_model
    text_model_variable = "MOLLY_OLLAMA_MODEL"
  end
  ollama_text_model = ollama_text_model or "qwen2.5:3b"
  if ollama_text_model:find("[%s%z\1-\31\127]") ~= nil or #ollama_text_model > 100 then
    personality_errors[#personality_errors + 1] = text_model_variable
    ollama_text_model = "qwen2.5:3b"
  end
  local ollama_vision_model = trim(read(env, "MOLLY_OLLAMA_VISION_MODEL")) or "qwen3.5:2b"
  if ollama_vision_model:find("[%s%z\1-\31\127]") ~= nil or #ollama_vision_model > 100 then
    personality_errors[#personality_errors + 1] = "MOLLY_OLLAMA_VISION_MODEL"
    ollama_vision_model = "qwen3.5:2b"
  end
  local ollama_thinking_enabled = boolean(read(env, "MOLLY_OLLAMA_THINKING_ENABLED"), false, personality_errors, "MOLLY_OLLAMA_THINKING_ENABLED")
  local ollama_timeout_ms = positive_integer(read(env, "MOLLY_OLLAMA_TIMEOUT_MS"), 15000, 100, 120000, personality_errors, "MOLLY_OLLAMA_TIMEOUT_MS")
  local ollama_max_bytes = positive_integer(read(env, "MOLLY_OLLAMA_MAX_RESPONSE_BYTES"), 262144, 1024, 4 * 1024 * 1024, personality_errors, "MOLLY_OLLAMA_MAX_RESPONSE_BYTES")
  local ollama_max_image_bytes = positive_integer(read(env, "MOLLY_OLLAMA_MAX_IMAGE_BYTES"), 4 * 1024 * 1024, 1024, 4 * 1024 * 1024, personality_errors, "MOLLY_OLLAMA_MAX_IMAGE_BYTES")
  local ollama_image_timeout_ms = positive_integer(read(env, "MOLLY_OLLAMA_IMAGE_TIMEOUT_MS"), 8000, 100, 30000, personality_errors, "MOLLY_OLLAMA_IMAGE_TIMEOUT_MS")
  local guild_members_intent = boolean(read(env, "MOLLY_GUILD_MEMBERS_INTENT"), false, errors, "MOLLY_GUILD_MEMBERS_INTENT")
  local updater_url, updater_token = trim(read(env, "MOLLY_UPDATER_URL")), trim(read(env, "MOLLY_UPDATER_TOKEN"))
  if not local_updater_url(updater_url) then errors[#errors + 1] = "MOLLY_UPDATER_URL" end
  if (updater_url and not updater_token) or (updater_token and not updater_url) then errors[#errors + 1] = updater_url and "MOLLY_UPDATER_TOKEN" or "MOLLY_UPDATER_URL" end
  if #errors > 0 then return nil, errors end
  return {
    discord = { token = token, guild_members_intent = guild_members_intent }, developers = developers,
    integrations = { spotify_client_id = trim(read(env, "MOLLY_SPOTIFY_CLIENT_ID")), spotify_client_secret = trim(read(env, "MOLLY_SPOTIFY_CLIENT_SECRET")), youtube_api_key = trim(read(env, "MOLLY_YOUTUBE_API_KEY")) },
    music = { lavalink_url = lavalink_url, lavalink_password = lavalink_password, lavalink_timeout_ms = lavalink_timeout_ms, configuration_errors = music_errors },
    persistence = {
      backend = persistence_backend,
      preppydb = {
        url = preppydb_url, token = preppydb_token, timeout_ms = preppydb_timeout_ms,
        max_response_bytes = preppydb_max_response_bytes,
      },
    },
    personality = {
      engine = {
        enabled = engine_enabled and #personality_errors == 0,
        requested = engine_enabled,
        configuration_errors = personality_errors,
        ollama = {
          url = ollama_url:gsub("/$", ""),
          model = ollama_text_model,
          text_model = ollama_text_model,
          vision_model = ollama_vision_model,
          thinking_enabled = ollama_thinking_enabled,
          max_image_bytes = ollama_max_image_bytes,
          image_timeout_ms = ollama_image_timeout_ms,
          timeout_ms = ollama_timeout_ms,
          max_response_bytes = ollama_max_bytes,
        },
      },
    },
    seaworld = { socket = sea_world_socket, health_url = sea_world_url, timeout_ms = timeout_ms, retry_attempts = retry_attempts },
    updater = { url = updater_url, token = updater_token },
    build = { version = trim(read(env, "MOLLY_VERSION")) or "1.2", commit = trim(read(env, "MOLLY_COMMIT")) },
  }
end

return Config
