local Adapter = {}
Adapter.__index = Adapter

local function unavailable(detail)
  return { status = "unavailable", detail = detail }
end

function Adapter.new(options)
  options = options or {}
  return setmetatable({
    provider = options.provider,
    configuration_errors = options.configuration_errors or {},
  }, Adapter)
end

function Adapter:status()
  if #self.configuration_errors > 0 then
    return unavailable("invalid_configuration")
  end
  if not self.provider then
    return unavailable("not_configured")
  end
  return self:health()
end

function Adapter:health()
  if #self.configuration_errors > 0 then
    return unavailable("invalid_configuration")
  end
  if not self.provider then
    return unavailable("not_configured")
  end
  local ok, result = pcall(self.provider.health, self.provider)
  if not ok or type(result) ~= "table" then
    return unavailable("request_failed")
  end
  return result
end

function Adapter:connect()
  return self:_call("connect")
end

function Adapter:disconnect()
  return self:_call("disconnect")
end

function Adapter:resolve(query)
  assert(type(query) == "string" and query ~= "", "track query is required")
  return self:_call("resolve", query)
end

function Adapter:play(player, track)
  assert(type(player) == "table", "player is required")
  assert(type(track) == "table", "track is required")
  return self:_call("play", player, track)
end

function Adapter:stop(player)
  assert(type(player) == "table", "player is required")
  return self:_call("stop", player)
end

function Adapter:start(user_id, on_event)
  return self:_call("start", user_id, on_event)
end

function Adapter:resolve(query)
  return self:_call("resolve", query)
end

function Adapter:update_player(guild_id, payload)
  return self:_call("update_player", guild_id, payload)
end

function Adapter:destroy_player(guild_id)
  return self:_call("destroy_player", guild_id)
end

function Adapter:stop_player(guild_id)
  return self:_call("stop_player", guild_id)
end

function Adapter:_call(method, ...)
  if #self.configuration_errors > 0 then
    return false, "invalid_configuration"
  end
  if not self.provider or type(self.provider[method]) ~= "function" then
    return false, "not_configured"
  end
  local ok, first, second = pcall(self.provider[method], self.provider, ...)
  if not ok then
    return false, "provider_failed"
  end
  return first, second
end

return Adapter
