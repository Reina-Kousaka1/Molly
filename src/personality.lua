local Personality = {}
local Seasonal = require("src.seasonal")

-- Keep voice and flavor centralized. Templates carry the concrete values so a
-- playful variant can never replace the useful result or error information.
Personality.lines = {
  generic_success = {
    "Done. Try not to look too surprised. ✨",
    "Handled. I do have my moments. 🖤",
  },
  generic_error = {
    "That did not work: {{detail}}",
    "A small snag: {{detail}}",
  },
  permission_denied = {
    "You do not have permission to do that.",
    "That one is outside your authority.",
  },
  music_added = {
    "Added **{{title}}** to the queue. Try not to ruin my playlist. 🖤",
    "**{{title}}** is in the queue. I expect decent taste from here on. 🎧",
  },
  music_playing = {
    "Now playing **{{title}}**. There, the silence is fixed. 🎶",
    "Starting **{{title}}**. Do keep up. 🖤",
  },
  music_idle = { "Nothing is playing. How terribly quiet. 🖤" },
  voice_created = {
    "Your room is ready: <#{{channel_id}}> . Make yourself comfortable. ✨",
    "A little corner of your own: <#{{channel_id}}>. 🖤",
  },
  system = { "Molly is here. The details are in the status below." },
  easter_egg = { "Careful what you try on. Some things fit a little too well. 👠" },
}

-- Seasonal overrides keep flavor centralized while leaving command results and
-- operational wording intact. The default profile presents Molly as staff.
Personality.default_lines = {
  generic_success = { "Done. The details are in order. ✨", "Handled. The team can keep moving. 🖤" },
  permission_denied = { "You do not have permission to do that.", "That action is outside your server permissions." },
  music_added = { "Added **{{title}}** to the queue. Enjoy the selection. 🎧", "**{{title}}** is in the queue. Good choice. 🎶" },
  music_playing = { "Now playing **{{title}}**. Enjoy the music. 🎶", "Starting **{{title}}**. The room has a soundtrack now. 🎧" },
  music_idle = { "Nothing is playing right now. Queue up a track when you are ready. 🎧" },
  voice_created = { "Your room is ready: <#{{channel_id}}>. Make yourself comfortable. ✨", "A room for your group: <#{{channel_id}}>. 🖤" },
  easter_egg = { "Molly keeps a few mysteries to herself. 🗝️" },
}

local function replace(template, values)
  return (template:gsub("{{([%w_]+)}}", function(key)
    local value = values and values[key]
    return value == nil and ("{{" .. key .. "}}") or tostring(value)
  end))
end

function Personality.render(category, values, random, timestamp)
  local season = Seasonal.current(timestamp)
  local variants = (season.personality == "default" and Personality.default_lines[category])
    or Personality.lines[category]
  if not variants or #variants == 0 then return nil end
  local choose = random or math.random
  local index = choose(#variants)
  if type(index) ~= "number" or index < 1 or index > #variants then index = 1 end
  return replace(variants[index], values)
end

function Personality.profile(timestamp)
  return Seasonal.current(timestamp).personality
end

function Personality.about(timestamp)
  if Personality.profile(timestamp) == "succubus" then
    return "Molly — self-possessed, sharp-tongued, and rather too confident. It began with an unmarked parcel, " ..
      "a pair of shoes, and a whisper. The rest is her business. 🖤"
  end
  return "Molly — your moderation and staff assistant. Keeping the community organized, the team informed, " ..
    "and the details in order. With a little style. 🖤"
end

return Personality
