local Store = require("src.persistence.guild_store")
local Permissions = require("src.discord.permissions")
local Util = require("src.commands.community_util")

local Commands = {}

function Commands.register(router, settings, options)
  options = options or {}
  router:register({
    name = "starboard", category = "Administration", description = "Configure this server's starboard",
    permission = "manage_guild", default_member_permissions = Permissions.flags.manage_guild,
    options = {
      { type = 1, name = "show", description = "Show starboard settings" },
      { type = 1, name = "enable", description = "Enable the starboard" },
      { type = 1, name = "disable", description = "Disable the starboard" },
      { type = 1, name = "channel", description = "Set the starboard text channel", options = { Util.option("channel", "Text channel", 7, true) } },
      { type = 1, name = "emoji", description = "Set the tracked emoji", options = { Util.option("value", "Unicode emoji or custom emoji", 3, true, 80) } },
      { type = 1, name = "threshold", description = "Set the reaction threshold", options = { { type = 4, name = "count", description = "Required reaction count (1-100)", required = true, min_value = 1, max_value = 100 } } },
      { type = 1, name = "ignore", description = "Ignore a source channel", options = { Util.option("channel", "Text channel", 7, true) } },
      { type = 1, name = "unignore", description = "Stop ignoring a source channel", options = { Util.option("channel", "Text channel", 7, true) } },
    },
    execute = function(ctx)
      local guild = ctx.guild and ctx.guild.id
      if not Store.valid_id(guild) then ctx:respond("This command requires a server.", { ephemeral = true }); return end
      if not Util.is_manager(ctx) then ctx:respond("You need Manage Server to configure the starboard.", { ephemeral = true }); return end
      if not Util.defer(ctx) then return end
      local action, ok, value = ctx.molly_subcommand
      if action == "show" then
        ok, value = settings:get_domain(guild, "starboard")
        if not ok then Util.reply(ctx, "Starboard settings are unavailable."); return end
        Util.reply(ctx, "Starboard is " .. (value.enabled and "enabled" or "disabled") .. ". Channel: "
          .. (value.channel_id ~= "" and ("<#" .. value.channel_id .. ">") or "not set")
          .. ". Emoji: " .. value.emoji .. ". Threshold: " .. tostring(value.threshold)
          .. ". Ignored source channels: " .. tostring(#value.ignored_channels) .. ".")
        return
      elseif action == "enable" or action == "disable" then
        local read_ok, current = settings:get_domain(guild, "starboard")
        if not read_ok then Util.reply(ctx, "Starboard settings are unavailable."); return end
        if action == "enable" and not Store.valid_id(current.channel_id) then
          Util.reply(ctx, "Set a text channel before enabling the starboard."); return
        end
        ok, value = settings:update_domain(guild, "starboard", function(config)
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
        ok, value = settings:update_domain(guild, "starboard", function(config)
          config.channel_id = channel
          return true
        end)
      elseif action == "emoji" then
        local emoji = Util.arg(ctx, "value")
        ok, value = settings:update_domain(guild, "starboard", function(config)
          config.emoji = emoji
          return true
        end)
      elseif action == "threshold" then
        local count = Util.arg(ctx, "count")
        ok, value = settings:update_domain(guild, "starboard", function(config)
          config.threshold = count
          return true
        end)
      elseif action == "ignore" or action == "unignore" then
        local channel = Util.id(Util.arg(ctx, "channel"))
        local valid, reason = Util.validate_text_channel(ctx.bot and ctx.bot.rest, guild, channel)
        if not valid then
          Util.reply(ctx, reason == "wrong_guild" and "Choose a text channel in this server." or "That text channel is unavailable.")
          return
        end
        ok, value = settings:update_domain(guild, "starboard", function(config)
          local found
          for i, id in ipairs(config.ignored_channels) do if id == channel then found = i; break end end
          if action == "ignore" and not found then config.ignored_channels[#config.ignored_channels + 1] = channel; table.sort(config.ignored_channels)
          elseif action == "unignore" and found then table.remove(config.ignored_channels, found)
          else return false end
          return true
        end)
      else
        Util.reply(ctx, "Choose a valid starboard setting action.")
        return
      end
      if not ok then Util.reply(ctx, value == "invalid_setting" and "That starboard value is invalid." or "Starboard settings could not be saved."); return end
      if options.logs then options.logs:record(guild, "settings", "Starboard settings updated.") end
      Util.reply(ctx, "Starboard settings updated.")
    end,
  })
end

return Commands
