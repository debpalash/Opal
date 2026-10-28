#!/usr/bin/env python3
"""Opt-in live Music timing with an isolated profile and pinned track identities.

Measures click to matching title and advancing audio clock, not speaker output.
Run without competing compilers; public-provider latency is not deterministic.
"""
import argparse
import json
from pathlib import Path
import time
import unittest
from urllib.parse import urlencode

import test_setup_token_live as live


class MusicPlaybackBenchmark(unittest.TestCase):
    def runTest(self):
        app = live.IsolatedOpal(self)
        self.addCleanup(app.stop)
        token = app.start()
        account = live.register('music-benchmark', host=app.loopback_authority, setup_token=token)
        self.assertEqual(account.status, 200)
        headers = (('Cookie', account.session_cookie()),)

        def request(method, path):
            response = live.request(method, path, host=app.loopback_authority, extra_headers=headers)
            self.assertEqual(response.status, 200)
            return response.json()

        pinned = {}
        previous_title = None
        for repeat in range(REPETITIONS):
            for source in (0, 7):
                request('POST', f'/api/music/source?id={source}')
                started = time.monotonic()
                songs = []
                while time.monotonic() - started < 45:
                    result = request('GET', '/api/music')
                    if result['source'] == source and not result['loading'] and result['songs']:
                        songs = result['songs']
                        break
                    time.sleep(.1)
                self.assertTrue(songs, 'catalog unavailable')
                catalog_ms = round((time.monotonic() - started) * 1000)
                if source in pinned:
                    songs = [song for song in songs if song['id'] == pinned[source]]
                    self.assertTrue(songs, 'pinned track missing on revisit; comparison is invalid')
                else:
                    # Distinct titles make the readiness gate reject the old track.
                    songs = [song for song in songs if song['title'] != previous_title]
                    self.assertTrue(songs)
                    pinned[source] = songs[0]['id']
                song = songs[0]
                self.assertNotEqual(previous_title, song['title'])
                started = time.monotonic()
                request('POST', '/api/music/play?' + urlencode({'source': source, 'id': song['id']}))
                ready = False
                while time.monotonic() - started < 45:
                    status = request('GET', '/api/status')
                    if (status.get('title') == song['title'] and not status.get('loading')
                            and not status.get('error') and status.get('pos', 0) > .2):
                        ready = True
                        break
                    time.sleep(.05)
                row = {'source': source, 'repeat': repeat, 'catalog_ms': catalog_ms,
                       'playback_ms': round((time.monotonic() - started) * 1000), 'ready': ready}
                RESULTS.append(row)
                print(json.dumps(row), flush=True)
                self.assertTrue(ready, 'track did not start')
                previous_title = song['title']


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--port', type=int, default=41863)
    parser.add_argument('--repetitions', type=int, default=2)
    parser.add_argument('--results', type=Path)
    args = parser.parse_args()
    live.BINARY = args.binary.resolve()
    live.PORT = args.port
    REPETITIONS = max(1, args.repetitions)
    RESULTS = []
    result = unittest.TextTestRunner(verbosity=1).run(MusicPlaybackBenchmark())
    if args.results:
        args.results.write_text(json.dumps(RESULTS, indent=2) + '\n')
    raise SystemExit(0 if result.wasSuccessful() else 1)
