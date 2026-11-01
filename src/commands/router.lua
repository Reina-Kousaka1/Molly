local Router = {}
Router.__index = Router

function Router.new(logger)
  return setmetatable({ logger = logger, commands = {}, gate = nil }, Router)
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
  assert(not self.commands[definition.name], "duplicate command: " .. definition.name)
  self.commands[definition.name] = definition
end

function Router:list()
  local result = {}
  for _, definition in pairs(self.commands) do result[#result + 1] = definition end
  table.sort(result, function(left, right) return left.name < right.name end)
  return result
end

function Router:dispatch(name, context)
  local definition = self.commands[name]
  if not definition then return false, "unknown_command" end
  if self.gate and not definition.admin then
    local call_ok, allowed, reason = pcall(self.gate, context, definition)
    if not call_ok or not allowed then
      if context and type(context.respond) == "function" then
        local message = reason == "blacklisted" and "You are globally blacklisted from using Molly."
          or "Molly could not verify command access right now. Please try again later."
        pcall(context.respond, context, message, { ephemeral = true })
      end
      return false, reason or "access_denied"
    end
  end
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

return Router
