local Store = require("src.persistence.guild_store")
local Util = require("src.commands.community_util")

local Commands = {}

function Commands.register(router, settings)
  router:register({
    name = "user-settings", category = "Utility", description = "Manage your optional private Molly preferences",
    options = {
      { type = 1, name = "show", description = "Show your saved preferences" },
      { type = 1, name = "mature-on", description = "Opt in to non-explicit mature themes where a server permits them" },
      { type = 1, name = "mature-off", description = "Opt out of non-explicit mature themes" },
      { type = 1, name = "compact-on", description = "Prefer compact replies where supported" },
      { type = 1, name = "compact-off", description = "Use standard replies where supported" },
      { type = 1, name = "reset", description = "Remove your saved Molly preferences" },
    },
    execute = function(ctx)
      local user = ctx.author and ctx.author.id
      if not Store.valid_id(user) then ctx:respond("A valid Discord user is required.", { ephemeral = true }); return end
      if not Util.defer(ctx) then return end
      local action = ctx.molly_subcommand
      local ok, value
      if action == "show" then
        ok, value = settings:get(user)
      elseif action == "mature-on" or action == "mature-off" then
        ok, value = settings:set_mature_opt_in(user, action == "mature-on")
      elseif action == "compact-on" or action == "compact-off" then
        ok, value = settings:set_compact(user, action == "compact-on")
      elseif action == "reset" then
        ok, value = settings:reset(user)
      else
        Util.reply(ctx, "Choose show, mature-on, mature-off, compact-on, compact-off, or reset.")
        return
      end
      if not ok then Util.reply(ctx, value == "capacity" and "The optional user-preference store is full." or "User preferences are unavailable."); return end
      if action == "show" then
        Util.reply(ctx, "Mature themes: " .. (value.mature_opt_in and "opted in" or "opted out (default)")
          .. ". Compact replies: " .. (value.compact_replies and "on" or "off (default)") .. ".")
      elseif action == "reset" then
        Util.reply(ctx, "Your optional Molly preferences have been removed.")
      elseif action == "mature-on" then
        Util.reply(ctx, "You opted in to non-explicit mature themes. A server's own policy and approved NSFW channel are still required; explicit sexual content remains prohibited.")
      elseif action == "mature-off" then
        Util.reply(ctx, "You opted out of non-explicit mature themes.")
      else
        Util.reply(ctx, "Compact reply preference updated.")
      end
    end,
  })
end

return Commands
