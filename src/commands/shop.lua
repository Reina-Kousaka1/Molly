local Store = require("src.persistence.guild_store")
local Util = require("src.commands.community_util")
local Catalog = require("src.economy.catalog")
local Money = require("src.economy.money_format")

local Commands = {}

local function money(settings, guild, amount)
  return Money.formatter(settings, guild)(amount)
end

function Commands.register(router, shop, settings)
  local resource_choices = {}
  for _, item in ipairs(Catalog.resources()) do resource_choices[#resource_choices + 1] = { name = item.name .. " — sell for " .. item.sell_price .. " coins", value = item.id } end

  local look_choices = {}
  for _, look in ipairs(shop:lookbook()) do look_choices[#look_choices + 1] = { name = look.name, value = look.id } end
  local quantity = { type = 4, name = "quantity", description = "Whole item quantity", required = false, min_value = 1, max_value = 99 }
  router:register({
    name = "shop", category = "Economy", description = "Browse KiddyyMolly\'s permanent pink economy shop",
    options = {
      { type = 1, name = "status", description = "Show the pink shop status" },
      { type = 1, name = "catalog", description = "Browse available virtual items" },
      { type = 1, name = "browse", description = "Browse verified retail departments", options = {
        { type = 3, name = "department", description = "Optional department", required = false, choices = {
          { name = "Sephora Beauty", value = "sephora" }, { name = "lululemon Fashion", value = "lululemon" },
          { name = "Pandora Jewelry", value = "pandora" },
        } },
      } },
      { type = 1, name = "search", description = "Search the curated retail catalog", options = {
        { type = 3, name = "query", description = "Product, brand or category", required = true, max_length = 80 },
      } },
      { type = 1, name = "item", description = "Show a retail product and its purchasable variants", options = {
        { type = 3, name = "product", description = "Stable product ID", required = true, max_length = 32 },
      } },
      { type = 1, name = "cart", description = "Manage your saved virtual retail cart", options = {
        { type = 3, name = "operation", description = "Show, add, or remove a variant", required = true, choices = {
          { name = "Show", value = "show" }, { name = "Add", value = "add" }, { name = "Remove", value = "remove" },
        } },
        { type = 3, name = "item", description = "Retail variant ID (for add/remove)", required = false, max_length = 32 },
        { type = 4, name = "quantity", description = "Quantity to add (cart only)", required = false, min_value = 1, max_value = 99 },
      } },
      { type = 1, name = "wishlist", description = "Save or view retail wishlist variants", options = {
        { type = 3, name = "operation", description = "Show, add, or remove a variant", required = true, choices = {
          { name = "Show", value = "show" }, { name = "Add", value = "add" }, { name = "Remove", value = "remove" },
        } },
        { type = 3, name = "item", description = "Retail variant ID (for add/remove)", required = false, max_length = 32 },
      } },
      { type = 1, name = "favorites", description = "Save or view your favorite retail variants", options = {
        { type = 3, name = "operation", description = "Show, add, or remove a variant", required = true, choices = {
          { name = "Show", value = "show" }, { name = "Add", value = "add" }, { name = "Remove", value = "remove" },
        } },
        { type = 3, name = "item", description = "Retail variant ID (for add/remove)", required = false, max_length = 32 },
      } },
      { type = 1, name = "looks", description = "Browse unlockable Sephora-inspired looks" },
      { type = 1, name = "try", description = "Wear a beauty look you already own", options = {
        { type = 3, name = "look", description = "Virtual style", required = true, choices = look_choices },
      } },
      { type = 1, name = "lookstatus", description = "Show your selected virtual look" },
      { type = 1, name = "clearlook", description = "Remove your selected virtual look" },
      { type = 1, name = "buy", description = "Buy a beauty or fashion item with coins", options = {
        { type = 3, name = "item", description = "Catalog or retail variant ID", required = true, max_length = 32 }, quantity,
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
        if value.mode == "sephora" then
          Util.reply(ctx, "Virtual Sephora is open: choose a free look with `/shop buy`. Coin purchases and selling are disabled in this mode.")
          return
        end
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
          local price = item.price and money(settings, guild, item.price) or "free"
          lines[#lines + 1] = string.format("%s (`%s`) — %s: %s", Util.safe(item.name, 80), Util.safe(item.id, 32), price, Util.safe(item.description, 180))
        end
        if result.mode == "sephora" then
          lines[#lines + 1] = "Choose one free virtual look with `/shop buy`; no coins or inventory items are changed."
        else
          for _, item in ipairs(Catalog.resources()) do
            lines[#lines + 1] = string.format("Sell %s (`%s`) — %s each", item.name, item.id, money(settings, guild, item.sell_price))
          end
          lines[#lines + 1] = "A pickaxe is required to mine; resources are sold through `/shop sell`."
        end
        Util.reply(ctx, table.concat(lines, "\n"))
      elseif action == "browse" then
        local ok, products = shop:retail_browse(guild, Util.arg(ctx, "department"))
        if not ok then Util.reply(ctx, products == "shop_disabled" and "The virtual retail shop is disabled for this server."
          or "The retail catalog is unavailable."); return end
        local lines = { "🎀 Curated virtual departments (not affiliated with the brands):" }
        for _, product in ipairs(products) do
          local variant = product.variants[1]
          lines[#lines + 1] = string.format("%s · %s · %s · `%s`", Util.safe(product.brand, 40),
            Util.safe(product.name, 80), money(settings, guild, variant.price), Util.safe(product.id, 32))
        end
        Util.reply(ctx, table.concat(lines, "\n"))
      elseif action == "search" then
        local ok, products = shop:retail_search(guild, Util.arg(ctx, "query"))
        if not ok then Util.reply(ctx, products == "shop_disabled" and "The virtual retail shop is disabled for this server."
          or "Enter a search term of 1–80 characters."); return end
        local lines = { "Retail search results:" }
        for _, product in ipairs(products) do
          local variant = product.variants[1]
          lines[#lines + 1] = string.format("%s · %s · %s · `%s`", Util.safe(product.brand, 40),
            Util.safe(product.name, 80), money(settings, guild, variant.price), Util.safe(product.id, 32))
        end
        Util.reply(ctx, #products > 0 and table.concat(lines, "\n") or "No curated products matched that search.")
      elseif action == "item" then
        local ok, product = shop:retail_item(guild, Util.arg(ctx, "product"))
        if not ok then Util.reply(ctx, product == "shop_disabled" and "The virtual retail shop is disabled for this server."
          or "That product is not in the curated catalog."); return end
        local lines = { string.format("%s · %s", Util.safe(product.brand, 40), Util.safe(product.name, 80)),
          Util.safe(product.description, 160), "Variants (use a variant ID with `/shop buy`):" }
        for _, variant in ipairs(product.variants) do
          lines[#lines + 1] = string.format("• %s — %s (`%s`)", Util.safe(variant.variant, 30),
            money(settings, guild, variant.price), Util.safe(variant.id, 32))
        end
        lines[#lines + 1] = "Reference price checked " .. Util.safe(product.variants[1].price_snapshot.checked_at, 10)
        Util.reply(ctx, table.concat(lines, "\n"))
      elseif action == "cart" or action == "wishlist" or action == "favorites" then
        local operation, item_id = Util.arg(ctx, "operation"), Util.arg(ctx, "item")
        if operation == "show" then
          local ok, state = shop:retail_user_state(guild, user)
          if not ok then Util.reply(ctx, "Your saved shopping state is unavailable."); return end
          local saved = state[action]
          local lines = { action == "cart" and "Your virtual retail cart:" or (action == "wishlist" and "Your retail wishlist:" or "Your favorite retail variants:") }
          local count = 0
          for id, quantity_or_index in pairs(saved) do
            count = count + 1
            if count <= 20 then
              local variant_id, quantity = action == "cart" and id or quantity_or_index, action == "cart" and quantity_or_index or 1
              local variant = Catalog.get(variant_id)
              lines[#lines + 1] = string.format("• %s · %s (%s) × %d — %s · `%s`",
                Util.safe(variant.brand, 35), Util.safe(variant.name, 70), Util.safe(variant.variant, 30), quantity,
                money(settings, guild, variant.price), Util.safe(variant.id, 32))
            end
          end
          if count == 0 then lines[#lines + 1] = "• Empty" end
          if count > 20 then lines[#lines + 1] = string.format("Showing 20 of %d saved variants.", count) end
          if action == "cart" then lines[#lines + 1] = "Cart checkout is not available yet; buy listed variants individually with `/shop buy`." end
          Util.reply(ctx, table.concat(lines, "\n"))
        elseif operation == "add" or operation == "remove" then
          if type(item_id) ~= "string" then Util.reply(ctx, "Provide a retail variant ID from `/shop item`."); return end
          local ok, result = shop:update_retail_state(guild, user, action, operation, item_id, Util.arg(ctx, "quantity"))
          if not ok then
            local error_text = result == "shop_disabled" and "The virtual retail shop is disabled for this server."
              or result == "not_saved" and "That variant is not saved in this list."
              or result == "capacity" and "This saved list has reached its limit."
              or result == "invalid_quantity" and "Choose a quantity from 1 to 99."
              or "That variant could not be saved. Check its ID with `/shop item`."
            Util.reply(ctx, error_text); return
          end
          local name = action == "cart" and "cart" or action
          Util.reply(ctx, operation == "add" and (result.already_saved and ("That variant is already in your " .. name .. ".")
            or ("Added the variant to your " .. name .. ".")) or ("Removed the variant from your " .. name .. "."))
        else
          Util.reply(ctx, "Choose show, add, or remove.")
        end
      elseif action == "looks" then
        local status_ok, shop_status = shop:status(guild)
        local free_selection = status_ok and shop_status.mode == "sephora"
        local lines = { free_selection and "🎀 Virtual Sephora looks: select one for free with `/shop buy`:" or "🎀 Beauty looks: earn coins and buy with `/shop buy`:" }
        for _, look in ipairs(shop:lookbook()) do
          local item = Catalog.get(look.id)
          local price = free_selection and "free in Virtual Sephora" or money(settings, guild, item and item.price or 0) .. " in Standard mode"
          lines[#lines + 1] = look.name .. " (`" .. look.id .. "`) — " .. price
        end
        Util.reply(ctx, table.concat(lines, "\n"))
      elseif action == "try" then
        local look_id = Util.arg(ctx, "look")
        local ok, result = shop.sephora:try_on(guild, user, look_id, ctx.request_id or ctx.interaction_id)
        if not ok then Util.reply(ctx, result == "not_owned" and "You need to own this look first. In Standard mode, buy it with coins; in Virtual Sephora, use `/shop buy` to select a free look." or ("That look could not be selected (" .. Util.safe(result, 40) .. ").")); return end
        Util.reply(ctx, "🎀 Virtual look selected: " .. Util.safe(result.look_id, 40) .. ".")
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
        if result.mode == "sephora" then
          Util.reply(ctx, "Virtual look selected: " .. Util.safe(result.name, 80) .. ". It was free; no coins were charged.")
          return
        end
        local bought_name = (result.brand and (result.brand .. " · ") or "") .. result.name
        if result.variant then bought_name = bought_name .. " (" .. result.variant .. ")" end
        local text = string.format("Purchased %d × %s for %s. Wallet: %s. Money ID: `%s`.", result.quantity,
          Util.safe(bought_name, 120), money(settings, guild, result.charged), money(settings, guild, result.wallet), Util.safe(result.money_id, 24))
        if result.personality_reply then text = text .. "\n\n" .. Util.safe(result.personality_reply, 180) end
        Util.reply(ctx, text)
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
        Util.reply(ctx, "Choose browse, search, item, cart, wishlist, favorites, catalog, buy, looks, try, lookstatus, clearlook, sell, status, enable, or disable.")
      end
    end,
  })
end

return Commands
