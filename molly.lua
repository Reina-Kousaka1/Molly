package.path = "./?.lua;./?/init.lua;./deps/?.lua;./deps/?/init.lua;" .. package.path
local Config = require("src.config")
local Logger = require("src.logger")
local App = require("src.app")
local SeaWorldConnector = require("src.persistence.seaworld_connector")
local MusicAdapter = require("src.music.adapter")
local LavalinkClient = require("src.music.lavalink_client")
local CommandRouter = require("src.commands.router")
local SmokeCommands = require("src.commands.smoke")
local InformationCommands = require("src.commands.information")
local EconomyCommands = require("src.commands.economy")
local ModerationCommands = require("src.commands.moderation")
local StaffCommands = require("src.commands.staff")
local MusicCommands = require("src.commands.music")
local MusicPanelCommands = require("src.commands.music_panel")
local VoiceCommands = require("src.commands.voice")
local GuildStore = require("src.persistence.guild_store")
local Ledger = require("src.economy.ledger")
local Cases = require("src.moderation.cases")
local StaffDirectory = require("src.staff.directory")
local MusicManager = require("src.music.manager")
local MusicPanel = require("src.music.panel")
local DynamicVoice = require("src.voice.dynamic_channels")
local Presence = require("src.presence.rotation")
local PrefixCommands = require("src.commands.prefix")
local timer = require("timer")
local uv = require("uv")
local DiscordBootstrap = require("src.discord.bootstrap")

local logger = Logger.new()
-- Luvit resolves package-internal relative imports through its own loader.
-- The persistence transport also uses Lua's ordinary require; share the
-- correctly loaded TLS module with that loader before either opens HTTPS.
local secure_socket_loaded, secure_socket = pcall(require, "secure-socket")
if not secure_socket_loaded then
  logger:error("luvit_dependency_unavailable", { dependency = "secure-socket" })
  os.exit(1)
end
package.loaded["secure-socket"] = secure_socket
local config, errors = Config.load()
if not config then
  -- Only variable names are reported; neither values nor secrets reach the log.
  logger:error("configuration_invalid", { variables = table.concat(errors, ",") })
  os.exit(1)
end

local loaded, discord = pcall(require, "discord.lua")
if not loaded then
  logger:error("discord_library_unavailable", { dependency = "discord.lua" })
  os.exit(1)
end
local gateway_intents = discord.enums.combine_intents(discord.enums.default_intents(), discord.enums.INTENTS.MESSAGE_CONTENT)

local driver_loaded, SeaWorldDriver = pcall(require, "src.seaworld.socket_driver")
if not driver_loaded then
  logger:error("luvit_transport_unavailable", { dependency = "coro-net" })
  os.exit(1)
end
local music_transport_loaded, MusicTransport = pcall(require, "src.music.luvit_transport")
if not music_transport_loaded then
  logger:error("luvit_transport_unavailable", { dependency = "coro-http" })
  os.exit(1)
end
local driver = config.seaworld.socket and SeaWorldDriver.new({
  path = config.seaworld.socket, timeout_ms = config.seaworld.timeout_ms,
})
local sea_world = SeaWorldConnector.new({ driver = driver })
local music_options = { configuration_errors = config.music.configuration_errors }
if #config.music.configuration_errors == 0 and config.music.lavalink_url then
  music_options.provider = LavalinkClient.new({
    url = config.music.lavalink_url,
    password = config.music.lavalink_password,
    timeout_ms = config.music.lavalink_timeout_ms,
    transport = MusicTransport.request,
  })
end
local music = MusicAdapter.new(music_options)
local app = App.new({ logger = logger, seaworld = sea_world, music = music })
local commands = CommandRouter.new(logger)
SmokeCommands.register(commands, app, { clock = function() return uv.now() end })
InformationCommands.register(commands, app)
local store = GuildStore.new(sea_world)
local economy = EconomyCommands.register(commands, Ledger.new(store), { logger = logger })
ModerationCommands.register(commands, Cases.new(store))
StaffCommands.register(commands, StaffDirectory.new(store))
local music_panel = MusicPanel.new(store)
local music_manager = MusicManager.new(music, { panel = music_panel, logger = logger })
music_panel.manager = music_manager
MusicCommands.register(commands, music_manager)
MusicPanelCommands.register(commands, music_panel)
local dynamic_voice = DynamicVoice.new(store, { music = music_manager, logger = logger })
VoiceCommands.register(commands, dynamic_voice)
local bootstrap
local function bind_client_events(client)
  -- Subscribe before the gateway is started so the first GUILD_CREATE cannot
  -- race past Join-to-Create recovery during READY handling.
  assert(client and type(client.on) == "function", "Discord client is required")
  -- REST is ready after Bot:connect(), before the first guild/voice event.
  -- Bind it here instead of waiting for READY so JTC cannot see a join with
  -- an uninitialized REST adapter.
  dynamic_voice:set_runtime(client.rest, client, nil)
  client:on("guild_create", function(guild)
    dynamic_voice:on_guild_create(guild)
    music_panel:recover(guild.id)
  end)
end
local presence = Presence.new({
  logger = logger,
  schedule = function(interval, fn) return timer.setInterval(interval, fn) end,
  cancel = timer.clearInterval,
  write = function(text)
    return bootstrap.bot:change_presence({ status = "online", activity = { to_dict = function() return { type = 0, name = text } end } })
  end,
})
bootstrap = DiscordBootstrap.new({
  discord = discord,
  intents = gateway_intents,
  app = app,
  commands = commands,
  logger = logger,
  presence = presence,
  on_client = bind_client_events,
}):build()

local prefix_commands = PrefixCommands.new(economy, { logger = logger, prefix = "." })
local prefix_registered, prefix_reason = prefix_commands:register(bootstrap.bot)
if not prefix_registered then
  logger:warn("prefix_commands_unavailable", { detail = prefix_reason or "event_unavailable" })
end

bootstrap.bot:on("voice_state_update", function(data) dynamic_voice:on_voice_state(data); music_manager:on_voice_state(data) end)
bootstrap.bot:on("voice_server_update", function(data) music_manager:on_voice_server(data) end)
bootstrap.bot:on("ready", function()
  local client, user = bootstrap.bot.client, bootstrap.bot.user
  if not client or not user or not user.id then return end
  music_manager:set_discord_client(client, user.id)
  dynamic_voice:set_runtime(client.rest, client, user.id)
  music_panel:set_bot(client, music_manager)
  music_panel:register_interactions(bootstrap.bot, music_manager)
  local started, reason = music_manager:start(user.id)
  if not started then logger:warn("music_gateway_unavailable", { detail = reason or "not_configured" }) end
end)

process:on("sigint", function() bootstrap:shutdown("SIGINT") end)
process:on("sigterm", function() bootstrap:shutdown("SIGTERM") end)
coroutine.wrap(function()
  sea_world:initialize()
  local connected = sea_world:connect()
  if not connected then
    logger:error("seaworld_preflight_failed", { status = sea_world:get_state().status })
    os.exit(1)
  end
  local started = bootstrap:start(config.discord.token)
  if not started then os.exit(1) end
end)()
