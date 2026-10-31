local Economy = {}
local Response = require("src.discord.response")
local messages = { invalid_user = "A valid server user is required.", invalid_target = "Choose another valid user.",
  invalid_amount = "Enter a positive whole amount, all, or max.", insufficient = "Insufficient funds.",
  overflow = "That amount would exceed the balance limit.", cooldown = "That reward is not available yet.",
  capacity = "The server economy has reached its current capacity.", busy = "Molly is processing another request. Try again shortly.",
  outcome_unknown = "The outcome could not be confirmed. Check your balance and transaction history before retrying.",
  unavailable = "Economy storage is unavailable.", invalid_store = "Economy storage requires administrator attention." }

local function finish(ctx, text) ctx:edit(text) end
local function arg(ctx, key) return ctx:get_arg(key) end

function Economy.register(router, ledger, options)
  options = options or {}
  local logger = options.logger
  local function add(name, category, description, handler, options)
    router:register({ name = name, category = category, description = description, options = options, execute = function(ctx)
      if not ctx.guild or not ctx.author or not ctx.author.id then
        ctx:respond("This command requires a server member.", { ephemeral = true }); return
      end
      if not Response.defer(ctx) then
        if logger then logger:error("economy_interaction_ack_failed", { command = name }) end
        pcall(ctx.respond, ctx, "Molly could not start that economy action. Please try again.", { ephemeral = true })
        return
      end
      local ok, text = pcall(handler, ctx, ctx.guild.id, ctx.author.id)
      if not ok then
        if logger then logger:error("economy_operation_failed", { command = name, stage = "handler" }) end
        text = "Molly could not complete the request."
      end
      finish(ctx, type(text) == "string" and text or "Molly could not complete the request.")
    end })
  end
  local function failed(reason) return messages[reason] or "Molly could not complete the request." end
  local function balance(ctx, guild, user)
    local ok, result = ledger:balance(guild, user)
    if not ok then return failed(result) end
    return string.format("Wallet: %.0f coins\nBank: %.0f coins\nTotal: %.0f coins", result.wallet, result.bank, result.wallet + result.bank)
  end
  add("balance", "Economy", "Show your wallet and bank balances", balance)
  add("bank", "Bank", "Show your bank and wallet balances", balance)
  local amount_option = { name = "amount", description = "Positive whole coins, all, or max", type = 3, required = true, max_length = 13 }
  local function change(kind)
    return function(ctx, guild, user)
      local target = arg(ctx, "user")
      local ok, result = ledger:change(guild, user, ctx.interaction_id, kind, arg(ctx, "amount"), target and target.id)
      if not ok then
        if logger and messages[result] then logger:warn("economy_operation_rejected", { command = kind, reason = result }) end
        return failed(result)
      end
      return string.format("%s: %.0f coins. Wallet: %.0f; bank: %.0f. Reference: %s", kind, result.amount, result.wallet, result.bank, result.id)
    end
  end
  add("deposit", "Bank", "Move coins from wallet to bank", change("deposit"), { amount_option })
  add("withdraw", "Bank", "Move coins from bank to wallet", change("withdraw"), { amount_option })
  add("pay", "Economy", "Pay another server user from your wallet", change("pay"), {
    { name = "user", description = "Recipient", type = 6, required = true }, amount_option,
  })
  for _, kind in ipairs({ "daily", "weekly", "work" }) do
    add(kind, "Economy", "Claim your " .. kind .. " reward", change(kind))
  end
  add("transactions", "Economy", "Show your latest economy transactions", function(_, guild, user)
    local ok, entries = ledger:history(guild, user)
    if not ok then return failed(entries) end
    local lines = {}
    for _, entry in ipairs(entries) do
      lines[#lines + 1] = string.format("%s · %s · %.0f coins · %s UTC", entry.id, entry.kind, entry.amount, os.date("!%Y-%m-%d %H:%M", entry.timestamp))
    end
    return #lines > 0 and table.concat(lines, "\n") or "No economy transactions yet."
  end)
  add("leaderboard", "Economy", "Show the server's top balances", function(_, guild)
    local ok, entries = ledger:leaderboard(guild)
    if not ok then return failed(entries) end
    local lines = {}
    for index, entry in ipairs(entries) do lines[#lines + 1] = string.format("%d. User %s: %.0f coins", index, entry.user, entry.total) end
    return #lines > 0 and table.concat(lines, "\n") or "No balances yet."
  end)
end

return Economy
