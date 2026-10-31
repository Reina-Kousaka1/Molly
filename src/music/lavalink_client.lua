local Client = {}
Client.__index = Client
local json_ok, json = pcall(require, "json")
if not json_ok then json = nil end

local function unavailable(detail)
  return { status = "unavailable", detail = detail }
end

function Client.new(options)
  assert(type(options) == "table", "options are required")
  assert(type(options.url) == "string" and options.url ~= "", "Lavalink URL is required")
  assert(type(options.password) == "string" and options.password ~= "", "Lavalink password is required")
  assert(type(options.transport) == "function", "transport is required")
  return setmetatable({
    url = options.url:gsub("/$", ""),
    password = options.password,
    timeout_ms = options.timeout_ms or 1000,
    transport = options.transport,
    websocket = options.websocket,
    session_id = nil,
    ready = false,
    last_user_id = nil,
    retry_delay_ms = 5000,
  }, Client)
end

local function encode(value)
  return (tostring(value):gsub("([^%w%-%._~])", function(char)
    return string.format("%%%02X", string.byte(char))
  end))
end

function Client:_request(method, path, payload)
  if not json then return false, "json_unavailable" end
  local headers = { authorization = self.password }
  if self.session_id then headers["lavalink-session-id"] = self.session_id end
  local body = payload and json.encode(payload) or nil
  local ok, response, raw = pcall(self.transport, method, self.url .. path, {
    timeout_ms = self.timeout_ms, headers = headers, body = body,
  })
  if not ok or type(response) ~= "table" then return false, "request_failed" end
  local code = tonumber(response.code)
  if code == 401 or code == 403 then return false, "authentication_failed" end
  if not code or code < 200 or code > 299 then return false, "request_rejected" end
  if type(raw) ~= "string" or raw == "" then return true, nil end
  local decoded, value = pcall(json.decode, raw)
  if not decoded or type(value) ~= "table" then return false, "invalid_response" end
  return true, value
end

function Client:health()
  local ok, response, body = pcall(self.transport, "GET", self.url .. "/version", {
    timeout_ms = self.timeout_ms,
    headers = { authorization = self.password },
  })
  if not ok or not response then
    return unavailable("request_failed")
  end
  if tonumber(response.code) == 401 or tonumber(response.code) == 403 then
    return unavailable("authentication_failed")
  end
  if not tonumber(response.code) or tonumber(response.code) < 200 or tonumber(response.code) > 299 then
    return unavailable("unexpected_status")
  end
  if type(body) ~= "string" or not body:match("^4%.") then
    return unavailable("unsupported_version")
  end
  return { status = "connected", detail = "v4" }
end

