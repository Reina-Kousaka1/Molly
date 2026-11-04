package.path = "./?.lua;./?/init.lua;./deps/?.lua;./deps/?/init.lua;" .. package.path
local discord = require("discord.lua")
local Router = require("src.commands.router")
local Bootstrap = require("src.discord.bootstrap")
local RegisterCommands = require("src.commands.register_all")
local router = Router.new()
local app = { started_at = os.time(), health_message = function() return "ok" end }
local function service(extra)
  return setmetatable(extra or {}, { __index = function() return function() return true, {} end end })
end
local noop = service()
RegisterCommands.register(router, {
  app = app, clock = os.time, ledger = noop, logger = noop, guild_settings = noop,
  shop = service({ lookbook = function() return {} end }), inventory = noop, mining = noop,
  fashion = noop, modes = noop, sephora = service({ lookbook = function() return {} end }),
  content_policy = noop, user_settings = noop, store = noop, action_log = noop,
  music_manager = noop, music_panel = noop, dynamic_voice = noop, developers = {},
  blacklist = noop, developer = noop, lifecycle = noop, updater = nil,
  terminate = function() end, permission_engine = noop, afk = noop, greetings = noop,
  self_roles = noop, member_events_enabled = false, on_prefix_changed = function() end,
})
local bootstrap = Bootstrap.new({ discord = discord, app = app, commands = router }):build()
local commands = bootstrap.bot.command_tree.commands
assert(#commands == #router:list())
local seen, settings_spec = {}, nil
local function validate_options(options, parent)
  local option_names = {}
  for _, option in ipairs(options or {}) do
    assert(type(option.name) == "string" and #option.name > 0 and #option.name <= 32,
      "invalid option name under " .. parent)
    assert(not option_names[option.name], "duplicate option name under " .. parent .. ": " .. option.name)
    option_names[option.name] = true
    assert(type(option.description) == "string" and #option.description > 0 and #option.description <= 100,
      "invalid option description under " .. parent .. ": " .. option.name)
    validate_options(option.options, parent .. "/" .. option.name)
  end
end
for _, cmd in ipairs(commands) do
  local data = cmd:to_dict()
  assert(not seen[data.name], "duplicate command"); seen[data.name] = true
  assert(#data.name <= 32 and #data.description <= 100, "command exceeds Discord name/description limits: " .. data.name)
  validate_options(data.options, data.name)
  if data.name == "settings" then settings_spec = data end
  if data.name == "hackban" then assert(#data.options == 3 and data.default_member_permissions == "4") end
  if data.name == "staff" then assert(#data.options == 5 and data.default_member_permissions == "32") end
end
local interaction = { id = "1", token = "fixture", guild_id = "2", member = { user = { id = "3" }, permissions = "32", roles = {} },
  app_permissions = "4", data = { name = "staff", options = { { type = 1, name = "notes", options = { { name = "user", type = 6, value = "4" } } } } } }
local ctx = bootstrap.bot:get_application_context(interaction)
assert(ctx.member.permissions == "32" and ctx.app_permissions == "4" and ctx.molly_subcommand == "notes" and ctx:get_arg("user").id == "4")
assert(seen.play and seen["music-panel"] and seen.voice and not seen.lyrics)
assert(seen.permissions and seen["my-permissions"])
assert(settings_spec.options[1].type == 2 and settings_spec.options[1].name == "prefix")
assert(settings_spec.options[2].type == 2 and settings_spec.options[2].name == "economy")
local settings_interaction = { id = "2", token = "fixture", guild_id = "2", member = { user = { id = "3" }, permissions = "32" },
  data = { name = "settings", options = { { type = 2, name = "prefix", options = {
    { type = 1, name = "set", options = { { name = "value", type = 3, value = "!" } } },
  } } } } }
local settings_context = bootstrap.bot:get_application_context(settings_interaction)
assert(settings_context.molly_subcommand == "prefix" and settings_context.molly_subcommand_action == "set")
local writes = 0
bootstrap.bot.client = { get_application_id = function() return '123' end }
bootstrap.bot.http = { get = function() return {} end }
bootstrap.sync_write = function(_, method, path, spec)
  assert(method == 'POST' and path == '/applications/123/commands')
  writes = writes + 1
  local result = {}
  for key, value in pairs(spec) do result[key] = value end
  result.id = tostring(writes)
  return result
end
assert(bootstrap.bot:sync_commands() and writes == #commands and bootstrap.sync_state.status == 'success')
assert(bootstrap.bot:sync_commands() and writes == #commands, 'repeated ready must not repeat writes')
print("PASS discord.lua full registration, options, permissions and interaction context: " .. #commands .. " commands")
