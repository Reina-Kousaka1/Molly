-- Captures a complete bounded snapshot only through an explicitly qualified
-- source capability. The current SeaWorld connector intentionally lacks it.
local Snapshot = {}
local MAX_COLLECTIONS, MAX_PAGES, MAX_PAGE_SIZE, MAX_RECORDS, MAX_BYTES, MAX_DEPTH, MAX_NODES =
  10000, 10000, 500, 200000, 64 * 1024 * 1024, 64, 2000000

local function dense_array(value)
  local count, highest = 0, 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
    count = count + 1
    if key > highest then highest = key end
  end
  return count == highest
end

local function allowed_collection(name)
  local guild = type(name) == "string" and name:match("^molly_g_(%d+)$")
  if guild and #guild <= 20 then return "guild", guild end
  local global = type(name) == "string" and name:match("^molly_global_([a-z][a-z0-9_%-]*)$")
  if global and #global <= 48 then return "global", global end
  return nil
end

local function validate_tree(json, value, depth, state, stack)
  state.nodes = state.nodes + 1
  if state.nodes > MAX_NODES then return false, "resource_limit" end
  if value == json.null then return true end
  local kind = type(value)
  if kind == "string" then
    if type(json.is_utf8) == "function" and not json.is_utf8(value) then return false, "invalid_utf8" end
    return true
  end
  if kind == "boolean" then return true end
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then return false, "invalid_number" end
    return true
  end
  if kind ~= "table" then return false, "invalid_json_value" end
  if depth > MAX_DEPTH then return false, "resource_limit" end
  if stack[value] then return false, "cyclic_value" end
  local meta = getmetatable(value)
  local array = type(json.is_array) == "function" and json.is_array(value)
  if meta ~= nil and not array then return false, "unsupported_metatable" end
  stack[value] = true
  local count, highest = 0, 0
  for key, child in pairs(value) do
    if array then
      if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then stack[value] = nil; return false, "invalid_array" end
      count = count + 1
      if key > highest then highest = key end
    elseif type(key) ~= "string" then
      stack[value] = nil
      return false, "invalid_object_key"
    end
    local ok, err = validate_tree(json, child, depth + 1, state, stack)
    if not ok then stack[value] = nil; return false, err end
  end
  if array and count ~= highest then stack[value] = nil; return false, "invalid_array" end
  stack[value] = nil
  return true
end

