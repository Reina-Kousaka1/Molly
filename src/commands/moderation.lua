local Permissions = require("src.discord.permissions")
local Hierarchy = require("src.moderation.hierarchy")
local Purge = require("src.moderation.purge")
local RolePolicy = require("src.discord.role_policy")
local Store = require("src.persistence.guild_store")
local Response = require("src.discord.response")
local Embeds = require("src.discord.embeds")
local Moderation = {}
local private_responses = {
  warn = true, hackban = true, delete = true, warnings = true, case = true, cases = true, modlogs = true,
  reason = true, delwarn = true, modlog = true,
}

local function text(value) return tostring(value or ""):gsub("@", "@\226\128\139"):gsub("[\r\n]", " "):sub(1, 500) end
local function option(name, description, kind, required)
  return { name = name, description = description, type = kind, required = required }
end
local function summary(c)
  local when = type(c.timestamp) == "number" and os.date("!%Y-%m-%d %H:%M UTC", c.timestamp) or "unknown time"
  return string.format("%s · %s · user %s · moderator %s · %s · %s · %s", text(c.id), text(c.action), text(c.target), text(c.moderator),
    c.status or (c.active and "active" or "removed"), when, text(c.reason):sub(1, 100))
end

local function has_guild_permission(ctx, permission)
  if ctx.source ~= "message" then return Permissions.has(ctx.member and ctx.member.permissions, permission) end
  if not ctx.bot or not ctx.bot.rest or not ctx.guild or not ctx.author then return false end
  local allowed = RolePolicy.member_has_permission(ctx.bot.rest, ctx.guild.id, ctx.author.id, permission)
  return allowed == true
end

local function bot_has_permission(ctx, permission)
  if ctx.app_permissions ~= nil then return Permissions.has(ctx.app_permissions, permission) end
  local bot_id = ctx.bot and ctx.bot.user and ctx.bot.user.id
  if not ctx.bot or not ctx.bot.rest or not Store.valid_id(bot_id) then return false end
  local allowed = RolePolicy.member_has_permission(ctx.bot.rest, ctx.guild.id, bot_id, permission)
  return allowed == true
end

