-- Bounded HTTPS download for Discord CDN image attachments only.
-- Uses the pinned Luvit coro-net TLS stack; no redirects, cookies,
-- arbitrary hosts or files are followed or persisted.
local net = require("coro-net")
local http_codec = require("http-codec")
local uv = require("uv")

local Transport = {}
local ALLOWED_HOST = "cdn.discordapp.com"
local MAX_URL_CHARS = 4096

local function parse_url(url)
  if type(url) ~= "string" or #url > MAX_URL_CHARS or url:find("[%z\1-\32\127]") then
    return nil
  end
  local host, path = url:match("^https://([^/?#]+)(/[^#]*)$")
  if host ~= ALLOWED_HOST or not path or path:sub(1, 13) ~= "/attachments/" then
    return nil
  end
  if path:find("\\", 1, true) or path:find("/../", 1, true) or path:find("/./", 1, true) then
    return nil
  end
  return path
end

local function response_header(response, name)
  local value
  for index = 1, #response do
    local pair = response[index]
    if type(pair) == "table" and type(pair[1]) == "string"
      and pair[1]:lower() == name then
      if value ~= nil then return nil, "duplicate_header" end
      value = pair[2]
    end
  end
  if value ~= nil and type(value) ~= "string" then return nil, "invalid_header" end
  return value
end

local function close_connection(connection)
  if type(connection) ~= "table" then return end
  if type(connection.write) == "function" then pcall(connection.write) end
  local socket = connection.socket
  if socket ~= nil then pcall(function() socket:close() end) end
end

local function canonical_image_type(value)
  if type(value) ~= "string" or #value > 100 then return nil end
  local mime = value:lower():match("^%s*([^;%s]+)")
  if mime == "image/jpeg" or mime == "image/png" or mime == "image/webp" then
    return mime
  end
  return nil
end

local function download(url, options, dependencies)
  options = type(options) == "table" and options or {}
  local path = parse_url(url)
  if not path then return nil, "invalid_image_url" end
  local timeout_ms = tonumber(options.timeout_ms) or 8000
  local max_bytes = tonumber(options.max_bytes) or (4 * 1024 * 1024)
  if timeout_ms % 1 ~= 0 or timeout_ms < 100 or timeout_ms > 30000
    or max_bytes % 1 ~= 0 or max_bytes < 1024 or max_bytes > 4 * 1024 * 1024 then
    return nil, "invalid_image_limits"
  end
  if options.expected_mime ~= nil and not canonical_image_type(options.expected_mime) then
    return nil, "invalid_content_type"
  end

  -- Lua 5.1/LuaJIT return nil from coroutine.running() on the main thread.
  if not coroutine.running() then return nil, "coroutine_required" end

  dependencies = dependencies or {}
  local client = dependencies.net or net
  local codec = dependencies.http_codec or http_codec
  local timer_api = dependencies.uv or uv
  if type(client) ~= "table" or type(client.connect) ~= "function"
    or type(codec) ~= "table" or type(codec.encoder) ~= "function"
    or type(codec.decoder) ~= "function"
    or type(timer_api) ~= "table" or type(timer_api.new_timer) ~= "function" then
    return nil, "transport_unavailable"
  end

  -- The host and port are constants. User-controlled URL data is used only as
  -- the validated attachment path, so this cannot become an SSRF primitive.
  local connected, read, write, socket = pcall(client.connect, {
    host = ALLOWED_HOST,
    port = 443,
    tls = true,
    timeout = timeout_ms,
    encoder = codec.encoder,
    decoder = codec.decoder,
  })
  if not connected or type(read) ~= "function" or type(write) ~= "function" then
    return nil, "connection_failed"
  end
  local connection = { read = read, write = write, socket = socket }

  local timer_ok, timer = pcall(timer_api.new_timer)
  if not timer_ok or not timer then
    close_connection(connection)
    return nil, "timeout_unavailable"
  end

  local timed_out = false
  local started = pcall(timer.start, timer, timeout_ms, 0, function()
    timed_out = true
    close_connection(connection)
  end)
  if not started then
    pcall(timer.close, timer)
    close_connection(connection)
    return nil, "timeout_unavailable"
  end

  local function request_image()
    connection.write({
      method = "GET",
      path = path,
      { "Host", ALLOWED_HOST },
      { "Accept", "image/jpeg, image/png, image/webp" },
      { "Accept-Encoding", "identity" },
      { "Connection", "close" },
    })

    local response, read_error = connection.read()
    if type(response) ~= "table" then
      return nil, timed_out and "timeout" or (read_error and "connection_failed" or "invalid_response")
    end
    if tonumber(response.code) ~= 200 then return nil, "http_error" end

    local content_type, content_type_error = response_header(response, "content-type")
    local content_encoding, encoding_error = response_header(response, "content-encoding")
    local content_length, length_error = response_header(response, "content-length")
    if content_type_error or encoding_error or length_error then return nil, "invalid_response" end
    if content_encoding and content_encoding:lower() ~= "identity" then
      return nil, "unsupported_content_encoding"
    end
    local response_mime = canonical_image_type(content_type)
    if not response_mime or (options.expected_mime and response_mime ~= options.expected_mime) then
      return nil, "invalid_content_type"
    end

    local declared_size
    if content_length ~= nil then
      if not content_length:match("^%d+$") then return nil, "invalid_response" end
      declared_size = tonumber(content_length)
      if not declared_size or declared_size < 1 then return nil, "invalid_response" end
      if declared_size > max_bytes then return nil, "image_too_large" end
    end

    local chunks, size = {}, 0
    while true do
      local chunk, body_error = connection.read()
      if chunk == nil then
        return nil, timed_out and "timeout" or (body_error and "connection_failed" or "invalid_response")
      end
      if type(chunk) ~= "string" then return nil, "invalid_response" end
      if #chunk == 0 then break end
      size = size + #chunk
      if size > max_bytes then return nil, "image_too_large" end
      chunks[#chunks + 1] = chunk
    end
    if size < 1 or (declared_size and size ~= declared_size) then return nil, "invalid_response" end
    return { body = table.concat(chunks), content_type = content_type }
  end

  local called, result, request_error = pcall(request_image)
  pcall(timer.stop, timer)
  pcall(timer.close, timer)
  close_connection(connection)
  if not called then return nil, timed_out and "timeout" or "request_failed" end
  if result == nil then return nil, request_error end
  return result
end

function Transport.new(dependencies)
  return {
    download = function(url, options)
      return download(url, options, dependencies)
    end,
  }
end

Transport.download = Transport.new().download
Transport.parse_url = parse_url
return Transport
