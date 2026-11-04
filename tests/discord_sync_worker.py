import importlib.util
import pathlib
import unittest
import urllib.error

path = pathlib.Path(__file__).resolve().parents[1] / 'tools' / 'discord_sync_worker.py'
spec = importlib.util.spec_from_file_location('worker', path)
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)
REQUEST = {'method': 'POST', 'path': '/applications/123/commands', 'token': 'fixture', 'body': {'name': 'test'}}

class Response:
    def __init__(self, status, body): self.status, self.body = status, body
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def read(self, size): return self.body
class Opener:
    def __init__(self, value): self.value, self.calls = value, 0
    def open(self, request, timeout):
        self.calls += 1
        if isinstance(self.value, Exception): raise self.value
        return self.value
class Tests(unittest.TestCase):
    def test_statuses_one_attempt(self):
        for code, state in [(200, 'success'), (400, 'failed'), (403, 'failed'), (429, 'failed'), (500, 'unknown')]:
            value = Response(200, b'{"id":"1","name":"test"}') if code == 200 else urllib.error.HTTPError('https://discord.com', code, '', {}, None)
            opener = Opener(value)
            self.assertEqual(w.write_once(REQUEST, opener)['state'], state)
            self.assertEqual(opener.calls, 1)
    def test_ambiguous_outcomes(self):
        for value in (TimeoutError(), ConnectionResetError(), Response(200, b'invalid'), Response(200, b'[]')):
            opener = Opener(value)
            self.assertEqual(w.write_once(REQUEST, opener)['state'], 'unknown')
            self.assertEqual(opener.calls, 1)
    def test_restricts_routes_and_methods(self):
        for method, path in [('PUT', '/applications/1/commands'), ('DELETE', '/applications/1/commands/2'),
                             ('POST', '/applications/1/commands/2'), ('PATCH', '/applications/1/commands')]:
            opener = Opener(Response(200, b'{}'))
            self.assertEqual(w.write_once(dict(REQUEST, method=method, path=path), opener)['state'], 'failed')
            self.assertEqual(opener.calls, 0)
if __name__ == '__main__': unittest.main()
