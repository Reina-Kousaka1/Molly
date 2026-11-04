local EventRouter = require("src.events.router")
local SafeSync = require("src.discord.safe_sync")
local Response = require("src.discord.response")

local Bootstrap = {}
Bootstrap.__index = Bootstrap

local function default_spawn(task)
  coroutine.wrap(task)()
end

function Bootstrap.new(options)
  assert(type(options) == "table", "options are required")
  assert(options.discord, "discord library is required")
  assert(options.app, "app is required")
  assert(options.commands, "command router is required")

  return setmetatable({
    discord = options.discord,
    intents = options.intents,
    app = options.app,
    commands = options.commands,
    logger = options.logger,
    presence = options.presence,
    on_client = options.on_client,
    allow_permissions_options_migration = options.allow_permissions_options_migration == true,
    spawn = options.spawn or default_spawn,
    events = EventRouter.new(options.logger),
    bot = nil,
  }, Bootstrap)
end

function Bootstrap:build()
  self.bot = self.discord.Bot(self.intents)
  if type(self.on_client) == "function" and type(self.bot.connect) == "function" then
    local connect = self.bot.connect
    self.bot.connect = function(bot, ...)
      local result = connect(bot, ...)
      self.on_client(bot.client, bot)
      return result
    end
  end
  if self.bot.command_tree then
    local logger = self.logger
    self.bot.sync_commands = function(bot)
      local call_ok, synced, outcome, details = pcall(SafeSync.run, bot, {
        allow_permissions_options_migration = self.allow_permissions_options_migration,
      })
      if not call_ok or not synced then
        self.sync_ok = false
        if logger then
          details = type(details) == "table" and details or {}
          logger:error("discord_command_sync_failed", {
            detail = call_ok and outcome or "request_failed",
            command = details.command,
            field = details.field,
          })
        end
        return false
      end
      self.sync_ok = true
      if logger then
        outcome = type(outcome) == "table" and outcome or {}
        logger:info("discord_command_sync_succeeded", {
          registered = #bot.command_tree.commands,
          updated_descriptions = outcome.updated or 0,
          created = outcome.created or 0,
        })
      end
      return true
    end
  end
  if type(self.bot.get_application_context) == "function" then
    local original = self.bot.get_application_context
    self.bot.get_application_context = function(bot, interaction, ...)
      local context = original(bot, interaction, ...)
      context.member = interaction.member
      context.app_permissions = interaction.app_permissions
      context.resolved = interaction.data and interaction.data.resolved or {}
      local first = interaction.data and interaction.data.options and interaction.data.options[1]
      if first and first.type == 1 then
        context.molly_subcommand = first.name
      elseif first and first.type == 2 then
        context.molly_subcommand = first.name
        local nested = first.options and first.options[1]
        if nested and nested.type == 1 then context.molly_subcommand_action = nested.name end
      end
      return context
    end
  end
  self.events:on("ready", function()
    if self.presence then self.presence:start() end
    self.spawn(function() self.app:on_ready() end)
  end)
  self.events:on("disconnect", function() self.app:on_disconnect() end)
  self.events:on("reconnect", function() self.app:on_reconnect() end)
  self.events:on("error", function()
    if self.logger then
      self.logger:error("discord_client_error", { detail = "client_error" })
    end
  end)
  self.events:on("shard_error", function(_, _, failure)
    if self.logger then
      local message = type(failure) == "string" and failure:lower() or ""
      local detail = "gateway_error"
      if message:find("module", 1, true) and message:find("not found", 1, true) then detail = "dependency_unavailable"
      elseif message:find("certificate", 1, true) or message:find("tls", 1, true) then detail = "tls_error"
      elseif message:find("timeout", 1, true) then detail = "timeout" end
      self.logger:error("discord_gateway_error", { detail = detail })
    end
  end)
  self.events:on("application_command_error", function()
    if self.logger then self.logger:error("discord_application_command_failed", { detail = "handler_error" }) end
  end)

  for _, event_name in ipairs({ "ready", "disconnect", "reconnect", "error", "shard_error", "application_command_error" }) do
    self.bot:on(event_name, function(...)
      self.events:dispatch(event_name, ...)
    end)
  end

  for _, definition in ipairs(self.commands:list("slash")) do
    self.bot:slash_command(definition.name, {
      description = definition.description,
      options = definition.options,
      default_member_permissions = definition.default_member_permissions,
      callback = function(context)
        context._molly_command_name = definition.name
        context._molly_category = definition.category
        Response.decorate(context)
        if self.sync_ok == false then
          context:respond("Commands are temporarily unavailable due to a registration conflict.", { ephemeral = true })
          return
        end
        self.commands:dispatch(definition.name, context)
      end,
    })
  end
  return self
end

function Bootstrap:start(token)
  assert(type(token) == "string" and token ~= "", "discord token is required")
  assert(self.bot, "build must be called before start")
  self.app:start()
  local ok = pcall(self.bot.run, self.bot, token)
  if not ok then
    self.app:shutdown("discord_login_failed")
    if self.logger then
      self.logger:error("discord_login_failed", { detail = "client_error" })
    end
    return false, "login_failed"
  end
  return true
end

function Bootstrap:shutdown(signal)
  if not self.app:shutdown(signal) then
    return false
  end
  if self.presence then self.presence:stop() end
  if type(self.bot.stop) == "function" then
    self.bot:stop()
  elseif type(self.bot.close) == "function" then
    self.bot:close()
  elseif self.bot.client and type(self.bot.client.stop_gateway) == "function" then
    self.bot.client:stop_gateway()
  end
  return true
end

return Bootstrap
