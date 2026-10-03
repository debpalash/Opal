#!/usr/bin/env python3
"""Owned local providers exercise cancellation, public cache and configured failover."""
import argparse, json, sqlite3, threading, time, unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
import test_setup_token_live as live

class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        path=urlsplit(self.path)
        if path.path == '/v1/audio/' and parse_qs(path.query).get('q') == ['slow']:
            self.send_response(200); self.send_header('Content-Length','1000000'); self.end_headers()
            self.server.started.set()
            try:
                for _ in range(80):
                    self.wfile.write(b' '*1000); self.wfile.flush(); time.sleep(.1)
            except (BrokenPipeError, ConnectionResetError): self.server.closed.set()
            return
        self.server.hits += 1
        if self.server.fail:
            self.send_error(503); return
        if path.path == '/channels.json' and getattr(self.server,'invalid',False):
            body=b'{}'
        elif path.path == '/channels.json':
            body=json.dumps({'channels':[{'id':'reliable','title':'reliable music radio','description':'reliable station','playlists':[{'url':self.server.base+'/audio.mp3','format':'mp3','quality':'highest'}]}]}).encode()
        else: body=b'{"result_count":0,"results":[]}'
        self.send_response(200); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)

class SourceReliabilityTest(unittest.TestCase):
    def setUp(self):
        self.servers=[]
        for fail in (False,True):
            s=ThreadingHTTPServer(('127.0.0.1',0),Provider); s.fail=fail; s.hits=0
            s.started=threading.Event(); s.closed=threading.Event(); s.base='http://127.0.0.1:'+str(s.server_port)
            threading.Thread(target=s.serve_forever,daemon=True).start(); self.servers.append(s)
            self.addCleanup(s.server_close); self.addCleanup(s.shutdown)
        self.good,self.bad=self.servers
        self.opal=live.IsolatedOpal(self); self.addCleanup(self.opal.stop)
        profile=self.opal.config_root/'opal'; sources=profile/'plugins'/'sources'; sources.mkdir(parents=True)
        (sources/'openverse.json').write_text(json.dumps({'base':self.good.base,'_v':'1.0.0'}))
        (sources/'somafm.json').write_text(json.dumps({'base':self.bad.base if self._testMethodName.endswith('failover') else self.good.base,'mirrors':self.good.base,'_v':'1.0.0'}))
        with sqlite3.connect(profile/'opal.db') as db:
            db.execute("CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT NOT NULL DEFAULT '')")
            db.executemany('INSERT INTO config VALUES(?,?)',[('web_port',str(live.PORT)),('web_bind','loopback'),('search_sources',str((1<<9)|(1<<10))),('auto_download_subs','0'),('content_cache_enabled','0')])
        token=self.opal.start(); account=live.register('reliability-fixture',host=self.opal.loopback_authority,setup_token=token)
        self.assertEqual(account.status,200); self.headers=(('Cookie',account.session_cookie()),)
    def api(self,path,method='GET'):
        r=live.request(method,'/api/'+path,host=self.opal.loopback_authority,extra_headers=self.headers)
        self.assertEqual(r.status,200,r.body[:512]); return r.json()
    def search(self,q):
        self.api('unified_search?q='+q)
        deadline=time.monotonic()+20
        while time.monotonic()<deadline:
            d=self.api('unified_search')
            if not d['loading']: return d
            time.sleep(.05)
        self.fail('search did not settle')
    def test_cancel_stops_provider_socket(self):
        self.api('unified_search?q=slow'); self.assertTrue(self.good.started.wait(10))
        d=self.api('unified_search'); self.api('unified_search/cancel?generation='+str(d['generation']),'POST')
        self.assertTrue(self.good.closed.wait(.8),'cancel left stale provider I/O running')
        self.assertFalse(self.api('unified_search')['loading'])
    def test_superseded_search_closes_socket_and_publishes_only_new_wave(self):
        old=self.api('unified_search?q=slow'); self.assertTrue(self.good.started.wait(10))
        self.api('unified_search?q=reliable')
        self.assertTrue(self.good.closed.wait(.8),'new search left old provider I/O running')
        deadline=time.monotonic()+10
        while time.monotonic()<deadline:
            d=self.api('unified_search')
            if not d['loading']: break
            time.sleep(.05)
        self.assertGreater(d['generation'],old['generation']); self.assertFalse(d['loading'])
        self.assertTrue(any(r.get('provider')=='somafm' for r in d['results']),d)
    def test_invalid_catalog_is_unavailable_and_never_cached(self):
        self.good.invalid=True; self.search('reliable')
        source=next(s for s in self.api('plugins')['sources'] if s['id']=='somafm')
        self.assertEqual(source['health']['state'],'unavailable')
        self.good.invalid=False
        d=self.search('music'); self.assertTrue(any(r.get('provider')=='somafm' for r in d['results']),d)
    def test_public_catalog_cache(self):
        self.search('reliable'); first=self.good.hits; self.search('music')
        # Openverse differs by query; the Soma catalog is identical and should be reused.
        self.assertEqual(self.good.hits-first,1)
    def test_configured_mirror_failover(self):
        d=self.search('reliable')
        self.assertTrue(any(r.get('provider')=='somafm' for r in d['results']),d)
        source=next(s for s in self.api('plugins')['sources'] if s['id']=='somafm')
        self.assertEqual(source['health']['state'],'available'); self.assertTrue(source['health']['fallback'])

if __name__=='__main__':
    p=argparse.ArgumentParser(); p.add_argument('--binary',required=True); p.add_argument('--port',type=int,default=41785)
    a,rest=p.parse_known_args(); live.BINARY=Path(a.binary).resolve(); live.PORT=a.port
    unittest.main(argv=[__file__,*rest],verbosity=2)
