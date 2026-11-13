-- Coordinates only the gated snapshot + manifest + import protocol. All
-- dependencies are injected; no module opens a connection or changes backend.
local Workflow = {}
local GateModule = require("src.persistence.migration_write_gate")
local Snapshot = require("src.persistence.migration_snapshot")
local Manifest = require("src.persistence.migration_manifest")
local Resumable = require("src.persistence.resumable_migration")
local gate = GateModule.shared

function Workflow.run(options)
  options = options or {}
  if options.mode ~= "dry_run" and options.mode ~= "apply" then
    return false, { code = "invalid_mode" }
  end
  if type(options.source) ~= "table" or type(options.target) ~= "table"
    or type(options.json) ~= "table" or type(options.target_identity) ~= "string" then
    return false, { code = "invalid_argument" }
  end
  if options.synthetic ~= true or options.source.synthetic_test_adapter ~= true
    or options.target.synthetic_test_adapter ~= true
    or not options.target_identity:match("^synthetic%-") then
    return false, { code = "live_import_disabled" }
  end
  local gate_token, gate_error = gate:quiesce()
  if not gate_token then return false, { code = gate_error } end
  local snapshot, manifest, lease, failure, import_result
  local ok = pcall(function()
    local snapshot_error
    snapshot, snapshot_error, lease = Snapshot.capture(options.source, gate, options.json,
      options.page_size, gate_token)
    if not snapshot then failure = snapshot_error; return end
    manifest, snapshot_error = Manifest.build(snapshot, options.json, options.target_identity)
    if not manifest then failure = { code = snapshot_error }; return end
    if options.mode == "dry_run" then
      return
    end
    local imported, result = Resumable.run({ snapshot = snapshot, manifest = manifest,
      target = options.target, json = options.json, target_identity = options.target_identity,
      batch_size = options.batch_size, synthetic = true,
      source_adapter = "synthetic", target_adapter = "synthetic" })
    if not imported then failure = result; return end
    import_result = result
  end)
  if not ok then failure = { code = "cutover_workflow_error" } end

  local source_closed = true
  if lease and lease.token then
    local called, ended = pcall(options.source.end_snapshot, options.source, lease.token)
    source_closed = called and ended == true
  end
  local gate_released, gate_release_error = gate:release(gate_token)
  if not source_closed then failure = { code = "source_snapshot_release_failed" } end
  if not gate_released then failure = { code = "write_gate_release_failed", detail = gate_release_error } end
  if failure then return false, failure end
  return true, { mode = options.mode, manifest = manifest,
    records = manifest.counts.total, manifest_digest = manifest.digest, import = import_result }
end

return Workflow
