local Dynamic = {}
Dynamic.__index = Dynamic

local CONNECT = 1048576
local MAX_TRACKED_GUILDS = 500
local MAX_TRACKED_MEMBERS = 5000
local MAX_TEMP_ROOMS = 100
local MAX_PENDING_EVENTS = 32
local MAX_PENDING_MOVES = 256
local function valid_id(value) return type(value) == "string" and #value <= 20 and value:match("^%d+$") ~= nil end
local function copy(value)
  local result = {}
  for key, item in pairs(value or {}) do result[key] = item end
  return result
end

local function temporary_count(value)
  local count = 0
  for _ in pairs(value or {}) do count = count + 1 end
  return count
end

local function valid_temporary(value)
  if type(value) ~= "table" or temporary_count(value) > MAX_TEMP_ROOMS then return false end
  for channel_id, record in pairs(value) do
    if not valid_id(channel_id) or type(record) ~= "table"
      or (record.owner_id ~= nil and not valid_id(record.owner_id))
      or (record.created_at ~= nil and type(record.created_at) ~= "number")
      or (record.user_limit ~= nil and (type(record.user_limit) ~= "number" or record.user_limit % 1 ~= 0 or record.user_limit < 0 or record.user_limit > 99))
      or (record.locked ~= nil and type(record.locked) ~= "boolean") then return false end
  end
  return true
end

local function compact_voice(data)
  local member_user = type(data.member) == "table" and data.member.user or nil
  local compact = { guild_id = data.guild_id, user_id = data.user_id, channel_id = data.channel_id }
  if type(member_user) == "table" then compact.member = { user = { id = member_user.id, bot = member_user.bot == true } } end
  return compact
end

local function set_pending_move(self, guild_id, user_id, move)
  self.pending_moves[guild_id] = self.pending_moves[guild_id] or {}
  local bucket = self.pending_moves[guild_id]
  if bucket[user_id] == nil and temporary_count(bucket) >= MAX_PENDING_MOVES then
    self.membership_incomplete[guild_id] = true
    return false
  end
  bucket[user_id] = move
  return true
end

local function normalize_decimal(value)
  if type(value) ~= "string" or not value:match("^%d+$") then return nil end
  local normalized = value:gsub("^0+", "")
  return normalized == "" and "0" or normalized
end

local function compare_decimal(left, right)
  left, right = normalize_decimal(left), normalize_decimal(right)
  if not left or not right then return nil end
  if #left < #right then return -1 end
  if #left > #right then return 1 end
  if left < right then return -1 end
  if left > right then return 1 end
  return 0
end

local function decimal_bit(value, bit)
  local normalized = normalize_decimal(value)
  if not normalized or type(bit) ~= "number" or bit < 1 or bit % 1 ~= 0 then return nil end
  local modulus, remainder = bit * 2, 0
  for digit in normalized:gmatch("%d") do remainder = (remainder * 10 + tonumber(digit)) % modulus end
  return remainder >= bit
end

