#!/usr/bin/env python3
"""Single Discord command write, invoked with private JSON on stdin."""
import json
import re
import sys
import urllib.error
import urllib.request

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None

def write_once(req, opener=None):
    method, path, token, body = (req.get(k) for k in ('method', 'path', 'token', 'body'))
    if method not in ('POST', 'PATCH') or not isinstance(token, str) or not token:
        return {'state': 'failed'}
    if not isinstance(path, str) or not re.fullmatch(r'/applications/[0-9]+/commands(?:/[0-9]+)?', path):
        return {'state': 'failed'}
    if (method == 'POST') != (path.count('/') == 3) or not isinstance(body, dict):
        return {'state': 'failed'}
    try:
        data = json.dumps(body, separators=(',', ':')).encode()
        request = urllib.request.Request('https://discord.com/api/v10' + path, data=data, method=method,
            headers={'Authorization': 'Bot ' + token, 'Content-Type': 'application/json',
                     'User-Agent': 'Molly-command-sync/1'})
        try:
            with (opener or urllib.request.build_opener(NoRedirect)).open(request, timeout=10) as response:
                status = response.status
                raw = response.read(1048577)
        except urllib.error.HTTPError as error:
            status = error.code
            raw = b''
        if status >= 500 or status == 408 or 300 <= status < 400:
            return {'state': 'unknown'}
        if status < 200 or status >= 300:
            return {'state': 'failed'}
        if len(raw) > 1048576:
            return {'state': 'unknown'}
        try:
            result = json.loads(raw)
        except (ValueError, UnicodeError):
            return {'state': 'unknown'}
        if not isinstance(result, dict):
            return {'state': 'unknown'}
        return {'state': 'success', 'value': result}
    except BaseException:
        return {'state': 'unknown'}

def main():
    try:
        raw = sys.stdin.buffer.read(1048577)
        if len(raw) > 1048576: raise ValueError('request too large')
        response = write_once(json.loads(raw))
    except BaseException:
        response = {'state': 'failed'}
    sys.stdout.write(json.dumps(response, separators=(',', ':')))
    sys.stdout.flush()

if __name__ == '__main__': main()
