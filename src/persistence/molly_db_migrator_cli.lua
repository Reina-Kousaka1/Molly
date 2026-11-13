-- Safe operator CLI policy and synthetic qualification path.
-- No command in this module opens a SeaWorld or PreppyDB connection.
local Cli = {}
local Policy = require("src.persistence.molly_migration_policy")
local Migration = require("src.persistence.seaworld_preppydb_migration")
local Json = require("src.preppydb.client")

local USAGE = [[
usage:
  luvit ops/molly-db-migrate.lua preflight
  luvit ops/molly-db-migrate.lua backup
  luvit ops/molly-db-migrate.lua migrate --dry-run
  luvit ops/molly-db-migrate.lua verify
  luvit ops/molly-db-migrate.lua cutover --confirm

Synthetic-only qualification (never contacts either database):
  luvit ops/molly-db-migrate.lua migrate --dry-run --synthetic
  luvit ops/molly-db-migrate.lua migrate --synthetic
  luvit ops/molly-db-migrate.lua verify --synthetic

Live backup, import, verification and cutover are blocked by current policy
and missing source/restore qualifications. No flag overrides those blockers.
]]

local function emit(writer, line)
  writer((line or "") .. "\n")
end

local function memory_adapters(guild_count)
  guild_count = guild_count or 3
  if type(guild_count) ~= "number" or guild_count < 1 or guild_count > 100
    or guild_count % 1 ~= 0 then
    return nil, nil, nil, "invalid_synthetic_size"
  end

  local source_rows, target_rows, writes = {}, {}, 0
  local guilds = {}
  for index = 1, guild_count do
    local guild = string.format("900000000000000%04d", index)
    guilds[index] = guild
    source_rows["molly_g_" .. guild] = {
      guild = guild,
      accounts = { ["synthetic-user"] = { wallet = index * 100, bank = index * 1000 } },
      inventory = { tokens = index },
      shop_purchases = {},
      journal = Json.array({ { id = "synthetic-" .. index, amount = index } }),
      receipts = { ["synthetic-request-" .. index] = { status = "committed" } },
    }
  end
  source_rows.molly_global_lifecycle = {
    lifecycle = { version = 1, state = "synthetic" },
    receipts = Json.array({ "synthetic-lifecycle-receipt" }),
  }

  local source = {}
  function source:query(request)
    local value = source_rows[request.collection]
    if not value then return false, "not_found" end
    return true, { rows = { { id = "synthetic-source", document = { data = value } } } }
  end

  local target = {}
  function target:version()
    return {
      api_version = "1.0.0", engine = "preppydb",
      sync_mode = "always", durable_writes = true,
    }
  end
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
      pending[#pending + 1] = { location = location, value = operation.value }
    end
    -- Publish only after the whole operation set has been validated.
    writes = writes + 1
    for _, item in ipairs(pending) do
      target_rows[item.location] = { value = item.value, version = 1 }
    end
    return { operations = #operations }
  end

  return source, target, {
    guilds = guilds,
    globals = { "lifecycle" },
    source_json = Json,
    target_json = Json,
    target_rows = target_rows,
    write_count = function() return writes end,
    source_rows = source_rows,
  }
end

local function run_synthetic(mode, guild_count)
  local source, target, fixture, fixture_error = memory_adapters(guild_count)
  if not source then return false, { code = fixture_error } end
  local options = {
    source = source,
    target = target,
    source_json = fixture.source_json,
    target_json = fixture.target_json,
    guilds = fixture.guilds,
    globals = fixture.globals,
  }

  if mode == "dry_run" then
    local before = fixture.write_count()
    local ok, result = Migration.run(options)
    if not ok then return false, { code = "synthetic_dry_run_failed", cause = result.code } end
    if result.mode ~= "dry_run" or result.verified ~= 0 or fixture.write_count() ~= before
      or next(fixture.target_rows) ~= nil then
      return false, { code = "synthetic_dry_run_mutated_target" }
    end
    return true, { mode = "dry_run", records = #fixture.guilds + #fixture.globals, verified = 0 }
  end

  if mode ~= "apply_and_verify" then return false, { code = "invalid_synthetic_mode" } end
  options.apply = true
  local applied, apply_result = Migration.run(options)
  if not applied then return false, { code = "synthetic_apply_failed", cause = apply_result.code } end
  local writes_after_apply = fixture.write_count()
  options.apply = nil
  options.verify_only = true
  local verified, verify_result = Migration.run(options)
  if not verified or verify_result.mode ~= "verify"
    or verify_result.verified ~= #fixture.guilds + #fixture.globals then
    return false, { code = "synthetic_verify_failed", cause = verify_result and verify_result.code }
  end
  options.verify_only = nil
  options.apply = true
  local repeated, repeat_result = Migration.run(options)
  if not repeated or repeat_result.verified ~= #fixture.guilds + #fixture.globals
    or fixture.write_count() ~= writes_after_apply then
    return false, { code = "synthetic_repeat_not_idempotent", cause = repeat_result and repeat_result.code }
  end
  return true, {
    mode = "synthetic_apply_verify",
    records = #fixture.guilds + #fixture.globals,
    verified = verify_result.verified,
    writes = writes_after_apply,
    repeated_writes = fixture.write_count(),
  }
end

Cli.run_synthetic = run_synthetic
Cli.usage = USAGE

local function parse(args)
  if type(args) ~= "table" or type(args[1]) ~= "string" then
    return nil, "missing_command"
  end
  local parsed = { command = args[1] }
  local known = {
    preflight = true, backup = true, migrate = true, verify = true, cutover = true,
  }
  if not known[parsed.command] then return nil, "unknown_command" end
  for index = 2, #args do
    local option = args[index]
    if option == "--dry-run" then
      if parsed.dry_run then return nil, "duplicate_option" end
      parsed.dry_run = true
    elseif option == "--synthetic" then
      if parsed.synthetic then return nil, "duplicate_option" end
      parsed.synthetic = true
    elseif option == "--confirm" then
      if parsed.confirm then return nil, "duplicate_option" end
      parsed.confirm = true
    elseif option:match("^%-%-") then
      return nil, "unknown_option"
    else
      return nil, "unexpected_argument"
    end
  end
  if parsed.dry_run and parsed.command ~= "migrate" then return nil, "invalid_option" end
  if parsed.confirm and parsed.command ~= "cutover" then return nil, "invalid_option" end
  if parsed.synthetic and parsed.command ~= "migrate" and parsed.command ~= "verify" then
    return nil, "invalid_option"
  end
  if parsed.command == "migrate" and not parsed.dry_run and not parsed.synthetic then
    return nil, "live_import_requires_policy_clearance"
  end
  if parsed.command == "cutover" and not parsed.confirm then return nil, "explicit_confirmation_required" end
  return parsed
end

function Cli.execute(args, stdout, stderr)
  stdout = stdout or function(value) io.stdout:write(value) end
  stderr = stderr or function(value) io.stderr:write(value) end
  local parsed, parse_error = parse(args)
  if type(args) == "table" and args[1] == "--help" then
    emit(stdout, USAGE)
    return 0
  end
  if not parsed then
    emit(stderr, "molly-db-migrate: " .. tostring(parse_error))
    emit(stderr, USAGE)
    return 2
  end

  if parsed.command == "migrate" and parsed.synthetic then
    local mode = parsed.dry_run and "dry_run" or "apply_and_verify"
    local ok, result = run_synthetic(mode)
    if not ok then
      emit(stderr, "molly-db-migrate: synthetic migration failed (" .. tostring(result.code) .. ")")
      return 1
    end
    emit(stdout, string.format("synthetic only: mode=%s records=%d verified=%d",
      result.mode, result.records, result.verified))
    return 0
  end

  if parsed.command == "verify" and parsed.synthetic then
    local ok, result = run_synthetic("apply_and_verify")
    if not ok then
      emit(stderr, "molly-db-migrate: synthetic verification failed (" .. tostring(result.code) .. ")")
      return 1
    end
    emit(stdout, string.format("synthetic only: verified=%d", result.verified))
    return 0
  end

  if parsed.command == "preflight" then
    local allowed, blockers = Policy.live_migration_allowed()
    if allowed then
      emit(stdout, "live migration preflight: passed")
      return 0
    end
    emit(stdout, "live migration preflight: BLOCKED")
    for _, blocker in ipairs(blockers) do emit(stdout, "  " .. blocker) end
    return 1
  end

  -- These paths intentionally perform no network, filesystem, or database IO.
  local _, blockers = Policy.live_migration_allowed()
  emit(stderr, "molly-db-migrate: live " .. parsed.command .. " is blocked; no database was contacted")
  for _, blocker in ipairs(blockers) do emit(stderr, "  " .. blocker) end
  return 1
end

return Cli
