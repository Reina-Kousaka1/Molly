local Store = require("src.persistence.guild_store")
local ReceiptWindow = require("src.persistence.receipt_window")

local Directory = {}
Directory.__index = Directory
local MAX_STAFF_RECEIPTS = 1000
local STAFF_RECEIPTS = {
  map = "staff_receipts", order = "staff_receipt_order", count = "staff_receipt_count",
  head = "staff_receipt_head", tail = "staff_receipt_tail", watermark = "staff_receipt_watermark",
  migrated = "staff_receipts_migrated", legacy_map = "receipts", limit = MAX_STAFF_RECEIPTS,
  legacy_filter = function(_, receipt)
    if type(receipt) ~= "table" or receipt.staff_id == nil then return false end
    for key in pairs(receipt) do if key ~= "staff_id" then return false end end
    return true
  end,
  legacy_validate = function(request, receipt)
    return Store.valid_id(request) and Store.valid_id(receipt.staff_id)
  end,
  legacy_transform = function(_, receipt)
    return { staff_id = receipt.staff_id, legacy = true }
  end,
}

function Directory.new(store, clock)
  return setmetatable({ store = store, clock = clock or os.time }, Directory)
end

local function replay_matches(receipt, target, actor, action, note, entry)
  if type(receipt) ~= "table" or type(receipt.staff_id) ~= "string" then
    return false, "invalid_store"
  end
  if receipt.legacy == true then
    if receipt.staff_id ~= target or not entry then return false, "invalid_store" end
    return true
  end
  if receipt.staff_id ~= target or receipt.actor_id ~= actor or receipt.action ~= action then
    return false, "replay_conflict"
  end
  if action == "note" then
    if type(receipt.note_index) ~= "number" or receipt.note_index % 1 ~= 0
      or type(entry) ~= "table" or type(entry.notes) ~= "table" then return false, "invalid_store" end
    local saved = entry.notes[receipt.note_index]
    if type(saved) ~= "table" or saved.author ~= actor then return false, "invalid_store" end
    if saved.text ~= note then return false, "replay_conflict" end
  elseif receipt.note_index ~= nil then
    return false, "invalid_store"
  end
  if not entry then return false, "invalid_store" end
  return true
end

function Directory:apply(guild, actor, target, action, note, request)
  if not Store.valid_id(actor) or not Store.valid_id(target) then return false, "invalid_argument" end
  if request ~= nil and not Store.valid_id(request) then return false, "invalid_argument" end
  if action ~= "add" and action ~= "remove" and action ~= "note" and action ~= "notes" and action ~= "info" then
    return false, "invalid_argument"
  end
  if action == "note" and (type(note) ~= "string" or #note < 1 or #note > 500 or not note:match("%S")) then
    return false, "invalid_argument"
  end
  return self.store:run(guild, function(data)
    local migrated, prepare_reason = ReceiptWindow.prepare(data, STAFF_RECEIPTS)
    if migrated == nil then return false, prepare_reason end
    local changed = migrated
    local entry = data.staff[target]
    if request then
      local status, receipt = ReceiptWindow.lookup(data, STAFF_RECEIPTS, request)
      if status == "retained" then
        local matches, replay_reason = replay_matches(receipt, target, actor, action, note, entry)
        if not matches then return false, replay_reason end
        return true, entry, changed
      elseif status == "expired" then
        return false, "replay_expired"
      elseif status == "invalid_store" then
        return false, "invalid_store"
      end
    end

    local note_index
    if action == "add" then
      if entry and entry.active then return false, "already_exists" end
      if not entry then
        local count = 0
        for _ in pairs(data.staff) do count = count + 1 end
        if count >= 200 then return false, "capacity" end
        entry = { id = target, notes = {} }
        data.staff[target] = entry
      end
      entry.active, entry.changed_by, entry.changed_at = true, actor, self.clock()
    elseif action == "remove" then
      if not entry or not entry.active then return false, "not_found" end
      entry.active, entry.changed_by, entry.changed_at = false, actor, self.clock()
    elseif action == "note" then
      if not entry or not entry.active or type(entry.notes) ~= "table" then return false, "not_found" end
      if #entry.notes >= 50 then return false, "capacity" end
      entry.notes[#entry.notes + 1] = { author = actor, text = note, timestamp = self.clock() }
      note_index = #entry.notes
    elseif not entry then
      return false, "not_found"
    end

    local mutation = action == "add" or action == "remove" or action == "note"
    if mutation and request then
      local saved, save_reason = ReceiptWindow.add(data, STAFF_RECEIPTS, request, {
        staff_id = target, actor_id = actor, action = action, note_index = note_index,
      })
      if not saved then return false, save_reason end
    end
    return true, entry, changed or mutation
  end)
end

function Directory:list(guild)
  return self.store:run(guild, function(data)
    local entries = {}
    for _, entry in pairs(data.staff) do if entry.active then entries[#entries + 1] = entry.id end end
    table.sort(entries)
    return true, entries, false
  end)
end

Directory.max_receipts = MAX_STAFF_RECEIPTS
return Directory
