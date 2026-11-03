local Store = require("src.persistence.guild_store")

local Events = {}
Events.__index = Events

local function snowflake(value)
  if Store.valid_id(value) then return value end
  if type(value) == "table" and Store.valid_id(value.id) then return value.id end
  return nil
end

local function safe(value, maximum)
  return tostring(value or ""):gsub("@", "@\226\128\139"):gsub("[\r\n]", " ")
    :gsub("[%z\1-\8\11\12\14-\31\127]", " "):sub(1, maximum or 120)
end

function Events.new(options)
  options = options or {}
  return setmetatable({ greetings = options.greetings, afk = options.afk, logs = options.logs,
    starboard = options.starboard, logger = options.logger, bound = false }, Events)
end

function Events:_run(name, callback, ...)
  local args = { n = select("#", ...), ... }
  local ok = pcall(function() callback(unpack(args, 1, args.n)) end)
  if not ok and self.logger then self.logger:warn("community_event_failed", { event = name, detail = "handler_error" }) end
  return ok
end

function Events:_bind(client, event, callback)
  if type(client.on) ~= "function" then return false end
  local ok = pcall(client.on, client, event, function(...)
    self:_run(event, callback, ...)
  end)
  return ok
end

function Events:_configure(client, bot)
  local rest = client and client.rest or (bot and bot.rest)
  if self.greetings then self.greetings:set_runtime(rest, client) end
  if self.logs and rest then self.logs:set_sender(function(channel, payload) return rest:send_message(channel, payload) end) end
  if self.afk and rest then self.afk.send = function(channel, payload) return rest:send_message(channel, payload) end end
  if self.starboard then self.starboard:set_runtime(rest, bot and bot.user and bot.user.id or client and client.user and client.user.id) end
end

function Events:bind(client, bot)
  if self.bound then return true end
  if type(client) ~= "table" or type(client.on) ~= "function" then return false, "client_events_unavailable" end
  self:_configure(client, bot)
  if bot and type(bot.on) == "function" then
    pcall(bot.on, bot, "ready", function() self:_configure(client, bot) end)
  end

  self:_bind(client, "guild_create", function(guild)
    if type(guild) == "table" and self.greetings then self.greetings:set_guild(guild.id, guild.name, guild.member_count) end
  end)
  self:_bind(client, "guild_member_add", function(member)
    local guild_id = type(member) == "table" and snowflake(member.guild_id)
    if not guild_id then return end
    local count = self.greetings and self.greetings:member_joined(guild_id)
    if self.greetings then self.greetings:send_event(guild_id, "welcome", member, count) end
    if self.logs then self.logs:record(guild_id, "member_join", "Member joined: " .. safe(member.user and member.user.id, 24)) end
  end)
  self:_bind(client, "guild_member_remove", function(member)
    local guild_id = type(member) == "table" and snowflake(member.guild_id)
    if not guild_id then return end
    local count = self.greetings and self.greetings:member_left(guild_id)
    if self.greetings then self.greetings:send_event(guild_id, "goodbye", member, count) end
    if self.logs then self.logs:record(guild_id, "member_leave", "Member left: " .. safe(member.user and member.user.id, 24)) end
  end)
  self:_bind(client, "guild_ban_add", function(ban)
    local guild_id = type(ban) == "table" and snowflake(ban.guild_id)
    if guild_id and self.logs then self.logs:record(guild_id, "ban", "Ban added for user " .. safe(ban.user and ban.user.id, 24)) end
  end)
  self:_bind(client, "guild_ban_remove", function(ban)
    local guild_id = type(ban) == "table" and snowflake(ban.guild_id)
    if guild_id and self.logs then self.logs:record(guild_id, "unban", "Ban removed for user " .. safe(ban.user and ban.user.id, 24)) end
  end)
  self:_bind(client, "guild_role_create", function(data)
    local guild_id = type(data) == "table" and snowflake(data.guild_id)
    local role_id = type(data) == "table" and snowflake(data.role)
    if guild_id and self.logs then self.logs:record(guild_id, "roles", "Role created: " .. safe(role_id, 24)) end
  end)
  self:_bind(client, "guild_role_delete", function(data)
    local guild_id = type(data) == "table" and snowflake(data.guild_id)
    local role_id = type(data) == "table" and snowflake(data.role_id)
    if guild_id and self.logs then self.logs:record(guild_id, "roles", "Role deleted: " .. safe(role_id, 24)) end
  end)
  self:_bind(client, "guild_delete", function(guild)
    local guild_id = type(guild) == "table" and snowflake(guild.id)
    if guild_id and self.greetings then
      self.greetings.guild_names[guild_id], self.greetings.counts[guild_id] = nil, nil
    end
  end)
  self:_bind(client, "guild_member_update", function(old_member, member)
    local guild_id = type(member) == "table" and snowflake(member.guild_id)
    if not guild_id or not self.logs then return end
    local before, after = {}, {}
    for _, id in ipairs(type(old_member) == "table" and old_member.roles or {}) do before[id] = true end
    for _, id in ipairs(type(member) == "table" and member.roles or {}) do after[id] = true end
    local changes = {}
    for id in pairs(after) do if not before[id] then changes[#changes + 1] = "+" .. safe(id, 24) end end
    for id in pairs(before) do if not after[id] then changes[#changes + 1] = "-" .. safe(id, 24) end end
    table.sort(changes)
    if #changes > 0 then
      while #changes > 8 do table.remove(changes) end
      self.logs:record(guild_id, "roles", "Member roles changed for " .. safe(member.user and member.user.id, 24) .. ": " .. table.concat(changes, ", "))
    end
  end)
  self:_bind(client, "message_delete", function(message)
    local guild_id = type(message) == "table" and snowflake(message.guild_id)
    if guild_id and self.logs then
      self.logs:record(guild_id, "moderation", "Message deleted in channel " .. safe(message.channel_id, 24) .. "; message " .. safe(message.id, 24))
    end
  end)
  self:_bind(client, "message_reaction_add", function(reaction)
    if self.starboard then self.starboard:on_reaction(reaction, true) end
  end)
  self:_bind(client, "message_reaction_remove", function(reaction)
    if self.starboard then self.starboard:on_reaction(reaction, false) end
  end)
  if bot and type(bot.on_message) == "function" then
    pcall(bot.on_message, bot, function(message)
      if self.afk then self:_run("message_create", self.afk.on_message, self.afk, message) end
    end)
  end
  self.bound = true
  return true
end

return Events
