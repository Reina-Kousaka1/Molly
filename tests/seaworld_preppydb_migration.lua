package.path = "./?.lua;./?/init.lua;" .. package.path

local Migration = require("src.persistence.seaworld_preppydb_migration")
local target_json = require("src.preppydb.client")
local source_json = { null = {} }
local array_meta = { __jsontype = "array" }
source_json.array = function(value) return setmetatable(value or {}, array_meta) end

local sources = {
  molly_g_123 = { rows = { { id = "legacy", document = { data = {
    guild = "123", accounts = { u = { wallet = 20, note = source_json.null } },
    cases = {}, staff = {}, journal = source_json.array({}), receipts = { r = true }, next_case = 1,
  } } } } },
  molly_global_lifecycle = { rows = { { id = "legacy-global", document = { data = {
    pending = false, receipts = source_json.array({ "done" }),
  } } } } },
}
local source = {}
function source:query(query) return true, sources[query.collection] end

local target_rows, writes = {}, 0
local target = {}
function target:version() return { api_version = "1.0.0", sync_mode = "always" } end
function target:get(collection, key)
  local row = target_rows[collection .. "/" .. key]
  if not row then return nil, { code = "not_found", status = 404 } end
  return { value = row.value, version = row.version }
end
function target:transaction(operations)
  local pending = {}
  for _, operation in ipairs(operations) do
    local location = operation.collection .. "/" .. operation.key
    if target_rows[location] then return nil, { code = "conflict", status = 409 } end
    pending[#pending + 1] = { location = location, operation = operation }
  end
  writes = writes + 1
  for _, item in ipairs(pending) do
    target_rows[item.location] = { value = item.operation.value, version = 1 }
  end
  return { operations = #operations }
end

local options = {
  source = source, target = target, source_json = source_json, target_json = target_json,
  guilds = { "123" }, globals = { "lifecycle" },
}
local ok, report = Migration.run(options)
assert(ok, report and report.code or "migration dry-run failed")
assert(report.mode == "dry_run" and #report.guilds == 1 and #report.globals == 1)
assert(report.guilds[1].status == "planned" and writes == 0 and report.verified == 0)

options.apply = true
ok, report = Migration.run(options)
assert(ok and report.mode == "apply" and report.verified == 2 and writes == 2)
local guild = target_rows["molly_guild_state/123"].value
assert(guild.accounts.u.note == target_json.null)
assert(guild._molly_preppydb_state.origin == "migrated")
assert(target_rows["molly_guild_registry/123"].value.status == "migrated")
assert(getmetatable(target_rows["molly_global_state/lifecycle"].value.receipts).__jsontype == "array")

ok, report = Migration.run(options)
assert(ok and report.verified == 2 and writes == 2)
assert(report.guilds[1].status == "already_identical")

local invalid = {}
for key, value in pairs(options) do invalid[key] = value end
invalid.guilds = { "123", "123" }
local invalid_ok, invalid_reason = Migration.run(invalid)
assert(not invalid_ok and invalid_reason.code == "invalid_manifest")

local conflicting_target = {
  version = function() return { sync_mode = "always" } end,
  get = function() return { value = { guild = "123", accounts = { u = { wallet = 999 } } }, version = 1 } end,
  transaction = function() error("must not overwrite existing data") end,
}
local conflict_ok, conflict_reason = Migration.run({
  source = source, target = conflicting_target, source_json = source_json, target_json = target_json,
  guilds = { "123" }, globals = {}, apply = true,
})
assert(not conflict_ok and conflict_reason.code == "target_conflict")

local uncertain_target = {
  version = function() return { sync_mode = "always" } end,
  get = function() return nil, { code = "not_found", status = 404 } end,
  transaction = function() return nil, { code = "transport_error" } end,
}
local uncertain_ok, uncertain_reason = Migration.run({
  source = source, target = uncertain_target, source_json = source_json, target_json = target_json,
  guilds = { "123" }, globals = {}, apply = true,
})
assert(not uncertain_ok and uncertain_reason.code == "outcome_unknown")

-- Durability gate ------------------------------------------------------------
-- Evidence is only ever borrowed from the destination. Silence is not consent:
-- a destination that cannot answer is reported as unverifiable, never durable.
local function memory_target(version_response)
  local rows, count = {}, 0
  local store = {}
  function store:get(collection, key)
    local row = rows[collection .. "/" .. key]
    if not row then return nil, { code = "not_found", status = 404 } end
    return { value = row.value, version = row.version }
  end
  function store:transaction(operations)
    local pending = {}
    for _, operation in ipairs(operations) do
      local location = operation.collection .. "/" .. operation.key
      if rows[location] then return nil, { code = "conflict", status = 409 } end
      pending[#pending + 1] = { location = location, operation = operation }
    end
    count = count + 1
    for _, item in ipairs(pending) do
      rows[item.location] = { value = item.operation.value, version = 1 }
    end
    return { operations = #operations }
  end
  if version_response == "raising" then
    store.version = function() error("probe exploded") end
  elseif version_response ~= nil then
    store.version = function() return version_response end
  end
  return store, function() return count end
end

local function run_against(store, extra)
  local run_options = {
    source = source, target = store, source_json = source_json, target_json = target_json,
    guilds = { "123" }, globals = {},
  }
  for key, value in pairs(extra or {}) do run_options[key] = value end
  return Migration.run(run_options)
end

local durable_ok, durable_evidence = Migration.durability(memory_target({ api_version = "1.0.0", sync_mode = "always" }))
assert(durable_ok and durable_evidence.sync_mode == "always")

local flag_ok, flag_evidence = Migration.durability(memory_target({ durable_writes = true }))
assert(flag_ok and flag_evidence.detail == "durable_writes")

local nested_ok = Migration.durability(memory_target({ durability = { sync_mode = "always", durable_writes = true } }))
assert(nested_ok)

local unsynced_ok, unsynced = Migration.durability(memory_target({ sync_mode = "periodic", durable_writes = false }))
assert(not unsynced_ok and unsynced.code == "not_durable")

local inconsistent_target = memory_target({ sync_mode = "always", durable_writes = false })
local inconsistent_ok, inconsistent = Migration.durability(inconsistent_target)
assert(not inconsistent_ok and inconsistent.code == "unverifiable" and inconsistent.detail == "inconsistent_durability")

local silent_ok, silent = Migration.durability(memory_target({ api_version = "1.0.0", engine = "preppydb" }))
assert(not silent_ok and silent.code == "unverifiable" and silent.detail == "durability_not_reported")

local unreachable_ok, unreachable = Migration.durability({
  version = function() return nil, { code = "transport_error" } end,
})
assert(not unreachable_ok and unreachable.code == "unverifiable" and unreachable.reason == "transport_error")

local raising_ok, raising = Migration.durability(memory_target("raising"))
assert(not raising_ok and raising.code == "unverifiable" and raising.detail == "version_probe_failed")

-- An apply against unsynced writes is refused before the first insert.
local unsynced_store, unsynced_writes = memory_target({ sync_mode = "periodic" })
local refused_ok, refused = run_against(unsynced_store, { apply = true })
assert(not refused_ok and refused.code == "not_durable" and unsynced_writes() == 0)
assert(refused.summary.durability == "not_durable" and refused.summary.durable == false)

-- A destination that cannot answer still runs, but its summary says so.
local quiet_store, quiet_writes = memory_target(nil)
local quiet_ok, quiet = run_against(quiet_store, { apply = true })
assert(not quiet_ok and quiet.code == "durability_unverifiable" and quiet_writes() == 0)
assert(quiet.summary.durability == "unverifiable" and quiet.summary.durable == false)

local proven_store = memory_target({ sync_mode = "always" })
local proven_ok, proven = run_against(proven_store, { apply = true })
assert(proven_ok and proven.durability == "durable" and proven.durable == true)

-- Verify-only cutover gate ----------------------------------------------------
local verified_store, verified_writes = memory_target({ sync_mode = "always" })
local filled_ok = run_against(verified_store, { apply = true })
assert(filled_ok)

local gate_ok, gate = run_against(verified_store, { verify_only = true })
assert(gate_ok and gate.mode == "verify" and gate.verified == 1 and verified_writes() == 1)
assert(gate.guilds[1].status == "verified")

local empty_store, empty_writes = memory_target({ sync_mode = "always" })
local open_ok, open = run_against(empty_store, { verify_only = true })
assert(not open_ok and open.code == "not_migrated" and empty_writes() == 0)
assert(open.summary.failed.key == "123" and open.summary.mode == "verify")

local ambiguous_ok, ambiguous = run_against(verified_store, { verify_only = true, apply = true })
assert(not ambiguous_ok and ambiguous.code == "invalid_argument")

print("SeaWorld to PreppyDB migration mapping: pass")
