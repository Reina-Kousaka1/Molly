package.path = "./?.lua;./?/init.lua;./deps/?.lua;./deps/?/init.lua;" .. package.path
local json = require("json")
local Client = require("src.music.lavalink_client")

local total, failed = 0, 0
local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then io.stdout:write("ok - " .. name .. "\n")
  else failed = failed + 1; io.stderr:write("not ok - " .. name .. ": " .. tostring(err) .. "\n") end
end

test("Lavalink v4 search parses only real tracks and sends the authorization header", function()
  local captured
  local client = Client.new({ url = "http://127.0.0.1:2333", password = "fixture-only", transport = function(method, url, options)
    captured = { method = method, url = url, options = options }
    return { code = 200 }, json.encode({ loadType = "search", data = {
      { encoded = "encoded-track", info = { title = "A track", author = "An artist" } },
      { info = { title = "Malformed" } },
    } })
  end })
  local ok, tracks = client:resolve("a song & query")
  assert(ok); assert(#tracks == 1); assert(tracks[1].encoded == "encoded-track")
  assert(captured.method == "GET")
  assert(captured.url:find("/v4/loadtracks?identifier=ytsearch%3Aa%20song%20%26%20query", 1, true))
  assert(captured.options.headers.authorization == "fixture-only")
  assert(captured.options.timeout_ms == 1000)
end)

test("Spotify search prefixes pass through and authentication failures stay sanitized", function()
  local captured
  local client = Client.new({ url = "http://127.0.0.1:2333", password = "fixture-only", transport = function(method, url, options)
    captured = { method = method, url = url, options = options }
    return { code = 401 }, "credential details must not be surfaced"
  end })
  local ok, failure = client:resolve("spsearch:queen bohemian rhapsody")
  assert(not ok); assert(failure == "authentication_failed")
  assert(captured.url:find("identifier=spsearch%3A", 1, true))
  local health = client:health()
  assert(health.status == "unavailable" and health.detail == "authentication_failed")
end)

test("unsupported Lavalink search prefixes are rejected before transport", function()
  local requests = 0
  local client = Client.new({ url = "http://127.0.0.1:2333", password = "fixture-only", transport = function()
    requests = requests + 1
    return { code = 200 }, json.encode({ loadType = "empty", data = {} })
  end })
  local ok, reason = client:resolve("unsupportedsearch:query")
  assert(not ok and reason == "unsupported_search_prefix")
  assert(requests == 0)
end)

test("player updates use the READY session, guild route, voice payload, and v4 JSON", function()
  local captured
  local client = Client.new({ url = "http://127.0.0.1:2333", password = "fixture-only", transport = function(method, url, options)
    captured = { method = method, url = url, options = options }
    return { code = 204 }, ""
  end })
  client.session_id, client.ready = "lavalink-session", true
  local ok = client:update_player("123", { voice = { token = "voice", endpoint = "voice.example", sessionId = "discord-session", channelId = "456" }, volume = 1000 })
  assert(ok)
  assert(captured.method == "PATCH")
  assert(captured.url == "http://127.0.0.1:2333/v4/sessions/lavalink-session/players/123")
  assert(captured.options.headers["lavalink-session-id"] == "lavalink-session")
  local payload = json.decode(captured.options.body)
  assert(payload.voice.sessionId == "discord-session" and payload.voice.channelId == "456")
  assert(payload.volume == 1000)
end)

test("Lavalink session WebSocket sends the required identifying headers", function()
  local connect_options, events, reads = nil, {}, 0
  local socket = { is_closing = function() return false end, close = function() end }
  local websocket = {
    parseUrl = function(url)
      assert(url == "ws://127.0.0.1:2333/v4/websocket")
      return { host = "127.0.0.1", port = 2333, tls = false, pathname = "/v4/websocket" }
    end,
    connect = function(options)
      connect_options = options
      return { socket = socket }, function()
        reads = reads + 1
        if reads == 1 then return { payload = json.encode({ op = "ready", sessionId = "session-id", resumed = false }) } end
        return nil
      end, function() return true end
    end,
  }
  local client = Client.new({ url = "http://127.0.0.1:2333", password = "fixture-only", transport = function() end, websocket = websocket })
  client.stopping = true -- keep the fake read closure from scheduling a retry
  local ok = client:start("123456", function(event) events[#events + 1] = event end)
  assert(ok)
  assert(connect_options.timeout == 1000)
  local headers = {}
  for _, header in ipairs(connect_options.headers) do headers[header[1]] = header[2] end
  assert(headers.Authorization == "fixture-only")
  assert(headers["User-Id"] == "123456")
  assert(headers["Client-Name"] == "molly/1.0.0")
  assert(client.session_id == "session-id")
  assert(events[1].type == "ready" and events[2].type == "disconnected")
end)

io.stdout:write(string.format("%d tests, %d failures\n", total, failed))
os.exit(failed == 0 and 0 or 1)
