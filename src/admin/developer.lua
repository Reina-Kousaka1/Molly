local Developer = {}
Developer.__index = Developer

local function count(value) local n = 0; for _ in pairs(value or {}) do n = n + 1 end; return n end
local function valid_id(value) return type(value) == "string" and value:match("^%d+$") ~= nil and #value <= 20 end

function Developer.new(options)
  options = options or {}
  return setmetatable({ ledger = options.ledger, store = options.store, seaworld = options.seaworld,
    started_at = options.started_at, max_transactions = options.max_transactions or 20 }, Developer)
end

function Developer:balance(guild, user)
  return self.ledger:balance(guild, user)
end

function Developer:user(guild, user)
  return self.store:run(guild, function(data)
    local a = data.accounts[user]
    if not a then return true, { user = user, exists = false }, false end
    return true, { user = user, exists = true, wallet = a.wallet, bank = a.bank }, false
  end)
end

function Developer:transactions(guild, user, limit)
  limit = tonumber(limit) or 10
  limit = math.max(1, math.min(self.max_transactions, math.floor(limit)))
  return self.ledger:history(guild, user, limit)
end

function Developer:transaction(guild, transaction_id)
  return self.ledger:transaction(guild, transaction_id)
end

function Developer:inventory()
  return false, "inventory_not_available"
end

function Developer:cooldowns(guild, user)
  if not valid_id(user) then return false, "invalid_user" end
  return self.store:run(guild, function(data)
    local a = data.accounts[user] or {}
    return true, { daily = a.daily or 0, weekly = a.weekly or 0, work = a.work or 0 }, false
  end)
end

function Developer:guild(guild)
  return self.store:run(guild, function(data)
    return true, { guild = guild, accounts = count(data.accounts), cases = #data.cases, staff = count(data.staff),
      transactions = #data.journal }, false
  end)
end

function Developer:runtime()
  return true, { lua = _VERSION, uptime = self.started_at and math.max(0, os.time() - self.started_at()) or 0 }
end

function Developer:tree()
  return true, { "app", "commands", "economy", "moderation", "music", "persistence", "seaworld", "staff", "voice" }
end

function Developer:errors()
  return false, "error_buffer_not_available"
end

function Developer:seaworld_status()
  local state = self.seaworld:get_state()
  return true, { status = state.status, detail = state.detail, api_version = state.api_version }
end

return Developer
