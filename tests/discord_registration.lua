package.path = "./?.lua;./?/init.lua;./deps/?.lua;./deps/?/init.lua;" .. package.path
local discord = require("discord.lua")
local Router = require("src.commands.router")
local Bootstrap = require("src.discord.bootstrap")
local router = Router.new()
local app = { started_at = os.time(), health_message = function() return "ok" end }
require("src.commands.smoke").register(router, app)
require("src.commands.information").register(router, app)
require("src.commands.economy").register(router, {})
require("src.commands.moderation").register(router, {})
require("src.commands.staff").register(router, {})
require("src.commands.music").register(router, {})
require("src.commands.music_panel").register(router, {})
require("src.commands.voice").register(router, {})
require("src.commands.settings").register(router, {
  get = function() return true, { prefix = ".", currency_name = "coins", currency_symbol = "" } end,
  set_prefix = function() return true, { prefix = "!" } end,
  reset_prefix = function() return true, { prefix = "." } end,
  set_currency_name = function() return true end,
  set_currency_symbol = function() return true end,
  reset_economy = function() return true end,
})
local bootstrap = Bootstrap.new({ discord = discord, app = app, commands = router }):build()
local commands = bootstrap.bot.command_tree.commands
assert(#commands == #router:list())
local seen, settings_spec = {}, nil
for _, cmd in ipairs(commands) do
  local data = cmd:to_dict()
  assert(not seen[data.name], "duplicate command"); seen[data.name] = true
  if data.name == "settings" then settings_spec = data end
  if data.name == "hackban" then assert(#data.options == 3 and data.default_member_permissions == "4") end
  if data.name == "staff" then assert(#data.options == 5 and data.default_member_permissions == "32") end
end
local interaction = { id = "1", token = "fixture", guild_id = "2", member = { user = { id = "3" }, permissions = "32", roles = {} },
  app_permissions = "4", data = { name = "staff", options = { { type = 1, name = "notes", options = { { name = "user", type = 6, value = "4" } } } } } }
local ctx = bootstrap.bot:get_application_context(interaction)
assert(ctx.member.permissions == "32" and ctx.app_permissions == "4" and ctx.molly_subcommand == "notes" and ctx:get_arg("user").id == "4")
assert(seen.play and seen["music-panel"] and seen.voice and not seen.lyrics)
assert(settings_spec.options[1].type == 2 and settings_spec.options[1].name == "prefix")
assert(settings_spec.options[2].type == 2 and settings_spec.options[2].name == "economy")
local settings_interaction = { id = "2", token = "fixture", guild_id = "2", member = { user = { id = "3" }, permissions = "32" },
  data = { name = "settings", options = { { type = 2, name = "prefix", options = {
    { type = 1, name = "set", options = { { name = "value", type = 3, value = "!" } } },
  } } } } }
local settings_context = bootstrap.bot:get_application_context(settings_interaction)
assert(settings_context.molly_subcommand == "prefix" and settings_context.molly_subcommand_action == "set")
print("PASS discord.lua registration, options, permissions and interaction context: " .. #commands .. " commands")
