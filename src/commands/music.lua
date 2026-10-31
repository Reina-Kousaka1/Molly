local Response = require("src.discord.response")
local Permissions = require("src.discord.permissions")
local Personality = require("src.personality")

local Commands = {}
local function safe(value)
  return tostring(value or "unknown"):gsub("@", "@\226\128\139"):gsub("[\r\n]", " "):sub(1, 120)
end
local function duration(milliseconds)
  if type(milliseconds) ~= "number" or milliseconds <= 0 then return "Unknown duration" end
  local seconds = math.floor(milliseconds / 1000)
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end
local function field(name, value, inline)
  if value == nil or value == "" then return nil end
  return { name = name, value = safe(value), inline = inline == true }
end
local function add_field(fields, name, value, inline)
  local item = field(name, value, inline)
  if item then fields[#fields + 1] = item end
end
local function option(name, description, kind, required, extra)
  local result = { name = name, description = description, type = kind, required = required }
  for key, value in pairs(extra or {}) do result[key] = value end
  return result
end

local function channel_for(ctx)
  if not ctx.guild or not ctx.author or not ctx.bot or type(ctx.bot.get_voice_channel_id) ~= "function" then
    return nil, "This command needs a server voice channel."
  end
  local guild_id = ctx.guild.id
  local selected = ctx.bot:get_voice_channel_id(guild_id, ctx.author.id)
  local admin = Permissions.has(ctx.member and ctx.member.permissions, "manage_guild")
  local bot_user = ctx.bot.user
  local bot_channel = bot_user and ctx.bot:get_voice_channel_id(guild_id, bot_user.id)
  if not selected and admin then selected = bot_channel end
  if not selected then return nil, "Join a voice channel first." end
  if bot_channel and bot_channel ~= selected then return nil, "Molly is already in a different voice channel." end
  return selected
end

function Commands.register(router, manager)
  local function register(name, description, args, action)
    router:register({ name = name, description = description, category = "Music", options = args,
      execute = function(ctx)
        if not ctx.guild then ctx:respond("Music commands only work in a server.", { ephemeral = true }); return end
        if not Response.defer(ctx) then return end
        local ok, message = pcall(function()
          local channel_id, reason = channel_for(ctx)
          if not channel_id and name ~= "play" and name ~= "queue" and name ~= "nowplaying" then return reason end
          local success, result = action(ctx, channel_id)
          if not success then
            if result == "not_in_session_voice" or result == "different_voice_channel" then return "Join Molly's voice channel to control this session." end
            if result == "no_results" then return "I couldn't find a playable track. Check the query or URL." end
            if result == "invalid_query" then return "Enter a search term or a supported audio URL." end
            if result == "lavalink_unavailable" or result == "not_configured" or result == "request_failed" then return "Music is unavailable right now; Lavalink is not connected." end
            if result == "voice_unavailable" then return "I couldn't join that voice channel. Check my Connect and Speak permissions." end
            if result == "Join a voice channel first." or result == "This command needs a server voice channel." then return result end
            return "Music action failed: " .. safe(result)
          end
          if type(result) == "table" and result.__molly_embed then
            Response.set_embed(ctx, result)
            return result.description or " "
          end
          return type(result) == "string" and result or "Done. Try not to look too pleased. ✨"
        end)
        ctx:edit(ok and message or "Music action failed. Please try again.")
      end,
    })
  end

  register("play", "Play a URL or search for music", {
    option("query", "YouTube search, spsearch: for Spotify, or a supported audio URL", 3, true, { min_length = 1, max_length = 500 }),
  }, function(ctx)
    local channel_id, reason = channel_for(ctx)
    if not channel_id then return false, reason end
    local ok, result = manager:play(ctx.guild.id, channel_id, ctx:get_arg("query"), ctx.author.id)
    if not ok then return false, result end
    local info = result.info or {}
    local title = safe(info.title or result.title)
    local description
    if result.connecting then description = "Connecting to your voice channel; **" .. title .. "** is queued. 🖤"
    elseif result.started then description = Personality.render("music_playing", { title = title })
    else description = Personality.render("music_added", { title = title }) end
    local fields = {}
    add_field(fields, "Artist", info.author, true)
    add_field(fields, "Duration", duration(info.length), true)
    add_field(fields, "Requester ID", ctx.author.id, true)
    add_field(fields, "Queue position", tostring(result.queue_position), true)
    return true, { __molly_embed = true, kind = "music", title = result.count > 1 and "Tracks Queued" or title,
      description = description, fields = fields, thumbnail = info.artworkUrl, url = info.uri }
  end)

  register("pause", "Pause the current track", nil, function(ctx, channel)
    local ok, reason = manager:control(ctx.guild.id, channel, "pause")
    return ok, ok and "Playback paused. The silence is yours for a moment. 🌙" or reason
  end)
  register("resume", "Resume the current track", nil, function(ctx, channel)
    local ok, reason = manager:control(ctx.guild.id, channel, "resume")
    return ok, ok and "Playback resumed. There we are. 🎶" or reason
  end)
  register("skip", "Skip the current track", nil, function(ctx, channel)
    local ok, reason = manager:control(ctx.guild.id, channel, "skip")
    return ok, ok and "Skipped. Let's see if the next one has better taste. 🖤" or reason
  end)
  register("stop", "Stop playback and clear the queue", nil, function(ctx, channel)
    local ok, reason = manager:control(ctx.guild.id, channel, "stop")
    return ok, ok and "Playback stopped and the queue cleared." or reason
  end)
  register("disconnect", "Disconnect Molly from voice", nil, function(ctx, channel)
    local ok, reason = manager:control(ctx.guild.id, channel, "disconnect")
    return ok, ok and "Disconnected. Try not to miss me too much. 🖤" or reason
  end)
  register("replay", "Replay the current track", nil, function(ctx, channel)
    local ok, reason = manager:control(ctx.guild.id, channel, "replay")
    return ok, ok and "Starting that one again. It was clearly worth a second listen. 🎧" or reason
  end)
  register("shuffle", "Shuffle the queued tracks", nil, function(ctx, channel)
    local ok, reason = manager:control(ctx.guild.id, channel, "shuffle")
    return ok, ok and "Queue shuffled. A little chaos improves everything. ✨" or reason
  end)
  register("clear", "Clear the queued tracks", nil, function(ctx, channel)
    local ok, reason = manager:control(ctx.guild.id, channel, "clear")
    return ok, ok and "The queue is clear." or reason
  end)
  register("queue", "Show the current track and queue", nil, function(ctx)
    local tracks, state = manager:queue(ctx.guild.id)
    if not state then return true, Personality.render("music_idle") end
    local lines = {}
    for index = 1, math.min(10, #tracks) do
      local info = tracks[index].info
      lines[#lines + 1] = tostring(index) .. ". " .. safe(info.title) ..
        (info.author and (" — " .. safe(info.author)) or "") .. " · requester ID " .. safe(tracks[index].requester)
    end
    if #tracks > 10 then lines[#lines + 1] = "…and " .. tostring(#tracks - 10) .. " more." end
    if #lines == 0 then return true, Personality.render("music_idle") end
    local fields = {}
    add_field(fields, "Now playing", state.current and safe(state.current.info.title) or "Nothing playing", true)
    add_field(fields, "Queue length", tostring(#tracks), true)
    add_field(fields, "Volume", tostring(state.volume) .. "%", true)
    add_field(fields, "Loop", state.loop, true)
    add_field(fields, "Voice channel", state.voice_channel_id and ("<#" .. state.voice_channel_id .. ">") or "Not connected", true)
    return true, { __molly_embed = true, kind = "music", title = "Music Queue", description = table.concat(lines, "\n"), fields = fields }
  end)
  register("nowplaying", "Show the current track", nil, function(ctx)
    local _, state = manager:queue(ctx.guild.id)
    if not state or not state.current then return true, Personality.render("music_idle") end
    local info = state.current.info
    local fields = {}
    add_field(fields, "Artist", info.author, true)
    add_field(fields, "Duration", duration(info.length), true)
    add_field(fields, "Progress", tostring(math.floor((state.position or 0) / 1000)) .. "s / " .. duration(info.length), true)
    add_field(fields, "Requester ID", state.current.requester, true)
    add_field(fields, "Volume", tostring(state.volume) .. "%", true)
    add_field(fields, "Loop", state.loop, true)
    add_field(fields, "Voice channel", state.voice_channel_id and ("<#" .. state.voice_channel_id .. ">") or "Not connected", true)
    return true, { __molly_embed = true, kind = "music", title = safe(info.title),
      description = Personality.render("music_playing", { title = safe(info.title) }), fields = fields,
      thumbnail = info.artworkUrl, url = info.uri }
  end)
  register("seek", "Seek to a position in the current track", {
    option("seconds", "Position in seconds", 4, true, { min_value = 0, max_value = 86400 }),
  }, function(ctx, channel)
    local ok, reason = manager:control(ctx.guild.id, channel, "seek", ctx:get_arg("seconds") * 1000)
    return ok, ok and "Moved to " .. tostring(ctx:get_arg("seconds")) .. " seconds." or reason
  end)
  register("volume", "Set playback volume from 0 to 100 percent", {
    option("percent", "Volume percentage", 4, true, { min_value = 0, max_value = 100 }),
  }, function(ctx, channel)
    local value = ctx:get_arg("percent")
    local ok, reason = manager:control(ctx.guild.id, channel, "volume", value)
    return ok, ok and "Volume set to " .. tostring(value) .. "%." or reason
  end)
  register("loop", "Set the loop mode", {
    option("mode", "Loop mode", 3, true, { choices = {
      { name = "Off", value = "off" }, { name = "Track", value = "track" }, { name = "Queue", value = "queue" },
    } }),
  }, function(ctx, channel)
    local value = ctx:get_arg("mode")
    local ok, reason = manager:control(ctx.guild.id, channel, "loop", value)
    return ok, ok and "Loop mode: " .. value .. "." or reason
  end)
  register("remove", "Remove a queued track by position", {
    option("position", "Queue position", 4, true, { min_value = 1, max_value = 50 }),
  }, function(ctx, channel)
    local ok, reason = manager:control(ctx.guild.id, channel, "remove", ctx:get_arg("position"))
    return ok, ok and "Removed queue item " .. tostring(ctx:get_arg("position")) .. "." or reason
  end)
  register("move", "Move a queued track", {
    option("from", "Current queue position", 4, true, { min_value = 1, max_value = 50 }),
    option("to", "New queue position", 4, true, { min_value = 1, max_value = 50 }),
  }, function(ctx, channel)
    local ok, reason = manager:control(ctx.guild.id, channel, "move", { from = ctx:get_arg("from"), to = ctx:get_arg("to") })
    return ok, ok and "Moved the track in the queue." or reason
  end)
end

return Commands
