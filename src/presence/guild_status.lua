-- Guild-local status messages; this never writes the bot's global presence.
local Store = require('src.persistence.guild_store')
local statuses = require('src.modes.sephora_statuses')
local GuildStatus = {}
GuildStatus.__index = GuildStatus
GuildStatus.default_interval_ms = 120000
local default_status = 'On duty for the community 🛡️'

local function valid_panel(panel)
  if type(panel) ~= 'table' then return false end
  return (panel.channel_id == nil and panel.message_id == nil)
    or (Store.valid_id(panel.channel_id) and Store.valid_id(panel.message_id))
end
local function payload(text)
  return { content = '**Molly · Server status**\n' .. text, allowed_mentions = { parse = {} } }
end
function GuildStatus.new(options)
  assert(options and options.store and options.modes and options.schedule and options.cancel, 'status dependencies required')
  local interval = options.interval_ms or GuildStatus.default_interval_ms
  assert(type(interval) == 'number' and interval >= 60000 and interval <= 86400000, 'invalid status interval')
  return setmetatable({ store = options.store, modes = options.modes, schedule = options.schedule,
    cancel = options.cancel, interval_ms = interval, random = options.random or math.random,
    spawn = options.spawn or function(task) coroutine.wrap(task)() end, logger = options.logger,
    guilds = {}, busy = {}, pending = {}, recover_pending = {}, running = false }, GuildStatus)
end
function GuildStatus:set_client(client) self.client = client end
function GuildStatus:_load(guild)
  return self.store:run(guild, function(data)
    local panel = data.guild_status or {}
    if not valid_panel(panel) then return false, 'invalid_store' end
    return true, { channel_id = panel.channel_id, message_id = panel.message_id }, false
  end)
end
function GuildStatus:_save(guild, panel)
  return self.store:run(guild, function(data)
    data.guild_status = { channel_id = panel.channel_id, message_id = panel.message_id }
    return true, true, true
  end)
end
function GuildStatus:_next(state)
  if state.bag and #state.bag == 1 and state.bag[1] == state.last then state.bag = nil end
  if not state.bag or #state.bag == 0 then
    local bag = {}
    for i = 1, #statuses do bag[i] = i end
    for i = #bag, 2, -1 do
      local j = self.random(i)
      if type(j) ~= 'number' or j % 1 ~= 0 or j < 1 or j > i then return nil end
      bag[i], bag[j] = bag[j], bag[i]
    end
    if state.last and #bag > 1 and bag[#bag] == state.last then
      bag[#bag], bag[#bag - 1] = bag[#bag - 1], bag[#bag]
    end
    state.bag = bag
  end
  if state.last and #state.bag > 1 and state.bag[#state.bag] == state.last then
    state.bag[#state.bag], state.bag[#state.bag - 1] = state.bag[#state.bag - 1], state.bag[#state.bag]
  end
  local index = table.remove(state.bag)
  return statuses[index], index
end
function GuildStatus:_run(guild, fn)
  if not Store.valid_id(guild) then return false, 'invalid_guild' end
  if self.busy[guild] then return false, 'busy' end
  self.busy[guild] = true
  local ok, result, reason = pcall(fn)
  self.busy[guild] = nil
  local pending = self.pending[guild]
  self.pending[guild] = nil
  if pending then self.spawn(function() self:apply(guild, pending.channel, pending.mode) end) end
  if not ok then return false, 'status_unavailable' end
  return result, reason
end
function GuildStatus:_show(guild, panel, state, channel)
  local rest = self.client and self.client.rest
  if not rest or type(rest.get_channel) ~= 'function' or type(rest.send_message) ~= 'function'
    or type(rest.edit_message) ~= 'function' then return false, 'discord_unavailable' end
  local text, index
  if state.mode == 'sephora' then text, index = self:_next(state) else text = default_status end
  if not text then return false, 'status_unavailable' end
  if panel.message_id then
    local edited, result = pcall(rest.edit_message, rest, panel.channel_id, panel.message_id, payload(text))
    if not edited or type(result) ~= 'table' then return false, 'status_update_failed' end
  else
    if state.mode ~= 'sephora' then return true end
    if not Store.valid_id(channel) then return false, 'status_channel_missing' end
    local fetched, target = pcall(rest.get_channel, rest, channel)
    if not fetched or type(target) ~= 'table' or target.guild_id ~= guild or (target.type ~= 0 and target.type ~= 5) then
      return false, 'status_channel_unavailable'
    end
    local sent, message = pcall(rest.send_message, rest, channel, payload(text))
    if not sent or type(message) ~= 'table' or not Store.valid_id(message.id) then return false, 'status_create_failed' end
    local saved, reason = self:_save(guild, { channel_id = channel, message_id = message.id })
    if not saved then return false, reason or 'persistence_unavailable' end
    panel = { channel_id = channel, message_id = message.id }
  end
  state.panel = panel
  if index then state.last = index end
  self.guilds[guild] = state
  return true
end
function GuildStatus:apply(guild, channel, mode)
  if self.busy[guild] then
    if mode ~= 'standard' and mode ~= 'sephora' then return false, 'invalid_mode' end
    self.pending[guild] = { channel = channel, mode = mode }
    if self.guilds[guild] then self.guilds[guild].mode = mode end
    return false, 'busy'
  end
  return self:_run(guild, function()
    if mode ~= 'standard' and mode ~= 'sephora' then return false, 'invalid_mode' end
    local ok, panel = self:_load(guild)
    if not ok then return false, 'persistence_unavailable' end
    local state = self.guilds[guild] or {}
    state.mode = mode
    local shown, reason = self:_show(guild, panel, state, channel)
    if not shown then return false, reason end
    return true
  end)
end
function GuildStatus:recover(guild)
  local ok, reason = self:_run(guild, function()
    local ok, mode = self.modes:get(guild)
    if not ok then return false, 'mode_unavailable' end
    local loaded, panel = self:_load(guild)
    if not loaded then return false, 'persistence_unavailable' end
    if not panel.message_id then return true end
    local state = self.guilds[guild] or {}
    state.mode = mode.id
    return self:_show(guild, panel, state)
  end)
  if Store.valid_id(guild) then self.recover_pending[guild] = not ok or nil end
  return ok, reason
end
function GuildStatus:forget(guild) self.guilds[guild], self.pending[guild], self.recover_pending[guild] = nil, nil, nil end
function GuildStatus:tick()
  if not self.running then return false end
  local recovering = {}
  for guild in pairs(self.recover_pending) do
    local guild_id = guild
    recovering[guild_id] = true
    self.spawn(function() self:recover(guild_id) end)
  end
  for guild, state in pairs(self.guilds) do
    if not recovering[guild] and state.mode == 'sephora' and state.panel and state.panel.message_id then
      local guild_id, current = guild, state
      self.spawn(function()
        local ok = self:_run(guild_id, function() return self:_show(guild_id, current.panel, current) end)
        if not ok and self.logger then self.logger:warn('guild_status_update_failed', { detail = 'status_unavailable' }) end
      end)
    end
  end
  return true
end
function GuildStatus:start()
  if self.running then return false end
  self.running = true
  local ok, handle = pcall(self.schedule, self.interval_ms, function() self:tick() end)
  if not ok or not handle then self.running = false; return false end
  self.handle = handle
  return true
end
function GuildStatus:stop()
  if not self.running then return false end
  self.running = false
  if self.handle then pcall(self.cancel, self.handle); self.handle = nil end
  return true
end
GuildStatus.statuses = statuses
GuildStatus.default_status = default_status
return GuildStatus
