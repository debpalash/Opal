#!/usr/bin/env python3
"""Hermetic real Browse overlap, incremental publication and stale cancellation.
Only original local HTML fixtures; external default providers hit a rejecting
owned CONNECT proxy. No media, personal credentials or profile are accessed.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import select
import socket
import sqlite3
import threading
import time
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlencode, urlsplit
import test_setup_token_live as live


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_CONNECT(self):
        self.send_response(503)
        self.send_header('Content-Length', '0')
        self.end_headers()
    def do_GET(self):
        parsed = urlsplit(self.path)
        params = parse_qs(parsed.query)
        q = next((params[k][0] for k in ('text', 'query', 'combinedquery', 'title', 'keyword') if k in params), '')
        path = parsed.path
        slow = path.startswith(('/comicfury/', '/royalroad/'))
        if q == 'fail' and slow:
            self.send_error(503)
            return
        role = 'slow' if slow else 'fast'
        title = f'{q} Fixture {role}'
        slug = f'{q}-{role}'
        if path.startswith('/comicfury/'):
            body = f"<div class='webcomic-results'><a href='/comicprofile.php?url={slug}'>{title}</a></div>"
        elif path.startswith('/weebcentral/'):
            body = f"<a href='/series/{slug}'>{title}</a>"
        elif path.startswith('/royalroad/'):
            body = f'<div class="fiction-list"><a href="/fiction/{slug}">{title}</a></div>'
        elif path.startswith('/novelfire/'):
            body = f'<div class="novel-list horizontal col2 chapters"><a href="/book/{slug}">{title}</a></div>'
        else:
            self.send_error(404)
            return
        data = body.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        try:
            if slow and q in ('overlap', 'old'):
                self.wfile.write(data[:1]); self.wfile.flush()
                self.server.started.set()
                deadline = time.monotonic() + 12
                while not self.server.release.is_set() and time.monotonic() < deadline:
                    ready, _, _ = select.select([self.connection], [], [], .03)
                    if ready and self.connection.recv(1, socket.MSG_PEEK) == b'':
                        self.server.closed.set()
                        return
                self.wfile.write(data[1:])
            else:
                self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError, OSError):
            self.server.closed.set()


class ParallelBrowse(unittest.TestCase):
    def setUp(self):
        self.fixture = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
        self.fixture.started = threading.Event()
        self.fixture.release = threading.Event()
        self.fixture.closed = threading.Event()
        self.base = f'http://127.0.0.1:{self.fixture.server_port}'
        threading.Thread(target=self.fixture.serve_forever, daemon=True).start()
        self.addCleanup(self.fixture.server_close)
        self.addCleanup(self.fixture.shutdown)
        self.opal = live.IsolatedOpal(self)
        self.addCleanup(self.opal.stop)
        self.addCleanup(self.fixture.release.set)
        profile = self.opal.config_root/'opal'
        sources = profile/'plugins'/'sources'
        sources.mkdir(parents=True)
        for provider in ('comicfury', 'weebcentral', 'royalroad', 'novelfire'):
            (sources/(provider+'.json')).write_text(json.dumps({'base': self.base+'/'+provider, '_v': '1.0.0'}), encoding='utf-8')
        with sqlite3.connect(profile/'opal.db') as db:
            db.execute("CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT NOT NULL DEFAULT '')")
            db.executemany('INSERT INTO config VALUES(?,?)', [('web_port', str(live.PORT)), ('web_bind', 'loopback'), ('content_cache_enabled', '0'), ('search_sources', '0'), ('scrape_use_browser', '0')])
        env = {'HTTPS_PROXY': self.base, 'https_proxy': self.base, 'NO_PROXY': 'localhost,127.0.0.1,::1', 'no_proxy': 'localhost,127.0.0.1,::1', 'ALL_PROXY': '', 'all_proxy': ''}
        with patch.dict(os.environ, env): token = self.opal.start()
        reply = live.register('browse-fixture', host=self.opal.loopback_authority, setup_token=token)
        self.assertEqual(reply.status, 200)
        self.headers = (('Cookie', reply.session_cookie()),)
    def api(self, path):
        reply = live.request('GET', '/api/'+path, host=self.opal.loopback_authority, extra_headers=self.headers)
        self.assertEqual(reply.status, 200, reply.body[:300])
        return reply.json()
    def snapshot(self, category):
        return self.api('comics/results' if category == 'comics' else 'novels')
    def until(self, category, predicate, timeout=8):
        deadline = time.monotonic()+timeout
        data = None
        while time.monotonic() < deadline:
            data = self.snapshot(category)
            if predicate(data): return data
            time.sleep(.03)
        self.fail(f'{category} did not publish/settle: {data}')
    def search(self, category, query):
        self.api(category+'/search?'+urlencode({'q': query}))
    @staticmethod
    def titles(data): return [r['title'] for r in data['results']]
    def overlap(self, category):
        started = time.monotonic()
        self.search(category, 'overlap')
        self.assertTrue(self.fixture.started.wait(4), 'slow provider did not start')
        data = self.until(category, lambda d: 'overlap Fixture fast' in self.titles(d), 4)
        self.assertTrue(data['loading'], 'whole wave finished before blocked provider')
        self.assertFalse(self.fixture.release.is_set())
        print(f'{category}: first useful rows before blocked provider, {time.monotonic()-started:.3f}s', flush=True)
        self.fixture.release.set()
        data = self.until(category, lambda d: not d['loading'])
        self.assertEqual(self.titles(data).count('overlap Fixture fast'), 1)
        self.assertEqual(self.titles(data).count('overlap Fixture slow'), 1)
    def stale(self, category):
        self.search(category, 'old')
        self.assertTrue(self.fixture.started.wait(4))
        self.until(category, lambda d: 'old Fixture fast' in self.titles(d), 4)
        self.search(category, 'fresh')
        self.assertTrue(self.fixture.closed.wait(1), 'superseded provider socket remained open')
        data = self.until(category, lambda d: not d['loading'] and 'fresh Fixture fast' in self.titles(d))
        self.assertIn('fresh Fixture slow', self.titles(data))
        self.assertFalse(any(t.startswith('old ') for t in self.titles(data)), data)
    def test_comics_overlap(self): self.overlap('comics')
    def test_novels_overlap(self): self.overlap('novels')
    def test_comics_stale(self): self.stale('comics')
    def test_novels_stale(self): self.stale('novels')
    def test_partial_failure_keeps_successful_results(self):
        for category in ('comics', 'novels'):
            with self.subTest(category=category):
                self.search(category, 'fail')
                data = self.until(category, lambda d: not d['loading'] and 'fail Fixture fast' in self.titles(d))
                self.assertNotIn('fail Fixture slow', self.titles(data))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True)
    parser.add_argument('--port', type=int, default=41819)
    args, rest = parser.parse_known_args()
    live.BINARY = Path(args.binary).resolve(); live.PORT = args.port
    unittest.main(argv=[__file__, *rest], verbosity=2)
