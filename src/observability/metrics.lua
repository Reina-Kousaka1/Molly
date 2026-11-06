local Metrics = {}
Metrics.__index = Metrics
Metrics.MAX_COMMANDS = 128

local function safe_clock(clock)
  local ok, value = pcall(clock)
  if ok and type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge then return value end
end

local function valid_command(value)
  return type(value) == "string" and #value > 0 and #value <= 64 and value:match("^[%w%-_]+$") ~= nil
end

local function copy_entry(value)
  return { calls = value.calls, succeeded = value.succeeded, denied = value.denied,
    failed = value.failed, duration_ms = value.duration_ms, max_duration_ms = value.max_duration_ms }
end

function Metrics.new(options)
  options = options or {}
  return setmetatable({ clock = options.clock or function() return os.clock() * 1000 end,
    max_commands = math.max(1, math.min(Metrics.MAX_COMMANDS, math.floor(options.max_commands or Metrics.MAX_COMMANDS))),
    started_at = nil, totals = { calls = 0, succeeded = 0, denied = 0, failed = 0, duration_ms = 0 },
    commands = {} }, Metrics)
end

function Metrics:start()
  local now = safe_clock(self.clock)
  if self.started_at == nil then self.started_at = now end
  return now
end

function Metrics:record(command, outcome, started_at)
  if outcome ~= "succeeded" and outcome ~= "denied" and outcome ~= "failed" then outcome = "failed" end
  local name = valid_command(command) and command or "other"
  if not self.commands[name] then
    local count = 0; for _ in pairs(self.commands) do count = count + 1 end
    if count >= self.max_commands then
      name = self.commands.other and "other" or nil
    end
    if name and not self.commands[name] then
      self.commands[name] = { calls = 0, succeeded = 0, denied = 0, failed = 0,
        duration_ms = 0, max_duration_ms = 0 }
    end
  end
  local now = safe_clock(self.clock)
  if self.started_at == nil then self.started_at = type(started_at) == "number" and started_at or now end
  local elapsed = 0
  if type(started_at) == "number" and type(now) == "number" and now >= started_at then
    elapsed = math.min(600000, math.floor(now - started_at + 0.5))
  end
  local row = name and self.commands[name]
  if row then
    row.calls, row[outcome], row.duration_ms = row.calls + 1, row[outcome] + 1, row.duration_ms + elapsed
    row.max_duration_ms = math.max(row.max_duration_ms, elapsed)
  end
  self.totals.calls, self.totals[outcome], self.totals.duration_ms =
    self.totals.calls + 1, self.totals[outcome] + 1, self.totals.duration_ms + elapsed
  return true
end

function Metrics:snapshot()
  local now = safe_clock(self.clock)
  local uptime = 0
  if type(now) == "number" and type(self.started_at) == "number" and now >= self.started_at then
    uptime = math.min(3153600000, math.floor(now - self.started_at))
  end
  local rows = {}
  for name, values in pairs(self.commands) do rows[#rows + 1] = { name = name, metrics = copy_entry(values) } end
  table.sort(rows, function(a, b) return a.name < b.name end)
  local totals = copy_entry(self.totals)
  return { uptime_ms = uptime, totals = totals, commands = rows, command_count = #rows }
end

return Metrics
