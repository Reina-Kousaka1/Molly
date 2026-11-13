-- Process-local gate for Molly writes. This does not stop other SeaWorld
-- clients; a source-level snapshot capability is still required separately.
local Gate = {}
Gate.__index = Gate

function Gate.new()
  return setmetatable({ accepting = true, active = 0, epoch = 0, nonce = 0 }, Gate)
end

function Gate:enter()
  if not self.accepting then return nil, "migration_write_stop" end
  self.active = self.active + 1
  return { gate = self }
end

function Gate:leave(lease, may_have_written)
  if type(lease) ~= "table" or lease.gate ~= self or lease.closed then
    return false, "invalid_write_lease"
  end
  lease.closed = true
  self.active = self.active - 1
  if may_have_written then self.epoch = self.epoch + 1 end
  return true
end

function Gate:quiesce()
  if not self.accepting then return nil, "already_quiesced" end
  self.accepting = false
  if self.active ~= 0 then
    self.accepting = true
    return nil, "writes_in_flight"
  end
  self.nonce = self.nonce + 1
  return { gate = self, epoch = self.epoch, nonce = self.nonce }
end

function Gate:validate(token)
  return type(token) == "table" and token.gate == self
    and token.nonce == self.nonce and token.epoch == self.epoch
    and self.accepting == false and self.active == 0
end

function Gate:release(token)
  if not self:validate(token) then return false, "invalid_quiesce_token" end
  self.accepting = true
  return true
end

function Gate:is_accepting() return self.accepting end
function Gate:active_writes() return self.active end
function Gate:write_epoch() return self.epoch end

Gate.shared = Gate.new()
return Gate
