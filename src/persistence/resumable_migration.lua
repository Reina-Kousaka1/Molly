-- Capability-gated insert-only import. Each batch's documents and durable
-- receipt are committed in one PreppyDB multi-document transaction.
local Migration = {}
local Durability = require("src.persistence.preppydb_durability")
local Manifest = require("src.persistence.migration_manifest")
local MAX_BATCH_RECORDS, MAX_RECORD_BYTES = 25, 3 * 1024 * 1024
local STATE_COLLECTION, GUILD_COLLECTION, GLOBAL_COLLECTION =
  "molly_migration_batches", "molly_guild_state", "molly_global_state"

local function encoded(json, value)
  local ok, result = pcall(json.encode, value)
  if ok and type(result) == "string" then return result end
end

local function same(json, a, b)
  local ea, eb = encoded(json, a), encoded(json, b)
  return ea ~= nil and ea == eb
end

local function target_map(record)
  if record.area == "guild" then
    if record.value.guild ~= record.key or record.value._molly_preppydb_state ~= nil then return nil end
    local value = {}
    for key, item in pairs(record.value) do value[key] = item end
    value._molly_preppydb_state = { version = 1, origin = "migrated" }
    return {
      { collection = GUILD_COLLECTION, key = record.key, value = value },
      { collection = "molly_guild_registry", key = record.key,
        value = { guild = record.key, version = 1, status = "migrated" } },
    }
  end
  if record.area == "global" then
    return { { collection = GLOBAL_COLLECTION, key = record.key, value = record.value } }
  end
end

local function read(target, collection, key)
  local called, value, err = pcall(target.get, target, collection, key)
  if not called then return nil, "target_unavailable" end
  if value then return value end
  if type(err) == "table" and err.code == "not_found" then return nil end
  return nil, "target_unavailable"
end

local function batch_id(manifest, first, last)
  return string.format("v2-%s-%06d-%06d", manifest.digest, first, last)
end

