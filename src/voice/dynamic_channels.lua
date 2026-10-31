local Dynamic = {}
Dynamic.__index = Dynamic

local CONNECT = 1048576
local function valid_id(value) return type(value) == "string" and #value <= 20 and value:match("^%d+$") ~= nil end
local function copy(value)
  local result = {}
  for key, item in pairs(value or {}) do result[key] = item end
  return result
end

local function decimal_bit(value, bit)
  local modulus, remainder = bit * 2, 0
  for digit in tostring(value or "0"):gmatch("%d") do remainder = (remainder * 10 + tonumber(digit)) % modulus end
  return remainder >= bit
end

local function decimal_add(value, amount)
  local digits, carry, index = {}, amount, #value
  while index > 0 or carry > 0 do
    local sum = (index > 0 and tonumber(value:sub(index, index)) or 0) + carry
    digits[#digits + 1] = tostring(sum % 10)
    carry = math.floor(sum / 10)
    index = index - 1
  end
  while index > 0 do digits[#digits + 1] = value:sub(index, index); index = index - 1 end
  local result = {}; for i = #digits, 1, -1 do result[#result + 1] = digits[i] end
  return table.concat(result)
end

local function decimal_subtract(value, amount)
  local digits, borrow, index = {}, amount, #value
  while index > 0 do
    local digit = tonumber(value:sub(index, index)) - borrow % 10
    borrow = math.floor(borrow / 10)
    if digit < 0 then digit, borrow = digit + 10, borrow + 1 end
    digits[#digits + 1] = tostring(digit)
    index = index - 1
  end
  while #digits > 1 and digits[#digits] == "0" do table.remove(digits) end
  local result = {}; for i = #digits, 1, -1 do result[#result + 1] = digits[i] end
  return table.concat(result)
end

local function set_bit(value, bit, enabled)
  value = tostring(value or "0")
  local has = decimal_bit(value, bit)
  if enabled and not has then return decimal_add(value, bit) end
  if not enabled and has then return decimal_subtract(value, bit) end
  return value
end

function Dynamic.new(store, options)
  assert(store, "guild store is required")
  options = options or {}
  return setmetatable({ store = store, rest = options.rest, client = options.client,
    music = options.music, logger = options.logger, bot_id = options.bot_id, configurations = {}, temporary = {},
    members = {}, busy = {}, pending = {} }, Dynamic)
end

local function log(self, level, event, fields)
  if self.logger and type(self.logger[level]) == "function" then
    pcall(self.logger[level], self.logger, event, fields)
  end
end

local function discord_code(value)
  if type(value) ~= "table" then return nil end
  local code = value.code or value.status_code
  return type(code) == "number" and code or nil
end

function Dynamic:set_runtime(rest, client, bot_id)
  self.rest, self.client, self.bot_id = rest, client, bot_id
end

function Dynamic:_run(guild_id, fn)
  return self.store:run(guild_id, function(data)
    data.voice_system = data.voice_system or { temporary = {} }
    data.voice_system.temporary = data.voice_system.temporary or {}
    return fn(data.voice_system)
  end)
end

function Dynamic:_trigger_category(guild_id, channel_id)
  if not self.rest then return nil, "discord_unavailable" end
  if not valid_id(channel_id) then return nil, "trigger_invalid" end
  local ok, trigger = pcall(self.rest.get_channel, self.rest, channel_id)
  if not ok or type(trigger) ~= "table" then return nil, "trigger_unavailable" end
  if trigger.guild_id ~= guild_id or trigger.type ~= 2 then return nil, "trigger_invalid" end
  if not valid_id(trigger.parent_id) then return nil, "trigger_category_missing" end
  local category_ok, category = pcall(self.rest.get_channel, self.rest, trigger.parent_id)
  if not category_ok or type(category) ~= "table" or category.type ~= 4 or category.guild_id ~= guild_id then
    return nil, "trigger_category_invalid"
  end
  return trigger.parent_id
end

function Dynamic:configure(guild_id, channel_id)
  if not valid_id(guild_id) or not valid_id(channel_id) then return false, "invalid_channel" end
  local category_id, category_reason = self:_trigger_category(guild_id, channel_id)
  if not category_id then return false, category_reason end
  local ok, result = self:_run(guild_id, function(config)
    config.trigger_channel_id = channel_id
    return true, copy(config), true
  end)
  if not ok then return false, "persistence_unavailable" end
  self.configurations[guild_id] = result
  return true
end

function Dynamic:disable(guild_id)
  local ok = self:_run(guild_id, function(config)
    config.trigger_channel_id = nil
    return true, true, true
  end)
  if not ok then return false, "persistence_unavailable" end
  self.configurations[guild_id] = nil
  return true
end

function Dynamic:status(guild_id)
  if self.configurations[guild_id] then return self.configurations[guild_id] end
  local ok, result = self:_run(guild_id, function(config) return true, copy(config), false end)
  if not ok then return nil, "persistence_unavailable" end
  self.configurations[guild_id] = result
  return result
end

function Dynamic:_save_temporary(guild_id, value)
  local ok = self:_run(guild_id, function(config)
    config.temporary = value
    return true, true, true
  end)
  if not ok then return false end
  local current = self.configurations[guild_id] or {}
  current.temporary = value
  self.configurations[guild_id] = current
  self.temporary[guild_id] = value
  return true
end

local function member_bucket(self, guild_id)
  self.members[guild_id] = self.members[guild_id] or {}
  return self.members[guild_id]
end

local function count_humans(self, guild_id, channel_id)
  local count = 0
  for user_id, is_bot in pairs(member_bucket(self, guild_id)[channel_id] or {}) do
    if user_id ~= self.bot_id and not is_bot then count = count + 1 end
  end
  return count
end

local function remove_member(self, guild_id, channel_id, user_id)
  local bucket = member_bucket(self, guild_id)[channel_id]
  if bucket then bucket[user_id] = nil; if not next(bucket) then member_bucket(self, guild_id)[channel_id] = nil end end
end

local function add_member(self, guild_id, channel_id, user_id, is_bot)
  if not channel_id then return end
  member_bucket(self, guild_id)[channel_id] = member_bucket(self, guild_id)[channel_id] or {}
  member_bucket(self, guild_id)[channel_id][user_id] = is_bot == true
end

local function cached_bot(self, user_id)
  if user_id == self.bot_id then return true end
  if not self.client or type(self.client.get_user) ~= "function" then return false end
  local ok, user = pcall(self.client.get_user, self.client, user_id)
  return ok and user ~= nil and user.bot == true
end

function Dynamic:on_guild_create(guild)
  if type(guild) ~= "table" or not valid_id(guild.id) then return false end
  local guild_id = guild.id
  self.members[guild_id] = {}
  self.memberships = self.memberships or {}
  self.memberships[guild_id] = {}
  for _, voice in ipairs(guild.voice_states or {}) do
    if type(voice.channel_id) == "string" then
      self.memberships[guild_id][voice.user_id] = voice.channel_id
      local is_bot = (voice.member and voice.member.user and voice.member.user.bot == true) or cached_bot(self, voice.user_id)
      if not is_bot then
        add_member(self, guild_id, voice.channel_id, voice.user_id,
          false)
      else
        add_member(self, guild_id, voice.channel_id, voice.user_id, true)
      end
    end
  end
  local config = self:status(guild_id)
  if type(config) ~= "table" then
    log(self, "warn", "dynamic_voice_configuration_unavailable", { detail = "persistence_unavailable" })
    return false
  end
  self.temporary[guild_id] = config.temporary or {}
  local category_id = config.trigger_channel_id and self:_trigger_category(guild_id, config.trigger_channel_id) or nil
  log(self, "info", "dynamic_voice_configuration_loaded", {
    configured = valid_id(config.trigger_channel_id), category_ready = category_id ~= nil,
  })
  local channel_map = {}
  for _, channel in ipairs(guild.channels or {}) do channel_map[channel.id] = channel end
  local changed = false
  for channel_id, temp in pairs(copy(config.temporary)) do
    local channel = channel_map[channel_id]
    if not channel or channel.type ~= 2 then
      config.temporary[channel_id] = nil; changed = true
    elseif count_humans(self, guild_id, channel_id) == 0 then
      if self.rest and pcall(self.rest.delete_channel, self.rest, channel_id) then
        config.temporary[channel_id] = nil; changed = true
      end
    elseif category_id and channel.parent_id ~= category_id then
      local moved = self.rest and pcall(self.rest.edit_channel, self.rest, channel_id, { parent_id = category_id })
      if moved then channel.parent_id = category_id; changed = true
      else log(self, "warn", "dynamic_voice_category_move_failed", { detail = "discord_unavailable" }) end
    end
    if channel and channel.type == 2 and count_humans(self, guild_id, channel_id) > 0
      and not member_bucket(self, guild_id)[channel_id][temp.owner_id] then
      local ids = {}; for user_id, is_bot in pairs(member_bucket(self, guild_id)[channel_id] or {}) do
        if user_id ~= self.bot_id and not is_bot then ids[#ids + 1] = user_id end
      end
      table.sort(ids)
      if #ids > 0 then temp.owner_id = ids[1]; changed = true end
    end
  end
  if changed then self:_save_temporary(guild_id, config.temporary) end
  return true
end

function Dynamic:_create_for(guild_id, user_id)
  if not self.rest then
    log(self, "warn", "dynamic_voice_create_failed", { detail = "discord_unavailable" })
    return false, "discord_unavailable"
  end
  local config = self.configurations[guild_id]
  local category_id, category_reason = self:_trigger_category(guild_id, config and config.trigger_channel_id)
  if not category_id then
    log(self, "warn", "dynamic_voice_create_failed", { detail = category_reason or "trigger_category_unavailable" })
    return false, category_reason or "trigger_category_unavailable"
  end
  local ok, channel = pcall(self.rest.create_guild_channel, self.rest, guild_id, {
    name = "Molly's room", type = 2, user_limit = 0, parent_id = category_id,
  })
  if not ok or type(channel) ~= "table" or not valid_id(channel.id) or channel.parent_id ~= category_id then
    log(self, "warn", "dynamic_voice_create_failed", {
      detail = ok and "category_assignment_failed" or "channel_create_failed",
      discord_code = not ok and discord_code(channel) or nil,
    })
    if ok and type(channel) == "table" and valid_id(channel.id) then pcall(self.rest.delete_channel, self.rest, channel.id) end
    return false, "channel_create_failed"
  end
  config = config or {}
  local temporary = copy(config.temporary)
  temporary[channel.id] = { guild_id = guild_id, channel_id = channel.id, owner_id = user_id,
    created_at = os.time(), user_limit = 0, locked = false }
  if not self:_save_temporary(guild_id, temporary) then
    pcall(self.rest.delete_channel, self.rest, channel.id)
    log(self, "warn", "dynamic_voice_create_failed", { detail = "persistence_unavailable" })
    return false, "persistence_unavailable"
  end
  local moved, move_result = pcall(self.rest.edit_member, self.rest, guild_id, user_id, { channel_id = channel.id })
  if not moved then
    pcall(self.rest.delete_channel, self.rest, channel.id)
    temporary[channel.id] = nil
    self:_save_temporary(guild_id, temporary)
    log(self, "warn", "dynamic_voice_create_failed", {
      detail = "move_failed", discord_code = discord_code(move_result),
    })
    return false, "move_failed"
  end
  self.memberships = self.memberships or {}
  self.memberships[guild_id] = self.memberships[guild_id] or {}
  self.memberships[guild_id][user_id] = channel.id
  add_member(self, guild_id, channel.id, user_id)
  log(self, "info", "dynamic_voice_room_created", {})
  return true, channel.id
end

function Dynamic:_delete_if_empty(guild_id, channel_id)
  local record = self.temporary[guild_id] and self.temporary[guild_id][channel_id]
  if not record or count_humans(self, guild_id, channel_id) > 0 then return false end
  if self.music then pcall(self.music.cleanup_guild, self.music, guild_id, channel_id) end
  local deleted = not self.rest or pcall(self.rest.delete_channel, self.rest, channel_id)
  if not deleted then return false end
  local temporary = copy(self.temporary[guild_id]); temporary[channel_id] = nil
  self:_save_temporary(guild_id, temporary)
  self.members[guild_id][channel_id] = nil
  return true
end

function Dynamic:_transfer_if_needed(guild_id, channel_id, user_id)
  local record = self.temporary[guild_id] and self.temporary[guild_id][channel_id]
  if not record or record.owner_id ~= user_id then return end
  local candidates = {}
  for member_id in pairs(member_bucket(self, guild_id)[channel_id] or {}) do
    if member_id ~= user_id and member_id ~= self.bot_id and not member_bucket(self, guild_id)[channel_id][member_id] then
      candidates[#candidates + 1] = member_id
    end
  end
  table.sort(candidates)
  if #candidates == 0 then self:_delete_if_empty(guild_id, channel_id); return end
  record.owner_id = candidates[1]
  self:_save_temporary(guild_id, copy(self.temporary[guild_id]))
end

function Dynamic:on_voice_state(data)
  if type(data) ~= "table" or not valid_id(data.guild_id) or not valid_id(data.user_id) then return false end
  local guild_id, user_id = data.guild_id, data.user_id
  local member_user = data.member and data.member.user
  local is_bot = user_id == self.bot_id or (member_user and member_user.bot == true)
  if not is_bot then is_bot = cached_bot(self, user_id) end
  local membership = self.memberships or {}; self.memberships = membership
  membership[guild_id] = membership[guild_id] or {}
  local old_channel = membership[guild_id][user_id]
  local new_channel = type(data.channel_id) == "string" and data.channel_id or nil
  if old_channel ~= new_channel then
    if old_channel then remove_member(self, guild_id, old_channel, user_id) end
    if new_channel then add_member(self, guild_id, new_channel, user_id, is_bot) end
    membership[guild_id][user_id] = new_channel
  end
  if is_bot then return true end
  if self.busy[guild_id] then
    self.pending[guild_id] = self.pending[guild_id] or {}
    self.pending[guild_id][#self.pending[guild_id] + 1] = data
    return true
  end
  self.busy[guild_id] = true
  local config = self.configurations[guild_id]
  if not config then config = self:status(guild_id); self.configurations[guild_id] = config end
  if new_channel and config and new_channel == config.trigger_channel_id then
    log(self, "info", "dynamic_voice_triggered", {})
    self:_create_for(guild_id, user_id)
  end
  if old_channel and old_channel ~= new_channel then
    self:_transfer_if_needed(guild_id, old_channel, user_id)
    self:_delete_if_empty(guild_id, old_channel)
  end
  self.busy[guild_id] = false
  local queued = table.remove(self.pending[guild_id] or {}, 1)
  if queued then self:on_voice_state(queued) end
  return true
end

function Dynamic:owner_action(guild_id, channel_id, actor_id, action, value, is_admin)
  if not valid_id(guild_id) or not valid_id(channel_id) or not valid_id(actor_id) then return false, "invalid_argument" end
  local config = self.temporary[guild_id]
  local record = config and config[channel_id]
  if not record then return false, "not_temporary" end
  if not is_admin and record.owner_id ~= actor_id then return false, "permission_denied" end
  if not self.rest then return false, "discord_unavailable" end
  if action == "rename" then
    if type(value) ~= "string" or value:match("^%s*$") or #value > 90 or value:find("[\r\n]") then return false, "invalid_name" end
    local ok = pcall(self.rest.edit_channel, self.rest, channel_id, { name = value })
    return ok, ok and true or "discord_unavailable"
  elseif action == "limit" then
    if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > 99 then return false, "invalid_limit" end
    local ok = pcall(self.rest.edit_channel, self.rest, channel_id, { user_limit = value })
    if not ok then return false, "discord_unavailable" end
    record.user_limit = value
  elseif action == "lock" or action == "unlock" or action == "permit" or action == "reject" then
    local target = (action == "lock" or action == "unlock") and guild_id or value
    local type_value = (action == "lock" or action == "unlock") and 0 or 1
    if not valid_id(target) then return false, "invalid_user" end
    local channel_ok, channel = pcall(self.rest.get_channel, self.rest, channel_id)
    if not channel_ok or type(channel) ~= "table" then return false, "discord_unavailable" end
    local existing
    for _, overwrite in ipairs(channel.permission_overwrites or {}) do
      if overwrite.id == target and overwrite.type == type_value then existing = overwrite; break end
    end
    local should_deny = action == "lock" or action == "reject"
    local allow = set_bit(existing and existing.allow or "0", CONNECT, not should_deny)
    local deny = set_bit(existing and existing.deny or "0", CONNECT, should_deny)
    if action == "unlock" or action == "permit" then deny = set_bit(deny, CONNECT, false) end
    local ok = pcall(self.rest.edit_channel_permissions, self.rest, channel_id, target,
      { type = type_value, allow = allow, deny = deny })
    if not ok then return false, "discord_unavailable" end
    if action == "lock" then record.locked = true elseif action == "unlock" then record.locked = false end
  elseif action == "transfer" then
    if not valid_id(value) or value == self.bot_id or not member_bucket(self, guild_id)[channel_id]
      or not member_bucket(self, guild_id)[channel_id][value] then return false, "target_not_in_channel" end
    record.owner_id = value
  else return false, "unsupported_action" end
  local saved = self:_save_temporary(guild_id, copy(config))
  return saved, saved and true or "persistence_unavailable"
end

return Dynamic
