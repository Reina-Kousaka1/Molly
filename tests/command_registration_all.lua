package.path = "./?.lua;./?/init.lua;./deps/?.lua;./deps/?/init.lua;" .. package.path

local Router = require("src.commands.router")
local RegisterCommands = require("src.commands.register_all")

local function service(extra)
  return setmetatable(extra or {}, { __index = function() return function() return true, {} end end })
end

local router = Router.new()
local app = { started_at = os.time(), health_message = function() return "ok" end }
local noop = service()
local shop = service({ lookbook = function() return {} end })
local sephora = service({ lookbook = function() return {} end })

RegisterCommands.register(router, {
  app = app, clock = os.time, ledger = noop, logger = noop, guild_settings = noop,
  shop = shop, inventory = noop, mining = noop, fashion = noop, modes = noop,
  sephora = sephora, content_policy = noop, user_settings = noop, store = noop,
  action_log = noop, music_manager = noop, music_panel = noop, dynamic_voice = noop,
  developers = {}, blacklist = noop, developer = noop, lifecycle = noop, updater = nil,
  terminate = function() end, permission_engine = noop, afk = noop, greetings = noop,
  self_roles = noop, member_events_enabled = false, on_prefix_changed = function() end,
})

local commands = router:list("slash")
local names = {}
for _, definition in ipairs(commands) do
  assert(not names[definition.name], "duplicate slash command: " .. definition.name)
  names[definition.name] = true
  assert(type(definition.description) == "string" and definition.description ~= "", "missing description: " .. definition.name)
  assert(type(definition.execute) == "function", "missing handler: " .. definition.name)
end
assert(names.permissions, "administrative /permissions command must remain registered")
assert(names["my-permissions"], "informational /my-permissions command must remain registered")
assert(names.settings and names["blacklist"] and names["observe"], "administrative commands must remain registered")
print("PASS full production command registration: " .. #commands .. " unique slash commands")
