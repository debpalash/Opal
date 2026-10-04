#!/usr/bin/env python3
"""Owned RSS stall proves real Browse first paint and stale-wave exclusion.
Existing public podcast directories may also run; assertions only inspect the
owned fixture identities. No enclosure is downloaded or played.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import threading
import time
import unittest
from urllib.parse import quote, urlsplit
import test_setup_token_live as live


class Feed(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == '/slow':
            self.server.slow_started.set()
            self.server.release.wait(20)
        title = {'/slow': 'Fixture slow', '/fast': 'Fixture fast', '/fresh': 'Fresh replacement'}.get(path)
        if title is None:
            self.send_error(404)
            return
        body = f'<rss version="2.0"><channel><title>{title}</title><description>Original local test feed</description></channel></rss>'.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/rss+xml')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


class ProgressiveAudioBrowse(unittest.TestCase):
    def setUp(self):
        if live.BINARY is None:
            self.skipTest('pass --binary')
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Feed)
        self.server.release = threading.Event()
        self.server.slow_started = threading.Event()
        self.base = f'http://127.0.0.1:{self.server.server_port}'
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.addCleanup(self.server.release.set)
        self.opal = live.IsolatedOpal(self)
        self.addCleanup(self.opal.stop)
        self.addCleanup(self.server.release.set)
        profile = self.opal.config_root/'opal'
        sources = profile/'plugins'/'sources'
        sources.mkdir(parents=True)
        for provider, path in (('podcast-nasa', '/slow'), ('podcast-bbc', '/fast')):
            (sources/(provider+'.json')).write_text(json.dumps({'feed': self.base+path, '_v': '1.0.0'}))
        with live.database(profile/'opal.db') as db:
            db.execute("CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT NOT NULL DEFAULT '')")
            db.executemany('INSERT INTO config VALUES(?,?)', [('web_port', str(live.PORT)), ('web_bind', 'loopback'), ('content_cache_enabled', '0'), ('search_sources', '0')])
        token = self.opal.start()
        account = live.register('audio-browse-fixture', host=self.opal.loopback_authority, setup_token=token)
        self.assertEqual(account.status, 200)
        self.headers = (('Cookie', account.session_cookie()),)

    def api(self, path):
        reply = live.request('GET', '/api/'+path, host=self.opal.loopback_authority, extra_headers=self.headers)
        self.assertEqual(reply.status, 200)
        return reply.json()

    def until(self, predicate, timeout=6):
        end = time.monotonic()+timeout
        while time.monotonic() < end:
            data = self.api('podcasts')
            if predicate(data):
                return data
            time.sleep(.03)
        self.fail('Owned podcast fixture state did not appear before deadline')

    def start_overlapping(self):
        started = time.monotonic()
        self.api('podcasts/search?q=Fixture')
        fast = self.until(lambda d: any(r.get('name') == 'Fixture fast' for r in d['results']))
        self.assertTrue(self.server.slow_started.wait(1), 'independent slow feed must start concurrently')
        self.assertLess(time.monotonic()-started, 5)
        self.assertTrue(fast['loading'], 'fast rows must paint while slow siblings remain loading')
        self.assertFalse(any(r.get('name') == 'Fixture slow' for r in fast['results']))
        return fast

    def test_fast_feed_paints_before_stalled_feed_then_merges(self):
        self.start_overlapping()
        self.server.release.set()
        merged = self.until(lambda d: all(any(r.get('name') == name for r in d['results']) for name in ('Fixture fast', 'Fixture slow')))
        self.assertEqual(sum(r.get('name') == 'Fixture fast' for r in merged['results']), 1)

    def test_new_search_rejects_old_stalled_feed_publication(self):
        self.start_overlapping()
        self.api('podcasts/search?q='+quote(self.base+'/fresh', safe=''))
        self.until(lambda d: not d['loading'] and len(d['results']) == 1 and d['results'][0].get('name') == 'Fresh replacement')
        self.server.release.set()
        time.sleep(.3)
        current = self.api('podcasts')
        self.assertEqual([r.get('name') for r in current['results']], ['Fresh replacement'])
        self.assertFalse(current['loading'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--port', type=int, default=41809)
    args, remaining = parser.parse_known_args()
    live.BINARY = args.binary.resolve()
    live.PORT = args.port
    unittest.main(argv=[__file__]+remaining)
