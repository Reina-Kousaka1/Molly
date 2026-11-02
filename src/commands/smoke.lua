local Smoke = {}
local Response = require("src.discord.response")
local Personality = require("src.personality")

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
    description = "Shows Molly bootstrap information",
    prefix = { arguments = {} },
    execute = function(context)
      context:respond(Personality.about())
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
