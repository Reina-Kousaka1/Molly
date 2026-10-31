local http = require("coro-http")

local Transport = {}

function Transport.request(method, url, options)
  local headers = {}
  for key, value in pairs(options.headers or {}) do
    if type(key) == "number" and type(value) == "table" then
      headers[#headers + 1] = value
    else
      headers[#headers + 1] = { tostring(key), tostring(value) }
    end
  end
  if options.body ~= nil then
    headers[#headers + 1] = { "Content-Type", "application/json" }
  end
  local response, body = http.request(
    method,
    url,
    headers,
    options.body,
    { timeout = options.timeout_ms, followRedirects = false }
  )
  if not response then
    return nil, "request_failed"
  end
  return { code = response.code }, body
end

return Transport
