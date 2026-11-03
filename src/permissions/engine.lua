local Store = require("src.persistence.guild_store")
local V2 = require("src.persistence.guild_v2")

local Engine = {}
Engine.__index = Engine

local MAX_RULES = 1000
local MAX_GUILDS = 500
local CACHE_TTL = 5
local PROTECTED_COMMANDS = { eval = true, blacklist = true, shutdown = true, restart = true, update = true }

local function copy(value)
  local result = {}
  for key, item in pairs(value or {}) do result[key] = item end
  return result
end

local function valid_command(value)
  return type(value) == "string" and #value >= 1 and #value <= 32 and value:match("^[%w%-_]+$") ~= nil
end

local function valid_selector(selector)
  if type(selector) ~= "table" then return false end
  local user, role, channel = selector.user_id, selector.role_id, selector.channel_id
  if user and not Store.valid_id(user) then return false end
  if role and not Store.valid_id(role) then return false end
  if channel and not Store.valid_id(channel) then return false end
  if user and role then return false end
  return true
end

local function key_for(selector)
  local user, role, channel = selector.user_id, selector.role_id, selector.channel_id
  if user and channel then return "uc:" .. user .. ":" .. channel end
  if role and channel then return "rc:" .. role .. ":" .. channel end
  if user then return "u:" .. user end
  if role then return "r:" .. role end
  if channel then return "c:" .. channel end
  return "g"
end

local function count_rules(rules)
  local count = 0
  for _, command_rules in pairs(rules or {}) do
    if type(command_rules) ~= "table" then return nil end
    for _, effect in pairs(command_rules) do
      if effect ~= "allow" and effect ~= "deny" then return nil end
      count = count + 1
    end
  end
  return count
end

