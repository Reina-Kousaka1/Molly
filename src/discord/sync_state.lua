local State = {}
State.__index = State
function State.new() return setmetatable({ status = 'idle' }, State) end
function State:begin()
  if self.status ~= 'idle' then return false end
  self.status = 'running'
  return true
end
function State:finish(ok, reason)
  if self.status ~= 'running' then return false end
  self.status = ok and 'success' or (reason == 'outcome_unknown' and 'unknown' or 'failed')
  return true
end
return State
