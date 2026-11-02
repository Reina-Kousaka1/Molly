local Permissions = require("src.discord.permissions")

local SettingsCommands = {}

local function option(name, description, max_length)
  return { name = name, description = description, type = 3, required = true, min_length = 1, max_length = max_length }
end

local function response(ctx, text)
  ctx:respond(text, { ephemeral = true })
end

function SettingsCommands.register(router, settings, options)
  options = options or {}
  router:register({
    name = "settings", category = "Administration", description = "Configure Molly for this server",
    permission = "manage_guild", default_member_permissions = Permissions.flags.manage_guild,
    options = {
      { type = 2, name = "prefix", description = "Configure this server's command prefix", options = {
        { type = 1, name = "show", description = "Show the current prefix" },
        { type = 1, name = "set", description = "Set a printable ASCII prefix (1-8 characters)", options = { option("value", "Prefix, for example ! or m!", 8) } },
        { type = 1, name = "reset", description = "Restore the default prefix" },
      } },
      { type = 2, name = "economy", description = "Configure this server's economy display", options = {
        { type = 1, name = "show", description = "Show the current currency display" },
        { type = 1, name = "currency-name", description = "Set the displayed currency name", options = { option("value", "Currency name", 32) } },
        { type = 1, name = "currency-symbol", description = "Set the displayed currency symbol or emoji", options = { option("value", "Currency symbol or emoji", 16) } },
        { type = 1, name = "reset", description = "Restore the default currency display" },
      } },
    },
    execute = function(ctx)
      if not ctx.guild or not ctx.guild.id then response(ctx, "This command requires a server."); return end
      if not Permissions.has(ctx.member and ctx.member.permissions, "manage_guild") then
        response(ctx, "You do not have permission to change server settings."); return
      end
      local group, action = ctx.molly_subcommand, ctx.molly_subcommand_action
      if group ~= "prefix" and group ~= "economy" then response(ctx, "Choose prefix or economy settings."); return end
      if action == "show" then
        local ok, current = settings:get(ctx.guild.id)
        if not ok then response(ctx, "Server settings are unavailable."); return end
        if group == "prefix" then
          response(ctx, "Command prefix: `" .. current.prefix .. "`")
        else
          response(ctx, "Currency: " .. (current.currency_symbol ~= "" and current.currency_symbol or "(no symbol)")
            .. " " .. current.currency_name .. "\nExisting balances and transaction amounts are unchanged.")
        end
        return
      end

      local ok, result
      if group == "prefix" and action == "set" then
        ok, result = settings:set_prefix(ctx.guild.id, ctx:get_arg("value"))
        if ok and options.on_prefix_changed then options.on_prefix_changed(ctx.guild.id, result.prefix) end
      elseif group == "prefix" and action == "reset" then
        ok, result = settings:reset_prefix(ctx.guild.id)
        if ok and options.on_prefix_changed then options.on_prefix_changed(ctx.guild.id, result.prefix) end
      elseif group == "economy" and action == "currency-name" then
        ok, result = settings:set_currency_name(ctx.guild.id, ctx:get_arg("value"))
      elseif group == "economy" and action == "currency-symbol" then
        ok, result = settings:set_currency_symbol(ctx.guild.id, ctx:get_arg("value"))
      elseif group == "economy" and action == "reset" then
        ok, result = settings:reset_economy(ctx.guild.id)
      else
        response(ctx, "Unknown server settings option."); return
      end
      if not ok then
        local message = result == "invalid_prefix" and "Use a non-whitespace printable ASCII prefix of at most 8 characters."
          or result == "invalid_currency_name" and "Use a non-empty currency name of at most 32 characters."
          or result == "invalid_currency_symbol" and "Use a non-whitespace symbol or emoji of at most 16 UTF-8 bytes."
          or "Server settings could not be saved."
        response(ctx, message)
        return
      end
      if group == "prefix" then
        response(ctx, action == "reset" and "Command prefix reset to `.`." or ("Command prefix set to `" .. result.prefix .. "`."))
      elseif action == "reset" then
        response(ctx, "Currency display reset to coins. Balances and transaction amounts were not changed.")
      else
        response(ctx, "Currency display updated. Existing balances and transaction amounts are unchanged.")
      end
    end,
  })
end

return SettingsCommands
