local Store = require("src.persistence.guild_store")
local Schema = require("src.settings.schema")

local Greetings = {}
Greetings.__index = Greetings

local PLACEHOLDERS = { user = true, mention = true, server = true, member_count = true }

local function safe(value, maximum)
  return tostring(value or ""):gsub("[\r\n]", " "):gsub("[%z\1-\8\11\12\14-\31\127]", " "):sub(1, maximum or 256)
end

local function render(template, values)
  if type(template) ~= "string" then return "" end
  return template:gsub("{([%w_]+)}", function(name)
    if PLACEHOLDERS[name] then return tostring(values[name] or "unknown") end
    return "{" .. name .. "}"
  end)
end

local function member_values(member, server, count)
  local user = type(member) == "table" and member.user or nil
  local id = user and user.id or (type(member) == "table" and member.id)
  local display = type(member) == "table" and member.nick or nil
  display = display or (user and (user.global_name or user.username)) or (type(member) == "table" and member.username)
  return {
    user = safe(display or id or "Member", 100),
    mention = Store.valid_id(id) and ("<@" .. id .. ">") or "Member",
    server = safe(server or "this server", 100),
    member_count = type(count) == "number" and tostring(math.max(0, math.floor(count))) or "unknown",
  }, id
end

function Greetings.new(settings, options)
  options = options or {}
  assert(type(settings) == "table" and type(settings.get_domain) == "function", "guild settings are required")
  local self = setmetatable({ settings = settings, rest = options.rest, send = options.send, logger = options.logger,
    guild_names = {}, counts = {}, max_guilds = options.max_guilds or 500 }, Greetings)
  if options.rest then self:set_runtime(options.rest) end
  return self
end

function Greetings:set_runtime(rest, client)
  self.rest, self.client = rest, client
  self.send = rest and type(rest.send_message) == "function"
    and function(channel, payload) return rest:send_message(channel, payload) end or nil
end

function Greetings:set_guild(guild_id, name, count)
  if not Store.valid_id(guild_id) then return false end
  local size = 0
  for _ in pairs(self.guild_names) do size = size + 1 end
  if not self.guild_names[guild_id] and size >= self.max_guilds then
    local oldest
    for id in pairs(self.guild_names) do oldest = id; break end
    if oldest then self.guild_names[oldest], self.counts[oldest] = nil, nil end
  end
  if type(name) == "string" then self.guild_names[guild_id] = safe(name, 100) end
  if type(count) == "number" and count >= 0 then self.counts[guild_id] = math.floor(count) end
  return true
end

function Greetings:member_joined(guild_id)
  if self.counts[guild_id] then self.counts[guild_id] = self.counts[guild_id] + 1 end
  return self.counts[guild_id]
end

function Greetings:member_left(guild_id)
  if self.counts[guild_id] then self.counts[guild_id] = math.max(0, self.counts[guild_id] - 1) end
  return self.counts[guild_id]
end

function Greetings:count(guild_id)
  return self.counts[guild_id]
end

function Greetings:_server_name(guild_id)
  if self.guild_names[guild_id] then return self.guild_names[guild_id] end
  if self.rest and type(self.rest.get_guild) == "function" then
    local ok, guild = pcall(self.rest.get_guild, self.rest, guild_id)
    if ok and type(guild) == "table" and type(guild.name) == "string" then
      self:set_guild(guild_id, guild.name, guild.member_count)
      return self.guild_names[guild_id]
    end
  end
  return "this server"
end

function Greetings:_payload(domain, config, guild_id, member, count, server_name)
  local values, user_id = member_values(member, server_name or self:_server_name(guild_id), count or self:count(guild_id))
  local content = render(config.message, values)
  local payload = { content = content, allowed_mentions = { parse = {} } }
  if Store.valid_id(user_id) then payload.allowed_mentions.users = { user_id } end
  if config.embed and config.embed.enabled then
    local default_title = domain == "welcome" and "Welcome" or "Goodbye"
    local title = config.embed.title ~= "" and render(config.embed.title, values) or default_title
    local description = config.embed.description ~= "" and render(config.embed.description, values) or content
    payload.embeds = { { title = safe(title, 256), description = safe(description, 4000), color = 0xD46AA6 } }
    if content == "" then payload.content = nil end
  end
  return payload
end

function Greetings:preview(guild_id, domain, member, count, server_name)
  if not Store.valid_id(guild_id) or (domain ~= "welcome" and domain ~= "goodbye") then return false, "invalid_argument" end
  local ok, config = self.settings:get_domain(guild_id, domain)
  if not ok then return false, config end
  return true, self:_payload(domain, config, guild_id, member, count, server_name), config
end

function Greetings:send_event(guild_id, domain, member, count)
  if not Store.valid_id(guild_id) or (domain ~= "welcome" and domain ~= "goodbye") then return false, "invalid_argument" end
  local ok, config = self.settings:get_domain(guild_id, domain)
  if not ok then return false, config end
  if not config.enabled or not Store.valid_id(config.channel_id) then return true, "disabled" end
  if not Schema.valid_id(config.channel_id) then return false, "invalid_store" end
  local payload = self:_payload(domain, config, guild_id, member, count)
  if (type(payload.content) ~= "string" or payload.content == "")
    and (type(payload.embeds) ~= "table" or #payload.embeds == 0) then
    return false, "empty_message"
  end
  if not self.send then return false, "discord_unavailable" end
  local called, response = pcall(self.send, config.channel_id, payload)
  if not called or response == false then
    if self.logger then self.logger:warn("greeting_delivery_failed", { domain = domain, detail = "discord_unavailable" }) end
    return false, "delivery_failed"
  end
  return true, "sent"
end

Greetings.render = render
return Greetings
