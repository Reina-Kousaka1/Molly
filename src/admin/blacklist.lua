local ReceiptWindow = require("src.persistence.receipt_window")

local Blacklist = {}
Blacklist.__index = Blacklist

local MAX_RECEIPTS = 1000
local RECEIPTS = {
  map = "receipts", order = "receipt_order", count = "receipt_count",
  head = "receipt_head", tail = "receipt_tail", watermark = "receipt_watermark",
  migrated = "receipts_migrated", limit = MAX_RECEIPTS,
}

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
    if type(data.entries) ~= "table" then return false, "invalid_store" end
    local migrated, prepare_reason = ReceiptWindow.prepare(data, RECEIPTS)
    if migrated == nil then return false, prepare_reason end
    local status, receipt = ReceiptWindow.lookup(data, RECEIPTS, interaction_id)
    if status == "retained" then return true, receipt, migrated end
    if status == "expired" then return false, "replay_expired" end
    if status == "invalid_store" then return false, "invalid_store" end
    local entry = { user = user_id, reason = reason, created_at = self.clock(), actor = actor_id }
    local saved, save_reason = ReceiptWindow.add(data, RECEIPTS, interaction_id,
      { action = "add", user = user_id })
    if not saved then return false, save_reason end
    data.entries[user_id] = entry
    return true, entry, true
  end)
end

function Blacklist:remove(user_id, actor_id, interaction_id)
  if not valid_id(user_id) or not valid_id(actor_id) or not valid_id(interaction_id) then return false, "invalid_user" end
  return self.store:run("blacklist", { entries = {}, receipts = {} }, function(data)
    if type(data.entries) ~= "table" then return false, "invalid_store" end
    local migrated, prepare_reason = ReceiptWindow.prepare(data, RECEIPTS)
    if migrated == nil then return false, prepare_reason end
    local status, receipt = ReceiptWindow.lookup(data, RECEIPTS, interaction_id)
    if status == "retained" then return true, receipt, migrated end
    if status == "expired" then return false, "replay_expired" end
    if status == "invalid_store" then return false, "invalid_store" end
    local existed = data.entries[user_id] ~= nil
    local saved, save_reason = ReceiptWindow.add(data, RECEIPTS, interaction_id,
      { action = "remove", user = user_id, existed = existed })
    if not saved then return false, save_reason end
    data.entries[user_id] = nil
    return true, { user = user_id, existed = existed }, true
  end)
end

Blacklist.max_receipts = MAX_RECEIPTS
return Blacklist
