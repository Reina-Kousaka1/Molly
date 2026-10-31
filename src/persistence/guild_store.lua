local Store = {}
Store.__index = Store

local function valid_id(value)
  return type(value) == "string" and #value >= 1 and #value <= 20 and value:match("^%d+$") ~= nil
end

function Store.new(connector)
  return setmetatable({
    connector = connector,
    guild_busy = {},
    transport_busy = false,
    transport_waiters = {},
  }, Store)
end

-- SeaWorld currently exposes a single connection-bound transaction at a time.
-- Keep that connection serial, but let independent guilds wait for their turn
-- instead of failing because another guild is using it.
local function acquire_transport(self, guild_id)
  if not self.transport_busy then
    self.transport_busy = true
    return true
  end

  local thread, is_main = coroutine.running()
  if not thread or is_main then return false, "busy" end
  self.transport_waiters[#self.transport_waiters + 1] = { thread = thread, guild_id = guild_id }
  local acquired, reason = coroutine.yield()
  if not acquired then return false, reason or "unavailable" end
  return true
end

local function release_transport(self)
  while #self.transport_waiters > 0 do
    local waiter = table.remove(self.transport_waiters, 1)
    if coroutine.status(waiter.thread) == "suspended" then
      local resumed = coroutine.resume(waiter.thread, true)
      if resumed then return end
    end
    self.guild_busy[waiter.guild_id] = nil
  end
  self.transport_busy = false
end

-- The transport's transactions are connection-bound and do not support query.
-- A guild gets one collection and exactly one immutable document ID. The ID is
-- located first, then the document is read again *inside* the transaction.
function Store:run(guild_id, fn)
  if not valid_id(guild_id) then return false, "invalid_guild" end
  if self.guild_busy[guild_id] then return false, "busy" end
  self.guild_busy[guild_id] = true
  local acquired, lock_error = acquire_transport(self, guild_id)
  if not acquired then
    self.guild_busy[guild_id] = nil
    return false, lock_error
  end
  local c, collection = self.connector, "molly_g_" .. guild_id
  local function work()
    local found, rows = c:query({ collection = collection, limit = 2 })
    local missing = not found and rows == "not_found"
    if not found and not missing then return false, "unavailable" end
    if found and (type(rows.rows) ~= "table" or #rows.rows ~= 1) then return false, "invalid_store" end
    local started = c:begin()
    if not started then return false, "unavailable" end
    local id, data
    if missing then
      local created = c:create_collection({ collection = collection })
      if not created then return false, "unavailable" end
      data = { guild = guild_id, accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {}, next_case = 1 }
      local inserted, result = c:insert({ collection = collection, document = { data = data } })
      if not inserted or not result.id then return false, "unavailable" end
      id = result.id
    else
      id = rows.rows[1].id
      local read, result = c:get({ collection = collection, id = id })
      if not read or type(result.document) ~= "table" or type(result.document.data) ~= "table" then return false, "unavailable" end
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
      if not updated or update.updated ~= true then return false, "unavailable" end
    end
    local committed = c:commit()
    if not committed then return false, "outcome_unknown" end
    return true, result
  end
  local ok, success, result = pcall(work)
  if c.in_transaction then pcall(c.rollback, c) end
  self.guild_busy[guild_id] = nil
  release_transport(self)
  if not ok then return false, "unavailable" end
  return success, result
end

Store.valid_id = valid_id
return Store
