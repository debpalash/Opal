#!/usr/bin/env python3
"""Opt-in isolated catalog and playback tests using local synthetic fixtures.
Playback tests generate silence WAVs; no external or copyrighted media is fetched.
Metadata-only fixtures return HTTP404 for authorized audio requests.
Run: python3 tests/test_content_maturity_live.py --binary zig-out/bin/opal
"""
import argparse
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import io
import wave
from pathlib import Path
import socket
import sqlite3
import threading
import time
import unittest
from urllib.parse import quote, urlsplit, parse_qs
import test_setup_token_live as harness


class Fixture(BaseHTTPRequestHandler):
    requests = []
    def log_message(self, *_):
        pass
    def reply(self, data, kind='application/json', status=200):
        body = data.encode() if isinstance(data, str) else json.dumps(data).encode()
        self.send_response(status)
        self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        url = urlsplit(self.path)
        self.requests.append((url.path, parse_qs(url.query), self.headers.get('Authorization', '')))
        if url.path == '/rss':
            items = ''.join(f"<item><title>Fixture episode {i:03d}</title><enclosure url='{self.server.base}/never-download/{i}.mp3' type='audio/mpeg'/></item>" for i in range(283))
            return self.reply('<rss version="2.0"><channel><title>Fixture podcast</title>'+items+'</channel></rss>', 'application/rss+xml')
        if url.path.startswith('/catalog') or url.path == '/opensearch':
            expected = 'Basic '+base64.b64encode(b'fixture:local-only').decode()
            if self.headers.get('Authorization') != expected:
                return self.reply({}, status=401)
            if url.path == '/opensearch':
                return self.reply(f'<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/"><Url type="application/atom+xml" template="{self.server.base}/catalog/search?q={{searchTerms}}"/></OpenSearchDescription>', 'application/opensearchdescription+xml')
            search = url.path.endswith('/search')
            title = 'Independent search book' if search else 'Browse book'
            link = '' if search else f'<link rel="search" type="application/opensearchdescription+xml" href="{self.server.base}/opensearch"/>'
            return self.reply(f'<feed xmlns="http://www.w3.org/2005/Atom"><id>fixture</id><title>Fixture catalog</title>{link}<entry><id>book-1</id><title>{title}</title><author><name>Fixture author</name></author><link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="{self.server.base}/never-download/book.epub"/></entry></feed>', 'application/atom+xml')
        if url.path.startswith('/s/item/') and self.server.generated_audio:
            audio = io.BytesIO()
            with wave.open(audio, 'wb') as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(8000)
                wav.writeframes(b'\x00\x00' * int(8000*self.server.track_duration))
            raw = audio.getvalue()
            start, end = 0, len(raw)-1
            requested = self.headers.get('Range', '')
            if requested.startswith('bytes='):
                bounds = requested[6:].split('-', 1)
                start = int(bounds[0] or 0)
                end = min(int(bounds[1]) if bounds[1] else end, end)
            if start >= len(raw):
                self.send_response(416)
                self.send_header('Content-Range', f'bytes */{len(raw)}')
                self.end_headers()
                return
            self.send_response(206 if requested else 200)
            self.send_header('Content-Type', 'audio/wav')
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Content-Length', str(end-start+1))
            if requested:
                self.send_header('Content-Range', f'bytes {start}-{end}/{len(raw)}')
            self.end_headers()
            try:
                self.wfile.write(raw[start:end+1])
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if url.path.startswith('/api/') and self.headers.get('Authorization') != 'Bearer fixture-local-token':
            return self.reply({}, status=401)
        if url.path == '/api/me/progress/book_1':
            return self.reply({'currentTime':self.server.resume_seconds,'duration':2*self.server.track_duration,'isFinished':False})
        if url.path == '/api/libraries':
            return self.reply({'libraries': [{'id':'lib_books','name':'Fixture books','mediaType':'book'}]})
        if url.path == '/api/libraries/lib_books/items':
            return self.reply({'results':[{'id':'book_1','media':{'metadata':{'title':'Fixture audiobook','authorName':'Fixture author'},'duration':2*self.server.track_duration}}], 'total':1})
        if url.path == '/api/items/book_1':
            return self.reply({'id':'book_1','mediaType':'book','media':{'metadata':{'title':'Fixture audiobook','authorName':'Fixture author'}, 'duration':2*self.server.track_duration, 'tracks':[{'index':1,'startOffset':0,'duration':self.server.track_duration,'contentUrl':'/s/item/book_1/first.mp3','metadata':{'filename':'first.mp3'}},{'index':2,'startOffset':self.server.track_duration,'duration':self.server.track_duration,'contentUrl':'/s/item/book_1/second.mp3','metadata':{'filename':'second.mp3'}}]}})
        self.reply({}, status=404)
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if self.path == '/login':
            return self.reply({'user':{'token':'fixture-local-token'}})
        self.reply({}, status=404)
    def do_PATCH(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if self.path == '/api/me/progress/book_1' and self.headers.get('Authorization') == 'Bearer fixture-local-token':
            self.server.progress.append(json.loads(body))
            return self.reply({'ok':True})
        self.reply({}, status=401)


class ContentMaturityLive(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if harness.BINARY is None:
            raise unittest.SkipTest('pass --binary')
    def setUp(self):
        self.fixture = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        self.fixture.generated_audio = False
        self.fixture.track_duration = 10
        self.fixture.resume_seconds = 0
        self.fixture.progress = []
        self.fixture.base = f'http://127.0.0.1:{self.fixture.server_port}'
        Fixture.requests = []
        threading.Thread(target=self.fixture.serve_forever, daemon=True).start()
        self.addCleanup(self.fixture.server_close)
        self.addCleanup(self.fixture.shutdown)
        self.opal = harness.IsolatedOpal(self)
        self.addCleanup(self.opal.stop)
        config = self.opal.config_root/'opal'
        config.mkdir(parents=True)
        with sqlite3.connect(config/'opal.db') as conn:
            conn.execute("CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT NOT NULL DEFAULT '')")
            conn.executemany('INSERT INTO config VALUES(?,?)', [('web_port',str(harness.PORT)),('web_bind','loopback'),('search_sources','32768'),('auto_download_subs','0'),('playback_volume','0')])
        token = self.opal.start()
        response = harness.register('fixture-admin', host=self.opal.loopback_authority, setup_token=token)
        self.assertEqual(response.status, 200)
        self.cookie = response.session_cookie()
    def api(self, path, method='GET', form=None, status=200):
        response = harness.request(method, '/api/'+path, host=self.opal.loopback_authority, origin='http://'+self.opal.loopback_authority if method=='POST' else None, form=form, extra_headers=(('Cookie',self.cookie),))
        self.assertEqual(response.status, status, f'{path}: unexpected HTTP status')
        return response.json()
    def wait(self, path, ready, timeout=25):
        end = time.monotonic()+timeout
        while time.monotonic()<end:
            data = self.api(path)
            if ready(data):
                return data
            time.sleep(.1)
        state = self.api('status') if path=='abs' else data
        diagnostic = {key:state.get(key) for key in ('loading','error','active','pos','dur','paused','buffering')}
        self.fail(f'{path}: fixture did not settle; state={diagnostic}, provider_paths={[p for p,_,_ in Fixture.requests]}, synced_progress={self.fixture.progress}')
    def load_podcast(self):
        self.api('podcasts/search?q='+quote(self.fixture.base+'/rss', safe=''))
        self.wait('podcasts', lambda d:not d['loading'] and len(d['results'])==1)
        self.api('podcasts/episodes?idx=0')
        return self.wait('podcasts',lambda d:not d['episodes_loading'] and d['episode_total']==283)
    def test_podcast_pages_cover_feed_and_reject_stale_navigation(self):
        first = self.load_podcast()
        self.assertEqual(len(first['episodes']),200)
        self.assertEqual(first['episodes'][0]['title'],'Fixture episode 000')
        second = self.api(f"podcasts/page?generation={first['generation']}&direction=next")
        self.assertEqual(second['episode_offset'],200)
        self.assertEqual(len(second['episodes']),83)
        self.assertEqual(second['episodes'][-1]['title'],'Fixture episode 282')
        stale = self.api(f"podcasts/page?generation={first['generation']}&direction=previous")
        self.assertEqual(stale['episode_offset'],200)
        self.api(f"podcasts/play?idx=0&generation={first['generation']}",status=409)
        self.api('podcasts/play?idx=0',status=400)
        end = self.api(f"podcasts/page?generation={second['generation']}&direction=next")
        self.assertEqual(end['episode_offset'],200)
        back = self.api(f"podcasts/page?generation={end['generation']}&direction=previous")
        self.assertEqual(back['episode_offset'],0)
        self.assertTrue(all(urlsplit(e['url']).username is None for e in back['episodes']))
    def test_podcast_page_requires_generation(self):
        self.api('podcasts/page?direction=next',status=400)
    def test_opds_advertised_authenticated_search_is_independent(self):
        self.api('opds/connect','POST',{'server':self.fixture.base+'/catalog','user':'fixture','pass':'local-only'})
        before = self.wait('opds',lambda d:d['connected'] and not d['loading'] and len(d['entries'])==1)
        self.assertEqual(before['entries'][0]['title'],'Browse book')
        self.api('unified_search?q=independent')
        result = self.wait('unified_search',lambda d:not d['loading'])
        self.assertTrue(any(r['title']=='Independent search book' for r in result['results']))
        after = self.api('opds')
        self.assertEqual(before['entries'],after['entries'])
        self.assertTrue(any(path=='/catalog/search' and query.get('q')==['independent'] and auth.startswith('Basic ') for path,query,auth in Fixture.requests))
        rendered = json.dumps(result)
        self.assertNotIn('local-only',rendered)
        self.assertNotIn('fixture:local-only@',rendered)
    def open_audiobook(self):
        self.api('abs/login','POST',{'server':self.fixture.base,'user':'fixture','pass':'local-only'})
        self.wait('abs',lambda d:d['connected'] and not d['loading'] and len(d['libraries'])==1)
        self.api('abs/open?idx=0','POST')
        self.wait('abs',lambda d:not d['loading'] and len(d['books'])==1)
        self.api('abs/play?idx=0','POST')
    def test_audiobook_generated_audio_eof_advances_once_and_finishes_book(self):
        self.fixture.generated_audio = True
        self.fixture.track_duration = 2
        self.open_audiobook()
        self.wait('abs',lambda _:any(p.get('isFinished') for p in self.fixture.progress),timeout=18)
        finished = [p for p in self.fixture.progress if p.get('isFinished')]
        self.assertEqual(len(finished),1)
        self.assertAlmostEqual(finished[0]['currentTime'],4,places=1)
        media = [path for path,_,_ in Fixture.requests if path.startswith('/s/item/')]
        ordered = [path for i,path in enumerate(media) if i==0 or path!=media[i-1]]
        self.assertEqual(ordered,['/s/item/book_1/first.mp3','/s/item/book_1/second.mp3'])
        time.sleep(.5)
        self.assertEqual(sum(p.get('isFinished',False) for p in self.fixture.progress),1)
    def test_audiobook_generated_audio_resume_uses_second_file_local_position(self):
        self.fixture.generated_audio = True
        self.fixture.track_duration = 50
        self.fixture.resume_seconds = 62
        self.open_audiobook()
        status = self.wait('status',lambda d: not d['loading'] and d['pos']>=12 and d['dur']>=49,timeout=15)
        self.assertLess(status['pos'],16)
        media = [path for path,_,_ in Fixture.requests if path.startswith('/s/item/')]
        self.assertTrue(media)
        self.assertEqual(set(media),{'/s/item/book_1/second.mp3'})
    def test_audiobook_multifile_selector_and_stale_action(self):
        self.api('abs/login','POST',{'server':self.fixture.base,'user':'fixture','pass':'local-only'})
        self.wait('abs',lambda d:d['connected'] and not d['loading'] and len(d['libraries'])==1)
        self.api('abs/open?idx=0','POST')
        self.wait('abs',lambda d:not d['loading'] and len(d['books'])==1)
        self.api('abs/play?idx=0','POST')
        view = self.wait('abs',lambda d:d['audio']['visible'] and not d['audio']['loading'])
        self.assertEqual(view['audio']['total'],2)
        self.assertTrue(view['audio']['complete_book'])
        self.assertEqual(len(view['audio']['tracks']),2)
        self.api('abs/audio/close','POST')
        self.api(f"abs/audio?idx=0&generation={view['audio']['generation']}",'POST',status=409)
        # Complete books automatically start their first real track. The local
        # fixture returns404 (zero media bytes); an archive must never be used.
        media_paths = [path for path,_,_ in Fixture.requests if path.startswith('/s/item/')]
        self.assertTrue(all(path=='/s/item/book_1/first.mp3' for path in media_paths))
        self.assertFalse(any('/download' in path for path,_,_ in Fixture.requests))
        self.assertNotIn('fixture-local-token',json.dumps(view))
        self.assertTrue(any(path=='/api/items/book_1' and auth=='Bearer fixture-local-token' for path,_,auth in Fixture.requests))
        self.assertFalse(any('token' in query for path,query,_ in Fixture.requests if path.startswith('/api/')))
        self.assertNotIn('local-only',json.dumps(view))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--port',type=int,default=41697)
    args = parser.parse_args()
    harness.BINARY = args.binary.resolve()
    harness.PORT = args.port
    unittest.main(argv=['test_content_maturity_live.py'],verbosity=2)

if __name__=='__main__':
    main()
