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
local AdminCommands = require("src.commands.admin")
local GuildStore = require("src.persistence.guild_store")
local GlobalStore = require("src.persistence.global_store")
local Ledger = require("src.economy.ledger")
local Cases = require("src.moderation.cases")
local StaffDirectory = require("src.staff.directory")
local Blacklist = require("src.admin.blacklist")
local Developer = require("src.admin.developer")
local Lifecycle = require("src.admin.lifecycle")
local Updater = require("src.admin.updater")
local MusicManager = require("src.music.manager")
local MusicPanel = require("src.music.panel")
local DynamicVoice = require("src.voice.dynamic_channels")
local Presence = require("src.presence.rotation")
local PrefixCommands = require("src.commands.prefix")
local GuildSettings = require("src.settings.guild")
local SettingsCommands = require("src.commands.settings")
local PermissionEngine = require("src.permissions.engine")
local PermissionCommands = require("src.commands.permissions")
local timer = require("timer")
local uv = require("uv")
local DiscordBootstrap = require("src.discord.bootstrap")

local logger = Logger.new()
local secure_socket_loaded, secure_socket = pcall(require, "secure-socket")
if not secure_socket_loaded then logger:error("luvit_dependency_unavailable", { dependency = "secure-socket" }); os.exit(1) end
package.loaded["secure-socket"] = secure_socket
local config, errors = Config.load()
if not config then logger:error("configuration_invalid", { variables = table.concat(errors, ",") }); os.exit(1) end
local loaded, discord = pcall(require, "discord.lua")
if not loaded then logger:error("discord_library_unavailable", { dependency = "discord.lua" }); os.exit(1) end
local gateway_intents = discord.enums.combine_intents(discord.enums.default_intents(), discord.enums.INTENTS.MESSAGE_CONTENT)
local driver_loaded, SeaWorldDriver = pcall(require, "src.seaworld.socket_driver")
if not driver_loaded then logger:error("luvit_transport_unavailable", { dependency = "coro-net" }); os.exit(1) end
local music_transport_loaded, MusicTransport = pcall(require, "src.music.luvit_transport")
if not music_transport_loaded then logger:error("luvit_transport_unavailable", { dependency = "coro-http" }); os.exit(1) end
local driver = config.seaworld.socket and SeaWorldDriver.new({ path = config.seaworld.socket, timeout_ms = config.seaworld.timeout_ms })
local sea_world = SeaWorldConnector.new({ driver = driver })
local music_options = { configuration_errors = config.music.configuration_errors }
if #config.music.configuration_errors == 0 and config.music.lavalink_url then music_options.provider = LavalinkClient.new({ url = config.music.lavalink_url, password = config.music.lavalink_password, timeout_ms = config.music.lavalink_timeout_ms, transport = MusicTransport.request }) end
local music = MusicAdapter.new(music_options)
local app = App.new({ logger = logger, seaworld = sea_world, music = music })
local commands = CommandRouter.new(logger)
local store, global_store = GuildStore.new(sea_world), GlobalStore.new(sea_world)
local guild_settings = GuildSettings.new(store)
local permission_engine = PermissionEngine.new(store)
commands:set_permission_engine(permission_engine)
local ledger = Ledger.new(store)
local blacklist = Blacklist.new(global_store)
local lifecycle = Lifecycle.new(global_store, { version = config.build.version, commit = config.build.commit })
local updater = nil
if config.updater.url then updater = Updater.new({ url = config.updater.url, token = config.updater.token, transport = MusicTransport.request }) end
commands:set_gate(function(ctx)
  if not ctx or not ctx.author or not ctx.author.id then return false, "access_unavailable" end
  local ok, entry = blacklist:check(ctx.author.id)
  if not ok then return false, "access_unavailable" end
  return entry == nil, entry and "blacklisted" or nil
end)
SmokeCommands.register(commands, app, { clock = function() return uv.now() end })
InformationCommands.register(commands, app)
EconomyCommands.register(commands, ledger, { logger = logger, settings = guild_settings })
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
local terminating = false
local function terminate(kind)
  if terminating then return false end
  terminating = true
  bootstrap:shutdown("command_" .. kind)
  local code = kind == "restart" and Lifecycle.EXIT_RESTART or (kind == "update" and Lifecycle.EXIT_UPDATE or Lifecycle.EXIT_SHUTDOWN)
  os.exit(code)
end
AdminCommands.register(commands, {
  owners = config.developers, blacklist = blacklist,
  developer = Developer.new({ ledger = ledger, store = store, seaworld = sea_world, started_at = function() return app.started_at end }),
  lifecycle = lifecycle, updater = updater, terminate = terminate,
})
local function bind_client_events(client)
  assert(client and type(client.on) == "function", "Discord client is required")
  dynamic_voice:set_runtime(client.rest, client, nil)
  client:on("guild_create", function(guild) dynamic_voice:on_guild_create(guild); music_panel:recover(guild.id) end)
end
local presence = Presence.new({ logger = logger, schedule = function(interval, fn) return timer.setInterval(interval, fn) end, cancel = timer.clearInterval,
  write = function(text) return bootstrap.bot:change_presence({ status = "online", activity = { to_dict = function() return { type = 0, name = text } end } }) end })
local prefix_commands = PrefixCommands.new(commands, guild_settings, { logger = logger, prefix = "." })
SettingsCommands.register(commands, guild_settings, { on_prefix_changed = function(guild, prefix) prefix_commands:set_prefix(guild, prefix) end })
PermissionCommands.register(commands, permission_engine)
bootstrap = DiscordBootstrap.new({ discord = discord, intents = gateway_intents, app = app, commands = commands,
  logger = logger, presence = presence, on_client = bind_client_events }):build()
local prefix_registered, prefix_reason = prefix_commands:register(bootstrap.bot)
if not prefix_registered then
  logger:warn("prefix_commands_unavailable", { detail = prefix_reason or "event_unavailable" })
end
bootstrap.bot:on("voice_state_update", function(data) dynamic_voice:on_voice_state(data); music_manager:on_voice_state(data) end)
bootstrap.bot:on("voice_server_update", function(data) music_manager:on_voice_server(data) end)
bootstrap.bot:on("ready", function()
  local client, user = bootstrap.bot.client, bootstrap.bot.user
  if not client or not user or not user.id then return end
  music_manager:set_discord_client(client, user.id); dynamic_voice:set_runtime(client.rest, client, user.id); music_panel:set_bot(client, music_manager); music_panel:register_interactions(bootstrap.bot, music_manager)
  local started, reason = music_manager:start(user.id); if not started then logger:warn("music_gateway_unavailable", { detail = reason or "not_configured" }) end
  local pending_ok, marker = lifecycle:pending()
  if pending_ok and marker then
    local health = app:health_snapshot()
    if health.status == "healthy" and client.rest and type(client.rest.create_message) == "function" then
      local sent = pcall(client.rest.create_message, client.rest, marker.channel_id, { content = lifecycle:health_message(marker, health) })
      if sent then lifecycle:complete(marker.interaction_id) end
    end
  end
end)
process:on("sigint", function() bootstrap:shutdown("SIGINT") end)
process:on("sigterm", function() bootstrap:shutdown("SIGTERM") end)
coroutine.wrap(function()
  sea_world:initialize()
  local connected = sea_world:connect()
  if not connected then logger:error("seaworld_preflight_failed", { status = sea_world:get_state().status }); os.exit(1) end
  local started = bootstrap:start(config.discord.token)
  if not started then os.exit(1) end
end)()