-- Lavalink v4 only exposes player operations inside a WebSocket-created
-- session. The READY opcode supplies the session ID used by REST requests.
function Client:start(user_id, on_event)
  if type(user_id) ~= "string" or not user_id:match("^%d+$") then return false, "invalid_user" end
  self.last_user_id, self.on_event = user_id, on_event
  local websocket = self.websocket
  if not websocket then
    local ok, loaded = pcall(require, "coro-websocket")
    if not ok then return false, "websocket_unavailable" end
    websocket = loaded
  end
  local parse_ok, parsed, parse_error = pcall(websocket.parseUrl,
    (self.url:gsub("^http://", "ws://"):gsub("^https://", "wss://")) .. "/v4/websocket")
  if not parse_ok then parsed = nil end
  if not parsed then return false, "invalid_endpoint" end
  local headers = {
    { "Authorization", self.password },
    { "User-Id", user_id },
    { "Client-Name", "molly/1.0.0" },
  }
  if self.session_id then headers[#headers + 1] = { "Session-Id", self.session_id } end
  local connect_ok, result, read, write = pcall(websocket.connect, {
    host = parsed.host, port = parsed.port, tls = parsed.tls,
    pathname = parsed.pathname, headers = headers, timeout = self.timeout_ms,
    heartbeat = 30000,
  })
  if not connect_ok or not result or type(read) ~= "function" or type(write) ~= "function" then
    self:_schedule_reconnect()
    return false, connect_ok and (parse_error or "websocket_unavailable") or "websocket_unavailable"
  end
  self.socket, self.read, self.write = result.socket, read, write
  self.ready = false
  coroutine.wrap(function()
    pcall(self._read_events, self)
  end)()
  return true, "connecting"
end

function Client:_read_events()
  local reason = "disconnected"
  while self.read do
    local ok, message = pcall(self.read)
    if not ok or type(message) ~= "table" or type(message.payload) ~= "string" then break end
    local decoded_ok, event = pcall(json.decode, message.payload)
    if not decoded_ok or type(event) ~= "table" then
      reason = "invalid_event"
      break
    end
    if event.op == "ready" and type(event.sessionId) == "string" then
      self.session_id, self.ready = event.sessionId, true
      self.retry_delay_ms = 5000
      if self.on_event then pcall(self.on_event, { type = "ready", resumed = event.resumed == true }) end
    elseif event.op == "event" or event.op == "playerUpdate" then
      if self.on_event then pcall(self.on_event, event) end
    end
  end
  self.ready = false
  self.read, self.write = nil, nil
  if self.on_event then pcall(self.on_event, { type = "disconnected", detail = reason }) end
  if self.last_user_id and not self.stopping then self:_schedule_reconnect() end
end

function Client:_schedule_reconnect()
  if self.retry_timer then return end
  local timer = require("timer")
  local delay = self.retry_delay_ms
  self.retry_delay_ms = math.min(self.retry_delay_ms * 2, 60000)
  self.retry_timer = timer.setTimeout(delay, function()
    self.retry_timer = nil
    if self.last_user_id and not self.stopping then
      local ok, started = pcall(self.start, self, self.last_user_id, self.on_event)
      if not ok or not started then self:_schedule_reconnect() end
    end
  end)
end

function Client:resolve(query)
  if type(query) ~= "string" or query:match("^%s*$") or #query > 500 then return false, "invalid_query" end
  local has_search_prefix = query:match("^[%a][%w+%.%-]*search:") ~= nil
  local supported_search_prefix = query:match("^ytsearch:") ~= nil or query:match("^spsearch:") ~= nil
  if has_search_prefix and not supported_search_prefix then return false, "unsupported_search_prefix" end
  if not json then return false, "json_unavailable" end
  local identifier = query:match("^https?://") and query or
    (supported_search_prefix and query or ("ytsearch:" .. query))
  local ok, result = self:_request("GET", "/v4/loadtracks?identifier=" .. encode(identifier))
  if not ok then return false, result end
  local load_type = result and (result.loadType or result.load_type)
  if load_type == "empty" or load_type == "error" then return false, "no_results" end
  local tracks = result and (result.data or result.tracks)
  if load_type == "playlist" and type(tracks) == "table" then tracks = tracks.tracks end
  if load_type == "track" and type(tracks) == "table" and tracks.encoded then tracks = { tracks } end
  if type(tracks) ~= "table" then return false, "invalid_response" end
  local valid = {}
  for _, track in ipairs(tracks) do
    if type(track) == "table" and type(track.encoded) == "string" and type(track.info) == "table" then
      valid[#valid + 1] = track
      if #valid >= 50 then break end
    end
  end
  if #valid == 0 then return false, "no_results" end
  return true, valid
end

function Client:update_player(guild_id, payload)
  if not self.ready or not self.session_id then return false, "lavalink_unavailable" end
  if type(guild_id) ~= "string" or not guild_id:match("^%d+$") then return false, "invalid_guild" end
  return self:_request("PATCH", "/v4/sessions/" .. self.session_id .. "/players/" .. guild_id, payload or {})
end

function Client:destroy_player(guild_id)
  if not self.ready or not self.session_id then return false, "lavalink_unavailable" end
  return self:_request("DELETE", "/v4/sessions/" .. self.session_id .. "/players/" .. tostring(guild_id))
end

function Client:stop_player(guild_id)
  if not json then return false, "json_unavailable" end
  return self:update_player(guild_id, { track = { encoded = json.null } })
end

-- Compatibility health-only entry point. Playback sessions use start() and
-- update_player() after the Discord voice handshake.
function Client:connect()
  local state = self:health()
  return state.status == "connected", state.detail
end

function Client:disconnect()
  self.stopping = true
  self.last_user_id = nil
  self.ready = false
  if self.retry_timer then require("timer").clearTimeout(self.retry_timer); self.retry_timer = nil end
  if self.write then pcall(self.write, { opcode = 8, payload = "" }) end
  if self.socket and not self.socket:is_closing() then self.socket:close() end
  self.read, self.write, self.socket = nil, nil, nil
  self.stopping = false
  return true, "disconnected"
end

return Client
