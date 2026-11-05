local Window = {}

local function normalize_decimal(value)
  if type(value) ~= "string" or not value:match("^%d+$") then return nil end
  local result = value:gsub("^0+", "")
  return result == "" and "0" or result
end

function Window.valid_id(value)
  return type(value) == "string" and #value >= 1 and #value <= 20 and value:match("^%d+$") ~= nil
end

function Window.compare_ids(left, right)
  left, right = normalize_decimal(left), normalize_decimal(right)
  if not left or not right then return nil end
  if #left < #right then return -1 end
  if #left > #right then return 1 end
  if left < right then return -1 end
  if left > right then return 1 end
  return 0
end

local function advance_watermark(container, field, request_id)
  local current = container[field]
  if current == nil or current == "" or Window.compare_ids(request_id, current) > 0 then
    container[field] = normalize_decimal(request_id)
  end
end

local function less_id(left, right)
  local compared = Window.compare_ids(left, right)
  if compared ~= 0 then return compared < 0 end
  return left < right
end

local function valid_count(value, maximum)
  return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= maximum
end

local function valid_layout(container, options)
  local maximum = options.limit
  local receipts, order = container[options.map], container[options.order]
  local count, head, tail = container[options.count], container[options.head], container[options.tail]
  local watermark = container[options.watermark]
  if type(receipts) ~= "table" or type(order) ~= "table" or not valid_count(count, maximum)
    or type(watermark) ~= "string" or (watermark ~= "" and not normalize_decimal(watermark)) then
    return false
  end
  if #order ~= count then return false end
  if count == 0 then
    return head == 1 and tail == 0
  end
  if type(head) ~= "number" or head % 1 ~= 0 or head < 1 or head > maximum
    or type(tail) ~= "number" or tail % 1 ~= 0 or tail < 1 or tail > maximum then
    return false
  end
  if count < maximum and (head ~= 1 or tail ~= count) then return false end
  if count == maximum and tail ~= ((head + maximum - 2) % maximum) + 1 then return false end
  local oldest, newest = order[head], order[tail]
  return Window.valid_id(oldest) and Window.valid_id(newest)
    and type(receipts[oldest]) == "table" and type(receipts[newest]) == "table"
end

