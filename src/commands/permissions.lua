local Response = require("src.discord.response")

local Commands = {}

local function option(name, description, kind, required)
  return { name = name, description = description, type = kind, required = required }
end

local function id_arg(ctx, name)
  local value = ctx:get_arg(name)
  return type(value) == "table" and value.id or nil
end

local function selector(ctx)
  return { user_id = id_arg(ctx, "user"), role_id = id_arg(ctx, "role"), channel_id = id_arg(ctx, "channel") }
end

local function has_selector(value)
  return value.user_id ~= nil or value.role_id ~= nil or value.channel_id ~= nil
end

local function scope_text(rule)
  local names = {
    g = "server", channel = "channel", role = "role", user = "user",
    role_channel = "role + channel", user_channel = "user + channel",
  }
  return names[rule.scope] or rule.scope or "unknown scope"
end

local function safe(value)
  return tostring(value or ""):gsub("@", "@\226\128\139"):gsub("[\r\n]", " "):sub(1, 120)
end

function Commands.register(router, engine)
  router:register({
    name = "permissions", category = "Administration", description = "Manage Molly command permission overrides",
    -- Keep Discord's existing command-level permission metadata during the
    -- schema migration. Router authorization still enforces Manage Server.
    permission = "manage_guild",
    molly_permission = false,
    options = {
      { type = 1, name = "allow", description = "Allow a user, role, channel or whole server", options = {
        option("command", "Registered Molly command name", 3, true),
        option("user", "Specific member", 6, false), option("role", "Specific role", 8, false),
        option("channel", "Specific channel", 7, false),
      } },
      { type = 1, name = "grant", description = "Grant an explicit allow override", options = {
        option("command", "Registered Molly command name", 3, true),
        option("user", "Specific member", 6, false), option("role", "Specific role", 8, false),
        option("channel", "Specific channel", 7, false),
      } },
      { type = 1, name = "deny", description = "Deny a user, role, channel or whole server", options = {
        option("command", "Registered Molly command name", 3, true),
        option("user", "Specific member", 6, false), option("role", "Specific role", 8, false),
        option("channel", "Specific channel", 7, false),
      } },
      { type = 1, name = "revoke", description = "Remove one override (or all overrides for a command)", options = {
        option("command", "Registered Molly command name", 3, true),
        option("user", "Specific member", 6, false), option("role", "Specific role", 8, false),
        option("channel", "Specific channel", 7, false),
      } },
      { type = 1, name = "reset", description = "Reset all Molly overrides for a command", options = {
        option("command", "Registered Molly command name", 3, true),
      } },
      { type = 1, name = "view", description = "Show the winning override for this context", options = {
        option("command", "Registered Molly command name", 3, true),
      } },
      { type = 1, name = "list", description = "List configured permission overrides", options = {
        option("command", "Optional command filter", 3, false),
      } },
    },
    execute = function(ctx)
      if not ctx.guild or not ctx.guild.id then
        ctx:respond("Permission overrides can only be managed in a server.", { ephemeral = true }); return
      end
      if not Response.defer(ctx, { ephemeral = true }) then return end
      local action = ctx.molly_subcommand
      local command = ctx:get_arg("command")
      if command ~= nil then command = type(command) == "string" and command:lower() or command end
      local result, ok, reason
      if action == "list" then
        local definition = command and router.commands[command]
        if command and not definition then ctx:edit("That is not a registered Molly command."); return end
        if definition and (definition.admin or definition.molly_permission == false or definition.category == "Developer") then
          ctx:edit("Developer and protected commands are outside the guild permission engine."); return
        end
        ok, result = engine:list(ctx.guild.id, command, 50)
        if not ok then ctx:edit("Permission rules are unavailable."); return end
        local lines = {}
        for _, rule in ipairs(result) do
          lines[#lines + 1] = string.format("%s · %s · %s · %s", safe(rule.command), safe(rule.effect),
            safe(scope_text(rule)), safe(rule.scope))
        end
        ctx:edit(#lines > 0 and table.concat(lines, "\n") or "No permission overrides are configured.")
        return
      end

      local definition = type(command) == "string" and router.commands[command] or nil
      if not definition then ctx:edit("Choose a registered Molly command."); return end
      if definition.admin or definition.molly_permission == false or definition.category == "Developer" then
        ctx:edit("Developer and protected commands are outside the guild permission engine."); return
      end
      local scope = selector(ctx)
      if scope.user_id and scope.role_id then ctx:edit("Choose a member or a role, not both."); return end
      local selected = has_selector(scope)

      if action == "allow" or action == "grant" or action == "deny" then
        ok, result = engine:set_rule(ctx.guild.id, command, scope, action == "deny" and "deny" or "allow")
        if not ok then
          local messages = { capacity = "The permission rule limit has been reached.", invalid_argument = "Choose only one member or role and a valid channel.",
            protected_command = "Developer and protected commands cannot be managed here." }
          ctx:edit(messages[result] or "Permission rule could not be saved."); return
        end
        ctx:edit(string.format("`%s` is now %s for the selected %s scope.", safe(command),
          action == "deny" and "denied" or "allowed", selected and "override" or "server"))
        return
      elseif action == "revoke" then
        ok, result = engine:reset(ctx.guild.id, command, selected and scope or nil)
      elseif action == "reset" then
        ok, result = engine:reset(ctx.guild.id, command)
      elseif action == "view" then
        ok, result = engine:resolve(ctx, command)
        if not ok then ctx:edit("Permission rules are unavailable."); return end
        if not result then ctx:edit("No explicit override wins here; Molly's normal command permissions apply."); return end
        ctx:edit(string.format("Winning rule for `%s`: **%s** at %s scope (`%s`).", safe(command),
          safe(result.effect), safe(scope_text(result)), safe(result.key)))
        return
      else
        ctx:edit("Choose allow, grant, deny, revoke, reset, view, or list."); return
      end
      if not ok then ctx:edit("Permission rules are unavailable."); return end
      if not result then ctx:edit("No matching permission override existed."); return end
      ctx:edit(action == "reset" and ("All Molly overrides for `" .. safe(command) .. "` were reset.")
        or (selected and "The selected Molly override was revoked." or ("All Molly overrides for `" .. safe(command) .. "` were revoked.")))
    end,
  })
end

return Commands
