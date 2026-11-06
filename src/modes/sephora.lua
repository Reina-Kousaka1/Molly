local Store = require("src.persistence.guild_store")
local V2 = require("src.persistence.guild_v2")
local InventoryData = require("src.economy.inventory_data")
local ReceiptWindow = require("src.persistence.receipt_window")

local Sephora = {}
Sephora.__index = Sephora

local LOOKS = {
  rose_glow = { id = "rose_glow", name = "Rose Glow", description = "A soft rose-toned virtual style." },
  citrus_satin = { id = "citrus_satin", name = "Citrus Satin", description = "A bright citrus-and-satin virtual style." },
  lilac_moon = { id = "lilac_moon", name = "Lilac Moon", description = "A calm lilac evening virtual style." },
  soft_gold = { id = "soft_gold", name = "Soft Gold", description = "A warm, subtle golden virtual style." },
}
local MAX_USERS = 200
local MAX_RECEIPTS = 5000
local SEPHORA_RECEIPTS = {
  map = "receipts", order = "receipt_order", count = "receipt_count",
  head = "receipt_head", tail = "receipt_tail", watermark = "receipt_watermark",
  migrated = "receipts_migrated", limit = MAX_RECEIPTS,
}

function Sephora.new(store, modes, clock)
  assert(type(store) == "table" and type(store.run) == "function", "guild store is required")
  assert(type(modes) == "table" and type(modes.get) == "function", "mode registry is required")
  return setmetatable({ store = store, modes = modes, clock = clock or os.time }, Sephora)
end

function Sephora:lookbook()
  local result = {}
  for _, id in ipairs({ "rose_glow", "citrus_satin", "lilac_moon", "soft_gold" }) do
    local look = LOOKS[id]
    result[#result + 1] = { id = look.id, name = look.name, description = look.description }
  end
  return result
end

function Sephora:is_look(id)
  return type(id) == "string" and LOOKS[id] ~= nil
end

function Sephora:try_on(guild, user, look_id, request_id)
  if not Store.valid_id(guild) or not Store.valid_id(user) or not self:is_look(look_id)
    or not Store.valid_id(request_id) then return false, "invalid_argument" end
  return self.store:run(guild, function(data)
    local inventory, inventory_reason = InventoryData.get(data, user)
    if not inventory then return false, inventory_reason end
    if (inventory.items[look_id] or 0) < 1 then return false, "not_owned" end
    local section, reason = V2.ensure_section(data, "sephora")
    if not section then return false, reason end
    section.fittings = section.fittings or {}
    if type(section.fittings) ~= "table" then return false, "invalid_store" end
    local migrated, prepare_reason = ReceiptWindow.prepare(section, SEPHORA_RECEIPTS)
    if migrated == nil then return false, prepare_reason end
    local receipt_status, receipt = ReceiptWindow.lookup(section, SEPHORA_RECEIPTS, request_id)
    if receipt_status == "retained" then
      if type(receipt) ~= "table" or not self:is_look(receipt.look_id) or not Store.valid_id(receipt.user) then
        return false, "invalid_store"
      end
      if receipt.user ~= user or receipt.look_id ~= look_id then return false, "replay_conflict" end
      return true, { look_id = receipt.look_id, replayed = true }, migrated
    elseif receipt_status == "expired" then
      return false, "replay_expired"
    elseif receipt_status == "invalid_store" then
      return false, "invalid_store"
    end
    if section.fittings[user] == nil then
      local count = 0; for _ in pairs(section.fittings) do count = count + 1 end
      if count >= MAX_USERS then return false, "capacity" end
    end
    section.fittings[user] = { look_id = look_id, timestamp = self.clock() }
    local result = { look_id = look_id, replayed = false }
    local saved, save_reason = ReceiptWindow.add(section, SEPHORA_RECEIPTS, request_id,
      { user = user, look_id = look_id })
    if not saved then return false, save_reason end
    return true, result, true
  end)
end

function Sephora:get(guild, user)
  if not Store.valid_id(guild) or not Store.valid_id(user) then return false, "invalid_argument" end
  return self.store:run(guild, function(data)
    local section, read_reason = V2.read_section(data, "sephora")
    if not section then return false, read_reason end
    local fittings = section.fittings or {}
    if type(fittings) ~= "table" then return false, "invalid_store" end
    local value = fittings[user]
    if value == nil then return true, nil, false end
    if type(value) ~= "table" or not self:is_look(value.look_id) or type(value.timestamp) ~= "number" then
      return false, "invalid_store"
    end
    return true, { look_id = value.look_id, timestamp = value.timestamp }, false
  end)
end

function Sephora:clear(guild, user)
  if not Store.valid_id(guild) or not Store.valid_id(user) then return false, "invalid_argument" end
  return self.store:run(guild, function(data)
    local section, read_reason = V2.read_section(data, "sephora")
    if not section then return false, read_reason end
    local fittings = section.fittings or {}
    if type(fittings) ~= "table" then return false, "invalid_store" end
    if fittings[user] == nil then return true, false, false end
    fittings[user] = nil
    section.fittings = fittings
    return true, true, true
  end)
end

Sephora.max_users = MAX_USERS
Sephora.max_receipts = MAX_RECEIPTS
return Sephora
