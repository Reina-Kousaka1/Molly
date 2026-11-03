local V2 = {}

local VERSION = 1

function V2.read(data)
  if type(data) ~= "table" then return nil, "invalid_store" end
  local value = data.molly_v2
  if value == nil then return {}, false end
  if type(value) ~= "table" then return nil, "invalid_store" end
  if value.schema_version ~= nil and (type(value.schema_version) ~= "number"
    or value.schema_version < 1 or value.schema_version % 1 ~= 0) then
    return nil, "invalid_store"
  end
  if value.schema_version and value.schema_version > VERSION then return nil, "unsupported_schema" end
  return value, true
end

function V2.ensure(data)
  local value, exists_or_reason = V2.read(data)
  if not value then return nil, exists_or_reason end
  if exists_or_reason == false then
    value = { schema_version = VERSION }
    data.molly_v2 = value
  elseif value.schema_version == nil then
    value.schema_version = VERSION
  end
  return value
end

function V2.read_section(data, name)
  if type(name) ~= "string" or not name:match("^[a-z][a-z0-9_]*$") then return nil, "invalid_argument" end
  local root, reason = V2.read(data)
  if not root then return nil, reason end
  local section = root[name]
  if section == nil then return {}, false end
  if type(section) ~= "table" then return nil, "invalid_store" end
  return section, true
end

function V2.ensure_section(data, name)
  if type(name) ~= "string" or not name:match("^[a-z][a-z0-9_]*$") then return nil, "invalid_argument" end
  local root, reason = V2.ensure(data)
  if not root then return nil, reason end
  if root[name] == nil then root[name] = {} end
  if type(root[name]) ~= "table" then return nil, "invalid_store" end
  return root[name]
end

V2.version = VERSION
return V2
