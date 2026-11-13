package.path = "./?.lua;./?/init.lua;" .. package.path

local Connector = require("src.preppydb.connector")
local Store = require("src.persistence.preppydb_store")
local Ledger = require("src.economy.ledger")
local uv = require("uv")
local run_suffix = assert(os.getenv("MOLLY_PREPPYDB_TEST_RUN_ID"), "shared synthetic test run ID is required")
assert(run_suffix:match("^%d+$") and #run_suffix <= 17, "invalid synthetic test run ID")

local function guild_id(index) return "9" .. run_suffix .. string.format("%02d", index) end
local function test_key(name) return "e2e-" .. run_suffix .. "-" .. name end
local function request_id(index) return "8" .. run_suffix .. tostring(index) end

local connector = assert(Connector.new({
  url = assert(os.getenv("PREPPYDB_URL")),
  token = assert(os.getenv("PREPPYDB_TOKEN")),
  async_bridge = true,
  timeout_ms = 5000,
  max_response_bytes = 4 * 1024 * 1024,
}))

local function request_async(client, method, path)
  local thread = coroutine.running()
  local finished, result, failure = false, nil, nil
  client:call_async(method, path, nil, function(data, err)
    result, failure, finished = data, err, true
    if thread then coroutine.resume(thread) end
  end)
  if not finished then coroutine.yield() end
  return result, failure
end
local completed
coroutine.wrap(function()
  local ok, failure = pcall(function()
    local store = Store.new(connector)
    local ledger = Ledger.new(store, function() return 700000 end)
    local source_ok, source = ledger:balance(guild_id(3), "201")
    local target_ok, target = ledger:balance(guild_id(3), "202")
    assert(source_ok and target_ok)
    assert(source.wallet == 1100 and target.wallet == 200)

    local before = source.wallet
    local replayed, result = ledger:change(guild_id(3), "201", request_id(3), "daily")
    assert(replayed and result.wallet == before - 200,
      "the persisted duplicate claim must return its original balance result")
    local lost_ack_replay, lost_ack_result = ledger:change(guild_id(3), "201", request_id(5), "daily")
    assert(lost_ack_replay and lost_ack_result.wallet == 1000,
      "the commit with a lost acknowledgement must replay its durable receipt after restart")
    local malformed_ack_replay, malformed_ack_result = ledger:change(guild_id(3), "201", request_id(6), "daily")
    assert(malformed_ack_replay and malformed_ack_result.wallet == 1100,
      "the commit with a malformed acknowledgement must replay its durable receipt after restart")
    local after_ok, after = ledger:balance(guild_id(3), "201")
    assert(after_ok and after.wallet == before, "receipt replay after restart changed the balance")

    local first = connector:get("molly_guild_state", guild_id(1))
    local second = connector:get("molly_guild_state", guild_id(2))
    local global = connector:get("molly_global_state", test_key("blacklist"))
    assert(first and first.value.guild == guild_id(1))
    assert(second and second.value.guild == guild_id(2))
    assert(global and global.value.entries[1] == "blocked-user")

    local absent, absent_error = connector:get("molly_guild_state", guild_id(7))
    assert(not absent and absent_error.code == "not_found")
    local pair_a = connector:get("molly_guild_state", test_key("txn-a"))
    local pair_b = connector:get("molly_guild_state", test_key("txn-b"))
    assert(pair_a and pair_b and pair_b.value.marker == "b")
    assert(pair_a.value.marker == "racer-1" or pair_a.value.marker == "racer-2")
    local inventory, inventory_error = request_async(connector.client, "GET", "/v1/inventory")
    assert(inventory and not inventory_error and inventory.complete == true)
    assert(type(inventory.sequence) == "string" and type(inventory.generation) == "string")
    local digest_path = assert(os.getenv("MOLLY_PREPPYDB_INVENTORY_SHA256_FILE"))
    local digest_file = assert(io.open(digest_path, "r"))
    local expected_digest = digest_file:read("*l")
    assert(digest_file:close())
    assert(inventory.sha256 == expected_digest, "persisted inventory changed across process restart")
    local page_path = "/v1/inventory/molly_guild_state/documents?sequence="
      .. inventory.sequence .. "&generation=" .. inventory.generation .. "&limit=1"
    local page, page_error = request_async(connector.client, "GET", page_path)
    assert(page and not page_error and page.sequence == inventory.sequence and #page.records == 1)
  end)
  completed = { ok = ok, failure = failure }
end)()

uv.run()
assert(completed and completed.ok, completed and completed.failure or "restart verification did not complete")
io.stdout:write("PreppyDB process-restart verification: pass\n")
