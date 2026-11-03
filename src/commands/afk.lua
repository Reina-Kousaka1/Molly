local Store = require("src.persistence.guild_store")
local Response = require("src.discord.response")

local Commands = {}

local function arg(ctx, name)
  if ctx.args and ctx.args[name] ~= nil then return ctx.args[name] end
  if type(ctx.get_arg) == "function" then return ctx:get_arg(name) end
end

local function reply(ctx, text)
  if ctx._molly_deferred then ctx:edit(text) else ctx:respond(text, { ephemeral = true }) end
end

local function option(name, description, required, maximum)
  return { type = 3, name = name, description = description, required = required == true,
    min_length = 1, max_length = maximum }
end

function Commands.register(router, afk, options)
  options = options or {}
  router:register({
    name = "afk", category = "Utility", description = "Set or clear your server-specific away status",
    options = {
      { type = 1, name = "set", description = "Set your away status", options = { option("message", "Optional short status message", false, 140) } },
      { type = 1, name = "clear", description = "Clear your away status" },
      { type = 1, name = "status", description = "Show your current away status" },
    },
    execute = function(ctx)
      if not Store.valid_id(ctx.guild and ctx.guild.id) or not Store.valid_id(ctx.author and ctx.author.id) then
        ctx:respond("This command requires a server.", { ephemeral = true }); return
      end
      local deferred = Response.defer(ctx, { ephemeral = true })
      if not deferred then return end
      local action, guild, user = ctx.molly_subcommand, ctx.guild.id, ctx.author.id
      if action == "set" then
        local ok, result = afk:set(guild, user, arg(ctx, "message") or "")
        if not ok then
          reply(ctx, result == "capacity" and "This server has reached its AFK status limit."
            or "AFK status could not be saved. Use at most 140 characters.")
          return
        end
        reply(ctx, "AFK status set.")
      elseif action == "clear" then
        local ok, removed = afk:clear(guild, user)
        if not ok then reply(ctx, "AFK status could not be cleared.")
        else reply(ctx, removed and "AFK status cleared." or "You did not have an AFK status.") end
      elseif action == "status" then
        local ok, entries = afk:get(guild, user)
        if not ok then reply(ctx, "AFK status is unavailable."); return end
        local value = entries[user]
        reply(ctx, value and (value.message ~= "" and ("Your AFK status: " .. value.message) or "Your AFK status is set.")
          or "You are not marked AFK.")
      else
        reply(ctx, "Choose set, clear, or status.")
      end
    end,
  })
end

return Commands
