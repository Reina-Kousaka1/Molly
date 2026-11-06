local Smoke = {}
local Response = require("src.discord.response")
local Personality = require("src.personality")

local function runtime_label()
  local parts = { _VERSION or "Lua runtime unavailable" }
  local jit_runtime = rawget(_G, "jit")
  if type(jit_runtime) == "table" and type(jit_runtime.version) == "string" then
    parts[#parts + 1] = jit_runtime.version
  end
  return table.concat(parts, " · ")
end

local function clock_ms(clock)
  if type(clock) == "function" then
    local value = clock()
    if type(value) == "number" then return value end
  end
  return nil
end

local function rounded_ms(value)
  return math.max(0, math.floor(value + 0.5))
end

function Smoke.register(router, app, options)
  options = options or {}
  router:register({
    name = "ping",
    description = "Checks whether Molly can respond",
    execute = function(context)
      local started = clock_ms(options.clock)
      if started and Response.acknowledge(context) then
        local elapsed = rounded_ms(clock_ms(options.clock) - started)
        context:edit("🏓 Pong! " .. elapsed .. " ms")
      else
        -- Keep a working initial response if this context lacks the library
        -- REST primitives needed for a measured deferred acknowledgment.
        context:respond("🏓 Pong! Response latency unavailable")
      end
    end,
  })

  router:register({
    name = "about",
    category = "Information",
    description = "Meet KiddyyMolly and see what she can do",
    prefix = { arguments = {} },
    execute = function(context)
      local version = tostring(options.version or "1.2"):sub(1, 32)
      local description = Personality.about()
      Response.set_embed(context, {
        kind = "info",
        title = "KiddyyMolly 🎀",
        description = description,
        fields = {
          { name = "What I do ✨", value = "Moderation and server administration · staff tools · welcome, AFK, logs, roles, and voice rooms" },
          { name = "Molly Coins & shopping 💗", value = "Earn and manage in-server Molly Coins, browse the virtual shop, and manage inventory and fashion. Retail catalog entries are fictional; Molly is independent and not affiliated with Sephora, lululemon, Pandora, or other brands. No real goods or purchases are offered." },
          { name = "Music 🎧", value = "Lavalink-powered playback, queues, and music controls when the configured music service is available." },
          { name = "Version & runtime 🛠️", value = "Molly " .. version .. " · " .. runtime_label() },
          { name = "Project 📎", value = "Open-source project · AGPL-3.0\nhttps://github.com/Reina-Kousaka1/Molly" },
        },
      })
      context:respond(description)
    end,
  })

  router:register({
    name = "health",
    description = "Shows non-sensitive technical health",
    execute = function(context)
      if not Response.acknowledge(context) then
        context:respond("Molly Health\nStatus: Temporarily unavailable")
        return
      end
      local ok, snapshot = pcall(app.health_snapshot, app)
      local message = ok and require("src.health").message(snapshot)
        or "Molly Health\nStatus: Degraded\nHealth details unavailable"
      context:edit(message)
    end,
  })
end

return Smoke
