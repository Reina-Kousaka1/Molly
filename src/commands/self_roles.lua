local Store = require("src.persistence.guild_store")
local Permissions = require("src.discord.permissions")
local Util = require("src.commands.community_util")

local Commands = {}

local function role_name_map(rest, guild)
  if not rest or type(rest.get_roles) ~= "function" then return {} end
  local ok, roles = pcall(rest.get_roles, rest, guild)
  if not ok or type(roles) ~= "table" then return {} end
  local result = {}
  for _, role in ipairs(roles) do
    if type(role) == "table" and Store.valid_id(role.id) then result[role.id] = Util.safe(role.name, 80) end
  end
  return result
end

local function role_options(action)
  return { type = 1, name = action, description = action == "join" and "Assign an available role to yourself"
      or action == "leave" and "Remove an available role from yourself"
      or action == "allow" and "Allow a safe role for self-assignment" or "Remove a role from the self-assignment list",
    options = { Util.option("role", "Role", 8, true) } }
end

function Commands.register(router, service, options)
  options = options or {}
  router:register({
    name = "selfroles", category = "Utility", description = "List, assign, or configure safe self-service roles",
    options = {
      { type = 1, name = "list", description = "List available self-service roles" },
      role_options("join"), role_options("leave"), role_options("allow"), role_options("disallow"),
    },
    execute = function(ctx)
      local guild = ctx.guild and ctx.guild.id
      if not Store.valid_id(guild) then ctx:respond("This command requires a server.", { ephemeral = true }); return end
      if not Util.defer(ctx) then return end
      local action = ctx.molly_subcommand
      if action == "list" then
        local ok, config = service:list(guild)
        if not ok then Util.reply(ctx, "Self-service roles are unavailable."); return end
        if #config.self_assignable == 0 then Util.reply(ctx, "No self-service roles are configured."); return end
        local names = role_name_map(ctx.bot and ctx.bot.rest, guild)
        local lines = {}
        for i, id in ipairs(config.self_assignable) do
          if i <= 20 then lines[#lines + 1] = (names[id] or "Role") .. " (`" .. id .. "`)" end
        end
        if #config.self_assignable > 20 then lines[#lines + 1] = "…and " .. tostring(#config.self_assignable - 20) .. " more." end
        Util.reply(ctx, "Self-service roles:\n" .. table.concat(lines, "\n"))
        return
      end

      local role_id = Util.id(Util.arg(ctx, "role"))
      if not Store.valid_id(role_id) then Util.reply(ctx, "Choose a valid server role."); return end
      local bot_id = ctx.bot and ctx.bot.user and ctx.bot.user.id
      if action == "allow" or action == "disallow" then
        if not Util.is_manager(ctx) then Util.reply(ctx, "You need Manage Server to configure self-service roles."); return end
        if not Store.valid_id(bot_id) then Util.reply(ctx, "Role management is unavailable."); return end
        local ok, result = service:set_allowed(guild, ctx.author and ctx.author.id, role_id, action == "allow", bot_id)
        if not ok then
          local message = result == "dangerous_role" and "Roles with powerful moderation or management permissions cannot be self-assigned."
            or result == "managed_role" and "Managed integration roles cannot be self-assigned."
            or result == "everyone_role" and "The everyone role cannot be self-assigned."
            or result == "actor_hierarchy" and "Your highest role must be above the selected role."
            or result == "bot_hierarchy" and "Molly's highest role must be above the selected role."
            or result == "bot_missing_manage_roles" and "Molly needs Manage Roles to configure this role."
            or "The role could not be configured."
          Util.reply(ctx, message)
          return
        end
        if options.logs then options.logs:record(guild, "settings", "Self-service role configuration updated.") end
        Util.reply(ctx, action == "allow" and "Role added to the self-service list." or "Role removed from the self-service list.")
        return
      elseif action == "join" or action == "leave" then
        if not Store.valid_id(bot_id) then Util.reply(ctx, "Role management is unavailable."); return end
        if not Permissions.has(ctx.app_permissions, "manage_roles") then
          Util.reply(ctx, "Molly needs the Manage Roles permission in this server."); return
        end
        local ok, result = service:assign(guild, ctx.author and ctx.author.id, role_id, action == "join", bot_id)
        if not ok then
          local message = result == "role_not_available" and "That role is not available for self-assignment."
            or result == "bot_hierarchy" and "Molly's highest role must be above the selected role."
            or result == "dangerous_role" and "This role cannot be self-assigned."
            or result == "managed_role" and "Managed integration roles cannot be self-assigned."
            or result == "bot_missing_manage_roles" and "Molly needs Manage Roles to assign roles."
            or "The role could not be updated."
          Util.reply(ctx, message)
          return
        end
        local text = result == "already_has_role" and "You already have that role."
          or result == "already_removed" and "You do not have that role." or action == "join" and "Role assigned." or "Role removed."
        Util.reply(ctx, text)
        return
      end
      Util.reply(ctx, "Choose list, join, leave, allow, or disallow.")
    end,
  })
end

return Commands
