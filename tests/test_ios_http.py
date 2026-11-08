"""Run the real Foundation transport against owned local HTTP fixtures."""
import ctypes as c
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
CANCEL = c.CFUNCTYPE(c.c_bool, c.c_void_p)


class Request(c.Structure):
    _fields_ = [('url', c.c_char_p), ('method', c.c_char_p), ('headers_json', c.c_char_p),
                ('payload', c.c_void_p), ('payload_len', c.c_size_t),
                ('body', c.c_void_p), ('body_capacity', c.c_size_t), ('body_len', c.c_size_t),
                ('headers', c.c_void_p), ('header_capacity', c.c_size_t), ('header_len', c.c_size_t),
                ('timeout_seconds', c.c_uint32), ('status', c.c_uint16),
                ('follow_redirects', c.c_bool), ('https_only', c.c_bool),
                ('cancelled', CANCEL), ('cancel_context', c.c_void_p)]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith('/redirect'):
            self.send_response(302)
            host = 'localhost' if self.path == '/redirect-cross' else '127.0.0.1'
            self.send_header('Location', f'http://{host}:{self.server.server_port}/ok')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path in ('/large', '/chunks'):
            body = b'x' * 4096
        else:
            body = json.dumps({'auth': self.headers.get('Authorization'), 'agent': self.headers.get('User-Agent'), 'range': self.headers.get('Range')}).encode()
        self.send_response(200)
        if self.path != '/chunks':
            self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if self.path == '/slow':
            time.sleep(3)
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


@unittest.skipUnless(sys.platform == 'darwin', 'Foundation requires Apple SDK')
class FoundationHttpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        output = ROOT / '.zig-cache/ios-native-tests/http.dylib'
        output.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-framework', 'Foundation',
                        str(ROOT / 'mobile/ios/http.m'), '-o', str(output)], check=True, capture_output=True)
        cls.library = c.CDLL(str(output))
        cls.call = cls.library.opal_apple_http_request
        cls.call.argtypes = [c.POINTER(Request)]
        cls.call.restype = c.c_int
        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def fetch(self, path='/ok', capacity=4096, headers=(), payload=None, follow=True, https=False, cancel_after=None):
        body = c.create_string_buffer(capacity)
        response_headers = c.create_string_buffer(4096)
        started = time.monotonic()
        callback = CANCEL(lambda _: cancel_after is not None and time.monotonic() - started >= cancel_after)
        request = Request(url=f'http://127.0.0.1:{self.server.server_port}{path}'.encode(),
                          method=b'POST' if payload is not None else b'GET',
                          headers_json=json.dumps(list(headers)).encode(), payload=c.cast(c.c_char_p(payload), c.c_void_p) if payload else None,
                          payload_len=len(payload or b''), body=c.cast(body, c.c_void_p), body_capacity=capacity,
                          headers=c.cast(response_headers, c.c_void_p), header_capacity=4096,
                          timeout_seconds=1, follow_redirects=follow, https_only=https, cancelled=callback)
        # Foundation must run on a worker, as it does in Opal's shared services.
        result = []
        worker = threading.Thread(target=lambda: result.append(self.call(c.byref(request))))
        worker.start(); worker.join(5)
        self.assertFalse(worker.is_alive(), 'request did not finish within its deadline')
        return result[0], request.status, body.raw[:request.body_len], response_headers.raw[:request.header_len]

    def test_headers_payload_and_status_are_preserved(self):
        code, status, body, headers = self.fetch(headers=[{'name': 'User-Agent', 'value': 'OwnedFixture'}, {'name': 'Range', 'value': 'bytes=10-20'}])
        self.assertEqual((code, status), (0, 200))
        self.assertEqual(json.loads(body)['agent'], 'OwnedFixture')
        self.assertEqual(json.loads(body)['range'], 'bytes=10-20')
        self.assertTrue(headers.startswith(b'HTTP/1.1 200'))
        self.assertEqual(self.fetch(payload=b'owned-post-body')[2], b'owned-post-body')

    def test_redirects_keep_same_origin_auth_and_strip_cross_origin_auth(self):
        auth = [{'name': 'Authorization', 'value': 'Bearer owned-fixture'}]
        self.assertEqual(json.loads(self.fetch('/redirect', headers=auth)[2])['auth'], 'Bearer owned-fixture')
        self.assertIsNone(json.loads(self.fetch('/redirect-cross', headers=auth)[2])['auth'])
        self.assertEqual(self.fetch('/redirect', follow=False)[1], 302)

    def test_advertised_and_unadvertised_oversized_bodies_are_bounded(self):
        for path in ['/large', '/chunks']:
            code, _, body, _ = self.fetch(path, capacity=8)
            self.assertEqual(code, 2)
            self.assertLessEqual(len(body), 8)

    def test_timeout_cancellation_and_https_policy(self):
        self.assertEqual(self.fetch('/slow')[0], 3)
        self.assertEqual(self.fetch('/slow', cancel_after=0.1)[0], 5)
        self.assertEqual(self.fetch(https=True)[0], 1)


if __name__ == '__main__':
    unittest.main()
