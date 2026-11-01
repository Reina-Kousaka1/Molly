local Blacklist = {}
Blacklist.__index = Blacklist

local function valid_id(value)
  return type(value) == "string" and value:match("^%d+$") ~= nil and #value <= 20
end

function Blacklist.new(store, clock)
  return setmetatable({ store = store, clock = clock or os.time }, Blacklist)
end

function Blacklist:check(user_id)
  if not valid_id(user_id) then return false, "invalid_user" end
  return self.store:run("blacklist", { entries = {}, receipts = {} }, function(data)
    if type(data.entries) ~= "table" or type(data.receipts) ~= "table" then return false, "invalid_store" end
    return true, data.entries[user_id], false
  end)
end

function Blacklist:add(user_id, reason, actor_id, interaction_id)
  if not valid_id(user_id) or not valid_id(actor_id) or not valid_id(interaction_id) then return false, "invalid_user" end
  reason = type(reason) == "string" and reason:match("^%s*(.-)%s*$") or ""
  if reason == "" or #reason > 500 then return false, "invalid_reason" end
  return self.store:run("blacklist", { entries = {}, receipts = {} }, function(data)
    if type(data.entries) ~= "table" or type(data.receipts) ~= "table" then return false, "invalid_store" end
    if data.receipts[interaction_id] then return true, data.receipts[interaction_id], false end
    local entry = { user = user_id, reason = reason, created_at = self.clock(), actor = actor_id }
    data.entries[user_id] = entry
    data.receipts[interaction_id] = { action = "add", user = user_id }
    return true, entry, true
  end)
end

function Blacklist:remove(user_id, actor_id, interaction_id)
  if not valid_id(user_id) or not valid_id(actor_id) or not valid_id(interaction_id) then return false, "invalid_user" end
  return self.store:run("blacklist", { entries = {}, receipts = {} }, function(data)
    if type(data.entries) ~= "table" or type(data.receipts) ~= "table" then return false, "invalid_store" end
    if data.receipts[interaction_id] then return true, data.receipts[interaction_id], false end
    local existed = data.entries[user_id] ~= nil
    data.entries[user_id] = nil
    data.receipts[interaction_id] = { action = "remove", user = user_id, existed = existed }
    return true, { user = user_id, existed = existed }, true
  end)
end

return Blacklist
