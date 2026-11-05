local Store = require("src.persistence.guild_store")

local Mining = {}
Mining.__index = Mining

function Mining.new(ledger, modes)
  assert(type(ledger) == "table" and type(ledger.mine) == "function", "economy ledger is required")
  assert(type(modes) == "table" and type(modes.get) == "function", "mode registry is required")
  return setmetatable({ ledger = ledger, modes = modes }, Mining)
end

function Mining:mine(guild, user, request_id, request_type)
  if not Store.valid_id(guild) or not Store.valid_id(user) or not Store.valid_id(request_id) then
    return false, "invalid_argument"
  end
  return self.ledger:mine(guild, user, request_id, request_type)
end

return Mining
