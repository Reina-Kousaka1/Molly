local Permissions = require("src.discord.permissions")
local Response = require("src.discord.response")
local PanelCommands = {}

function PanelCommands.register(router, panel)
  router:register({ name = "music-panel", description = "Configure Molly's persistent music controls",
    category = "Administration", permission = "manage_guild", default_member_permissions = Permissions.flags.manage_guild,
    options = {
      { type = 1, name = "setup", description = "Create or move the music control panel", options = {
        { name = "channel", description = "Text channel for the music panel", type = 7, required = true, channel_types = { 0, 5 } },
      } },
      { type = 1, name = "status", description = "Show music panel configuration" },
      { type = 1, name = "disable", description = "Disable the music panel" },
    },
    execute = function(ctx)
      if not ctx.guild or not Permissions.has(ctx.member and ctx.member.permissions, "manage_guild") then
        ctx:respond("You do not have permission to change music panel settings.", { ephemeral = true }); return
      end
      local action = ctx.molly_subcommand
      if action == "status" then
        local ok, current = panel:_read(ctx.guild.id)
        ctx:respond(not ok and "Music panel configuration is unavailable." or
          (current.message_id and ("Music panel: <#" .. current.channel_id .. ">") or "Music panel is not configured."), { ephemeral = true })
        return
      end
      if not Response.defer(ctx, { ephemeral = true }) then return end
      if action == "disable" then
        local ok = panel:disable(ctx.guild.id)
        ctx:edit(ok and "Music panel disabled." or "Could not update music panel configuration.")
        return
      end
      if action == "setup" then
        local channel = ctx:get_arg("channel")
        local channel_id = type(channel) == "table" and channel.id or nil
        local ok, result = panel:configure(ctx.guild.id, channel_id)
        ctx:edit(ok and ("Music control panel is ready in <#" .. channel_id .. ">.") or "Could not create the music control panel.")
        return
      end
      ctx:edit("Choose setup, status, or disable.")
    end,
  })
end

return PanelCommands
