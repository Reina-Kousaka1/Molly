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

local function ensure_target(target, collection, key, value, target_json, mode, max_document_bytes)
  local encoded = encode(target_json, value)
  if not encoded then return nil, "serialization_failed" end
  if #encoded > max_document_bytes then return nil, "resource_limit" end
  local current, read_error = target:get(collection, key)
  if current then
    if encode(target_json, current.value) ~= encoded then return nil, "target_conflict" end
    if mode == "verify" then return "verified" end
    return "already_identical"
  end
  if type(read_error) ~= "table" or read_error.code ~= "not_found" then return nil, "target_unavailable" end
  -- The cutover gate: a verify-only run proves the manifest is already in the
  -- destination and writes nothing at all. It fails on the first missing key
  -- instead of reporting a clean bill of health it cannot support.
  if mode == "verify" then return nil, "not_migrated" end
  if mode ~= "apply" then return "planned" end

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

-- A migration may only claim success when the destination acknowledges writes
-- after they are durable. PreppyDB exposes that configuration on /v1/version;
-- this probe turns it into an explicit answer instead of an assumption.
local function durability_evidence(version)
  local durability = type(version.durability) == "table" and version.durability or {}
  local signals = {}
  local sync_mode = version.sync_mode or durability.sync_mode
  local durable_writes = version.durable_writes
  if durable_writes == nil then durable_writes = durability.durable_writes end
  if type(durable_writes) == "boolean" then signals[#signals + 1] = durable_writes end
  if sync_mode ~= nil then
    local normalized = type(sync_mode) == "string" and sync_mode:lower() or nil
    if normalized == "always" then
      signals[#signals + 1] = true
    elseif normalized == "never" or normalized == "none" or normalized == "off"
      or normalized == "periodic" or normalized == "interval" or normalized == "batch" then
      signals[#signals + 1] = false
    else
      return "unverifiable", "unknown_sync_mode", sync_mode
    end
  end
  if #signals == 0 then return "unverifiable", "durability_not_reported", sync_mode end
  local durable, weak = false, false
  for _, signal in ipairs(signals) do
    if signal then durable = true else weak = true end
  end
  if durable and weak then return "unverifiable", "inconsistent_durability", sync_mode end
  if weak then return "not_durable", "writes_not_synced", sync_mode end
  return "durable", "durable_writes", sync_mode
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
  local state, detail, sync_mode = durability_evidence(version)
  if state ~= "durable" then return false, { code = state, detail = detail, sync_mode = sync_mode } end
  return true, {
    durability = state,
    detail = detail,
    sync_mode = sync_mode,
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
    if mode == "apply" and durability_state == "not_durable" then
      return false, { code = "not_durable", detail = durability_detail, summary = summary }
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
      local disposition, target_error = ensure_target(target, collection, key, converted,
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
