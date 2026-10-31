package.path = "./?.lua;./?/init.lua;" .. package.path

local state = { timer_start_count = 0 }
package.preload["coro-net"] = function()
  return {
    connect = function(options)
      assert(state.timer_start_count == 1, "overall timer must start before connecting")
      assert(options.timeout == state.timer_timeout, "connect must use the same call timeout")
      state.connect_called = true
      state.timer_callback()
      return nil, "transport_unavailable"
    end,
  }
end
package.preload.json = function()
  return { null = {}, encode = function() return "{}" end }
end
package.preload.uv = function()
  return {
    new_timer = function()
      local timer = { closed = false }
      function timer:start(timeout, _, callback)
        state.timer_start_count = state.timer_start_count + 1
        state.timer_timeout = timeout
        state.timer_callback = callback
      end
      function timer:stop() state.timer_stopped = true end
      function timer:is_closing() return self.closed end
      function timer:close() self.closed = true end
      return timer
    end,
  }
end

local Driver = require("src.seaworld.socket_driver")
local driver = Driver.new({ path = "/tmp/molly-fixture.sock", timeout_ms = 250 })
local ok, reason = driver:_call("health", {}, false)
assert(not ok and reason == "timeout", "connect time must count toward the call timeout")
assert(state.connect_called and state.timer_start_count == 1)
assert(state.timer_stopped and driver.busy == false)
io.stdout:write("PASS socket timeout includes connection establishment\n")
