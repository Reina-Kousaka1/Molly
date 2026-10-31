local Health = {}

local function component(status)
  return { status = status }
end

function Health.snapshot(input)
  input = input or {}
  local runtime_ok = type(input.runtime) == "string" and input.runtime ~= ""
  local process_ok = input.running == true
  local seaworld_status = type(input.seaworld) == "table" and input.seaworld.status or "unavailable"
  local sea_ok = seaworld_status == "healthy"
  local uptime = 0
  if type(input.started_at) == "number" and type(input.now) == "number" then
    uptime = math.max(0, math.floor(input.now - input.started_at))
  end

  return {
    status = process_ok and runtime_ok and input.discord_connected == true and sea_ok and "healthy" or "degraded",
    process = component(process_ok and "healthy" or "unavailable"),
    runtime = component(runtime_ok and "healthy" or "unavailable"),
    discord = component(input.discord_connected == true and "healthy" or "unavailable"),
    seaworld = component(sea_ok and "healthy" or "unavailable"),
    persistence = component(sea_ok and "healthy" or "degraded"),
    api_version = sea_ok and input.seaworld.api_version or nil,
    capabilities = sea_ok and input.seaworld.capabilities or nil,
    music = type(input.music) == "table" and input.music.status or "unavailable",
    uptime_seconds = uptime,
  }
end

local function title(value)
  return value:sub(1, 1):upper() .. value:sub(2)
end

local function uptime_text(seconds)
  local days = math.floor(seconds / 86400)
  local hours = math.floor((seconds % 86400) / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  local parts = {}
  if days > 0 then parts[#parts + 1] = days .. "d" end
  if hours > 0 or days > 0 then parts[#parts + 1] = hours .. "h" end
  parts[#parts + 1] = minutes .. "m"
  return table.concat(parts, " ")
end

function Health.message(snapshot)
  local seaworld = title(snapshot.seaworld.status)
  if snapshot.seaworld.status == "healthy" and type(snapshot.api_version) == "string" then
    seaworld = seaworld .. " (API " .. snapshot.api_version .. ")"
  end
  return table.concat({
    "Molly Health — " .. title(snapshot.status),
    "Process: " .. title(snapshot.process.status),
    "Runtime: " .. title(snapshot.runtime.status),
    "Discord: " .. title(snapshot.discord.status),
    "SeaWorld: " .. seaworld,
    "Persistence: " .. title(snapshot.persistence.status),
    "Music: " .. snapshot.music,
    "Uptime: " .. uptime_text(snapshot.uptime_seconds),
  }, "\n")
end

return Health
