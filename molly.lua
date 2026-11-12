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
local ShopCommands = require("src.commands.shop")
local InventoryCommands = require("src.commands.inventory")
local MiningCommands = require("src.commands.mining")
local FashionCommands = require("src.commands.fashion")
local ModeCommands = require("src.commands.mode")
local SephoraCommands = require("src.commands.sephora")
local ContentCommands = require("src.commands.content")
local UserSettingsCommands = require("src.commands.user_settings")
local ModerationCommands = require("src.commands.moderation")
local StaffCommands = require("src.commands.staff")
local MusicCommands = require("src.commands.music")
local MusicPanelCommands = require("src.commands.music_panel")
local VoiceCommands = require("src.commands.voice")
local AdminCommands = require("src.commands.admin")
local GuildStore = require("src.persistence.guild_store")
local GlobalStore = require("src.persistence.global_store")
local PreppyStore = require("src.persistence.preppydb_store")
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
local Personality = require("src.personality.engine")
local PersonalityDiscordBridge = require("src.personality.discord_bridge")
local PrefixCommands = require("src.commands.prefix")
local GuildSettings = require("src.settings.guild")
local SettingsCommands = require("src.commands.settings")
local PermissionEngine = require("src.permissions.engine")
local PermissionCommands = require("src.commands.permissions")
local AFK = require("src.community.afk")
local Greetings = require("src.community.greetings")
local ActionLog = require("src.community.action_log")
local CommunityEvents = require("src.community.events")
local SelfRoles = require("src.community.self_roles")
local Starboard = require("src.community.starboard")
local AFKCommands = require("src.commands.afk")
local GreetingCommands = require("src.commands.greetings")
local ActionLogCommands = require("src.commands.action_logs")
local SelfRoleCommands = require("src.commands.self_roles")
local StarboardCommands = require("src.commands.starboard")
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
local music_transport_loaded, MusicTransport = pcall(require, "src.music.luvit_transport")
if not music_transport_loaded then logger:error("luvit_transport_unavailable", { dependency = "coro-http" }); os.exit(1) end
local persistence, store, global_store
if config.persistence.backend == "seaworld" then
  local driver_loaded, SeaWorldDriver = pcall(require, "src.seaworld.socket_driver")
  if not driver_loaded then logger:error("luvit_transport_unavailable", { dependency = "coro-net" }); os.exit(1) end
  local driver = config.seaworld.socket and SeaWorldDriver.new({ path = config.seaworld.socket, timeout_ms = config.seaworld.timeout_ms })
  persistence = SeaWorldConnector.new({ driver = driver })
  store, global_store = GuildStore.new(persistence), GlobalStore.new(persistence)
else
  local PreppyConnector = require("src.preppydb.connector")
  local PreppyService = require("src.persistence.preppydb_service")
  local preppy, preppy_error = PreppyConnector.new({
    url = config.persistence.preppydb.url,
    token = config.persistence.preppydb.token,
    timeout_ms = config.persistence.preppydb.timeout_ms,
    max_response_bytes = config.persistence.preppydb.max_response_bytes,
    async_bridge = true,
  })
  if not preppy then logger:error("preppydb_connector_unavailable", { detail = preppy_error or "initialization_failed" }); os.exit(1) end
  persistence = PreppyService.new(preppy)
  store = PreppyStore.new(preppy)
  global_store = store
end
local music_options = { configuration_errors = config.music.configuration_errors }
if #config.music.configuration_errors == 0 and config.music.lavalink_url then music_options.provider = LavalinkClient.new({ url = config.music.lavalink_url, password = config.music.lavalink_password, timeout_ms = config.music.lavalink_timeout_ms, transport = MusicTransport.request }) end
local music = MusicAdapter.new(music_options)
-- Personality Engine V1 (integration phase): opt-in behind
-- MOLLY_PERSONALITY_ENGINE_ENABLED, disabled by default. Even when enabled it is
-- constructed for readiness diagnostics only and is NOT bound to any Discord
-- event, never auto-replies and never persists conversation data. A
-- misconfiguration keeps the engine off and logs an error; it never stops Molly.
if #config.personality.engine.configuration_errors > 0 then
  logger:error("personality_engine_config_invalid", { variables = table.concat(config.personality.engine.configuration_errors, ",") })
