#!/usr/bin/env python3
"""One-shot Discord permissions migration. Run explicitly; never prints credentials."""
import argparse
import json
import multiprocessing
import os
import subprocess
import sys
import urllib.error
import urllib.request

COMMAND_ID = '1565628256500191287'
OLD_DESCRIPTION = 'Show selected effective permissions'
BASE = 'https://discord.com/api/v10'
TIMEOUT = 10
METADATA = ('default_member_permissions', 'integration_types', 'contexts', 'nsfw',
            'name_localizations', 'description_localizations')

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None

def _worker(conn, method, path, token, payload):
    try:
        body = None if payload is None else json.dumps(payload, separators=(',', ':')).encode()
        req = urllib.request.Request(BASE + path, data=body, method=method,
            headers={'Authorization': 'Bot ' + token, 'Content-Type': 'application/json',
                     'User-Agent': 'Molly-command-migration/1'})
        try:
            with urllib.request.build_opener(NoRedirect).open(req, timeout=TIMEOUT) as response:
                status, data = response.status, response.read(1048577)
        except urllib.error.HTTPError as error:
            status, data = error.code, b''
        if len(data) > 1048576:
            conn.send(('invalid_response', None)); return
        try:
            decoded = json.loads(data) if data else None
        except (ValueError, UnicodeError):
            conn.send(('invalid_response', None)); return
        conn.send((status, decoded))
    except BaseException:
        conn.send(('network_error', None))
    finally:
        conn.close()

def request(method, path, token, payload=None):
    """Separate process enforces a total deadline, including DNS and response body."""
    parent, child = multiprocessing.Pipe(False)
    process = multiprocessing.Process(target=_worker, args=(child, method, path, token, payload))
    process.start(); child.close()
    try:
        if parent.poll(TIMEOUT):
            try: return parent.recv()
            except EOFError: return 'network_error', None
        return 'timeout', None
    finally:
        if process.is_alive(): process.terminate()
        process.join(1)
        if process.is_alive(): process.kill(); process.join(1)
        parent.close()

def normalize_options(options):
    def normalize(option):
        return {key: (normalize_options(option.get(key) or []) if key == 'options'
                      else option.get(key, False) if key == 'required'
                      else option.get(key))
                for key in ('type', 'name', 'description', 'required', 'options',
                            'choices', 'channel_types', 'min_value', 'max_value',
                            'min_length', 'max_length', 'autocomplete')}
    return [normalize(item) for item in (options or [])]

def command_state(value, spec):
    if not isinstance(value, dict) or value.get('id') != COMMAND_ID or value.get('name') != 'permissions' or value.get('type', 1) != 1:
        return 'unexpected'
    if (value.get('description') == OLD_DESCRIPTION and value.get('options') in (None, [])
            and value.get('default_member_permissions') is None):
        return 'legacy'
    try:
        if value.get('description') == spec['description'] and normalize_options(value.get('options')) == normalize_options(spec['options']):
            return 'migrated'
    except (TypeError, AttributeError):
        pass
    return 'unexpected'

def migrate(token, spec, call=request):
    status, app = call('GET', '/oauth2/applications/@me', token)
    if status != 200 or not isinstance(app, dict) or not str(app.get('id', '')).isdigit(): return 'preflight_failed'
    app_id = str(app['id'])
    endpoint = '/applications/' + app_id + '/commands'
    status, commands = call('GET', endpoint, token)
    if status != 200 or not isinstance(commands, list): return 'preflight_failed'
    matches = [x for x in commands if isinstance(x, dict) and x.get('name') == 'permissions' and x.get('type', 1) == 1]
    if len(matches) != 1: return 'preflight_failed'
    old = matches[0]
    if str(old.get('application_id', '')) != app_id or old.get('guild_id') is not None: return 'preflight_failed'
    state = command_state(old, spec)
    if state == 'migrated': return 'already_migrated'
    if state != 'legacy': return 'preflight_failed'
    metadata = {key: old.get(key) for key in METADATA}
    path = endpoint + '/' + COMMAND_ID
    status, changed = call('PATCH', path, token, spec)
    if status == 200 and command_state(changed, spec) == 'migrated' and all(changed.get(k) == v for k, v in metadata.items()):
        return 'migrated'
    # Any uncertain outcome is inspected by GET only. This never initiates a retry.
    if status in ('timeout', 'network_error', 'invalid_response') or status == 200 or (isinstance(status, int) and status >= 500):
        read_status, observed = call('GET', path, token)
        if read_status == 200:
            return 'uncertain_observed_' + command_state(observed, spec)
        return 'uncertain_unavailable'
    return 'http_error_' + str(status)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--execute', action='store_true', help='explicitly perform the one-shot PATCH')
    args = parser.parse_args()
    if not args.execute:
        print('Migration disabled; explicit --execute required.'); return 2
    token = os.environ.get('MOLLY_DISCORD_TOKEN')
    if not token:
        print('Discord token is not configured.'); return 2
    try:
        env = dict(os.environ, LUA_PATH='./deps/?.lua;./deps/?/init.lua;;')
        env.pop('MOLLY_DISCORD_TOKEN', None)
        result = subprocess.run(['./runtime/luvit', 'tools/permissions_spec.lua'], capture_output=True, timeout=10, check=True, env=env)
        spec = json.loads(result.stdout)
        if set(spec) != {'description', 'options'} or not spec['options']: raise ValueError()
    except Exception:
        print('Unable to load local command specification.'); return 2
    result = migrate(token, spec)
    print('Migration result:', result)
    return 0 if result in ('migrated', 'already_migrated') else 1

if __name__ == '__main__':
    sys.exit(main())
