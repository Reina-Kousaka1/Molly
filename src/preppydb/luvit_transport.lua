-- One bounded HTTP request per socket for the PreppyDB client.
--
-- `coro-http` pools sockets and may resend a request when a reused socket closes.
-- That retry is unsafe when a transaction may already have committed, so this
-- adapter uses Luvit's lower-level stream modules and never retries or redirects.
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
  if not authority then error("unsupported PreppyDB transport URL", 0) end

  local host, port, host_header
  if authority:sub(1, 1) == "[" then
    local address, port_text = authority:match("^%[([^%]]+)%]:?(%d*)$")
    if not address then error("invalid PreppyDB transport authority", 0) end
    host = address
    port = port_text ~= "" and tonumber(port_text) or 80
    host_header = "[" .. address .. "]" .. (port ~= 80 and ":" .. port or "")
  else
    host, port = authority:match("^([^:]+):(%d+)$")
    if not host then host, port = authority, 80 else port = tonumber(port) end
    host_header = authority
  end
  if not host or host == "" or not port or port < 1 or port > 65535 then
    error("invalid PreppyDB transport authority", 0)
  end
  if path == "" then path = "/" end
  return host, port, host_header, path
end

local function response_headers(head)
  local headers, bytes = {}, 0
  for _, pair in ipairs(head) do
    local key, value = tostring(pair[1]), tostring(pair[2])
    bytes = bytes + #key + #value + 4
    if bytes > MAX_RESPONSE_HEADERS then error("response headers exceed configured limit", 0) end
    headers[key:lower()] = value
  end
  return headers
end

local function perform(request, socket_ready)
  local host, port, host_header, path = parse_url(request.url)
  local read, write, socket = net.connect({
    host = host,
    port = port,
    timeout = request.timeout_ms,
    encoder = codec.encoder,
    decoder = codec.decoder,
  })
  if not read or not write or not socket then error("connection failed", 0) end
  socket_ready(socket)

  local outgoing = { method = request.method, path = path }
  local has_host, has_length = false, false
  for key, value in pairs(request.headers or {}) do
    local normalized = tostring(key):lower()
    if normalized == "host" then has_host = true end
    if normalized == "content-length" then has_length = true end
    if normalized ~= "connection" then
      outgoing[#outgoing + 1] = { tostring(key), tostring(value) }
    end
  end
  if not has_host then outgoing[#outgoing + 1] = { "Host", host_header } end
  outgoing[#outgoing + 1] = { "Connection", "close" }
  if request.body and not has_length then
    outgoing[#outgoing + 1] = { "Content-Length", tostring(#request.body) }
  end

  write(outgoing)
  if request.body then write(request.body) end
  local head = read()
  if type(head) ~= "table" or type(head.code) ~= "number" then
    error("invalid HTTP response", 0)
  end
  local headers = response_headers(head)
  local declared = headers["content-length"]
  if declared then
    if not declared:match("^%d+$") or tonumber(declared) > request.max_response_bytes then
      error("invalid or oversized response length", 0)
    end
  end

  local chunks, size = {}, 0
  while true do
    local chunk = read()
    if not chunk or #chunk == 0 then break end
    size = size + #chunk
    if size > request.max_response_bytes then error("response exceeds configured limit", 0) end
    chunks[#chunks + 1] = chunk
  end
  if declared and size ~= tonumber(declared) then error("response length mismatch", 0) end
  return head.code, table.concat(chunks), headers
end

function Transport.request(request, callback)
  local completed, socket = false, nil
  local timer = uv.new_timer()

  local function close_socket()
    if socket and type(socket.close) == "function" and not socket:is_closing() then
      socket:close()
    end
  end

  local function finish(status, body, headers)
    if completed then return end
    completed = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    close_socket()
    callback(status, body or "", headers or {})
  end

  local timeout_ms = tonumber(request.timeout_ms) or 10000
  timer:start(timeout_ms, 0, function()
    finish(nil, "request timed out", {})
  end)

  local thread = coroutine.create(function()
    local ok, status, body, headers = pcall(perform, request, function(connected_socket)
      socket = connected_socket
      if completed then close_socket() end
    end)
    if not ok then
      finish(nil, "request failed", {})
    else
      finish(status, body, headers)
    end
  end)
  local resumed = coroutine.resume(thread)
  if not resumed then finish(nil, "request failed", {}) end
end

return Transport
