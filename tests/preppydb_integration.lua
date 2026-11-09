package.path = "./?.lua;./?/init.lua;" .. package.path

local Connector = require("src.preppydb.connector")
local Store = require("src.persistence.preppydb_store")
local Service = require("src.persistence.preppydb_service")
local Migration = require("src.persistence.seaworld_preppydb_migration")
local Ledger = require("src.economy.ledger")
local client_library = require("src.preppydb.client")
local uv = require("uv")

local base_url = assert(os.getenv("PREPPYDB_URL"), "PREPPYDB_URL is required")
local token = assert(os.getenv("PREPPYDB_TOKEN"), "PREPPYDB_TOKEN is required")
local common = { url = base_url, token = token, async_bridge = true, timeout_ms = 5000, max_response_bytes = 4 * 1024 * 1024 }
local connector = assert(Connector.new(common))
local store = Store.new(connector)
local service = Service.new(connector)

local function await(label, fn)
  local completed
  coroutine.wrap(function()
    local ok, first, second = pcall(fn)
    completed = { ok = ok, first = first, second = second }
  end)()
  uv.run()
  assert(completed, label .. ": coroutine did not complete")
  assert(completed.ok, label .. ": " .. tostring(completed.first))
  return completed.first, completed.second
end

local function store_read(active_store, guild)
  local value
  local ok, reason = active_store:run(guild, function(data)
    value = data
    return true, true, false
  end)
  assert(ok, tostring(reason))
  return value
end

local function test(label, fn)
  await(label, fn)
  io.stdout:write("ok - " .. label .. "\n")
end

