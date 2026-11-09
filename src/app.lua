local Status = require("src.status")
local Health = require("src.health")

local App = {}
App.__index = App

function App.new(options)
  assert(type(options) == "table", "options are required")
  assert(options.logger, "logger is required")
  assert(options.persistence or options.seaworld, "persistence client is required")

  return setmetatable({
    logger = options.logger,
    seaworld = options.seaworld,
    persistence = options.persistence or options.seaworld,
    persistence_backend = options.persistence_backend or "seaworld",
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
    persistence_backend = self.persistence_backend,
    persistence_configured = self.persistence:get_state().detail ~= "not_configured",
  })
end

function App:on_ready()
  self.discord_connected = true
  self.logger:info("discord_ready", { status = "connected" })
  local state = self.persistence:check()
  self.logger:info("persistence_health_checked", {
    backend = self.persistence_backend,
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
  local ok, persistence_state = pcall(self.persistence.health, self.persistence)
  if not ok or type(persistence_state) ~= "table" then
    persistence_state = { status = "unavailable" }
  end
  return Health.snapshot({
    running = self.running,
    started_at = self.started_at,
    now = os.time(),
    runtime = _VERSION,
    discord_connected = self.discord_connected,
    seaworld = self.persistence_backend == "seaworld" and persistence_state or { status = "not_active" },
    persistence = persistence_state,
    persistence_backend = self.persistence_backend,
    music = self.music_state,
  })
end

function App:shutdown(signal)
  if self.shutting_down then
    return false
  end
  self.shutting_down = true
  self.running = false
  if type(self.persistence.close) == "function" then self.persistence:close() end
  self.logger:info("shutdown_requested", { signal = signal or "unknown" })
  return true
end

return App