function Snapshot.capture(source, gate, json, page_size, held_gate_token)
  page_size = page_size or 250
  if type(source) ~= "table" or type(source.begin_consistent_snapshot) ~= "function"
    or type(source.list_collections) ~= "function" or type(source.list_documents) ~= "function"
    or type(source.validate_snapshot) ~= "function" or type(source.end_snapshot) ~= "function"
    or type(gate) ~= "table" or type(gate.quiesce) ~= "function"
    or type(json) ~= "table" or type(json.encode) ~= "function" or type(json.decode) ~= "function"
    or type(page_size) ~= "number" or page_size < 1 or page_size > MAX_PAGE_SIZE or page_size % 1 ~= 0 then
    return nil, { code = "snapshot_capability_unavailable" }
  end
  local token = held_gate_token
  if token then
    if type(gate.validate) ~= "function" or not gate:validate(token) then
      return nil, { code = "invalid_quiesce_token" }
    end
  else
    local gate_error
    token, gate_error = gate:quiesce()
    if not token then return nil, { code = gate_error } end
  end

  local snapshot, failure, source_token
  local function run()
    local descriptor
    source_token, descriptor = source:begin_consistent_snapshot()
    if not source_token or type(descriptor) ~= "table"
      or type(descriptor.source_id) ~= "string" or descriptor.source_id == ""
      or #descriptor.source_id > 128
      or type(descriptor.snapshot_id) ~= "string" or descriptor.snapshot_id == ""
      or #descriptor.snapshot_id > 256
      or type(descriptor.format_version) ~= "string" or descriptor.format_version == ""
      or #descriptor.format_version > 64
      or type(descriptor.write_epoch) ~= "number" or descriptor.write_epoch < 0
      or descriptor.write_epoch % 1 ~= 0 or descriptor.inventory_complete ~= true
      or descriptor.inventory_scope ~= "molly_persistence" then
      failure = { code = "source_snapshot_unavailable" }; return
    end
    local names, list_error = source:list_collections(source_token)
    if type(names) ~= "table" then failure = { code = "source_inventory_failed", detail = list_error }; return end
    local count = #names
    if not dense_array(names) or count > MAX_COLLECTIONS then failure = { code = "invalid_inventory" }; return end
    local inventory_seen = {}
    for _, name in ipairs(names) do
      if type(name) ~= "string" then failure = { code = "invalid_inventory" }; return end
      if inventory_seen[name] then failure = { code = "duplicate_inventory_entry" }; return end
      inventory_seen[name] = true
    end
    table.sort(names)
    local seen, records, expected, total_bytes = {}, {}, {}, 0
    local tree_state = { nodes = 0 }
    for _, collection in ipairs(names) do
      if #collection > 128 then failure = { code = "invalid_inventory" }; return end
      local area, key = allowed_collection(collection)
      if not area or seen[collection] then failure = { code = "unsupported_source_collection", collection = collection }; return end
      seen[collection] = true
      expected[#expected + 1] = { collection = collection, key = key, area = area }
      local cursor, cursor_seen, rows = nil, {}, 0
      for _ = 1, MAX_PAGES do
        local items, next_cursor = source:list_documents(source_token, collection, cursor, page_size)
        if type(items) ~= "table" or not dense_array(items) or #items > page_size then
          failure = { code = "source_page_failed", collection = collection }; return
        end
        for _, item in ipairs(items) do
          if type(item) ~= "table" or item.key ~= key or type(item.value) ~= "table"
            or item.value == json.null
            or (type(json.is_array) == "function" and json.is_array(item.value)) then
            failure = { code = "source_record_invalid", collection = collection }; return
          end
          rows = rows + 1
          if rows ~= 1 then failure = { code = "source_collection_cardinality", collection = collection }; return end
          local tree_ok, tree_error = validate_tree(json, item.value, 0, tree_state, {})
          if not tree_ok then failure = { code = tree_error, collection = collection }; return end
          local encoded_ok, encoded = pcall(json.encode, item.value)
          if not encoded_ok or type(encoded) ~= "string" then failure = { code = "source_record_serialization" }; return end
          total_bytes = total_bytes + #encoded
          if total_bytes > MAX_BYTES then failure = { code = "resource_limit" }; return end
          local decoded_ok, detached = pcall(json.decode, encoded)
          if not decoded_ok or type(detached) ~= "table" then failure = { code = "source_record_serialization" }; return end
          records[#records + 1] = { collection = collection, key = key, area = area, value = detached }
          if #records > MAX_RECORDS then failure = { code = "resource_limit" }; return end
        end
        if next_cursor == nil then break end
        if type(next_cursor) ~= "string" or next_cursor == "" or #next_cursor > 512 or cursor_seen[next_cursor] then
          failure = { code = "invalid_page_cursor", collection = collection }; return
        end
        cursor_seen[next_cursor], cursor = true, next_cursor
        if _ == MAX_PAGES then failure = { code = "page_limit", collection = collection }; return end
      end
      if rows ~= 1 then failure = { code = "source_collection_cardinality", collection = collection }; return end
    end
    table.sort(records, function(a, b)
      if a.collection == b.collection then return a.key < b.key end
      return a.collection < b.collection
    end)
    local valid, validation = source:validate_snapshot(source_token)
    if not valid or type(validation) ~= "table" or validation.source_id ~= descriptor.source_id
      or validation.snapshot_id ~= descriptor.snapshot_id or validation.write_epoch ~= descriptor.write_epoch
      or validation.format_version ~= descriptor.format_version
      or validation.inventory_complete ~= true or validation.inventory_scope ~= "molly_persistence" then
      failure = { code = "source_snapshot_changed" }; return
    end
    snapshot = { source_id = descriptor.source_id, snapshot_id = descriptor.snapshot_id,
      format_version = descriptor.format_version, write_epoch = descriptor.write_epoch,
      collections = expected, records = records }
  end

  local ok = pcall(run)
  if not ok then failure = { code = "source_snapshot_error" } end
  if source_token and not held_gate_token then
    local ended, end_result = pcall(source.end_snapshot, source, source_token)
    if not ended or end_result ~= true then failure = { code = "source_snapshot_release_failed" } end
  end
  if not held_gate_token then
    local released = gate:release(token)
    if not released then return nil, { code = "write_gate_release_failed" } end
  end
  if failure then
    if source_token and held_gate_token then pcall(source.end_snapshot, source, source_token) end
    return nil, failure
  end
  if held_gate_token then return snapshot, nil, { token = source_token } end
  return snapshot
end

Snapshot.allowed_collection = allowed_collection
Snapshot.limits = { collections = MAX_COLLECTIONS, pages_per_collection = MAX_PAGES,
  page_size = MAX_PAGE_SIZE, records = MAX_RECORDS, bytes = MAX_BYTES,
  depth = MAX_DEPTH, nodes = MAX_NODES }
return Snapshot
