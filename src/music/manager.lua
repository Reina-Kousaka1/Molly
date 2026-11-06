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

local function clean_text(value, maximum)
  if type(value) ~= "string" then return nil end
  value = value:gsub("[%z\1-\8\11\12\14-\31\127]", " "):gsub("[\r\n]", " ")
  if #value > maximum then return nil end
  return value
end

local function normalized_track(track, requester)
  if type(track) ~= "table" or type(track.encoded) ~= "string" or #track.encoded < 1 or #track.encoded > 8192
    or type(track.info) ~= "table" then return nil end
  local info = track.info
  local title = clean_text(info.title, 256)
  if not title or title == "" then return nil end
  local author = clean_text(info.author, 256)
  local uri = clean_text(info.uri, 512)
  if uri and not uri:match("^https://") then uri = nil end
  local artwork = clean_text(info.artworkUrl, 512)
  if artwork and not artwork:match("^https://") then artwork = nil end
  local length = type(info.length) == "number" and info.length == info.length
    and info.length >= 0 and info.length <= 43200000 and math.floor(info.length) or 0
  return { encoded = track.encoded, info = { title = title, author = author, uri = uri,
    artworkUrl = artwork, length = length, identifier = clean_text(info.identifier, 256), isStream = info.isStream == true },
    requester = requester }
end

local function compact_voice_state(data)
  local session_id = type(data.session_id) == "string" and #data.session_id <= 256 and data.session_id or nil
  return { guild_id = data.guild_id, user_id = data.user_id,
    channel_id = valid_id(data.channel_id) and data.channel_id or nil, session_id = session_id }
end

local MAX_GUILDS = 500
local MAX_QUEUE = 50
local MAX_TRACKS_PER_REQUEST = 25
local MAX_TRACKS_INSPECTED = 100
local MAX_PENDING_EVENTS = 32

