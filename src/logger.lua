local Logger = {}
Logger.__index = Logger

local secret_key = {
  token = true,
  authorization = true,
  password = true,
  secret = true,
  credential = true,
  api_key = true,
  apikey = true,
  client_secret = true,
  access_token = true,
  refresh_token = true,
}

local function is_secret_key(key)
  key = tostring(key):lower():gsub("%-", "_")
  return secret_key[key] or key:match("_token$") or key:match("_secret$")
end

local function escape(value)
  return tostring(value)
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\n", "\\n")
    :gsub("\r", "\\r")
end

local function encode(value, key)
  if key and is_secret_key(key) then
    return '"[REDACTED]"'
  end

  if type(value) == "string" then
    return '"' .. escape(value) .. '"'
  elseif type(value) == "number" or type(value) == "boolean" then
    return tostring(value)
  elseif type(value) == "table" then
    local fields = {}
    for field, field_value in pairs(value) do
      fields[#fields + 1] = '"' .. escape(field) .. '":' .. encode(field_value, field)
    end
    table.sort(fields)
    return "{" .. table.concat(fields, ",") .. "}"
  end
  return '"' .. escape(value == nil and "null" or type(value)) .. '"'
end

function Logger.new(sink)
  return setmetatable({ sink = sink or print }, Logger)
end

function Logger:write(level, event, fields)
  local record = {
    timestamp = os.date("%Y-%m-%dT%H:%M:%S%z"),
    level = level,
    event = event,
  }
  for key, value in pairs(fields or {}) do
    if key == "timestamp" or key == "level" or key == "event" then
      record["context_" .. key] = value
    else
      record[key] = value
    end
  end
  self.sink(encode(record))
end

function Logger:info(event, fields)
  self:write("info", event, fields)
end

function Logger:warn(event, fields)
  self:write("warn", event, fields)
end

function Logger:error(event, fields)
  self:write("error", event, fields)
end

return Logger
