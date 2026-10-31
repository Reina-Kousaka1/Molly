local Sync = {}
local fields = { "type", "name", "description", "required", "options", "choices", "channel_types",
  "min_value", "max_value", "min_length", "max_length", "default_member_permissions", "value", "autocomplete" }

local function difference(a, b, path, ignore_descriptions)
  if type(a) ~= type(b) then return path end
  if type(a) ~= "table" then
    if a == b then return nil end
    return path
  end
  if #a > 0 or #b > 0 then
    if #a ~= #b then return path .. ".length" end
    for i = 1, #a do
      local mismatch = difference(a[i], b[i], path .. "[" .. i .. "]", ignore_descriptions)
      if mismatch then return mismatch end
    end
    return nil
  end
  for _, field in ipairs(fields) do
    if not (ignore_descriptions and field == "description") then
    local x, y = a[field], b[field]
    if field == "type" then x, y = x or 1, y or 1 end
    if field == "required" then x, y = x or false, y or false end
    if field == "options" and (x == nil or (type(x) == "table" and #x == 0))
      and (y == nil or (type(y) == "table" and #y == 0)) then x, y = nil, nil end
    if x ~= nil or y ~= nil then
      local mismatch = difference(x, y, path == "" and field or (path .. "." .. field), ignore_descriptions)
      if mismatch then return mismatch end
    end
    end
  end
  return nil
end

-- Preflight all schemas first. Only description-only drift is PATCHed; this
-- never deletes commands or changes an executable command schema.
function Sync.run(bot)
  if type(bot) ~= "table" or type(bot.client) ~= "table"
    or type(bot.client.get_application_id) ~= "function" then
    return false, "application_unavailable"
  end
  local id_ok, id = pcall(bot.client.get_application_id, bot.client)
  if not id_ok or (type(id) ~= "string" and type(id) ~= "number") or type(bot.http) ~= "table" then
    return false, "application_unavailable"
  end
  if type(bot.http.get) ~= "function" then return false, "remote_unavailable" end
  local endpoint = "/applications/" .. id .. "/commands"
  local remote_ok, remote = pcall(bot.http.get, bot.http, endpoint)
  if not remote_ok or type(remote) ~= "table" then return false, "remote_unavailable" end
  local existing, missing, local_names, updates = {}, {}, {}, {}
  for _, command in ipairs(remote) do
    local key = tostring(command.type or 1) .. ":" .. command.name
    if existing[key] then return false, "remote_duplicate_command", { command = command.name } end
    existing[key] = command
  end
  for _, command in ipairs(bot.command_tree.commands) do
    if command.guild_ids then return false, "unsupported_scope" end
    local spec = command:to_dict()
    local key = tostring(spec.type or 1) .. ":" .. spec.name
    if local_names[key] then return false, "local_duplicate_command", { command = spec.name } end
    local_names[key] = true
    local found = existing[key]
    if found then
      local field = difference(spec, found, "")
      if field then
        -- Discord command descriptions are explanatory metadata. Repair them
        -- only when the entire executable schema matches, so stale descriptions
        -- cannot hide option, permission, or scope conflicts.
        local contract_field = difference(spec, found, "", true)
        if contract_field ~= nil then
          return false, "command_conflict", { command = spec.name, field = contract_field }
        end
        if type(found.id) ~= "string" or not found.id:match("^%d+$") then
          return false, "registration_unconfirmed", { command = spec.name, field = field }
        end
        updates[#updates + 1] = { id = found.id, name = spec.name, key = key, spec = spec }
      end
    end
    if not found then missing[#missing + 1] = spec end
  end
  for _, update in ipairs(updates) do
    if type(bot.http.patch) ~= "function" then
      return false, "registration_unconfirmed", { command = update.name, field = "description" }
    end
    local patch_ok, changed = pcall(bot.http.patch, bot.http, endpoint .. "/" .. update.id, update.spec)
    if not patch_ok then
      return false, "registration_unconfirmed", { command = update.name, field = "description" }
    end
    if type(changed) ~= "table" or changed.id ~= update.id or changed.name ~= update.name
      or difference(update.spec, changed, "") ~= nil then
      return false, "registration_unconfirmed", { command = update.name, field = "description" }
    end
    existing[update.key] = changed
  end
  for _, spec in ipairs(missing) do
    if type(bot.http.post) ~= "function" then
      return false, "registration_unconfirmed", { command = spec.name }
    end
    local post_ok, created = pcall(bot.http.post, bot.http, endpoint, spec)
    if not post_ok then return false, "registration_unconfirmed", { command = spec.name } end
    if type(created) ~= "table" or created.name ~= spec.name or type(created.id) ~= "string" then
      return false, "registration_unconfirmed", { command = spec.name }
    end
  end
  return true, { updated = #updates, created = #missing }
end
return Sync
