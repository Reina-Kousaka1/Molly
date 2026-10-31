package.path = "./?.lua;./?/init.lua;./deps/?.lua;./deps/?/init.lua;" .. package.path
local Connector = require("src.persistence.seaworld_connector")
local Driver = require("src.seaworld.socket_driver")
local path = assert(os.getenv("MOLLY_TEST_SOCKET"))
local phase = assert(os.getenv("MOLLY_TEST_PHASE"))

local function run()
  local c = Connector.new({ driver = Driver.new({ path = path, timeout_ms = 3000 }) })
  c:initialize()
  if phase == "unavailable" then
    local ok = c:insert({ collection = "records", document = { value = "must-not-write" } })
    assert(not ok, "unavailable service must fail closed")
    print("PASS unavailable write failed closed")
    return
  end
  assert(c:connect(), "health/version negotiation failed")
  assert(c:get_state().status == "healthy")
  if phase == "reopen" then
    local ok, row = c:get({ collection = "records", id = 1 })
    assert(ok and row.document.value == "committed", "persisted record missing")
    print("PASS reopen persistence")
    c:close()
    return
  end
  assert(c:create_collection({ collection = "records" }))
  local unsafe, unsafe_reason = c:insert({ collection = "records", document = { value = 123456789012345 } })
  assert(not unsafe and unsafe_reason == "invalid_argument", "unsafe numeric value must be rejected")
  local ok, inserted = c:insert({ collection = "records", document = { value = "initial" } })
  assert(ok and inserted.id == 1)
  local id = inserted.id
  local read_ok, row = c:get({ collection = "records", id = id })
  assert(read_ok and row.document.value == "initial")
  local update_ok, update = c:update({ collection = "records", id = id, set = { value = "updated" } })
  assert(update_ok and update.affected == 1)
  local query_ok, query = c:query({ collection = "records", id = id })
  assert(query_ok and query.rows[1].document.value == "updated")
  assert(c:begin())
  assert(c:health().detail == "transaction_active")
  local tx_ok, tx_insert = c:insert({ collection = "records", document = { value = "other" } })
  assert(tx_ok and tx_insert.provisional)
  assert(c:update({ collection = "records", id = id, set = { value = "committed" } }))
  assert(c:commit())
  local committed_ok, committed = c:get({ collection = "records", id = tx_insert.id })
  assert(committed_ok and committed.document.value == "other")
  assert(c:begin())
  assert(c:update({ collection = "records", id = id, set = { value = "rolled-back" } }))
  assert(c:rollback())
  local rollback_ok, rollback = c:get({ collection = "records", id = id })
  assert(rollback_ok and rollback.document.value == "committed")
  local del_ok, deleted = c:delete({ collection = "records", id = tx_insert.id })
  assert(del_ok and deleted.affected == 1)
  local upsert_ok, upsert = c:upsert({ collection = "records", id = id, document = { value = "unused" }, set = { value = "committed" } })
  assert(upsert_ok and not upsert.inserted)
  local empty_ok, empty = c:insert({ collection = "records", document = {} })
  assert(empty_ok and empty.id, "empty document should be supported")
  c:close()
  print("PASS health, version, insert, read, update, query, commit, rollback, delete, upsert")
end

coroutine.wrap(function()
  local ok, err = pcall(run)
  if not ok then io.stderr:write("FAIL " .. tostring(err) .. "\n"); os.exit(1) end
end)()