local function fault_transport(mode)
  local http = require("http")
  return function(request, callback)
    local is_transaction = request.method == "POST"
      and request.url:find("/v1/transactions", 1, true) ~= nil
    if is_transaction and mode == "before_commit" then
      callback(nil, "injected connection failure before request send", {})
      return
    end
    local options = http.parseUrl(request.url)
    options.method, options.headers = request.method, request.headers
    local complete = false
    local function finish(status, body, headers)
      if complete then return end
      complete = true
      callback(status, body, headers or {})
    end
    local outgoing = http.request(options, function(response)
      local chunks = {}
      response:on("data", function(chunk) chunks[#chunks + 1] = chunk end)
      response:on("end", function()
        local body = table.concat(chunks)
        if is_transaction and mode == "after_commit" then
          finish(nil, "injected lost acknowledgement", {})
        elseif is_transaction and mode == "malformed_ack" then
          finish(200, "{malformed", response.headers)
        else
          finish(tonumber(response.statusCode), body, response.headers)
        end
      end)
      response:on("error", function(err) finish(nil, tostring(err), {}) end)
    end)
    outgoing:on("error", function(err) finish(nil, tostring(err), {}) end)
    if request.timeout_ms then
      outgoing:setTimeout(request.timeout_ms, function()
        finish(nil, "injected transport timeout", {})
        outgoing:destroy()
      end)
    end
    outgoing:done(request.body)
  end
end

local function connector_with_transport(mode)
  local options = {}
  for key, value in pairs(common) do options[key] = value end
  options.transport = fault_transport(mode)
  return assert(Connector.new(options))
end

test("PreppyDB health, readiness, API version, role and collections preflight", function()
  local connected, reason = service:connect()
  assert(connected, tostring(reason))
  assert(service:get_state().api_version == "1.0.0")
end)

test("Molly guild/global store read, write and multi-guild isolation", function()
  local ok, result = store:run("91001", function(data)
    data.accounts["101"] = { wallet = 25, bank = 0 }
    return true, "created", true
  end)
  assert(ok and result == "created")
  local first = store_read(store, "91001")
  assert(first.guild == "91001" and first.accounts["101"].wallet == 25)
  local second_ok = store:run("91002", function(data)
    data.accounts["101"] = { wallet = 7, bank = 0 }
    return true, "created", true
  end)
  assert(second_ok)
  assert(store_read(store, "91001").accounts["101"].wallet == 25)
  assert(store_read(store, "91002").accounts["101"].wallet == 7)

  local global_ok = store:run("preppydb_e2e_global", { entries = {}, receipts = {} }, function(data)
    data.entries["101"] = true
    return true, "global", true
  end)
  assert(global_ok)
end)

test("PreppyDB transaction is atomic across document keys and enforces CAS", function()
  for _, key in ipairs({ "txn-a", "txn-b" }) do
    local existing, lookup_error = connector:get("molly_guild_state", key)
    local code = type(lookup_error) == "table" and lookup_error.code or nil
    assert(not existing and code == "not_found",
      "synthetic CAS key already exists before transaction: key=" .. key
        .. " version=" .. tostring(existing and existing.version)
        .. " lookup_code=" .. tostring(code))
  end
  local created, create_error = connector:transaction({
    { op = "put", collection = "molly_guild_state", key = "txn-a", expected_version = 0, value = { marker = "a" } },
    { op = "put", collection = "molly_guild_state", key = "txn-b", expected_version = 0, value = { marker = "b" } },
  })
  assert(created, create_error and create_error.code)

  local rejected, conflict = connector:transaction({
    { op = "put", collection = "molly_guild_state", key = "txn-c", expected_version = 0, value = { marker = "must-not-appear" } },
    { op = "put", collection = "molly_guild_state", key = "txn-a", expected_version = 0, value = { marker = "stale" } },
  })
  assert(not rejected and conflict and conflict.code == "conflict")
  local absent, absent_error = connector:get("molly_guild_state", "txn-c")
  assert(not absent and absent_error.code == "not_found", "a failed multi-key transaction partially published")

  local left = assert(connector:get("molly_guild_state", "txn-a"))
  local right = assert(connector:get("molly_guild_state", "txn-a"))
  assert(left.version == right.version)
  local outcomes = {}
  for index = 1, 2 do
    local value = { marker = "racer-" .. index }
    coroutine.wrap(function()
      local ok, result = connector:transaction({ {
        op = "put", collection = "molly_guild_state", key = "txn-a",
        expected_version = left.version, value = value,
      } })
      outcomes[index] = { ok = ok, result = result }
    end)()
  end
  uv.run()
  assert(outcomes[1] and outcomes[2], "both CAS contenders must complete")
  assert((outcomes[1].ok and outcomes[2].result.code == "conflict")
    or (outcomes[2].ok and outcomes[1].result.code == "conflict"),
    "same-version writes must produce one commit and one conflict")
end)

test("parallel economy transfers preserve balances and allow explicit conflict retry", function()
  local seed_ok = store:run("91003", function(data)
    data.accounts["201"] = { wallet = 1000, bank = 0 }
    data.accounts["202"] = { wallet = 0, bank = 0 }
    return true, "seeded", true
  end)
  assert(seed_ok)
  local store_a, store_b = Store.new(connector), Store.new(assert(Connector.new(common)))
  local ledger_a = Ledger.new(store_a, function() return 200000 end)
  local ledger_b = Ledger.new(store_b, function() return 200000 end)
  local outcomes = {}
  local ids = { "92001", "92002" }
  for index, ledger in ipairs({ ledger_a, ledger_b }) do
    coroutine.wrap(function()
      local ok, result = ledger:change("91003", "201", ids[index], "pay", "100", "202")
      outcomes[index] = { ok = ok, result = result }
    end)()
  end
  uv.run()
  assert(outcomes[1] and outcomes[2], "both transfer attempts must complete")
  for index, ledger in ipairs({ ledger_a, ledger_b }) do
    if not outcomes[index].ok then
      assert(outcomes[index].result == "conflict", tostring(outcomes[index].result))
      local retried, retry_result = ledger:change("91003", "201", ids[index], "pay", "100", "202")
      assert(retried, tostring(retry_result))
    end
  end
  local from_ok, from = ledger_a:balance("91003", "201")
  local to_ok, to = ledger_a:balance("91003", "202")
  assert(from_ok and to_ok)
  assert(from.wallet == 800 and to.wallet == 200)
  assert(from.wallet + to.wallet == 1000)
end)

test("concurrent duplicate reward claim and durable receipt replay", function()
  local store_a, store_b = Store.new(connector), Store.new(assert(Connector.new(common)))
  local ledger_a = Ledger.new(store_a, function() return 300000 end)
  local ledger_b = Ledger.new(store_b, function() return 300000 end)
  local before_ok, before_state = ledger_a:balance("91003", "201")
  assert(before_ok)
  local before = before_state.wallet
  local outcomes = {}
  for index, ledger in ipairs({ ledger_a, ledger_b }) do
    coroutine.wrap(function()
      local ok, result = ledger:change("91003", "201", "93001", "daily")
      outcomes[index] = { ok = ok, result = result }
    end)()
  end
  uv.run()
  for index, ledger in ipairs({ ledger_a, ledger_b }) do
    if not outcomes[index].ok then
      assert(outcomes[index].result == "conflict", tostring(outcomes[index].result))
      local retried, retry_result = ledger:change("91003", "201", "93001", "daily")
      assert(retried, tostring(retry_result))
    end
  end
  local after_ok, after_state = ledger_a:balance("91003", "201")
  assert(after_ok)
  local after = after_state.wallet
  assert(after == before + 100, "a duplicated claim must be applied only once")
  local retry_store = Store.new(assert(Connector.new(common)))
  local restarted = Ledger.new(retry_store, function() return 400000 end)
  local replayed, replay = restarted:change("91003", "201", "93001", "daily")
  assert(replayed and replay.wallet == after)
  assert(retry_store:run("91003", function(data)
    data.accounts["201"].wallet = data.accounts["201"].wallet
    return true, "should-not-run", false
  end))
  local changed, conflict = restarted:change("91003", "201", "93001", "work")
  assert(not changed and conflict == "replay_conflict")
end)

test("unknown, lost and malformed write acknowledgements fail closed and receipt replay is safe", function()
  local before_connector = connector_with_transport("before_commit")
  local before_store = Store.new(before_connector)
  local before_ok, before_reason = before_store:run("91004", function(data)
    data.accounts["301"] = { wallet = 10, bank = 0 }
    return true, "staged", true
  end)
  assert(not before_ok and before_reason == "outcome_unknown")
  local no_write, no_write_error = connector:get("molly_guild_state", "91004")
  assert(not no_write and no_write_error.code == "not_found", "pre-commit transport failure reached the server")

  local normal_ledger = Ledger.new(Store.new(connector), function() return 500000 end)
  local lost_ledger = Ledger.new(Store.new(connector_with_transport("after_commit")), function() return 500000 end)
  local initial_ok, initial = normal_ledger:balance("91003", "201")
  assert(initial_ok)
  local lost_ok, lost_reason = lost_ledger:change("91003", "201", "95001", "daily")
  assert(not lost_ok and lost_reason == "outcome_unknown")
  local replay_ok, replay = normal_ledger:change("91003", "201", "95001", "daily")
  assert(replay_ok)
  local after_lost_ok, after_lost = normal_ledger:balance("91003", "201")
  assert(after_lost_ok and after_lost.wallet == initial.wallet + 100)
  assert(replay.wallet == after_lost.wallet)

  local malformed_ledger = Ledger.new(Store.new(connector_with_transport("malformed_ack")), function() return 600000 end)
  local before_malformed_ok, before_malformed = normal_ledger:balance("91003", "201")
  assert(before_malformed_ok)
  local malformed_ok, malformed_reason = malformed_ledger:change("91003", "201", "95002", "daily")
  assert(not malformed_ok and malformed_reason == "outcome_unknown")
  local recovered_ok, recovered = normal_ledger:change("91003", "201", "95002", "daily")
  assert(recovered_ok)
  local after_malformed_ok, after_malformed = normal_ledger:balance("91003", "201")
  assert(after_malformed_ok and after_malformed.wallet == before_malformed.wallet + 100)
  assert(recovered.wallet == after_malformed.wallet)
end)

test("manifest migration dry-run, apply, interruption and idempotent resume", function()
  assert(type(client_library.array) == "function", "PreppyDB JSON array adapter is unavailable")
  assert(client_library.null ~= nil, "PreppyDB JSON null adapter is unavailable")
  assert(type(client_library.encode) == "function", "PreppyDB JSON encoder is unavailable")
  assert(type(client_library.decode) == "function", "PreppyDB JSON decoder is unavailable")
  local adapter_probe = client_library.array({})
  local encoded_probe = client_library.encode({ items = adapter_probe, missing = client_library.null })
  local decoded_ok, decoded_probe = pcall(client_library.decode, encoded_probe)
  assert(decoded_ok and type(decoded_probe) == "table", "PreppyDB JSON adapter round-trip failed")
  assert(client_library.is_array(decoded_probe.items), "PreppyDB JSON adapter did not preserve array semantics")
  assert(decoded_probe.missing == client_library.null, "PreppyDB JSON adapter did not preserve null semantics")

  local source_data = {
    ["molly_g_94001"] = { guild = "94001", accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {} },
    ["molly_g_94002"] = { guild = "94002", accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {} },
    ["molly_global_blacklist"] = {
      entries = client_library.array({ "blocked-user" }), receipts = {},
    },
  }
  local source = {}
  function source:query(request)
    local value = source_data[request.collection]
    if not value then return false, "not_found" end
    return true, { rows = { { id = "synthetic", document = { data = value } } } }
  end
  local options = {
    source = source, target = connector, source_json = client_library,
    target_json = client_library, guilds = { "94001", "94002" }, globals = { "blacklist" },
  }
  local target_keys = {
    { collection = "molly_guild_state", key = "94001" },
    { collection = "molly_guild_state", key = "94002" },
    { collection = "molly_global_state", key = "blacklist" },
  }
  local function target_snapshot()
    local snapshot = {}
    for _, item in ipairs(target_keys) do
      local envelope, read_error = connector:get(item.collection, item.key)
      if envelope then
        local encoded = client_library.encode(envelope)
        assert(type(encoded) == "string", "could not encode synthetic migration target snapshot")
        snapshot[#snapshot + 1] = item.collection .. "/" .. item.key .. "=" .. encoded
      else
        local code = type(read_error) == "table" and read_error.code or nil
        assert(code == "not_found", "could not inspect migration target "
          .. item.collection .. "/" .. item.key .. ": code=" .. tostring(code))
        snapshot[#snapshot + 1] = item.collection .. "/" .. item.key .. "=<missing>"
      end
    end
    return table.concat(snapshot, "\n")
  end
  local before_dry_run = target_snapshot()
  local dry_ok, dry = Migration.run(options)
  local dry_summary = type(dry) == "table" and (dry.summary or dry) or {}
  assert(dry_ok, "migration dry-run failed: code="
    .. tostring(type(dry) == "table" and dry.code or nil)
    .. " mode=" .. tostring(dry_summary.mode)
    .. " verified=" .. tostring(dry_summary.verified))
  assert(type(dry) == "table", "migration dry-run returned no summary")
  assert(dry.mode == "dry_run", "migration dry-run returned mode=" .. tostring(dry.mode))
  assert(dry.verified == 0, "migration dry-run unexpectedly verified " .. tostring(dry.verified) .. " records")
  local after_dry_run = target_snapshot()
  assert(after_dry_run == before_dry_run, "migration dry-run changed synthetic target state")
  local repeated_ok, repeated_dry = Migration.run(options)
  local repeated_summary = type(repeated_dry) == "table" and (repeated_dry.summary or repeated_dry) or {}
  assert(repeated_ok, "repeated migration dry-run failed: code="
    .. tostring(type(repeated_dry) == "table" and repeated_dry.code or nil)
    .. " mode=" .. tostring(repeated_summary.mode)
    .. " verified=" .. tostring(repeated_summary.verified))
  assert(type(repeated_dry) == "table", "repeated migration dry-run returned no summary")
  assert(repeated_dry.mode == "dry_run", "repeated migration dry-run returned mode=" .. tostring(repeated_dry.mode))
  assert(repeated_dry.verified == 0, "repeated migration dry-run unexpectedly verified "
    .. tostring(repeated_dry.verified) .. " records")
  assert(target_snapshot() == before_dry_run, "repeated migration dry-run changed synthetic target state")
  local missing = connector:get("molly_guild_state", "94001")
  assert(not missing, "dry-run must not create target data")

  local partial_source = {}
  function partial_source:query(request)
    if request.collection == "molly_g_94001" then return source:query(request) end
    return false, "synthetic_interruption"
  end
  options.source, options.apply = partial_source, true
  local partial_ok = Migration.run(options)
  assert(not partial_ok, "the synthetic interrupted migration should stop")
  options.source = source
  local resumed, report = Migration.run(options)
  assert(resumed and report.mode == "apply" and report.verified == 3)
  local repeated, repeated_report = Migration.run(options)
  assert(repeated and repeated_report.verified == 3)
  local migrated = connector:get("molly_guild_state", "94002")
  assert(migrated and migrated.value.guild == "94002")
  local global = connector:get("molly_global_state", "blacklist")
  assert(global and global.value.entries[1] == "blocked-user")
end)

io.stdout:write("PreppyDB real-server integration: pass\n")

