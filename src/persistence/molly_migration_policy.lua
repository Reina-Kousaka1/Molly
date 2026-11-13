-- Live SeaWorld -> PreppyDB Economy migration remains disabled until every
-- blocker below has been independently qualified and the virtual-currency
-- policy explicitly permits Molly's workload. CLI flags cannot override this.
local Policy = {}

local BLOCKERS = {
  "preppydb_virtual_currency_policy_scope_not_approved",
  "seaworld_snapshot_export_not_integrated_with_molly_transport",
  "complete_molly_source_manifest_not_independently_verified",
  "external_seaworld_writer_quiescence_not_proven",
  "preppydb_inventory_api_not_released_or_integrated",
  "resumable_import_real_database_adapters_not_qualified",
  "live_backup_restore_unqualified",
  "rollback_after_preppydb_writes_unsupported",
  "reverse_reconciliation_unimplemented",
  "preppydb_durability_revision_not_released",
  "raspberry_pi_arm64_hardware_not_qualified",
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
