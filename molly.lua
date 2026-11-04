package.path = "./?.lua;./?/init.lua;./deps/?.lua;./deps/?/init.lua;" .. package.path
local Config = require("src.config")
local Logger = require("src.logger")
local App = require("src.app")
local SeaWorldConnector = require("src.persistence.seaworld_connector")
local MusicAdapter = require("src.music.adapter")
local LavalinkClient = require("src.music.lavalink_client")
local CommandRouter = require("src.commands.router")
local RegisterCommands = require("src.commands.register_all")
local GuildStore = require("src.persistence.guild_store")
local GlobalStore = require("src.persistence.global_store")
local Ledger = require("src.economy.ledger")
local Inventory = require("src.economy.inventory")
local Shop = require("src.economy.shop")
local Mining = require("src.economy.mining")
local Fashion = require("src.economy.fashion")
local Modes = require("src.modes.registry")
local Sephora = require("src.modes.sephora")
local ContentPolicy = require("src.content.policy")
local UserSettings = require("src.settings.user")
local Metrics = require("src.observability.metrics")
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
local PermissionEngine = require("src.permissions.engine")
local AFK = require("src.community.afk")
local Greetings = require("src.community.greetings")
local ActionLog = require("src.community.action_log")
local CommunityEvents = require("src.community.events")
local SelfRoles = require("src.community.self_roles")
local Starboard = require("src.community.starboard")
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
if config.discord.guild_members_intent then
  if not discord.enums.INTENTS.GUILD_MEMBERS then
    logger:error("discord_member_intent_unavailable", { detail = "library_intent_missing" }); os.exit(1)
  end
  gateway_intents = discord.enums.combine_intents(gateway_intents, discord.enums.INTENTS.GUILD_MEMBERS)
end
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
local metrics = Metrics.new({ clock = function() return uv.now() end })
metrics:start()
commands:set_observability(metrics)
local store, global_store = GuildStore.new(sea_world), GlobalStore.new(sea_world)
local guild_settings = GuildSettings.new(store)
local user_settings = UserSettings.new(global_store)
local content_policy = ContentPolicy.new(guild_settings, { user_settings = user_settings })
local modes = Modes.new(guild_settings)
local sephora = Sephora.new(store, modes)
local ledger = Ledger.new(store)
local inventory = Inventory.new(store)
local shop = Shop.new(guild_settings, ledger, modes, sephora)
local mining = Mining.new(ledger, modes)
local fashion = Fashion.new(inventory, modes)
local permission_engine = PermissionEngine.new(store)
commands:set_permission_engine(permission_engine)
local greetings = Greetings.new(guild_settings, { logger = logger })
local afk = AFK.new(store, { logger = logger })
local action_log = ActionLog.new(guild_settings, { logger = logger })
local self_roles = SelfRoles.new(guild_settings, { logger = logger })
local starboard = Starboard.new(store, guild_settings, { logger = logger, content_policy = content_policy })
local community_events = CommunityEvents.new({ greetings = greetings, afk = afk, logs = action_log,
  starboard = starboard, content_policy = content_policy, logger = logger })
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
local music_panel = MusicPanel.new(store)
local music_manager = MusicManager.new(music, { panel = music_panel, logger = logger })
music_panel.manager = music_manager
local dynamic_voice = DynamicVoice.new(store, { music = music_manager, logger = logger })
local bootstrap
local terminating = false
local function terminate(kind)
  if terminating then return false end
  terminating = true
  bootstrap:shutdown("command_" .. kind)
  local code = kind == "restart" and Lifecycle.EXIT_RESTART or (kind == "update" and Lifecycle.EXIT_UPDATE or Lifecycle.EXIT_SHUTDOWN)
  os.exit(code)
end
local function bind_client_events(client)
  assert(client and type(client.on) == "function", "Discord client is required")
  dynamic_voice:set_runtime(client.rest, client, nil)
  client:on("guild_create", function(guild) dynamic_voice:on_guild_create(guild); music_panel:recover(guild.id) end)
  local bound, reason = community_events:bind(client, bootstrap.bot)
  if not bound then logger:warn("community_events_unavailable", { detail = reason or "binding_failed" }) end
end
local presence = Presence.new({ logger = logger, schedule = function(interval, fn) return timer.setInterval(interval, fn) end, cancel = timer.clearInterval,
  write = function(text) return bootstrap.bot:change_presence({ status = "online", activity = { to_dict = function() return { type = 0, name = text } end } }) end })
local prefix_commands = PrefixCommands.new(commands, guild_settings, { logger = logger, prefix = "." })
RegisterCommands.register(commands, {
  app = app, clock = function() return uv.now() end, ledger = ledger, logger = logger,
  guild_settings = guild_settings, shop = shop, inventory = inventory, mining = mining,
  fashion = fashion, modes = modes, sephora = sephora, content_policy = content_policy,
  user_settings = user_settings, store = store, action_log = action_log,
  music_manager = music_manager, music_panel = music_panel, dynamic_voice = dynamic_voice,
  developers = config.developers, blacklist = blacklist, developer = Developer.new({ ledger = ledger,
    store = store, inventory = inventory, metrics = metrics, seaworld = sea_world,
    started_at = function() return app.started_at end }),
  lifecycle = lifecycle, updater = updater, terminate = terminate,
  permission_engine = permission_engine, afk = afk, greetings = greetings,
  self_roles = self_roles, member_events_enabled = config.discord.guild_members_intent,
  on_prefix_changed = function(guild, prefix) prefix_commands:set_prefix(guild, prefix) end,
})
bootstrap = DiscordBootstrap.new({ discord = discord, intents = gateway_intents, app = app, commands = commands,
  logger = logger, presence = presence, on_client = bind_client_events,
  allow_permissions_options_migration = config.discord.migrate_permissions_command }):build()
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
