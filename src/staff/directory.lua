local Store = require("src.persistence.guild_store")
local Directory = {}
Directory.__index = Directory
-- Request IDs are Discord snowflakes, so numeric string order retains the
-- newest idempotency receipts while bounding each guild document.
local MAX_RECEIPTS = 1000

local function older_request(a, b)
  if #a == #b then return a < b end
  return #a < #b
end

local function prune_receipts(receipts)
  local requests = {}
  for request, receipt in pairs(receipts) do
    if type(receipt) == "table" and type(receipt.staff_id) == "string" then
      requests[#requests + 1] = request
    end
  end
  if #requests <= MAX_RECEIPTS then return end
  table.sort(requests, older_request)
  for index = 1, #requests - MAX_RECEIPTS do
    receipts[requests[index]] = nil
  end
end

function Directory.new(store, clock) return setmetatable({ store = store, clock = clock or os.time }, Directory) end

function Directory:apply(guild, actor, target, action, note, request)
  if not Store.valid_id(actor) or not Store.valid_id(target) then return false, "invalid_argument" end
  if request ~= nil and not Store.valid_id(request) then return false, "invalid_argument" end
  if action ~= "add" and action ~= "remove" and action ~= "note" and action ~= "notes" and action ~= "info" then return false, "invalid_argument" end
  if action == "note" and (type(note) ~= "string" or #note < 1 or #note > 500 or not note:match("%S")) then return false, "invalid_argument" end
  return self.store:run(guild, function(data)
    local entry = data.staff[target]
    if request and data.receipts[request] then
      local receipt = data.receipts[request]
      if type(receipt) ~= "table" or receipt.staff_id ~= target or not entry then return false, "invalid_store" end
      return true, entry, false
    end
    if action == "add" then
      if entry and entry.active then return false, "already_exists" end
      if not entry then
        local count = 0; for _ in pairs(data.staff) do count = count + 1 end
        if count >= 200 then return false, "capacity" end
        entry = { id = target, notes = {} }; data.staff[target] = entry
      end
      entry.active, entry.changed_by, entry.changed_at = true, actor, self.clock()
    elseif action == "remove" then
      if not entry or not entry.active then return false, "not_found" end
      entry.active, entry.changed_by, entry.changed_at = false, actor, self.clock()
    elseif action == "note" then
      if not entry or not entry.active or type(entry.notes) ~= "table" then return false, "not_found" end
      if #entry.notes >= 50 then return false, "capacity" end
      entry.notes[#entry.notes + 1] = { author = actor, text = note, timestamp = self.clock() }
    elseif not entry then return false, "not_found" end
    local changed = action == "add" or action == "remove" or action == "note"
    if changed and request then
      data.receipts[request] = { staff_id = target }
      prune_receipts(data.receipts)
    end
    return true, entry, changed
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
return Directory
