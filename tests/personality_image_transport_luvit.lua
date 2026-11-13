local Images = require("src.personality.discord_images")
local Transport = require("src.personality.discord_image_transport")

assert(type(Transport.download) == "function", "bounded HTTPS downloader must load in Luvit")
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

local result, err = Transport.download("http://127.0.0.1/attachments/1/2/a.png", {})
assert(result == nil and err == "invalid_image_url", "invalid URLs fail before opening a socket")
print("personality image transport: Luvit HTTPS module loaded; allowlist and no-network rejection verified")
