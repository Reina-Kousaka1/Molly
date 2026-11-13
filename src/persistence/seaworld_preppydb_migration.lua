-- Explicit-manifest, insert-only migration from Molly's existing SeaWorld
-- one-document-per-store layout into the shared PreppyDB state collections.
-- Dry-run is the default. The module never deletes or changes source records.
local Migration = {}
local Durability = require("src.persistence.preppydb_durability")

local MAX_GUILDS = 10000
local MAX_GLOBALS = 1000
local MAX_DEPTH = 64
local GUILD_STATE_MARKER = "_molly_preppydb_state"
local DEFAULT_GUILD_REGISTRY = "molly_guild_registry"

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

local function ensure_target(target, entries, target_json, mode, max_document_bytes)
  local encoded, states, missing = {}, {}, 0
  for index, entry in ipairs(entries) do
    encoded[index] = encode(target_json, entry.value)
    if not encoded[index] then return nil, "serialization_failed" end
    if #encoded[index] > max_document_bytes then return nil, "resource_limit" end
    local current, read_error = target:get(entry.collection, entry.key)
    if current then
      if encode(target_json, current.value) ~= encoded[index] then return nil, "target_conflict" end
      states[index] = "present"
    elseif type(read_error) == "table" and read_error.code == "not_found" then
      states[index] = "missing"
      missing = missing + 1
    else
      return nil, "target_unavailable"
    end
  end
  if missing == 0 then
    if mode == "verify" then return "verified" end
    return "already_identical"
  end
  if missing ~= #entries then return nil, "target_inconsistent" end
  -- The cutover gate: a verify-only run proves the manifest is already in the
  -- destination and writes nothing at all. It fails on the first missing key
  -- instead of reporting a clean bill of health it cannot support.
  if mode == "verify" then return nil, "not_migrated" end
  if mode ~= "apply" then return "planned" end

  local operations = {}
  for _, entry in ipairs(entries) do
    operations[#operations + 1] = {
      op = "put", collection = entry.collection, key = entry.key,
      expected_version = 0, value = entry.value,
    }
  end
  local result, write_error = target:transaction(operations)
  if result then
    for index, entry in ipairs(entries) do
      local verified = target:get(entry.collection, entry.key)
      if not verified or encode(target_json, verified.value) ~= encoded[index] then
        return nil, "verification_failed"
      end
    end
    return "inserted"
  end
  if type(write_error) == "table" and write_error.code == "conflict" then
    local all_identical = true
    for index, entry in ipairs(entries) do
      local raced = target:get(entry.collection, entry.key)
      if not raced or encode(target_json, raced.value) ~= encoded[index] then all_identical = false end
    end
    if all_identical then return "already_identical" end
  end
  -- A lost response after submission is deliberately not retried here. A later
  -- invocation safely re-reads the insert-only destination and verifies bytes.
  if type(write_error) == "table" and (write_error.status == nil or write_error.status >= 500
    or write_error.code == "transport_error") then return nil, "outcome_unknown" end
  return nil, "write_failed"
end

--- Probe a PreppyDB connector for durable-write evidence.
-- Returns true with evidence, or false with `not_durable` when the server says
-- writes are not synced, and `unverifiable` when it cannot answer at all. The
-- three outcomes are deliberately distinct: silence is not agreement.
function Migration.durability(target)
  if type(target) ~= "table" or type(target.version) ~= "function" then
    return false, { code = "unverifiable", detail = "no_version_endpoint" }
  end
  local called, version, version_error = pcall(target.version, target)
  if not called then
    return false, { code = "unverifiable", detail = "version_probe_failed" }
  end
  if type(version) ~= "table" then
    return false, {
      code = "unverifiable",
      detail = "version_unavailable",
      reason = type(version_error) == "table" and version_error.code or nil,
    }
  end
  local state, detail, sync_mode, durable_writes = Durability.classify(version)
  if state ~= "durable" then return false, {
    code = state, detail = detail, sync_mode = sync_mode, durable_writes = durable_writes,
  } end
  return true, {
    durability = state,
    detail = detail,
    sync_mode = sync_mode,
    durable_writes = durable_writes,
    api_version = version.api_version,
    engine = version.engine,
  }
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
  if options.verify_only ~= nil and options.verify_only ~= true and options.verify_only ~= false then
    return false, { code = "invalid_argument" }
  end
  if options.verify_only == true and options.apply == true then
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
  local mode = options.verify_only == true and "verify" or (options.apply == true and "apply" or "dry_run")
  local summary = { mode = mode, guilds = {}, globals = {}, verified = 0 }

  -- Durability gate. An apply against a destination that does not sync writes
  -- to disk is refused before the first insert, because every later "verified"
  -- line would be an unsupported claim. When the server cannot be asked, that
  -- fact is carried in the summary rather than being reported as success.
  local durability_state, durability_detail
  if mode == "dry_run" then
    durability_state, durability_detail = "not_checked", nil
  else
    local durable, evidence = Migration.durability(target)
    durability_state = durable and "durable" or (evidence and evidence.code or "unverifiable")
    durability_detail = evidence and evidence.detail or nil
    summary.durability = durability_state
    summary.durability_detail = durability_detail
    summary.durable = durable == true
    if mode == "apply" and durability_state ~= "durable" then
      local code = durability_state == "not_durable" and "not_durable" or "durability_unverifiable"
      return false, { code = code, detail = durability_detail, summary = summary }
    end
  end

  local function migrate_list(values, kind, collection, report)
    for _, key in ipairs(values) do
      local source_collection = kind == "guild" and ("molly_g_" .. key) or ("molly_global_" .. key)
      local original, source_error = source_store(source, source_collection, key)
      if not original then
        summary.failed = { key = key, collection = source_collection, code = source_error }
        return false, source_error
      end
      local converted, convert_error = convert(original, source_json, target_json, {}, 0)
      if not converted then
        summary.failed = { key = key, collection = source_collection, code = convert_error }
        return false, convert_error
      end
      local entries = { { collection = collection, key = key, value = converted } }
      if kind == "guild" then
        if converted[GUILD_STATE_MARKER] ~= nil then
          summary.failed = { key = key, collection = source_collection, code = "reserved_field_present" }
          return false, "source_inconsistent"
        end
        converted[GUILD_STATE_MARKER] = { version = 1, origin = "migrated" }
        entries[#entries + 1] = {
          collection = options.guild_registry_collection or DEFAULT_GUILD_REGISTRY,
          key = key, value = { guild = key, version = 1, status = "migrated" },
        }
      end
      local disposition, target_error = ensure_target(target, entries,
        target_json, mode, max_document_bytes)
      if not disposition then
        summary.failed = { key = key, collection = collection, code = target_error }
        return false, target_error
      end
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
