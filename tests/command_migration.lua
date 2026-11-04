package.path = "./?.lua;./?/init.lua;./deps/?.lua;./deps/?/init.lua;" .. package.path

local Router = require("src.commands.router")
local PermissionCommands = require("src.commands.permissions")
local SafeSync = require("src.discord.safe_sync")

local router = Router.new()
PermissionCommands.register(router, {})
local definition = router.commands.permissions
assert(definition and definition.permission == "manage_guild")
assert(definition.default_member_permissions == nil,
  "the migration must preserve the existing Discord default permission metadata")
local allowed, denial = router:authorize("permissions", { member = { permissions = "0" } })
assert(not allowed and denial == "permission_denied",
  "router authorization must enforce Manage Server even without Discord default permission metadata")
local local_spec = {
  name = definition.name, type = 1, description = definition.description,
  options = definition.options,
}

local function fixture(remote)
  local calls = { patches = {}, posts = {}, deletes = {}, bulk = 0 }
  local bot = {
    client = { get_application_id = function() return "app-id" end },
    command_tree = { commands = { { to_dict = function() return local_spec end } } },
    http = {},
  }
  function bot.http:get(path)
    assert(path == "/applications/app-id/commands")
    return remote
  end
  function bot.http:patch(path, payload, options)
    calls.patches[#calls.patches + 1] = { path = path, payload = payload, options = options }
    local item = remote[1]
    for key, value in pairs(payload) do item[key] = value end
    return item
  end
  function bot.http:post(path, payload)
    calls.posts[#calls.posts + 1] = { path = path, payload = payload }
    return { id = "new-id", name = payload.name, type = payload.type }
  end
  function bot.http:delete(path) calls.deletes[#calls.deletes + 1] = path end
  function bot.http:put(path) calls.bulk = calls.bulk + 1; error("bulk overwrite must never be called: " .. path) end
  return bot, calls
end

local function legacy_command()
  return {
    id = "1565628256500191287", name = "permissions", type = 1,
    description = "Show selected effective permissions", options = {},
    integration_types = { 0, 1 }, contexts = { 0 }, nsfw = false,
  }
end

do
  local remote = { legacy_command() }
  local bot, calls = fixture(remote)
  local ok, reason, details = SafeSync.run(bot)
  assert(not ok and reason == "command_conflict" and details.command == "permissions")
  assert(#calls.patches == 0 and #calls.posts == 0 and #calls.deletes == 0 and calls.bulk == 0,
    "migration must be disabled unless explicitly approved")
end

do
  local remote = { legacy_command() }
  local bot, calls = fixture(remote)
  local ok, reason = SafeSync.run(bot, { allow_permissions_options_migration = true })
  assert(not ok and reason == "migration_requires_controlled_transport")
  assert(#calls.patches == 0 and #calls.posts == 0 and #calls.deletes == 0 and calls.bulk == 0)
end

do
  local remote = { legacy_command() }
  remote[1].id = "1565628256500191288"
  local bot, calls = fixture(remote)
  local ok = SafeSync.run(bot, { allow_permissions_options_migration = true })
  assert(not ok and #calls.patches == 0, "unexpected command ID must fail closed")
end

do
  local remote = { legacy_command() }
  remote[1].description = "Changed outside Molly"
  local bot, calls = fixture(remote)
  local ok, reason = SafeSync.run(bot, { allow_permissions_options_migration = true })
  assert(not ok and reason == "command_conflict" and #calls.patches == 0,
    "unexpected remote definitions must fail closed")
end

io.write("PASS legacy migration is blocked in the automatic sync path\n")
