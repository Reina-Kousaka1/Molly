local Store = require("src.persistence.guild_store")
local Util = require("src.commands.community_util")
local Catalog = require("src.economy.catalog")

local Commands = {}

function Commands.register(router, fashion)
  local item_choices = {}
  for _, item in ipairs(Catalog.list()) do
    if item.kind == "fashion" then item_choices[#item_choices + 1] = { name = item.name, value = item.id } end
  end
  router:register({
    name = "fashion", category = "Economy", description = "Equip or remove virtual fashion items you own in this server",
    options = {
      { type = 1, name = "status", description = "Show your equipped fashion" },
      { type = 1, name = "equip", description = "Equip an owned fashion item", options = {
        { type = 3, name = "item", description = "Owned fashion item", required = true, choices = item_choices },
      } },
      { type = 1, name = "unequip", description = "Remove an equipped item", options = {
        { type = 3, name = "slot", description = "Fashion slot", required = true, choices = {
          { name = "Head", value = "head" }, { name = "Outfit", value = "outfit" }, { name = "Accessory", value = "accessory" },
        } },
      } },
    },
    execute = function(ctx)
      local guild, user = ctx.guild and ctx.guild.id, ctx.author and ctx.author.id
      if not Store.valid_id(guild) or not Store.valid_id(user) then ctx:respond("This command requires a server member.", { ephemeral = true }); return end
      if not Util.defer(ctx) then return end
      local action = ctx.molly_subcommand
      if action == "status" then
        local ok, result = fashion:get(guild, user)
        if not ok then
          Util.reply(ctx, result == "virtual_mode" and "Fashion inventory is unavailable in Virtual Sephora mode; use `/sephora` for its free virtual looks."
            or "Fashion inventory is unavailable.")
          return
        end
        local lines = {}
        for slot, item_id in pairs(result.equipped) do
          local item = Catalog.get(item_id)
          lines[#lines + 1] = string.format("%s: %s", Util.safe(slot, 24), Util.safe(item and item.name or item_id, 80))
        end
        table.sort(lines)
        Util.reply(ctx, #lines > 0 and ("Equipped fashion:\n" .. table.concat(lines, "\n")) or "You have no fashion items equipped. Use `/inventory` to see owned items.")
      elseif action == "equip" then
        local ok, result = fashion:equip(guild, user, Util.arg(ctx, "item"))
        if not ok then
          local message = result == "not_owned" and "You do not own that fashion item."
            or result == "not_fashion" and "That catalog item cannot be equipped."
            or result == "virtual_mode" and "Use `/sephora` for Virtual Sephora mode."
            or "Fashion settings could not be updated."
          Util.reply(ctx, message)
          return
        end
        Util.reply(ctx, result.name .. " is now equipped in the " .. result.slot .. " slot.")
      elseif action == "unequip" then
        local ok, result = fashion:unequip(guild, user, Util.arg(ctx, "slot"))
        if not ok then Util.reply(ctx, result == "virtual_mode" and "Use `/sephora` for Virtual Sephora mode." or "Fashion settings could not be updated."); return end
        Util.reply(ctx, result and "Fashion item unequipped." or "That slot was already empty.")
      else
        Util.reply(ctx, "Choose status, equip, or unequip.")
      end
    end,
  })
end

return Commands
