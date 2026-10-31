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
local bootstrap = Bootstrap.new({ discord = discord, app = app, commands = router }):build()
local commands = bootstrap.bot.command_tree.commands
assert(#commands == #router:list())
local seen = {}
for _, cmd in ipairs(commands) do
  local data = cmd:to_dict()
  assert(not seen[data.name], "duplicate command"); seen[data.name] = true
  if data.name == "hackban" then assert(#data.options == 3 and data.default_member_permissions == "4") end
  if data.name == "staff" then assert(#data.options == 5 and data.default_member_permissions == "32") end
end
local interaction = { id = "1", token = "fixture", guild_id = "2", member = { user = { id = "3" }, permissions = "32", roles = {} },
  app_permissions = "4", data = { name = "staff", options = { { type = 1, name = "notes", options = { { name = "user", type = 6, value = "4" } } } } } }
local ctx = bootstrap.bot:get_application_context(interaction)
assert(ctx.member.permissions == "32" and ctx.app_permissions == "4" and ctx.molly_subcommand == "notes" and ctx:get_arg("user").id == "4")
assert(seen.play and seen["music-panel"] and seen.voice and not seen.lyrics)
print("PASS discord.lua registration, options, permissions and interaction context: " .. #commands .. " commands")
