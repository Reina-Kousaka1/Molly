package.path = "./?.lua;./?/init.lua;" .. package.path

local Config = require("src.config")
local Logger = require("src.logger")
local Status = require("src.status")
local SeaWorldClient = require("src.seaworld.client")
local App = require("src.app")
local EventRouter = require("src.events.router")
local CommandRouter = require("src.commands.router")
local SmokeCommands = require("src.commands.smoke")
local DiscordBootstrap = require("src.discord.bootstrap")
local MusicAdapter = require("src.music.adapter")
local LavalinkClient = require("src.music.lavalink_client")
local SeaWorldConnector = require("src.persistence.seaworld_connector")
local Health = require("src.health")
local Response = require("src.discord.response")

local total, failed = 0, 0
local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then
    io.stdout:write("ok - " .. name .. "\n")
  else
    failed = failed + 1
    io.stderr:write("not ok - " .. name .. ": " .. tostring(err) .. "\n")
  end
end

local function equal(actual, expected)
  assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

test("config validates without disclosing a token", function()
  local config, errors = Config.load({ MOLLY_DISCORD_TOKEN = "" })
  assert(config == nil)
  equal(errors[1], "MOLLY_DISCORD_TOKEN")
  assert(not table.concat(errors, ","):find("fixture", 1, true))
end)

test("config accepts namespaced SeaWorld configuration", function()
  local config = assert(Config.load({
    MOLLY_DISCORD_TOKEN = string.rep("x", 1),
    SEAWORLD_HEALTH_URL = "http://127.0.0.1:9184/health",
    SEAWORLD_TIMEOUT_MS = "250",
    SEAWORLD_RETRY_ATTEMPTS = "2",
  }))
  equal(config.seaworld.timeout_ms, 250)
  equal(config.seaworld.retry_attempts, 2)
end)

test("config rejects a SeaWorld URL containing credentials", function()
  local config, errors = Config.load({
    MOLLY_DISCORD_TOKEN = string.rep("x", 1),
    SEAWORLD_HEALTH_URL = "https://user:password@example.invalid/health",
  })
  assert(config == nil)
  equal(errors[1], "SEAWORLD_HEALTH_URL")
end)

test("invalid optional Lavalink configuration does not enable music", function()
  local config = assert(Config.load({
    MOLLY_DISCORD_TOKEN = string.rep("x", 1),
    MOLLY_LAVALINK_URL = "http://127.0.0.1:2333",
  }))
  equal(config.music.configuration_errors[1], "MOLLY_LAVALINK_PASSWORD")
end)

test("SeaWorld unreachable is reported as unavailable", function()
  local client = SeaWorldClient.new({
    health_url = "http://example.invalid/health",
    transport = function() return nil, "connection_refused" end,
  })
  equal(client:check().status, "unavailable")
end)

test("SeaWorld timeout is bounded and reported", function()
  local attempts = 0
  local client = SeaWorldClient.new({
    health_url = "http://example.invalid/health",
    retry_attempts = 2,
    transport = function(_, _, options)
      attempts = attempts + 1
      equal(options.timeout_ms, 1000)
      return nil, "timeout"
    end,
  })
  local state = client:check()
  equal(attempts, 2)
  equal(state.detail, "timeout")
end)

test("SeaWorld successful health response is connected", function()
  local client = SeaWorldClient.new({
    health_url = "http://example.invalid/health",
    transport = function() return { code = 200 }, '{"status":"ok"}' end,
  })
  equal(client:check().status, "connected")
end)

test("SeaWorld malformed response is rejected", function()
  local client = SeaWorldClient.new({
    health_url = "http://example.invalid/health",
    transport = function() return { code = 200 }, '{"state":"fine"}' end,
  })
  equal(client:check().detail, "invalid_response")
end)

test("SeaWorld invalid HTTP metadata is rejected", function()
  local client = SeaWorldClient.new({
    health_url = "http://example.invalid/health",
    transport = function() return { code = "not-a-status" }, '{"status":"ok"}' end,
  })
  equal(client:check().detail, "unexpected_status")
end)

