package.path = './?.lua;./?/init.lua;./deps/?.lua;./deps/?/init.lua;' .. package.path
local router = require('src.commands.router').new()
require('src.commands.permissions').register(router, {})
local c = assert(router.commands.permissions)
local json = require('json')
io.write(json.encode({description = c.description, options = c.options}))
