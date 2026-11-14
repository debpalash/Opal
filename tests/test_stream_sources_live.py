#!/usr/bin/env python3
"""Owned executable plugins and local header-gated media; no screenshots."""
import argparse
import io
import json
import sqlite3
import sys
import threading
import time
import unittest
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote
import test_setup_token_live as live

class Media(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        if self.headers.get('Referer') != 'https://fixture.test/' or self.headers.get('User-Agent') != 'OpalFixture':
            self.send_error(403); return
        self.server.hits.append(self.path)
        self.send_response(200)
        self.send_header('Content-Type', 'audio/wav')
        self.send_header('Content-Length', str(len(self.server.media)))
        self.end_headers()
        try: self.wfile.write(self.server.media)
        except (BrokenPipeError, ConnectionResetError): pass

class StreamSources(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Media)
        self.server.hits = []
        wav = io.BytesIO()
        with wave.open(wav, 'wb') as out:
            out.setnchannels(1); out.setsampwidth(2); out.setframerate(8000)
            out.writeframes(bytes(2 * 8000 * 90))
        self.server.media = wav.getvalue()
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close); self.addCleanup(self.server.shutdown)
        self.opal = live.IsolatedOpal(self); self.addCleanup(self.opal.stop)
        profile = self.opal.config_root / 'opal'
        plugin = profile / 'plugins' / 'stream-fixture'; plugin.mkdir(parents=True)
        (plugin / 'manifest.json').write_text(json.dumps({'id':'stream-fixture', 'name':'Stream fixture', 'version':'1.0.0', 'allow_unsafe':True}))
        media = f'http://127.0.0.1:{self.server.server_port}/audio.wav?token=' + 'a' * 3000
        self.media = media
        rows = [{'id':v, 'title':'Fixture ' + v, 'type':'video'} for v in ('good','broken','slow','fast','timeout')]
        rows.append({'id':'direct','title':'Fixture direct','type':'video','stream_url':media,'headers':{'Referer':'https://fixture.test/','User-Agent':'OpalFixture'},'quality':'1080p','language':'en'})
        if self._testMethodName == 'test_dedup_preserves_different_http_identities':
            rows = [row for row in rows if row['id'] != 'timeout']
            rows.append({**rows[-1], 'id':'other-direct', 'title':'Fixture other direct', 'headers':{'Referer':'https://another.test/','User-Agent':'OpalFixture'}})
        self.script(plugin / 'search', f'import json\nprint(json.dumps({rows!r}))\n')
        self.script(plugin / 'resolve', f'''import json,sys,time
item=sys.argv[1]
if item == 'slow': time.sleep(1.5)
if item == 'timeout': time.sleep(40)
if item == 'broken': print('{{invalid'); sys.exit(0)
print(json.dumps({{'url':{media!r}+'&item='+item,'headers':{{'Referer':'https://fixture.test/','User-Agent':'OpalFixture'}}}}))
''')
        with live.database(profile / 'opal.db') as db:
            db.execute('CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT NOT NULL)')
            db.executemany('INSERT INTO config VALUES(?,?)', [('web_port',str(live.PORT)),('web_bind','loopback'),('search_sources','1'),('auto_download_subs','0'),('content_cache_enabled','0')])
        token = self.opal.start()
        self.addCleanup(self.save_log)
        account = live.register('stream-fixture',host=self.opal.loopback_authority,setup_token=token)
        self.assertEqual(account.status,200,account.body)
        self.headers = (('Cookie',account.session_cookie()),)
        machine = (profile / 'api.token').read_text().strip()
        self.machine = machine
        approval = live.request('POST','/api/plugins?action=approve-exec&id=stream-fixture&confirm=1',host=self.opal.loopback_authority,extra_headers=(('Authorization','Bearer '+machine),))
        self.assertEqual(approval.status,200,approval.body)

    def save_log(self):
        self.opal.log.flush(); self.opal.log.seek(0)
        Path("/tmp/opal-stream-"+self._testMethodName+".log").write_bytes(self.opal.log.read())
    def script(self, path, text):
        path.write_text('#!' + sys.executable + '\n' + text); path.chmod(0o755)
    def api(self, path, method='GET'):
        r = live.request(method,'/api/'+path,host=self.opal.loopback_authority,extra_headers=self.headers)
        self.assertEqual(r.status,200,r.body[:500]); return r.json()
    def wait(self, fn, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = fn()
            if value: return value
            time.sleep(.05)
        self.fail('Timed out waiting for stream state')
    def search(self):
        self.api('unified_search?q=Fixture')
        return self.wait(lambda: (lambda d: d if sum(r.get('source') == 'plugin' for r in d['results']) >= 5 else None)(self.api('unified_search')))
    def play(self, data, name):
        row = next(r for r in data['results'] if r['title'] == 'Fixture ' + name)
        self.api(f"unified_search/play?generation={data['generation']}&key={row['key']}",'POST')
    def test_dedup_preserves_different_http_identities(self):
        data = self.search()
        rows = [r for r in data['results'] if 'direct' in r['title']]
        self.assertEqual(len(rows),2)
        self.assertNotEqual(rows[0]['key'],rows[1]['key'])
        self.assertTrue(all(not r['queueable'] for r in rows))
        self.play(data,'direct'); self.wait(lambda: self.server.hits)

    def test_direct_long_signed_url_and_headers(self):
        data = self.search(); self.play(data,'direct')
        self.wait(lambda: self.server.hits)
        self.assertIn('token='+'a'*3000,self.server.hits[-1])
        status = self.wait(lambda: (lambda d: d if d.get('dur',0)>80 else None)(self.api('status')))
        self.assertFalse(status['error'])
        self.assertTrue(status['can_choose_source'])
        self.api('player/action?action=source_fallback&value=false','POST')
        self.assertFalse(self.api('status')['source_fallback'])
    def test_resolve_failure_clears_loading_and_can_retry(self):
        data = self.search(); self.play(data,'broken')
        status = self.wait(lambda: (lambda d: d if d.get('error') else None)(self.api('status')))
        self.assertFalse(status['loading']); self.assertTrue(status['retryable'])
        self.api('player/action?action=retry','POST')
        self.wait(lambda: self.api('status').get('error'))
        self.play(data,'good'); self.wait(lambda: self.server.hits)
    def test_late_resolve_cannot_replace_new_selection(self):
        data = self.search(); self.play(data,'slow')
        self.wait(lambda: self.api('status').get('stage') == 'Resolving source')
        self.play(data,'fast'); self.wait(lambda: any('item=fast' in h for h in self.server.hits))
        time.sleep(1.8)
        self.assertFalse(any('item=slow' in h for h in self.server.hits),self.server.hits)
        self.assertFalse(self.api('status')['loading'])
    def test_revoked_provider_finishes_with_actionable_error(self):
        data = self.search()
        revoked = live.request('POST','/api/plugins?action=revoke-exec&id=stream-fixture&confirm=1',host=self.opal.loopback_authority,extra_headers=(('Authorization','Bearer '+self.machine),))
        self.assertEqual(revoked.status,200,revoked.body)
        self.play(data,'good')
        status = self.wait(lambda: (lambda d: d if d.get('error') else None)(self.api('status')))
        self.assertIn('approve',status['error']); self.assertFalse(status['loading'])

    def test_timeout_and_cancel_release_loading(self):
        data = self.search(); self.play(data,'timeout')
        self.wait(lambda: self.api('status').get('stage') == 'Resolving source')
        status = self.wait(lambda: (lambda d: d if d.get('error') else None)(self.api('status')), timeout=35)
        self.assertIn('too long',status['error']); self.assertFalse(status['loading'])
        self.play(data,'slow')
        self.wait(lambda: self.api('status').get('stage') == 'Resolving source')
        self.api('player/action?action=cancel','POST')
        time.sleep(1.8)
        self.assertFalse(self.api('status')['loading'])
        self.assertFalse(any('item=slow' in h for h in self.server.hits))

    def test_retry_and_source_switch_keep_position(self):
        data = self.search(); self.play(data,'good')
        self.wait(lambda: self.api('status').get('dur',0) > 80)
        self.api('player/action?action=seek&value=30','POST')
        self.wait(lambda: self.api('status').get('pos',0) >= 29)
        self.api('player/action?action=retry','POST')
        self.wait(lambda: self.api('status').get('pos',0) >= 29 and not self.api('status')['loading'])
        self.api('player/action?action=choose_source','POST')
        data = self.search(); self.play(data,'direct')
        status = self.wait(lambda: (lambda d: d if d.get('pos',0) >= 29 and not d['loading'] else None)(self.api('status')))
        self.assertTrue(status['can_choose_source'])
        self.assertGreaterEqual(status['pos'],29)
        self.play(data,'fast')
        self.wait(lambda: any('item=fast' in h for h in self.server.hits))
        self.wait(lambda: (lambda d: not d['loading'] and d.get('dur',0)>80 and d['pos']<10)(self.api('status')))

    def test_preference_saved_cleared_and_private(self):
        data = self.search(); row = data['results'][0]
        self.assertTrue(row['can_prefer'])
        suffix = f"?generation={data['generation']}&key={row['key']}"
        self.api('unified_search/prefer'+suffix,'POST')
        self.wait(lambda: any(r['preferred'] for r in self.api('unified_search')['results']))
        preferred = next(r for r in self.api('unified_search')['results'] if r['key'] == row['key'])
        self.assertEqual(preferred['score'],max(0,row['score']-32))
        with live.database(self.opal.config_root/'opal'/'opal.db') as db:
            stored = db.execute("SELECT key,value FROM config WHERE key LIKE 'source_preference:%'").fetchall()
        self.assertEqual(len(stored),1); self.assertEqual(stored[0][1],'stream-fixture')
        self.assertNotIn(self.media,json.dumps(self.api('unified_search')))
        self.api('unified_search/clear_preference'+suffix,'POST')
        self.wait(lambda: not any(r['preferred'] for r in self.api('unified_search')['results']))

if __name__ == '__main__':
    p=argparse.ArgumentParser(); p.add_argument('--binary',required=True); p.add_argument('--port',type=int,default=41867)
    args,rest=p.parse_known_args(); live.BINARY=Path(args.binary).resolve(); live.PORT=args.port
    unittest.main(argv=[__file__,*rest],verbosity=2)
