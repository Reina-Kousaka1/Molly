-- Validate and transiently encode one Discord image attachment for Ollama.
-- Image bytes are held only in request memory; this module has no persistence.
local Images = {}
Images.__index = Images

Images.DEFAULT_MAX_BYTES = 4 * 1024 * 1024
Images.DEFAULT_TIMEOUT_MS = 8000
Images.ALLOWED_HOST = "cdn.discordapp.com"

local TYPES = {
  ["image/jpeg"] = { extension = { jpg = true, jpeg = true } },
  ["image/png"] = { extension = { png = true } },
  ["image/webp"] = { extension = { webp = true } },
}

local function error_code(code)
  return nil, code
end

local function valid_url(url)
  if type(url) ~= "string" or #url > 4096 or url:find("[%z\1-\32\127]") then return false end
  local authority, path = url:match("^https://([^/?#]+)(/[^#]*)$")
  if authority ~= Images.ALLOWED_HOST or not path or path:sub(1, 13) ~= "/attachments/" then
    return false
  end
  if path:find("\\", 1, true) or path:find("/../", 1, true) or path:find("/./", 1, true) then
    return false
  end
  return true
end

local function canonical_mime(value)
  if type(value) ~= "string" or #value > 100 then return nil end
  local mime = value:lower():match("^%s*([^;%s]+)")
  return mime and TYPES[mime] and mime or nil
end

local function image_type(bytes)
  if #bytes >= 4 and bytes:sub(1, 3) == "\255\216\255"
    and bytes:sub(-2) == "\255\217" then return "image/jpeg" end
  if #bytes >= 45 and bytes:sub(1, 8) == "\137PNG\13\10\26\10"
    and bytes:sub(9, 12) == "\0\0\0\13" and bytes:sub(13, 16) == "IHDR"
    and bytes:sub(-12, -9) == "\0\0\0\0" and bytes:sub(-8, -5) == "IEND"
    and bytes:find("IDAT", 33, true) then return "image/png" end
  if #bytes >= 12 and bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WEBP" then
    local riff_size = bytes:byte(5) + bytes:byte(6) * 256
      + bytes:byte(7) * 65536 + bytes:byte(8) * 16777216
    if riff_size + 8 == #bytes and #bytes >= 20 then return "image/webp" end
  end
  return nil
end

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64_encode(value)
  local output, batch = {}, {}
  for index = 1, #value, 3 do
    local first, second, third = value:byte(index, index + 2)
    second, third = second or 0, third or 0
    local bits = first * 65536 + second * 256 + third
    local a = math.floor(bits / 262144) % 64 + 1
    local b = math.floor(bits / 4096) % 64 + 1
    local c = math.floor(bits / 64) % 64 + 1
    local d = bits % 64 + 1
    batch[#batch + 1] = ALPHABET:sub(a, a)
    batch[#batch + 1] = ALPHABET:sub(b, b)
    batch[#batch + 1] = index + 1 <= #value and ALPHABET:sub(c, c) or "="
    batch[#batch + 1] = index + 2 <= #value and ALPHABET:sub(d, d) or "="
    if #batch >= 8192 then
      output[#output + 1] = table.concat(batch)
      batch = {}
    end
  end
  if #batch > 0 then output[#output + 1] = table.concat(batch) end
  return table.concat(output)
end

function Images.new(options)
  options = type(options) == "table" and options or {}
  local max_bytes = tonumber(options.max_bytes) or Images.DEFAULT_MAX_BYTES
  local timeout_ms = tonumber(options.timeout_ms) or Images.DEFAULT_TIMEOUT_MS
  if max_bytes % 1 ~= 0 or max_bytes < 1024 or max_bytes > Images.DEFAULT_MAX_BYTES then
    return nil, "invalid_image_limit"
  end
  if timeout_ms % 1 ~= 0 or timeout_ms < 100 or timeout_ms > 30000 then
    return nil, "invalid_image_timeout"
  end
  return setmetatable({
    download = options.download,
    max_bytes = max_bytes,
    timeout_ms = timeout_ms,
  }, Images)
end

function Images:prepare(attachments)
  if attachments == nil then return {} end
  if type(attachments) ~= "table" then return error_code("invalid_attachment") end
  if #attachments == 0 then return {} end
  if #attachments ~= 1 then return error_code("too_many_images") end

  local attachment = attachments[1]
  if type(attachment) ~= "table" or not valid_url(attachment.url) then
    return error_code("invalid_image_url")
  end
  local expected_mime = canonical_mime(attachment.content_type)
  if not expected_mime then return error_code("unsupported_image_type") end

  local size = tonumber(attachment.size)
  if not size or size % 1 ~= 0 or size < 1 or size > self.max_bytes then
    return error_code("image_too_large")
  end
  if type(attachment.filename) == "string" then
    if #attachment.filename > 255 or attachment.filename:find("[%z\1-\31\127]") then
      return error_code("invalid_attachment")
    end
    local extension = attachment.filename:lower():match("%.([%w]+)$")
    if extension and not TYPES[expected_mime].extension[extension] then
      return error_code("image_type_mismatch")
    end
  end
  if type(self.download) ~= "function" then return error_code("image_download_unavailable") end

  local called, downloaded, download_error = pcall(self.download, attachment.url, {
    max_bytes = self.max_bytes, timeout_ms = self.timeout_ms, expected_mime = expected_mime,
  })
  if not called then return error_code("image_download_failed") end
  if type(downloaded) ~= "table" or type(downloaded.body) ~= "string" then
    return error_code(type(download_error) == "string" and download_error or "image_download_failed")
  end

  local bytes = downloaded.body
  if #bytes < 1 or #bytes > self.max_bytes or #bytes ~= size then
    return error_code("image_size_mismatch")
  end
  local actual_mime = image_type(bytes)
  if actual_mime ~= expected_mime then return error_code("image_content_mismatch") end
  local response_mime = canonical_mime(downloaded.content_type)
  if response_mime ~= expected_mime then return error_code("image_content_mismatch") end

  return { base64_encode(bytes) }
end

Images.valid_url = valid_url
Images.image_type = image_type
Images.base64_encode = base64_encode

return Images
