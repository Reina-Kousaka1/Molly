-- Keep the production registration sequence in one place so startup and
-- registration validation exercise exactly the same command set.
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
local SettingsCommands = require("src.commands.settings")
local PermissionCommands = require("src.commands.permissions")
local AFKCommands = require("src.commands.afk")
local GreetingCommands = require("src.commands.greetings")
local ActionLogCommands = require("src.commands.action_logs")
local SelfRoleCommands = require("src.commands.self_roles")
local StarboardCommands = require("src.commands.starboard")
local Cases = require("src.moderation.cases")
local StaffDirectory = require("src.staff.directory")

local RegisterAll = {}

function RegisterAll.register(router, d)
  SmokeCommands.register(router, d.app, { clock = d.clock })
  InformationCommands.register(router, d.app)
  EconomyCommands.register(router, d.ledger, { logger = d.logger, settings = d.guild_settings })
  ShopCommands.register(router, d.shop, d.guild_settings)
  InventoryCommands.register(router, d.inventory)
  MiningCommands.register(router, d.mining)
  FashionCommands.register(router, d.fashion)
  ModeCommands.register(router, d.modes, { logs = d.action_log, guild_status = d.guild_status })
  SephoraCommands.register(router, d.modes, d.sephora)
  ContentCommands.register(router, d.guild_settings, d.content_policy, { logs = d.action_log })
  UserSettingsCommands.register(router, d.user_settings)
  ModerationCommands.register(router, Cases.new(d.store), { logs = d.action_log })
  StaffCommands.register(router, StaffDirectory.new(d.store))
  MusicCommands.register(router, d.music_manager)
  MusicPanelCommands.register(router, d.music_panel)
  VoiceCommands.register(router, d.dynamic_voice)
  AdminCommands.register(router, {
    owners = d.developers, blacklist = d.blacklist, developer = d.developer,
    lifecycle = d.lifecycle, updater = d.updater, terminate = d.terminate,
  })
  SettingsCommands.register(router, d.guild_settings, { on_prefix_changed = d.on_prefix_changed })
  PermissionCommands.register(router, d.permission_engine)
  AFKCommands.register(router, d.afk)
  GreetingCommands.register(router, d.guild_settings, d.greetings, {
    logs = d.action_log, member_events_enabled = d.member_events_enabled,
  })
  ActionLogCommands.register(router, d.guild_settings, d.action_log)
  SelfRoleCommands.register(router, d.self_roles, { logs = d.action_log })
  StarboardCommands.register(router, d.guild_settings, { logs = d.action_log })
  return router
end

return RegisterAll