local function member_roles(context)
  local roles, seen = {}, {}
  for _, role in ipairs(context and context.member and context.member.roles or {}) do
    local id = type(role) == "table" and role.id or role
    if Store.valid_id(id) and not seen[id] then roles[#roles + 1] = id; seen[id] = true end
  end
  table.sort(roles)
  return roles
end

function Engine.new(store, options)
  options = options or {}
  assert(type(store) == "table" and type(store.run) == "function", "guild store is required")
  return setmetatable({ store = store, clock = options.clock or os.time, cache_ttl = options.cache_ttl or CACHE_TTL,
    max_guilds = options.max_guilds or MAX_GUILDS, cache = {}, router = nil }, Engine)
end

function Engine:set_router(router)
  self.router = router
end

function Engine:_is_protected(command)
  if PROTECTED_COMMANDS[command] then return true end
  local definition = self.router and self.router.commands and self.router.commands[command]
  return definition and (definition.admin == true or definition.molly_permission == false
    or definition.category == "Developer") or false
end

function Engine:is_manageable(command)
  if not valid_command(command) then return false, "invalid_command" end
  if self:_is_protected(command) then return false, "protected_command" end
  if self.router and self.router.commands and not self.router.commands[command] then return false, "unknown_command" end
  return true
end

function Engine:_remember(guild, rules)
  local count = 0
  for _ in pairs(self.cache) do count = count + 1 end
  if not self.cache[guild] and count >= self.max_guilds then
    local oldest, oldest_expiry
    for id, item in pairs(self.cache) do
      if not oldest_expiry or item.expires < oldest_expiry then oldest, oldest_expiry = id, item.expires end
    end
    if oldest then self.cache[oldest] = nil end
  end
  self.cache[guild] = { rules = rules, expires = self.clock() + self.cache_ttl }
end

function Engine:_rules(guild)
  if not Store.valid_id(guild) then return false, "invalid_guild" end
  local now, cached = self.clock(), self.cache[guild]
  if cached and cached.expires >= now then return true, cached.rules end
  local ok, rules = self.store:run(guild, function(data)
    local permissions, reason = V2.read_section(data, "permissions")
    if not permissions then return false, reason end
    local value = permissions.rules or {}
    if type(value) ~= "table" then return false, "invalid_rules_type_" .. type(value) end
    local total = count_rules(value)
    if total == nil then return false, "invalid_rules_contents" end
    return true, value, false
  end)
  if not ok then return false, rules end
  self:_remember(guild, rules)
  return true, rules
end

function Engine:set_rule(guild, command, selector, effect)
  command = type(command) == "string" and command:lower() or command
  if not Store.valid_id(guild) then return false, "invalid_guild" end
  if not valid_selector(selector) then return false, "invalid_argument" end
  local manageable, command_reason = self:is_manageable(command)
  if not manageable then return false, command_reason end
  if effect ~= "allow" and effect ~= "deny" then return false, "invalid_effect" end
  local rule_key = key_for(selector)
  local ok, result = self.store:run(guild, function(data)
    local permissions, reason = V2.ensure_section(data, "permissions")
    if not permissions then return false, reason end
    permissions.rules = permissions.rules or {}
    if type(permissions.rules) ~= "table" then return false, "invalid_store" end
    local current = permissions.rules[command]
    if current ~= nil and type(current) ~= "table" then return false, "invalid_store" end
    current = current or {}
    local existing = current[rule_key]
    if existing == effect then return true, { command = command, scope = rule_key, effect = effect }, false end
    if existing == nil then
      local total = count_rules(permissions.rules)
      if not total then return false, "invalid_store" end
      if total >= MAX_RULES then return false, "capacity" end
    end
    current[rule_key] = effect
    permissions.rules[command] = current
    return true, { command = command, scope = rule_key, effect = effect }, true
  end)
  if ok then self.cache[guild] = nil end
  return ok, result
end

function Engine:reset(guild, command, selector)
  command = type(command) == "string" and command:lower() or command
  if not Store.valid_id(guild) or (selector ~= nil and not valid_selector(selector)) then return false, "invalid_argument" end
  local manageable, command_reason = self:is_manageable(command)
  if not manageable then return false, command_reason end
  local rule_key = selector and key_for(selector) or nil
  local ok, result = self.store:run(guild, function(data)
    local permissions, reason = V2.ensure_section(data, "permissions")
    if not permissions then return false, reason end
    permissions.rules = permissions.rules or {}
    if type(permissions.rules) ~= "table" then return false, "invalid_store" end
    local current = permissions.rules[command]
    if current == nil then return true, false, false end
    if type(current) ~= "table" then return false, "invalid_store" end
    if rule_key then
      if current[rule_key] == nil then return true, false, false end
      current[rule_key] = nil
      if not next(current) then permissions.rules[command] = nil end
    else
      permissions.rules[command] = nil
    end
    return true, true, true
  end)
  if ok then self.cache[guild] = nil end
  return ok, result
end

function Engine:list(guild, command, limit)
  if not Store.valid_id(guild) then return false, "invalid_guild" end
  if command ~= nil then
    command = type(command) == "string" and command:lower() or command
    local manageable, reason = self:is_manageable(command)
    if not manageable then return false, reason end
  end
  limit = math.max(1, math.min(100, math.floor(tonumber(limit) or 50)))
  local ok, rules = self:_rules(guild)
  if not ok then return false, rules end
  local result = {}
  local commands = {}
  if command then commands[1] = command else
    for name in pairs(rules) do commands[#commands + 1] = name end
    table.sort(commands)
  end
  for _, name in ipairs(commands) do
    local scoped = rules[name]
    if scoped == nil then scoped = {} end
    if type(scoped) ~= "table" then return false, "invalid_store" end
    local scopes = {}
    for scope in pairs(scoped) do scopes[#scopes + 1] = scope end
    table.sort(scopes)
    for _, scope in ipairs(scopes) do
      result[#result + 1] = { command = name, scope = scope, effect = scoped[scope] }
      if #result >= limit then return true, result end
    end
  end
  return true, result
end

local function match_at(rules, command, keys, roles, scope_name)
  local scoped = rules[command] or {}
  local matches = {}
  for _, key in ipairs(keys) do
    local effect = scoped[key]
    if effect then matches[#matches + 1] = { effect = effect, scope = scope_name, key = key } end
  end
  if #matches == 0 then return nil end
  table.sort(matches, function(a, b)
    if a.effect ~= b.effect then return a.effect == "deny" end
    return a.key < b.key
  end)
  return matches[1]
end

function Engine:resolve(context, command)
  command = type(command) == "string" and command:lower() or command
  if not context or not context.guild or not Store.valid_id(context.guild.id) then return true, nil end
  if not valid_command(command) then return false, "invalid_command" end
  if self:_is_protected(command) then return true, nil end
  local ok, rules = self:_rules(context.guild.id)
  if not ok then return false, "access_unavailable" end
  local user_id = context.author and context.author.id
  local channel_id = (context.channel and context.channel.id) or context.channel_id
  local roles = member_roles(context)
  local candidates = {}
  if Store.valid_id(user_id) and Store.valid_id(channel_id) then
    candidates[#candidates + 1] = match_at(rules, command, { "uc:" .. user_id .. ":" .. channel_id }, roles, "user_channel")
  end
  if Store.valid_id(channel_id) then
    local keys = {}; for _, id in ipairs(roles) do keys[#keys + 1] = "rc:" .. id .. ":" .. channel_id end
    candidates[#candidates + 1] = match_at(rules, command, keys, roles, "role_channel")
  end
  if Store.valid_id(user_id) then
    candidates[#candidates + 1] = match_at(rules, command, { "u:" .. user_id }, roles, "user")
  end
  do
    local keys = {}; for _, id in ipairs(roles) do keys[#keys + 1] = "r:" .. id end
    candidates[#candidates + 1] = match_at(rules, command, keys, roles, "role")
  end
  if Store.valid_id(channel_id) then
    candidates[#candidates + 1] = match_at(rules, command, { "c:" .. channel_id }, roles, "channel")
  end
  candidates[#candidates + 1] = match_at(rules, command, { "g" }, roles, "guild")
  for _, candidate in ipairs(candidates) do if candidate then return true, candidate end end
  return true, nil
end

function Engine:authorize(context, definition, default_allowed)
  if definition.admin or definition.molly_permission == false or definition.category == "Developer" then
    return default_allowed, default_allowed and nil or "permission_denied"
  end
  local ok, rule = self:resolve(context, definition.molly_permission or definition.name)
  if not ok then return false, rule or "access_unavailable" end
  if rule and rule.effect == "deny" then return false, "permission_denied", rule end
  if rule and rule.effect == "allow" then
    if default_allowed or definition.permission_override == true then return true, nil, rule end
    return false, "permission_denied", rule
  end
  return default_allowed, default_allowed and nil or "permission_denied"
end

Engine.valid_selector = valid_selector
Engine.key_for = key_for
Engine.max_rules = MAX_RULES
return Engine
