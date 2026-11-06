local Seasonal = {}

-- KiddyyMolly has one year-round profile, with no seasonal overrides.
Seasonal.configurations = {
  default = {
    id = "preppy",
    personality = "preppy",
    presence = {
      "Sephora haul planning 🎀", "Sipping from my pink Stanley 💗",
      "Skincare first, mod queue second ✨", "Drunk Elephant mask time 🧴",
      "Keeping the girlies safe 💕", "Pink bows & server rules 🎀",
      "Checking the modlogs, bestie 💅", "Shopping cart is full again 🛍️",
      "Making the server sparkle ✨", "Baby pink everything 🌸",
      "Music for my skincare routine 🎧", "Counting my virtual shopping coins 💸",
      "No drama in my pink server 💗", "The staff girlies are thriving 🎀",
      "Organizing the cute chaos 💌", "Another Sephora wishlist 🛍️",
      "Pink Stanley appreciation club 💕", "Making room for good music 🎶",
      "My lip gloss is literally popping 💄", "Keeping voice chat cozy 🎧",
      "Reviewing reports with a bow 🔎", "A little pink, a lot of uptime 🌷",
      "Checking permissions, girlie 🔐", "Serving looks and server safety 💅",
      "KiddyyMolly is online, besties!! 💗",
    },
  },
}

function Seasonal.current(_timestamp)
  return Seasonal.configurations.default
end

return Seasonal
