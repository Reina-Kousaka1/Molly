-- Pure state-machine simulator. Never changes Molly's configured backend.
local Simulator = {}

function Simulator.new()
  return setmetatable({ phase = "seaworld_active", writes = { seaworld = 0, preppydb = 0 },
    verified = false, maintenance = false }, { __index = Simulator })
end

function Simulator:stop_writes()
  if self.phase ~= "seaworld_active" then return false, "invalid_transition" end
  self.maintenance, self.phase = true, "maintenance"
  return true
end

function Simulator:import_complete()
  if not self.maintenance or self.phase ~= "maintenance" then return false, "invalid_transition" end
  self.phase = "imported_unreleased"
  return true
end

function Simulator:verify()
  if self.phase ~= "imported_unreleased" then return false, "invalid_transition" end
  self.verified, self.phase = true, "verified_unreleased"
  return true
end

function Simulator:switch()
  if self.phase ~= "verified_unreleased" or not self.maintenance then return false, "cutover_not_qualified" end
  self.phase = "preppydb_unreleased"
  return true
end

function Simulator:release_writes()
  if self.phase ~= "preppydb_unreleased" then return false, "cutover_not_qualified" end
  self.maintenance, self.phase = false, "preppydb_active"
  return true
end

function Simulator:record_write(backend)
  if backend == "preppydb" and self.phase ~= "preppydb_active" then return false, "writes_not_released" end
  if backend == "seaworld" and self.phase ~= "seaworld_active" then return false, "writes_not_released" end
  if backend ~= "preppydb" and backend ~= "seaworld" then return false, "invalid_backend" end
  self.writes[backend] = self.writes[backend] + 1
  return true
end

function Simulator:rollback(reconciled)
  if self.phase == "preppydb_active" and self.writes.preppydb > 0 then
    if not self.maintenance then
      self.maintenance, self.phase = true, "preppydb_maintenance"
      return false, "rollback_requires_write_stop"
    end
  end
  if self.phase == "preppydb_maintenance" then
    if type(reconciled) ~= "table" or reconciled.verified ~= true
      or reconciled.source_manifest_digest == nil
      or reconciled.source_manifest_digest ~= reconciled.target_manifest_digest
      or reconciled.source_snapshot_id == nil
      or reconciled.source_snapshot_id ~= reconciled.target_snapshot_id
      or type(reconciled.source_records) ~= "number"
      or reconciled.source_records ~= reconciled.target_records then
      return false, "reverse_reconciliation_required"
    end
    self.phase = "seaworld_reconciled_maintenance"
    return true
  end
  if self.phase == "preppydb_unreleased" or self.phase == "imported_unreleased"
    or self.phase == "verified_unreleased" or self.phase == "maintenance" then
    self.phase = "seaworld_active"
    self.maintenance = false
    return true
  end
  return false, "rollback_not_available"
end

return Simulator
