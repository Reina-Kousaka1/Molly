local Store = require("src.persistence.guild_store")
local Permissions = require("src.discord.permissions")
local Util = require("src.commands.community_util")

local Commands = {}
local EVENTS = { "member_join", "member_leave", "moderation", "ban", "unban", "roles", "settings" }
local choices = {}
for _, name in ipairs(EVENTS) do choices[#choices + 1] = { name = name, value = name } end

function Commands.register(router, settings, action_log)
  router:register({
    name = "logs", category = "Administration", description = "Configure this server's event log channel",
    permission = "manage_guild", default_member_permissions = Permissions.flags.manage_guild,
    options = {
      { type = 1, name = "show", description = "Show the current event log configuration" },
      { type = 1, name = "enable", description = "Enable configured event logging" },
      { type = 1, name = "disable", description = "Disable event logging" },
      { type = 1, name = "channel", description = "Set the log text channel", options = { Util.option("channel", "Text channel", 7, true) } },
      { type = 1, name = "event", description = "Enable or disable one event category", options = {
        { type = 3, name = "event", description = "Event category", required = true, choices = choices },
        { type = 5, name = "enabled", description = "Whether this event category is enabled", required = true },
      } },
    },
    execute = function(ctx)
      local guild = ctx.guild and ctx.guild.id
      if not Store.valid_id(guild) then ctx:respond("This command requires a server.", { ephemeral = true }); return end
      if not Util.is_manager(ctx) then ctx:respond("You need Manage Server to configure event logs.", { ephemeral = true }); return end
      if not Util.defer(ctx) then return end
      local action, ok, value = ctx.molly_subcommand
      if action == "show" then
        ok, value = settings:get_domain(guild, "logs")
        if not ok then Util.reply(ctx, "Event log settings are unavailable."); return end
        local enabled_events = {}
        for _, name in ipairs(EVENTS) do if value.events[name] then enabled_events[#enabled_events + 1] = name end end
        Util.reply(ctx, "Event logs are " .. (value.enabled and "enabled" or "disabled")
          .. ". Channel: " .. (value.channel_id ~= "" and ("<#" .. value.channel_id .. ">") or "not set")
          .. ". Categories: " .. (#enabled_events > 0 and table.concat(enabled_events, ", ") or "none") .. ".")
        return
      elseif action == "enable" or action == "disable" then
        local current_ok, current = settings:get_domain(guild, "logs")
        if not current_ok then Util.reply(ctx, "Event log settings are unavailable."); return end
        if action == "enable" and not Store.valid_id(current.channel_id) then
          Util.reply(ctx, "Set a text channel before enabling event logs."); return
        end
        ok, value = settings:update_domain(guild, "logs", function(config)
          config.enabled = action == "enable"
          return true
        end)
      elseif action == "channel" then
        local channel = Util.id(Util.arg(ctx, "channel"))
        local valid, reason = Util.validate_text_channel(ctx.bot and ctx.bot.rest, guild, channel)
        if not valid then
          Util.reply(ctx, reason == "wrong_guild" and "Choose a text channel in this server." or "That text channel is unavailable.")
          return
        end
        ok, value = settings:update_domain(guild, "logs", function(config)
          config.channel_id = channel
          return true
        end)
      elseif action == "event" then
        local event, enabled = Util.arg(ctx, "event"), Util.arg(ctx, "enabled")
        local known = false
        for _, name in ipairs(EVENTS) do if name == event then known = true end end
        if not known or type(enabled) ~= "boolean" then Util.reply(ctx, "Choose a valid event category and enabled value."); return end
        ok, value = settings:update_domain(guild, "logs", function(config)
          config.events[event] = enabled
          return true
        end)
      else
        Util.reply(ctx, "Choose a valid event log action.")
        return
      end
      if not ok then Util.reply(ctx, value == "invalid_setting" and "Event log settings are invalid." or "Event log settings could not be saved."); return end
      if action_log then action_log:record(guild, "settings", "Event log settings updated.") end
      Util.reply(ctx, "Event log settings updated.")
    end,
  })
end

return Commands
