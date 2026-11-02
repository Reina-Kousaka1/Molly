local Economy = {}
local Response = require("src.discord.response")
local Permissions = require("src.discord.permissions")
local Money = require("src.economy.money_format")
local messages = { invalid_user = "A valid server user is required.", invalid_target = "Choose another valid user.",
  invalid_amount = "Enter a positive whole amount, all, or max.", insufficient = "Insufficient funds.",
  overflow = "That amount would exceed the balance limit.", cooldown = "That reward is not available yet.",
  capacity = "The server economy has reached its current capacity.", busy = "Molly is processing another request. Try again shortly.",
  outcome_unknown = "The outcome could not be confirmed. Check your balance and transaction history before retrying.",
  unavailable = "Economy storage is unavailable.", invalid_store = "Economy storage requires administrator attention." }

local function finish(ctx, text) ctx:edit(text) end
local function arg(ctx, key) return ctx:get_arg(key) end
local function safe(value)
  return tostring(value or ""):gsub("@", "@\226\128\139"):gsub("[\r\n]", " "):sub(1, 120)
end

function Economy.register(router, ledger, options)
  options = options or {}
  local logger = options.logger
  local function add(name, category, description, handler, options, prefix_arguments)
    local prefix = nil
    if prefix_arguments then
      if prefix_arguments.arguments then prefix = prefix_arguments
      else prefix = { arguments = prefix_arguments } end
    end
    local definition = { name = name, category = category, description = description, options = options,
      prefix = prefix, execute = function(ctx)
      if not ctx.guild or not ctx.author or not ctx.author.id then
        ctx:respond("This command requires a server member.", { ephemeral = true }); return
      end
      if ctx.source == "message" then
        local ok, text = pcall(handler, ctx, ctx.guild.id, ctx.author.id)
        if not ok then
          if logger then logger:error("economy_operation_failed", { command = name, stage = "handler" }) end
          text = "Molly could not complete the request."
        end
        ctx:respond(type(text) == "string" and text or "Molly could not complete the request.")
        return
      end
      local acknowledged, ack_error = Response.defer(ctx)
      if not acknowledged then
        if logger then logger:error("economy_interaction_ack_failed", { command = name, reason = ack_error }) end
        pcall(ctx.respond, ctx, "Molly could not start that economy action. Please try again.", { ephemeral = true })
        return
      end
      local ok, text = pcall(handler, ctx, ctx.guild.id, ctx.author.id)
      if not ok then
        if logger then logger:error("economy_operation_failed", { command = name, stage = "handler" }) end
        text = "Molly could not complete the request."
      end
      finish(ctx, type(text) == "string" and text or "Molly could not complete the request.")
    end }
    router:register(definition)
  end
  local function failed(reason) return messages[reason] or "Molly could not complete the request." end
  local function money(guild) return Money.formatter(options.settings, guild) end
  local function balance(ctx, guild, user)
    local ok, result = ledger:balance(guild, user)
    if not ok then return failed(result) end
    local format = money(guild)
    return string.format("Wallet: %s\nBank: %s\nTotal: %s", format(result.wallet), format(result.bank), format(result.wallet + result.bank))
  end
  add("balance", "Economy", "Show your wallet and bank balances", balance, nil, { arguments = {}, aliases = { "money" } })
  add("bank", "Bank", "Show your bank and wallet balances", balance, nil, {})
  local amount_option = { name = "amount", description = "Positive whole coins, all, or max", type = 3, required = true, max_length = 13 }
  local function change(kind)
    return function(ctx, guild, user)
      local target = arg(ctx, "user")
      local request_id = ctx.request_id or ctx.interaction_id
      local ok, result = ledger:change(guild, user, request_id, kind, arg(ctx, "amount"), target and target.id, ctx.request_type)
      if not ok then
        if logger and messages[result] then logger:warn("economy_operation_rejected", { command = kind, reason = result }) end
        return failed(result)
      end
      local format = money(guild)
      return string.format("%s: %s. Wallet: %s; bank: %s.", kind, format(result.amount), format(result.wallet), format(result.bank))
    end
  end
  add("deposit", "Bank", "Move coins from wallet to bank", change("deposit"), { amount_option }, { "amount" })
  add("withdraw", "Bank", "Move coins from bank to wallet", change("withdraw"), { amount_option }, { "amount" })
  add("pay", "Economy", "Pay another server user from your wallet", change("pay"), {
    { name = "user", description = "Recipient", type = 6, required = true }, amount_option,
  }, { "user", "amount" })
  for _, kind in ipairs({ "daily", "weekly", "work" }) do
    add(kind, "Economy", "Claim your " .. kind .. " reward", change(kind), nil, {})
  end
  router:register({ name = "transaction", category = "Economy", description = "Look up a money transaction by ID",
    default_member_permissions = Permissions.flags.manage_guild,
    options = { { name = "id", description = "Money ID, for example Mbwi530hzprtq", type = 3, required = true, max_length = 21 } },
    execute = function(ctx)
      if not ctx.guild or not ctx.author or not Permissions.has(ctx.member and ctx.member.permissions, "manage_guild") then
        ctx:respond("You do not have permission to look up economy transactions.", { ephemeral = true }); return
      end
      if not Response.defer(ctx, { ephemeral = true }) then return end
      local id = arg(ctx, "id")
      local ok, entry = ledger:transaction(ctx.guild.id, id)
      if not ok then
        local text = entry == "invalid_transaction" and "Enter a Money ID such as Mabc123."
          or entry == "transaction_not_found" and "No matching transaction was found in this server."
          or failed(entry)
        finish(ctx, text)
        return
      end
      local lines = { "Money ID: " .. safe(entry.money_id or entry.id) }
      if entry.user then lines[#lines + 1] = "User ID: " .. safe(entry.user) end
      if entry.guild then lines[#lines + 1] = "Guild ID: " .. safe(entry.guild) end
      if entry.kind then lines[#lines + 1] = "Type: " .. safe(entry.kind) end
      if type(entry.amount) == "number" then lines[#lines + 1] = "Amount: " .. money(ctx.guild.id)(entry.amount) end
      if entry.counterparty and entry.counterparty ~= "" then lines[#lines + 1] = "Counterparty: " .. safe(entry.counterparty) end
      if type(entry.timestamp) == "number" then
        local valid_time, timestamp = pcall(os.date, "!%Y-%m-%d %H:%M UTC", entry.timestamp)
        if valid_time and timestamp then lines[#lines + 1] = "Timestamp: " .. timestamp end
      end
      if entry.status then lines[#lines + 1] = "Status: " .. safe(entry.status) end
      finish(ctx, table.concat(lines, "\n"))
    end })
  add("transactions", "Economy", "Show your latest economy transactions", function(_, guild, user)
    local ok, entries = ledger:history(guild, user)
    if not ok then return failed(entries) end
    local lines = {}
    local format = money(guild)
    for _, entry in ipairs(entries) do
      lines[#lines + 1] = string.format("%s · %s · %s · %s UTC", entry.money_id or entry.id, entry.kind, format(entry.amount), os.date("!%Y-%m-%d %H:%M", entry.timestamp))
    end
    return #lines > 0 and table.concat(lines, "\n") or "No economy transactions yet."
  end, nil, {})
  add("leaderboard", "Economy", "Show the server's top balances", function(_, guild)
    local ok, entries = ledger:leaderboard(guild)
    if not ok then return failed(entries) end
    local lines = {}
    local format = money(guild)
    for index, entry in ipairs(entries) do lines[#lines + 1] = string.format("%d. User %s: %s", index, entry.user, format(entry.total)) end
    return #lines > 0 and table.concat(lines, "\n") or "No balances yet."
  end, nil, {})

end

return Economy
