local GlobalStore = {}
GlobalStore.__index = GlobalStore

local function valid_name(value)
  return type(value) == "string" and value:match("^[a-z][a-z0-9_%-]*$") ~= nil and #value <= 48
end

function GlobalStore.new(connector)
  return setmetatable({ connector = connector, busy = {} }, GlobalStore)
end

function GlobalStore:run(name, defaults, fn)
  if not valid_name(name) or type(defaults) ~= "table" or type(fn) ~= "function" then return false, "invalid_argument" end
  if self.busy[name] then return false, "busy" end
  self.busy[name] = true
  local ok_session, c, reason = pcall(self.connector.session, self.connector)
  if not ok_session or not c then self.busy[name] = nil; return false, ok_session and (reason or "unavailable") or "unavailable" end
  local collection = "molly_global_" .. name
  local function work()
    local found, rows = c:query({ collection = collection, limit = 2 })
    local missing = not found and rows == "not_found"
    if not found and not missing then return false, "unavailable" end
    if found and (type(rows.rows) ~= "table" or #rows.rows ~= 1) then return false, "invalid_store" end
    if not c:begin() then return false, "unavailable" end
    local id, data
    if missing then
      if not c:create_collection({ collection = collection }) then return false, "unavailable" end
      data = {}
      for key, value in pairs(defaults) do data[key] = value end
      local inserted, result = c:insert({ collection = collection, document = { data = data } })
      if not inserted or not result.id then return false, "unavailable" end
      id = result.id
    else
      id = rows.rows[1].id
      local read, result = c:get({ collection = collection, id = id })
      if not read or type(result.document) ~= "table" or type(result.document.data) ~= "table" then return false, "unavailable" end
      data = result.document.data
    end
    local success, result, changed = fn(data)
    if not success then return false, result end
    if changed then
      local updated, update = c:update({ collection = collection, id = id, set = { data = data } })
      if not updated or update.updated ~= true then return false, "unavailable" end
    end
    if not c:commit() then return false, "outcome_unknown" end
    return true, result
  end
  local called, success, result = pcall(work)
  if c.in_transaction then pcall(c.rollback, c) end
  pcall(c.close, c)
  self.busy[name] = nil
  if not called then return false, "unavailable" end
  return success, result
end

return GlobalStore
