import copy
import importlib.util
import pathlib
import time
import unittest
import unittest.mock
import urllib.error

path = pathlib.Path(__file__).resolve().parents[1] / 'tools' / 'migrate_permissions.py'
specification = importlib.util.spec_from_file_location('migration', path)
m = importlib.util.module_from_spec(specification)
specification.loader.exec_module(m)
SPEC = {'description': 'new', 'options': [{'type': 1, 'name': 'allow', 'description': 'Allow'}]}
OLD = {'id': m.COMMAND_ID, 'application_id': '123', 'type': 1, 'name': 'permissions',
       'description': m.OLD_DESCRIPTION, 'integration_types': [0, 1], 'nsfw': False}

class Tests(unittest.TestCase):
    def run_case(self, patch_status=200, patch_body=None, old=None, read=None):
        calls = []
        old = copy.deepcopy(OLD if old is None else old)
        def call(method, path, token, payload=None):
            calls.append((method, path, payload))
            if path == '/oauth2/applications/@me': return 200, {'id': '123'}
            if method == 'GET' and path.endswith('/commands'): return 200, [old]
            if method == 'PATCH':
                new = dict(old, **SPEC) if patch_body is None else patch_body
                return patch_status, new
            if method == 'GET': return (200, old) if read is None else read
            self.fail('unexpected request')
        return m.migrate('fixture', SPEC, call), calls
    def test_success_once_and_metadata(self):
        result, calls = self.run_case()
        self.assertEqual(result, 'migrated')
        self.assertEqual([c[0] for c in calls], ['GET', 'GET', 'PATCH'])
        self.assertEqual(calls[-1][2], SPEC)
    def test_definite_errors_do_not_retry(self):
        for status in (400, 403, 429):
            result, calls = self.run_case(status)
            self.assertEqual(result, 'http_error_' + str(status))
            self.assertEqual([c[0] for c in calls], ['GET', 'GET', 'PATCH'])
    def test_uncertain_outcomes_are_read_only(self):
        for status in (500, 'timeout', 'network_error', 'invalid_response'):
            result, calls = self.run_case(status)
            self.assertEqual(result, 'uncertain_observed_legacy')
            self.assertEqual([c[0] for c in calls], ['GET', 'GET', 'PATCH', 'GET'])
        result, calls = self.run_case('timeout', read=(200, dict(OLD, **SPEC)))
        self.assertEqual(result, 'uncertain_observed_migrated')
    def test_unexpected_response_is_ambiguous(self):
        result, calls = self.run_case(200, {'id': m.COMMAND_ID})
        self.assertEqual(result, 'uncertain_observed_legacy')
        self.assertEqual(sum(c[0] == 'PATCH' for c in calls), 1)
    def test_metadata_change_is_ambiguous(self):
        result, calls = self.run_case(200, dict(OLD, **SPEC, integration_types=[0]))
        self.assertEqual(result, 'uncertain_observed_legacy')
        self.assertEqual(sum(c[0] == 'PATCH' for c in calls), 1)
    def test_reject_wrong_id_scope_and_options(self):
        for old in (dict(OLD, id='999'), dict(OLD, guild_id='111'), dict(OLD, options=[{'type': 1}]), dict(OLD, application_id='999')):
            result, calls = self.run_case(old=old)
            self.assertEqual(result, 'preflight_failed')
            self.assertFalse(any(c[0] == 'PATCH' for c in calls))
    def test_already_migrated(self):
        result, calls = self.run_case(old=dict(OLD, **SPEC))
        self.assertEqual(result, 'already_migrated')
        self.assertFalse(any(c[0] == 'PATCH' for c in calls))
    def test_total_deadline_kills_worker(self):
        original_worker, original_timeout = m._worker, m.TIMEOUT
        def slow(conn, *args): time.sleep(3)
        try:
            m._worker, m.TIMEOUT = slow, 0.05
            start = time.monotonic()
            self.assertEqual(m.request('PATCH', '/fixture', 'fixture'), ('timeout', None))
            self.assertLess(time.monotonic() - start, 2)
        finally:
            m._worker, m.TIMEOUT = original_worker, original_timeout
    def test_worker_http_responses_and_invalid_json(self):
        class Response:
            status = 200
            def __init__(self, body): self.body = body
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, limit): return self.body
        class Opener:
            def __init__(self, response): self.response = response
            def open(self, request, timeout):
                if isinstance(self.response, Exception): raise self.response
                return self.response
        for response, expected in ((Response(b'{"ok":true}'), (200, {'ok': True})),
                                   (Response(b'{broken'), ('invalid_response', None)),
                                   (urllib.error.HTTPError('https://discord.com', 429, 'limited', {}, None), (429, None)),
                                   (OSError('offline'), ('network_error', None))):
            with unittest.mock.patch.object(m.urllib.request, 'build_opener', return_value=Opener(response)):
                self.assertEqual(m.request('PATCH', '/fixture', 'fixture'), expected)

if __name__ == '__main__': unittest.main()
