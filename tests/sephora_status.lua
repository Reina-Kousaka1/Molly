package.path = './?.lua;./?/init.lua;./deps/?.lua;./deps/?/init.lua;' .. package.path
local Status = require('src.presence.guild_status')
local Registry = require('src.modes.registry')
local Settings = require('src.settings.guild')
local Router = require('src.commands.router')
local ModeCommands = require('src.commands.mode')
local Config = require('src.config')
local function clone(x)
  if type(x) ~= 'table' then return x end
  local out = {}; for k,v in pairs(x) do out[k] = clone(v) end; return out
end
local store = { data = {} }
function store:run(guild, fn)
  local data = clone(self.data[guild] or { guild = guild, accounts = {}, cases = {}, staff = {}, journal = {}, receipts = {} })
  local ok, result, changed = fn(data)
  if ok and changed then self.data[guild] = data end
  return ok, result
end
local modes = Registry.new(Settings.new(store))
local updates, messages, next_id = {}, {}, 100
local rest = {}
function rest:get_channel(id) return { id = id, guild_id = id == '91' and '1' or '2', type = 0 } end
function rest:send_message(channel, body)
  next_id = next_id + 1; local id = tostring(next_id)
  messages[id] = { channel = channel, content = body.content }
  updates[#updates + 1] = { channel = channel, text = body.content }
  assert(body.allowed_mentions and #body.allowed_mentions.parse == 0)
  return { id = id }
end
function rest:edit_message(channel, id, body)
  assert(messages[id] and messages[id].channel == channel)
  messages[id].content = body.content
  updates[#updates + 1] = { channel = channel, text = body.content }
  return { id = id }
end
local scheduled, cancelled, period = 0, 0
local function create()
  local obj = Status.new({ store = store, modes = modes, random = function(n) return n end,
    schedule = function(ms, cb) scheduled = scheduled + 1; period = ms; return cb end,
    cancel = function() cancelled = cancelled + 1 end })
  obj:set_client({ rest = rest }); return obj
end
local manager = create()
assert(#Status.statuses == 60 and Status.statuses[1] == '💄 Doing my lip combo' and Status.statuses[60] == '🛒 mom can you buy me ONE more thing')
local seen = {}
for _, value in ipairs(Status.statuses) do
  assert(not seen[value] and #value <= 128 and #value > 0); seen[value] = true
end
local initial_updates = #updates
local wrong_guild, wrong_reason = manager:apply('3', '91', 'sephora')
assert(not wrong_guild and wrong_reason == 'status_channel_unavailable' and #updates == initial_updates)
local invalid, invalid_reason = manager:apply('1', '91', 'invalid')
assert(not invalid and invalid_reason == 'invalid_mode' and #updates == initial_updates)
do
  local state = { bag = { 5, 6 }, last = 5 }
  local _, failed_index = manager:_next(state)
  assert(failed_index == 6)
  local _, next_index = manager:_next(state)
  assert(next_index ~= 5, 'a failed update must not repeat the last visible status')
end
assert(modes:set('1', 'sephora'))
assert(manager:apply('1', '91', 'sephora'))
assert(#updates == 1 and updates[1].channel == '91' and updates[1].text:find(Status.statuses[60], 1, true))
assert(manager:start() and not manager:start() and scheduled == 1 and period == 120000)
local previous = updates[1].text; local bag = { [previous] = true }
for i = 2, 121 do
  assert(manager:tick()); local current = updates[#updates].text
  assert(current ~= previous, 'consecutive statuses must differ across shuffle boundaries')
  if i <= 60 then assert(not bag[current], 'each bag contains every status once'); bag[current] = true end
  previous = current
end
assert(modes:set('2', 'sephora'))
assert(manager:apply('2', '92', 'sephora'))
local guild2_id = store.data['2'].guild_status.message_id
local guild2_previous = messages[guild2_id].content
assert(modes:set('1', 'standard'))
assert(manager:apply('1', '91', 'standard'))
local guild1_id = store.data['1'].guild_status.message_id
assert(messages[guild1_id].content:find(Status.default_status, 1, true))
assert(messages[guild2_id].content == guild2_previous)
assert(manager:stop() and not manager:stop() and cancelled == 1)
local before = #updates; assert(not manager:tick() and #updates == before)
-- On a fresh instance, recover the persisted guild mode and message, without new messages.
local restart = create(); assert(restart:recover('1') and restart:recover('2'))
assert(next_id == 102 and messages[guild1_id].content:find(Status.default_status, 1, true))
assert(messages[guild2_id].content ~= guild2_previous or messages[guild2_id].content:find('Molly', 1, true))
local no_mode = create(); assert(no_mode:recover('3') and next_id == 102)
do
  local real_get = modes.get
  local attempts = 0
  modes.get = function(self, guild)
    attempts = attempts + 1
    if attempts == 1 then return false, 'busy' end
    return real_get(self, guild)
  end
  local recovering = create()
  assert(not recovering:recover('2') and recovering.recover_pending['2'])
  assert(recovering:start() and recovering:tick())
  assert(not recovering.recover_pending['2'] and recovering.guilds['2'].mode == 'sephora')
  assert(recovering:stop())
  modes.get = real_get
end
-- A mode change arriving while an edit is in progress is applied afterwards.
do
  local edit = rest.edit_message
  local injected = false
  rest.edit_message = function(self, channel, id, body)
    if not injected and channel == '92' then
      injected = true
      assert(modes:set('2', 'standard'))
      local immediate, reason = restart:apply('2', '92', 'standard')
      assert(not immediate and reason == 'busy')
    end
    return edit(self, channel, id, body)
  end
  assert(restart:apply('2', '92', 'sephora'))
  assert(injected and messages[guild2_id].content:find(Status.default_status, 1, true))
  rest.edit_message = edit
end
-- The existing /mode command remains the authorization boundary.
local router = Router.new(); local calls = 0
ModeCommands.register(router, modes, { guild_status = { apply = function() calls = calls + 1; return true end } })
local definition = router.commands.mode
local denied
local ctx = { guild = { id = '1' }, member = { permissions = '0' }, respond = function(_, text) denied = text end }
definition.execute(ctx); assert(denied and calls == 0)
local reply
ctx = { guild = { id = '1' }, member = { permissions = '32' }, molly_subcommand = 'set', channel_id = '91',
  args = { value = 'sephora' }, interaction_id = '1', interaction_token = 'fixture',
  bot = { application_id = '1', rest = { create_interaction_response = function() end } },
  edit = function(_, text) reply = text end }
definition.execute(ctx)
local mode_ok, mode_active = modes:is('1', 'sephora')
assert(calls == 1 and reply and mode_ok and mode_active)
local cfg = assert(Config.load({ MOLLY_DISCORD_TOKEN = 'fixture', MOLLY_SEPHORA_STATUS_INTERVAL_MS = '180000' }))
assert(cfg.status.sephora_interval_ms == 180000)
local invalid = Config.load({ MOLLY_DISCORD_TOKEN = 'fixture', MOLLY_SEPHORA_STATUS_INTERVAL_MS = '100' })
assert(not invalid)
print('PASS 60 mixed Sephora statuses, rotation, permissions, guild isolation, mode switch and recovery')
