#!/usr/bin/env python3
"""Hermetic 905-chapter reader traversal and same-title resume isolation."""
import argparse
import http.server
import json
import os
from pathlib import Path
import sqlite3
import ssl
import subprocess
import threading
import time
import unittest
from urllib.parse import urlencode
import test_setup_token_live as live


class NovelWindowsTest(unittest.TestCase):
    def setUp(self):
        self.opal = live.IsolatedOpal(self)
        self.addCleanup(self.opal.stop)
        self.prepend = False
        owner = self
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if '/api/chapters/' in self.path:
                    book = self.path.split('/api/chapters/')[1].split('/')[0]
                    ids = list(range(1, 906))
                    if owner.prepend and book == 'book-a': ids.insert(0, 0)
                    body = [{'title': f'Chapter {i}', 'novSlugChapSlug': f'{book}-{i}'} for i in ids]
                elif '/api/getchapter/' in self.path:
                    identity = self.path.split('/api/getchapter/')[1].split('/')[0]
                    body = {'text': f'Exact chapter identity: {identity}. ' + 'Readable prose. ' * 30}
                else:
                    self.send_error(404); return
                payload = json.dumps(body, separators=(',', ':')).encode()
                self.send_response(200); self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(payload))); self.end_headers(); self.wfile.write(payload)
            def log_message(self, *args): pass
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.addCleanup(self.server.server_close)
        cert = self.opal.config_root / 'fixture.pem'
        key = self.opal.config_root / 'fixture.key'
        cert.parent.mkdir(parents=True, exist_ok=True)
        cert_config = cert.parent / 'fixture-openssl.cnf'
        cert_config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost\nbasicConstraints=CA:TRUE\n')
        subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1',
                        '-config',str(cert_config),
                        '-keyout',str(key),'-out',str(cert)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(cert, key)
        self.server.socket = context.wrap_socket(self.server.socket, server_side=True)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.shutdown)
        self.base = f'https://localhost:{self.server.server_port}'
        profile = self.opal.config_root / 'opal'
        sources = profile / 'plugins' / 'sources'; sources.mkdir(parents=True)
        (sources / 'wuxiaclick.json').write_text(json.dumps({'base':self.base,'_v':'1.0.0'}))
        with sqlite3.connect(profile / 'opal.db') as db:
            db.execute("CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT NOT NULL DEFAULT '')")
            db.executemany('INSERT INTO config VALUES(?,?)', [('web_port',str(live.PORT)),('web_bind','loopback'),('content_cache_enabled','0'),('auto_download_subs','0')])
        old = os.environ.get('CURL_CA_BUNDLE'); os.environ['CURL_CA_BUNDLE'] = str(cert)
        try: token = self.opal.start()
        finally:
            if old is None: os.environ.pop('CURL_CA_BUNDLE', None)
            else: os.environ['CURL_CA_BUNDLE'] = old
        account = live.register('chapter-window-fixture',host=self.opal.loopback_authority,setup_token=token)
        self.assertEqual(account.status,200,account.body)
        self.headers = (('Cookie',account.session_cookie()),)

    def request(self, path, status=200):
        reply=live.request('POST' if '?' in path else 'GET','/api/'+path,host=self.opal.loopback_authority,extra_headers=self.headers)
        self.assertEqual(reply.status,status,reply.body[:1024]); return reply.json()

    def settled(self, predicate=lambda d:True):
        deadline=time.monotonic()+25
        while time.monotonic()<deadline:
            d=self.request('novels')
            if not d['chapters_loading'] and not d['text_loading'] and predicate(d): return d
            time.sleep(.05)
        self.fail(f'reader did not settle: {d.get("error")}, offset={d.get("chapter_offset")}, rows={len(d.get("chapters",[]))}')

    def open(self, book):
        self.request('novels/open?'+urlencode({'source':'wuxiaclick','title':'Same title','url':self.base+'/novel/'+book}))
        return self.settled(lambda d:d['chapter_total']>=905)

    def action(self, d, path, ordinal):
        self.request('novels/'+path+'?'+urlencode({'ordinal':ordinal,'generation':d['chapter_generation']}))
        return self.settled()

    def test_complete_windows_edges_and_exact_resume(self):
        d=self.open('book-a'); self.assertEqual(len(d['chapters']),400); self.assertEqual(d['chapter_total'],905)
        original=d
        for offset,count in [(400,400),(800,105),(400,400),(0,400)]:
            d=self.action(d,'window',offset)
            self.assertEqual(d['chapter_offset'],offset); self.assertEqual(len(d['chapters']),count)
            self.assertEqual(d['chapters'][0]['title'],f'Chapter {offset+1}')
        self.request('novels/window?'+urlencode({'ordinal':400,'generation':original['chapter_generation']}),409)
        for ordinal in [399,400,799,800,399,850]:
            d=self.action(d,'chapter',ordinal)
            self.assertEqual(d['current_chapter'],ordinal)
            self.assertIn(f'book-a-{ordinal+1}',d['text'])
        d=self.open('book-b')
        self.request('novels/resume?generation='+str(d['chapter_generation'])); d=self.settled()
        self.assertNotIn('book-a-',d.get('text',''))
        self.prepend=True; d=self.open('book-a')
        self.request('novels/resume?generation='+str(d['chapter_generation'])); d=self.settled(lambda d:d['view']=='reader')
        self.assertEqual(d['current_chapter'],851); self.assertIn('book-a-851',d['text'])
        self.request('novels/open?'+urlencode({'source':'wuxiaclick','title':'bad','url':'https://evil.invalid/novel/x'}),400)
        print('905 chapters: full forward/backward windows, edge traversal, stale generation rejection, exact resume after insertion and same-title isolation passed',flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--binary',type=Path,required=True); parser.add_argument('--port',type=int,default=41708)
    args=parser.parse_args(); live.BINARY=args.binary.resolve(); live.PORT=args.port
    unittest.main(argv=[__file__],verbosity=2)
