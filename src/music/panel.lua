local Permissions = require("src.discord.permissions")
local Personality = require("src.personality")
local Response = require("src.discord.response")
local Embeds = require("src.discord.embeds")
local Panel = {}
Panel.__index = Panel

local ACTIONS = { "pause", "skip", "stop", "replay", "shuffle", "loop", "queue", "disconnect" }
local function valid_id(value) return type(value) == "string" and #value <= 20 and value:match("^%d+$") ~= nil end
local function safe(value, limit)
  return tostring(value or "Unknown"):gsub("@", "@\226\128\139"):gsub("[\r\n]", " "):sub(1, limit or 180)
end

function Panel.new(store, options)
  assert(store, "guild store is required")
  options = options or {}
  return setmetatable({ store = store, bot = options.bot, manager = options.manager,
    cache = {}, last_signature = {}, last_update = {}, clock = options.clock or os.time }, Panel)
end

function Panel:set_bot(bot, manager)
  self.bot, self.manager = bot, manager or self.manager
end

function Panel:_read(guild_id)
  if self.cache[guild_id] then return true, self.cache[guild_id] end
  local ok, result = self.store:run(guild_id, function(data)
    return true, data.music_panel or {}, false
  end)
  if not ok then return false, "persistence_unavailable" end
  self.cache[guild_id] = result
  return true, result
end

function Panel:_save(guild_id, value)
  local ok = self.store:run(guild_id, function(data)
    data.music_panel = value
    return true, true, true
  end)
  if not ok then return false, "persistence_unavailable" end
  self.cache[guild_id] = value
  return true
end

