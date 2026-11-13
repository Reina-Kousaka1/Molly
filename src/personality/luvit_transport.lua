-- Bounded, single-request HTTP transport for the Ollama adapter (Luvit only).
--
-- Deliberately mirrors src/preppydb/luvit_transport.lua: one socket per
-- request, no pooling, no redirects and no retries, so a timed-out local
-- write is never replayed behind the caller's back. Only plain http:// is
-- supported — Ollama is expected on loopback or a trusted private network.
-- For anything else, inject a different transport into Ollama.new.
--
-- Response bodies are bounded by options.max_response_bytes (headers capped at
-- 16 KiB); exceeding the bound fails the request instead of buffering.
--
-- Transport.request returns:
--   response = { code = number }, body = string   on HTTP response
--   nil, "timeout" | "response_too_large" | "connection_failed"
--       | "invalid_response" | "request_failed"   otherwise

local net = require("coro-net")
local codec = require("http-codec")
local uv = require("uv")

local Transport = {}
local MAX_RESPONSE_HEADERS = 16 * 1024

local function parse_url(url)
  local authority, path = tostring(url):match("^http://([^/]+)(/.*)$")
  if not authority then
    authority, path = tostring(url):match("^http://([^/]+)/?$")
    path = path or ""
  end
  if not authority then error("unsupported protocol (http only)", 0) end

  local host, port, host_header
  if authority:sub(1, 1) == "[" then
    local address, port_text = authority:match("^%[([^%]]+)%]:?(%d*)$")
    if not address then error("invalid authority", 0) end
    host = address
    port = port_text ~= "" and tonumber(port_text) or 80
    host_header = "[" .. address .. "]" .. (port ~= 80 and ":" .. port or "")
  else
    host, port = authority:match("^([^:]+):(%d+)$")
    if not host then host, port = authority, 80 else port = tonumber(port) end
    host_header = authority
  end
  if not host or host == "" or not port or port < 1 or port > 65535 then
    error("invalid authority", 0)
  end
  if path == "" then path = "/" end
  return host, port, host_header, path
end

local function response_headers(head)
  local headers, bytes = {}, 0
  for _, pair in ipairs(head) do
    local key, value = tostring(pair[1]), tostring(pair[2])
    bytes = bytes + #key + #value + 4
    if bytes > MAX_RESPONSE_HEADERS then error("response_too_large", 0) end
    headers[key:lower()] = value
  end
  return headers
end

function Transport.request(method, url, options)
  options = options or {}
  local timeout_ms = tonumber(options.timeout_ms) or 15000
  local max_response_bytes = tonumber(options.max_response_bytes) or (256 * 1024)

  local timed_out, socket, close_socket = false, nil, nil
  local timer = uv.new_timer()
  timer:start(timeout_ms, 0, function()
    timed_out = true
    if close_socket then
      -- coro-net's returned closer also wakes a coroutine blocked in read().
      -- Calling the raw uv socket close alone can leave that reader suspended
      -- forever, leaking a Discord bridge concurrency slot after timeout.
      pcall(close_socket)
    elseif socket and type(socket.close) == "function" and not socket:is_closing() then
      pcall(socket.close, socket)
    end
  end)

  local ok, code, body = pcall(function()
    local host, port, host_header, path = parse_url(url)
    local read, write, raw_socket, _update_decoder, _update_encoder, coro_close = net.connect({
      host = host,
      port = port,
      timeout = timeout_ms,
      encoder = codec.encoder,
      decoder = codec.decoder,
    })
    socket = raw_socket
    if not read or not write then error("connection_failed", 0) end
    if type(coro_close) == "function" then
      close_socket = coro_close
    elseif socket and type(socket.close) == "function" then
      close_socket = function()
        if not socket:is_closing() then socket:close() end
      end
    end
    if timed_out then error("timeout", 0) end

    local outgoing = { method = method, path = path }
    local has_host, has_length = false, false
    for key, value in pairs(options.headers or {}) do
      if type(key) == "number" and type(value) == "table" then
        value = { tostring(value[1]), tostring(value[2]) }
        local name = value[1]:lower()
        if name == "host" then has_host = true end
        if name == "content-length" then has_length = true end
        outgoing[#outgoing + 1] = value
      else
        local name = tostring(key):lower()
        if name == "host" then has_host = true end
        if name == "content-length" then has_length = true end
        if name ~= "connection" then
          outgoing[#outgoing + 1] = { tostring(key), tostring(value) }
        end
      end
    end
    if not has_host then outgoing[#outgoing + 1] = { "Host", host_header } end
    outgoing[#outgoing + 1] = { "Connection", "close" }
    if options.body and not has_length then
      outgoing[#outgoing + 1] = { "Content-Length", tostring(#options.body) }
    end

    write(outgoing)
    if options.body then write(options.body) end
    local head = read()
    if type(head) ~= "table" or type(head.code) ~= "number" then
      error("invalid_response", 0)
    end
    local headers = response_headers(head)
    local declared = headers["content-length"]
    if declared then
      if not declared:match("^%d+$") or tonumber(declared) > max_response_bytes then
        error("response_too_large", 0)
      end
    end

    local chunks, size = {}, 0
    while true do
      if timed_out then error("timeout", 0) end
      local chunk = read()
      if not chunk or #chunk == 0 then break end
      size = size + #chunk
      if size > max_response_bytes then error("response_too_large", 0) end
      chunks[#chunks + 1] = chunk
    end
    if declared and size ~= tonumber(declared) then error("invalid_response", 0) end
    return head.code, table.concat(chunks)
  end)

  if not timer:is_closing() then
    timer:stop()
    timer:close()
  end

  if timed_out then return nil, "timeout" end
  if not ok then
    local message = type(code) == "string" and code or "request_failed"
    if message == "connection_failed" then return nil, "connection_failed" end
    if message == "response_too_large" or message == "timeout" or message == "invalid_response" then
      return nil, message
    end
    return nil, "request_failed"
  end
  return { code = code }, body or ""
end

return Transport