function Moderation.register(router, cases, options)
  options = options or {}
  local purge = options.purge or Purge.new({ clock = options.clock })
  local function audit(ctx, action, item)
    if options.logs and item then
      options.logs:record(ctx.guild.id, "moderation", action .. " case " .. text(item.id)
        .. " for user " .. text(item.target) .. " by moderator " .. text(item.moderator))
    end
  end
  local function add(name, description, permission, command_options, fn, prefix)
    router:register({ name = name, description = description, category = "Moderation", permission = permission,
      default_member_permissions = Permissions.flags[permission], options = command_options, prefix = prefix,
      execute = function(ctx)
        if not ctx.guild or not ctx.author or not has_guild_permission(ctx, permission) then
          ctx:respond("You do not have permission to use this command.", { ephemeral = true }); return
        end
        if ctx.source == "message" then
          local ok, result = pcall(fn, ctx)
          ctx:respond(ok and (type(result) == "string" and result or "Molly could not complete the request.")
            or "Molly could not complete the request.")
          return
        end
        if not Response.defer(ctx, private_responses[name] and { ephemeral = true } or nil) then return end
        local ok, result = pcall(fn, ctx)
        ctx:edit(ok and result or "Molly could not complete the request.")
      end })
  end
  local function arg(ctx, name) return ctx:get_arg(name) end
  local function log(ctx, item)
    local ok, channel = cases:modlog(ctx.guild.id, "status")
    if not ok or channel == "" then return " Modlog channel is not configured." end
    local embed = Embeds.create("moderation", "Moderation case · " .. text(item.id), summary(item))
    local sent, message = pcall(ctx.bot.rest.send_message, ctx.bot.rest, channel, {
      embeds = { embed }, allowed_mentions = { parse = {} },
    })
    local confirmed = sent and type(message) == "table" and Store.valid_id(message.id)
    return confirmed and " Modlog sent." or " Case saved; modlog delivery was not confirmed."
  end
  add("delete", "Delete up to 100 recent messages from this channel", "manage_messages", {
    { name = "count", description = "Number of recent messages to delete (1-100)", type = 4,
      required = true, min_value = 1, max_value = 100 },
  }, function(ctx)
    local ok, deleted = purge:run(ctx, arg(ctx, "count"))
    if not ok then
      return deleted == "invalid_count" and "Choose between 1 and 100 messages (prefix alias .d supports up to 99)."
        or deleted == "bot_permission_denied" and "Molly needs Manage Messages in this channel."
        or "Molly could not verify or delete those messages. Only recent messages are eligible."
    end
    if options.logs and deleted > 0 then options.logs:record(ctx.guild.id, "moderation", "Message purge deleted " .. tostring(deleted) .. " recent messages.") end
    return deleted > 0 and ("Deleted " .. tostring(deleted) .. " recent messages.") or "No recent messages eligible for deletion."
  end, { arguments = { "count" }, aliases = { "d" } })
  add("warn",  "Record a warning for a server member", "manage_messages", {
    option("user", "Server member", 6, true), option("reason", "Reason for the warning", 3, true),
  }, function(ctx)
    local user = arg(ctx, "user")
    if not user or not Hierarchy.check(ctx, user.id) then return "Cannot verify the target's role hierarchy." end
    local ok, case = cases:warn(ctx.guild.id, ctx.author.id, user.id, arg(ctx, "reason"), ctx.interaction_id)
    if not ok then return "The warning was not confirmed; check cases before retrying." end
    audit(ctx, "Warning", case)
    return "Warning recorded: " .. summary(case) .. log(ctx, case)
  end)
  add("hackban", "Ban a user ID even if they are not a member", "ban_members", {
    option("user_id", "Discord user ID", 3, true), option("reason", "Reason for the ban", 3, true),
    option("confirm", "Confirm this ban", 5, true),
  }, function(ctx)
    local id, reason = arg(ctx, "user_id"), arg(ctx, "reason")
    if type(id) ~= "string" or #id < 17 or #id > 20 or not id:match("^[1-9]%d+$") or not Store.valid_id(id)
      or (#id == 20 and id > "18446744073709551615") then return "Invalid Discord user ID." end
    local confirmed = arg(ctx, "confirm") == true or (ctx.source == "message" and arg(ctx, "confirm") == "confirm")
    if not confirmed then return "Ban cancelled: explicit confirmation is required." end
    if type(reason) ~= "string" or #reason == 0 or #reason > 500 or not reason:match("%S") then return "Provide a reason of at most 500 characters." end
    if not bot_has_permission(ctx, "ban_members") then return "Molly lacks the required ban permission." end
    if id == ctx.author.id or (ctx.bot.user and id == ctx.bot.user.id) then return "Cannot ban that user." end
    local guild_ok, guild = pcall(ctx.bot.rest.get_guild, ctx.bot.rest, ctx.guild.id)
    if not guild_ok or type(guild) ~= "table" or not Store.valid_id(guild.owner_id) or id == guild.owner_id then return "Cannot verify the server owner." end
    local member_ok, member = pcall(ctx.bot.rest.get_member, ctx.bot.rest, ctx.guild.id, id)
    if member_ok then
      if type(member) ~= "table" or not Hierarchy.check(ctx, id) then return "Cannot verify the target's role hierarchy." end
    elseif type(member) ~= "table" or member.code ~= 10007 then
      return "Cannot verify whether that user is a server member."
    end
    local recorded, result = cases:pending(ctx.guild.id, ctx.author.id, id, reason,
      ctx.interaction_id or ctx.request_id, "hackban")
    if not recorded then return "No ban was sent because the case could not be recorded." end
    local case = result.case
    if not result.fresh then return "This interaction was already recorded as " .. summary(case) .. "; no ban was repeated." end
    local sent = pcall(ctx.bot.rest.ban, ctx.bot.rest, ctx.guild.id, id, 0, reason)
    local verified, ban = false, nil
    if sent then verified, ban = pcall(ctx.bot.rest.get_ban, ctx.bot.rest, ctx.guild.id, id) end
    local confirmed = verified and type(ban) == "table" and type(ban.user) == "table" and ban.user.id == id
    local saved, updated = cases:finish(ctx.guild.id, case.id, confirmed and "completed" or "unknown")
    if not saved then
      return confirmed and ("Discord confirms the ban, but case " .. case.id .. " needs reconciliation.")
        or ("Ban outcome is unknown; case " .. case.id .. " needs reconciliation. Do not retry blindly.")
    end
    if not confirmed then return "Ban outcome is unknown; review case " .. case.id .. " before retrying." end
    audit(ctx, "Ban", updated)
    return "Discord confirms the ban: " .. summary(updated) .. log(ctx, updated)
  end, { arguments = { "confirm", "user_id", "reason" }, aliases = { "hb" } })
  add("warnings", "Show recent warnings for a member", "manage_messages", { option("user", "Server member", 6, true) }, function(ctx)
    local user = arg(ctx, "user")
    if not user or not Store.valid_id(user.id) then return "Choose a valid server member." end
    local ok, list = cases:list(ctx.guild.id, user and user.id)
    if not ok then return "Warnings are unavailable." end
    local lines = {}; for _, item in ipairs(list) do if item.action == "warn" then lines[#lines + 1] = summary(item) end end
    return #lines == 0 and "No warnings found." or table.concat(lines, "\n")
  end)
  add("case", "Show a moderation case", "manage_messages", { option("id", "Molly case ID, for example C1", 3, true) }, function(ctx)
    local ok, item = cases:get(ctx.guild.id, arg(ctx, "id"))
    return ok and summary(item) or "Case not found or unavailable."
  end)
  local function list(ctx)
    local ok, items = cases:list(ctx.guild.id)
    if not ok then return "Cases are unavailable." end
    local lines = {}; for _, item in ipairs(items) do lines[#lines + 1] = summary(item) end
    return #lines == 0 and "No cases yet." or table.concat(lines, "\n")
  end
  add("cases", "Show recent moderation cases", "manage_messages", nil, list)
  add("modlogs", "Show recent moderation cases", "manage_messages", nil, list)
  add("reason", "Change a case reason", "manage_messages", {
    option("id", "Molly case ID", 3, true), option("reason", "New reason", 3, true),
  }, function(ctx)
    local ok, case = cases:edit(ctx.guild.id, arg(ctx, "id"), ctx.author.id, "reason", arg(ctx, "reason"))
    if ok then audit(ctx, "Case reason updated", case) end
    return ok and ("Case updated: " .. summary(case) .. log(ctx, case)) or "Case update was not confirmed."
  end)
  add("delwarn", "Remove an active warning", "manage_messages", { option("id", "Molly case ID", 3, true) }, function(ctx)
    local found, case = cases:get(ctx.guild.id, arg(ctx, "id"))
    if not found or not Hierarchy.check(ctx, case.target) then return "Cannot verify the case or target hierarchy." end
    local ok, updated = cases:edit(ctx.guild.id, case.id, ctx.author.id, "remove")
    if ok then audit(ctx, "Warning removed", updated) end
    return ok and ("Warning removed: " .. summary(updated) .. log(ctx, updated)) or "Warning removal was not confirmed."
  end)
  add("modstats", "Show recent moderation case counts", "manage_messages", nil, function(ctx)
    local ok, items = cases:list(ctx.guild.id)
    if not ok then return "Moderation statistics are unavailable." end
    local active = 0; for _, item in ipairs(items) do if item.active then active = active + 1 end end
    return string.format("Last %d cases: %d active.", #items, active)
  end)
  add("modlog", "Configure the moderation log channel", "manage_guild", {
    { name = "set", description = "Select a log channel", type = 1, options = { option("channel", "Log channel", 7, true) } },
    { name = "disable", description = "Disable log delivery", type = 1 },
    { name = "status", description = "Show the configured channel", type = 1 },
  }, function(ctx)
    local mode, selected = ctx.molly_subcommand, arg(ctx, "channel")
    if mode == "set" then
      local ok, channel = pcall(ctx.bot.rest.get_channel, ctx.bot.rest, selected and selected.id)
      if not ok or type(channel) ~= "table" or channel.guild_id ~= ctx.guild.id or (channel.type ~= 0 and channel.type ~= 5) then
        return "Choose a text channel in this server."
      end
    end
    local ok, channel = cases:modlog(ctx.guild.id, mode, selected and selected.id)
    if not ok then return "Modlog configuration was not confirmed." end
    if mode ~= "status" and options.logs then options.logs:record(ctx.guild.id, "settings", "Moderation modlog settings updated.") end
    return channel == "" and "Modlog delivery is disabled." or ("Modlog channel ID: " .. text(channel))
  end)
end

return Moderation
