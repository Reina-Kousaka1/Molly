local Store = require("src.persistence.guild_store")
local Util = require("src.commands.community_util")
local Catalog = require("src.economy.catalog")
local Money = require("src.economy.money_format")

local Commands = {}

local function money(settings, guild, amount)
  return Money.formatter(settings, guild)(amount)
end

function Commands.register(router, shop, settings)
  local buy_choices, resource_choices = {}, {}
  for _, item in ipairs(Catalog.list()) do buy_choices[#buy_choices + 1] = { name = item.name .. " — " .. item.price .. " coins", value = item.id } end
  for _, item in ipairs(Catalog.resources()) do resource_choices[#resource_choices + 1] = { name = item.name .. " — sell for " .. item.sell_price .. " coins", value = item.id } end

  local look_choices = {}
  for _, look in ipairs(shop:lookbook()) do look_choices[#look_choices + 1] = { name = look.name, value = look.id } end
  local quantity = { type = 4, name = "quantity", description = "Whole item quantity", required = false, min_value = 1, max_value = 99 }
  router:register({
    name = "shop", category = "Economy", description = "Browse KiddyyMolly\'s permanent pink economy shop",
    options = {
      { type = 1, name = "status", description = "Show the pink shop status" },
      { type = 1, name = "catalog", description = "Browse available virtual items" },
      { type = 1, name = "looks", description = "Browse unlockable Sephora-inspired looks" },
      { type = 1, name = "try", description = "Wear a beauty look you already own", options = {
        { type = 3, name = "look", description = "Virtual style", required = true, choices = look_choices },
      } },
      { type = 1, name = "lookstatus", description = "Show your selected virtual look" },
      { type = 1, name = "clearlook", description = "Remove your selected virtual look" },
      { type = 1, name = "buy", description = "Buy a beauty or fashion item with coins", options = {
        { type = 3, name = "item", description = "Catalog item", required = true, choices = buy_choices }, quantity,
      } },
      { type = 1, name = "sell", description = "Sell mined resources", options = {
        { type = 3, name = "item", description = "Mined resource", required = true, choices = resource_choices }, quantity,
      } },
      { type = 1, name = "enable", description = "Enable this server's coin shop and resource exchange" },
      { type = 1, name = "disable", description = "Disable the coin shop and resource exchange" },
    },
    execute = function(ctx)
      local guild, user = ctx.guild and ctx.guild.id, ctx.author and ctx.author.id
      if not Store.valid_id(guild) or not Store.valid_id(user) then ctx:respond("This command requires a server member.", { ephemeral = true }); return end
      if not Util.defer(ctx, { public = true }) then return end
      local action = ctx.molly_subcommand
      if action == "status" then
        local ok, value = shop:status(guild)
        if not ok then Util.reply(ctx, "Shop settings are unavailable."); return end
        Util.reply(ctx, "🎀 KiddyyMolly shop: " .. (value.enabled and "open" or "closed") .. ". Earn coins with economy commands, then buy your favorite looks.")
      elseif action == "catalog" then
        local ok, result = shop:list(guild)
        if not ok then
          Util.reply(ctx, result == "shop_disabled" and "The Kiddy coin shop is disabled for this server. A manager can run `/shop enable`."
            or "The shop catalog is unavailable.")
          return
        end
        local lines = {}
        for _, item in ipairs(result.items) do
          local price = item.price and (tostring(item.price) .. " coins") or "free"
          lines[#lines + 1] = string.format("%s (`%s`) — %s: %s", Util.safe(item.name, 80), Util.safe(item.id, 32), price, Util.safe(item.description, 180))
        end
        for _, item in ipairs(Catalog.resources()) do
          lines[#lines + 1] = string.format("Sell %s (`%s`) — %d coins each", item.name, item.id, item.sell_price)
        end
        lines[#lines + 1] = "A pickaxe is required to mine; resources are sold through `/shop sell`."
        Util.reply(ctx, table.concat(lines, "\n"))
      elseif action == "looks" then
        local lines = { "🎀 Beauty looks: earn coins, buy with `/shop buy`, then wear with `/shop try`:" }
        for _, look in ipairs(shop:lookbook()) do
          local item = Catalog.get(look.id)
          lines[#lines + 1] = look.name .. " (`" .. look.id .. "`) — " .. tostring(item and item.price or "?") .. " coins"
        end
        Util.reply(ctx, table.concat(lines, "\n"))
      elseif action == "try" then
        local look_id = Util.arg(ctx, "look")
        local ok, result = shop.sephora:try_on(guild, user, look_id, ctx.request_id or ctx.interaction_id)
        if not ok then Util.reply(ctx, result == "not_owned" and "You need to buy this look first using `/shop buy` and coins earned through economy commands." or ("That look could not be selected (" .. Util.safe(result, 40) .. ").")); return end
        Util.reply(ctx, "🎀 Virtual look selected: " .. Util.safe(result.look_id, 40) .. ". Previously purchased with coins.")
      elseif action == "lookstatus" then
        local ok, result = shop.sephora:get(guild, user)
        if not ok then Util.reply(ctx, "Your virtual look is unavailable."); return end
        Util.reply(ctx, result and ("Current virtual look: " .. Util.safe(result.look_id, 40)) or "No virtual look selected.")
      elseif action == "clearlook" then
        local ok, removed = shop.sephora:clear(guild, user)
        Util.reply(ctx, not ok and "Could not clear your virtual look." or (removed and "Virtual look cleared." or "No virtual look selected."))
      elseif action == "enable" or action == "disable" then
        if not Util.is_manager(ctx) then Util.reply(ctx, "You need Manage Server to configure the shop."); return end
        local ok = shop:set_enabled(guild, action == "enable")
        Util.reply(ctx, ok and (action == "enable" and "The Kiddy coin shop and resource exchange are enabled." or "The Kiddy coin shop and resource exchange are disabled.")
          or "Shop settings could not be saved.")
      elseif action == "buy" then
        local item, count = Util.arg(ctx, "item"), Util.arg(ctx, "quantity") or 1
        local ok, result = shop:buy(guild, user, ctx.request_id or ctx.interaction_id, item, count, ctx.request_type)
        if not ok then
          local messages = { shop_disabled = "The Kiddy coin shop is disabled for this server.",
            insufficient = "You do not have enough coins for that purchase.", capacity = "The shop or economy has reached its storage limit.",
            unknown_item = "That item is not in the server catalog.", virtual_item = "That item is not a virtual Sephora look.",
            replay_conflict = "This request ID was already used for a different economy action; no new changes were made.",
            replay_expired = "This request is outside the retained retry window; no new economy action was made.",
            virtual_mode = "That free look is available only while this server uses Virtual Sephora mode.",
            virtual_quantity = "Virtual Sephora looks are selected one at a time.", invalid_amount = "Choose a quantity from 1 to 99.",
            unavailable = "Economy storage is unavailable.", invalid_store = "Economy storage requires administrator attention." }
          Util.reply(ctx, messages[result] or "The purchase could not be completed.")
          return
        end
        Util.reply(ctx, string.format("Purchased %d × %s for %s. Wallet: %s. Money ID: `%s`.", result.quantity,
          Util.safe(result.name, 80), money(settings, guild, result.charged), money(settings, guild, result.wallet), Util.safe(result.money_id, 24)))
      elseif action == "sell" then
        local ok, result = shop:sell(guild, user, ctx.request_id or ctx.interaction_id,
          Util.arg(ctx, "item"), Util.arg(ctx, "quantity") or 1, ctx.request_type)
        if not ok then
          local messages = { shop_disabled = "The resource exchange is disabled for this server.",
            virtual_mode = "Mining resources cannot be sold in virtual Sephora mode.", not_owned = "You do not own that many resources.",
            unknown_item = "That resource cannot be sold.", invalid_amount = "Choose a quantity from 1 to 99.",
            overflow = "That sale would exceed the wallet limit.", unavailable = "Economy storage is unavailable.",
            invalid_store = "Economy storage requires administrator attention." }
          Util.reply(ctx, messages[result] or "The sale could not be completed.")
          return
        end
        Util.reply(ctx, string.format("Sold %d × %s for %s. Wallet: %s. Money ID: `%s`.", result.quantity,
          Util.safe(result.name, 80), money(settings, guild, result.charged), money(settings, guild, result.wallet), Util.safe(result.money_id, 24)))
      else
        Util.reply(ctx, "Choose catalog, buy, looks, try, lookstatus, clearlook, sell, status, enable, or disable.")
      end
    end,
  })
end

return Commands
