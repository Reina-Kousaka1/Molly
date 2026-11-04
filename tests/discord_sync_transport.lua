package.path = './?.lua;./?/init.lua;./deps/?.lua;./deps/?/init.lua;' .. package.path
local uv = require('uv')
require('json')
local transport = require('src.discord.sync_transport')
local Bootstrap = require('src.discord.bootstrap')
local tmp = assert(uv.fs_mkdtemp('/tmp/molly-sync-test-XXXXXX'))
assert(uv.fs_mkdir(tmp .. '/tools', 448))
local file = assert(io.open(tmp .. '/tools/discord_sync_worker.py', 'w'))
file:write([[
import json, sys, time
r=json.load(sys.stdin)
with open('calls', 'a') as log: log.write(r['body']['name']+'\n')
if r['body']['name']=='timeout': time.sleep(5)
elif r['body']['name']=='first':
 time.sleep(0.2)
 print(json.dumps({'state':'success','value':dict(r['body'],id='5')}))
elif r['body']['name']=='invalid': print('broken')
else: print(json.dumps({'state':'success','value':dict(r['body'],id='5')}))
]])
file:close()
assert(uv.chdir(tmp))
coroutine.wrap(function()
  local bot = { http = { token = 'fixture' } }
  local result, err = transport.write(bot, 'POST', '/applications/1/commands', { name = 'ok' }, 2000)
  assert(result and result.id == '5' and not err, 'worker must return confirmed response')
  local bad, reason = transport.write(bot, 'POST', '/applications/1/commands', { name = 'invalid' }, 2000)
  assert(not bad and reason == 'unknown', 'malformed worker response is unknown')
  local timeout, why = transport.write(bot, 'POST', '/applications/1/commands', { name = 'timeout' }, 100)
  assert(not timeout and why == 'unknown', 'total deadline must produce unknown outcome')
  local function instance(names)
    local fake = { http = { token = 'fixture', get = function() return {} end },
      client = { get_application_id = function() return '1' end }, command_tree = { commands = {} } }
    for _, name in ipairs(names) do
      fake.command_tree.commands[#fake.command_tree.commands + 1] = { to_dict = function()
        return { name = name, description = 'fixture', type = 1 }
      end }
    end
    function fake:on() end
    function fake:slash_command() end
    local boot = Bootstrap.new({ discord = { Bot = function() return fake end }, app = {},
      commands = { list = function() return {} end } }):build()
    return fake, boot
  end
  local good, good_boot = instance({ 'first', 'second' })
  local overlapping_ready = false
  local ready_timer = uv.new_timer()
  ready_timer:start(50, 0, function()
    overlapping_ready = true
    assert(not good:sync_commands(), 'running sync must reject another ready event')
    ready_timer:close()
  end)
  assert(good:sync_commands() and good_boot.sync_state.status == 'success')
  assert(overlapping_ready)
  assert(good:sync_commands())
  local bad_bot, bad_boot = instance({ 'invalid', 'must_not_write' })
  assert(not bad_bot:sync_commands() and bad_boot.sync_state.status == 'unknown')
  assert(not bad_bot:sync_commands())
  local calls = assert(io.open('calls')):read('*a')
  assert(not calls:find('must_not_write', 1, true))
  assert(select(2, calls:gsub('first\n', '')) == 1)
  assert(uv.fs_unlink(tmp .. '/calls'))
  assert(uv.fs_unlink(tmp .. '/tools/discord_sync_worker.py'))
  assert(uv.fs_rmdir(tmp .. '/tools'))
  assert(uv.fs_rmdir(tmp))
  print('PASS real subprocess transport: success, malformed response, hard deadline')
end)()
