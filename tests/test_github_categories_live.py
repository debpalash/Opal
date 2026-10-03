#!/usr/bin/env python3
"""Fresh-profile category actions: owned podcast silence fixture; opt-in real ComicFury PNG reader."""
import argparse
import io
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sqlite3
import threading
import time
import unittest
from urllib.parse import urlencode, urlsplit
import wave
import test_setup_token_live as live

LIVE_PROVIDERS = False

class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if urlsplit(self.path).path == '/feed.xml':
            base = self.server.base
            body = (f"<rss><channel><title>Fixture podcast</title><item><title>Fixture episode</title>"
                    f"<enclosure url='{base}/cover.jpg' type='image/jpeg'/>"
                    f"<enclosure url='{base}/silence.wav' type='audio/wav'/></item></channel></rss>").encode()
            kind = 'application/rss+xml'
        elif urlsplit(self.path).path == '/silence.wav':
            output = io.BytesIO()
            with wave.open(output, 'wb') as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(8000)
                wav.writeframes(b'\0\0' * 80000)
            body = output.getvalue()
            kind = 'audio/wav'
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

class CategoryActions(unittest.TestCase):
    def setUp(self):
        self.fixture = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        self.fixture.base = f'http://127.0.0.1:{self.fixture.server_port}'
        threading.Thread(target=self.fixture.serve_forever, daemon=True).start()
        self.addCleanup(self.fixture.server_close)
        self.addCleanup(self.fixture.shutdown)
        self.opal = live.IsolatedOpal(self)
        self.addCleanup(self.opal.stop)
        profile = self.opal.config_root / 'opal'
        sources = profile / 'plugins' / 'sources'
        sources.mkdir(parents=True)
        (sources / 'comicfury.json').write_text(json.dumps({'base': 'https://comicfury.com'}))
        (sources / 'podcast-waveform.json').write_text(json.dumps({'feed': self.fixture.base + '/feed.xml'}))
        with sqlite3.connect(profile / 'opal.db') as db:
            db.execute("CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT NOT NULL DEFAULT '')")
            db.executemany('INSERT INTO config VALUES(?,?)', [('web_port', str(live.PORT)), ('web_bind', 'loopback'), ('search_sources', '32'), ('auto_download_subs', '0'), ('playback_volume', '0'), ('content_cache_enabled', '0')])
        token = self.opal.start()
        account = live.register('category-fixture', host=self.opal.loopback_authority, setup_token=token)
        self.assertEqual(account.status, 200, account.body)
        self.headers = (('Cookie', account.session_cookie()),)

    def api(self, path, method='GET'):
        reply = live.request(method, '/api/' + path, host=self.opal.loopback_authority, extra_headers=self.headers)
        self.assertEqual(reply.status, 200, reply.body[:1024])
        return reply.json()

    def until(self, path, predicate, timeout=55):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            data = self.api(path)
            if predicate(data):
                return data
            time.sleep(.15)
        self.fail(f'{path} did not settle: {data}')

    def test_podcast_audio_selection_reaches_opal_decoder(self):
        self.api('podcasts/search?' + urlencode({'q': self.fixture.base + '/feed.xml'}))
        self.until('podcasts', lambda d: bool(d['results']) and not d.get('loading'))
        self.api('podcasts/episodes?idx=0')
        data = self.until('podcasts', lambda d: bool(d['episodes']) and not d.get('episodes_loading'))
        self.assertEqual(len(data['episodes']), 1)
        self.assertEqual(data['episodes'][0]['url'], self.fixture.base + '/silence.wav')
        self.api('podcasts/play?' + urlencode({'idx': 0, 'generation': data['generation']}), 'POST')
        self.until('status', lambda d: d.get('active') and d.get('dur', 0) > 0)
        print('Podcast fixture: real Opal decoder active, duration > 0; image enclosure skipped', flush=True)

    def test_comicfury_public_search_action_keeps_browse_and_serves_png(self):
        if not LIVE_PROVIDERS:
            self.skipTest('real provider reading requires --live-providers')
        before = self.until('comics/results', lambda d: not d.get('loading'))
        self.api('unified_search?' + urlencode({'q': 'The Dragon in you'}))
        data = self.until('unified_search', lambda d: not d['loading'])
        rows = [r for r in data['results'] if r.get('provider') == 'comicfury']
        self.assertTrue(rows, data)
        row = next((r for r in rows if r['title'] == 'The Dragon in you'), rows[0])
        self.assertTrue(row.get('poster_url'), row)
        self.api('unified_search/play?' + urlencode({'generation': data['generation'], 'key': row['key']}), 'POST')
        reader = self.until('comics', lambda d: d.get('pages', 0) > 0 and d.get('downloaded', 0) > 0 and not d['loading'])
        after = self.api('comics/results')
        self.assertEqual(after['results'], before['results'])
        reply = live.request('GET', '/api/comics/page?i=0', host=self.opal.loopback_authority, extra_headers=self.headers)
        self.assertEqual(reply.status, 200)
        self.assertTrue(reply.body.startswith(b'\x89PNG\r\n\x1a\n'), reply.body[:40])
        print(f'ComicFury: {len(rows)} universal works; {reader["pages"]} reader pages; PNG {len(reply.body)} bytes; Browse preserved', flush=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True)
    parser.add_argument('--port', type=int, default=41712)
    parser.add_argument('--live-providers', action='store_true')
    args, rest = parser.parse_known_args()
    live.BINARY = Path(args.binary).resolve()
    live.PORT = args.port
    LIVE_PROVIDERS = args.live_providers
    unittest.main(argv=[__file__, *rest], verbosity=2)
