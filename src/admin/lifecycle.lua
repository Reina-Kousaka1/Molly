local Lifecycle = {}
Lifecycle.__index = Lifecycle
Lifecycle.EXIT_SHUTDOWN = 0
Lifecycle.EXIT_RESTART = 75
Lifecycle.EXIT_UPDATE = 76
local function valid_id(value) return type(value) == "string" and value:match("^%d+$") ~= nil and #value <= 20 end
function Lifecycle.new(store, options) options = options or {}; return setmetatable({ store = store, clock = options.clock or os.time, version = options.version or "1.2", commit = options.commit }, Lifecycle) end
function Lifecycle:request(kind, request)
  if kind ~= "restart" and kind ~= "update" then return false, "invalid_action" end
  if type(request) ~= "table" or not valid_id(request.interaction_id) or not valid_id(request.guild_id) or not valid_id(request.channel_id) or not valid_id(request.requester_id) then return false, "invalid_request" end
  return self.store:run("lifecycle", { pending = false, receipts = {} }, function(data)
    if type(data.receipts) ~= "table" then return false, "invalid_store" end
    if data.receipts[request.interaction_id] then return true, data.receipts[request.interaction_id], false end
    if data.pending then return false, "already_pending" end
    local marker = { kind = kind, interaction_id = request.interaction_id, guild_id = request.guild_id, channel_id = request.channel_id,
      requester_id = request.requester_id, reason = request.reason or "", requested_at = self.clock(), version = self.version, commit = self.commit or "" }
    data.pending = marker; data.receipts[request.interaction_id] = { kind = kind, accepted = true }
    return true, marker, true
  end)
end
function Lifecycle:pending() return self.store:run("lifecycle", { pending = false, receipts = {} }, function(data) return true, data.pending or false, false end) end
function Lifecycle:cancel(interaction_id) return self.store:run("lifecycle", { pending = false, receipts = {} }, function(data) if data.pending and data.pending.interaction_id == interaction_id then data.pending = false end; data.receipts[interaction_id] = nil; return true, true, true end) end
function Lifecycle:complete(interaction_id) return self.store:run("lifecycle", { pending = false, receipts = {} }, function(data) if not data.pending or data.pending.interaction_id ~= interaction_id then return false, "marker_mismatch" end; data.pending = false; return true, true, true end) end
function Lifecycle:health_message(marker, health)
  local kind = marker.kind == "update" and "updated" or "restarted"
  local lines = { "🟢 I'm alive & healthy!", "Molly " .. kind .. " successfully." }
  if self.version then lines[#lines + 1] = "Version: " .. self.version end
  if self.commit and self.commit ~= "" then lines[#lines + 1] = "Commit: " .. tostring(self.commit):sub(1, 12) end
  if health and health.seaworld and health.seaworld.status == "healthy" then lines[#lines + 1] = "SeaWorld: healthy" end
  if marker.requested_at then lines[#lines + 1] = "Downtime: ~" .. math.max(0, self.clock() - marker.requested_at) .. "s" end
  return table.concat(lines, "\n")
end
return Lifecycle
