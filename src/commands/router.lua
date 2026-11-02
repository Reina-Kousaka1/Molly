local Router = {}
Router.__index = Router
local Permissions = require("src.discord.permissions")

function Router.new(logger)
  return setmetatable({ logger = logger, commands = {}, prefix_commands = {}, gate = nil }, Router)
end

function Router:set_gate(gate)
  assert(gate == nil or type(gate) == "function", "gate must be a function")
  self.gate = gate
end

function Router:register(definition)
  assert(type(definition) == "table", "command definition is required")
  assert(type(definition.name) == "string" and definition.name:match("^[%w%-_]+$"), "valid command name is required")
  assert(type(definition.description) == "string" and definition.description ~= "", "command description is required")
  assert(type(definition.execute) == "function", "command execute function is required")
  assert(not self.commands[definition.name] and not self.prefix_commands[definition.name], "duplicate command: " .. definition.name)
  local aliases = type(definition.prefix) == "table" and definition.prefix.aliases or {}
  assert(type(aliases) == "table", "prefix aliases must be a table")
  if definition.prefix then
    assert(type(definition.prefix) == "table" and type(definition.prefix.arguments or {}) == "table",
      "prefix configuration must declare arguments")
    assert(not self.prefix_commands[definition.name], "duplicate prefix command: " .. definition.name)
    for _, alias in ipairs(aliases) do
      assert(type(alias) == "string" and alias:match("^[%w_%-]+$"), "valid prefix alias is required")
      assert(not self.commands[alias] and not self.prefix_commands[alias], "duplicate prefix command: " .. alias)
    end
  end
  definition.slash = definition.slash ~= false
  self.commands[definition.name] = definition
  if definition.prefix then
    self.prefix_commands[definition.name] = definition
    for _, alias in ipairs(aliases) do self.prefix_commands[alias] = definition end
  end
end

function Router:list(surface)
  local result = {}
  local seen = {}
  for _, definition in pairs(self.commands) do
    local include = surface == "prefix" and definition.prefix ~= nil
      or surface == "slash" and definition.slash
      or surface == nil and definition.slash ~= false
    if include and not seen[definition.name] then
      result[#result + 1] = definition
      seen[definition.name] = true
    end
  end
  table.sort(result, function(left, right) return left.name < right.name end)
  return result
end

function Router:prefix_definition(name)
  if type(name) ~= "string" then return nil end
  return self.prefix_commands[name:lower()]
end

function Router:prefix_aliases(definition)
  local result = {}
  if not definition or not definition.prefix then return result end
  for _, alias in ipairs(definition.prefix.aliases or {}) do result[#result + 1] = alias end
  return result
end

function Router:authorize(name, context)
  local definition = self.commands[name]
  if not definition then return false, "unknown_command" end
  if definition.permission and not Permissions.has(context and context.member and context.member.permissions, definition.permission) then
    return false, "permission_denied"
  end
  if self.gate and not definition.admin then
    local call_ok, allowed, reason = pcall(self.gate, context, definition)
    if not call_ok then return false, "access_unavailable" end
    if not allowed then return false, reason or "access_denied" end
  end
  return true
end

function Router:dispatch(name, context)
  local authorized, reason = self:authorize(name, context)
  if not authorized then
    if reason ~= "unknown_command" and context and type(context.respond) == "function" then
      local message = reason == "blacklisted" and "You are globally blacklisted from using Molly."
        or reason == "permission_denied" and "You do not have permission to use this command."
        or "Molly could not verify command access right now. Please try again later."
      pcall(context.respond, context, message, { ephemeral = true })
    end
    return false, reason
  end
  local definition = self.commands[name]
  local ok = pcall(definition.execute, context)
  if not ok then
    if self.logger then self.logger:error("command_handler_failed", { command = name }) end
    if context and type(context.respond) == "function" then
      if context._molly_deferred and type(context.edit) == "function" then pcall(context.edit, context, "Molly could not complete that command.")
      else pcall(context.respond, context, "Molly could not complete that command.", { ephemeral = true }) end
    end
    return false, "handler_failed"
  end
  return true
end

function Router:dispatch_prefix(name, context)
  local definition = self:prefix_definition(name)
  if not definition then return false, "unknown_command" end
  context.command_prefix_name = name:lower()
  return self:dispatch(definition.name, context)
end

return Router
