-- Starts the real entry point with a fake SeaWorld driver and fake Discord
-- gateway. No network or production data is used.
package.path = './?.lua;./?/init.lua;./deps/?.lua;./deps/?/init.lua;' .. package.path
local driver = require('src.seaworld.socket_driver')
driver.new = function()
  return { initialize = function() return true end, connect = function() return true end,
    health = function() return { status = 'healthy', api_version = '1.0.0',
      capabilities = { native_queries = true, field_updates = true, transactions = true } } end }
end
local bootstrap = require('src.discord.bootstrap')
local new_bootstrap = bootstrap.new
local writes = 0
bootstrap.new = function(options)
  options.sync_write = function(_, method, _, spec)
    assert(method == 'POST')
    writes = writes + 1
    local response = {}
    for k, v in pairs(spec) do response[k] = v end
    response.id = tostring(writes)
    return response
  end
  return new_bootstrap(options)
end
local discord = require('discord.lua')
local new_bot = discord.Bot
discord.Bot = function(intents)
  local bot = new_bot(intents)
  bot.run = function(self)
    self.client = { get_application_id = function() return '123' end }
    self.http = { get = function() return {} end }
    assert(#self.command_tree.commands == 79)
    assert(self:sync_commands() and writes == 79)
    assert(self:sync_commands() and writes == 79)
    print('PASS real Molly entrypoint: mocked SeaWorld, gateway, 79-command sync and repeated ready')
    os.exit(0)
  end
  return bot
end
require('../molly')
