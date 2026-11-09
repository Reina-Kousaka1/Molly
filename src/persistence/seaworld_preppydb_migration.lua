-- Explicit-manifest, insert-only migration from Molly's existing SeaWorld
-- one-document-per-store layout into the shared PreppyDB state collections.
-- Dry-run is the default. The module never deletes or changes source records.
local Migration = {}

local MAX_GUILDS = 10000
local MAX_GLOBALS = 1000
local MAX_DEPTH = 64

local function valid_guild(value)
  return type(value) == "string" and #value > 0 and #value <= 20 and value:match("^%d+$") ~= nil
end

local function valid_global(value)
  return type(value) == "string" and #value <= 48 and value:match("^[a-z][a-z0-9_%-]*$") ~= nil
end

local function sorted_unique(values, validate, limit)
  if type(values) ~= "table" then return nil end
  local count, highest = 0, 0
  for key in pairs(values) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return nil end
    count = count + 1
    if key > highest then highest = key end
  end
  if count > limit or highest ~= count then return nil end
  local result, seen = {}, {}
  for index = 1, count do
    local value = values[index]
    if not validate(value) or seen[value] then return nil end
    seen[value] = true
    result[#result + 1] = value
  end
  table.sort(result)
  return result
end

local function convert(value, source_json, target_json, seen, depth)
  if depth > MAX_DEPTH then return nil, "resource_limit" end
  if value == source_json.null then return target_json.null end
  local kind = type(value)
  if kind == "nil" or kind == "boolean" or kind == "string" then return value end
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then return nil, "invalid_data" end
    return value
  end
  if kind ~= "table" then return nil, "invalid_data" end
  if seen[value] then return nil, "invalid_data" end
  seen[value] = true
  local meta = getmetatable(value)
  local is_array = type(meta) == "table" and meta.__jsontype == "array"
  local output = is_array and target_json.array({}) or {}
  for key, child in pairs(value) do
    if is_array then
      if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then seen[value] = nil; return nil, "invalid_data" end
    elseif type(key) ~= "string" then
      seen[value] = nil
      return nil, "invalid_data"
    end
    local item, err = convert(child, source_json, target_json, seen, depth + 1)
    if err then seen[value] = nil; return nil, err end
    output[key] = item
  end
  if is_array then
    local count, highest = 0, 0
    for key in pairs(value) do
      count = count + 1
      if key > highest then highest = key end
    end
    if highest ~= count then seen[value] = nil; return nil, "invalid_data" end
  end
  seen[value] = nil
  return output
end

local function encode(json, value)
  local ok, result = pcall(json.encode, value)
  if not ok or type(result) ~= "string" then return nil end
  return result
end

local function source_store(source, collection, key)
  local ok, result = source:query({ collection = collection, limit = 2 })
  if not ok or type(result) ~= "table" or type(result.rows) ~= "table" or #result.rows ~= 1 then
    return nil, "source_inconsistent"
  end
  local row = result.rows[1]
  if type(row) ~= "table" or type(row.document) ~= "table" or type(row.document.data) ~= "table" then
    return nil, "source_inconsistent"
  end
  local value = row.document.data
  if collection:match("^molly_g_") and value.guild ~= key then return nil, "source_inconsistent" end
  return value
end

local function ensure_target(target, collection, key, value, target_json, apply, max_document_bytes)
  local encoded = encode(target_json, value)
  if not encoded then return nil, "serialization_failed" end
  if #encoded > max_document_bytes then return nil, "resource_limit" end
  local current, read_error = target:get(collection, key)
  if current then
    if encode(target_json, current.value) ~= encoded then return nil, "target_conflict" end
    return "already_identical"
  end
  if type(read_error) ~= "table" or read_error.code ~= "not_found" then return nil, "target_unavailable" end
  if not apply then return "planned" end

  local result, write_error = target:transaction({ {
    op = "put", collection = collection, key = key, expected_version = 0, value = value,
  } })
  if result then
    local verified, verify_error = target:get(collection, key)
    if not verified or encode(target_json, verified.value) ~= encoded then return nil, "verification_failed" end
    return "inserted"
  end
  if type(write_error) == "table" and write_error.code == "conflict" then
    local raced, race_error = target:get(collection, key)
    if raced and encode(target_json, raced.value) == encoded then return "already_identical" end
  end
  -- A lost response after submission is deliberately not retried here. A later
  -- invocation safely re-reads the insert-only destination and verifies bytes.
  if type(write_error) == "table" and (write_error.status == nil or write_error.status >= 500
    or write_error.code == "transport_error") then return nil, "outcome_unknown" end
  return nil, "write_failed"
end

function Migration.run(options)
  options = options or {}
  local source, target = options.source, options.target
  local source_json, target_json = options.source_json, options.target_json
  if type(source) ~= "table" or type(source.query) ~= "function"
    or type(target) ~= "table" or type(target.get) ~= "function" or type(target.transaction) ~= "function"
    or type(source_json) ~= "table" or source_json.null == nil
    or type(target_json) ~= "table" or type(target_json.null) == "nil" or type(target_json.array) ~= "function" then
    return false, { code = "invalid_argument" }
  end
  if options.apply ~= nil and options.apply ~= true and options.apply ~= false then
    return false, { code = "invalid_argument" }
  end
  local max_document_bytes = options.max_document_bytes or 3 * 1024 * 1024
  if type(max_document_bytes) ~= "number" or max_document_bytes < 1024
    or max_document_bytes > 4 * 1024 * 1024 or max_document_bytes % 1 ~= 0 then
    return false, { code = "invalid_argument" }
  end
  local guilds = sorted_unique(options.guilds or {}, valid_guild, MAX_GUILDS)
  local globals = sorted_unique(options.globals or {}, valid_global, MAX_GLOBALS)
  if not guilds or not globals then return false, { code = "invalid_manifest" } end
  local summary = { mode = options.apply == true and "apply" or "dry_run", guilds = {}, globals = {}, verified = 0 }

  local function migrate_list(values, kind, collection, report)
    for _, key in ipairs(values) do
      local source_collection = kind == "guild" and ("molly_g_" .. key) or ("molly_global_" .. key)
      local original, source_error = source_store(source, source_collection, key)
      if not original then return false, source_error end
      local converted, convert_error = convert(original, source_json, target_json, {}, 0)
      if not converted then return false, convert_error end
      local disposition, target_error = ensure_target(target, collection, key, converted,
        target_json, options.apply == true, max_document_bytes)
      if not disposition then return false, target_error end
      report[#report + 1] = { key = key, status = disposition }
      if disposition ~= "planned" then summary.verified = summary.verified + 1 end
    end
    return true
  end

  local ok, err = migrate_list(guilds, "guild", options.guild_collection or "molly_guild_state", summary.guilds)
  if not ok then return false, { code = err, summary = summary } end
  ok, err = migrate_list(globals, "global", options.global_collection or "molly_global_state", summary.globals)
  if not ok then return false, { code = err, summary = summary } end
  return true, summary
end

return Migration