local function decimal_add(value, amount)
  local left, right = normalize_decimal(value), normalize_decimal(amount)
  if not left or not right then return nil end
  local result, carry, i, j = {}, 0, #left, #right
  while i > 0 or j > 0 or carry > 0 do
    local sum = carry
    if i > 0 then sum, i = sum + tonumber(left:sub(i, i)), i - 1 end
    if j > 0 then sum, j = sum + tonumber(right:sub(j, j)), j - 1 end
    result[#result + 1] = tostring(sum % 10)
    carry = math.floor(sum / 10)
  end
  local output = {}; for index = #result, 1, -1 do output[#output + 1] = result[index] end
  return table.concat(output)
end

local function decimal_subtract(value, amount)
  local left, right = normalize_decimal(value), normalize_decimal(amount)
  if not left or not right or compare_decimal(left, right) < 0 then return nil end
  local result, borrow, i, j = {}, 0, #left, #right
  while i > 0 do
    local digit = tonumber(left:sub(i, i)) - borrow
    if j > 0 then digit = digit - tonumber(right:sub(j, j)) end
    if digit < 0 then digit, borrow = digit + 10, 1 else borrow = 0 end
    result[#result + 1] = tostring(digit)
    i, j = i - 1, j - 1
  end
  if borrow ~= 0 or j > 0 then return nil end
  while #result > 1 and result[#result] == "0" do table.remove(result) end
  local output = {}; for index = #result, 1, -1 do output[#output + 1] = result[index] end
  return table.concat(output)
end

local function set_bit(value, bit, enabled)
  value = normalize_decimal(value)
  if not value then return nil end
  local has = decimal_bit(value, bit)
  if has == nil then return nil end
  if enabled and not has then return decimal_add(value, tostring(bit)) end
  if not enabled and has then return decimal_subtract(value, tostring(bit)) end
  return value
end

function Dynamic.new(store, options)
  assert(store, "guild store is required")
  options = options or {}
  return setmetatable({ store = store, rest = options.rest, client = options.client,
    music = options.music, logger = options.logger, bot_id = options.bot_id, configurations = {}, temporary = {},
    members = {}, memberships = {}, membership_counts = {}, membership_incomplete = {},
    busy = {}, pending = {}, pending_moves = {} }, Dynamic)
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

local function rest_succeeded(called, result)
  return called == true and result ~= nil and result ~= false
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

function Dynamic:_ensure_tracking(guild_id)
  if not valid_id(guild_id) then return false end
  if self.memberships[guild_id] then return true end
  if temporary_count(self.memberships) >= MAX_TRACKED_GUILDS then return false end
  self.memberships[guild_id], self.members[guild_id] = {}, {}
  self.membership_counts[guild_id], self.membership_incomplete[guild_id] = 0, false
  return true
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
  if not self:_ensure_tracking(guild_id) then return false, "capacity" end
  local ok, result = self:_run(guild_id, function(config)
    config.trigger_channel_id = channel_id
    return true, copy(config), true
  end)
  if not ok then return false, "persistence_unavailable" end
  self.configurations[guild_id] = result
  return true
end

function Dynamic:disable(guild_id)
  if not valid_id(guild_id) then return false, "invalid_guild" end
  local ok = self:_run(guild_id, function(config)
    config.trigger_channel_id = nil
    return true, true, true
  end)
  if not ok then return false, "persistence_unavailable" end
  self.configurations[guild_id] = nil
  return true
end

function Dynamic:status(guild_id)
  if not valid_id(guild_id) then return nil, "invalid_guild" end
  if self.configurations[guild_id] then return self.configurations[guild_id] end
  if not self:_ensure_tracking(guild_id) then return nil, "capacity" end
  local ok, result = self:_run(guild_id, function(config) return true, copy(config), false end)
  if not ok then return nil, "persistence_unavailable" end
  self.configurations[guild_id] = result
  return result
end

function Dynamic:_save_temporary(guild_id, value)
  if not valid_id(guild_id) or not valid_temporary(value) or not self:_ensure_tracking(guild_id) then return false end
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

local function clear_channel_members(self, guild_id, channel_id)
  local membership = self.memberships[guild_id] or {}
  for user_id, current_channel in pairs(membership) do
    if current_channel == channel_id then
      membership[user_id] = nil
      self.membership_counts[guild_id] = math.max(0, (self.membership_counts[guild_id] or 0) - 1)
    end
  end
  if self.members[guild_id] then self.members[guild_id][channel_id] = nil end
end

local function cached_bot(self, user_id)
  if user_id == self.bot_id then return true end
  if not self.client or type(self.client.get_user) ~= "function" then return false end
  local ok, user = pcall(self.client.get_user, self.client, user_id)
  return ok and type(user) == "table" and user.bot == true
end

function Dynamic:on_guild_create(guild)
  if type(guild) ~= "table" or not valid_id(guild.id) then return false end
  local guild_id = guild.id
  if not self:_ensure_tracking(guild_id) then
    log(self, "warn", "dynamic_voice_tracking_unavailable", { detail = "guild_limit" })
    return false
  end
  self.members[guild_id], self.memberships[guild_id] = {}, {}
  self.membership_counts[guild_id], self.membership_incomplete[guild_id] = 0, false
  self.pending_moves[guild_id], self.pending[guild_id], self.busy[guild_id] = nil, nil, nil
  local voice_states = guild.voice_states
  if type(voice_states) ~= "table" then
    self.membership_incomplete[guild_id] = true
    voice_states = {}
  end
  local scanned = 0
  for _, voice in ipairs(voice_states) do
    scanned = scanned + 1
    if scanned > MAX_TRACKED_MEMBERS then
      self.membership_incomplete[guild_id] = true
      break
    end
    if type(voice) ~= "table" or not valid_id(voice.user_id) or not valid_id(voice.channel_id) then
      self.membership_incomplete[guild_id] = true
    else
      local existing = self.memberships[guild_id][voice.user_id]
      local can_track = existing ~= nil
      if existing and existing ~= voice.channel_id then remove_member(self, guild_id, existing, voice.user_id) end
      if not existing then
        if self.membership_counts[guild_id] >= MAX_TRACKED_MEMBERS then
          self.membership_incomplete[guild_id], can_track = true, false
        else
          self.membership_counts[guild_id], can_track = self.membership_counts[guild_id] + 1, true
        end
      end
      if can_track then
        self.memberships[guild_id][voice.user_id] = voice.channel_id
        local member = type(voice.member) == "table" and voice.member.user or nil
        local is_bot = (type(member) == "table" and member.bot == true) or cached_bot(self, voice.user_id)
        add_member(self, guild_id, voice.channel_id, voice.user_id, is_bot)
      end
    end
  end
  if type(guild.channels) ~= "table" then
    self.membership_incomplete[guild_id] = true
    log(self, "warn", "dynamic_voice_configuration_unavailable", { detail = "guild_channels_unavailable" })
    return false
  end
  local config = self:status(guild_id)
  if type(config) ~= "table" then
    log(self, "warn", "dynamic_voice_configuration_unavailable", { detail = "persistence_unavailable" })
    return false
  end
  config.temporary = config.temporary or {}
  if not valid_temporary(config.temporary) then
    log(self, "warn", "dynamic_voice_configuration_unavailable", { detail = "invalid_temporary_rooms" })
    return false
  end
  self.temporary[guild_id] = config.temporary
  local category_id = config.trigger_channel_id and self:_trigger_category(guild_id, config.trigger_channel_id) or nil
  log(self, "info", "dynamic_voice_configuration_loaded", {
    configured = valid_id(config.trigger_channel_id), category_ready = category_id ~= nil,
  })
  local channel_map = {}
  for _, channel in ipairs(guild.channels or {}) do channel_map[channel.id] = channel end
  local changed = false
  for channel_id, temp in pairs(copy(config.temporary)) do
    local channel = channel_map[channel_id]
    if not channel and count_humans(self, guild_id, channel_id) > 0 then
      self.membership_incomplete[guild_id] = true
      log(self, "warn", "dynamic_voice_configuration_unavailable", { detail = "active_room_missing_from_snapshot" })
    elseif not channel or channel.type ~= 2 then
      config.temporary[channel_id] = nil; changed = true
      clear_channel_members(self, guild_id, channel_id)
    elseif not self.membership_incomplete[guild_id] and count_humans(self, guild_id, channel_id) == 0 then
      local called, result = false, nil
      if self.rest and type(self.rest.delete_channel) == "function" then
        called, result = pcall(self.rest.delete_channel, self.rest, channel_id)
      end
      if rest_succeeded(called, result) then
        config.temporary[channel_id] = nil; changed = true
        clear_channel_members(self, guild_id, channel_id)
      end
    elseif category_id and channel.parent_id ~= category_id then
      local called, result = false, nil
      if self.rest and type(self.rest.edit_channel) == "function" then
        called, result = pcall(self.rest.edit_channel, self.rest, channel_id, { parent_id = category_id })
      end
      if rest_succeeded(called, result) then channel.parent_id = category_id; changed = true
      else log(self, "warn", "dynamic_voice_category_move_failed", { detail = "discord_unavailable" }) end
    end
    if not self.membership_incomplete[guild_id] and channel and channel.type == 2
      and count_humans(self, guild_id, channel_id) > 0
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
  if not config or not valid_temporary(config.temporary or {}) then
    log(self, "warn", "dynamic_voice_create_failed", { detail = "configuration_unavailable" })
    return false, "configuration_unavailable"
  end
  if temporary_count(config.temporary) >= MAX_TEMP_ROOMS then
    log(self, "warn", "dynamic_voice_create_failed", { detail = "room_limit" })
    return false, "room_limit"
  end
  local category_id, category_reason = self:_trigger_category(guild_id, config.trigger_channel_id)
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
  if not rest_succeeded(moved, move_result) then
    local delete_called, delete_result = pcall(self.rest.delete_channel, self.rest, channel.id)
    if rest_succeeded(delete_called, delete_result) then
      temporary[channel.id] = nil
      self:_save_temporary(guild_id, temporary)
    end
    log(self, "warn", "dynamic_voice_create_failed", {
      detail = rest_succeeded(delete_called, delete_result) and "move_failed" or "move_and_cleanup_failed",
      discord_code = discord_code(move_result),
    })
    return false, "move_failed"
  end
  self.memberships = self.memberships or {}
  self.memberships[guild_id] = self.memberships[guild_id] or {}
  local old_channel = self.memberships[guild_id][user_id]
  if old_channel then remove_member(self, guild_id, old_channel, user_id) end
  self.memberships[guild_id][user_id] = channel.id
  if old_channel then
    set_pending_move(self, guild_id, user_id, { from_channel = old_channel, to_channel = channel.id, expires = os.time() + 10 })
  end
  add_member(self, guild_id, channel.id, user_id)
  log(self, "info", "dynamic_voice_room_created", {})
  return true, channel.id
end

function Dynamic:_delete_if_empty(guild_id, channel_id)
  local record = self.temporary[guild_id] and self.temporary[guild_id][channel_id]
  if not record or self.membership_incomplete[guild_id]
    or not self.memberships[guild_id] or count_humans(self, guild_id, channel_id) > 0 then return false end
  if not self.rest or type(self.rest.delete_channel) ~= "function" then return false end
  local called, result = pcall(self.rest.delete_channel, self.rest, channel_id)
  if not rest_succeeded(called, result) then return false end
  if self.music then pcall(self.music.cleanup_guild, self.music, guild_id, channel_id) end
  local temporary = copy(self.temporary[guild_id]); temporary[channel_id] = nil
  self:_save_temporary(guild_id, temporary)
  clear_channel_members(self, guild_id, channel_id)
  return true
end

function Dynamic:_transfer_if_needed(guild_id, channel_id, user_id)
  local record = self.temporary[guild_id] and self.temporary[guild_id][channel_id]
  if not record or record.owner_id ~= user_id or self.membership_incomplete[guild_id] then return end
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
  local member_user = type(data.member) == "table" and data.member.user or nil
  local is_bot = user_id == self.bot_id or (type(member_user) == "table" and member_user.bot == true)
  if not is_bot then is_bot = cached_bot(self, user_id) end
  if is_bot then return true end
  if not self:_ensure_tracking(guild_id) then return false, "capacity" end
  if self.busy[guild_id] then
    self.pending[guild_id] = self.pending[guild_id] or {}
    if #self.pending[guild_id] >= MAX_PENDING_EVENTS then
      self.membership_incomplete[guild_id] = true
      log(self, "warn", "dynamic_voice_tracking_incomplete", { detail = "pending_event_limit" })
      return false, "busy"
    end
    self.pending[guild_id][#self.pending[guild_id] + 1] = compact_voice(data)
    return true
  end
  if data.channel_id ~= nil and not valid_id(data.channel_id) then
    self.membership_incomplete[guild_id] = true
    return false, "invalid_channel"
  end
  local membership = self.memberships[guild_id]
  local old_channel = membership[user_id]
  local new_channel = data.channel_id
  if not old_channel and new_channel and self.membership_counts[guild_id] >= MAX_TRACKED_MEMBERS then
    self.membership_incomplete[guild_id] = true
    return false, "capacity"
  end
  local pending_move = self.pending_moves[guild_id] and self.pending_moves[guild_id][user_id]
  if pending_move then
    if pending_move.expires >= os.time() and new_channel == pending_move.from_channel then return true end
    self.pending_moves[guild_id][user_id] = nil
  end
  if old_channel ~= new_channel then
    if old_channel then
      remove_member(self, guild_id, old_channel, user_id)
      self.membership_counts[guild_id] = math.max(0, self.membership_counts[guild_id] - 1)
    end
    if new_channel then
      add_member(self, guild_id, new_channel, user_id, false)
      self.membership_counts[guild_id] = self.membership_counts[guild_id] + 1
    end
    membership[user_id] = new_channel
  end
  self.busy[guild_id] = true
  local config = self.configurations[guild_id]
  if not config then config = self:status(guild_id); self.configurations[guild_id] = config end
  if new_channel and old_channel ~= new_channel and config and new_channel == config.trigger_channel_id
    and not (old_channel == nil and self.membership_incomplete[guild_id]) then
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
    local called, result = pcall(self.rest.edit_channel, self.rest, channel_id, { name = value })
    local ok = rest_succeeded(called, result)
    return ok, ok and true or "discord_unavailable"
  elseif action == "limit" then
    if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > 99 then return false, "invalid_limit" end
    local called, result = pcall(self.rest.edit_channel, self.rest, channel_id, { user_limit = value })
    if not rest_succeeded(called, result) then return false, "discord_unavailable" end
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
    if not allow or not deny then return false, "invalid_permissions" end
    local called, result = pcall(self.rest.edit_channel_permissions, self.rest, channel_id, target,
      { type = type_value, allow = allow, deny = deny })
    if not rest_succeeded(called, result) then return false, "discord_unavailable" end
    if action == "lock" then record.locked = true elseif action == "unlock" then record.locked = false end
  elseif action == "transfer" then
    if not valid_id(value) or value == self.bot_id or not member_bucket(self, guild_id)[channel_id]
      or not member_bucket(self, guild_id)[channel_id][value] then return false, "target_not_in_channel" end
    record.owner_id = value
  else return false, "unsupported_action" end
  local saved = self:_save_temporary(guild_id, copy(config))
  return saved, saved and true or "persistence_unavailable"
end

Dynamic.max_tracked_guilds = MAX_TRACKED_GUILDS
Dynamic.max_tracked_members = MAX_TRACKED_MEMBERS
Dynamic.max_temp_rooms = MAX_TEMP_ROOMS
Dynamic.max_pending_events = MAX_PENDING_EVENTS
Dynamic.max_pending_moves = MAX_PENDING_MOVES
Dynamic.decimal = { bit = decimal_bit, add = decimal_add, subtract = decimal_subtract, set_bit = set_bit }
return Dynamic
