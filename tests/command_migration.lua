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
  function bot.http:patch(path, payload)
    calls.patches[#calls.patches + 1] = { path = path, payload = payload }
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
  local ok, outcome = SafeSync.run(bot, { allow_permissions_options_migration = true })
  assert(ok and outcome.migrated == 1 and outcome.created == 0 and outcome.updated == 0)
  assert(#calls.patches == 1 and #calls.posts == 0 and #calls.deletes == 0 and calls.bulk == 0)
  local call = calls.patches[1]
  assert(call.path == "/applications/app-id/commands/1565628256500191287")
  assert(call.payload.description == definition.description and #call.payload.options == #definition.options)
  assert(call.payload.default_member_permissions == nil and call.payload.integration_types == nil
    and call.payload.contexts == nil and call.payload.nsfw == nil and call.payload.id == nil,
    "PATCH must omit permissions and integration metadata to preserve existing values")
  assert(remote[1].id == "1565628256500191287" and remote[1].integration_types[1] == 0
    and remote[1].integration_types[2] == 1 and remote[1].contexts[1] == 0
    and remote[1].nsfw == false and remote[1].default_member_permissions == nil,
    "targeted update must retain identity and existing command metadata")
  local synced, after = SafeSync.run(bot)
  assert(synced and after.migrated == 0 and after.created == 0 and after.updated == 0,
    "normal sync should accept the migrated options schema")
end

do
  local remote = { legacy_command() }
  remote[1].description = "Changed outside Molly"
  local bot, calls = fixture(remote)
  local ok, reason = SafeSync.run(bot, { allow_permissions_options_migration = true })
  assert(not ok and reason == "command_conflict" and #calls.patches == 0,
    "unexpected remote definitions must fail closed")
end

io.write("PASS targeted /permissions options migration: explicit opt-in, stable ID, metadata preserved\n")
