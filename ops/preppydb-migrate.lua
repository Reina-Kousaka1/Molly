-- Operator entry point for the explicit-manifest SeaWorld -> PreppyDB migration.
--
-- This is deliberately NOT part of Molly's startup and is not exercised by CI:
-- it needs the deployed Luvit runtime (`uv`, `coro-net`, `json`) and a real
-- SeaWorld socket plus a reachable PreppyDB. It never discovers data on its
-- own; the manifest is the complete list of guild and global stores that the
-- operator has established must be migrated.
--
--   luvit ops/preppydb-migrate.lua --manifest=manifest.json            # dry run
--   luvit ops/preppydb-migrate.lua --manifest=manifest.json --apply    # insert
--   luvit ops/preppydb-migrate.lua --manifest=manifest.json --verify   # cutover gate
--
-- Exit codes: 0 = the requested mode succeeded, 1 = the migration or the
-- verification failed, 2 = the invocation or the manifest is unusable.
--
-- Manifest (JSON):
--   { "guilds": ["1234"], "globals": ["lifecycle"],
--     "guild_collection": "molly_guild_state", "global_collection": "molly_global_state" }
--
-- Connection settings come from the flags below or, when omitted, from the
-- same environment variables Molly's service uses (MOLLY_SEAWORLD_SOCKET,
-- MOLLY_PREPPYDB_URL, MOLLY_PREPPYDB_TOKEN, MOLLY_PREPPYDB_TIMEOUT_MS).

local EXIT_OK, EXIT_FAILED, EXIT_UNUSABLE = 0, 1, 2

local USAGE = [[
usage: luvit ops/preppydb-migrate.lua --manifest=<path> [--apply | --verify] [options]

modes (exactly one, default is the read-only dry run):
  --dry-run            report what would be inserted; writes nothing
  --apply              insert missing destination records (insert-only)
  --verify             gate: every manifest key must already be present and
                       byte-identical; writes nothing, fails on the first miss

options:
  --url=<url>            PreppyDB base URL (env MOLLY_PREPPYDB_URL)
  --token=<token>        PreppyDB bearer token (env MOLLY_PREPPYDB_TOKEN)
  --seaworld-socket=<p>  SeaWorld unix socket (env MOLLY_SEAWORLD_SOCKET)
  --timeout-ms=<n>       request timeout (env MOLLY_PREPPYDB_TIMEOUT_MS, default 3000)
  --help                 this text

exit codes: 0 success, 1 migration/verification failure, 2 unusable invocation
]]

local function fail_usage(message)
  io.stderr:write("preppydb-migrate: " .. message .. "\n\n" .. USAGE)
  os.exit(EXIT_UNUSABLE)
end

local function trim(value)
  if type(value) ~= "string" then return nil end
  local result = value:match("^%s*(.-)%s*$")
  return result ~= "" and result or nil
end

local FLAGS_WITH_VALUE = {
  manifest = true, url = true, token = true,
  ["seaworld-socket"] = true, ["timeout-ms"] = true,
}
local FLAGS_WITHOUT_VALUE = {
  apply = true, verify = true, ["dry-run"] = true, help = true,
}

