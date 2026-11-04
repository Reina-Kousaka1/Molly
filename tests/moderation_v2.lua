package.path = "./?.lua;./?/init.lua;" .. package.path

local Router = require("src.commands.router")
local Prefix = require("src.commands.prefix")
local Settings = require("src.settings.guild")
local Cases = require("src.moderation.cases")
local Moderation = require("src.commands.moderation")
local Purge = require("src.moderation.purge")

local total, failed = 0, 0
local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then print("ok - " .. name)
  else failed = failed + 1; io.stderr:write("not ok - " .. name .. ": " .. tostring(err) .. "\n") end
end

local function clone(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = clone(item) end
  return result
end

local function memory_store()
  local store = { data = {} }
  function store:run(guild, fn)
    local data = clone(self.data[guild] or { guild = guild, accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {}, next_case = 1 })
    local ok, result, changed = fn(data)
    if ok and changed then self.data[guild] = data end
    return ok, result
  end
  return store
end

local function recent_message(id, timestamp)
  return { id = id, timestamp = timestamp, content = "discarded" }
end

local function permission_rest(options)
  options = options or {}
  local roles = {
    { id = "1", position = 0, permissions = "0" },
    { id = "30", position = 4, permissions = options.actor_permissions or "8192" },
    { id = "50", position = 5, permissions = options.bot_permissions or "8192" },
  }
  local rest = {
    get_guild = function() return { owner_id = "90" } end,
    get_roles = function() return roles end,
    get_member = function(_, _, id)
      if id == "10" then return { roles = { "30" } } end
      if id == "99" then return { roles = { "50" } } end
      if options.target_missing and id == options.target_missing then error({ code = 10007 }) end
      if id == options.target then return { roles = { "30" } } end
      return { roles = {} }
    end,
  }
  return rest, roles
end

test("purge validates the guild channel and bulk-deletes only recent messages", function()
  local now = os.time()
  local deleted, limit
  local rest = {
    get_channel = function(_, id) return { id = id, guild_id = "1", type = 0 } end,
    get_channel_messages = function(_, _, options)
      limit = options.limit
      return { recent_message("100", os.date("!%Y-%m-%dT%H:%M:%S", now - 30)),
        recent_message("101", os.date("!%Y-%m-%dT%H:%M:%S", now - 60)),
        recent_message("102", os.date("!%Y-%m-%dT%H:%M:%S", now - 15 * 86400)) }
    end,
    bulk_delete_messages = function(_, channel, ids, reason)
      deleted = { channel = channel, ids = ids, reason = reason }
      return true
    end,
  }
  local ctx = { source = "slash", guild = { id = "1" }, channel = { id = "2" }, app_permissions = "8192",
    bot = { rest = rest }, author = { id = "10" } }
  local ok, count = Purge.new({ clock = function() return now end }):run(ctx, 3)
  assert(ok and count == 2 and limit == 3)
  assert(deleted and deleted.channel == "2" and #deleted.ids == 2)
  assert(deleted.ids[1] == "100" and deleted.ids[2] == "101" and deleted.reason == "Moderation purge")
end)

test("prefix purge preserves its invocation and caps the request", function()
  local now = os.time()
  local removed, limit, reply
  local rest = permission_rest({})
  rest.get_channel = function(_, id) return { id = id, guild_id = "1", type = 0 } end
  rest.get_channel_messages = function(_, _, options)
    limit = options.limit
    return { recent_message("100", os.date("!%Y-%m-%dT%H:%M:%S", now)),
      recent_message("101", os.date("!%Y-%m-%dT%H:%M:%S", now - 30)),
      recent_message("102", os.date("!%Y-%m-%dT%H:%M:%S", now - 60)) }
  end
  rest.bulk_delete_messages = function(_, channel, ids) removed = { channel = channel, ids = ids }; return true end
  local ctx = { source = "message", guild = { id = "1" }, channel = { id = "2" }, channel_id = "2",
    message = { id = "100" }, request_id = "100", author = { id = "10" }, bot = { user = { id = "99" }, rest = rest } }
  local ok, count = Purge.new({ clock = function() return now end }):run(ctx, "2")
  assert(ok and count == 2 and limit == 3 and removed.channel == "2")
  assert(#removed.ids == 2 and removed.ids[1] == "101" and removed.ids[2] == "102")
  local rejected, reason = Purge.new():run(ctx, "100")
  assert(not rejected and reason == "invalid_count")
end)

test("purge fails closed on missing bot permission, wrong guild and stale-only messages", function()
  local now = os.time()
  local rest, roles = permission_rest({ bot_permissions = "0" })
  rest.get_channel = function(_, id) return { id = id, guild_id = "1", type = 0 } end
  rest.get_channel_messages = function() error("must not fetch without permission") end
  local ctx = { source = "slash", guild = { id = "1" }, channel = { id = "2" }, app_permissions = "0",
    bot = { rest = rest } }
  local ok, reason = Purge.new():run(ctx, 1)
  assert(not ok and reason == "bot_permission_denied")
  ctx.app_permissions = "8192"
  rest.get_channel = function() return { id = "2", guild_id = "3", type = 0 } end
  ok, reason = Purge.new():run(ctx, 1)
  assert(not ok and reason == "invalid_channel")
  rest.get_channel = function() return { id = "2", guild_id = "1", type = 0 } end
  rest.get_channel_messages = function() return { recent_message("120", os.date("!%Y-%m-%dT%H:%M:%S", now - 15 * 86400)) } end
  local deleted = false
  rest.delete_message = function() deleted = true; return true end
  rest.bulk_delete_messages = function() deleted = true; return true end
  ok, reason = Purge.new():run(ctx, 1)
  assert(ok and reason == 0 and not deleted)
end)

test("fixed d and hb aliases route purge and confirmed hackban without replay", function()
  local store = memory_store()
  local cases = Cases.new(store)
  local router = Router.new()
  Moderation.register(router, cases)
  assert(router:prefix_definition("d") == router.commands.delete)
  assert(router:prefix_definition("hb") == router.commands.hackban)
  assert(router:prefix_definition("purge") == nil and router:prefix_definition("hackban") == router.commands.hackban)

  local now = os.time()
  local bot_rest = permission_rest({ actor_permissions = "8196", bot_permissions = "8196", target_missing = "12345678901234567" })
  bot_rest.get_channel = function(_, id) return { id = id, guild_id = "1", type = 0 } end
  bot_rest.get_channel_messages = function(_, _, options)
    assert(options.limit == 3)
    return { recent_message("1000", os.date("!%Y-%m-%dT%H:%M:%S", now)),
      recent_message("1001", os.date("!%Y-%m-%dT%H:%M:%S", now - 30)),
      recent_message("1002", os.date("!%Y-%m-%dT%H:%M:%S", now - 60)) }
  end
  local purged, bans, replies = {}, 0, {}
  bot_rest.bulk_delete_messages = function(_, channel, ids) purged.channel, purged.ids = channel, ids; return true end
  bot_rest.ban = function(_, guild, user) bans = bans + 1; assert(guild == "1" and user == "12345678901234567"); return true end
  bot_rest.get_ban = function(_, _, user) return { user = { id = user } } end
  local bot = { user = { id = "99" }, rest = bot_rest }
  local settings = { get = function() return true, { prefix = "." } end }
  local prefix = Prefix.new(router, settings, { clock = function() return now end })
  prefix.bot = { client = bot }

  local message = { id = "1000", guild_id = "1", channel_id = "2", content = ".d 2",
    author = { id = "10" }, member = { permissions = "8192", roles = { "30" } },
    reply = function(_, text) replies[#replies + 1] = text end }
  assert(prefix:dispatch(message))
  assert(#purged.ids == 2 and purged.ids[1] == "1001" and purged.ids[2] == "1002")
  assert(replies[#replies]:find("Deleted 2", 1, true))

  local hackban = { id = "1003", guild_id = "1", channel_id = "2",
    content = ".hb confirm 12345678901234567 repeated reason with spaces", author = { id = "10" },
    member = { permissions = "4", roles = { "30" } }, reply = function(_, text) replies[#replies + 1] = text end }
  local handled, handle_reason = prefix:dispatch(hackban)
  assert(handled and bans == 1, tostring(handled) .. ":" .. tostring(handle_reason) .. ":" .. tostring(replies[#replies]))
  assert(replies[#replies]:find("Discord confirms the ban", 1, true))
  assert(prefix:dispatch(hackban) and bans == 1)
  assert(replies[#replies]:find("no ban was repeated", 1, true))
end)

print(string.format("%d V2 moderation tests, %d failures", total, failed))
if failed > 0 then os.exit(1) end
