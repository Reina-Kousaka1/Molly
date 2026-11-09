package.path = "./?.lua;./?/init.lua;" .. package.path

local Connector = require("src.preppydb.connector")
local Store = require("src.persistence.preppydb_store")
local Ledger = require("src.economy.ledger")
local uv = require("uv")

local connector = assert(Connector.new({
  url = assert(os.getenv("PREPPYDB_URL")),
  token = assert(os.getenv("PREPPYDB_TOKEN")),
  async_bridge = true,
  timeout_ms = 5000,
  max_response_bytes = 4 * 1024 * 1024,
}))

local completed
coroutine.wrap(function()
  local ok, failure = pcall(function()
    local store = Store.new(connector)
    local ledger = Ledger.new(store, function() return 700000 end)
    local source_ok, source = ledger:balance("91003", "201")
    local target_ok, target = ledger:balance("91003", "202")
    assert(source_ok and target_ok)
    assert(source.wallet == 1100 and target.wallet == 200)

    local before = source.wallet
    local replayed, result = ledger:change("91003", "201", "93001", "daily")
    assert(replayed and result.wallet == before - 200,
      "the persisted duplicate claim must return its original balance result")
    local lost_ack_replay, lost_ack_result = ledger:change("91003", "201", "95001", "daily")
    assert(lost_ack_replay and lost_ack_result.wallet == 1000,
      "the commit with a lost acknowledgement must replay its durable receipt after restart")
    local malformed_ack_replay, malformed_ack_result = ledger:change("91003", "201", "95002", "daily")
    assert(malformed_ack_replay and malformed_ack_result.wallet == 1100,
      "the commit with a malformed acknowledgement must replay its durable receipt after restart")
    local after_ok, after = ledger:balance("91003", "201")
    assert(after_ok and after.wallet == before, "receipt replay after restart changed the balance")

    local first = connector:get("molly_guild_state", "94001")
    local second = connector:get("molly_guild_state", "94002")
    local global = connector:get("molly_global_state", "blacklist")
    assert(first and first.value.guild == "94001")
    assert(second and second.value.guild == "94002")
    assert(global and global.value.entries[1] == "blocked-user")

    local absent, absent_error = connector:get("molly_guild_state", "91004")
    assert(not absent and absent_error.code == "not_found")
    local pair_a = connector:get("molly_guild_state", "txn-a")
    local pair_b = connector:get("molly_guild_state", "txn-b")
    assert(pair_a and pair_b and pair_b.value.marker == "b")
    assert(pair_a.value.marker == "racer-1" or pair_a.value.marker == "racer-2")
  end)
  completed = { ok = ok, failure = failure }
end)()

uv.run()
assert(completed and completed.ok, completed and completed.failure or "restart verification did not complete")
io.stdout:write("PreppyDB process-restart verification: pass\n")
