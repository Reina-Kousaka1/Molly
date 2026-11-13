local Images = require("src.personality.discord_images")
local Transport = require("src.personality.discord_image_transport")

local function run_in_coroutine(fn)
  local thread = coroutine.create(fn)
  local resumed, result, err = coroutine.resume(thread)
  assert(resumed, tostring(result))
  assert(coroutine.status(thread) == "dead", "mock downloader must not yield")
  return result, err
end

local function fixture(options)
  options = options or {}
  local timer = { closed = false }
  function timer:start(timeout, repeat_ms, callback)
    self.timeout, self.callback = timeout, callback
    return 0
  end
  function timer:stop() self.stopped = true end
  function timer:close() self.closed = true end
  function timer:is_closing() return self.closed end

  local response = options.response
  if not response then
    response = { code = 200, { "Content-Type", options.content_type or "image/png" } }
    if options.content_length ~= false then
      response[#response + 1] = { "Content-Length", options.content_length or "8" }
    end
  end
  local chunks = options.chunks or { "12345678" }
  local read_index, connection_count = 0, 0
  local connection = {
    socket = { closed = false },
    writes = {},
  }
  function connection.socket:close() self.closed = true end
  function connection.write(value)
    if value ~= nil then
      connection.writes[#connection.writes + 1] = value
    else
      connection.closed = true
    end
  end
  function connection.read()
    read_index = read_index + 1
    if read_index == 1 then return response end
    if options.timeout and read_index == 2 then
      timer.callback()
      return nil
    end
    local chunk = chunks[read_index - 1]
    if chunk ~= nil then return chunk end
    return ""
  end

  local client = {}
  function client.connect(connect_options)
    connection_count = connection_count + 1
    client.host, client.port = connect_options.host, connect_options.port
    client.tls, client.timeout = connect_options.tls, connect_options.timeout
    client.has_encoder = type(connect_options.encoder) == "function"
    client.has_decoder = type(connect_options.decoder) == "function"
    return connection.read, connection.write, connection.socket
  end
  local uv = { new_timer = function() return timer end }
  local codec = {
    encoder = function() return function() end end,
    decoder = function() return function() end end,
  }
  return Transport.new({ net = client, http_codec = codec, uv = uv }), client, connection, timer,
    function() return connection_count end
end

assert(Images.valid_url("https://cdn.discordapp.com/attachments/123/456/image.png?ex=test"))
assert(Transport.parse_url("https://cdn.discordapp.com/attachments/123/456/image.png?ex=test")
  == "/attachments/123/456/image.png?ex=test")
for _, url in ipairs({
  "http://cdn.discordapp.com/attachments/123/456/image.png",
  "https://cdn.discordapp.com.evil.test/attachments/123/456/image.png",
  "https://cdn.discordapp.com/avatars/123/image.png",
}) do
  assert(Transport.parse_url(url) == nil, "transport must reject unsafe host or path")
end

local downloader, client, connection, timer = fixture()
local result, err = run_in_coroutine(function()
  return downloader.download(
    "https://cdn.discordapp.com/attachments/123/456/image.png?ex=test",
    { max_bytes = 1024, timeout_ms = 2000, expected_mime = "image/png" })
end)
assert(result and result.body == "12345678" and result.content_type == "image/png", tostring(err))
assert(client.host == "cdn.discordapp.com" and client.port == 443 and client.tls == true)
assert(client.timeout == 2000, "connection timeout must be bounded")
assert(client.has_encoder and client.has_decoder, "the real Luvit HTTP codecs must be attached")
assert(connection.writes[1].method == "GET")
assert(connection.writes[1].path == "/attachments/123/456/image.png?ex=test")
assert(connection.socket.closed and timer.closed, "successful downloads close their resources")

local count
downloader, client, connection, timer, count = fixture()
result, err = run_in_coroutine(function()
  return downloader.download("https://cdn.discordapp.com.evil.test/attachments/1/2/a.png", {})
end)
assert(result == nil and err == "invalid_image_url" and count() == 0,
  "invalid URLs fail before opening a connection")

downloader = fixture({ content_length = "2048" })
result, err = run_in_coroutine(function()
  return downloader.download("https://cdn.discordapp.com/attachments/1/2/a.png",
    { max_bytes = 1024 })
end)
assert(result == nil and err == "image_too_large", "oversized declared bodies are rejected early")

downloader = fixture({ content_length = false, chunks = { string.rep("a", 600), string.rep("b", 500) } })
result, err = run_in_coroutine(function()
  return downloader.download("https://cdn.discordapp.com/attachments/1/2/a.png",
    { max_bytes = 1024 })
end)
assert(result == nil and err == "image_too_large", "streamed bodies are stopped at the byte cap")

downloader = fixture({ timeout = true })
result, err = run_in_coroutine(function()
  return downloader.download("https://cdn.discordapp.com/attachments/1/2/a.png",
    { timeout_ms = 8000 })
end)
assert(result == nil and err == "timeout", "the response deadline closes and reports timeouts")

downloader = fixture({ content_type = "image/gif" })
result, err = run_in_coroutine(function()
  return downloader.download("https://cdn.discordapp.com/attachments/1/2/a.png",
    { expected_mime = "image/png" })
end)
assert(result == nil and err == "invalid_content_type", "unsupported response media types are rejected")

downloader = fixture({ response = { code = 302, { "Location", "https://127.0.0.1/private" } } })
result, err = run_in_coroutine(function()
  return downloader.download("https://cdn.discordapp.com/attachments/1/2/a.png", {})
end)
assert(result == nil and err == "http_error", "redirects are not followed")

print("personality image transport: allowlist, TLS target, byte caps, MIME, timeout and redirect policy passed")
