#!/usr/bin/env python3
"""Real Opal HLS playback using generated color bars and silent audio only.
This exercises shared in-app/native dispatch, not a localhost impersonation of
an external anime provider. Provider extraction has separate pure fixtures.
"""
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import shutil
import sqlite3
import subprocess
import threading
import time
import unittest
from urllib.parse import urlencode
import test_setup_token_live as live

class HlsFiles(SimpleHTTPRequestHandler):
    requests=[]
    def log_message(self,*_): pass
    def do_GET(self):
        self.requests.append(self.path)
        return super().do_GET()
    def guess_type(self,path):
        if path.endswith('.m3u8'): return 'application/vnd.apple.mpegurl'
        if path.endswith('.ts'): return 'video/mp2t'
        return super().guess_type(path)

class HlsPlaybackLiveTest(unittest.TestCase):
    def setUp(self):
        ffmpeg=shutil.which('ffmpeg')
        if ffmpeg is None: self.skipTest('ffmpeg is required to generate the local HLS fixture')
        self.opal=live.IsolatedOpal(self); self.addCleanup(self.opal.stop)
        media=self.opal.root/'generated-hls'; media.mkdir()
        self.media=media; self.ffmpeg=ffmpeg
        subprocess.run([ffmpeg,'-v','error','-f','lavfi','-i','testsrc2=size=320x180:rate=24','-f','lavfi','-i','anullsrc=r=48000:cl=stereo','-t','16','-c:v','libx264','-preset','ultrafast','-g','48','-c:a','aac','-f','hls','-hls_time','2','-hls_list_size','0','-hls_segment_filename',str(media/'segment-%03d.ts'),str(media/'fixture.m3u8')],check=True,timeout=30)
        HlsFiles.requests=[]
        self.fixture=ThreadingHTTPServer(('127.0.0.1',0),partial(HlsFiles,directory=str(media)))
        threading.Thread(target=self.fixture.serve_forever,daemon=True).start()
        self.addCleanup(self.fixture.server_close); self.addCleanup(self.fixture.shutdown)
        profile=self.opal.config_root/'opal'; profile.mkdir(parents=True)
        with sqlite3.connect(profile/'opal.db') as db:
            db.execute("CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT NOT NULL DEFAULT '')")
            db.executemany('INSERT INTO config VALUES(?,?)',[('web_port',str(live.PORT)),('web_bind','loopback'),('web_remote','1'),('auto_download_subs','0'),('playback_volume','0')])
        token=self.opal.start(); account=live.register('local-hls-fixture',host=self.opal.loopback_authority,setup_token=token)
        self.assertEqual(account.status,200); self.headers=(('Cookie',account.session_cookie()),)
    def api(self,path,method='GET'):
        r=live.request(method,'/api/'+path,host=self.opal.loopback_authority,extra_headers=self.headers)
        self.assertEqual(r.status,200,r.body[:512]); return r.json()
    def until(self,predicate):
        end=time.monotonic()+25
        while time.monotonic()<end:
            state=self.api('status')
            if predicate(state): return state
            time.sleep(.1)
        self.fail('HLS playback did not reach expected state: '+str({key:state.get(key) for key in ('active','dur','pos','paused','buffering')}))
    def test_generated_hls_shared_dispatch_pause_seek_and_resume(self):
        url=f'http://127.0.0.1:{self.fixture.server_port}/fixture.m3u8'
        self.api('open?'+urlencode({'url':url,'title':'Generated local HLS fixture'}),'POST')
        playing=self.until(lambda d:d.get('active') and d.get('dur',0)>=15 and d.get('pos',0)>.25)
        self.assertFalse(playing['paused'])
        self.assertIn('/fixture.m3u8',HlsFiles.requests)
        self.assertTrue(any(path.endswith('.ts') for path in HlsFiles.requests))
        self.api('toggle','POST'); self.until(lambda d:d.get('paused') is True)
        self.api('seek_pct?v=50','POST'); sought=self.until(lambda d:d.get('paused') is True and 6<=d.get('pos',0)<=10)
        self.api('toggle','POST'); self.until(lambda d:d.get('paused') is False and d.get('pos',0)>sought['pos']+.2)

    def test_generated_video_only_podcast_plays_in_opal(self):
        # Repackage our own generated color bars/silence, never provider media.
        subprocess.run([self.ffmpeg,'-v','error','-i',str(self.media/'fixture.m3u8'),
                        '-c','copy','-movflags','+faststart',str(self.media/'podcast.mp4')],
                       check=True,timeout=15)
        base=f'http://127.0.0.1:{self.fixture.server_port}'
        feed=("<rss version='2.0'><channel><title>Generated video podcast</title>"
              "<item><title>Generated color bars and silence</title>"
              f"<enclosure type='video/mp4' url='{base}/podcast.mp4'/></item>"
              "</channel></rss>")
        (self.media/'podcast.xml').write_text(feed,encoding='utf-8')
        self.api('podcasts/search?'+urlencode({'q':base+'/podcast.xml'}))
        def settled(predicate):
            end=time.monotonic()+20
            while time.monotonic()<end:
                data=self.api('podcasts')
                if predicate(data): return data
                time.sleep(.1)
            self.fail('Video podcast did not settle: '+str(data))
        settled(lambda d:not d.get('loading') and len(d['results'])==1)
        self.api('podcasts/episodes?idx=0')
        episodes=settled(lambda d:not d.get('episodes_loading') and bool(d['episodes']))
        self.assertEqual(len(episodes['episodes']),1)
        self.assertEqual(episodes['episodes'][0]['url'],base+'/podcast.mp4')
        self.api('podcasts/play?'+urlencode({'idx':0,'generation':episodes['generation']}),'POST')
        playing=self.until(lambda d:d.get('active') and d.get('dur',0)>=15 and d.get('pos',0)>.25)
        self.assertFalse(playing['paused'])
        self.assertIn('/podcast.mp4',HlsFiles.requests)
        advanced=self.until(lambda d:d.get('active') and not d.get('paused')
                            and d.get('pos',0)>playing['pos']+.25)
        self.assertGreater(advanced['pos'],playing['pos'])

if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--binary',required=True); parser.add_argument('--port',type=int,default=41801)
    args,rest=parser.parse_known_args(); live.BINARY=Path(args.binary).resolve(); live.PORT=args.port
    unittest.main(argv=[__file__,*rest],verbosity=2)