function Panel:_payload(guild_id, state)
  local title, description
  if state and state.current then
    local info = state.current.info
    title = safe(info.title)
    description = safe(info.author)
  else
    title = "Nothing is playing."
    description = Personality.render("music_idle")
  end
  local fields = {}
  if state and state.current then
    fields[#fields + 1] = { name = "Progress", value = string.format("%ds / %ds",
      math.floor((state.position or 0) / 1000), math.floor((state.current.info.length or 0) / 1000)), inline = true }
    fields[#fields + 1] = { name = "Requester", value = safe(state.current.requester), inline = true }
  end
  fields[#fields + 1] = { name = "Queue", value = tostring(state and #state.queue or 0) .. " track(s)", inline = true }
  fields[#fields + 1] = { name = "Volume", value = tostring(state and state.volume or 100) .. "%", inline = true }
  fields[#fields + 1] = { name = "Loop", value = state and state.loop or "off", inline = true }
  fields[#fields + 1] = { name = "Voice", value = state and state.voice_channel_id and ("<#" .. state.voice_channel_id .. ">") or "Not connected", inline = true }
  local info = state and state.current and state.current.info or {}
  local embed = Embeds.create("music", title, description, {
    fields = fields,
    thumbnail = info.artworkUrl,
    url = info.uri,
  })
  local paused = state and state.paused == true
  local labels = { paused and "Resume" or "Pause", "Skip", "Stop", "Replay", "Shuffle",
    "Loop: " .. (state and state.loop or "off"), "Queue", "Disconnect" }
  local components = {
    { type = 1, components = {
      { type = 2, style = 1, label = labels[1], custom_id = "molly_music:pause" },
      { type = 2, style = 2, label = labels[2], custom_id = "molly_music:skip" },
      { type = 2, style = 4, label = labels[3], custom_id = "molly_music:stop" },
      { type = 2, style = 2, label = labels[4], custom_id = "molly_music:replay" },
      { type = 2, style = 2, label = labels[5], custom_id = "molly_music:shuffle" },
    } },
    { type = 1, components = {
      { type = 2, style = 2, label = labels[6], custom_id = "molly_music:loop" },
      { type = 2, style = 2, label = labels[7], custom_id = "molly_music:queue" },
      { type = 2, style = 4, label = labels[8], custom_id = "molly_music:disconnect" },
    } },
  }
  local payload = { content = "Molly's Music Room 🖤", embeds = { embed }, components = components }
  local signature = table.concat({ title, description, tostring(state and state.position and math.floor(state.position / 15000) or 0),
    tostring(state and #state.queue or 0), tostring(state and state.paused), tostring(state and state.volume),
    tostring(state and state.loop), tostring(state and state.voice_channel_id) }, "|")
  return payload, signature
end

function Panel:configure(guild_id, channel_id)
  if not valid_id(guild_id) or not valid_id(channel_id) then return false, "invalid_channel" end
  if not self.bot or not self.bot.rest then return false, "discord_unavailable" end
  local payload = self:_payload(guild_id, self.manager and self.manager:state(guild_id, false))
  local ok, message = pcall(self.bot.rest.send_message, self.bot.rest, channel_id, payload)
  if not ok or type(message) ~= "table" or not valid_id(message.id) then return false, "panel_create_failed" end
  local previous_ok, previous = self:_read(guild_id)
  if not previous_ok then pcall(self.bot.rest.delete_message, self.bot.rest, channel_id, message.id); return false, previous end
  local saved, reason = self:_save(guild_id, { channel_id = channel_id, message_id = message.id })
  if not saved then pcall(self.bot.rest.delete_message, self.bot.rest, channel_id, message.id); return false, reason end
  if previous.channel_id and previous.message_id then
    pcall(self.bot.rest.delete_message, self.bot.rest, previous.channel_id, previous.message_id)
  end
  self.last_signature[guild_id] = nil
  return true, message.id
end

function Panel:disable(guild_id)
  local ok, current = self:_read(guild_id)
  if not ok then return false, current end
  if current.channel_id and current.message_id and self.bot and self.bot.rest then
    pcall(self.bot.rest.edit_message, self.bot.rest, current.channel_id, current.message_id,
      { content = "Molly's music controls are offline for now.", embeds = {}, components = {} })
  end
  return self:_save(guild_id, {})
end

function Panel:refresh(guild_id, state, force)
  if not valid_id(guild_id) or not self.bot or not self.bot.rest then return false end
  local ok, config = self:_read(guild_id)
  if not ok or not valid_id(config.channel_id) or not valid_id(config.message_id) then return false end
  local payload, signature = self:_payload(guild_id, state)
  if not force and self.last_signature[guild_id] == signature then return true end
  local ok_edit, err = pcall(self.bot.rest.edit_message, self.bot.rest, config.channel_id, config.message_id, payload)
  if ok_edit then
    self.last_signature[guild_id], self.last_update[guild_id] = signature, self.clock()
    return true
  end
  local status = type(err) == "table" and err.status_code
  local code = type(err) == "table" and err.code
  if status ~= 404 and code ~= 10008 then return false, "panel_update_failed" end
  local ok_send, message = pcall(self.bot.rest.send_message, self.bot.rest, config.channel_id, payload)
  if not ok_send or type(message) ~= "table" or not valid_id(message.id) then return false, "panel_recreate_failed" end
  local saved = self:_save(guild_id, { channel_id = config.channel_id, message_id = message.id })
  if not saved then return false, "persistence_unavailable" end
  self.last_signature[guild_id] = signature
  return true
end

function Panel:register_interactions(bot, manager)
  self:set_bot(bot.client, manager)
  for _, action_name in ipairs(ACTIONS) do
    bot:interaction("molly_music:" .. action_name, function(ctx)
      ctx._molly_category = "Music"
      ctx._molly_command_name = "music-panel"
      Response.decorate(ctx)
      if not valid_id(ctx.guild_id) then ctx:respond("This control only works in a server.", { ephemeral = true }); return end
      local state = manager:state(ctx.guild_id, false)
      if not state then ctx:update("This music panel is no longer active.", { components = {} }); return end
      local member = ctx.member or {}
      local author = member.user or ctx.user or {}
      local channel_id = author.id and ctx.bot:get_voice_channel_id(ctx.guild_id, author.id)
      local admin = Permissions.has(member.permissions, "manage_guild")
      if not channel_id and admin then channel_id = ctx.bot:get_voice_channel_id(ctx.guild_id, ctx.bot.user and ctx.bot.user.id) end
      if not channel_id or channel_id ~= state.voice_channel_id then
        ctx:respond("Join Molly's voice channel to use these controls.", { ephemeral = true }); return
      end
      if action_name == "queue" then
        local tracks = state.queue
        local lines = {}
        for index = 1, math.min(10, #tracks) do lines[#lines + 1] = tostring(index) .. ". " .. safe(tracks[index].info.title) end
        ctx:respond(#lines > 0 and table.concat(lines, "\n") or "The queue is empty.", { ephemeral = true })
        return
      end
      if not ctx:defer() then return end
      local action, value = action_name
      if action_name == "pause" then action = state.paused and "resume" or "pause"
      elseif action_name == "loop" then value = state.loop == "off" and "track" or (state.loop == "track" and "queue" or "off") end
      local acted = manager:control(ctx.guild_id, channel_id, action, value, { suppress_panel = true })
      local updated = manager:state(ctx.guild_id, false)
      local payload = self:_payload(ctx.guild_id, updated)
      if not acted then payload.content = "Molly couldn't apply that control. The session may have changed." end
      ctx:update(payload.content, { embeds = payload.embeds, components = payload.components })
      if acted then self.last_signature[ctx.guild_id] = select(2, self:_payload(ctx.guild_id, updated)) end
    end)
  end
end

function Panel:recover(guild_id)
  local ok, config = self:_read(guild_id)
  if not ok or not valid_id(config.channel_id) or not valid_id(config.message_id) then return false end
  local fetched = pcall(self.bot.rest.get_message, self.bot.rest, config.channel_id, config.message_id)
  if fetched then return true end
  local state = self.manager and self.manager:state(guild_id, false)
  return self:refresh(guild_id, state, true)
end

return Panel
