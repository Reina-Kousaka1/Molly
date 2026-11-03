local Response = require("src.discord.response")
local Admin = {}

local function user_id(ctx, name)
  local value = ctx:get_arg(name)
  return type(value) == "table" and value.id or value
end
local function channel_id(ctx)
  return (ctx.channel and ctx.channel.id) or ctx.channel_id or (ctx.interaction and ctx.interaction.channel_id)
end
local function owner_only(owners, ctx)
  return ctx.author and ctx.author.id and owners[ctx.author.id] == true
end
local function private(ctx, text)
  if ctx._molly_deferred then return ctx:edit(text) end
  return ctx:respond(text, { ephemeral = true })
end
local function safe(value)
  value = tostring(value == nil and "n/a" or value)
  if #value > 500 then value = value:sub(1, 500) .. "…" end
  return value
end

function Admin.register(router, options)
  local owners, blacklist, developer, lifecycle = options.owners, options.blacklist, options.developer, options.lifecycle
  local function register(def) def.admin = true; router:register(def) end

  register({ name = "blacklist", category = "Developer", description = "Manage Molly's global blacklist", options = {
    { name = "add", description = "Add a user", type = 1, options = {
      { name = "user", description = "User", type = 6, required = true },
      { name = "reason", description = "Reason", type = 3, required = true, max_length = 500 }, } },
    { name = "remove", description = "Remove a user", type = 1, options = { { name = "user", description = "User", type = 6, required = true } } },
    { name = "check", description = "Check a user", type = 1, options = { { name = "user", description = "User", type = 6, required = true } } },
  }, execute = function(ctx)
    if not owner_only(owners, ctx) then return private(ctx, "This command is restricted to configured Molly developers.") end
    local target, action = user_id(ctx, "user"), ctx.molly_subcommand
    local ok, result
    if action == "add" then ok, result = blacklist:add(target, ctx:get_arg("reason"), ctx.author.id, ctx.interaction_id)
    elseif action == "remove" then ok, result = blacklist:remove(target, ctx.author.id, ctx.interaction_id)
    elseif action == "check" then ok, result = blacklist:check(target)
    else return private(ctx, "Unknown blacklist operation.") end
    if not ok then return private(ctx, "Blacklist operation failed: " .. safe(result)) end
    if action == "check" then
      if not result then return private(ctx, "User " .. safe(target) .. " is not globally blacklisted.") end
      return private(ctx, string.format("User %s is blacklisted.\nReason: %s\nAdded: %s UTC\nBy developer: %s", safe(target), safe(result.reason), os.date("!%Y-%m-%d %H:%M", result.created_at), safe(result.actor)))
    end
    return private(ctx, "Blacklist " .. action .. " completed for user " .. safe(target) .. ".")
  end })

  local user_option = { name = "user", description = "User", type = 6, required = true }
  register({ name = "eval", category = "Developer", description = "Read-only Molly developer inspector", options = {
    { name = "db-user", description = "Inspect economy user", type = 1, options = { user_option } },
    { name = "db-balance", description = "Inspect balance", type = 1, options = { user_option } },
    { name = "db-transactions", description = "Inspect recent transactions", type = 1, options = { user_option, { name = "limit", description = "1-20", type = 4, required = false, min_value = 1, max_value = 20 } } },
    { name = "db-transaction", description = "Inspect one transaction", type = 1, options = { { name = "id", description = "Transaction reference", type = 3, required = true, max_length = 32 } } },
    { name = "db-inventory", description = "Inspect inventory availability", type = 1, options = { user_option } },
    { name = "guild", description = "Inspect current guild store summary", type = 1 },
    { name = "cooldowns", description = "Inspect reward cooldown timestamps", type = 1, options = { user_option } },
    { name = "tree", description = "Show safe Molly component tree", type = 1 },
    { name = "runtime", description = "Show safe runtime metadata", type = 1 },
    { name = "errors", description = "Show error-buffer availability", type = 1 },
    { name = "seaworld", description = "Show SeaWorld status", type = 1 },
  }, execute = function(ctx)
    if not owner_only(owners, ctx) then return private(ctx, "This command is restricted to configured Molly developers.") end
    if not ctx.guild or not ctx.guild.id then return private(ctx, "This inspector currently requires a guild context.") end
    local op, guild, target = ctx.molly_subcommand, ctx.guild.id, user_id(ctx, "user")
    local ok, result
    if op == "db-user" then ok, result = developer:user(guild, target)
    elseif op == "db-balance" then ok, result = developer:balance(guild, target)
    elseif op == "db-transactions" then ok, result = developer:transactions(guild, target, ctx:get_arg("limit"))
    elseif op == "db-transaction" then ok, result = developer:transaction(guild, ctx:get_arg("id"))
    elseif op == "db-inventory" then ok, result = developer:inventory(guild, target)
    elseif op == "guild" then ok, result = developer:guild(guild)
    elseif op == "cooldowns" then ok, result = developer:cooldowns(guild, target)
    elseif op == "tree" then ok, result = developer:tree()
    elseif op == "runtime" then ok, result = developer:runtime()
    elseif op == "errors" then ok, result = developer:errors()
    elseif op == "seaworld" then ok, result = developer:seaworld_status()
    else return private(ctx, "Unknown inspector operation.") end
    if not ok then return private(ctx, "Inspector result unavailable: " .. safe(result)) end
    if op == "db-transactions" then
      local lines = { "Recent transactions — User " .. safe(target) }
      for _, entry in ipairs(result) do lines[#lines + 1] = string.format("%s %s %+.0f", safe(entry.id), safe(entry.kind):upper(), entry.amount or 0) end
      return private(ctx, table.concat(lines, "\n"))
    elseif op == "db-transaction" then
      return private(ctx, string.format("Transaction %s\nGuild: %s\nUser: %s\nKind: %s\nAmount: %s\nCounterparty: %s\nTimestamp: %s UTC\nStatus: %s", safe(result.id), safe(result.guild), safe(result.user), safe(result.kind), safe(result.amount), safe(result.counterparty), os.date("!%Y-%m-%d %H:%M", result.timestamp), safe(result.status)))
    elseif op == "tree" then return private(ctx, table.concat(result, "\n")) end
    local lines = {}; for key, value in pairs(result) do lines[#lines + 1] = safe(key) .. ": " .. safe(value) end; table.sort(lines)
    return private(ctx, table.concat(lines, "\n"))
  end })

  register({ name = "observe", category = "Developer", description = "Inspect bounded, non-sensitive Molly runtime metrics", options = {
    { name = "metrics", description = "Show command call counts and response timings", type = 1 },
    { name = "runtime", description = "Show runtime version and uptime", type = 1 },
    { name = "seaworld", description = "Show persistence service health", type = 1 },
  }, execute = function(ctx)
    if not owner_only(owners, ctx) then return private(ctx, "This command is restricted to configured Molly developers.") end
    if not Response.defer(ctx, { ephemeral = true }) then return end
    local action = ctx.molly_subcommand
    local ok, result
    if action == "metrics" then ok, result = developer:observability()
    elseif action == "runtime" then ok, result = developer:runtime()
    elseif action == "seaworld" then ok, result = developer:seaworld_status()
    else return private(ctx, "Choose metrics, runtime, or seaworld.") end
    if not ok then return private(ctx, "Observability data is unavailable: " .. safe(result)) end
    if action == "metrics" then
      local totals = result.totals or {}
      local lines = { string.format("Command metrics · process uptime %ds", math.floor((result.uptime_ms or 0) / 1000)),
        string.format("Calls: %d · succeeded: %d · denied: %d · failed: %d · total handler time: %dms",
          totals.calls or 0, totals.succeeded or 0, totals.denied or 0, totals.failed or 0, totals.duration_ms or 0) }
      local limit = math.min(12, #(result.commands or {}))
      for index = 1, limit do
        local row = result.commands[index]
        local value = row.metrics or {}
        lines[#lines + 1] = string.format("%s: %d calls · %d denied · %d failed · max %dms",
          safe(row.name), value.calls or 0, value.denied or 0, value.failed or 0, value.max_duration_ms or 0)
      end
      if #(result.commands or {}) > limit then lines[#lines + 1] = "Additional command counters omitted." end
      return private(ctx, table.concat(lines, "\n"))
    elseif action == "runtime" then
      return private(ctx, string.format("Lua: %s\nUptime: %ss", safe(result.lua), safe(result.uptime)))
    end
    return private(ctx, string.format("SeaWorld: %s\nDetail: %s\nAPI: %s", safe(result.status), safe(result.detail), safe(result.api_version)))
  end })

  local function lifecycle_command(name)
    register({ name = name, category = "Developer", description = name == "shutdown" and "Shut Molly down cleanly" or (name == "restart" and "Restart Molly cleanly" or "Request a controlled Molly update"),
      options = { { name = "reason", description = "Optional reason", type = 3, required = false, max_length = 200 } }, execute = function(ctx)
        if not owner_only(owners, ctx) then return private(ctx, "This command is restricted to configured Molly developers.") end
        if not Response.defer(ctx, { ephemeral = true }) then return end
        if name == "shutdown" then
          ctx:edit("Shutdown accepted. Molly is closing cleanly.")
          return options.terminate("shutdown")
        end
        if name == "update" and not options.updater then return ctx:edit("Update service unavailable/not configured.") end
        local ok, marker = lifecycle:request(name, { interaction_id = ctx.interaction_id, guild_id = ctx.guild and ctx.guild.id,
          channel_id = channel_id(ctx), requester_id = ctx.author.id, reason = ctx:get_arg("reason") })
        if not ok then return ctx:edit("Lifecycle request rejected: " .. safe(marker)) end
        if name == "update" then
          local requested, reason = options.updater:request(marker)
          if not requested then lifecycle:cancel(marker.interaction_id); return ctx:edit("Update request failed safely: " .. safe(reason)) end
        end
        ctx:edit(name == "restart" and "Restart accepted. Molly is closing cleanly." or "Update accepted. Molly is handing off to the configured updater.")
        return options.terminate(name)
      end })
  end
  lifecycle_command("shutdown"); lifecycle_command("restart"); lifecycle_command("update")
end

return Admin