function Migration.run(options)
  options = options or {}
  if options.synthetic ~= true or options.source_adapter ~= "synthetic"
    or options.target_adapter ~= "synthetic" then
    return false, { code = "live_import_disabled" }
  end
  local snapshot, manifest, target, json = options.snapshot, options.manifest, options.target, options.json
  if type(snapshot) ~= "table" or type(snapshot.records) ~= "table"
    or type(manifest) ~= "table" or type(manifest.digest) ~= "string"
    or type(target) ~= "table" or type(target.get) ~= "function"
    or type(target.transaction) ~= "function" or type(target.inventory) ~= "function"
    or type(target.ready) ~= "function" or type(json) ~= "table"
    or type(json.encode) ~= "function" then return false, { code = "invalid_argument" } end
  if type(snapshot.source_id) ~= "string" or not snapshot.source_id:match("^synthetic%-")
    or type(options.target_identity) ~= "string" or not options.target_identity:match("^synthetic%-") then
    return false, { code = "synthetic_identity_required" }
  end
  if type(options.target_identity) ~= "string" or type(manifest.target) ~= "table"
    or type(manifest.source) ~= "table" or manifest.target.identity ~= options.target_identity
    or manifest.source.snapshot_id ~= snapshot.snapshot_id
    or manifest.source.write_epoch ~= snapshot.write_epoch then
    return false, { code = "source_snapshot_changed" }
  end
  local manifest_ok, manifest_error = Manifest.verify(manifest, snapshot, json, options.target_identity)
  if not manifest_ok then return false, { code = manifest_error } end
  local batch_size = options.batch_size or MAX_BATCH_RECORDS
  if type(batch_size) ~= "number" or batch_size < 1 or batch_size > MAX_BATCH_RECORDS
    or batch_size % 1 ~= 0 then return false, { code = "invalid_batch_size" } end
  local version_ok, version = pcall(target.version, target)
  if not version_ok or type(version) ~= "table" then return false, { code = "durability_unverifiable" } end
  local durability = Durability.classify(version)
  if durability ~= "durable" then return false, { code = durability or "durability_unverifiable" } end
  local ready_ok, readiness = pcall(target.ready, target)
  if not ready_ok or type(readiness) ~= "table" or readiness.ready ~= true or readiness.read_only ~= false then
    return false, { code = "target_not_write_ready" }
  end

  local inventory_ok, inventory = pcall(target.inventory, target)
  if not inventory_ok or type(inventory) ~= "table" or inventory.complete ~= true
    or inventory.identity ~= options.target_identity or type(inventory.collections) ~= "table" then
    return false, { code = "target_inventory_unavailable" }
  end
  local allowed = {}
  for _, record in ipairs(snapshot.records) do
    local mapped = target_map(record)
    if not mapped then return false, { code = "unsupported_or_invalid_record" } end
    for _, item in ipairs(mapped) do
      allowed[item.collection] = allowed[item.collection] or {}
      allowed[item.collection][item.key] = true
    end
  end
  local expected_batch_count = math.ceil(#snapshot.records / batch_size)
  for index = 1, expected_batch_count do
    local first = (index - 1) * batch_size + 1
    local last = math.min(first + batch_size - 1, #snapshot.records)
    allowed[STATE_COLLECTION] = allowed[STATE_COLLECTION] or {}
    allowed[STATE_COLLECTION][batch_id(manifest, first, last)] = true
  end
  for collection, keys in pairs(inventory.collections) do
    if type(collection) ~= "string" or type(keys) ~= "table" then
      return false, { code = "target_inventory_invalid" }
    end
    if not allowed[collection] then return false, { code = "target_has_unmanifested_data", collection = collection } end
    for key in pairs(keys) do
      if not allowed[collection] or not allowed[collection][key] then
        return false, { code = "target_has_unmanifested_data", collection = collection }
      end
    end
  end

  local batches, writes, resumed = 0, 0, 0
  for first = 1, #snapshot.records, batch_size do
    local last = math.min(first + batch_size - 1, #snapshot.records)
    batches = batches + 1
    local id, expected = batch_id(manifest, first, last), {}
    local operations = {}
    for index = first, last do
      local record = snapshot.records[index]
      local mapped = target_map(record)
      if not mapped then return false, { code = "unsupported_or_invalid_record", record = index } end
      for _, item in ipairs(mapped) do
        local body = encoded(json, item.value)
        if not body then return false, { code = "serialization_failed" } end
        if #body > MAX_RECORD_BYTES then return false, { code = "resource_limit" } end
        local current, read_error = read(target, item.collection, item.key)
        if read_error then return false, { code = read_error } end
        if current and not same(json, current.value, item.value) then
          return false, { code = "target_conflict", collection = item.collection, key = item.key }
        end
        expected[#expected + 1] = { collection = item.collection, key = item.key, value = item.value }
        if not current then operations[#operations + 1] = {
          op = "put", collection = item.collection, key = item.key,
          expected_version = 0, value = item.value,
        } end
      end
    end

    local receipt, receipt_error = read(target, STATE_COLLECTION, id)
    if receipt_error then return false, { code = receipt_error } end
    if receipt then
      if type(receipt.value) ~= "table" or receipt.value.manifest_digest ~= manifest.digest
        or receipt.value.batch_id ~= id then
        return false, { code = "batch_receipt_conflict" }
      end
      for _, item in ipairs(expected) do
        local current, current_error = read(target, item.collection, item.key)
        if current_error then return false, { code = current_error } end
        if not current or not same(json, current.value, item.value) then
          return false, { code = "batch_receipt_data_mismatch" }
        end
      end
      resumed = resumed + 1
    else
      -- If data exists without its atomic receipt, a prior partial application
      -- is impossible under the required transaction contract; fail closed.
      local already_present = #operations < #expected
      if already_present then return false, { code = "unreceipted_batch_data" } end
      operations[#operations + 1] = { op = "put", collection = STATE_COLLECTION, key = id,
        expected_version = 0, value = { batch_id = id, manifest_digest = manifest.digest,
          first = first, last = last, count = #expected } }
      local called, result, write_error = pcall(target.transaction, target, operations)
      if not called then return false, { code = "outcome_unknown", batch_id = id } end
      if not result then
        if type(write_error) == "table" and (write_error.code == "transport_error"
          or write_error.status == nil or write_error.status >= 500) then
          return false, { code = "outcome_unknown", batch_id = id }
        end
        return false, { code = "batch_commit_failed", batch_id = id }
      end
      writes = writes + 1
    end
    for _, item in ipairs(expected) do
      local current, current_error = read(target, item.collection, item.key)
      if current_error then return false, { code = current_error } end
      if not current or not same(json, current.value, item.value) then
        return false, { code = "batch_verification_failed", batch_id = id }
      end
    end
  end
  local final_ok, final_inventory = pcall(target.inventory, target)
  if not final_ok or type(final_inventory) ~= "table" or final_inventory.complete ~= true
    or final_inventory.identity ~= options.target_identity or type(final_inventory.collections) ~= "table" then
    return false, { code = "target_inventory_unavailable" }
  end
  for collection, keys in pairs(final_inventory.collections) do
    if type(collection) ~= "string" or type(keys) ~= "table" or not allowed[collection] then
      return false, { code = "target_has_unmanifested_data", collection = tostring(collection) }
    end
    for key in pairs(keys) do
      if not allowed[collection][key] then return false, { code = "target_has_unmanifested_data", collection = collection } end
    end
  end
  return true, { batches = batches, writes = writes, resumed = resumed, records = #snapshot.records,
    manifest_digest = manifest.digest }
end

Migration.limits = { batch_records = MAX_BATCH_RECORDS, record_bytes = MAX_RECORD_BYTES }
return Migration
