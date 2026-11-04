local Store = require("src.persistence.guild_store")
local Util = require("src.commands.community_util")

local Commands = {}

function Commands.register(router, modes, sephora)
  local choices = {}
  for _, item in ipairs(sephora:lookbook()) do choices[#choices + 1] = { name = item.name, value = item.id } end
  router:register({
    name = "sephora", category = "Utility", description = "Try a fictional, free virtual style in this server's Sephora mode",
    options = {
      { type = 1, name = "lookbook", description = "Browse available virtual styles" },
      { type = 1, name = "try", description = "Try a virtual style", options = {
        { type = 3, name = "look", description = "Choose a virtual style", required = true, choices = choices },
      } },
      { type = 1, name = "status", description = "Show your current virtual style" },
      { type = 1, name = "clear", description = "Clear your current virtual style" },
    },
    execute = function(ctx)
      local guild, user = ctx.guild and ctx.guild.id, ctx.author and ctx.author.id
      if not Store.valid_id(guild) or not Store.valid_id(user) then ctx:respond("This command requires a server member.", { ephemeral = true }); return end
      if not Util.defer(ctx) then return end
      local ok, mode = modes:get(guild)
      if not ok or mode.id ~= "sephora" then Util.reply(ctx, "This server is not using Virtual Sephora mode. Ask a server manager to change `/mode`."); return end
      local action = ctx.molly_subcommand
      if action == "lookbook" then
        local lines = {}
        for _, item in ipairs(sephora:lookbook()) do lines[#lines + 1] = item.name .. " — " .. item.description end
        Util.reply(ctx, "Fictional virtual styles; free to try, with no purchases or payment.\n" .. table.concat(lines, "\n"))
      elseif action == "try" then
        local look_id = Util.arg(ctx, "look")
        local request = ctx.interaction_id
        local changed, result = sephora:try_on(guild, user, look_id, request)
        if not changed then Util.reply(ctx, result == "capacity" and "This server's virtual fitting list is full." or "That virtual look could not be selected."); return end
        local chosen
        for _, item in ipairs(sephora:lookbook()) do if item.id == result.look_id then chosen = item end end
        Util.reply(ctx, chosen and ("Virtual look selected: " .. chosen.name .. ". No currency or payment was used.")
          or "Virtual look selected. No currency or payment was used.")
      elseif action == "status" then
        local found, result = sephora:get(guild, user)
        if not found then Util.reply(ctx, "Virtual style settings are unavailable."); return end
        if not result then Util.reply(ctx, "You have not selected a virtual look."); return end
        for _, item in ipairs(sephora:lookbook()) do
          if item.id == result.look_id then Util.reply(ctx, "Current virtual look: " .. item.name .. "."); return end
        end
        Util.reply(ctx, "Your virtual look is unavailable.")
      elseif action == "clear" then
        local cleared, result = sephora:clear(guild, user)
        Util.reply(ctx, cleared and (result and "Virtual look cleared." or "No virtual look was selected.")
          or "Virtual look could not be cleared.")
      else
        Util.reply(ctx, "Choose lookbook, try, status, or clear.")
      end
    end,
  })
end

return Commands