-- Lazily migrates a legacy receipt map, prunes it deterministically by decimal
-- request ID, and builds a bounded ring. The ring is persisted alongside the
-- map so eviction stays O(1) without an unbounded index or a full-map scan.
function Window.prepare(container, options)
  if type(container) ~= "table" or type(options) ~= "table"
    or type(options.limit) ~= "number" or options.limit < 1 or options.limit % 1 ~= 0 then
    return nil, "invalid_store"
  end
  local marker = options.migrated
  if container[marker] == true then
    if not valid_layout(container, options) then return nil, "invalid_store" end
    return false
  end
  if container[marker] ~= nil and container[marker] ~= false then return nil, "invalid_store" end

  local source = container[options.map]
  if source == nil then source = {} end
  if type(source) ~= "table" then return nil, "invalid_store" end
  local receipts = {}
  for request_id, receipt in pairs(source) do
    if not Window.valid_id(request_id) or type(receipt) ~= "table" then return nil, "invalid_store" end
    receipts[request_id] = receipt
  end

  local legacy_name = options.legacy_map
  if legacy_name and legacy_name ~= options.map then
    local legacy = container[legacy_name]
    if legacy ~= nil and type(legacy) ~= "table" then return nil, "invalid_store" end
    for request_id, receipt in pairs(legacy or {}) do
      local matches, match_error = false, nil
      if options.legacy_filter then
        local called, result, reason = pcall(options.legacy_filter, request_id, receipt)
        if not called then return nil, "invalid_store" end
        matches, match_error = result, reason
      end
      if match_error then return nil, match_error end
      if matches then
        if not Window.valid_id(request_id) or type(receipt) ~= "table"
          or (options.legacy_validate and not options.legacy_validate(request_id, receipt)) then
          return nil, "invalid_store"
        end
        if receipts[request_id] == nil then
          local value = receipt
          if options.legacy_transform then
            local called, transformed = pcall(options.legacy_transform, request_id, receipt)
            if not called or type(transformed) ~= "table" then return nil, "invalid_store" end
            value = transformed
          end
          receipts[request_id] = value
        end
        legacy[request_id] = nil
      end
    end
  end

  local watermark = container[options.watermark]
  if watermark == nil then watermark = "" end
  if type(watermark) ~= "string" or (watermark ~= "" and not normalize_decimal(watermark)) then
    return nil, "invalid_store"
  end
  local ids = {}
  for request_id in pairs(receipts) do ids[#ids + 1] = request_id end
  table.sort(ids, less_id)

  local remove_count = math.max(0, #ids - options.limit)
  for index = 1, remove_count do
    local request_id = ids[index]
    receipts[request_id] = nil
    if watermark == "" or Window.compare_ids(request_id, watermark) > 0 then
      watermark = normalize_decimal(request_id)
    end
  end

  local order = {}
  local count = 0
  for index = remove_count + 1, #ids do
    count = count + 1
    order[count] = ids[index]
  end
  container[options.map] = receipts
  container[options.order] = order
  container[options.count] = count
  container[options.head] = 1
  container[options.tail] = count
  container[options.watermark] = watermark
  container[marker] = true
  return true
end

-- Returns "retained", receipt; "expired"; "invalid_store"; or "new", nil,
-- oldest_id. The retained lookup precedes the watermark so every surviving
-- receipt remains replayable even if an out-of-order ID was later evicted.
function Window.lookup(container, options, request_id)
  if not Window.valid_id(request_id) then return "invalid_store" end
  local receipts = container[options.map]
  local receipt = receipts[request_id]
  if receipt ~= nil then return "retained", receipt end
  local watermark = container[options.watermark]
  if watermark ~= "" and Window.compare_ids(request_id, watermark) <= 0 then return "expired" end
  if container[options.count] == options.limit then
    local oldest = container[options.order][container[options.head]]
    if not Window.valid_id(oldest) or type(receipts[oldest]) ~= "table" then return "invalid_store" end
    if Window.compare_ids(request_id, oldest) <= 0 then return "expired" end
    return "new", nil, oldest
  end
  return "new"
end

function Window.remove(container, options, request_id)
  if not Window.valid_id(request_id) then return false, "invalid_argument" end
  local status, receipt = Window.lookup(container, options, request_id)
  if status == "invalid_store" then return false, "invalid_store" end
  if status ~= "retained" then return true, false end
  if type(receipt) ~= "table" then return false, "invalid_store" end
  local count, head = container[options.count], container[options.head]
  local retained = {}
  local removed = false
  for offset = 0, count - 1 do
    local slot = ((head + offset - 1) % options.limit) + 1
    local value = container[options.order][slot]
    if value == request_id then
      if removed then return false, "invalid_store" end
      removed = true
    else
      retained[#retained + 1] = value
    end
  end
  if not removed then return false, "invalid_store" end
  container[options.map][request_id] = nil
  container[options.order] = retained
  container[options.count] = #retained
  container[options.head] = 1
  container[options.tail] = #retained
  return true, true
end

function Window.add(container, options, request_id, receipt)
  local status, _, oldest = Window.lookup(container, options, request_id)
  if status ~= "new" then
    return false, status == "expired" and "replay_expired"
      or status == "retained" and "duplicate_receipt" or "invalid_store"
  end
  local receipts, order = container[options.map], container[options.order]
  local count, head, tail = container[options.count], container[options.head], container[options.tail]
  if count == options.limit then
    if oldest == nil then return false, "invalid_store" end
    receipts[oldest] = nil
    advance_watermark(container, options.watermark, oldest)
    order[head] = ""
    head = head % options.limit + 1
    count = count - 1
  end
  tail = tail % options.limit + 1
  order[tail] = request_id
  receipts[request_id] = receipt
  count = count + 1
  container[options.count], container[options.head], container[options.tail] = count, head, tail
  return true
end

return Window
