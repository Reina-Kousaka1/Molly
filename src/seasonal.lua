local Seasonal = {}

-- Halloween runs from 00:00 on 30 October through 23:59 on 1 November 2026,
-- using Europe/Berlin local time (CET, UTC+01:00 for this interval).
-- These UTC bounds keep selection independent of the host/container timezone.
Seasonal.halloween_start_utc = "2026-10-29T23:00:00Z"
Seasonal.halloween_end_utc = "2026-11-01T23:00:00Z"

Seasonal.configurations = {
  default = {
    id = "default",
    personality = "default",
    presence = {
      "Keeping the mod queue moving 📋", "On duty for the community 🛡️", "Keeping the staff team in sync 💬",
      "Reviewing reports with care 🔎", "Making server life a little smoother ✨", "Keeping the modlogs tidy 🗂️",
      "Helping the staff team grow 🌱", "Watching over the server 👀", "Organizing the daily chaos 📁",
      "Making sure everyone feels welcome 🤝", "A quick check on the community 🏡", "Keeping an eye on voice chat 🎙️",
      "Here when the team needs a hand 🫡", "The details are under control 🗝️", "Helping the server run smoothly ⚙️",
      "Checking in with the staff desk ☕", "Keeping conversations on track 💬", "Community first, always 🌟",
      "Making room for good music 🎧", "The queue is behaving. For now. 🎶", "Keeping things fair and friendly ⚖️",
      "Sorting the little things before they grow 🧹", "Server support, with a little style 🖤", "Available for the next report 📬",
      "Another shift, handled neatly 📋",
    },
  },
  halloween_2026 = {
    id = "halloween-2026",
    personality = "succubus",
    presence = {
      "Halloween shift; mind your manners 🎃", "Your moderator has horns tonight 😈", "Haunting the mod queue 📋",
      "Watching from the shadows 👀", "Definitely not cursed. Probably. 🕯️", "A whisper came from the parcel 📦",
      "Those shoes fit far too perfectly 👠", "Moderating after dark 🌙", "Keeping an eye on voice chat 🎙️",
      "One more night in the shadows 🖤", "The reports won't investigate themselves 🔎", "A little mischief, neatly logged 🗂️",
      "The staff room feels colder tonight ❄️", "Something is listening in the dark 🕯️", "Keeping the peace, with claws tucked away 🛡️",
      "A strange parcel, an ordinary shift 📦", "The playlist sounds better after midnight 🎧", "Try not to summon another ticket 📬",
      "The mod queue has nowhere to hide 👁️", "A quiet smile from the shadows 🌑", "Those shoes have opinions again 👠",
      "Halloween chaos, professionally managed 📋", "I heard that. The shadows did too. 👀", "Just a little after-dark supervision 🖤",
      "The night shift suits me rather well 🌙",
    },
  },
}

local function utc_string(timestamp)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", timestamp or os.time())
end

function Seasonal.current(timestamp)
  local now = utc_string(timestamp)
  if now >= Seasonal.halloween_start_utc and now < Seasonal.halloween_end_utc then
    return Seasonal.configurations.halloween_2026
  end
  return Seasonal.configurations.default
end

return Seasonal
