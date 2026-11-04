local Store = require("src.persistence.guild_store")
local Permissions = require("src.discord.permissions")
local Util = require("src.commands.community_util")

local Commands = {}

local function domain_text(domain)
  return domain == "welcome" and "Welcome" or "Goodbye"
end

local function options_for()
  return {
    { type = 1, name = "show", description = "Show the current greeting configuration" },
    { type = 1, name = "enable", description = "Enable this greeting" },
    { type = 1, name = "disable", description = "Disable this greeting" },
    { type = 1, name = "channel", description = "Set the text channel", options = { Util.option("channel", "Text channel", 7, true) } },
    { type = 1, name = "message", description = "Set the message template", options = { Util.option("value", "Supports {user}, {mention}, {server}, {member_count}", 3, true, 1800) } },
    { type = 1, name = "embed-on", description = "Enable an embed preview" },
    { type = 1, name = "embed-off", description = "Disable the embed" },
    { type = 1, name = "embed-title", description = "Set the embed title", options = { Util.option("value", "Embed title", 3, true, 256) } },
    { type = 1, name = "embed-description", description = "Set the embed description", options = { Util.option("value", "Embed description template", 3, true, 1000) } },
    { type = 1, name = "preview", description = "Preview the message privately" },
  }
end

local function register_one(router, domain, greetings, options)
  router:register({
    name = domain, category = "Administration", description = "Configure " .. domain_text(domain):lower() .. " messages",
    permission = "manage_guild", default_member_permissions = Permissions.flags.manage_guild,
    options = options_for(),
    execute = function(ctx)
      local guild = ctx.guild and ctx.guild.id
      if not Store.valid_id(guild) then ctx:respond("This command requires a server.", { ephemeral = true }); return end
      if not Util.is_manager(ctx) then ctx:respond("You need Manage Server to change greeting settings.", { ephemeral = true }); return end
      if not Util.defer(ctx) then return end
      local action = ctx.molly_subcommand
      local ok, value
      if action == "show" then
        ok, value = options.settings:get_domain(guild, domain)
        if not ok then Util.reply(ctx, "Greeting settings are unavailable."); return end
        Util.reply(ctx, domain_text(domain) .. " is " .. (value.enabled and "enabled" or "disabled")
          .. ". Channel: " .. (value.channel_id ~= "" and ("<#" .. value.channel_id .. ">") or "not set")
          .. ". Embed: " .. (value.embed.enabled and "on" or "off") .. ".")
        return
      elseif action == "preview" then
        local author = ctx.author or {}
        local member = { user = author, nick = ctx.member and ctx.member.nick }
        local guild_name = ctx.guild and ctx.guild.name
        local preview_ok, payload = greetings:preview(guild, domain, member, greetings:count(guild), guild_name)
        if not preview_ok then Util.reply(ctx, "Greeting preview is unavailable."); return end
        if payload.content == "" and not payload.embeds then Util.reply(ctx, "Set a message or enable an embed before previewing."); return end
        ctx:edit(payload.content, { embeds = payload.embeds, allowed_mentions = { parse = {} } })
        return
      elseif action == "enable" or action == "disable" then
        local current_ok, current = options.settings:get_domain(guild, domain)
        if not current_ok then Util.reply(ctx, "Greeting settings are unavailable."); return end
        if action == "enable" and not Store.valid_id(current.channel_id) then
          Util.reply(ctx, "Set a text channel before enabling this greeting."); return
        end
        ok, value = options.settings:update_domain(guild, domain, function(config)
          config.enabled = action == "enable"
          return true
        end)
      elseif action == "channel" then
        local channel = Util.id(Util.arg(ctx, "channel"))
        local valid, reason = Util.validate_text_channel(ctx.bot and ctx.bot.rest, guild, channel)
        if not valid then
          Util.reply(ctx, reason == "wrong_guild" and "Choose a text channel in this server." or "That text channel is unavailable.")
          return
        end
        ok, value = options.settings:update_domain(guild, domain, function(config)
          config.channel_id = channel
          return true
        end)
      elseif action == "message" then
        local template = Util.arg(ctx, "value")
        ok, value = options.settings:update_domain(guild, domain, function(config)
          config.message = template
          return true
        end)
      elseif action == "embed-on" or action == "embed-off" then
        ok, value = options.settings:update_domain(guild, domain, function(config)
          config.embed.enabled = action == "embed-on"
          return true
        end)
      elseif action == "embed-title" then
        local title = Util.arg(ctx, "value")
        ok, value = options.settings:update_domain(guild, domain, function(config)
          config.embed.title = title
          return true
        end)
      elseif action == "embed-description" then
        local description = Util.arg(ctx, "value")
        ok, value = options.settings:update_domain(guild, domain, function(config)
          config.embed.description = description
          return true
        end)
      else
        Util.reply(ctx, "Choose a valid greeting setting action.")
        return
      end
      if not ok then
        Util.reply(ctx, value == "invalid_setting" and "The channel, template, or embed value is invalid."
          or "Greeting settings could not be saved.")
        return
      end
      if options.logs then options.logs:record(guild, "settings", domain_text(domain) .. " settings updated.") end
      if action == "enable" and options.member_events_enabled == false then
        Util.reply(ctx, domain_text(domain) .. " settings saved, but automatic member events require MOLLY_GUILD_MEMBERS_INTENT=true and the Discord privileged intent enabled in the Developer Portal.")
      else
        Util.reply(ctx, domain_text(domain) .. " settings updated.")
      end
    end,
  })
end

function Commands.register(router, settings, greetings, options)
  options = options or {}
  options.settings = settings
  register_one(router, "welcome", greetings, options)
  register_one(router, "goodbye", greetings, options)
end

return Commands
