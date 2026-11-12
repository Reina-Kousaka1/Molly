-- Unit tests for the Luvit-only Ollama transport
-- (src/personality/luvit_transport.lua). coro-net, http-codec and uv are
-- stubbed with in-memory fakes, so no Luvit runtime or network access is
-- needed; the fakes drive the exact code paths the real modules would.
package.path = "./?.lua;./?/init.lua;" .. package.path

local failures = 0
local function check(name, condition)
  if condition then
    io.write("ok - " .. name .. "\n")
  else
    failures = failures + 1
    io.write("not ok - " .. name .. "\n")
  end
end

local fake_uv = {}
local last_timer
function fake_uv.new_timer()
  local timer = {}
  function timer:start(ms, _repeat, cb)
    self.ms = ms
    self.cb = cb
    last_timer = self
  end
  function timer:stop() self.stopped = true end
  function timer:is_closing() return self.closed == true end
  function timer:close() self.closed = true end
  return timer
end

local scenario = { script = {}, connect_ok = true, fire_timer_on_first_read = false }
local requests

local function fake_connect(_options)
  if not scenario.connect_ok then return nil end
  local step = 0
  requests = {}
  local socket = {
    closed = false,
    close = function(self) self.closed = true end,
    is_closing = function(self) return self.closed end,
  }
  local function read()
    step = step + 1
    if scenario.fire_timer_on_first_read and step == 1 and last_timer and last_timer.cb then
      last_timer.cb()
    end
    return scenario.script[step]
  end
  local function write(data)
    requests[#requests + 1] = data
    return true
  end
  return read, write, socket
end

package.loaded["coro-net"] = { connect = fake_connect }
package.loaded["http-codec"] = { encoder = { fake = true }, decoder = { fake = true } }
package.loaded["uv"] = fake_uv

local Transport = require("src.personality.luvit_transport")

-- A. happy path with content-length
scenario = { connect_ok = true,
  script = {
    { code = 200, { "Content-Length", "5" } },
    "he", "llo",
  },
}
local response, body = Transport.request("POST", "http://127.0.0.1:11434/api/chat", {
  timeout_ms = 1000,
  headers = { ["Content-Type"] = "application/json" },
  body = "{}",
  max_response_bytes = 1024,
})
check("happy path returns status and body", response ~= nil and response.code == 200 and body == "hello")
check("request line carries method and path", requests[1].method == "POST" and requests[1].path == "/api/chat")
local names = {}
for _, pair in ipairs(requests[1]) do names[tostring(pair[1]):lower()] = pair[2] end
check("host header is added", names["host"] == "127.0.0.1:11434")
check("connection close is forced", names["connection"] == "close")
check("content-length matches body", names["content-length"] == "2")
check("content-type is passed through", names["content-type"] == "application/json")
check("raw body is written", requests[2] == "{}")

-- B. declared content-length beyond the configured bound
scenario = { connect_ok = true,
  script = { { code = 200, { "Content-Length", "99999" } }, "never-read" },
}
local result, err = Transport.request("GET", "http://127.0.0.1:11434/api/version", {
  timeout_ms = 1000, max_response_bytes = 1024,
})
check("oversized declared length is rejected", result == nil and err == "response_too_large")

-- C. streaming body beyond the configured bound (no content-length)
scenario = { connect_ok = true,
  script = {
    { code = 200, {} },
    string.rep("a", 600), string.rep("b", 600),
  },
}
result, err = Transport.request("GET", "http://127.0.0.1:11434/api/chat", {
  timeout_ms = 1000, max_response_bytes = 1024,
})
check("oversized streamed body is rejected", result == nil and err == "response_too_large")

-- D. header block beyond the 16 KiB cap
local big_headers = { code = 200 }
for i = 1, 200 do big_headers[#big_headers + 1] = { "X-Pad-" .. i, string.rep("v", 100) } end
scenario = { connect_ok = true, script = { big_headers } }
result, err = Transport.request("GET", "http://127.0.0.1:11434/", {
  timeout_ms = 1000, max_response_bytes = 1024 * 1024,
})
check("oversized header block is rejected", result == nil and err == "response_too_large")

-- E. timeout: the fake server dies and the timer fires
scenario = { script = {}, connect_ok = true, fire_timer_on_first_read = true }
result, err = Transport.request("POST", "http://127.0.0.1:11434/api/chat", {
  timeout_ms = 5, max_response_bytes = 1024, body = "{}",
})
check("a timed-out request reports timeout", result == nil and err == "timeout")

-- F. connection refused
scenario = { script = {}, connect_ok = false }
result, err = Transport.request("GET", "http://127.0.0.1:11434/api/version", {
  timeout_ms = 1000, max_response_bytes = 1024,
})
check("connection failure is reported", result == nil and err == "connection_failed")

-- G. non-2xx status is returned to the adapter, not fatal at transport level
scenario = { connect_ok = true,
  script = {
    { code = 500, { "Content-Length", "2" } },
    "{}",
  },
}
response, body = Transport.request("GET", "http://127.0.0.1:11434/api/chat", {
  timeout_ms = 1000, max_response_bytes = 1024,
})
check("http 500 reaches the adapter", response ~= nil and response.code == 500 and body == "{}")

-- H. content-length mismatch is detected
scenario = { connect_ok = true,
  script = {
    { code = 200, { "Content-Length", "10" } },
    "short",
  },
}
result, err = Transport.request("GET", "http://127.0.0.1:11434/", {
  timeout_ms = 1000, max_response_bytes = 1024,
})
check("content-length mismatch is rejected", result == nil and err == "invalid_response")

-- I. https URLs are refused (http only, like the PreppyDB transport)
result, err = Transport.request("GET", "https://127.0.0.1:11434/api/version", {
  timeout_ms = 1000, max_response_bytes = 1024,
})
check("https is refused by the built-in transport", result == nil and err == "request_failed")

io.write(failures == 0 and "personality luvit transport: pass\n" or ("personality luvit transport: " .. failures .. " failures\n"))
os.exit(failures == 0 and 0 or 1)
