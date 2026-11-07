local Personality = {}
local Seasonal = require("src.seasonal")
local PREFIX_MARKER, DISCORD_CONTENT_LIMIT = "🎀 ", 2000

-- Keep voice and flavor centralized. Templates carry the concrete values so a
-- playful variant can never replace the useful result or error information.
Personality.lines = {
  generic_success = { "Doneee, bestie! Everything's handled 💗", "All set, girlie! 🎀" },
  generic_error = { "Omggg, that didn't work: {{detail}} 😭", "Tiny snag, bestie: {{detail}} 💕" },
  permission_denied = { "Sorry bestie, you don't have permission for that 🔐", "Girl, that action needs different server permissions 🎀" },
  music_added = { "Added **{{title}}** to the queue, bestie! 🎧💗", "**{{title}}** is queued! Skincare playlist energy 🎀" },
  music_playing = { "Now playing **{{title}}** — this is a vibe 🎶", "Starting **{{title}}**! Grab your pink Stanley 💕" },
  music_idle = { "Nothing's playing yet, bestie! Queue up a song 🎧" },
  voice_created = { "Your cute room is ready: <#{{channel_id}}> 🎀", "Room created: <#{{channel_id}}> — enjoy, girlie 💗" },
  system = { "KiddyyMolly is here, besties! Check the status below 💕" },
  easter_egg = { "Sephora wishlist? Girl, it's already full 🛍️🎀" },
}
Personality.default_lines = Personality.lines

local function replace(template, values)
  return (template:gsub("{{([%w_]+)}}", function(key)
    local value = values and values[key]
    return value == nil and ("{{" .. key .. "}}") or tostring(value)
  end))
end

function Personality.render(category, values, random, timestamp)
  local variants = Personality.lines[category]
  if not variants or #variants == 0 then return nil end
  local choose = random or math.random
  local index = choose(#variants)
  if type(index) ~= "number" or index < 1 or index > #variants then index = 1 end
  return replace(variants[index], values)
end

function Personality.profile(timestamp)
  return Seasonal.current(timestamp).personality
end

function Personality.about(_timestamp)
  return "I'm KiddyyMolly, your pink little Discord bestie! 💗 From Molly Coins and fictional shopping adventures to moderation, music, and helpful server features, I bring a little sparkle while keeping server safety real."
end

-- Prefix commands use Discord message replies instead of the shared interaction
-- embed pipeline. Add a small, consistent identity marker without rewriting
-- command output (amounts, IDs, diagnostics, and moderation language stay intact).
function Personality.prefix_response(text)
  if type(text) ~= "string" then return text end
  if text:sub(1, #PREFIX_MARKER) == PREFIX_MARKER then return text end
  if #text + #PREFIX_MARKER > DISCORD_CONTENT_LIMIT then return text end
  return PREFIX_MARKER .. text
end

return Personality