local function queue_pending_voice(state, kind, data)
  state.pending_voice = state.pending_voice or {}
  local pending = state.pending_voice
  for index = #pending, 1, -1 do
    if pending[index].kind == kind then table.remove(pending, index); break end
  end
  if #pending >= MAX_PENDING_EVENTS then return false end
  pending[#pending + 1] = { kind = kind, data = data }
  return true
end

local function requeue_current(self, state)
  if not state.current then return end
  if #state.queue >= MAX_QUEUE then
    table.remove(state.queue)
    if self.logger then pcall(self.logger.warn, self.logger, "music_voice_leave_queue_trimmed", { detail = "queue_limit" }) end
  end
  table.insert(state.queue, 1, state.current)
  state.current = nil
end

local function discard_empty_session(self, guild_id, state, created)
  if created and not state.lock and not state.current and #state.queue == 0
    and not state.voice_channel_id and not state.voice_ready and not state.connecting then
    self.guilds[guild_id] = nil
  end
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
  if not state and create then
    local count = 0; for _ in pairs(self.guilds) do count = count + 1 end
    if count >= MAX_GUILDS then return nil end
    state = new_guild(guild_id)
    self.guilds[guild_id] = state
  end
  return state
end

function Manager:set_discord_client(client, bot_id)
  self.client, self.bot_id = client, bot_id
end

function Manager:start(user_id)
  return self.adapter:start(user_id, function(event) self:on_lavalink_event(event) end)
end

function Manager:on_voice_state(data)
  if type(data) ~= "table" or not valid_id(self.bot_id) or data.user_id ~= self.bot_id
    or not valid_id(data.guild_id) then return false end
  local raw_channel = data.channel_id
  if raw_channel ~= nil and not valid_id(raw_channel) then return false end
  local channel_id = raw_channel
  local session_id = type(data.session_id) == "string" and #data.session_id > 0 and #data.session_id <= 256 and data.session_id or nil
  if channel_id and not session_id then return false end
  local state = self:state(data.guild_id, false)
  if not state then return true, "ignored" end
  if state.lock then
    if not queue_pending_voice(state, "state", compact_voice_state(data)) then
      state.voice_ready, state.connecting = false, false
      return false, "busy"
    end
    return true
  end
  local previous_session = state.voice_state and state.voice_state.session_id
  local restarted = state.voice_channel_id ~= channel_id
    or (previous_session and session_id and previous_session ~= session_id)
  if restarted then
    state.voice_ready, state.connecting, state.voice_server = false, false, nil
    requeue_current(self, state)
  end
  state.voice_state = { session_id = session_id, channel_id = channel_id }
  if not channel_id then
    requeue_current(self, state)
    state.voice_channel_id, state.position = nil, 0
    state.voice_ready, state.connecting, state.paused = false, false, false
    self:_refresh_panel(data.guild_id)
    return true
  end
  state.voice_channel_id = channel_id
  self:_try_voice(data.guild_id, state)
  return true
end

function Manager:on_voice_server(data)
  if type(data) ~= "table" or not valid_id(data.guild_id) then return false end
  if data.endpoint == nil then
    local existing = self:state(data.guild_id, false)
    if not existing then return true end
    if existing.lock then
      if not queue_pending_voice(existing, "server", { guild_id = data.guild_id }) then
        existing.voice_ready, existing.connecting = false, false
        return false, "busy"
      end
    else
      existing.voice_server, existing.voice_ready, existing.connecting = nil, false, false
    end
    return true
  end
  if type(data.token) ~= "string" or #data.token < 1 or #data.token > 512
    or type(data.endpoint) ~= "string" or #data.endpoint < 1 or #data.endpoint > 512 then return false end
  local state = self:state(data.guild_id, false)
  if not state then return true, "ignored" end
  if state.lock then
    if not queue_pending_voice(state, "server",
      { guild_id = data.guild_id, token = data.token, endpoint = data.endpoint }) then
      state.voice_ready, state.connecting = false, false
      return false, "busy"
    end
    return true
  end
  state.voice_server = { token = data.token, endpoint = data.endpoint }
  self:_try_voice(data.guild_id, state)
  return true
end

function Manager:_try_voice(guild_id, state)
  if not state.voice_state or not state.voice_state.session_id or not state.voice_state.channel_id
    or not state.voice_server or state.voice_ready then return false end
  local called, ok = pcall(self.adapter.update_player, self.adapter, guild_id, {
    volume = state.volume * 10,
    voice = { token = state.voice_server.token, endpoint = state.voice_server.endpoint,
      sessionId = state.voice_state.session_id, channelId = state.voice_state.channel_id },
  })
  if not called or not ok then return false end
  state.voice_ready, state.connecting = true, false
  if not state.current and #state.queue > 0 then self:_advance(guild_id, state) end
  self:_refresh_panel(guild_id)
  return true
end

function Manager:_refresh_panel(guild_id)
  if self.panel then pcall(self.panel.refresh, self.panel, guild_id, self:state(guild_id, false)) end
end

local function compact_event(event)
  if type(event) ~= "table" then return nil end
  local result = { type = event.type, op = event.op, guildId = event.guildId,
    reason = event.reason, resumed = event.resumed }
  if type(event.state) == "table" and type(event.state.position) == "number" then
    result.state = { position = math.max(0, math.floor(event.state.position)) }
  end
  if type(event.track) == "table" and type(event.track.encoded) == "string" and #event.track.encoded <= 8192 then
    result.track = { encoded = event.track.encoded }
  end
  return result
end

local function queue_pending_event(state, event)
  state.pending_events = state.pending_events or {}
  if #state.pending_events < MAX_PENDING_EVENTS then
    state.pending_events[#state.pending_events + 1] = event
    return true
  end
  local recovery = state.pending_recovery or { replay = false }
  if event and event.type == "ready" then
    recovery.last, recovery.resumed = "ready", event.resumed == true
  elseif event and event.type == "disconnected" then
    recovery.last = "disconnected"
  else
    recovery.replay = true
  end
  state.pending_recovery = recovery
  return false
end

function Manager:_drain_pending(state, guild_id)
  local turns = 0
  while not state.lock and turns < MAX_PENDING_EVENTS * 2 do
    local voice = table.remove(state.pending_voice or {}, 1)
    if voice then
      if voice.kind == "state" then pcall(self.on_voice_state, self, voice.data)
      else pcall(self.on_voice_server, self, voice.data) end
      turns = turns + 1
    else
      local event = table.remove(state.pending_events or {}, 1)
      if not event then break end
      pcall(self.on_lavalink_event, self, event)
      turns = turns + 1
    end
  end
  local recovery = state.pending_recovery
  if recovery and not state.lock then
    state.pending_recovery = nil
    local replay = recovery.replay or (recovery.last == "ready" and recovery.resumed ~= true)
    if replay then requeue_current(self, state) end
    if recovery.last == "disconnected" then
      state.voice_ready, state.connecting = false, false
    else
      state.voice_ready, state.connecting = false, false
      self:_try_voice(guild_id, state)
    end
    self:_refresh_panel(guild_id)
  end
end

function Manager:_unlock(state, guild_id)
  state.lock = false
  self:_drain_pending(state, guild_id)
end

function Manager:_advance(guild_id, state)
  local next_track = table.remove(state.queue, 1)
  if not next_track then
    local called, stopped, reason = pcall(self.adapter.stop_player, self.adapter, guild_id)
    if called and stopped then
      state.current, state.paused, state.position = nil, false, 0
      self:_refresh_panel(guild_id)
    end
    return called and stopped == true, called and reason or "lavalink_unavailable"
  end
  if not state.voice_ready then table.insert(state.queue, 1, next_track); return false, "voice_unavailable" end
  local called, ok = pcall(self.adapter.update_player, self.adapter, guild_id, {
    track = { encoded = next_track.encoded, userData = { requester = next_track.requester } },
    paused = false, volume = state.volume * 10,
    voice = { token = state.voice_server.token, endpoint = state.voice_server.endpoint,
      sessionId = state.voice_state.session_id, channelId = state.voice_state.channel_id },
  })
  if not called or not ok then table.insert(state.queue, 1, next_track); return false, "lavalink_unavailable" end
  state.current, state.paused, state.position = next_track, false, 0
  self:_refresh_panel(guild_id)
  return true, next_track
end

function Manager:play(guild_id, channel_id, query, requester_id)
  if not valid_id(guild_id) or not valid_id(channel_id) or not valid_id(requester_id) then return false, "invalid_argument" end
  if type(query) ~= "string" or #query > 500 or not query:match("%S") then return false, "invalid_query" end
  local state = self:state(guild_id, false)
  local created = state == nil
  if not state then state = self:state(guild_id, true) end
  if not state then return false, "capacity" end
  if state.lock then return false, "busy" end
  state.lock = true
  local resolved_call, ok, tracks = pcall(self.adapter.resolve, self.adapter, query)
  if not resolved_call or not ok or type(tracks) ~= "table" or #tracks == 0 then
    self:_unlock(state, guild_id)
    discard_empty_session(self, guild_id, state, created)
    return false, resolved_call and (type(tracks) == "string" and tracks or "no_results") or "lavalink_unavailable"
  end
  if state.voice_channel_id and state.voice_channel_id ~= channel_id then
    self:_unlock(state, guild_id)
    discard_empty_session(self, guild_id, state, created)
    return false, "different_voice_channel"
  end
  local available = MAX_QUEUE - #state.queue
  if available <= 0 then
    local reconnecting = false
    if not state.voice_ready and not state.connecting and self.client
      and type(self.client.voice_state_update) == "function" then
      local previous_channel = state.voice_channel_id
      state.voice_channel_id = channel_id
      local join_ok, join_result = pcall(self.client.voice_state_update, self.client, guild_id, channel_id, false, false)
      if join_ok and join_result ~= false then state.connecting, reconnecting = true, true
      else state.voice_channel_id = previous_channel end
    end
    self:_unlock(state, guild_id)
    if reconnecting then
      self:_refresh_panel(guild_id)
      return false, "queue_full_reconnecting"
    end
    return false, "queue_full"
  end
  local queue_position, added, first_track = #state.queue + 1, 0, nil
  local limit, inspected = math.min(available, MAX_TRACKS_PER_REQUEST), 0
  for _, source_track in ipairs(tracks) do
    inspected = inspected + 1
    if added >= limit or inspected > MAX_TRACKS_INSPECTED then break end
    local track = normalized_track(source_track, requester_id)
    if track then
      state.queue[#state.queue + 1] = track
      first_track = first_track or track
      added = added + 1
    end
  end
  if added == 0 then
    self:_unlock(state, guild_id)
    discard_empty_session(self, guild_id, state, created)
    return false, "no_results"
  end
  local previous_channel = state.voice_channel_id
  state.voice_channel_id = channel_id
  local started = false
  if not state.voice_ready then
    if not state.connecting then
      if not self.client or type(self.client.voice_state_update) ~= "function" then
        for _ = 1, added do table.remove(state.queue) end
        state.voice_channel_id = previous_channel
        self:_unlock(state, guild_id)
        discard_empty_session(self, guild_id, state, created)
        return false, "voice_unavailable"
      end
      local join_ok, join_result = pcall(self.client.voice_state_update, self.client, guild_id, channel_id, false, false)
      if not join_ok or join_result == false then
        for _ = 1, added do table.remove(state.queue) end
        state.voice_channel_id = previous_channel
        self:_unlock(state, guild_id)
        discard_empty_session(self, guild_id, state, created)
        return false, "voice_unavailable"
      end
      state.connecting = true
    end
  elseif not state.current then
    started = self:_advance(guild_id, state)
  end
  self:_unlock(state, guild_id)
  self:_refresh_panel(guild_id)
  return true, { count = added, title = first_track.info.title, info = first_track.info,
    requester = requester_id, queue_position = queue_position, omitted_count = math.max(0, #tracks - added),
    started = started == true, connecting = state.connecting }
end

function Manager:on_lavalink_event(event)
  if type(event) ~= "table" then return false end
  if event.type == "ready" then
    for guild_id, session in pairs(self.guilds) do
      if session.lock then
        queue_pending_event(session, compact_event(event))
      elseif session.voice_state and session.voice_server then
        if event.resumed ~= true then requeue_current(self, session) end
        session.voice_ready = false
        self:_try_voice(guild_id, session)
      end
    end
    return true
  end
  if event.type == "disconnected" then
    for _, session in pairs(self.guilds) do
      if session.lock then
        queue_pending_event(session, compact_event(event))
      else
        session.voice_ready = false
      end
    end
    return true
  end
  if not valid_id(event.guildId) then return false end
  local state = self:state(event.guildId, false)
  if not state then return false end
  if state.lock then
    if not queue_pending_event(state, compact_event(event)) then return false, "busy" end
    return true
  end
  if event.op == "playerUpdate" and type(event.state) == "table" and type(event.state.position) == "number" then
    state.position = math.max(0, math.floor(event.state.position))
  elseif event.type == "TrackStartEvent" then
    if type(event.track) == "table" and type(event.track.info) == "table" then state.position = 0 end
  elseif event.type == "TrackEndEvent" then
    if state.current and event.track and event.track.encoded and state.current.encoded ~= event.track.encoded then return true end
    if state.loop == "track" and state.current and event.reason == "finished" then
      local called, restarted = pcall(self.adapter.update_player, self.adapter, event.guildId,
        { track = { encoded = state.current.encoded }, paused = false })
      if called and restarted then state.position = 0 end
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

Manager.max_guilds = MAX_GUILDS
Manager.max_queue = MAX_QUEUE
Manager.max_tracks_per_request = MAX_TRACKS_PER_REQUEST
Manager.max_pending_events = MAX_PENDING_EVENTS
return Manager
