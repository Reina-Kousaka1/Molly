package.path = "./?.lua;./?/init.lua;./deps/?.lua;./deps/?/init.lua;" .. package.path
local Connector = require("src.persistence.seaworld_connector")
local Driver = require("src.seaworld.socket_driver")
local Store = require("src.persistence.guild_store")
local Ledger = require("src.economy.ledger")
local Cases = require("src.moderation.cases")
local Directory = require("src.staff.directory")
local socket = assert(os.getenv("MOLLY_TEST_SOCKET"))
local c = Connector.new({ driver = Driver.new({ path = socket, timeout_ms = 3000 }) })
local store = Store.new(c)
local ledger = Ledger.new(store, function() return 2000000000 end)

local function run()
  if os.getenv("MOLLY_TEST_PHASE") == "verify" then
    local ok, value = ledger:balance("123", "456")
    assert(ok and value.wallet == 10 and value.bank == 30, "reopened balance")
    local cases, staff = Cases.new(store), Directory.new(store)
    ok, value = cases:get("123", "C1"); assert(ok and value.reason == "updated reason", "reopened case")
    ok, value = staff:apply("123", "456", "789", "notes"); assert(ok and value.notes[1].text == "private note", "reopened staff note")
    c:close(); print("PASS economy, cases and staff persist across service restart"); return
  end
  if os.getenv("MOLLY_TEST_PHASE") == "unavailable" then
    local ok = ledger:change("123", "456", "9999", "pay", "1", "789")
    assert(not ok, "unavailable storage must fail closed")
    c:close(); print("PASS unavailable economy fails closed"); return
  end
  local ok, value = ledger:change("123", "456", "1001", "daily")
  assert(ok and value.wallet == 100, "daily reward")
  ok, value = ledger:change("123", "456", "1001", "daily")
  assert(ok and value.wallet == 100, "repeated interaction must not duplicate reward")
  ok, value = ledger:change("123", "456", "1002", "daily")
  assert(not ok and value == "cooldown", "daily cooldown")
  ok, value = ledger:change("123", "456", "1003", "deposit", "40")
  assert(ok and value.wallet == 60 and value.bank == 40, "deposit")
  ok, value = ledger:change("123", "456", "1004", "withdraw", "10")
  assert(ok and value.wallet == 70 and value.bank == 30, "withdraw")
  for _, invalid in ipairs({ "-1", "0", "99999999999999999", "nan" }) do
    ok = ledger:change("123", "456", "1005", "deposit", invalid)
    assert(not ok, "invalid amounts must fail")
  end
  ok, value = ledger:change("123", "456", "1006", "pay", "1", "456")
  assert(not ok and value == "invalid_target", "self pay")
  ok, value = ledger:change("123", "456", "1007", "pay", "100", "789")
  assert(not ok and value == "insufficient", "insufficient funds")
  ok, value = ledger:change("123", "456", "1008", "pay", "20", "789")
  assert(ok and value.wallet == 50, "pay")
  ok, value = ledger:balance("123", "789")
  assert(ok and value.wallet == 20, "pay recipient")
  local history; ok, history = ledger:history("123", "456")
  assert(ok and #history == 4, "journal records only committed changes")
  local complete, results = 0, {}
  for i = 1, 2 do
    coroutine.wrap(function()
      local success, result = ledger:change("123", "456", tostring(1100 + i), "pay", "40", "789")
      results[i] = { success, result }; complete = complete + 1
    end)()
  end
  local uv = require("uv")
  while complete < 2 do
    local thread, timer = coroutine.running(), uv.new_timer()
    timer:start(10, 0, function() timer:close(); assert(coroutine.resume(thread)) end)
    coroutine.yield()
  end
  assert((results[1][1] and not results[2][1]) or (results[2][1] and not results[1][1]), "concurrent payments must not both commit")
  ok, value = ledger:balance("123", "456")
  assert(ok and value.wallet == 10 and value.bank == 30, "concurrent sender balance")
  ok, value = ledger:balance("123", "789")
  assert(ok and value.wallet == 60, "concurrent recipient balance")
  local query_ok, rows = c:query({ collection = "molly_g_123", limit = 2 })
  assert(query_ok and #rows.rows == 1)
  local record_id = rows.rows[1].id
  assert(c:begin())
  local got, record = c:get({ collection = "molly_g_123", id = record_id })
  assert(got); record.document.data.accounts["456"].wallet = 999
  local changed, change = c:update({ collection = "molly_g_123", id = record_id, set = { data = record.document.data } })
  assert(changed and change.updated); assert(c:rollback())
  ok, value = ledger:balance("123", "456"); assert(ok and value.wallet == 10, "rollback must discard staged balance")
  local cases, staff = Cases.new(store, function() return 2000000000 end), Directory.new(store, function() return 2000000000 end)
  ok, value = cases:warn("123", "456", "789", "test reason", "1201")
  assert(ok and value.id == "C1", "persistent case")
  ok, value = cases:edit("123", "C1", "456", "reason", "updated reason")
  assert(ok and value.reason == "updated reason", "persistent case reason")
  ok, value = cases:modlog("123", "status")
  assert(ok and value == "", "missing modlog")
  ok, value = cases:pending("123", "456", "789", "test ban", "1202", "hackban")
  assert(ok and value.fresh and value.case.status == "pending")
  assert(cases:finish("123", value.case.id, "completed"))
  ok, value = cases:pending("123", "456", "789", "test ban", "1202", "hackban")
  assert(ok and not value.fresh and value.case.status == "completed", "pending case replay must not dispatch")
  assert(staff:apply("123", "456", "789", "add", nil, "1203"))
  assert(staff:apply("123", "456", "789", "note", "private note", "1204"))
  assert(staff:apply("123", "456", "789", "note", "private note", "1204"))
  ok, value = staff:apply("123", "456", "789", "notes")
  assert(ok and #value.notes == 1 and value.notes[1].text == "private note", "persistent staff note and replay")
  c:close()
  print("PASS economy, rollback, cases and private staff records over SeaWorld")
end

coroutine.wrap(function()
  local ok, err = pcall(run)
  if not ok then io.stderr:write("FAIL " .. tostring(err) .. "\n"); os.exit(1) end
end)()
