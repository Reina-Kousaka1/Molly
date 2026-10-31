local Permissions = require("src.discord.permissions")
local Response = require("src.discord.response")
local VoiceCommands = {}

local function arg(ctx, key) return ctx:get_arg(key) end
local function option(name, description, kind, required, extra)
  local item = { name = name, description = description, type = kind, required = required }
  for key, value in pairs(extra or {}) do item[key] = value end
  return item
end

function VoiceCommands.register(router, dynamic)
  router:register({
    name = "voice", description = "Configure Join-to-Create and temporary voice rooms",
    category = "Administration",
    options = {
      { type = 1, name = "setup", description = "Set the Join-to-Create voice channel", options = {
        option("channel", "Voice channel users join to create a room", 7, true, { channel_types = { 2 } }),
      } },
      { type = 1, name = "disable", description = "Disable Join-to-Create" },
      { type = 1, name = "status", description = "Show Join-to-Create status" },
      { type = 1, name = "rename", description = "Rename your temporary voice room", options = {
        option("name", "New channel name", 3, true, { min_length = 1, max_length = 90 }),
      } },
      { type = 1, name = "lock", description = "Stop new members joining your room" },
      { type = 1, name = "unlock", description = "Allow members to join your room" },
      { type = 1, name = "limit", description = "Set your room user limit (0 means unlimited)", options = {
        option("users", "Maximum users", 4, true, { min_value = 0, max_value = 99 }),
      } },
      { type = 1, name = "permit", description = "Allow a user into your locked room", options = {
        option("user", "User to permit", 6, true),
      } },
      { type = 1, name = "reject", description = "Stop a user joining your room", options = {
        option("user", "User to reject", 6, true),
      } },
      { type = 1, name = "transfer", description = "Transfer room ownership to a current member", options = {
        option("user", "New owner", 6, true),
      } },
    },
    execute = function(ctx)
      if not ctx.guild then ctx:respond("This command only works in a server.", { ephemeral = true }); return end
      local action = ctx.molly_subcommand
      local admin = Permissions.has(ctx.member and ctx.member.permissions, "manage_guild")
      if (action == "setup" or action == "disable" or action == "status") and not admin then
        ctx:respond("You need Manage Server to configure Join-to-Create.", { ephemeral = true }); return
      end
      if action == "status" then
        local config, reason = dynamic:status(ctx.guild.id)
        ctx:respond(not config and (reason or "Voice configuration is unavailable.") or
          (config.trigger_channel_id and ("Join-to-Create: <#" .. config.trigger_channel_id .. ">") or "Join-to-Create is not configured."), { ephemeral = true })
        return
      end
      -- Voice room controls are owner/admin scoped; keep their acknowledgements
      -- private while ordinary information and music responses remain public.
      if not Response.defer(ctx, { ephemeral = true }) then return end
      if action == "setup" then
        local channel = arg(ctx, "channel")
        local ok, reason = dynamic:configure(ctx.guild.id, type(channel) == "table" and channel.id or nil)
        local errors = {
          trigger_category_missing = "Place the Join-to-Create voice channel inside a voice category, then run setup again.",
          trigger_category_invalid = "The Join-to-Create channel's parent is not a valid voice category.",
          trigger_unavailable = "Molly could not access the selected Join-to-Create channel.",
          trigger_invalid = "Select a voice channel in this server.",
          discord_unavailable = "Discord is unavailable; try configuring Join-to-Create again shortly.",
          persistence_unavailable = "The voice configuration could not be saved.",
        }
        ctx:edit(ok and "Join-to-Create is configured. New rooms will appear under the same category." or
          (errors[reason] or "Could not save the voice configuration."))
        return
      elseif action == "disable" then
        local ok = dynamic:disable(ctx.guild.id)
        ctx:edit(ok and "Join-to-Create is disabled." or "Could not save the voice configuration.")
        return
      end
      local channel_id = ctx.bot:get_voice_channel_id(ctx.guild.id, ctx.author.id)
      local value
      if action == "rename" then value = arg(ctx, "name")
      elseif action == "limit" then value = arg(ctx, "users")
      elseif action == "permit" or action == "reject" or action == "transfer" then
        local user = arg(ctx, "user"); value = type(user) == "table" and user.id or nil
      end
      local ok, result = dynamic:owner_action(ctx.guild.id, channel_id, ctx.author.id, action, value, admin)
      local messages = {
        rename = "Your room has a new name. Try not to get attached. ✨", lock = "Room locked.", unlock = "Room unlocked.",
        limit = "Room limit updated.", permit = "User permitted.", reject = "User rejected.", transfer = "Room ownership transferred.",
      }
      local errors = {
        permission_denied = "Only the room owner or a server manager can do that.",
        not_temporary = "You must be in one of Molly's temporary rooms.",
        target_not_in_channel = "The new owner must already be in this room.",
      }
      ctx:edit(ok and (messages[action] or "Done.") or (errors[result] or "Molly could not update that voice room."))
    end,
  })
end

return VoiceCommands
