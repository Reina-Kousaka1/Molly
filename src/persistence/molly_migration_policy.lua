-- Live SeaWorld -> PreppyDB Economy migration remains disabled until every
-- blocker below has been independently qualified and the virtual-currency
-- policy explicitly permits Molly's workload. CLI flags cannot override this.
local Policy = {}

local BLOCKERS = {
  "virtual_currency_policy",
  "consistent_seaworld_snapshot_unqualified",
  "seaworld_consistent_snapshot_api_missing",
  "complete_source_manifest_unqualified",
  "source_write_stop_unqualified",
  "preppydb_complete_destination_inventory_unavailable",
  "resumable_import_not_production_qualified",
  "live_backup_restore_unqualified",
  "rollback_after_preppydb_writes_unsupported",
  "reverse_reconciliation_unimplemented",
  "preppydb_durability_revision_not_released",
}

function Policy.live_blockers()
  local result = {}
  for index, blocker in ipairs(BLOCKERS) do result[index] = blocker end
  return result
end

function Policy.live_migration_allowed()
  return false, Policy.live_blockers()
end

return Policy
