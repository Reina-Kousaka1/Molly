local Seasonal = require("src.seasonal")

local Rotation = {}
Rotation.__index = Rotation
Rotation.interval_ms = 120000

function Rotation.new(options)
  assert(options and options.write and options.schedule and options.cancel, "presence dependencies required")
  return setmetatable({
    write = options.write,
    schedule = options.schedule,
    cancel = options.cancel,
    logger = options.logger,
    clock = options.clock or os.time,
    interval_ms = options.interval_ms or Rotation.interval_ms,
    index = 0,
    season_id = nil,
    current_text = nil,
    handle = nil,
    running = false,
  }, Rotation)
end

function Rotation:tick()
  if not self.running then return false end
  local ok, config = pcall(Seasonal.current, self.clock())
  if not ok then
    if self.logger then self.logger:error("presence_selection_failed", { detail = "season_unavailable" }) end
    return false
  end
  if config.id ~= self.season_id then
    self.season_id, self.index = config.id, 0
  end
  self.index = self.index % #config.presence + 1
  local write_ok, result, reason = pcall(self.write, config.presence[self.index])
  local accepted = write_ok and result ~= false
  if accepted then self.current_text = config.presence[self.index] end
  if self.logger then
    if accepted then
      self.logger:info("presence_update", { season = config.id, index = self.index })
    else
      self.logger:warn("presence_update_failed", {
        season = config.id,
        detail = write_ok and (reason or "gateway_rejected") or "gateway_error",
      })
    end
  end
  return accepted
end

function Rotation:get_current()
  return self.current_text
end

function Rotation:start()
  if self.running then
    -- READY can fire again after a gateway reconnect. Re-apply once without
    -- creating another timer, since Discord may have reset session presence.
    self:tick()
    return false
  end
  self.running = true
  self:tick()
  local ok, handle = pcall(self.schedule, self.interval_ms, function() self:tick() end)
  if not ok then
    self.running = false
    if self.logger then self.logger:error("presence_timer_failed", { detail = "scheduler_error" }) end
    return false
  end
  self.handle = handle
  return true
end

function Rotation:stop()
  if not self.running then return false end
  self.running = false
  if self.handle then
    pcall(self.cancel, self.handle)
    self.handle = nil
  end
  return true
end

return Rotation
