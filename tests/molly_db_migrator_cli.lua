package.path = "./?.lua;./?/init.lua;" .. package.path

local Cli = require("src.persistence.molly_db_migrator_cli")
local Policy = require("src.persistence.molly_migration_policy")

local function capture(args)
  local out, err = {}, {}
  local code = Cli.execute(args,
    function(value) out[#out + 1] = value end,
    function(value) err[#err + 1] = value end)
  return code, table.concat(out), table.concat(err)
end

local blockers = Policy.live_blockers()
local allowed, live_blockers = Policy.live_migration_allowed()
assert(allowed == false and #live_blockers == #blockers)
local required_blockers = {
  "preppydb_virtual_currency_policy_scope_not_approved",
  "seaworld_snapshot_export_not_integrated_with_molly_transport",
  "preppydb_inventory_api_not_released_or_integrated",
  "rollback_after_preppydb_writes_unsupported",
  "raspberry_pi_arm64_hardware_not_qualified",
}
local seen = {}
for _, blocker in ipairs(live_blockers) do seen[blocker] = true end
for _, blocker in ipairs(required_blockers) do
  assert(seen[blocker], "missing live blocker: " .. blocker)
end
assert(#blockers > 0)
local code, output = capture({ "preflight" })
assert(code ~= 0 and output:find("BLOCKED", 1, true))
assert(output:find("preppydb_virtual_currency_policy_scope_not_approved", 1, true))

for _, command in ipairs({
  { "backup" },
  { "migrate", "--dry-run" },
  { "verify" },
  { "cutover", "--confirm" },
}) do
  local blocked_code, _, diagnostic = capture(command)
  assert(blocked_code ~= 0 and diagnostic:find("no database was contacted", 1, true))
end

local no_confirmation, _, confirmation_error = capture({ "cutover" })
assert(no_confirmation == 2 and confirmation_error:find("explicit_confirmation_required", 1, true))
local invalid_option = capture({ "migrate", "--apply", "--synthetic" })
assert(invalid_option == 2)

local dry_code, dry_output, dry_error = capture({ "migrate", "--dry-run", "--synthetic" })
assert(dry_code == 0, dry_error)
assert(dry_output:find("synthetic only: mode=dry_run", 1, true))
assert(dry_output:find("records=4", 1, true))

local full_code, full_output, full_error = capture({ "migrate", "--synthetic" })
assert(full_code == 0, full_error)
assert(full_output:find("synthetic only: mode=synthetic_apply_verify", 1, true))
assert(full_output:find("records=4 verified=4", 1, true))

local verify_code, verify_output, verify_error = capture({ "verify", "--synthetic" })
assert(verify_code == 0, verify_error)
assert(verify_output:find("synthetic only: verified=4", 1, true))

local large_ok, large_result = Cli.run_synthetic("apply_and_verify", 50)
assert(large_ok, large_result and large_result.code)
assert(large_result.records == 51 and large_result.verified == 51)
local empty_ok, empty_result = Cli.run_synthetic("apply_and_verify", 0)
assert(not empty_ok and empty_result.code == "invalid_synthetic_size")

print("Molly one-shot migrator CLI policy and synthetic transfer: pass")
