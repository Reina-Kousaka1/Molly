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
function target:get(collection, key)
  local row = target_rows[collection .. "/" .. key]
  if not row then return nil, { code = "not_found", status = 404 } end
  return { value = row.value, version = row.version }
end
function target:transaction(operations)
  assert(#operations == 1)
  local operation = operations[1]
  local location = operation.collection .. "/" .. operation.key
  if target_rows[location] then return nil, { code = "conflict", status = 409 } end
  writes = writes + 1
  target_rows[location] = { value = operation.value, version = 1 }
  return { operations = 1 }
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
  get = function() return { value = { guild = "123", accounts = { u = { wallet = 999 } } }, version = 1 } end,
  transaction = function() error("must not overwrite existing data") end,
}
local conflict_ok, conflict_reason = Migration.run({
  source = source, target = conflicting_target, source_json = source_json, target_json = target_json,
  guilds = { "123" }, globals = {}, apply = true,
})
assert(not conflict_ok and conflict_reason.code == "target_conflict")

local uncertain_target = {
  get = function() return nil, { code = "not_found", status = 404 } end,
  transaction = function() return nil, { code = "transport_error" } end,
}
local uncertain_ok, uncertain_reason = Migration.run({
  source = source, target = uncertain_target, source_json = source_json, target_json = target_json,
  guilds = { "123" }, globals = {}, apply = true,
})
assert(not uncertain_ok and uncertain_reason.code == "outcome_unknown")

print("SeaWorld to PreppyDB migration mapping: pass")
