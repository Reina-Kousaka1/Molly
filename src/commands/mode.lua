local Store = require("src.persistence.guild_store")
local Permissions = require("src.discord.permissions")
local Util = require("src.commands.community_util")

local Commands = {}

function Commands.register(router, modes, options)
  options = options or {}
  router:register({
    name = "mode", category = "Administration", description = "Choose this server's virtual experience mode",
    permission = "manage_guild", default_member_permissions = Permissions.flags.manage_guild,
    options = {
      { type = 1, name = "show", description = "Show the current server mode" },
      { type = 1, name = "set", description = "Set the server mode", options = {
        { type = 3, name = "value", description = "Standard or virtual Sephora mode", required = true,
          choices = { { name = "Standard", value = "standard" }, { name = "Virtual Sephora", value = "sephora" } } },
      } },
    },
    execute = function(ctx)
      local guild = ctx.guild and ctx.guild.id
      if not Store.valid_id(guild) then ctx:respond("This command requires a server.", { ephemeral = true }); return end
      if not Util.is_manager(ctx) then ctx:respond("You need Manage Server to change the server mode.", { ephemeral = true }); return end
      if not Util.defer(ctx) then return end
      if ctx.molly_subcommand == "show" then
        local ok, mode = modes:get(guild)
        Util.reply(ctx, ok and ("Server mode: " .. mode.label .. ".") or "Server mode is unavailable.")
        return
      end
      if ctx.molly_subcommand ~= "set" then Util.reply(ctx, "Choose show or set."); return end
      local selected = Util.arg(ctx, "value")
      if selected ~= "standard" and selected ~= "sephora" then Util.reply(ctx, "Choose standard or sephora."); return end
      local ok = modes:set(guild, selected)
      if not ok then Util.reply(ctx, "Server mode could not be saved."); return end
      if options.logs then options.logs:record(guild, "settings", "Server mode changed to " .. selected .. ".") end
      local response = selected == "sephora"
        and "Virtual Sephora mode is active for this server. Its looks are fictional, cosmetic, and free; no purchases or payments are involved."
        or "Standard mode is active. The existing server economy and ledger remain unchanged."
      Util.reply(ctx, response)
    end,
  })
end

return Commands
