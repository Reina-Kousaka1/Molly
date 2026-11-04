local Store = require("src.persistence.guild_store")

local Policy = {}
Policy.__index = Policy

local function includes(list, value)
  for _, id in ipairs(list or {}) do if id == value then return true end end
  return false
end

function Policy.new(settings, options)
  options = options or {}
  assert(type(settings) == "table" and type(settings.get_domain) == "function"
    and type(settings.update_domain) == "function", "guild settings are required")
  return setmetatable({ settings = settings, rest = options.rest, user_settings = options.user_settings }, Policy)
end

function Policy:set_runtime(rest)
  self.rest = rest
end

function Policy:validate_channel(guild, channel_id)
  if not Store.valid_id(guild) or not Store.valid_id(channel_id) or not self.rest
    or type(self.rest.get_channel) ~= "function" then return false, "invalid_channel" end
  local ok, channel = pcall(self.rest.get_channel, self.rest, channel_id)
  if not ok or type(channel) ~= "table" then return false, "channel_unavailable" end
  if channel.guild_id ~= guild then return false, "wrong_guild" end
  if channel.type ~= 0 and channel.type ~= 5 then return false, "not_text_channel" end
  if channel.nsfw ~= true then return false, "nsfw_channel_required" end
  return true, channel
end

function Policy:add_channel(guild, channel_id)
  local valid, reason = self:validate_channel(guild, channel_id)
  if not valid then return false, reason end
  return self.settings:update_domain(guild, "content", function(config)
    if includes(config.mature_channels, channel_id) then return false end
    if #config.mature_channels >= 10 then return nil, "capacity" end
    config.mature_channels[#config.mature_channels + 1] = channel_id
    table.sort(config.mature_channels)
    return true
  end)
end

function Policy:remove_channel(guild, channel_id)
  if not Store.valid_id(guild) or not Store.valid_id(channel_id) then return false, "invalid_argument" end
  return self.settings:update_domain(guild, "content", function(config)
    local found
    for i, value in ipairs(config.mature_channels) do if value == channel_id then found = i; break end end
    if not found then return false end
    table.remove(config.mature_channels, found)
    if #config.mature_channels == 0 then config.mature_enabled = false end
    return true
  end)
end

function Policy:set_enabled(guild, enabled)
  if not Store.valid_id(guild) or type(enabled) ~= "boolean" then return false, "invalid_argument" end
  return self.settings:update_domain(guild, "content", function(config)
    if enabled and #config.mature_channels == 0 then return nil, "channel_required" end
    config.mature_enabled = enabled
    return true
  end)
end

function Policy:allows(guild, channel_id)
  if not Store.valid_id(guild) or not Store.valid_id(channel_id) then return false, "invalid_argument" end
  local ok, config = self.settings:get_domain(guild, "content")
  if not ok then return false, config end
  if not config.mature_enabled or not includes(config.mature_channels, channel_id) then return false, "mature_disabled" end
  local valid, reason = self:validate_channel(guild, channel_id)
  if not valid then return false, reason end
  return true
end

-- Explicit sexual/pornographic content is never allowed by this policy. The
-- opt-in only gates non-explicit mature themes in allowlisted NSFW channels.
function Policy:authorize(guild, channel_id, category, user)
  if category == "explicit" or category == "pornographic" then return false, "content_prohibited" end
  if category == "mature" then
    local allowed, reason = self:allows(guild, channel_id)
    if not allowed then return false, reason end
    if self.user_settings then
      if not Store.valid_id(user) then return false, "user_opt_in_required" end
      local loaded, preferences = self.user_settings:get(user)
      if not loaded then return false, "user_preferences_unavailable" end
      if not preferences.mature_opt_in then return false, "user_opt_in_required" end
    end
    return true
  end
  if category == "general" or category == "non_mature" then return true end
  return false, "unknown_category"
end

return Policy
