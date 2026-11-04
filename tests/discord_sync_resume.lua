package.path = './?.lua;./?/init.lua;./deps/?.lua;./deps/?/init.lua;' .. package.path
local Sync = require('src.discord.safe_sync')
local names = { 'afk', 'content', 'delete', 'fashion', 'goodbye', 'inventory', 'logs', 'mine',
  'mode', 'my-permissions', 'observe', 'selfroles', 'sephora', 'settings', 'shop', 'starboard',
  'transaction', 'user-settings', 'welcome' }
local remote, commands, calls = {}, {}, {}
for i, name in ipairs(names) do
  local spec = { type = 1, name = name, description = 'fixture' }
  commands[#commands + 1] = { to_dict = function() return spec end }
  if i <= 6 then remote[#remote + 1] = { id = tostring(i), type = 1, name = name, description = 'fixture' } end
end
local bot = { client = { get_application_id = function() return '1' end }, http = {}, command_tree = { commands = commands } }
function bot.http:get() return remote end
local function write(_, method, _, spec)
  assert(method == 'POST')
  calls[#calls + 1] = spec.name
  local doc = { id = tostring(10 + #calls), name = spec.name, description = spec.description, type = 1 }
  remote[#remote + 1] = doc
  return doc
end
local ok, outcome = Sync.run(bot, { write = write })
assert(ok and outcome.created == 13 and #calls == 13 and #remote == 19)
for _, name in ipairs(calls) do
  for i = 1, 6 do assert(name ~= names[i], 'already existing command must be skipped') end
end
local again, result = Sync.run(bot, { write = write })
assert(again and result.created == 0 and #calls == 13)
-- A command appearing between the initial preflight and its POST is skipped.
do
  local reads, writes = 0, 0
  local one = { client = bot.client, http = {}, command_tree = { commands = { commands[7] } } }
  function one.http:get()
    reads = reads + 1
    return reads == 1 and {} or { { id = '99', type = 1, name = 'logs', description = 'fixture' } }
  end
  local success, info = Sync.run(one, { write = function() writes = writes + 1 end })
  assert(success and info.created == 0 and info.skipped == 1 and writes == 0)
end
-- Proactive waits use successful response headers, and never repeat a write.
do
  local writes, waits = 0, 0
  local two = { client = bot.client, http = { get = function() return {} end },
    command_tree = { commands = { commands[7], commands[8] } } }
  local success, info = Sync.run(two, {
    write = function(_, _, _, spec)
      writes = writes + 1
      return { id = tostring(writes), type = 1, name = spec.name, description = spec.description }, nil,
        { rate_limit_remaining = 0, rate_limit_reset_ms = 1250 }
    end,
    wait = function(ms) waits = waits + 1; assert(ms == 1275); return true end,
  })
  assert(success and info.created == 2 and writes == 2 and waits == 1)
end
do
  local writes = 0
  local two = { client = bot.client, http = { get = function() return {} end },
    command_tree = { commands = { commands[7], commands[8] } } }
  local success, reason = Sync.run(two, {
    write = function(_, _, _, spec)
      writes = writes + 1
      return { id = tostring(writes), type = 1, name = spec.name, description = spec.description }, nil,
        { rate_limit_remaining = 0, rate_limit_reset_ms = 60000 }
    end,
    wait = function() return false end,
  })
  assert(not success and reason == 'rate_limit_wait_exceeded' and writes == 1)
end
-- A conflicting concurrent command prevents all writes.
do
  local reads, writes = 0, 0
  local one = { client = bot.client, http = {}, command_tree = { commands = { commands[7] } } }
  function one.http:get()
    reads = reads + 1
    return reads == 1 and {} or { { id = '99', type = 1, name = 'logs', description = 'fixture', options = { { type = 1, name = 'other' } } } }
  end
  local success, reason = Sync.run(one, { write = function() writes = writes + 1 end })
  assert(not success and reason == 'command_conflict' and writes == 0)
end
print('PASS partial sync resume, existing commands skipped, concurrent conflicts fail closed')
