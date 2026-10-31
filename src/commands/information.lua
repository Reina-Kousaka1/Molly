local Permissions = require("src.discord.permissions")
local Store = require("src.persistence.guild_store")
local Response = require("src.discord.response")
local Information = {}

local function safe(value)
  return tostring(value or "unknown"):gsub("@", "@\226\128\139"):sub(1, 200)
end
local function guild(ctx) return ctx.guild and ctx.guild.id end
local function arg(ctx, name) return type(ctx.get_arg) == "function" and ctx:get_arg(name) or nil end
local function respond(ctx, text) ctx:respond(text) end
local function user_option() return { name = "user", description = "The user to inspect", type = 6, required = false } end

function Information.register(router, app)
  local function register(name, description, execute, options, category)
    router:register({ name = name, description = description, execute = execute, options = options, category = category or "Information" })
  end
  register("uptime", "Show how long Molly has been running", function(ctx)
    local seconds = math.max(0, os.time() - (app.started_at or os.time()))
    respond(ctx, string.format("Uptime: %dd %dh %dm", math.floor(seconds / 86400), math.floor(seconds / 3600) % 24, math.floor(seconds / 60) % 60))
  end, nil, "Utility")
  register("botinfo", "Show Molly information", function(ctx)
    respond(ctx, "Molly · Discord management bot\n" .. app:health_message())
  end)
  register("serverinfo", "Show information about this server", function(ctx)
    if not Store.valid_id(guild(ctx)) then respond(ctx, "This command requires a server."); return end
    if not Response.defer(ctx) then return end
    local ok, server = pcall(ctx.bot.rest.get_guild, ctx.bot.rest, guild(ctx))
    if not ok or type(server) ~= "table" then ctx:edit("Server information is unavailable."); return end
    ctx:edit("Server: " .. safe(server.name) .. "\nID: " .. safe(server.id) .. "\nOwner ID: " .. safe(server.owner_id))
  end)
  register("membercount", "Show the server's approximate member count", function(ctx)
    if not Store.valid_id(guild(ctx)) then respond(ctx, "This command requires a server."); return end
    if not Response.defer(ctx) then return end
    if not ctx.bot.http then ctx:edit("Member count is unavailable."); return end
    local ok, server = pcall(ctx.bot.http.get, ctx.bot.http, "/guilds/" .. guild(ctx) .. "?with_counts=true")
    local count = ok and type(server) == "table" and server.approximate_member_count
    ctx:edit(type(count) == "number" and ("Approximate members: " .. tostring(count)) or "Member count is unavailable.")
  end)
  register("userinfo", "Show information about a user", function(ctx)
    local selected = arg(ctx, "user") or ctx.author or {}
    respond(ctx, "User: " .. safe(selected.global_name or selected.username) .. "\nID: " .. safe(selected.id))
  end, { user_option() })
  register("avatar", "Show a user's avatar URL", function(ctx)
    local selected = arg(ctx, "user") or ctx.author or {}
    local raw = ctx.resolved and ctx.resolved.users and ctx.resolved.users[selected.id] or selected
    if type(raw.id) ~= "string" or not raw.id:match("^%d+$") or type(raw.avatar) ~= "string" or not raw.avatar:match("^[%w_]+$") then
      respond(ctx, "No custom avatar is available in this interaction.")
      return
    end
    respond(ctx, "https://cdn.discordapp.com/avatars/" .. raw.id .. "/" .. raw.avatar .. ".png")
  end, { user_option() })
  register("channelinfo", "Show information about this channel", function(ctx)
    local channel = ctx.channel or {}
    respond(ctx, "Channel: " .. safe(channel.name) .. "\nID: " .. safe(channel.id) .. "\nType: " .. safe(channel.type))
  end)
  register("roleinfo", "Show an available role", function(ctx)
    local role = arg(ctx, "role") or {}
    respond(ctx, "Role: " .. safe(role.name) .. "\nID: " .. safe(role.id))
  end, { { name = "role", description = "The role to inspect", type = 8, required = true } })
  register("roles", "List your server role IDs", function(ctx)
    if not guild(ctx) or not ctx.member then respond(ctx, "This command requires a server member."); return end
    local ids = {}
    for _, id in ipairs(ctx.member.roles or {}) do
      if type(id) == "string" and id:match("^%d+$") then ids[#ids + 1] = id end
      if #ids >= 50 then break end
    end
    respond(ctx, #ids > 0 and ("Your role IDs: " .. table.concat(ids, ", ")) or "No additional roles.")
  end)
  register("permissions", "Show selected effective permissions", function(ctx)
    local value = ctx.member and ctx.member.permissions
    if type(value) ~= "string" then respond(ctx, "Your effective permissions are unavailable."); return end
    local names = {}
    for _, name in ipairs({ "administrator", "manage_guild", "manage_roles", "manage_messages", "kick_members", "ban_members", "moderate_members" }) do
      if Permissions.has(value, name) then names[#names + 1] = name end
    end
    respond(ctx, #names > 0 and ("Selected permissions: " .. table.concat(names, ", ")) or "No selected moderation permissions.")
  end)
  register("help", "List available Molly commands", function(ctx)
    local groups, order = {}, { "Moderation", "Staff / HR", "Economy", "Bank", "Information", "Utility", "Music", "Administration" }
    for _, definition in ipairs(router:list()) do
      local category = definition.category or "Utility"
      if not definition.permission or Permissions.has(ctx.member and ctx.member.permissions, definition.permission) then
        groups[category] = groups[category] or {}
        groups[category][#groups[category] + 1] = "/" .. definition.name
      end
    end
    local lines = {}
    for _, category in ipairs(order) do
      if groups[category] then lines[#lines + 1] = category .. ": " .. table.concat(groups[category], ", ") end
    end
    respond(ctx, table.concat(lines, "\n"))
  end, nil, "Utility")
end

return Information
