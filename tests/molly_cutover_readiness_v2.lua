package.path = "./?.lua;./?/init.lua;" .. package.path

local Json = require("src.preppydb.client")
local Gate = require("src.persistence.migration_write_gate")
local Snapshot = require("src.persistence.migration_snapshot")
local Manifest = require("src.persistence.migration_manifest")
local Resumable = require("src.persistence.resumable_migration")
local Simulator = require("src.persistence.cutover_simulator")
local Workflow = require("src.persistence.molly_cutover_readiness_v2")
local GuildStore = require("src.persistence.guild_store")
local GlobalStore = require("src.persistence.global_store")
local PreppyStore = require("src.persistence.preppydb_store")

local gate = Gate.new()
local busy_lease = assert(gate:enter())
local refused, busy_error = gate:quiesce()
assert(not refused and busy_error == "writes_in_flight")
assert(gate:leave(busy_lease, true))
assert(gate:write_epoch() == 1)

local docs = {
  molly_g_1001 = { guild = "1001", accounts = { a = { wallet = 50 }, b = { wallet = 8 } },
    inventory = {}, journal = Json.array({}), receipts = {} },
  molly_g_1002 = { guild = "1002", accounts = { c = { wallet = 70 } },
    inventory = {}, journal = Json.array({}), receipts = {} },
  molly_global_lifecycle = { state = "active", receipts = Json.array({ "r1" }) },
}
local provider = { snapshot_serial = 0, active = nil, synthetic_test_adapter = true }
function provider:begin_consistent_snapshot()
  self.snapshot_serial = self.snapshot_serial + 1
  self.active = "token-" .. self.snapshot_serial
  return self.active, { source_id = "synthetic-seaworld", snapshot_id = self.active,
    format_version = "synthetic-v1", write_epoch = 1, inventory_complete = true,
    inventory_scope = "molly_persistence" }
