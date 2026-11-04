local Sync = {}
local fields = { "type", "name", "description", "required", "options", "choices", "channel_types",
  "min_value", "max_value", "min_length", "max_length", "default_member_permissions", "value", "autocomplete" }
local preserved_command_metadata = { "default_member_permissions", "integration_types", "contexts", "nsfw",
  "name_localizations", "description_localizations" }

local function same_value(left, right)
  if type(left) ~= type(right) then return false end
  if type(left) ~= "table" then return left == right end
  for key, value in pairs(left) do if not same_value(value, right[key]) then return false end end
  for key in pairs(right) do if left[key] == nil then return false end end
  return true
end

local function copy_metadata(command)
  local snapshot = {}
  for _, field in ipairs(preserved_command_metadata) do
    if command[field] ~= nil then snapshot[field] = command[field] end
  end
  return snapshot
end

local function metadata_preserved(snapshot, command)
  for field, value in pairs(snapshot) do
    if not same_value(value, command[field]) then return false, field end
  end
  return true
end

local function is_permissions_options_migration(remote, local_spec, field)
  if local_spec.name ~= "permissions" or local_spec.type ~= 1
    or type(local_spec.options) ~= "table" or #local_spec.options == 0
    or local_spec.default_member_permissions ~= nil then return false end
  if remote.name ~= "permissions" or (remote.type or 1) ~= 1
    or remote.description ~= "Show selected effective permissions"
    or remote.default_member_permissions ~= nil
    or (type(remote.options) == "table" and #remote.options > 0)
    or remote.id ~= "1565628256500191287" then return false end
  if not field or not field:match("^options") then return false end
  for _, option in ipairs(local_spec.options) do
    if type(option) ~= "table" or option.type ~= 1 then return false end
  end
  return true
end

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

-- Preflight all schemas first. By default only description-only drift is
-- PATCHed. One explicit, signature-guarded migration may update the global
-- /permissions options; this never deletes commands or uses bulk overwrite.
function Sync.run(bot, options)
  options = options or {}
  local id = bot.client:get_application_id()
  if not id or not bot.http then return false, "application_unavailable" end
  local endpoint = "/applications/" .. id .. "/commands"
  local remote = bot.http:get(endpoint)
  if type(remote) ~= "table" then return false, "remote_unavailable" end
  local existing, missing, local_names, updates, migrations = {}, {}, {}, {}, {}
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
        local migrating_permissions = false
        -- Discord command descriptions are explanatory metadata. Repair them
        -- only when the entire executable schema matches, so stale descriptions
        -- cannot hide option, permission, or scope conflicts.
        local contract_field = difference(spec, found, "", true)
        if contract_field ~= nil then
          if options.allow_permissions_options_migration == true
            and is_permissions_options_migration(found, spec, contract_field) then
            migrations[#migrations + 1] = {
              id = found.id, key = key, name = spec.name, spec = spec,
              metadata = copy_metadata(found),
            }
            migrating_permissions = true
          else
            return false, "command_conflict", { command = spec.name, field = contract_field }
          end
        elseif spec.name == "permissions" and found.description == "Show selected effective permissions"
          and options.allow_permissions_options_migration == true then
          -- A comparator change must never turn the explicit migration into a
          -- no-op. The legacy description/options signature is required above.
          if is_permissions_options_migration(found, spec, "options") then
            migrations[#migrations + 1] = {
              id = found.id, key = key, name = spec.name, spec = spec,
              metadata = copy_metadata(found),
            }
            migrating_permissions = true
          end
        end
        if type(found.id) ~= "string" or not found.id:match("^%d+$") then
          return false, "registration_unconfirmed", { command = spec.name, field = field }
        end
        if not migrating_permissions then
          updates[#updates + 1] = { id = found.id, name = spec.name, key = key, spec = spec }
        end
      end
    end
    if not found then missing[#missing + 1] = spec end
  end
  if #migrations > 0 then
    -- The built-in Discord client retries 429 responses and lacks a total
    -- deadline. The separately controlled migration must run first.
    return false, "migration_requires_controlled_transport", { command = migrations[1].name }
  end
  local writer = options.write or require('src.discord.sync_transport').write
  for _, update in ipairs(updates) do
    local changed, failure = writer(bot, 'PATCH', endpoint .. "/" .. update.id, update.spec)
    if not changed then return false, failure == 'failed' and 'write_failed' or 'outcome_unknown', { command = update.name } end
    if type(changed) ~= "table" or changed.id ~= update.id or changed.name ~= update.name
      or difference(update.spec, changed, "") ~= nil then
      return false, "outcome_unknown", { command = update.name, field = "description" }
    end
    existing[update.key] = changed
  end
  for _, spec in ipairs(missing) do
    local created, failure = writer(bot, 'POST', endpoint, spec)
    if not created then return false, failure == 'failed' and 'write_failed' or 'outcome_unknown', { command = spec.name } end
    if type(created) ~= "table" or created.name ~= spec.name or type(created.id) ~= "string" or not created.id:match('^%d+$')
      or difference(spec, created, "") ~= nil then
      return false, "outcome_unknown", { command = spec.name }
    end
  end
  return true, { updated = #updates, created = #missing, migrated = #migrations }
end
return Sync
