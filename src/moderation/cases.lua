local Store = require("src.persistence.guild_store")
local Cases = {}
Cases.__index = Cases
local function parse(id)
  if type(id) ~= "string" or not id:match("^C%d+$") or #id > 15 then return nil end
  return tonumber(id:sub(2))
end
local function reason(value)
  return type(value) == "string" and #value >= 1 and #value <= 500 and value:match("%S") and value or nil
end
local function case_for_receipt(data, receipt)
  if type(receipt) ~= "table" then return nil end
  local id = receipt.case_id or receipt.id
  if not parse(id) then return nil end
  for _, item in ipairs(data.cases) do
    if item.id == id then
      if receipt.case_id == id then
        for key in pairs(receipt) do if key ~= "case_id" then return nil end end
        return item
      end
      if receipt.guild == item.guild and receipt.action == item.action and receipt.target == item.target
        and receipt.moderator == item.moderator and receipt.timestamp == item.timestamp then return item end
      return nil
    end
  end
  return nil
end
function Cases.new(store, clock) return setmetatable({ store = store, clock = clock or os.time }, Cases) end

function Cases:warn(guild, actor, target, text, request)
  if not Store.valid_id(actor) or not Store.valid_id(target) or not Store.valid_id(request) or not reason(text) then return false, "invalid_argument" end
  return self.store:run(guild, function(data)
    if data.receipts[request] then
      local case = case_for_receipt(data, data.receipts[request])
      if not case then return false, "invalid_store" end
      local changed = data.receipts[request].case_id ~= case.id
      if changed then data.receipts[request] = { case_id = case.id } end
      return true, case, changed
    end
    if #data.cases >= 1000 or type(data.next_case) ~= "number" or data.next_case < 1 or data.next_case > 9999999999999 then return false, "capacity" end
    local case = { id = "C" .. string.format("%.0f", data.next_case), guild = guild, action = "warn", target = target,
      moderator = actor, reason = text, timestamp = self.clock(), active = true }
    data.next_case = data.next_case + 1
    data.cases[#data.cases + 1] = case
    data.receipts[request] = { case_id = case.id }
    return true, case, true
  end)
end

-- Record intent before an external Discord action. A replay of the same
-- interaction never dispatches the action again, including after a timeout.
function Cases:pending(guild, actor, target, text, request, action)
  if not Store.valid_id(actor) or not Store.valid_id(target) or not Store.valid_id(request)
    or not reason(text) or action ~= "hackban" then return false, "invalid_argument" end
  return self.store:run(guild, function(data)
    if data.receipts[request] then
      local receipt = data.receipts[request]
      local case = case_for_receipt(data, receipt)
      if not case then return false, "invalid_store" end
      local changed = receipt.case_id ~= case.id
      if changed then data.receipts[request] = { case_id = case.id } end
      return true, { case = case, fresh = false }, changed
    end
    if #data.cases >= 1000 or type(data.next_case) ~= "number" or data.next_case < 1 or data.next_case > 9999999999999 then return false, "capacity" end
    local case = { id = "C" .. string.format("%.0f", data.next_case), guild = guild, action = action, target = target,
      moderator = actor, reason = text, timestamp = self.clock(), active = true, status = "pending" }
    data.next_case = data.next_case + 1
    data.cases[#data.cases + 1] = case
    data.receipts[request] = { case_id = case.id }
    return true, { case = case, fresh = true }, true
  end)
end

function Cases:finish(guild, id, status)
  if not parse(id) or (status ~= "completed" and status ~= "unknown") then return false, "invalid_argument" end
  return self.store:run(guild, function(data)
    for _, item in ipairs(data.cases) do
      if item.id == id and item.status == "pending" then
        item.status, item.completed_at = status, self.clock()
        return true, item, true
      end
    end
    return false, "not_found"
  end)
end

function Cases:list(guild, target)
  if target and not Store.valid_id(target) then return false, "invalid_argument" end
  return self.store:run(guild, function(data)
    local result = {}
    for i = #data.cases, 1, -1 do
      local item = data.cases[i]
      if not target or item.target == target then result[#result + 1] = item end
      if #result == 10 then break end
    end
    return true, result, false
  end)
end

function Cases:get(guild, id)
  if not parse(id) then return false, "invalid_argument" end
  return self.store:run(guild, function(data)
    for _, item in ipairs(data.cases) do if item.id == id then return true, item, false end end
    return false, "not_found"
  end)
end

function Cases:edit(guild, id, actor, action, text)
  if not parse(id) or not Store.valid_id(actor) or (action == "reason" and not reason(text)) then return false, "invalid_argument" end
  if action ~= "reason" and action ~= "remove" then return false, "invalid_argument" end
  return self.store:run(guild, function(data)
    for _, item in ipairs(data.cases) do
      if item.id == id then
        if action == "remove" then
          if item.action ~= "warn" or not item.active then return false, "not_found" end
          item.active, item.removed_by, item.removed_at = false, actor, self.clock()
        else
          item.reason_history = item.reason_history or {}
          if #item.reason_history >= 20 then return false, "capacity" end
          item.reason_history[#item.reason_history + 1] = { reason = item.reason, changed_by = actor, changed_at = self.clock() }
          item.reason, item.reason_updated_by, item.reason_updated_at = text, actor, self.clock()
        end
        return true, item, true
      end
    end
    return false, "not_found"
  end)
end

function Cases:modlog(guild, mode, channel)
  if mode ~= "status" and mode ~= "disable" and mode ~= "set" then return false, "invalid_argument" end
  if mode == "set" and not Store.valid_id(channel) then return false, "invalid_argument" end
  return self.store:run(guild, function(data)
    if mode == "set" then data.modlog = channel elseif mode == "disable" then data.modlog = "" end
    return true, data.modlog or "", mode ~= "status"
  end)
end

return Cases
