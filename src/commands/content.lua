local Store = require("src.persistence.guild_store")
local Permissions = require("src.discord.permissions")
local Util = require("src.commands.community_util")

local Commands = {}

function Commands.register(router, settings, policy, options)
  options = options or {}
  router:register({
    name = "content", category = "Administration", description = "Configure the non-explicit mature-content safety policy",
    permission = "manage_guild", default_member_permissions = Permissions.flags.manage_guild,
    options = {
      { type = 1, name = "show", description = "Show the current mature-content policy" },
      { type = 1, name = "enable", description = "Allow non-explicit mature themes in approved NSFW channels" },
      { type = 1, name = "disable", description = "Disable mature themes" },
      { type = 1, name = "channel-add", description = "Allow a verified NSFW text channel", options = { Util.option("channel", "NSFW text channel", 7, true) } },
      { type = 1, name = "channel-remove", description = "Remove an allowed NSFW channel", options = { Util.option("channel", "Channel to remove", 7, true) } },
    },
    execute = function(ctx)
      local guild = ctx.guild and ctx.guild.id
      if not Store.valid_id(guild) then ctx:respond("This command requires a server.", { ephemeral = true }); return end
      if not Util.is_manager(ctx) then ctx:respond("You need Manage Server to configure this policy.", { ephemeral = true }); return end
      if not Util.defer(ctx) then return end
      local action = ctx.molly_subcommand
      local ok, result
      if action == "show" then
        ok, result = settings:get_domain(guild, "content")
        if not ok then Util.reply(ctx, "Content policy settings are unavailable."); return end
        local channels = {}
        for _, id in ipairs(result.mature_channels) do channels[#channels + 1] = "<#" .. id .. ">" end
        Util.reply(ctx, "Non-explicit mature themes are " .. (result.mature_enabled and "enabled" or "disabled")
          .. ". Approved NSFW channels: " .. (#channels > 0 and table.concat(channels, ", ") or "none") .. ".")
        return
      elseif action == "enable" then
        ok, result = policy:set_enabled(guild, true)
      elseif action == "disable" then
        ok, result = policy:set_enabled(guild, false)
      elseif action == "channel-add" then
        local id = Util.id(Util.arg(ctx, "channel"))
        ok, result = policy:add_channel(guild, id)
      elseif action == "channel-remove" then
        local id = Util.id(Util.arg(ctx, "channel"))
        ok, result = policy:remove_channel(guild, id)
      else
        Util.reply(ctx, "Choose show, enable, disable, channel-add, or channel-remove.")
        return
      end
      if not ok then
        local message = result == "channel_required" and "Add at least one verified NSFW text channel before enabling."
          or result == "nsfw_channel_required" and "The selected channel must be marked NSFW by Discord."
          or result == "wrong_guild" and "Choose a channel in this server."
          or result == "capacity" and "At most 10 mature-content channels can be configured."
          or "The content policy could not be saved."
        Util.reply(ctx, message)
        return
      end
      if options.logs then options.logs:record(guild, "settings", "Mature-content safety policy updated.") end
      Util.reply(ctx, "Content policy updated. It permits only non-explicit mature themes in approved NSFW channels; explicit sexual content remains prohibited.")
    end,
  })
end

return Commands
