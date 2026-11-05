local Embeds = {}

Embeds.colors = {
  success = 0xF48FB1,
  error = 0xD85A8B,
  warning = 0xE7A2B5,
  info = 0xF8BBD0,
  moderation = 0xEC86AD,
  economy = 0xF4A6C5,
  music = 0xF062A6,
  voice = 0xF6A5CA,
  system = 0xFADADD,
}

local category_kind = {
  ["Moderation"] = "moderation", ["Economy"] = "economy", ["Bank"] = "economy",
  ["Music"] = "music", ["Staff / HR"] = "moderation", ["Administration"] = "voice",
  ["Information"] = "info", ["Utility"] = "info",
}

local titles = {
  ping = "Pong", health = "Molly Health", about = "About Molly", uptime = "Uptime",
  botinfo = "Molly · Bot Information", serverinfo = "Server Information", membercount = "Member Count",
  userinfo = "User Information", avatar = "Avatar", channelinfo = "Channel Information",
  roleinfo = "Role Information", roles = "Your Roles", permissions = "Permissions", help = "Molly Help",
  ["music-panel"] = "Music Controls", voice = "Voice Rooms",
}

local function truncate(value, limit, suffix)
  value = tostring(value or "")
  if #value <= limit then return value end
  suffix = suffix or "…"
  return value:sub(1, math.max(0, limit - #suffix)) .. suffix
end

local function text_kind(value)
  local lower = tostring(value or ""):lower()
  if lower:find("degraded", 1, true) or lower:find("temporarily", 1, true)
    or lower:find("not configured", 1, true) then return "warning" end
  if lower:find("permission", 1, true) or lower:find("denied", 1, true)
    or lower:find("could not", 1, true) or lower:find("couldn't", 1, true)
    or lower:find("failed", 1, true) or lower:find("invalid", 1, true)
    or lower:find("unavailable", 1, true) or lower:find("insufficient", 1, true) then
    return "error"
  end
  if lower:match("^done[%p%s]") or lower:match("^added[%s]") or lower:match("^now playing[%s]")
    or lower:match("^starting[%s]") or lower:match("^playback paused[%p%s]")
    or lower:match("^playback resumed[%p%s]") or lower:match("^skipped[%p%s]")
    or lower:match("^disconnected[%p%s]") or lower:match("^volume set[%s]")
    or lower:match("^room locked[%p%s]") or lower:match("^room unlocked[%p%s]") then
    return "success"
  end
  return nil
end

local function make(kind, title, description, options)
  options = options or {}
  local color = Embeds.colors[kind] or Embeds.colors.info
  local embed = {
    author = { name = "KiddyyMolly 🎀" },
    title = truncate(title or "KiddyyMolly", 256),
    color = color,
    footer = { text = "KiddyyMolly • Pink dreams & server safety 💗" },
  }
  if type(description) == "string" and description ~= "" then
    embed.description = truncate(description, 4096, "…")
  end
  if options.url and type(options.url) == "string" and options.url:match("^https://") then
    embed.url = options.url:sub(1, 2048)
  end
  if options.thumbnail and type(options.thumbnail) == "string" and options.thumbnail:match("^https://") then
    embed.thumbnail = { url = options.thumbnail:sub(1, 2048) }
  end
  local remaining = 5900 - #embed.title - #embed.footer.text - #embed.author.name - #(embed.description or "")
  if type(options.fields) == "table" then
    embed.fields = {}
    for _, field in ipairs(options.fields) do
      if #embed.fields >= 25 or remaining <= 2 then break end
      local name = truncate(field.name or "Details", 256)
      local value = tostring(field.value or "—")
      local allowance = math.min(1024, remaining - #name - 2)
      if allowance > 0 then
        value = truncate(value, allowance)
        embed.fields[#embed.fields + 1] = { name = name, value = value, inline = field.inline == true }
        remaining = remaining - #name - #value
      end
    end
  end
  return embed
end

function Embeds.create(kind, title, description, options)
  return make(kind, title, description, options)
end

local function split_text(value)
  local maximum = 5500
  if #value > maximum then
    local suffix = "\n… output shortened to fit Discord's embed limits."
    value = value:sub(1, maximum - #suffix) .. suffix
  end
  local chunks, rest = {}, value
  while #rest > 4096 do
    local cut = rest:sub(1, 4096):match("^.*()\n")
    if not cut or cut < 1024 then cut = 4096 end
    chunks[#chunks + 1] = rest:sub(1, cut)
    rest = rest:sub(cut + 1)
  end
  chunks[#chunks + 1] = rest
  return chunks
end

function Embeds.for_command(category, command, value)
  local kind = category_kind[category] or "info"
  local override = text_kind(value)
  if override then kind = override end
  local title = titles[command] or ("/" .. tostring(command or "command"))

  if command == "health" and type(value) == "string" then
    local lines, fields, first = {}, {}, nil
    for line in (value .. "\n"):gmatch("([^\n]*)\n") do
      if line ~= "" then
        if not first then first = line
        else
          local name, field_value = line:match("^([^:]+):%s*(.*)$")
          if name and #fields < 25 then fields[#fields + 1] = { name = name, value = field_value, inline = true }
          else lines[#lines + 1] = line end
        end
      end
    end
    title = first or title
    return { make(kind == "info" and "system" or kind, title, #lines > 0 and table.concat(lines, "\n") or nil, { fields = fields }) }
  end

  local chunks = split_text(tostring(value or ""))
  local result = {}
  for index, chunk in ipairs(chunks) do
    result[#result + 1] = make(kind, index == 1 and title or (title .. " · Continued"), chunk)
  end
  return result
end

return Embeds
