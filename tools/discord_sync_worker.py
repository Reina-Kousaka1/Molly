#!/usr/bin/env python3
"""Single Discord command write, invoked with private JSON on stdin."""
import json
import math
import re
import sys
import urllib.error
import urllib.request

SAFE_MESSAGES = {
    'Invalid Form Body', 'Missing Access', 'Missing Permissions',
    'You are being rate limited.', 'Unknown Application', 'Unknown Command',
    'Maximum number of application commands reached',
}

def error_details(status, raw):
    details = {'http_status': status}
    try:
        body = json.loads(raw)
    except (ValueError, UnicodeError, TypeError):
        return details
    if not isinstance(body, dict): return details
    code = body.get('code')
    if type(code) is int and 0 <= code <= 99999999:
        details['discord_code'] = code
    retry = body.get('retry_after')
    if type(retry) in (int, float) and math.isfinite(retry) and 0 <= retry <= 86400:
        details['retry_after_ms'] = int(retry * 1000)
    message = body.get('message')
    if isinstance(message, str) and message in SAFE_MESSAGES:
        details['discord_message'] = message
    return details

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
                headers = getattr(response, 'headers', {})
                remaining = headers.get('X-RateLimit-Remaining')
                reset_after = headers.get('X-RateLimit-Reset-After')
                raw = response.read(1048577)
        except urllib.error.HTTPError as error:
            status = error.code
            try: raw = error.read(65537)
            except Exception: raw = b''
        if status >= 500 or status == 408 or 300 <= status < 400:
            return dict({'state': 'unknown'}, **error_details(status, raw))
        if status < 200 or status >= 300:
            return dict({'state': 'failed'}, **error_details(status, raw))
        if len(raw) > 1048576:
            return {'state': 'unknown'}
        try:
            result = json.loads(raw)
        except (ValueError, UnicodeError):
            return {'state': 'unknown'}
        if not isinstance(result, dict):
            return {'state': 'unknown'}
        output = {'state': 'success', 'value': result}
        try:
            remaining, reset_after = int(remaining), float(reset_after)
            if 0 <= remaining <= 100000 and math.isfinite(reset_after) and 0 <= reset_after <= 86400:
                output['rate_limit_remaining'] = remaining
                output['rate_limit_reset_ms'] = math.ceil(reset_after * 1000)
        except (ValueError, TypeError, OverflowError):
            pass
        return output
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
