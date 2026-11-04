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
do
  local Sync = require('src.discord.safe_sync')
  local bot = { client = { get_application_id = function() return '1' end }, http = { get = function() return {} end },
    command_tree = { commands = { { to_dict = function() return { type = 1, name = 'logs', description = 'test' } end } } } }
  local writes = 0
  local ok, reason, details = Sync.run(bot, { write = function()
    writes = writes + 1
    return nil, 'failed', { http_status = 429, discord_code = 0, discord_message = 'You are being rate limited.' }
  end })
  assert(not ok and reason == 'write_failed' and details.command == 'logs' and details.http_status == 429
    and details.discord_code == 0 and details.discord_message == 'You are being rate limited.' and writes == 1)
end
do
  local record
  local fake = { http = { get = function() return {} end }, client = { get_application_id = function() return '1' end },
    command_tree = { commands = { { to_dict = function() return { type = 1, name = 'logs', description = 'test' } end } } } }
  function fake:on() end
  function fake:slash_command() end
  local boot = Bootstrap.new({ discord = { Bot = function() return fake end }, app = {},
    commands = { list = function() return {} end },
    logger = { error = function(_, _, fields) record = fields end },
    sync_write = function() return nil, 'failed', { http_status = 429, discord_code = 0,
      discord_message = 'You are being rate limited.', retry_after_ms = 1250, secret = 'private-fixture' } end }):build()
  assert(not fake:sync_commands() and boot.sync_state.status == 'failed')
  assert(record.http_status == 429 and record.discord_code == 0 and record.retry_after_ms == 1250
    and record.discord_message == 'You are being rate limited.' and record.secret == nil)
  assert(not fake:sync_commands())
end
print('PASS sync state: success, failure, unknown, reconnect, repeated ready, single writer')
