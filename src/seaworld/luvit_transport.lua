local http = require("coro-http")

local Transport = {}

function Transport.request(method, url, options)
  local response, body = http.request(
    method,
    url,
    options.headers,
    nil,
    { timeout = options.timeout_ms, followRedirects = false }
  )

  if not response then
    return nil, "request_failed"
  end

  return { code = response.code }, body
end

return Transport
