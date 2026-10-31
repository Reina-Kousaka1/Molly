local Router = {}
Router.__index = Router

function Router.new(logger)
  return setmetatable({ logger = logger, handlers = {} }, Router)
end

function Router:on(name, handler)
  assert(type(name) == "string" and name ~= "", "event name is required")
  assert(type(handler) == "function", "event handler is required")
  local handlers = self.handlers[name] or {}
  handlers[#handlers + 1] = handler
  self.handlers[name] = handlers
end

function Router:dispatch(name, ...)
  local handlers = self.handlers[name] or {}
  for _, handler in ipairs(handlers) do
    local ok = pcall(handler, ...)
    if not ok and self.logger then
      self.logger:error("event_handler_failed", { source_event = name })
    end
  end
end

return Router
