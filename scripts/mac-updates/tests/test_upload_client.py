import io
import json
import pathlib
import ssl
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from upload_client import MAXIMUM_RESPONSE, ORIGIN, UploadClient


class Response:
    def __init__(self, status=200, data=None, content_type='application/json'):
        self.status = status
        self.raw = json.dumps(data).encode()
        self.content_type = content_type

    def read(self, limit):
        return self.raw[:limit]

    def getheader(self, key, default=None):
        return self.content_type if key == 'Content-Type' else default


class Connection:
    def __init__(self, response):
        self.response = response
        self.requests = []
        self.closed = False

    def request(self, method, path, body=None, headers=None):
        if body is not None:
            assert isinstance(body, io.BufferedReader)
            body = body.read()
        self.requests.append((method, path, body, headers))

    def getresponse(self):
        return self.response

    def close(self):
        self.closed = True


class UploadClientTests(unittest.TestCase):
    def setUp(self):
        self.client = UploadClient({'base_url': ORIGIN, 'timeout_seconds': 180})

    def test_only_exact_fixed_origin_and_bounded_timeout_are_allowed(self):
        for base, timeout in [('http://deploy.chongyang.asia', 180), (ORIGIN + '/other', 180),
                              ('https://example.com', 180), (ORIGIN, True), (ORIGIN, 0)]:
            with self.assertRaises(ValueError):
                UploadClient({'base_url': base, 'timeout_seconds': timeout})

    def test_raw_file_stream_has_exact_length_and_ingest_path(self):
        connection = Connection(Response(data={'test': True}))
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'package.ycu'
            path.write_bytes(b'unit-test-raw-package')
            with mock.patch.object(self.client, '_connection', return_value=connection):
                self.assertEqual(self.client.upload(path), {'test': True})
        method, url, body, headers = connection.requests[0]
        self.assertEqual((method, url, body), ('POST', '/api/yingchui-mac/ingest', b'unit-test-raw-package'))
        self.assertEqual(headers['Content-Length'], str(len(body)))
        self.assertEqual(headers['Content-Type'], 'application/octet-stream')
        self.assertTrue(connection.closed)

    def test_undeployed_redirect_auth_and_conflict_never_call_legacy_upload(self):
        for status in [301, 307, 401, 403, 404, 409, 413, 500, 503]:
            connection = Connection(Response(status, {'error': {'code': 'test'}}))
            with mock.patch.object(self.client, '_connection', return_value=connection):
                with self.assertRaises(RuntimeError):
                    self.client.request('releases')
            self.assertEqual(len(connection.requests), 1)
            self.assertTrue(connection.closed)

    def test_large_malformed_and_html_responses_fail(self):
        invalid_json = Response()
        invalid_json.raw = b'{broken'
        huge = Response()
        huge.raw = b' ' * (MAXIMUM_RESPONSE + 1)
        for response in [invalid_json, huge, Response(content_type='text/html')]:
            with mock.patch.object(self.client, '_connection', return_value=Connection(response)):
                with self.assertRaises(RuntimeError):
                    self.client.request('releases')

    def test_network_and_certificate_failures_are_chinese(self):
        for error in [TimeoutError('timed out'), ssl.SSLError('certificate error'), ConnectionError('closed')]:
            connection = Connection(Response())
            with mock.patch.object(self.client, '_connection', return_value=connection), mock.patch.object(connection, 'request', side_effect=error):
                with self.assertRaises(RuntimeError) as found:
                    self.client.request('releases')
            self.assertIsNone(__import__('re').search('[A-Za-z]', str(found.exception)))
            self.assertTrue(connection.closed)

    def test_release_lookup_rejects_duplicate_or_unavailable_lists(self):
        valid = {'release_id': 'abc'}
        with mock.patch.object(self.client, 'request', return_value={'updates_available': True, 'releases': [valid]}):
            self.assertEqual(self.client.find_release('abc'), valid)
            self.assertIsNone(self.client.find_release('def'))
        for data in [{'updates_available': False, 'releases': []},
                     {'updates_available': True, 'releases': [valid, valid]},
                     {'updates_available': True, 'releases': [None]}]:
            with mock.patch.object(self.client, 'request', return_value=data):
                with self.assertRaises(ValueError):
                    self.client.find_release('abc')


if __name__ == '__main__':
    unittest.main()
