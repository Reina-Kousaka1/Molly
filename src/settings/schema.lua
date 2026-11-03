local Schema = {}

local function valid_id(value, allow_empty)
  return (allow_empty and value == "") or (type(value) == "string" and #value <= 20 and value:match("^%d+$") ~= nil)
end

local function deep_copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = deep_copy(child) end
  return result
end

local function valid_template(value, maximum)
  if type(value) ~= "string" or #value > maximum or value:find("%z") then return false end
  for token in value:gmatch("{([^{}]+)}") do
    if token ~= "user" and token ~= "mention" and token ~= "server" and token ~= "member_count" then return false end
  end
  return true
end

local log_events = {
  member_join = true, member_leave = true, moderation = true, ban = true,
  unban = true, roles = true, settings = true,
}

Schema.defaults = {
  guild = {},
  welcome = {
    enabled = false, channel_id = "", message = "Welcome {mention} to {server}!",
    embed = { enabled = false, title = "", description = "" },
  },
  goodbye = {
    enabled = false, channel_id = "", message = "Goodbye {user} — thanks for being part of {server}.",
    embed = { enabled = false, title = "", description = "" },
  },
  logs = {
    enabled = false, channel_id = "",
    events = { member_join = true, member_leave = true, moderation = true, ban = true,
      unban = true, roles = true, settings = true },
  },
  roles = { self_assignable = {} },
  starboard = {
    enabled = false, channel_id = "", emoji = "⭐", threshold = 3,
    ignored_channels = {},
  },
  content = { mature_enabled = false },
  shop = { enabled = true },
  sephora = { enabled = false },
}

Schema.log_events = log_events

function Schema.copy(value)
  return deep_copy(value)
end

function Schema.normalize(name, saved)
  local defaults = Schema.defaults[name]
  if not defaults then return nil, "invalid_domain" end
  if saved ~= nil and type(saved) ~= "table" then return nil, "invalid_store" end
  local result = deep_copy(saved or {})
  for key, default_value in pairs(defaults) do
    if result[key] == nil then
      result[key] = deep_copy(default_value)
    elseif type(default_value) == "table" and type(result[key]) == "table" then
      for child_key, child_default in pairs(default_value) do
        if result[key][child_key] == nil then result[key][child_key] = deep_copy(child_default) end
      end
    end
  end

  if name == "welcome" or name == "goodbye" then
    if type(result.enabled) ~= "boolean" or not valid_id(result.channel_id, true)
      or not valid_template(result.message, 1800) or type(result.embed) ~= "table"
      or type(result.embed.enabled) ~= "boolean" or type(result.embed.title) ~= "string"
      or #result.embed.title > 256 or not valid_template(result.embed.description, 4000) then
      return nil, "invalid_setting"
    end
  elseif name == "logs" then
    if type(result.enabled) ~= "boolean" or not valid_id(result.channel_id, true) or type(result.events) ~= "table" then
      return nil, "invalid_setting"
    end
    for event in pairs(log_events) do
      if type(result.events[event]) ~= "boolean" then return nil, "invalid_setting" end
    end
  elseif name == "roles" then
    if type(result.self_assignable) ~= "table" or #result.self_assignable > 100 then return nil, "invalid_setting" end
    local seen = {}
    for _, id in ipairs(result.self_assignable) do
      if not valid_id(id, false) or seen[id] then return nil, "invalid_setting" end
      seen[id] = true
    end
  elseif name == "starboard" then
    if type(result.enabled) ~= "boolean" or not valid_id(result.channel_id, true)
      or type(result.emoji) ~= "string" or #result.emoji < 1 or #result.emoji > 80
      or result.emoji:find("[%c%s]") or type(result.threshold) ~= "number"
      or result.threshold % 1 ~= 0 or result.threshold < 1 or result.threshold > 100
      or type(result.ignored_channels) ~= "table"
      or #result.ignored_channels > 100 then return nil, "invalid_setting" end
    local seen = {}
    for _, id in ipairs(result.ignored_channels) do
      if not valid_id(id, false) or seen[id] then return nil, "invalid_setting" end
      seen[id] = true
    end
  elseif name == "content" then
    if type(result.mature_enabled) ~= "boolean" then return nil, "invalid_setting" end
  elseif name == "shop" then
    if type(result.enabled) ~= "boolean" then return nil, "invalid_setting" end
  elseif name == "sephora" then
    if type(result.enabled) ~= "boolean" then return nil, "invalid_setting" end
  elseif name == "guild" then
    if type(result) ~= "table" then return nil, "invalid_setting" end
  end

  return result
end

function Schema.valid_template(value, maximum)
  return valid_template(value, maximum or 1800)
end

function Schema.valid_id(value, allow_empty)
  return valid_id(value, allow_empty)
end

return Schema
