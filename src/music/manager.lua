local Manager = {}
Manager.__index = Manager

local function new_guild(id)
  return { guild_id = id, queue = {}, current = nil, paused = false, volume = 100,
    loop = "off", voice_channel_id = nil, voice_state = nil, voice_server = nil,
    voice_ready = false, connecting = false, lock = false, position = 0 }
end

local function valid_id(value)
  return type(value) == "string" and #value >= 1 and #value <= 20 and value:match("^%d+$") ~= nil
end

function Manager.new(adapter, options)
  assert(adapter, "music adapter is required")
  options = options or {}
  return setmetatable({ adapter = adapter, guilds = {}, client = nil, bot_id = nil,
    panel = options.panel, logger = options.logger }, Manager)
end

function Manager:state(guild_id, create)
  if not valid_id(guild_id) then return nil end
  local state = self.guilds[guild_id]
  if not state and create then state = new_guild(guild_id); self.guilds[guild_id] = state end
  return state
end

function Manager:set_discord_client(client, bot_id)
  self.client, self.bot_id = client, bot_id
end

function Manager:start(user_id)
  return self.adapter:start(user_id, function(event) self:on_lavalink_event(event) end)
end

function Manager:on_voice_state(data)
  if type(data) ~= "table" or data.user_id ~= self.bot_id or not valid_id(data.guild_id) then return false end
  local state = self:state(data.guild_id, true)
  if state.lock then
    state.pending_voice = state.pending_voice or {}
    state.pending_voice[#state.pending_voice + 1] = { kind = "state", data = data }
    return true
  end
  local channel_id = type(data.channel_id) == "string" and data.channel_id or nil
  if state.voice_channel_id ~= channel_id then
    state.voice_ready = false
    state.voice_server = nil
  end
  state.voice_state = { session_id = data.session_id, channel_id = channel_id }
  if not channel_id then state.voice_ready, state.connecting = false, false; return true end
  state.voice_channel_id = channel_id
  self:_try_voice(data.guild_id, state)
  return true
end

function Manager:on_voice_server(data)
  if type(data) ~= "table" or not valid_id(data.guild_id) then return false end
  local state = self:state(data.guild_id, true)
  if state.lock then
    state.pending_voice = state.pending_voice or {}
    state.pending_voice[#state.pending_voice + 1] = { kind = "server", data = data }
    return true
  end
  if type(data.token) ~= "string" or type(data.endpoint) ~= "string" then return false end
  state.voice_server = { token = data.token, endpoint = data.endpoint }
  self:_try_voice(data.guild_id, state)
  return true
end

function Manager:_try_voice(guild_id, state)
  if not state.voice_state or not state.voice_state.session_id or not state.voice_state.channel_id
    or not state.voice_server or state.voice_ready then return false end
  local ok = self.adapter:update_player(guild_id, {
    volume = state.volume * 10,
    voice = { token = state.voice_server.token, endpoint = state.voice_server.endpoint,
      sessionId = state.voice_state.session_id, channelId = state.voice_state.channel_id },
  })
  if not ok then return false end
  state.voice_ready, state.connecting = true, false
  if not state.current and #state.queue > 0 then self:_advance(guild_id, state) end
  self:_refresh_panel(guild_id)
  return true
end

function Manager:_refresh_panel(guild_id)
  if self.panel then pcall(self.panel.refresh, self.panel, guild_id, self:state(guild_id, false)) end
end

function Manager:_unlock(state, guild_id)
  state.lock = false
  local voice = table.remove(state.pending_voice or {}, 1)
  if voice then
    if voice.kind == "state" then self:on_voice_state(voice.data) else self:on_voice_server(voice.data) end
    return
  end
  local event = table.remove(state.pending_events or {}, 1)
  if event then self:on_lavalink_event(event) end
end

function Manager:_advance(guild_id, state)
  local next_track = table.remove(state.queue, 1)
  if not next_track then
    local stopped, reason = self.adapter:stop_player(guild_id)
    if stopped then
      state.current, state.paused, state.position = nil, false, 0
      self:_refresh_panel(guild_id)
    end
    return stopped == true, reason
  end
  if not state.voice_ready then table.insert(state.queue, 1, next_track); return false, "voice_unavailable" end
  local ok = self.adapter:update_player(guild_id, {
    track = { encoded = next_track.encoded, userData = { requester = next_track.requester } },
    paused = false, volume = state.volume * 10,
    voice = { token = state.voice_server.token, endpoint = state.voice_server.endpoint,
      sessionId = state.voice_state.session_id, channelId = state.voice_state.channel_id },
  })
  if not ok then table.insert(state.queue, 1, next_track); return false, "lavalink_unavailable" end
  state.current, state.paused, state.position = next_track, false, 0
  self:_refresh_panel(guild_id)
  return true, next_track
end

function Manager:play(guild_id, channel_id, query, requester_id)
  if not valid_id(guild_id) or not valid_id(channel_id) or not valid_id(requester_id) then return false, "invalid_argument" end
  local state = self:state(guild_id, true)
  if state.lock then return false, "busy" end
  state.lock = true
  local ok, tracks = self.adapter:resolve(query)
  if not ok or type(tracks) ~= "table" or #tracks == 0 then self:_unlock(state, guild_id); return false, tracks or "no_results" end
  if state.voice_channel_id and state.voice_channel_id ~= channel_id then self:_unlock(state, guild_id); return false, "different_voice_channel" end
  state.voice_channel_id = channel_id
  local queue_position = #state.queue + 1
  local added = 0
  for _, track in ipairs(tracks) do
    if type(track.encoded) == "string" and type(track.info) == "table" then
      state.queue[#state.queue + 1] = { encoded = track.encoded, info = track.info, requester = requester_id }
      added = added + 1
    end
  end
  local started = false
  if not state.voice_ready then
    if not state.connecting then
      if not self.client or type(self.client.voice_state_update) ~= "function" then
        for _ = 1, added do table.remove(state.queue) end
        self:_unlock(state, guild_id)
        return false, "voice_unavailable"
      end
      local join_ok = pcall(self.client.voice_state_update, self.client, guild_id, channel_id, false, false)
      if not join_ok then
        for _ = 1, added do table.remove(state.queue) end
        self:_unlock(state, guild_id)
        return false, "voice_unavailable"
      end
      state.connecting = true
    end
  elseif not state.current then
    started = self:_advance(guild_id, state)
  end
  self:_unlock(state, guild_id)
  self:_refresh_panel(guild_id)
  return true, { count = added, title = tracks[1].info.title or "Unknown track", info = tracks[1].info,
    requester = requester_id, queue_position = queue_position, started = started == true, connecting = state.connecting }
end

function Manager:on_lavalink_event(event)
  if type(event) ~= "table" then return false end
  if event.type == "ready" then
    for guild_id, session in pairs(self.guilds) do
      if session.voice_state and session.voice_server then
        if event.resumed ~= true and session.current then
          table.insert(session.queue, 1, session.current)
          session.current = nil
        end
        session.voice_ready = false
        self:_try_voice(guild_id, session)
      end
    end
    return true
  end
  if event.type == "disconnected" then
    for _, session in pairs(self.guilds) do session.voice_ready = false end
    return true
  end
  if not valid_id(event.guildId) then return false end
  local state = self:state(event.guildId, false)
  if not state then return false end
  if state.lock then
    state.pending_events = state.pending_events or {}
    state.pending_events[#state.pending_events + 1] = event
    return true
  end
  if event.op == "playerUpdate" and type(event.state) == "table" and type(event.state.position) == "number" then
    state.position = math.max(0, math.floor(event.state.position))
  elseif event.type == "TrackStartEvent" then
    if type(event.track) == "table" and type(event.track.info) == "table" then state.position = 0 end
  elseif event.type == "TrackEndEvent" then
    if state.current and event.track and event.track.encoded and state.current.encoded ~= event.track.encoded then return true end
    if state.loop == "track" and state.current and event.reason == "finished" then
      state.position = 0
      self.adapter:update_player(event.guildId, { track = { encoded = state.current.encoded }, paused = false })
    else
      if state.loop == "queue" and state.current and event.reason == "finished" then
        state.queue[#state.queue + 1] = state.current
      end
      state.current = nil
      self:_advance(event.guildId, state)
    end
  elseif event.type == "TrackExceptionEvent" or event.type == "TrackStuckEvent" then
    if state.current and event.track and event.track.encoded and state.current.encoded ~= event.track.encoded then return true end
    state.current = nil
    self:_advance(event.guildId, state)
  elseif event.type == "WebSocketClosedEvent" then
    state.voice_ready = false
  end
  self:_refresh_panel(event.guildId)
  return true
end

local function voice_allowed(state, channel_id)
  return state and state.voice_ready and state.voice_channel_id == channel_id
end

function Manager:_control(guild_id, channel_id, action, value, options)
  options = options or {}
  local state = self:state(guild_id, false)
  if not voice_allowed(state, channel_id) then return false, "not_in_session_voice" end
  local payload = {}
  local after_success
  if action == "pause" then payload.paused = true; after_success = function() state.paused = true end
  elseif action == "resume" then payload.paused = false; after_success = function() state.paused = false end
  elseif action == "seek" then
    if not state.current or type(value) ~= "number" or value < 0 or value > (state.current.info.length or 0) then return false, "invalid_position" end
    payload.position = math.floor(value); after_success = function() state.position = payload.position end
  elseif action == "volume" then
    if type(value) ~= "number" or value < 0 or value > 100 or value % 1 ~= 0 then return false, "invalid_volume" end
    payload.volume = value * 10; after_success = function() state.volume = value end
  elseif action == "skip" then
    local ok, reason = self:_advance(guild_id, state)
    if not ok then return false, reason end
  elseif action == "replay" then
    if not state.current then return false, "nothing_playing" end
    payload.track = { encoded = state.current.encoded }; payload.position = 0; after_success = function() state.position = 0 end
  elseif action == "stop" then
    local ok = self.adapter:stop_player(guild_id)
    if not ok then return false, "lavalink_unavailable" end
    state.queue, state.current, state.paused, state.position = {}, nil, false, 0
  elseif action == "shuffle" then
    for index = #state.queue, 2, -1 do local other = math.random(index); state.queue[index], state.queue[other] = state.queue[other], state.queue[index] end
  elseif action == "loop" then
    if value ~= "off" and value ~= "track" and value ~= "queue" then return false, "invalid_loop" end
    state.loop = value
  elseif action == "remove" then
    if type(value) ~= "number" or value % 1 ~= 0 or value < 1 or value > #state.queue then return false, "invalid_position" end
    table.remove(state.queue, value)
  elseif action == "move" then
    local from, to = value and value.from, value and value.to
    if type(from) ~= "number" or type(to) ~= "number" or from % 1 ~= 0 or to % 1 ~= 0 or from < 1 or from > #state.queue or to < 1 or to > #state.queue then return false, "invalid_position" end
    local track = table.remove(state.queue, from); table.insert(state.queue, to, track)
  elseif action == "clear" then
    state.queue = {}
  elseif action == "disconnect" then
    local destroyed = self.adapter:destroy_player(guild_id)
    if not destroyed then return false, "lavalink_unavailable" end
    if self.client then
      local left, result = pcall(self.client.voice_state_update, self.client, guild_id, nil, false, false)
      if not left or result == false then return false, "voice_unavailable" end
    end
    self.guilds[guild_id] = nil
    self:_refresh_panel(guild_id)
    return true
  else return false, "unsupported_action" end
  if next(payload) then
    local ok = self.adapter:update_player(guild_id, payload)
    if not ok then return false, "lavalink_unavailable" end
  end
  if after_success then after_success() end
  if not options.suppress_panel then self:_refresh_panel(guild_id) end
  return true
end

function Manager:control(guild_id, channel_id, action, value, options)
  local state = self:state(guild_id, false)
  if not voice_allowed(state, channel_id) then return false, "not_in_session_voice" end
  if state.lock then return false, "busy" end
  state.lock = true
  local ok, success, detail = pcall(self._control, self, guild_id, channel_id, action, value, options)
  self:_unlock(state, guild_id)
  if not ok then return false, "lavalink_unavailable" end
  return success, detail
end

function Manager:cleanup_guild(guild_id, channel_id)
  local state = self:state(guild_id, false)
  if not state or (channel_id and state.voice_channel_id ~= channel_id) then return true end
  pcall(self.adapter.destroy_player, self.adapter, guild_id)
  if self.client then pcall(self.client.voice_state_update, self.client, guild_id, nil, false, false) end
  self.guilds[guild_id] = nil
  self:_refresh_panel(guild_id)
  return true
end

function Manager:queue(guild_id)
  local state = self:state(guild_id, false)
  return state and state.queue or {}, state
end

return Manager
