local Store = require("src.persistence.guild_store")
local V2 = require("src.persistence.guild_v2")

local AFK = {}
AFK.__index = AFK

local MAX_RECORDS = 200
local MAX_PROCESSED = 512
local MAX_NOTICE_KEYS = 500
local NOTICE_TTL = 30

local function safe(value, maximum)
  value = tostring(value or ""):gsub("@", "@\226\128\139"):gsub("[\r\n]", " "):gsub("[%z\1-\8\11\12\14-\31\127]", " ")
  return value:sub(1, maximum or 160)
end

local function record_count(records)
  local n = 0
  for _ in pairs(records) do n = n + 1 end
  return n
end

function AFK.new(store, options)
  options = options or {}
  assert(type(store) == "table" and type(store.run) == "function", "guild store is required")
  return setmetatable({ store = store, clock = options.clock or os.time, send = options.send,
    logger = options.logger, processed = {}, processed_order = {}, notices = {} }, AFK)
end

function AFK:set(guild, user, message)
  if not Store.valid_id(guild) or not Store.valid_id(user) then return false, "invalid_argument" end
  message = message or ""
  if type(message) ~= "string" or #message > 140 or message:find("[%z\1-\8\11\12\14-\31\127]") then
    return false, "invalid_message"
  end
  return self.store:run(guild, function(data)
    local section, reason = V2.ensure_section(data, "afk")
    if not section then return false, reason end
    section.records = section.records or {}
    if type(section.records) ~= "table" then return false, "invalid_store" end
    local current = section.records[user]
    if not current and record_count(section.records) >= MAX_RECORDS then return false, "capacity" end
    if current and current.message == message then return true, current, false end
    local value = { message = message, timestamp = self.clock() }
    section.records[user] = value
    return true, value, true
  end)
end

function AFK:clear(guild, user)
  if not Store.valid_id(guild) or not Store.valid_id(user) then return false, "invalid_argument" end
  return self.store:run(guild, function(data)
    local section, reason = V2.read_section(data, "afk")
    if not section then return false, reason end
    local records = section.records or {}
    if type(records) ~= "table" then return false, "invalid_store" end
    if records[user] == nil then return true, false, false end
    records[user] = nil
    if data.molly_v2 and data.molly_v2.afk then data.molly_v2.afk.records = records end
    return true, true, true
  end)
end

function AFK:get(guild, user)
  if not Store.valid_id(guild) or not Store.valid_id(user) then return false, "invalid_argument" end
  return self:lookup(guild, { user })
end

function AFK:lookup(guild, users)
  if not Store.valid_id(guild) or type(users) ~= "table" then return false, "invalid_argument" end
  local wanted, count = {}, 0
  for _, user in ipairs(users) do
    if Store.valid_id(user) and not wanted[user] then wanted[user] = true; count = count + 1 end
    if count >= 10 then break end
  end
  return self.store:run(guild, function(data)
    local section, reason = V2.read_section(data, "afk")
    if not section then return false, reason end
    local records = section.records or {}
    if type(records) ~= "table" then return false, "invalid_store" end
    local result = {}
    for user in pairs(wanted) do
      local record = records[user]
      if record ~= nil then
        if type(record) ~= "table" or type(record.message) ~= "string" or type(record.timestamp) ~= "number" then
          return false, "invalid_store"
        end
        result[user] = { message = record.message, timestamp = record.timestamp }
      end
    end
    return true, result, false
  end)
end

local function message_id(message)
  return type(message) == "table" and Store.valid_id(message.id) and message.id or nil
end

function AFK:_seen(message)
  local id, now = message_id(message), self.clock()
  if not id then return false end
  if self.processed[id] then return true end
  self.processed[id] = now
  self.processed_order[#self.processed_order + 1] = id
  while #self.processed_order > MAX_PROCESSED do
    local oldest = table.remove(self.processed_order, 1)
    self.processed[oldest] = nil
  end
  return false
end

function AFK:_can_notify(guild, channel, user)
  local key, now = guild .. ":" .. channel .. ":" .. user, self.clock()
  local previous = self.notices[key]
  if previous and now - previous < NOTICE_TTL then return false end
  self.notices[key] = now
  local count = 0
  for _, at in pairs(self.notices) do
    count = count + 1
    if count > MAX_NOTICE_KEYS then
      local oldest_key, oldest_at
      for candidate, timestamp in pairs(self.notices) do
        if not oldest_at or timestamp < oldest_at then oldest_key, oldest_at = candidate, timestamp end
      end
      if oldest_key then self.notices[oldest_key] = nil end
      break
    end
  end
  return true
end

function AFK:_send(channel, content)
  if type(self.send) ~= "function" then return false end
  local called, result = pcall(self.send, channel, { content = content, allowed_mentions = { parse = {} } })
  if not called or result == false then
    if self.logger then self.logger:warn("afk_notice_failed", { detail = "discord_unavailable" }) end
    return false
  end
  return true
end

function AFK:on_message(message)
  if type(message) ~= "table" or not Store.valid_id(message.guild_id)
    or not Store.valid_id(message.channel_id) or type(message.author) ~= "table"
    or not Store.valid_id(message.author.id) or message.author.bot or message.webhook_id then
    return false, "ignored_message"
  end
  if self:_seen(message) then return false, "duplicate_message" end

  local guild, author, channel = message.guild_id, message.author.id, message.channel_id
  local returned_ok, returned = self:clear(guild, author)
  if returned_ok and returned then
    self:_send(channel, "AFK status cleared for " .. safe(author, 24) .. ". Welcome back.")
  end

  local ids, seen = {}, {}
  for _, user in ipairs(message.mentions or {}) do
    local id = type(user) == "table" and user.id or nil
    if Store.valid_id(id) and id ~= author and not seen[id] then
      ids[#ids + 1] = id; seen[id] = true
      if #ids >= 10 then break end
    end
  end
  if #ids == 0 then return true end
  local ok, entries = self:lookup(guild, ids)
  if not ok then return false, entries end
  local lines = {}
  for _, id in ipairs(ids) do
    local entry = entries[id]
    if entry and self:_can_notify(guild, channel, id) then
      local text = entry.message ~= "" and (": " .. safe(entry.message, 140)) or " is away."
      lines[#lines + 1] = "<@" .. id .. ">" .. text
      if #lines >= 5 then break end
    end
  end
  if #lines > 0 and self.send then self:_send(channel, table.concat(lines, "\n")) end
  return true
end

return AFK
