#!/usr/bin/env python3
"""Headless resolver publication must reach mpv without a GUI frame.

Uses an owned profile, copied binary, fake Streamlink helper and local HTTP WAV.
Run with --binary /path/to/headless/opal --port <unused port>.
"""
import functools
import http.server
from pathlib import Path
import shutil
import sys
import tempfile
import threading
import time
import unittest
import wave

import test_setup_token_live as harness


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


class HeadlessPlaybackTests(unittest.TestCase):
    def setUp(self):
        if harness.BINARY is None:
            self.skipTest('pass --binary or OPAL_HEADLESS_BIN')
        self.fixture = tempfile.TemporaryDirectory(prefix='opal-headless-playback-')
        self.addCleanup(self.fixture.cleanup)
        self.root = Path(self.fixture.name)
        self.original_binary = harness.BINARY
        self.original_cwd = harness.REPO_ROOT
        harness.REPO_ROOT = self.root
        # Development binaries can resolve this wrapper relative to cwd.
        for name in ('libtorrent_wrapper.so', 'libtorrent_wrapper.dylib'):
            library = self.original_cwd / name
            if library.exists():
                (self.root / name).symlink_to(library)
        self.addCleanup(setattr, harness, 'REPO_ROOT', self.original_cwd)
        copied = self.root / harness.BINARY.name
        shutil.copy2(harness.BINARY, copied)
        harness.BINARY = copied
        self.addCleanup(setattr, harness, 'BINARY', self.original_binary)
        with wave.open(str(self.root / 'silence.wav'), 'wb') as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(8000)
            wav.writeframes(bytes(2 * 8000 * 30))
        self.server = http.server.ThreadingHTTPServer(
            ('127.0.0.1', 0), functools.partial(QuietHandler, directory=str(self.root)))
        self.addCleanup(self.server.server_close)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.shutdown)
        self.opal = harness.IsolatedOpal(self)
        self.addCleanup(self.opal.stop)

    def test_streamlink_completion_loads_local_media_without_window(self):
        url = f'http://127.0.0.1:{self.server.server_port}/silence.wav'
        marker = self.root / 'resolver-invoked'
        helper = (
            'from pathlib import Path\n'
            f'Path({str(marker)!r}).write_text("invoked")\n'
            f'print({url!r})\n'
        )
        (self.root / 'streamlink_resolve.py').write_text(helper)
        # Some platforms use the process cwd fallback for bundled helpers.
        (self.root / 'bin').mkdir()
        (self.root / 'bin' / 'streamlink_resolve.py').write_text(helper)
        token = self.opal.start()
        claimed = harness.register('playback-owner', host=self.opal.loopback_authority, setup_token=token)
        self.assertEqual(claimed.status, 200, claimed.body)
        headers = (("Cookie", claimed.session_cookie()),)
        loaded = harness.request('POST', '/api/load', host=self.opal.loopback_authority,
                                 extra_headers=headers, form={'url': 'https://www.twitch.tv/opal-local-fixture'})
        self.assertEqual(loaded.status, 200, loaded.body)
        deadline = time.monotonic() + 15
        last = None
        while time.monotonic() < deadline:
            result = harness.request('GET', '/api/status', host=self.opal.loopback_authority, extra_headers=headers)
            self.assertEqual(result.status, 200, result.body)
            last = result.json()
            if (marker.exists() and last.get('dur', 0) >= 29
                    and last.get('pos', 0) > 0 and not last.get('loading')):
                self.assertFalse(last.get('error'), last)
                return
            time.sleep(.1)
        self.fail(f'resolver publication never reached mpv: helper={marker.exists()}, status={last}')


if __name__ == '__main__':
    args, rest = harness.parse_args()
    harness.PORT = args.port
    if args.binary:
        harness.BINARY = Path(args.binary).expanduser().resolve()
    unittest.main(argv=[sys.argv[0], *rest], verbosity=2)
