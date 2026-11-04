package.path = './?.lua;./?/init.lua;./deps/?.lua;./deps/?/init.lua;' .. package.path
local Bootstrap = require('src.discord.bootstrap')
local function fixture(write)
  local bot = { events = {}, http = {}, client = { get_application_id = function() return '1' end },
    command_tree = { commands = {
      { to_dict = function() return { type = 1, name = 'one', description = 'first' } end },
      { to_dict = function() return { type = 1, name = 'two', description = 'second' } end },
    } } }
  function bot:on(name, callback) self.events[name] = callback end
  function bot:slash_command() end
  function bot.http:get() return {} end
  local router = { list = function() return {} end }
  local app = { on_ready = function() end, on_reconnect = function() end, on_disconnect = function() end }
  local bootstrap = Bootstrap.new({ discord = { Bot = function() return bot end }, app = app,
    commands = router, sync_write = write }):build()
  return bot, bootstrap
end
for _, mode in ipairs({ 'failed', 'unknown', 'exception', 'invalid' }) do
  local count = 0
  local bot, bootstrap = fixture(function(_, method, path, spec)
    count = count + 1
    if mode == 'exception' then error('private diagnostic') end
    if mode == 'invalid' then return { id = '1', name = 'wrong' } end
    return nil, mode
  end)
  assert(not bot:sync_commands())
  assert(count == 1, 'no further writes after failure')
  assert(bootstrap.sync_state.status == (mode == 'failed' and 'failed' or 'unknown'))
  bot.events.reconnect()
  bot.events.ready()
  assert(not bot:sync_commands() and not bot:sync_commands())
  assert(count == 1, 'repeated ready or reconnect must not initiate writes')
end
do
  local count = 0
  local bot, bootstrap = fixture(function(_, method, path, spec)
    count = count + 1
    return { id = tostring(count), name = spec.name, description = spec.description, type = 1 }
  end)
  assert(bot:sync_commands() and bootstrap.sync_state.status == 'success' and count == 2)
  assert(bot:sync_commands() and count == 2)
end
do
  local State = require('src.discord.sync_state')
  local state = State.new()
  assert(state:begin() and not state:begin() and state.status == 'running')
  assert(state:finish(false, 'outcome_unknown') and not state:begin() and state.status == 'unknown')
end
print('PASS sync state: success, failure, unknown, reconnect, repeated ready, single writer')
