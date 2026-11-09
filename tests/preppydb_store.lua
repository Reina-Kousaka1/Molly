package.path = "./?.lua;./?/init.lua;" .. package.path

local Store = require("src.persistence.preppydb_store")
local Service = require("src.persistence.preppydb_service")
local Ledger = require("src.economy.ledger")

local rows, commits = {}, {}
local connector = {}
function connector:get(collection, key)
  local row = rows[collection .. "/" .. key]
  if not row then return nil, { code = "not_found", status = 404 } end
  return { value = row.value, version = row.version }
end
function connector:encoded_size(value)
  return #tostring(value)
end
function connector:transaction(operations)
  assert(#operations == 1)
  local op = operations[1]
  local slot = op.collection .. "/" .. op.key
  local previous = rows[slot]
  local actual = previous and previous.version or 0
  if actual ~= op.expected_version then return nil, { code = "conflict", status = 409 } end
  rows[slot] = { value = op.value, version = actual + 1 }
  commits[#commits + 1] = { op = op, version = actual + 1 }
  return { operations = 1 }
end

local store = Store.new(connector)
local ok, result = store:run("123", function(data)
  data.accounts["42"] = { wallet = 50, bank = 0 }
  data.journal[1] = { id = "r1", amount = 50 }
  data.receipts.r1 = { operation = "credit", amount = 50 }
  return true, "credited", true
end)
assert(ok and result == "credited")
assert(#commits == 1 and commits[1].op.expected_version == 0)
assert(commits[1].op.collection == "molly_guild_state" and commits[1].op.key == "123")
assert(rows["molly_guild_state/123"].value.accounts["42"].wallet == 50)

ok, result = store:run("123", function(data)
  assert(data.accounts["42"].wallet == 50)
  data.accounts["42"].wallet = 75
  return true, "updated", true
end)
assert(ok and result == "updated")
assert(commits[2].op.expected_version == 1 and rows["molly_guild_state/123"].version == 2)

local before = #commits
local other_ok, other_result = store:run("456", function(data)
  data.accounts.user = { wallet = 5, bank = 0 }
  return true, "created", true
end)
assert(other_ok and other_result == "created")
assert(rows["molly_guild_state/456"].value.accounts.user.wallet == 5)
assert(rows["molly_guild_state/123"].value.accounts["42"].wallet == 75)
assert(#commits == before + 1)

local ledger = Ledger.new(store, function() return 100000 end)
local paid, payment = ledger:change("123", "42", "9001", "deposit", "10")
assert(paid and payment.wallet == 65 and payment.bank == 10)
local after_payment = #commits
local replayed, replay = ledger:change("123", "42", "9001", "deposit", "10")
assert(replayed and replay.wallet == payment.wallet and replay.bank == payment.bank)
assert(#commits == after_payment)
local replay_conflict, replay_reason = ledger:change("123", "42", "9001", "deposit", "11")
assert(not replay_conflict and replay_reason == "replay_conflict" and #commits == after_payment)
local restarted_store = Store.new(connector)
local restarted_ledger = Ledger.new(restarted_store, function() return 100000 end)
local after_restart, restart_result = restarted_ledger:change("123", "42", "9001", "deposit", "10")
assert(after_restart and restart_result.wallet == payment.wallet and #commits == after_payment)

local stale = Store.new({
  get = function() return { value = { guild = "123", accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {} }, version = 8 } end,
  encoded_size = function() return 128 end,
  transaction = function(_, operations)
    assert(operations[1].expected_version == 8)
    return nil, { code = "conflict", status = 409 }
  end,
})
local stale_ok, stale_reason = stale:run("123", function(data)
  data.accounts.x = { wallet = 1 }
  return true, "done", true
end)
assert(not stale_ok and stale_reason == "conflict")

before = #commits
local stopped, reason = store:run("123", function(data)
  data.accounts.bad = { wallet = -1 }
  return false, "insufficient", false
end)
assert(not stopped and reason == "insufficient" and #commits == before)

local too_large = Store.new({
  get = function() return { value = { guild = "9", accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {} }, version = 1 } end,
  encoded_size = function() return 4097 end,
  transaction = function() error("must not send oversized write") end,
}, { max_document_bytes = 4096 })
local large_ok, large_reason = too_large:run("9", function(data)
  data.accounts.large = { wallet = 1 }
  return true, "done", true
end)
assert(not large_ok and large_reason == "resource_limit")

local unknown = Store.new({
  get = function() return nil, { code = "not_found", status = 404 } end,
  encoded_size = function() return 32 end,
  transaction = function() return nil, { code = "transport_error", retryable = true } end,
})
local unknown_ok, unknown_reason = unknown:run("99", function(data)
  data.accounts.x = { wallet = 1 }
  return true, "done", true
end)
assert(not unknown_ok and unknown_reason == "outcome_unknown")

local malformed_ack = Store.new({
  get = function() return nil, { code = "not_found", status = 404 } end,
  encoded_size = function() return 32 end,
  transaction = function() return nil, { code = "invalid_response", status = 200 } end,
})
local malformed_ok, malformed_reason = malformed_ack:run("98", function(data)
  data.accounts.x = { wallet = 1 }
  return true, "done", true
end)
assert(not malformed_ok and malformed_reason == "outcome_unknown",
  "a malformed success response cannot prove the transaction did not commit")

local status_connector = {
  health = function() return { status = "ok" } end,
  ready = function() return { ready = true } end,
  version = function() return { api_version = "1.0.0", version = "0.1.0", engine = "preppydb" } end,
  whoami = function() return { roles = { "write" } } end,
  collections = function() return { "molly_guild_state", "molly_global_state" } end,
}
local service = Service.new(status_connector)
assert(service:connect())
assert(service:get_state().status == "healthy" and service:get_state().api_version == "1.0.0")
assert(service:health().status == "healthy")
status_connector.collections = function() return { "molly_guild_state" } end
local missing_ok, missing_reason = service:connect()
assert(not missing_ok and missing_reason == "required_collection_missing")
status_connector.collections = function() return { "molly_guild_state", "molly_global_state" } end
status_connector.whoami = function() return { roles = { "read" } } end
local role_ok, role_reason = service:connect()
assert(not role_ok and role_reason == "write_role_required")

print("PreppyDB persistence adapter: pass")