end
local ollama_engine, ollama_bridge
if config.personality.engine.enabled then
  local Ollama = require("src.personality.ollama")
  local EngineV1 = require("src.personality.llm_engine")
  local transport_loaded, OllamaTransport = pcall(require, "src.personality.luvit_transport")
  local adapter, adapter_error = Ollama.new({
    url = config.personality.engine.ollama.url,
    model = config.personality.engine.ollama.model,
    timeout_ms = config.personality.engine.ollama.timeout_ms,
    max_response_bytes = config.personality.engine.ollama.max_response_bytes,
    transport = transport_loaded and OllamaTransport.request or nil,
  })
  if adapter then
    ollama_engine = EngineV1.new({ enabled = true, provider = adapter, provider_name = "ollama", logger = logger })
    local status = ollama_engine:status()
    logger:info("personality_engine_prepared", {
      enabled = status.enabled, ready = status.ready, provider = status.provider,
      model = config.personality.engine.ollama.model,
      bound_to_discord = status.bound_to_discord, memory = status.memory,
    })
    ollama_bridge = PersonalityDiscordBridge.new({ enabled = status.ready, engine = ollama_engine,
      logger = logger, cooldown_seconds = 30, max_parallel = 2,
      send = function(channel, message)
        local rest = bootstrap and bootstrap.bot and bootstrap.bot.client and bootstrap.bot.client.rest
        if not rest or type(rest.send_message) ~= "function" then return false end
        return rest:send_message(channel, { content = message })
      end })
  else
    logger:error("personality_engine_unavailable", { detail = tostring(adapter_error) })
  end
end
local app = App.new({ logger = logger, seaworld = persistence, persistence = persistence,
  persistence_backend = config.persistence.backend, music = music })
local commands = CommandRouter.new(logger)
local metrics = Metrics.new({ clock = function() return uv.now() end })
metrics:start()
commands:set_observability(metrics)
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
SmokeCommands.register(commands, app, { clock = function() return uv.now() end })
InformationCommands.register(commands, app)
EconomyCommands.register(commands, ledger, { logger = logger, settings = guild_settings })
ShopCommands.register(commands, shop, guild_settings)
InventoryCommands.register(commands, inventory)
MiningCommands.register(commands, mining)
FashionCommands.register(commands, fashion)
ContentCommands.register(commands, guild_settings, content_policy, { logs = action_log })
UserSettingsCommands.register(commands, user_settings)
ModerationCommands.register(commands, Cases.new(store), { logs = action_log })
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
  developer = Developer.new({ ledger = ledger, store = store, inventory = inventory, seaworld = persistence,
    started_at = function() return app.started_at end }),
  lifecycle = lifecycle, updater = updater, terminate = terminate,
})
local personality = Personality.new(store, { logger = logger, send = function(channel, message)
  local rest = bootstrap and bootstrap.bot and bootstrap.bot.client and bootstrap.bot.client.rest
  if not rest or type(rest.send_message) ~= "function" then return false end
  return rest:send_message(channel, { content = message })
end })
local function bind_client_events(client)
  assert(client and type(client.on) == "function", "Discord client is required")
  dynamic_voice:set_runtime(client.rest, client, nil)
  client:on("guild_create", function(guild) dynamic_voice:on_guild_create(guild); music_panel:recover(guild.id) end)
  if bootstrap.bot and type(bootstrap.bot.on_message) == "function" then
    bootstrap.bot:on_message(function(message)
      if ollama_bridge and ollama_bridge:matches(message) then
        local handled, reason = pcall(ollama_bridge.on_message, ollama_bridge, message)
        if not handled then logger:warn("personality_ollama_event_failed", { detail = "handler_error" }) end
        return
      end
      local ok, reason = pcall(personality.observe, personality, message)
      if not ok then logger:warn("personality_observe_failed", { detail = "handler_error" }) end
    end)
  end
  local bound, reason = community_events:bind(client, bootstrap.bot)
  if not bound then logger:warn("community_events_unavailable", { detail = reason or "binding_failed" }) end
end
local presence = Presence.new({ logger = logger, schedule = function(interval, fn) return timer.setInterval(interval, fn) end, cancel = timer.clearInterval,
  write = function(text) personality:set_status(text); return bootstrap.bot:change_presence({ status = "online", activity = { to_dict = function() return { type = 0, name = text } end } }) end })
local prefix_commands = PrefixCommands.new(commands, guild_settings, { logger = logger, prefix = "." })
SettingsCommands.register(commands, guild_settings, { on_prefix_changed = function(guild, prefix) prefix_commands:set_prefix(guild, prefix) end })
PermissionCommands.register(commands, permission_engine)
AFKCommands.register(commands, afk)
GreetingCommands.register(commands, guild_settings, greetings, { logs = action_log,
  member_events_enabled = config.discord.guild_members_intent })
ActionLogCommands.register(commands, guild_settings, action_log)
SelfRoleCommands.register(commands, self_roles, { logs = action_log })
StarboardCommands.register(commands, guild_settings, { logs = action_log })
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
  personality.bot_id = user.id
  if ollama_bridge then ollama_bridge:set_bot_id(user.id) end
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
  persistence:initialize()
  local connected = persistence:connect()
  if not connected then logger:error("persistence_preflight_failed", {
    backend = config.persistence.backend, status = persistence:get_state().status,
    detail = persistence:get_state().detail,
  }); os.exit(1) end
  local started = bootstrap:start(config.discord.token)
  if not started then os.exit(1) end
end)()
