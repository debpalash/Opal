#!/usr/bin/env python3
"""Opt-in live JioSaavn/YouTube Music smoke test in an isolated Opal profile."""
import argparse
from pathlib import Path
import time
import unittest
import test_setup_token_live as live

class MusicCatalog(unittest.TestCase):
    def test_catalog_loads_without_query_and_retains_track_identity(self):
        app = live.IsolatedOpal(self)
        self.addCleanup(app.stop)
        setup = app.start()
        account = live.register("music-catalog-owner", host=app.loopback_authority, setup_token=setup)
        self.assertEqual(account.status, 200)
        headers = (("Cookie", account.session_cookie()),)

        def request(method, path):
            response = live.request(method, path, host=app.loopback_authority, extra_headers=headers)
            self.assertEqual(response.status, 200, response.body[:200])
            return response.json()

        def loaded(source):
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                result = request("GET", "/api/music")
                if not result['loading']:
                    self.assertEqual(result['source'], source)
                    self.assertGreater(len(result['songs']), 0, result)
                    for song in result['songs']:
                        self.assertTrue(song['id'])
                        self.assertTrue(song['title'])
                        self.assertTrue(song['url'].startswith('https://'))
                    print(f"PASS: source {source} loaded {len(result['songs'])} tracks with IDs", flush=True)
                    return
                time.sleep(.25)
            self.fail(f"source {source} timed out")

        loaded(0)  # First visit, no explicit search.
        request("POST", "/api/music/source?id=7")
        loaded(7)  # Source change, no explicit search.
        request("POST", "/api/music/search?q=Daft%20Punk")
        loaded(7)
        request("POST", "/api/music/source?id=0")
        request("POST", "/api/music/search?q=")
        loaded(0)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--port', type=int, default=41731)
    args = parser.parse_args()
    live.BINARY = args.binary.resolve()
    live.PORT = args.port
    unittest.main(argv=[__file__], verbosity=2)