end
function provider:list_collections(token)
  assert(token == self.active)
  local names = {}
  for name in pairs(docs) do names[#names + 1] = name end
  return names
end
function provider:list_documents(token, collection, cursor, limit)
  assert(token == self.active and cursor == nil and type(limit) == "number"
    and limit >= 1 and limit <= Snapshot.limits.page_size)
  local key = collection:match("^molly_g_(%d+)$") or collection:match("^molly_global_(.+)$")
  return { { key = key, value = docs[collection] } }, nil
end
function provider:validate_snapshot(token)
  return token == self.active, { source_id = "synthetic-seaworld", snapshot_id = token,
    format_version = "synthetic-v1", write_epoch = 1, inventory_complete = true,
    inventory_scope = "molly_persistence" }
end
function provider:end_snapshot(token)
  assert(token == self.active)
  self.active = nil
  return true
end

local snapshot = assert(Snapshot.capture(provider, gate, Json, 2))
assert(snapshot.source_id == "synthetic-seaworld" and #snapshot.records == 3)
assert(gate:is_accepting() and provider.active == nil)
local manifest = assert(Manifest.build(snapshot, Json, "synthetic-preppydb"))
assert(manifest.schema_version == 2 and manifest.counts.total == 3)
assert(manifest.counts.areas.guild == 2 and manifest.counts.areas.global == 1)
assert(Manifest.verify(manifest, snapshot, Json, "synthetic-preppydb"))
local rebuilt_manifest = assert(Manifest.build(snapshot, Json, "synthetic-preppydb"))
assert(rebuilt_manifest.digest == manifest.digest and Json.is_array(manifest.records))
local altered = {}
for key, value in pairs(snapshot) do altered[key] = value end
altered.snapshot_id = "different"
local unchanged, changed_error = Manifest.verify(manifest, altered, Json, "synthetic-preppydb")
assert(not unchanged and changed_error == "manifest_mismatch")
local altered_records = {}
for index, record in ipairs(snapshot.records) do
  altered_records[index] = { collection = record.collection, key = record.key,
    area = record.area, value = record.value }
end
altered_records[1].value = { guild = altered_records[1].key, injected = true }
local altered_snapshot = { source_id = snapshot.source_id, snapshot_id = snapshot.snapshot_id,
  format_version = snapshot.format_version, write_epoch = snapshot.write_epoch,
  collections = snapshot.collections, records = altered_records }
local checksum_ok, checksum_error = Manifest.verify(manifest, altered_snapshot, Json, "synthetic-preppydb")
assert(not checksum_ok and checksum_error == "manifest_mismatch")
local bad_reference = { source_id = snapshot.source_id, snapshot_id = snapshot.snapshot_id,
  format_version = snapshot.format_version, write_epoch = snapshot.write_epoch,
  records = { { collection = "molly_g_1001", key = "1001", area = "guild",
    value = { guild = "somebody-else" } } } }
local reference_manifest, reference_error = Manifest.build(bad_reference, Json, "synthetic-preppydb")
assert(not reference_manifest and reference_error == "guild_reference_mismatch")

local no_capability = assert(Gate.new())
local unavailable, unavailable_error = Snapshot.capture({ query = function() end }, no_capability, Json)
assert(not unavailable and unavailable_error.code == "snapshot_capability_unavailable")
assert(no_capability:is_accepting())

local mutable_provider = {}
for key, value in pairs(provider) do mutable_provider[key] = value end
-- A changed source epoch invalidates the capture, and the gate is still released.
function mutable_provider:begin_consistent_snapshot()
  self.active = "drift"
  return self.active, { source_id = "synthetic-seaworld", snapshot_id = self.active,
    format_version = "synthetic-v1", write_epoch = 1, inventory_complete = true,
    inventory_scope = "molly_persistence" }
end
function mutable_provider:validate_snapshot(token)
  return true, { source_id = "synthetic-seaworld", snapshot_id = token,
    format_version = "synthetic-v1", write_epoch = 2, inventory_complete = true,
    inventory_scope = "molly_persistence" }
end
function mutable_provider:end_snapshot(token) self.active = nil; return token == "drift" end
local drift, drift_error = Snapshot.capture(mutable_provider, no_capability, Json)
assert(not drift and drift_error.code == "source_snapshot_changed")
assert(no_capability:is_accepting())

local unsupported_provider = {}
for key, value in pairs(provider) do unsupported_provider[key] = value end
function unsupported_provider:list_collections(token)
  assert(token == self.active)
  return { "molly_g_1001", "molly_g_1002", "molly_global_lifecycle", "molly_untracked_cache" }
end
local unsupported_snapshot, unsupported_error = Snapshot.capture(unsupported_provider, no_capability, Json)
assert(not unsupported_snapshot and unsupported_error.code == "unsupported_source_collection")
assert(no_capability:is_accepting() and unsupported_provider.active == nil)

docs.molly_g_1001.cycle = docs.molly_g_1001
local cyclic_snapshot, cyclic_error = Snapshot.capture(provider, no_capability, Json)
assert(not cyclic_snapshot and cyclic_error.code == "cyclic_value")
docs.molly_g_1001.cycle = nil
local deep = {}
local deep_cursor = deep
for _ = 1, Snapshot.limits.depth + 2 do deep_cursor.child = {}; deep_cursor = deep_cursor.child end
docs.molly_g_1001.deep = deep
local deep_snapshot, deep_error = Snapshot.capture(provider, no_capability, Json)
assert(not deep_snapshot and deep_error.code == "resource_limit")
docs.molly_g_1001.deep = nil
assert(no_capability:is_accepting() and provider.active == nil)

local incomplete_provider = {}
for key, value in pairs(provider) do incomplete_provider[key] = value end
function incomplete_provider:begin_consistent_snapshot()
  self.active = "incomplete"
  return self.active, { source_id = "synthetic-seaworld", snapshot_id = self.active,
    format_version = "synthetic-v1", write_epoch = 1, inventory_complete = false }
end
local incomplete, incomplete_error = Snapshot.capture(incomplete_provider, no_capability, Json)
assert(not incomplete and incomplete_error.code == "source_snapshot_unavailable")
assert(no_capability:is_accepting() and incomplete_provider.active == nil)

local empty_provider = { active = nil, synthetic_test_adapter = true }
function empty_provider:begin_consistent_snapshot()
  self.active = "empty"
  return self.active, { source_id = "synthetic-empty", snapshot_id = "empty",
    format_version = "synthetic-v1", write_epoch = 0, inventory_complete = true,
    inventory_scope = "molly_persistence" }
end
function empty_provider:list_collections(token) assert(token == self.active); return {} end
function empty_provider:list_documents() error("empty inventory must not request pages") end
function empty_provider:validate_snapshot(token)
  return token == self.active, { source_id = "synthetic-empty", snapshot_id = token,
    format_version = "synthetic-v1", write_epoch = 0, inventory_complete = true,
    inventory_scope = "molly_persistence" }
end
function empty_provider:end_snapshot(token) self.active = nil; return token == "empty" end
local empty_snapshot = assert(Snapshot.capture(empty_provider, no_capability, Json))
assert(#empty_snapshot.records == 0)
local empty_manifest = assert(Manifest.build(empty_snapshot, Json, "synthetic-empty-target"))
assert(empty_manifest.counts.total == 0 and empty_manifest.counts.bytes == 0)

local shared_gate = Gate.shared
local shared_token = assert(shared_gate:quiesce())
local untouched = { session = function() error("closed migration gate must reject before DB session") end }
local guild_write, guild_error = GuildStore.new(untouched):run("123", function() return true end)
local global_write, global_error = GlobalStore.new(untouched):run("lifecycle", {}, function() return true end)
local target_touched = false
local preppy_store = PreppyStore.new({
  get = function() target_touched = true; error("closed migration gate must reject before target read") end,
  transaction = function() target_touched = true; error("closed migration gate must reject before target write") end,
  encoded_size = function() return 1 end,
})
local preppy_write, preppy_error = preppy_store:run("123", function() return true, "x", true end)
local provisioned, provision_error = preppy_store:provision_new_guild("123")
assert(not guild_write and guild_error == "migration_write_stop")
assert(not global_write and global_error == "migration_write_stop")
assert(not preppy_write and preppy_error == "migration_write_stop")
assert(not provisioned and provision_error == "migration_write_stop" and not target_touched)
assert(shared_gate:release(shared_token))

local function target_new(identity)
  local target = { rows = {}, writes = 0, unknown_after_commit = false, fail_at = nil,
    inventory_calls = 0, inject_on_inventory = nil,
    synthetic_test_adapter = true, identity = identity or "synthetic-preppydb" }
  function target:version()
    return { api_version = "1.0.0", engine = "preppydb", sync_mode = "always", durable_writes = true }
  end
  function target:ready() return { ready = true, read_only = false } end
  function target:get(collection, key)
    local row = self.rows[collection .. "/" .. key]
    if not row then return nil, { code = "not_found", status = 404 } end
    return { value = row }
  end
  function target:inventory()
    self.inventory_calls = self.inventory_calls + 1
    if self.inject_on_inventory == self.inventory_calls then self.rows["foreign/new"] = { value = true } end
    local result = {}
    for location in pairs(self.rows) do
      local collection, key = location:match("^(.-)/(.*)$")
      result[collection] = result[collection] or {}
      result[collection][key] = true
    end
    return { complete = true, identity = self.identity, collections = result }
  end
  function target:transaction(operations)
    self.writes = self.writes + 1
    if self.fail_at == self.writes then return nil, { code = "io_error", status = 507 } end
    local pending = {}
    for _, operation in ipairs(operations) do
      local location = operation.collection .. "/" .. operation.key
      if self.rows[location] then return nil, { code = "conflict", status = 409 } end
      pending[#pending + 1] = { location = location, value = operation.value }
    end
    for _, item in ipairs(pending) do self.rows[item.location] = item.value end
    if self.unknown_after_commit then
      self.unknown_after_commit = false
      return nil, { code = "transport_error" }
    end
    return { operations = #pending }
  end
  return target
end

local target = target_new()
local changed_snapshot_target = target_new()
altered_snapshot.snapshot_id = altered.snapshot_id
local changed_source, changed_source_error = Resumable.run({ snapshot = altered_snapshot,
  manifest = manifest, target = changed_snapshot_target, json = Json,
  target_identity = "synthetic-preppydb", synthetic = true,
  source_adapter = "synthetic", target_adapter = "synthetic" })
assert(not changed_source and changed_source_error.code == "source_snapshot_changed")
assert(changed_snapshot_target.writes == 0)
local dry_target = target_new("synthetic-workflow-target")
local dry_ok, dry_result = Workflow.run({ source = provider, target = dry_target, json = Json,
  target_identity = "synthetic-workflow-target", mode = "dry_run", page_size = 2, synthetic = true })
assert(dry_ok and dry_result.records == 3 and dry_target.writes == 0)
assert(Gate.shared:is_accepting() and provider.active == nil)
local live_refusal, live_refusal_error = Workflow.run({ source = provider, target = dry_target, json = Json,
  target_identity = "live-target", mode = "apply" })
assert(not live_refusal and live_refusal_error.code == "live_import_disabled" and dry_target.writes == 0)
local workflow_target = target_new("synthetic-workflow-target")
local workflow_ok, workflow_result = Workflow.run({ source = provider, target = workflow_target, json = Json,
  target_identity = "synthetic-workflow-target", mode = "apply", page_size = 2, batch_size = 1, synthetic = true })
assert(workflow_ok and workflow_result.records == 3 and workflow_result.import.writes == 3)
assert(Gate.shared:is_accepting() and provider.active == nil)

target.unknown_after_commit = true
local import_ok, import_error = Resumable.run({ snapshot = snapshot, manifest = manifest,
  target = target, json = Json, target_identity = "synthetic-preppydb", batch_size = 1,
  synthetic = true, source_adapter = "synthetic", target_adapter = "synthetic" })
assert(not import_ok and import_error.code == "outcome_unknown")
local restarted_target = target_new()
restarted_target.rows = target.rows -- durable synthetic state survives client/process reconstruction
local resume_ok, resume = Resumable.run({ snapshot = snapshot, manifest = manifest,
  target = restarted_target, json = Json, target_identity = "synthetic-preppydb", batch_size = 1,
  synthetic = true, source_adapter = "synthetic", target_adapter = "synthetic" })
assert(resume_ok and resume.records == 3 and resume.resumed == 1 and resume.writes == 2)
local repeat_ok, repeated = Resumable.run({ snapshot = snapshot, manifest = manifest,
  target = restarted_target, json = Json, target_identity = "synthetic-preppydb", batch_size = 1,
  synthetic = true, source_adapter = "synthetic", target_adapter = "synthetic" })
assert(repeat_ok and repeated.writes == 0 and repeated.resumed == 3)

local interrupted_target = target_new()
interrupted_target.fail_at = 2
local interrupted_ok, interrupted_error = Resumable.run({ snapshot = snapshot, manifest = manifest,
  target = interrupted_target, json = Json, target_identity = "synthetic-preppydb", batch_size = 1,
  synthetic = true, source_adapter = "synthetic", target_adapter = "synthetic" })
assert(not interrupted_ok and interrupted_error.code == "batch_commit_failed")
local interrupted_restart = target_new()
interrupted_restart.rows = interrupted_target.rows
local resumed_after_restart, resumed_after_restart_report = Resumable.run({ snapshot = snapshot,
  manifest = manifest, target = interrupted_restart, json = Json,
  target_identity = "synthetic-preppydb", batch_size = 1,
  synthetic = true, source_adapter = "synthetic", target_adapter = "synthetic" })
assert(resumed_after_restart and resumed_after_restart_report.records == 3
  and resumed_after_restart_report.resumed == 1 and resumed_after_restart_report.writes == 2)

local nonpublishing_target = target_new()
local original_transaction = nonpublishing_target.transaction
function nonpublishing_target:transaction(operations)
  self.writes = self.writes + 1
  return { operations = #operations }
end
local unpublished, unpublished_error = Resumable.run({ snapshot = snapshot, manifest = manifest,
  target = nonpublishing_target, json = Json, target_identity = "synthetic-preppydb", batch_size = 1,
  synthetic = true, source_adapter = "synthetic", target_adapter = "synthetic" })
assert(not unpublished and unpublished_error.code == "batch_verification_failed")
assert(type(original_transaction) == "function")

local target_extra = target_new()
target_extra.rows["unrelated/secret"] = { marker = true }
local extra_ok, extra_error = Resumable.run({ snapshot = snapshot, manifest = manifest,
  target = target_extra, json = Json, target_identity = "synthetic-preppydb",
  synthetic = true, source_adapter = "synthetic", target_adapter = "synthetic" })
assert(not extra_ok and extra_error.code == "target_has_unmanifested_data")

local concurrent_extra = target_new()
concurrent_extra.inject_on_inventory = 2
local concurrent_ok, concurrent_error = Resumable.run({ snapshot = snapshot, manifest = manifest,
  target = concurrent_extra, json = Json, target_identity = "synthetic-preppydb", batch_size = 1,
  synthetic = true, source_adapter = "synthetic", target_adapter = "synthetic" })
assert(not concurrent_ok and concurrent_error.code == "target_has_unmanifested_data")

local not_durable = target_new()
function not_durable:version()
  return { api_version = "1.0.0", engine = "preppydb", sync_mode = "periodic", durable_writes = false }
end
local durability_ok, durability_error = Resumable.run({ snapshot = snapshot, manifest = manifest,
  target = not_durable, json = Json, target_identity = "synthetic-preppydb",
  synthetic = true, source_adapter = "synthetic", target_adapter = "synthetic" })
assert(not durability_ok and durability_error.code == "not_durable" and not_durable.writes == 0)

local simulator = Simulator.new()
assert(simulator:stop_writes())
assert(simulator:import_complete())
assert(simulator:rollback())
assert(simulator.phase == "seaworld_active")
assert(simulator:stop_writes() and simulator:import_complete() and simulator:verify() and simulator:switch())
assert(simulator:rollback() and simulator.phase == "seaworld_active")
assert(simulator:stop_writes() and simulator:import_complete() and simulator:verify() and simulator:switch())
assert(simulator:release_writes() and simulator:record_write("preppydb"))
local rolled_back, rollback_error = simulator:rollback()
assert(not rolled_back and rollback_error == "rollback_requires_write_stop")
assert(simulator.phase == "maintenance")
local unreconciled, reconciliation_error = simulator:rollback(false)
assert(not unreconciled and reconciliation_error == "reverse_reconciliation_required")
local weak_evidence, weak_error = simulator:rollback(true)
assert(not weak_evidence and weak_error == "reverse_reconciliation_required")
local evidence = { verified = true, source_manifest_digest = "abc", target_manifest_digest = "abc",
  source_snapshot_id = "snapshot", target_snapshot_id = "snapshot", source_records = 3, target_records = 3 }
assert(simulator:rollback(evidence) and simulator.phase == "seaworld_reconciled_maintenance")

print("Molly cutover readiness V2: synthetic snapshot, manifest, resumable import, policy and rollback pass")
