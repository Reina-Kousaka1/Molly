local Store = require("src.persistence.guild_store")

local Events = {}
Events.__index = Events
local unpack_values = table.unpack or unpack

local function snowflake(value)
  if Store.valid_id(value) then return value end
  if type(value) == "table" and Store.valid_id(value.id) then return value.id end
  return nil
end

local function safe(value, maximum)
  return tostring(value or ""):gsub("@", "@\226\128\139"):gsub("[\r\n]", " ")
    :gsub("[%z\1-\8\11\12\14-\31\127]", " "):sub(1, maximum or 120)
end

local function safe_error_detail(value)
  if type(value) == "table" then
    local details = { "handler_error" }
    local status = value.status_code or value.status
    if type(status) == "number" and status % 1 == 0 and status >= 100 and status <= 599 then
      details[#details + 1] = "http_status=" .. tostring(status)
    end
    local code = value.code
    if type(code) == "number" and code % 1 == 0 and code >= 0 and code <= 9999999999 then
      details[#details + 1] = "error_code=" .. tostring(code)
    elseif type(code) == "string" and #code <= 10 and code:match("^%d+$") then
      details[#details + 1] = "error_code=" .. code
    end
    return table.concat(details, " ")
  end
  if type(value) ~= "string" then return "handler_error" end
  local source = value:match("^(.-%.lua:%d+):")
  local lowered = value:lower()
  local category = "handler_error"
  if lowered:find("attempt to index", 1, true) then category = "attempt_to_index"
  elseif lowered:find("attempt to call", 1, true) then category = "attempt_to_call"
  elseif lowered:find("bad argument", 1, true) then category = "bad_argument"
  elseif lowered:find("assertion failed", 1, true) then category = "assertion_failed"
  elseif lowered:find("stack overflow", 1, true) then category = "stack_overflow"
  elseif lowered:find("out of memory", 1, true) then category = "out_of_memory" end
  if source then return safe(source, 160) .. ": " .. category end
  return category
end

function Events.new(options)
  options = options or {}
  return setmetatable({ greetings = options.greetings, afk = options.afk, logs = options.logs,
    starboard = options.starboard, content_policy = options.content_policy, logger = options.logger, bound = false }, Events)
end

function Events:_run(name, callback, ...)
  if type(callback) ~= "function" then return false, "handler_unavailable" end
  local args = { n = select("#", ...), ... }
  local ok, result = pcall(function() return callback(unpack_values(args, 1, args.n)) end)
  if not ok and self.logger and type(self.logger.warn) == "function" then
    pcall(self.logger.warn, self.logger, "community_event_failed", {
      event = safe(name, 80), detail = safe_error_detail(result),
    })
  end
  return ok, result
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
  if self.content_policy then self.content_policy:set_runtime(rest) end
  if self.starboard then
    self.starboard:set_runtime(rest, bot and bot.user and bot.user.id or client and client.user and client.user.id)
    if self.content_policy then self.starboard:set_content_policy(self.content_policy) end
  end
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
    local count
    if self.greetings then
      local counted, result = self:_run("guild_member_add_count", self.greetings.member_joined, self.greetings, guild_id)
      if counted then count = result end
      self:_run("guild_member_add_welcome", self.greetings.send_event, self.greetings, guild_id, "welcome", member, count)
    end
    if self.logs then
      self:_run("guild_member_add_log", self.logs.record, self.logs, guild_id,
        "member_join", "Member joined: " .. safe(member.user and member.user.id, 24))
    end
  end)
  self:_bind(client, "guild_member_remove", function(member)
    local guild_id = type(member) == "table" and snowflake(member.guild_id)
    if not guild_id then return end
    local count
    if self.greetings then
      local counted, result = self:_run("guild_member_remove_count", self.greetings.member_left, self.greetings, guild_id)
      if counted then count = result end
      self:_run("guild_member_remove_goodbye", self.greetings.send_event, self.greetings, guild_id, "goodbye", member, count)
    end
    if self.logs then
      self:_run("guild_member_remove_log", self.logs.record, self.logs, guild_id,
        "member_leave", "Member left: " .. safe(member.user and member.user.id, 24))
    end
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
