package.path = "./?.lua;./?/init.lua;" .. package.path

local Images = require("src.personality.discord_images")
local passed, failed = 0, 0
local failures = {}
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    io.write("ok - " .. name .. "\n")
  else
    failed = failed + 1
    failures[#failures + 1] = name .. ": " .. tostring(err)
    io.write("not ok - " .. name .. ": " .. tostring(err) .. "\n")
  end
end

local function attachment(name, mime, bytes, overrides)
  local result = {
    filename = name,
    content_type = mime,
    size = #bytes,
    url = "https://cdn.discordapp.com/attachments/123/456/" .. name .. "?ex=fixture",
  }
  for key, value in pairs(overrides or {}) do result[key] = value end
  return result
end

local function png()
  return "\137PNG\13\10\26\10" .. "\0\0\0\13IHDR" .. string.rep("\0", 13)
    .. "\0\0\0\0" .. "\0\0\0\0IDAT" .. "\0\0\0\0\0\0\0\0"
    .. "\0\0\0\0IEND" .. "\0\0\0\0"
end

test("Discord image URLs allow only HTTPS attachment paths on the exact CDN host", function()
  assert(Images.valid_url("https://cdn.discordapp.com/attachments/123/456/p.png?ex=abc"))
  for _, url in ipairs({
    "http://cdn.discordapp.com/attachments/123/456/p.png",
    "https://discordapp.com/attachments/123/456/p.png",
    "https://cdn.discordapp.com.evil.test/attachments/123/456/p.png",
    "https://user@cdn.discordapp.com/attachments/123/456/p.png",
    "https://cdn.discordapp.com:443/attachments/123/456/p.png",
    "https://cdn.discordapp.com/avatars/123/p.png",
    "https://cdn.discordapp.com/attachments/123/../secret",
    "https://cdn.discordapp.com/attachments/123/456/p.png#fragment",
  }) do assert(not Images.valid_url(url), url) end
end)

test("one supported attachment is size and content checked, then encoded transiently", function()
  local bytes, calls = png(), 0
  local image_loader = assert(Images.new({ download = function(url, options)
    calls = calls + 1
    assert(url:match("^https://cdn%.discordapp%.com/attachments/"))
    assert(options.max_bytes == Images.DEFAULT_MAX_BYTES and options.timeout_ms == Images.DEFAULT_TIMEOUT_MS)
    return { body = bytes, content_type = "image/png; charset=binary" }
  end }))
  local encoded = assert(image_loader:prepare({ attachment("face.png", "image/png", bytes) }))
  assert(calls == 1 and #encoded == 1)
  assert(encoded[1] == Images.base64_encode(bytes))
  assert(#encoded[1] == math.ceil(#bytes / 3) * 4)
  assert(encoded[1]:match("^[%w%+/]+=*$"))
end)

test("JPEG and WebP signatures are accepted only when bytes match metadata", function()
  local jpeg = "\255\216\255\224" .. "fixture" .. "\255\217"
  local webp = "RIFF" .. string.char(12, 0, 0, 0) .. "WEBPVP8 " .. string.char(0, 0, 0, 0)
  local image_loader = assert(Images.new({ download = function(url)
    if url:match("%.jpg") then return { body = jpeg, content_type = "image/jpeg" } end
    return { body = webp, content_type = "image/webp" }
  end }))
  assert(image_loader:prepare({ attachment("face.jpg", "image/jpeg", jpeg) }))
  assert(image_loader:prepare({ attachment("face.webp", "image/webp", webp) }))
end)

test("unsupported, oversized, mismatched, multiple and malformed attachments fail closed", function()
  local downloaded = 0
  local image_loader = assert(Images.new({ download = function()
    downloaded = downloaded + 1
    return { body = png(), content_type = "image/png" }
  end }))
  local good = png()
  local cases = {
    { attachment("face.gif", "image/gif", "GIF89a") , "unsupported_image_type" },
    { attachment("face.jpg", "image/jpeg", good), "image_type_mismatch" },
    { attachment("face.png", "image/png", good, { size = #good + 1 }), "image_size_mismatch" },
    { attachment("face.png", "text/plain", good), "unsupported_image_type" },
    { attachment("face.png", "image/png", good, { url = "https://127.0.0.1/attachments/1/2/x.png" }), "invalid_image_url" },
  }
  for _, case in ipairs(cases) do
    local value, err = image_loader:prepare({ case[1] })
    assert(value == nil and err == case[2], tostring(err))
  end
  local value, err = image_loader:prepare({ attachment("face.png", "image/png", good),
    attachment("other.png", "image/png", good) })
  assert(value == nil and err == "too_many_images")
  value, err = image_loader:prepare({ attachment("face.png", "image/png", good, { size = Images.DEFAULT_MAX_BYTES + 1 }) })
  assert(value == nil and err == "image_too_large")
  assert(downloaded == 1, "invalid metadata must not trigger a download")
end)

test("download size, returned MIME, and actual file signature must agree", function()
  local good = png()
  local mismatch = assert(Images.new({ download = function() return { body = "not an image", content_type = "image/png" } end }))
  local value, err = mismatch:prepare({ attachment("face.png", "image/png", "not an image") })
  assert(value == nil and err == "image_content_mismatch")
  local wrong_mime = assert(Images.new({ download = function() return { body = good, content_type = "image/jpeg" } end }))
  value, err = wrong_mime:prepare({ attachment("face.png", "image/png", good) })
  assert(value == nil and err == "image_content_mismatch")
  local wrong_size = assert(Images.new({ download = function() return { body = good:sub(1, -2), content_type = "image/png" } end }))
  value, err = wrong_size:prepare({ attachment("face.png", "image/png", good) })
  assert(value == nil and err == "image_size_mismatch")
end)

test("image limits and base64 output are bounded and deterministic", function()
  assert(Images.base64_encode("hello") == "aGVsbG8=")
  assert(Images.new({ max_bytes = 0 }) == nil)
  assert(Images.new({ timeout_ms = 1 }) == nil)
  local missing = assert(Images.new({}))
  local value, err = missing:prepare({ attachment("face.png", "image/png", png()) })
  assert(value == nil and err == "image_download_unavailable")
end)

io.write(string.format("personality vision: %d tests, %d failures\n", passed + failed, failed))
if failed > 0 then
  for _, failure in ipairs(failures) do io.write(" - " .. failure .. "\n") end
  os.exit(1)
end
os.exit(0)
