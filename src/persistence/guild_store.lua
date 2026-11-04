local Store = {}
Store.__index = Store

local function valid_id(value)
  return type(value) == "string" and #value >= 1 and #value <= 20 and value:match("^%d+$") ~= nil
end

local function persistence_error(reason)
  if reason == "resource_limit" or reason == "outcome_unknown" or reason == "serialization_failed" then
    return reason
  end
  return "unavailable"
end

function Store.new(connector)
  return setmetatable({ connector = connector, busy_guilds = {} }, Store)
end

-- The transport's transactions are connection-bound and do not support query.
-- A guild gets one collection and exactly one immutable document ID. The ID is
-- located first, then the document is read again *inside* the transaction.
function Store:run(guild_id, fn)
  if not valid_id(guild_id) then return false, "invalid_guild" end
  if self.busy_guilds[guild_id] then return false, "busy" end
  self.busy_guilds[guild_id] = true
  local c, collection
  local session_ok, session, session_reason = pcall(self.connector.session, self.connector)
  if session_ok and session then
    c = session
  else
    self.busy_guilds[guild_id] = nil
    return false, session_ok and (session_reason or "capability_unavailable") or "unavailable"
  end
  collection = "molly_g_" .. guild_id
  local commit_attempted = false
  local function work()
    local found, rows = c:query({ collection = collection, limit = 2 })
    local missing = not found and rows == "not_found"
    if not found and not missing then return false, persistence_error(rows) end
    if found and (type(rows.rows) ~= "table" or #rows.rows ~= 1) then return false, "invalid_store" end
    local started, begin_reason = c:begin()
    if not started then return false, persistence_error(begin_reason) end
    local id, data
    if missing then
      local created, create_reason = c:create_collection({ collection = collection })
      if not created then return false, persistence_error(create_reason) end
      data = { guild = guild_id, accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {}, next_case = 1 }
      local inserted, result = c:insert({ collection = collection, document = { data = data } })
      if not inserted or type(result) ~= "table" or not result.id then
        return false, persistence_error(result)
      end
      id = result.id
    else
      id = rows.rows[1].id
      local read, result = c:get({ collection = collection, id = id })
      if not read then return false, persistence_error(result) end
      if type(result) ~= "table" or type(result.document) ~= "table" or type(result.document.data) ~= "table" then
        return false, "invalid_store"
      end
      data = result.document.data
    end
    if data.guild ~= guild_id or type(data.accounts) ~= "table" or type(data.cases) ~= "table"
      or type(data.staff) ~= "table" or type(data.journal) ~= "table" or type(data.receipts) ~= "table" then
      return false, "invalid_store"
    end
    local ok, result, changed = fn(data)
    if not ok then return false, result end
    if changed then
      local updated, update = c:update({ collection = collection, id = id, set = { data = data } })
      if not updated then return false, persistence_error(update) end
      if type(update) ~= "table" or update.updated ~= true then return false, "unavailable" end
    end
    commit_attempted = true
    local commit_call_ok, committed = pcall(c.commit, c)
    if not commit_call_ok or not committed then return false, "outcome_unknown" end
    return true, result
  end
  local ok, success, result = pcall(work)
  local rollback_failed = false
  if not commit_attempted and c.in_transaction then
    local rollback_ok, rolled_back = pcall(c.rollback, c)
    rollback_failed = not rollback_ok or not rolled_back
  end
  pcall(c.close, c)
  self.busy_guilds[guild_id] = nil
  if rollback_failed then return false, "outcome_unknown" end
  if not ok then return false, "unavailable" end
  return success, result
end

Store.valid_id = valid_id
return Store
