local Status = {}

function Status.message(discord_connected, sea_world_state, music_state)
  local sea_world = sea_world_state and sea_world_state.status or "unavailable"
  local music = music_state and music_state.status or "unavailable"
  return table.concat({
    "Molly: online",
    "Discord: " .. (discord_connected and "connected" or "unavailable"),
    "SeaWorld: " .. sea_world,
    "Music: " .. music,
  }, "\n")
end

return Status
