local Service = {}
Service.__index = Service
local Durability = require("src.persistence.preppydb_durability")

local function state(status, detail, extra)
  local result = { status = status, detail = detail }
  for key, value in pairs(extra or {}) do result[key] = value end
  return result
end

function Service.new(connector, required_collections)
  assert(type(connector) == "table", "PreppyDB connector is required")
  return setmetatable({
    connector = connector,
    required_collections = required_collections or {
      "molly_guild_state", "molly_guild_registry", "molly_global_state",
    },
    current = state("unavailable", "not_initialized"),
  }, Service)
end

function Service:get_state()
  local result = {}
  for key, value in pairs(self.current) do result[key] = value end
  return result
end

function Service:initialize()
  self.current = state("unavailable", "initialized")
  return self:get_state()
end

function Service:check()
  local health, health_error = self.connector:health()
  if type(health) ~= "table" or health.status ~= "ok" then
    self.current = state("unavailable", "health_failed")
    return self:get_state()
  end
  local ready, ready_error = self.connector:ready()
  if type(ready) ~= "table" or ready.ready ~= true then
    self.current = state("unavailable", "storage_not_ready")
    return self:get_state()
  end
  if ready.read_only ~= false then
    local evidence = {}
    if type(ready.read_only) == "boolean" then evidence.read_only = ready.read_only end
    self.current = state("not_ready", "storage_writeability_unverifiable", evidence)
    return self:get_state()
  end
  local version, version_error = self.connector:version()
  if type(version) ~= "table" or version.api_version ~= "1.0.0" then
    self.current = state("incompatible_api", "api_version", {
      api_version = type(version) == "table" and version.api_version or nil,
    })
    return self:get_state()
  end
  if version.engine ~= "preppydb" then
    self.current = state("incompatible_api", "server_identity", { engine = version.engine })
    return self:get_state()
  end
  local durability, durability_detail, sync_mode, durable_writes = Durability.classify(version)
  if durability ~= "durable" then
    local detail = durability == "not_durable" and "not_durable" or "durability_unverifiable"
    local evidence = {
      durability_detail = durability_detail,
    }
    if type(sync_mode) == "string" then evidence.sync_mode = sync_mode end
    if type(durable_writes) == "boolean" then evidence.durable_writes = durable_writes end
    self.current = state("not_ready", detail, evidence)
    return self:get_state()
  end
  local principal, auth_error = self.connector:whoami()
  if type(principal) ~= "table" or type(principal.roles) ~= "table" then
    self.current = state("unavailable", "authorization_unavailable")
    return self:get_state()
  end
  local can_write = false
  for _, role in ipairs(principal.roles) do
    if role == "write" or role == "admin" then can_write = true end
  end
  if not can_write then
    self.current = state("unauthorized", "write_role_required")
    return self:get_state()
  end
  local collections, collection_error = self.connector:collections()
  if type(collections) ~= "table" then
    self.current = state("unavailable", "collections_unavailable")
    return self:get_state()
  end
  local present = {}
  for _, entry in ipairs(collections) do
    local name = type(entry) == "table" and entry.name or entry
    if type(name) == "string" then present[name] = true end
  end
  for _, name in ipairs(self.required_collections) do
    if not present[name] then
      self.current = state("not_ready", "required_collection_missing", { collection = name })
      return self:get_state()
    end
  end
  self.current = state("healthy", "ok", {
    api_version = version.api_version,
    package_version = version.version,
    engine = version.engine,
    read_only = false,
    sync_mode = sync_mode,
    durable_writes = durable_writes,
    durability = durability,
  })
  return self:get_state()
end

function Service:connect()
  local checked = self:check()
  return checked.status == "healthy", checked.detail
end

function Service:health()
  local health = self.connector:health()
  if type(health) ~= "table" or health.status ~= "ok" then
    self.current = state("unavailable", "health_failed")
    return self:get_state()
  end
  local ready = self.connector:ready()
  if type(ready) ~= "table" or ready.ready ~= true then
    self.current = state("unavailable", "storage_not_ready")
    return self:get_state()
  end
  if ready.read_only ~= false then
    local evidence = {}
    if type(ready.read_only) == "boolean" then evidence.read_only = ready.read_only end
    self.current = state("not_ready", "storage_writeability_unverifiable", evidence)
    return self:get_state()
  end
  if self.current.status == "healthy" then return self:get_state() end
  return state("unavailable", "not_preflighted")
end

function Service:close()
  self.current = state("unavailable", "closed")
  return true
end

return Service