test("SeaWorld persistence connector is not configured without an official driver", function()
  local connector = SeaWorldConnector.new()
  equal(connector:initialize().status, "not_configured")
  equal(connector:health().status, "not_configured")
  local ok, reason = connector:write({ key = "test" })
  assert(not ok)
  equal(reason, "not_configured")
end)

test("SeaWorld persistence connector delegates a compatible official driver", function()
  local calls = {}
  local driver = {
    initialize = function() calls.initialize = true end,
    connect = function() calls.connect = true return true end,
    health = function()
      return { status = "healthy", api_version = "1.0.0", capabilities = { read = true, write = true, transaction = true, native_queries = true, field_updates = true, transactions = true } }
    end,
    read = function(_, key) calls.read = key return true, { key = key } end,
    write = function(_, value) calls.write = value return true, "stored" end,
    transaction = function(_, fn) calls.transaction = true return fn() end,
    close = function() calls.close = true end,
  }
  local connector = SeaWorldConnector.new({ driver = driver })
  equal(connector:initialize().detail, "initialized")
  assert(connector:connect())
  local capabilities = assert(connector:capabilities())
  assert(capabilities.write)
  local read_ok, record = connector:read("key")
  assert(read_ok)
  equal(record.key, "key")
  assert(connector:write({ key = "key" }))
  assert(connector:transaction(function() return true, "committed" end))
  assert(connector:close())
  assert(calls.initialize and calls.connect and calls.read and calls.write and calls.transaction and calls.close)
end)

test("SeaWorld persistence connector rejects incompatible APIs and fails closed writes", function()
  local driver = {
    connect = function() return true end,
    health = function() return { status = "healthy", api_version = "2.0.0", capabilities = { write = true } } end,
    write = function() return true end,
  }
  local connector = SeaWorldConnector.new({ driver = driver })
  equal(connector:health().status, "incompatible_api")
  local ok, reason = connector:write({ key = "must-not-write" })
  assert(not ok)
  equal(reason, "incompatible_api")
end)

test("SeaWorld V1 negotiation requires the capabilities used by Molly", function()
  local version, caps = "1.3.0", { native_queries = true, field_updates = true, transactions = true }
  local connector = SeaWorldConnector.new({ driver = {
    health = function() return { status = "healthy", api_version = version, capabilities = caps } end,
  } })
  equal(connector:health().status, "healthy")
  caps.transactions = false
  equal(connector:health().status, "incompatible_api")
  caps.transactions = true
  version = "1.0.0-invalid"
  equal(connector:health().status, "incompatible_api")
end)

test("SeaWorld persistence connector reports unavailable transport and closes gracefully", function()
  local closed = false
  local connector = SeaWorldConnector.new({
    driver = {
      connect = function() return false end,
      health = function() return { status = "unhealthy" } end,
      close = function() closed = true end,
    },
  })
  local ok, reason = connector:connect()
  assert(not ok)
  equal(reason, "connect_failed")
  assert(connector:close())
  assert(closed)
end)

test("health status remains non-sensitive", function()
  local output = Status.message(true, { status = "unavailable" })
  assert(output:find("Molly: online", 1, true))
  assert(output:find("Discord: connected", 1, true))
  assert(not output:find("http", 1, true))
end)

