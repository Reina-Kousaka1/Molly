local Store = require("src.persistence.guild_store")
local Util = require("src.commands.community_util")
local Catalog = require("src.economy.catalog")

local Commands = {}

function Commands.register(router, mining)
  router:register({
    name = "mine", category = "Economy", description = "Mine a virtual resource using a reusable pickaxe",
    execute = function(ctx)
      local guild, user = ctx.guild and ctx.guild.id, ctx.author and ctx.author.id
      if not Store.valid_id(guild) or not Store.valid_id(user) then ctx:respond("This command requires a server member.", { ephemeral = true }); return end
      if not Util.defer(ctx) then return end
      local ok, result = mining:mine(guild, user, ctx.request_id or ctx.interaction_id, ctx.request_type)
      if not ok then
        local messages = {
          mode_unavailable = "Mining is unavailable in this server mode.",
          replay_conflict = "This request ID was already used for a different economy action; no new changes were made.",
          replay_expired = "This request is outside the retained retry window; no new mining action was made.",
          pickaxe_required = "You need a pickaxe. Enable the shop and buy one with `/shop buy`.",
          cooldown = "You need to wait before mining again.",
          capacity = "Your inventory or the economy has reached its current limit.",
          random_unavailable = "Mining could not safely determine a result; no resources were changed.",
          busy = "Molly is processing another economy request. Try again shortly.",
          outcome_unknown = "The outcome could not be confirmed. Check `/inventory` and `/transactions` before retrying.",
          unavailable = "Economy storage is unavailable.", invalid_store = "Economy storage requires administrator attention.",
        }
        Util.reply(ctx, messages[result] or "Mining could not be completed.")
        return
      end
      local item = Catalog.get_resource(result.item_id)
      Util.reply(ctx, string.format("You mined %d × %s. Sell resources with `/shop sell`. Next mining attempt is available after %d seconds. Money ID: `%s`.",
        result.quantity, Util.safe(item and item.name or result.item_id, 80), result.cooldown_seconds, Util.safe(result.money_id, 24)))
    end,
  })
end

return Commands
