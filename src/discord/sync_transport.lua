-- One subprocess per write. Its private stdin carries the token; a timer kills
-- the process at the total deadline. No HTTP pooling, redirects, or retries.
local Transport = {}
local MAX = 1024 * 1024
local uv, json = require('uv'), require('json')

function Transport.write(bot, method, path, body, deadline_ms)
  local token = bot.http and bot.http.token
  if type(token) ~= 'string' or token == '' then return nil, 'failed' end
  local ok, input = pcall(json.encode, { method = method, path = path, token = token, body = body })
  if not ok or #input > MAX then return nil, 'failed' end
  local thread = coroutine.running()
  if not thread then return nil, 'failed' end
  local stdin, stdout = uv.new_pipe(false), uv.new_pipe(false)
  local timer = uv.new_timer()
  local proc, timed_out, exited, eof, done, chunks, size = nil, false, false, false, false, {}, 0
  local function close(handle)
    if handle and not handle:is_closing() then handle:close() end
  end
  local function finish()
    if done or not exited or not eof then return end
    done = true
    timer:stop(); close(timer); close(stdin); close(stdout); close(proc)
    local success, failure = coroutine.resume(thread, timed_out and nil or table.concat(chunks), timed_out and 'unknown' or nil)
    if not success then error(failure, 0) end
  end
  proc = uv.spawn('/usr/bin/python3', { args = { 'tools/discord_sync_worker.py' },
    stdio = { stdin, stdout, nil }, env = { 'PATH=/usr/bin:/bin', 'HOME=/nonexistent' } }, function(code, signal)
      if code ~= 0 or signal ~= 0 then timed_out = true end
      exited = true; finish()
    end)
  if not proc then close(timer); close(stdin); close(stdout); return nil, 'failed' end
  uv.update_time()
  timer:start(deadline_ms or 12000, 0, function() timed_out = true; if not proc:is_closing() then proc:kill('sigkill') end end)
  stdout:read_start(function(err, data)
    if err then timed_out = true end
    if data then
      size = size + #data
      if size > MAX then timed_out = true; if not proc:is_closing() then proc:kill('sigkill') end
      else chunks[#chunks + 1] = data end
    else eof = true; stdout:read_stop(); finish() end
  end)
  stdin:write(input, function(err)
    if err then timed_out = true; if not proc:is_closing() then proc:kill('sigkill') end end
    if not stdin:is_closing() then stdin:shutdown(function() close(stdin) end) end
  end)
  local raw, failure = coroutine.yield()
  if failure then return nil, failure end
  local decoded, pos, err = json.decode(raw or '')
  if err or type(decoded) ~= 'table' or type(pos) ~= 'number' or (raw or ''):sub(pos):find('%S') then return nil, 'unknown' end
  local details = {}
  if type(decoded.http_status) == 'number' and decoded.http_status >= 100 and decoded.http_status <= 599
    and decoded.http_status % 1 == 0 then details.http_status = decoded.http_status end
  if type(decoded.discord_code) == 'number' and decoded.discord_code >= 0 and decoded.discord_code <= 99999999
    and decoded.discord_code % 1 == 0 then details.discord_code = decoded.discord_code end
  if type(decoded.retry_after_ms) == 'number' and decoded.retry_after_ms >= 0 and decoded.retry_after_ms <= 86400000
    and decoded.retry_after_ms % 1 == 0 then details.retry_after_ms = decoded.retry_after_ms end
  if type(decoded.rate_limit_remaining) == 'number' and decoded.rate_limit_remaining >= 0 and decoded.rate_limit_remaining <= 100000
    and decoded.rate_limit_remaining % 1 == 0 then details.rate_limit_remaining = decoded.rate_limit_remaining end
  if type(decoded.rate_limit_reset_ms) == 'number' and decoded.rate_limit_reset_ms >= 0 and decoded.rate_limit_reset_ms <= 86400000
    and decoded.rate_limit_reset_ms % 1 == 0 then details.rate_limit_reset_ms = decoded.rate_limit_reset_ms end
  local safe_messages = { ['Invalid Form Body'] = true, ['Missing Access'] = true, ['Missing Permissions'] = true,
    ['You are being rate limited.'] = true, ['Unknown Application'] = true, ['Unknown Command'] = true,
    ['Maximum number of application commands reached'] = true }
  if safe_messages[decoded.discord_message] then details.discord_message = decoded.discord_message end
  if decoded.state == 'success' and type(decoded.value) == 'table' then return decoded.value, nil, details end
  if decoded.state == 'failed' then return nil, 'failed', details end
  return nil, 'unknown', details
end

function Transport.wait(milliseconds)
  local thread = coroutine.running()
  if not thread or type(milliseconds) ~= 'number' or milliseconds < 0 or milliseconds > 60000 then return false end
  uv.update_time()
  local timer = uv.new_timer()
  timer:start(milliseconds, 0, function()
    timer:close()
    local ok, err = coroutine.resume(thread, true)
    if not ok then error(err, 0) end
  end)
  return coroutine.yield()
end
return Transport
