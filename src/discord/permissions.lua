local Permissions = {}
Permissions.flags = { administrator = 8, manage_guild = 32, manage_messages = 8192,
  manage_roles = 268435456, kick_members = 2, ban_members = 4, moderate_members = 1099511627776 }

-- Discord serializes permission bits as decimal strings; avoid rounding a
-- snowflake-sized bitfield through Lua's double before extracting lower bits.
local function has_bit(value, bit)
  if type(value) ~= "string" or #value == 0 or #value > 24 or not value:match("^%d+$") then return false end
  local modulus, remainder = bit * 2, 0
  for digit in value:gmatch("%d") do remainder = (remainder * 10 + tonumber(digit)) % modulus end
  return remainder >= bit
end

function Permissions.has(value, name)
  local bit = Permissions.flags[name]
  if not bit then return false end
  return has_bit(value, Permissions.flags.administrator) or has_bit(value, bit)
end

return Permissions