local function parse_arguments(argv)
  local parsed, errors = {}, {}
  local index = 1
  while index <= #argv do
    local argument = argv[index]
    local name, value = argument:match("^%-%-([%a%-]+)=(.*)$")
    if not name then
      name = argument:match("^%-%-([%a%-]+)$")
      if name and FLAGS_WITH_VALUE[name] then
        value = argv[index + 1]
        if value == nil or value:match("^%-%-") then
          errors[#errors + 1] = "missing value for --" .. name
          index = index + 1
          name = nil
        else
          index = index + 1
        end
      end
    end
    if name then
      if FLAGS_WITH_VALUE[name] then
        if value == nil then
          -- `--flag=value` form already carries its value.
          errors[#errors + 1] = "missing value for --" .. name
        else
          parsed[name] = value
        end
      elseif FLAGS_WITHOUT_VALUE[name] then
        if argument:find("=", 1, true) then
          errors[#errors + 1] = "--" .. name .. " does not take a value"
        else
          parsed[name] = true
        end
      else
        errors[#errors + 1] = "unknown option " .. tostring(argument)
      end
    elseif argument:sub(1, 1) == "-" then
      errors[#errors + 1] = "unknown option " .. tostring(argument)
    else
      errors[#errors + 1] = "unexpected argument " .. tostring(argument)
    end
    index = index + 1
  end
  return parsed, errors
end

local function request_mode(parsed)
  local chosen = {}
  if parsed.apply then chosen[#chosen + 1] = "apply" end
  if parsed.verify then chosen[#chosen + 1] = "verify" end
  if parsed["dry-run"] then chosen[#chosen + 1] = "dry_run" end
  if #chosen > 1 then fail_usage("choose exactly one of --apply, --verify, --dry-run") end
  return chosen[1] or "dry_run"
end

local function read_file(path)
  local handle = io.open(path, "rb")
  if not handle then return nil, "cannot read manifest " .. tostring(path) end
  local content = handle:read("*a")
  handle:close()
  if not content or content == "" then return nil, "manifest is empty: " .. tostring(path) end
  return content
end

local function load_manifest(path)
  local encoded, read_error = read_file(path)
  if not encoded then return nil, read_error end
  local client_ok, client = pcall(require, "src.preppydb.client")
  if not client_ok or type(client) ~= "table" or type(client.decode) ~= "function" then
    return nil, "the bundled PreppyDB client is unavailable"
  end
  local decoded_ok, manifest = pcall(client.decode, encoded)
  if not decoded_ok or type(manifest) ~= "table" then
    return nil, "manifest is not valid JSON in " .. tostring(path)
  end
  if type(manifest.guilds) ~= "table" and type(manifest.globals) ~= "table" then
    return nil, "manifest needs a guilds and/or globals array"
  end
  for _, field in ipairs({ "guilds", "globals" }) do
    if manifest[field] ~= nil and type(manifest[field]) ~= "table" then
      return nil, "manifest." .. field .. " must be an array"
    end
  end
  return manifest
end

local function connector_environment(parsed)
  return {
    socket = parsed["seaworld-socket"] or trim(os.getenv("MOLLY_SEAWORLD_SOCKET")),
    url = parsed.url or trim(os.getenv("MOLLY_PREPPYDB_URL")),
    token = parsed.token or trim(os.getenv("MOLLY_PREPPYDB_TOKEN")),
    timeout_ms = tonumber(parsed["timeout-ms"] or trim(os.getenv("MOLLY_PREPPYDB_TIMEOUT_MS"))) or 3000,
  }
end

local function build_source(environment)
  if not environment.socket then
    fail_usage("SeaWorld socket required (--seaworld-socket or MOLLY_SEAWORLD_SOCKET)")
  end
  local driver_ok, driver_module = pcall(require, "src.seaworld.socket_driver")
  if not driver_ok then
    io.stderr:write("preppydb-migrate: the SeaWorld socket driver is unavailable in this runtime\n")
    os.exit(EXIT_UNUSABLE)
  end
  local connector_ok, connector_module = pcall(require, "src.persistence.seaworld_connector")
  if not connector_ok then
    io.stderr:write("preppydb-migrate: the SeaWorld connector is unavailable in this runtime\n")
    os.exit(EXIT_UNUSABLE)
  end
  local driver = driver_module.new({ path = environment.socket, timeout_ms = environment.timeout_ms })
  local connector = connector_module.new({ driver = driver })
  local state = connector:initialize()
  if state.status == "unavailable" and state.detail ~= "initialized" then
    io.stderr:write("preppydb-migrate: SeaWorld initialization failed (" .. tostring(state.detail) .. ")\n")
    os.exit(EXIT_UNUSABLE)
  end
  local connected, detail = connector:connect()
  if not connected then
    io.stderr:write("preppydb-migrate: cannot use SeaWorld at " .. tostring(environment.socket)
      .. " (" .. tostring(detail) .. ")\n")
    os.exit(EXIT_UNUSABLE)
  end
  return connector
end

local function build_target(environment)
  if not environment.url or not environment.token then
    fail_usage("PreppyDB URL and token required (--url/--token or MOLLY_PREPPYDB_URL/MOLLY_PREPPYDB_TOKEN)")
  end
  local connector_ok, connector_module = pcall(require, "src.preppydb.connector")
  if not connector_ok then
    io.stderr:write("preppydb-migrate: the PreppyDB connector is unavailable in this runtime\n")
    os.exit(EXIT_UNUSABLE)
  end
  local connector, reason = connector_module.new({
    url = environment.url,
    token = environment.token,
    timeout_ms = environment.timeout_ms,
    async_bridge = true,
  })
  if not connector then
    io.stderr:write("preppydb-migrate: cannot build the PreppyDB connector (" .. tostring(reason) .. ")\n")
    os.exit(EXIT_UNUSABLE)
  end
  return connector
end

local function report_durability(Migration, target)
  local durable, evidence = Migration.durability(target)
  if durable then
    io.stdout:write(string.format("durability: durable (sync_mode=%s, detail=%s)\n",
      tostring(evidence.sync_mode), tostring(evidence.detail)))
  else
    io.stdout:write(string.format("durability: %s (%s)\n",
      tostring(evidence.code), tostring(evidence.detail)))
  end
  return durable
end

local function print_entries(label, entries)
  for _, entry in ipairs(entries or {}) do
    io.stdout:write(string.format("  %s %-20s %s\n", label, tostring(entry.key), tostring(entry.status)))
  end
end

local function exit_code_for(code)
  if code == "invalid_manifest" or code == "invalid_argument" then return EXIT_UNUSABLE end
  return EXIT_FAILED
end

local function main(argv)
  local parsed, errors = parse_arguments(argv)
  if parsed.help then
    io.stdout:write(USAGE)
    return EXIT_OK
  end
  if #errors > 0 then fail_usage(errors[1]) end
  if not parsed.manifest then fail_usage("--manifest=<path> is required") end
  local mode = request_mode(parsed)

  -- The migration primitive yields while a PreppyDB request is in flight, so it
  -- must not run on Luvit's main thread; a coroutine is the documented context.
  if not coroutine.running() then
    io.stderr:write("preppydb-migrate: must run inside a coroutine (use the Luvit entry point)\n")
    return EXIT_UNUSABLE
  end

  local Migration = require("src.persistence.seaworld_preppydb_migration")
  local client = require("src.preppydb.client")

  local manifest, manifest_error = load_manifest(parsed.manifest)
  if not manifest then
    io.stderr:write("preppydb-migrate: " .. tostring(manifest_error) .. "\n")
    return EXIT_UNUSABLE
  end
  local guilds, globals = manifest.guilds or {}, manifest.globals or {}
  if #guilds == 0 and #globals == 0 then
    io.stderr:write("preppydb-migrate: refusing an empty manifest; it cannot evidence anything\n")
    return EXIT_UNUSABLE
  end

  -- SeaWorld's documents carry its own JSON marker types, so the source codec
  -- has to be the runtime's own decoder; Molly's PreppyDB client is the target.
  local luvit_json_ok, luvit_json = pcall(require, "json")
  if not luvit_json_ok or type(luvit_json) ~= "table" or luvit_json.null == nil then
    io.stderr:write("preppydb-migrate: the Luvit 'json' module is required as the source codec\n")
    return EXIT_UNUSABLE
  end

  local environment = connector_environment(parsed)
  local source = build_source(environment)
  local target = build_target(environment)
  report_durability(Migration, target)

  local ok, report = Migration.run({
    source = source,
    target = target,
    source_json = luvit_json,
    target_json = client,
    guilds = guilds,
    globals = globals,
    guild_collection = manifest.guild_collection,
    global_collection = manifest.global_collection,
    apply = mode == "apply",
    verify_only = mode == "verify",
  })

  if not ok then
    local code = type(report) == "table" and report.code or "unknown"
    io.stderr:write(string.format("migration %s failed: %s\n", mode, tostring(code)))
    local summary = type(report) == "table" and report.summary or nil
    if summary and summary.failed then
      io.stderr:write(string.format("  first failure: %s/%s (%s)\n",
        tostring(summary.failed.collection), tostring(summary.failed.key), tostring(summary.failed.code)))
    end
    if summary then
      print_entries("guild ", summary.guilds)
      print_entries("global", summary.globals)
    end
    return exit_code_for(code)
  end

  io.stdout:write(string.format("mode: %s, verified: %d\n", report.mode, report.verified))
  if report.mode ~= "dry_run" then
    io.stdout:write(string.format("durability: %s\n", tostring(report.durability)))
  end
  print_entries("guild ", report.guilds)
  print_entries("global", report.globals)

  -- Migration writes require affirmative durability evidence; no override exists.
  if report.mode == "apply" and report.durability ~= "durable" then
    io.stderr:write("preppydb-migrate: destination durability is not proven; "
      .. "this apply is not reported as success\n")
    return EXIT_FAILED
  end
  return EXIT_OK
end

local function provided_arguments()
  -- Luvit exposes the user arguments in `args`; PUC Lua exposes them in `arg`
  -- with the script path at `arg[0]`. Normalise both, and tolerate a runtime
  -- that hands the script path over as the first entry.
  local current = rawget(_G, "args") or arg or {}
  if type(current) ~= "table" then return {} end
  local result = {}
  for index = 1, #current do
    local value = current[index]
    if type(value) == "string" and not (index == 1 and value:match("%.lua$")) then
      result[#result + 1] = value
    end
  end
  return result
end

local passed, code = pcall(main, provided_arguments())
if not passed then
  io.stderr:write("preppydb-migrate: unexpected failure: " .. tostring(code) .. "\n")
  os.exit(EXIT_FAILED)
end
os.exit(code)
