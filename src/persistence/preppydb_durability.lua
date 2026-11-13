-- Fail-closed interpretation of PreppyDB's /v1/version durability contract.
-- Both fields are required together; one field alone cannot establish the
-- acknowledgement boundary expected by Molly.
local Durability = {}

local NON_DURABLE_MODES = {
  never = true, none = true, off = true, periodic = true, interval = true, batch = true,
}

function Durability.classify(version)
  if type(version) ~= "table" then return "unverifiable", "version_unavailable" end
  if version.api_version ~= "1.0.0" or version.engine ~= "preppydb" then
    return "unverifiable", "server_identity_unverified"
  end

  local mode = version.sync_mode
  local durable_writes = version.durable_writes
  if type(mode) ~= "string" or type(durable_writes) ~= "boolean" then
    return "unverifiable", "durability_not_reported", mode, durable_writes
  end

  local normalized = mode:lower()
  if normalized ~= "always" and not NON_DURABLE_MODES[normalized] then
    return "unverifiable", "unknown_sync_mode", mode, durable_writes
  end

  local mode_is_durable = normalized == "always"
  if mode_is_durable ~= durable_writes then
    return "unverifiable", "inconsistent_durability", mode, durable_writes
  end
  if not mode_is_durable then
    return "not_durable", "writes_not_synced", mode, durable_writes
  end

  return "durable", "durable_writes", mode, durable_writes
end

return Durability