test("normal logs redact secret fields", function()
  local records = {}
  local logger = Logger.new(function(record) records[#records + 1] = record end)
  local fixture = table.concat({ "test", "only" }, "-")
  logger:info("test", { token = fixture, nested = { password = fixture } })
  assert(not records[1]:find(fixture, 1, true))
  assert(records[1]:find("[REDACTED]", 1, true))
end)

test("event router isolates a failing handler", function()
  local records = {}
  local logger = Logger.new(function(record) records[#records + 1] = record end)
  local events = EventRouter.new(logger)
  local completed = false
  events:on("test", function() error("fixture failure") end)
  events:on("test", function() completed = true end)
  events:dispatch("test")
  assert(completed)
  assert(records[1]:find("event_handler_failed", 1, true))
  assert(not records[1]:find("fixture failure", 1, true))
end)

test("smoke commands route without a Discord connection", function()
  local sea_world = {
    get_state = function() return { status = "unavailable", detail = "not_configured" } end,
    health = function() return { status = "unavailable", detail = "not_configured" } end,
  }
  local app = App.new({ logger = Logger.new(function() end), seaworld = sea_world })
  local commands = CommandRouter.new(Logger.new(function() end))
  local ticks = { 100, 142.738 }
  SmokeCommands.register(commands, app, { clock = function() return table.remove(ticks, 1) end })
  local response, ack, edited
  local context = {
    interaction_id = "1", interaction_token = "fixture",
    bot = { application_id = "2", rest = { create_interaction_response = function(_, _, _, payload)
      ack = payload.type == 5
    end } },
    respond = function(_, value) response = value end,
    edit = function(_, value) edited = value end,
  }
  assert(commands:dispatch("ping", context))
  assert(ack)
  equal(edited, "🏓 Pong! 43 ms")
  assert(not edited:find("%.%d+ ms"))
  assert(commands:dispatch("health", context))
  assert(edited:find("SeaWorld: Unavailable", 1, true))
  assert(edited:find("Persistence: Degraded", 1, true))
  local ok, reason = commands:dispatch("unknown", context)
  assert(not ok)
  equal(reason, "unknown_command")
end)

test("deferred responses are public by default and private only when requested", function()
  local payloads, reads = {}, 0
  local rest = {
    create_interaction_response = function(_, _, _, payload) payloads[#payloads + 1] = payload; return true end,
    get_original_interaction_response = function() reads = reads + 1; error("must not require a second request") end,
  }
  local function context()
    return { bot = { application_id = "2", rest = rest }, interaction_id = "1", interaction_token = "fixture" }
  end
  local public, private = context(), context()
  assert(Response.defer(public))
  assert(public._molly_deferred and payloads[1].type == 5 and payloads[1].data == nil)
  assert(Response.defer(private, { ephemeral = true }))
  assert(private._molly_deferred and payloads[2].type == 5 and payloads[2].data.flags == 64)
  assert(reads == 0)
  assert(Response.defer(public) and #payloads == 2)
end)

test("ping uses a plain response fallback if defer is unavailable", function()
  local app = { health_snapshot = function() return Health.snapshot({}) end }
  local commands = CommandRouter.new(Logger.new(function() end))
  SmokeCommands.register(commands, app)
  local response
  assert(commands:dispatch("ping", { respond = function(_, value) response = value end }))
  equal(response, "🏓 Pong! Response latency unavailable")
end)

test("health snapshot reports healthy runtime, Discord, SeaWorld, persistence, and uptime", function()
  local app = App.new({
    logger = Logger.new(function() end),
    seaworld = { health = function() return { status = "healthy", api_version = "1.0.0", capabilities = { transactions = true } } end },
  })
  app.running, app.started_at, app.discord_connected = true, os.time() - 8040, true
  local state = app:health_snapshot()
  equal(state.status, "healthy")
  equal(state.process.status, "healthy")
  equal(state.runtime.status, "healthy")
  equal(state.discord.status, "healthy")
  equal(state.seaworld.status, "healthy")
  equal(state.persistence.status, "healthy")
  assert(state.uptime_seconds >= 8040)
  local text = Health.message(state)
  assert(text:find("Uptime: 2h 14m", 1, true))
  assert(not text:find("socket", 1, true))
end)

test("health command defers before running checks and edits the final response", function()
  local order, edited = {}, nil
  local app = { health_snapshot = function()
    order[#order + 1] = "health"
    return Health.snapshot({ running = true, runtime = "Lua", discord_connected = true,
      seaworld = { status = "healthy" }, started_at = 10, now = 70 })
  end }
  local commands = CommandRouter.new(Logger.new(function() end))
  SmokeCommands.register(commands, app)
  local context = {
    interaction_id = "1", interaction_token = "fixture",
    bot = { application_id = "2", rest = { create_interaction_response = function()
      order[#order + 1] = "defer"
    end } },
    edit = function(_, text) edited = text; order[#order + 1] = "edit" end,
  }
  assert(commands:dispatch("health", context))
  equal(table.concat(order, ","), "defer,health,edit")
  assert(edited:find("Discord: Healthy", 1, true))
  assert(edited:find("Uptime: 1m", 1, true))
end)

test("health degrades on SeaWorld timeout and contains component exceptions", function()
  local unavailable = App.new({ logger = Logger.new(function() end), seaworld = {
    health = function() return { status = "unavailable", detail = "timeout" } end,
  } })
  unavailable.running, unavailable.started_at, unavailable.discord_connected = true, os.time(), true
  local state = unavailable:health_snapshot()
  equal(state.discord.status, "healthy")
  equal(state.seaworld.status, "unavailable")
  equal(state.persistence.status, "degraded")

  local broken = App.new({ logger = Logger.new(function() end), seaworld = {
    health = function() error("private fixture detail") end,
  } })
  broken.running, broken.started_at, broken.discord_connected = true, os.time(), true
  local ok, snapshot = pcall(broken.health_snapshot, broken)
  assert(ok)
  equal(snapshot.seaworld.status, "unavailable")
  equal(snapshot.persistence.status, "degraded")
  assert(not Health.message(snapshot):find("private fixture", 1, true))
end)

test("Discord bootstrap forwards lifecycle, command routing, and shutdown", function()
  local records, checks = {}, 0
  local logger = Logger.new(function(record) records[#records + 1] = record end)
  local sea_world = {
    get_state = function() return { status = "unavailable", detail = "not_configured" } end,
    check = function()
      checks = checks + 1
      return { status = "unavailable", detail = "not_configured" }
    end,
  }
  local fake_bot = { events = {}, registered = {}, stopped = false }
  function fake_bot:on(name, callback) self.events[name] = callback end
  function fake_bot:slash_command(name, definition) self.registered[name] = definition end
  function fake_bot:run(token) self.started_with = token end
  function fake_bot:stop() self.stopped = true end
  local fake_discord = { Bot = function() return fake_bot end }
  local app = App.new({ logger = logger, seaworld = sea_world })
  local commands = CommandRouter.new(logger)
  SmokeCommands.register(commands, app)
  local bootstrap = DiscordBootstrap.new({
    discord = fake_discord,
    app = app,
    commands = commands,
    logger = logger,
  }):build()
  local started, start_error = pcall(function() bootstrap:start("") end)
  assert(not started)
  assert(start_error:find("discord token is required", 1, true))
  assert(bootstrap:start(string.rep("x", 1)))
  assert(fake_bot.events.ready)
  fake_bot.events.shard_error(0, {}, "module fixture-secret not found")
  assert(records[#records]:find("discord_gateway_error", 1, true))
  assert(not records[#records]:find("fixture-secret", 1, true))
  fake_bot.events.ready()
  equal(checks, 1)
  assert(app.discord_connected)
  local response
  fake_bot.registered.health.callback({
    interaction_id = "1", interaction_token = "fixture",
    bot = { application_id = "2", rest = { create_interaction_response = function() end } },
    edit = function(_, value, options) response = { content = value, options = options } end,
    respond = function(_, value, options) response = { content = value, options = options } end,
  })
  assert(response.options.embeds[1].fields[3].value == "Healthy")
  fake_bot.events.disconnect()
  assert(not app.discord_connected)
  assert(bootstrap:shutdown("SIGTERM"))
  assert(fake_bot.stopped)
  assert(not bootstrap:shutdown("SIGTERM"))
end)

test("Discord client hooks bind during connect before gateway events start", function()
  local order, client_events = {}, {}
  local bot = { events = {} }
  function bot:on(name, callback) self.events[name] = callback end
  function bot:slash_command() end
  function bot:connect()
    self.client = { on = function(_, name, callback) client_events[name] = callback end }
    order[#order + 1] = "connect"
    return self
  end
  function bot:run()
    self:connect()
    order[#order + 1] = "gateway"
  end
  local bootstrap = DiscordBootstrap.new({
    discord = { Bot = function() return bot end },
    app = App.new({ logger = Logger.new(function() end), seaworld = {
      get_state = function() return { status = "unavailable", detail = "not_configured" } end,
      check = function() return { status = "unavailable", detail = "not_configured" } end,
    } }),
    commands = CommandRouter.new(),
    on_client = function(client)
      assert(client == bot.client)
      client:on("guild_create", function() end)
      order[#order + 1] = "hook"
    end,
  }):build()
  assert(bootstrap:start("fixture"))
  equal(table.concat(order, ","), "connect,hook,gateway")
  assert(client_events.guild_create)
end)

test("Discord login failures are contained without token logging", function()
  local records = {}
  local logger = Logger.new(function(record) records[#records + 1] = record end)
  local sea_world = {
    get_state = function() return { status = "unavailable", detail = "not_configured" } end,
    check = function() return { status = "unavailable", detail = "not_configured" } end,
  }
  local fake_bot = { events = {} }
  function fake_bot:on(name, callback) self.events[name] = callback end
  function fake_bot:slash_command() end
  function fake_bot:run() error("client rejected fixture") end
  local app = App.new({ logger = logger, seaworld = sea_world })
  local bootstrap = DiscordBootstrap.new({
    discord = { Bot = function() return fake_bot end },
    app = app,
    commands = CommandRouter.new(logger),
    logger = logger,
  }):build()
  local ok, reason = bootstrap:start(string.rep("x", 1))
  assert(not ok)
  equal(reason, "login_failed")
  assert(not app.running)
  assert(records[#records]:find("discord_login_failed", 1, true))
  assert(not records[#records]:find("fixture", 1, true))
end)

test("Lavalink v4 client reports unavailable and healthy states", function()
  local password = string.rep("x", 1)
  local unavailable_client = LavalinkClient.new({
    url = "http://127.0.0.1:2333",
    password = password,
    transport = function() return nil, "timeout" end,
  })
  equal(unavailable_client:health().status, "unavailable")
  local healthy_client = LavalinkClient.new({
    url = "http://127.0.0.1:2333/",
    password = password,
    transport = function(method, url, options)
      equal(method, "GET")
      equal(url, "http://127.0.0.1:2333/version")
      equal(options.headers.authorization, password)
      return { code = 200 }, "4.2.2"
    end,
  })
  equal(healthy_client:health().status, "connected")
  local unsupported_client = LavalinkClient.new({
    url = "http://127.0.0.1:2333",
    password = password,
    transport = function() return { code = 200 }, "3.7.0" end,
  })
  equal(unsupported_client:health().detail, "unsupported_version")
end)

test("music adapter is provider-neutral and mockable", function()
  local adapter = MusicAdapter.new()
  equal(adapter:status().detail, "not_configured")
  local calls = {}
  local provider = {
    health = function() return { status = "connected", detail = "v4" } end,
    connect = function() calls.connect = true return true, "connected" end,
    disconnect = function() calls.disconnect = true return true, "disconnected" end,
    resolve = function(_, query) calls.query = query return true, { encoded = "track" } end,
    play = function(_, player, track) calls.play = player.guild_id .. track.encoded return true end,
    stop = function(_, player) calls.stop = player.guild_id return true end,
  }
  adapter = MusicAdapter.new({ provider = provider })
  equal(adapter:status().status, "connected")
  assert(adapter:connect())
  local resolved, track = adapter:resolve("search input")
  assert(resolved)
  equal(track.encoded, "track")
  assert(adapter:play({ guild_id = "guild" }, track))
  assert(adapter:stop({ guild_id = "guild" }))
  assert(adapter:disconnect())
  assert(calls.connect and calls.disconnect and calls.query and calls.play and calls.stop)
end)

test("music adapter refuses invalid configuration", function()
  local adapter = MusicAdapter.new({ configuration_errors = { "MOLLY_LAVALINK_PASSWORD" } })
  equal(adapter:status().detail, "invalid_configuration")
  local ok, reason = adapter:connect()
  assert(not ok)
  equal(reason, "invalid_configuration")
end)

test("app health includes checked music state without exposing configuration", function()
  local sea_world = {
    get_state = function() return { status = "unavailable", detail = "not_configured" } end,
    check = function() return { status = "unavailable", detail = "not_configured" } end,
  }
  local music = {
    health = function() return { status = "connected", detail = "v4" } end,
  }
  local app = App.new({ logger = Logger.new(function() end), seaworld = sea_world, music = music })
  app:on_ready()
  local message = app:health_message()
  assert(message:find("Music: connected", 1, true))
  assert(not message:find("http", 1, true))
end)

io.stdout:write(string.format("%d tests, %d failures\n", total, failed))
os.exit(failed == 0 and 0 or 1)
