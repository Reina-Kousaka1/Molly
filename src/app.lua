local Status = require("src.status")
local Health = require("src.health")

local App = {}
App.__index = App

function App.new(options)
  assert(type(options) == "table", "options are required")
  assert(options.logger, "logger is required")
  assert(options.seaworld, "seaworld client is required")

  return setmetatable({
    logger = options.logger,
    seaworld = options.seaworld,
    music = options.music,
    music_state = { status = "unavailable", detail = "not_configured" },
    running = false,
    discord_connected = false,
    shutting_down = false,
  }, App)
end

function App:start()
  self.running = true
  self.started_at = os.time()
  self.logger:info("molly_starting", {
    seaworld_configured = self.seaworld:get_state().detail ~= "not_configured",
  })
end

function App:on_ready()
  self.discord_connected = true
  self.logger:info("discord_ready", { status = "connected" })
  local state = self.seaworld:check()
  self.logger:info("seaworld_health_checked", {
    status = state.status,
    detail = state.detail,
  })
  if self.music then
    self.music_state = self.music:health()
    self.logger:info("music_health_checked", {
      status = self.music_state.status,
      detail = self.music_state.detail,
    })
  end
end

function App:on_disconnect()
  self.discord_connected = false
  self.logger:warn("discord_disconnected", { status = "unavailable" })
end

function App:on_reconnect()
  self.logger:info("discord_reconnect_requested", { status = "connecting" })
end

function App:health_message()
  return Health.message(self:health_snapshot())
end

-- Return a Discord-independent snapshot so a future container probe can use
-- the same checks without constructing or dispatching a Discord command.
function App:health_snapshot()
  local ok, sea_state = pcall(self.seaworld.health, self.seaworld)
  if not ok or type(sea_state) ~= "table" then
    sea_state = { status = "unavailable" }
  end
  return Health.snapshot({
    running = self.running,
    started_at = self.started_at,
    now = os.time(),
    runtime = _VERSION,
    discord_connected = self.discord_connected,
    seaworld = sea_state,
    music = self.music_state,
  })
end

function App:shutdown(signal)
  if self.shutting_down then
    return false
  end
  self.shutting_down = true
  self.running = false
  if type(self.seaworld.close) == "function" then self.seaworld:close() end
  self.logger:info("shutdown_requested", { signal = signal or "unknown" })
  return true
end

return App
