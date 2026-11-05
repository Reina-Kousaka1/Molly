local Store = require("src.persistence.guild_store")
local Util = require("src.commands.community_util")
local Catalog = require("src.economy.catalog")

local Commands = {}

function Commands.register(router, inventory)
  router:register({
    name = "inventory", category = "Economy", description = "View your server-specific virtual inventory",
    execute = function(ctx)
      local guild, user = ctx.guild and ctx.guild.id, ctx.author and ctx.author.id
      if not Store.valid_id(guild) or not Store.valid_id(user) then ctx:respond("This command requires a server member.", { ephemeral = true }); return end
      if not Util.defer(ctx) then return end
      local ok, value = inventory:get(guild, user)
      if not ok then Util.reply(ctx, value == "unavailable" and "Inventory storage is unavailable." or "Inventory could not be read."); return end
      local lines = { "Your inventory in this server:" }
      local items = {}
      for item_id, quantity in pairs(value.items) do
        local item = Catalog.get(item_id) or Catalog.get_resource(item_id)
        items[#items + 1] = { id = item_id, name = item and item.name or item_id, quantity = quantity }
      end
      table.sort(items, function(a, b) return a.name == b.name and a.id < b.id or a.name < b.name end)
      for _, item in ipairs(items) do
        local definition = Catalog.get(item.id) or Catalog.get_resource(item.id)
        local label = item.name .. (definition and definition.variant and (" (" .. definition.variant .. ")") or "")
        lines[#lines + 1] = string.format("• %s × %d (`%s`)", Util.safe(label, 100), item.quantity, Util.safe(item.id, 32))
      end
      if #items == 0 then lines[#lines + 1] = "• Empty" end
      local slots = {}
      for slot, item_id in pairs(value.equipped) do slots[#slots + 1] = { slot = slot, item = item_id } end
      table.sort(slots, function(a, b) return a.slot < b.slot end)
      if #slots > 0 then
        lines[#lines + 1] = "Equipped fashion:"
        for _, equipped in ipairs(slots) do
          local item = Catalog.get(equipped.item)
          lines[#lines + 1] = string.format("• %s: %s", Util.safe(equipped.slot, 24), Util.safe(item and item.name or equipped.item, 80))
        end
      end
      Util.reply(ctx, table.concat(lines, "\n"))
    end,
  })
end

return Commands
