-- Bounded HTTPS download for Discord CDN image attachments only.
-- No redirects, cookies, arbitrary hosts or files are followed or persisted.
local https = require("https")
local uv = require("uv")

local Transport = {}
local ALLOWED_HOST = "cdn.discordapp.com"
local MAX_URL_CHARS = 4096
local MAX_HEADER_BYTES = 16 * 1024

local function parse_url(url)
  if type(url) ~= "string" or #url > MAX_URL_CHARS or url:find("[%z\1-\32\127]") then
    return nil
  end
  local host, path = url:match("^https://([^/?#]+)(/[^#]*)$")
  if host ~= ALLOWED_HOST or not path or path:sub(1, 12) ~= "/attachments/" then
    return nil
  end
  if path:find("\\", 1, true) or path:find("/../", 1, true) or path:find("/./", 1, true) then
    return nil
  end
  return path
end

local function header(headers, name)
  if type(headers) ~= "table" then return nil end
  local value = headers[name]
  if type(value) == "table" then value = value[1] end
  return type(value) == "string" and value or nil
end

function Transport.download(url, options)
  options = type(options) == "table" and options or {}
  local path = parse_url(url)
  if not path then return nil, "invalid_image_url" end
  local timeout_ms = tonumber(options.timeout_ms) or 8000
  local max_bytes = tonumber(options.max_bytes) or (4 * 1024 * 1024)
  if timeout_ms % 1 ~= 0 or timeout_ms < 100 or timeout_ms > 30000
    or max_bytes % 1 ~= 0 or max_bytes < 1024 or max_bytes > 4 * 1024 * 1024 then
    return nil, "invalid_image_limits"
  end

  -- Lua 5.1/LuaJIT return only the running coroutine (or nil on the main
  -- thread); coroutine.running() does not return an is-main flag there.
  local thread = coroutine.running()
  if not thread then return nil, "coroutine_required" end
  local timer = uv.new_timer()
  local request, response
  local done, yielded, size = false, false, 0
  local result, result_error

  local function close_timer()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end

  local function resume_waiter()
    if yielded then
      local resumed = coroutine.resume(thread)
      if not resumed then
        -- Do not expose low-level callback errors or downloaded content.
        result, result_error = nil, "request_failed"
      end
    end
  end

  local function settle(value, code)
    if done then return end
    done = true
    result, result_error = value, code
    close_timer()
    resume_waiter()
  end

  local function abort(code)
    if done then return end
    done = true
    result, result_error = nil, code
    close_timer()
    if request and type(request.destroy) == "function" then pcall(request.destroy, request) end
    if response and type(response.destroy) == "function" then pcall(response.destroy, response) end
    resume_waiter()
  end

  timer:start(timeout_ms, 0, function() abort("timeout") end)

  local ok, created = pcall(https.get, url, function(res)
    if done then return end
    response = res
    if res == nil or tonumber(res.statusCode) ~= 200 then
      abort("http_error")
      return
    end
    local headers = res.headers
    local encoding = header(headers, "content-encoding")
    if encoding and encoding:lower() ~= "identity" then
      abort("unsupported_content_encoding")
      return
    end
    local content_type = header(headers, "content-type")
    local content_length = header(headers, "content-length")
    if content_length then
      local declared = tonumber(content_length)
      if not declared or declared % 1 ~= 0 or declared < 1 or declared > max_bytes then
        abort("image_too_large")
        return
      end
    end
    if type(content_type) ~= "string" or #content_type > 100 then
      abort("invalid_content_type")
      return
    end
    local response_body = {}

    res:on("data", function(chunk)
      if done then return end
      if type(chunk) ~= "string" then abort("invalid_response"); return end
      size = size + #chunk
      if size > max_bytes then abort("image_too_large"); return end
      response_body[#response_body + 1] = chunk
    end)
    res:on("end", function()
      if done then return end
      if content_length and size ~= tonumber(content_length) then
        abort("invalid_response")
        return
      end
      settle({ body = table.concat(response_body), content_type = content_type })
    end)
    res:on("error", function() abort("request_failed") end)
  end)

  if not ok or created == nil then
    done = true
    close_timer()
    return nil, "connection_failed"
  end
  request = created
  local listener_ok = pcall(function()
    request:on("error", function() abort("request_failed") end)
  end)
  if not listener_ok then abort("request_failed") end
  if done then return result, result_error end
  yielded = true
  coroutine.yield()
  return result, result_error
end

Transport.parse_url = parse_url
return Transport
