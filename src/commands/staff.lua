local Permissions = require("src.discord.permissions")
local Hierarchy = require("src.moderation.hierarchy")
local Response = require("src.discord.response")
local Staff = {}
local function opt(name, description, kind, required) return { name = name, description = description, type = kind, required = required } end
local function safe(value) return tostring(value or ""):gsub("@", "@\226\128\139"):gsub("[\r\n]", " "):sub(1, 160) end
function Staff.register(router, directory)
  local function register(name, description, options, fn)
    router:register({ name = name, description = description, category = "Staff / HR", permission = "manage_guild",
      default_member_permissions = Permissions.flags.manage_guild, options = options, execute = function(ctx)
        if not ctx.guild or not ctx.author or not Permissions.has(ctx.member and ctx.member.permissions, "manage_guild") then
          ctx:respond("You do not have permission to use this command.", { ephemeral = true }); return
        end
        if not Response.defer(ctx, { ephemeral = true }) then return end
        local ok, result = pcall(fn, ctx)
        ctx:edit(ok and result or "Molly could not complete the request.")
      end })
  end
  local function detail(ctx, action)
    local user = ctx:get_arg("user")
    if not user then return "Choose a server member." end
    if (action == "add" or action == "remove" or action == "note") and not Hierarchy.check(ctx, user.id) then
      return "Cannot verify the target's role hierarchy."
    end
    local ok, entry = directory:apply(ctx.guild.id, ctx.author.id, user.id, action, ctx:get_arg("note"), ctx.interaction_id)
    if not ok then return "Staff record was not confirmed; check it before retrying." end
    if action == "notes" then
      local lines = {}
      for i = math.max(1, #entry.notes - 9), #entry.notes do
        local note = entry.notes[i]; lines[#lines + 1] = safe(note.author) .. ": " .. safe(note.text)
      end
      return #lines > 0 and table.concat(lines, "\n") or "No notes for this staff member."
    end
    return "Staff directory user " .. safe(entry.id) .. ": " .. (entry.active and "active" or "inactive") ..
      " · notes: " .. tostring(#entry.notes) .. ". Discord roles were not changed."
  end
  local user = opt("user", "Server member", 6, true)
  register("staff", "Manage Molly's staff directory", {
    { type = 1, name = "list", description = "List active staff" },
    { type = 1, name = "add", description = "Add to the directory", options = { user } },
    { type = 1, name = "remove", description = "Mark inactive", options = { user } },
    { type = 1, name = "note", description = "Add a private note", options = { user, opt("note", "Private staff note", 3, true) } },
    { type = 1, name = "notes", description = "Read private notes", options = { user } },
  }, function(ctx)
    local action = ctx.molly_subcommand
    if action ~= "list" then return detail(ctx, action) end
    local ok, entries = directory:list(ctx.guild.id)
    if not ok then return "Staff directory is unavailable." end
    while #entries > 50 do table.remove(entries) end
    return #entries > 0 and ("Active staff IDs: " .. table.concat(entries, ", ")) or "No active staff in the directory."
  end)
  register("staffinfo", "Show a staff directory record", { user }, function(ctx) return detail(ctx, "info") end)
  register("staffstats", "Show the active staff count", nil, function(ctx)
    local ok, entries = directory:list(ctx.guild.id)
    return ok and ("Active staff: " .. tostring(#entries)) or "Staff directory is unavailable."
  end)
end
return Staff
