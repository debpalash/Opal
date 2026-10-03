#!/usr/bin/env python3
"""Isolated Jellyfin/Plex direct-play workflows using generated media only."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import threading
import time
import unittest
from urllib.parse import urlencode, urlsplit, parse_qs
import test_setup_token_live as live


class MediaServersLive(unittest.TestCase):
    def setUp(self):
        ffmpeg = shutil.which('ffmpeg')
        if not ffmpeg: self.skipTest('ffmpeg required for generated fixture')
        self.opal = live.IsolatedOpal(self); self.addCleanup(self.opal.stop)
        media = self.opal.root / 'generated'; media.mkdir()
        subtitle = media/'subtitle.srt'; subtitle.write_text('1\n00:00:00,000 --> 00:02:00,000\nGenerated legal subtitle fixture\n')
        self.media = media/'fixture.mkv'
        subprocess.run([ffmpeg,'-v','error','-f','lavfi','-i','color=c=navy:s=160x90:r=10','-f','lavfi','-i','anullsrc=r=48000:cl=stereo','-i',str(subtitle),'-t','120','-map','0:v','-map','1:a','-map','2:s','-c:v','mpeg4','-q:v','5','-c:a','aac','-c:s','srt','-metadata:s:s:0','language=eng',str(self.media)],check=True,timeout=30)
        self.events=[]; self.expired=False; self.resume_secs=30; self.reverse_sections=False; self.delay_auth=False; self.auth_started=threading.Event(); self.auth_release=threading.Event(); self.auth_response_done=threading.Event(); owner=self
        class Provider(BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def send(self,body,code=200):
                data=json.dumps(body,separators=(',',':')).encode()
                self.send_response(code); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data)));self.end_headers()
                try:self.wfile.write(data)
                except (BrokenPipeError,ConnectionResetError):pass
            def do_POST(self):
                body=self.rfile.read(int(self.headers.get('Content-Length','0')))
                owner.events.append((self.path,dict(self.headers),body.decode()))
                if self.path=='/Users/AuthenticateByName':
                    if owner.delay_auth:
                        owner.auth_started.set(); owner.auth_release.wait(10)
                    self.send({'AccessToken':'fixture-jelly-token','User':{'Id':'user-a'}})
                    owner.auth_response_done.set()
                elif self.path.startswith('/Sessions/Playing'):
                    if self.path.endswith('/Progress'):
                        owner.resume_secs = json.loads(body).get('PositionTicks',0)/10000000
                    self.send({})
                elif self.path.startswith('/:/timeline'):
                    owner.resume_secs = int(parse_qs(urlsplit(self.path).query).get('time',['0'])[0])/1000
                    self.send({})
                else: self.send({},404)
            def do_GET(self):
                owner.events.append((self.path,dict(self.headers),''))
                path=urlsplit(self.path).path
                if owner.expired: self.send({},401); return
                if path.startswith('/Videos/') or path.startswith('/library/parts/'):
                    data=owner.media.read_bytes(); start=0; end=len(data)-1
                    raw=self.headers.get('Range','')
                    if raw.startswith('bytes='):
                        pair=raw[6:].split('-',1);start=int(pair[0] or 0);end=min(end,int(pair[1]) if pair[1] else end)
                    self.send_response(206 if raw else 200);self.send_header('Content-Type','video/x-matroska');self.send_header('Accept-Ranges','bytes')
                    if raw:self.send_header('Content-Range',f'bytes {start}-{end}/{len(data)}')
                    self.send_header('Content-Length',str(end-start+1));self.end_headers()
                    try:self.wfile.write(data[start:end+1])
                    except (BrokenPipeError,ConnectionResetError):pass
                elif path.endswith('/Views'):self.send({'Items':[{'Name':'Fixture Movies','Id':'library-a','CollectionType':'movies'}]})
                elif path.startswith('/Users/') and '/Items' in path:
                    self.send({'Items':[{'Name':'Generated Movie','Id':'item-a','Type':'Movie','RunTimeTicks':1200000000,'UserData':{'PlaybackPositionTicks':int(owner.resume_secs*10000000)},'MediaSources':[{'Id':'source-a','Container':'mkv'}]}],'TotalRecordCount':1})
                elif path=='/library/sections':
                    sections=[{'key':'1','title':'Fixture Movies','type':'movie'},{'key':'2','title':'Other Movies','type':'movie'}]
                    self.send({'MediaContainer':{'Directory':list(reversed(sections)) if owner.reverse_sections else sections}})
                elif path in ('/library/sections/1/all','/library/sections/2/all'):self.send({'MediaContainer':{'size':1,'totalSize':1,'Metadata':[{'ratingKey':'123','title':'Other Movie' if '/sections/2/' in path else 'Generated Movie','type':'movie','duration':120000,'viewOffset':int(owner.resume_secs*1000),'Media':[{'Part':[{'key':'/library/parts/123/fixture.mkv'}]}]}]}})
                elif path=='/:/timeline':
                    owner.resume_secs = int(parse_qs(urlsplit(self.path).query).get('time',['0'])[0])/1000
                    self.send({})
                else:self.send({},404)
        self.server=ThreadingHTTPServer(('127.0.0.1',0),Provider)
        threading.Thread(target=self.server.serve_forever,daemon=True).start()
        self.addCleanup(self.server.server_close);self.addCleanup(self.server.shutdown)
        self.base=f'http://127.0.0.1:{self.server.server_port}'
        profile=self.opal.config_root/'opal';profile.mkdir(parents=True)
        (profile/'plex.json').write_text(json.dumps({'token':'fixture-plex-account','server_token':'fixture-plex-server','server':self.base,'name':'Isolated fixture'}))
        with sqlite3.connect(profile/'opal.db') as db:
            db.execute("CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT NOT NULL DEFAULT '')")
            db.executemany('INSERT INTO config VALUES(?,?)',[('web_port',str(live.PORT)),('web_bind','loopback'),('auto_download_subs','0'),('playback_volume','0')])
        token=self.opal.start();account=live.register('media-server-fixture',host=self.opal.loopback_authority,setup_token=token)
        self.assertEqual(account.status,200,account.body);self.headers=(('Cookie',account.session_cookie()),)

    def tearDown(self):
        if hasattr(self, 'opal'):
            name=self.id().rsplit('.',1)[-1]
            (Path(tempfile.gettempdir()) / ('opal-'+name+'.log')).write_text(self.opal.safe_log().replace('fixture-jelly-token','[fixture token]').replace('fixture-plex-account','[fixture token]').replace('fixture-plex-server','[fixture token]'), encoding='utf-8')
        if hasattr(self, 'events'): print('Fixture paths: '+str([event[0] for event in self.events]),flush=True)

    def api(self,path,method='GET',form=None):
        reply=live.request(method,'/api/'+path,host=self.opal.loopback_authority,extra_headers=self.headers,form=form)
        self.assertEqual(reply.status,200,reply.body[:512])
        try: return reply.json()
        except json.JSONDecodeError:
            (Path(tempfile.gettempdir()) / ('opal-media-invalid-'+path.split('?')[0].replace('/','-')+'.json')).write_bytes(reply.body)
            raise
    def until(self,path,predicate,timeout=15):
        end=time.monotonic()+timeout
        while time.monotonic()<end:
            data=self.api(path)
            if predicate(data):return data
            time.sleep(.05)
        self.fail(f'{path} failed to settle: {str(data)[:900]}')
    def await_new_stream(self, prefix, previous_count, token):
        deadline=time.monotonic()+10
        while time.monotonic()<deadline:
            streams=[event for event in self.events if event[0].startswith(prefix)]
            if len(streams)>previous_count:
                headers={key.lower():value for key,value in streams[-1][1].items()}
                field='x-emby-token' if prefix.startswith('/Videos') else 'x-plex-token'
                self.assertEqual(headers.get(field),token)
                return
            time.sleep(.05)
        self.fail('reconnected playback did not issue a fresh authenticated stream request')

    def playback(self,provider):
        playing=self.until('status',lambda d:d.get('active') and d.get('dur',0)>119 and d.get('pos',0)>=29)
        self.assertLess(playing['pos'],40,'server resume should start around30 seconds')
        self.assertEqual(playing.get('title'),'Generated Movie','Now Playing must retain provider title')
        detail=self.api('player');self.assertTrue(detail['tracks']['subtitles'],'generated embedded subtitle must be visible')
        self.assertEqual(detail['state']['title'],'Generated Movie','rich player snapshot must retain provider title')
        self.assertIn('audio_devices',detail,'rich snapshot must remain valid after subtitle discovery')
        sid=detail['tracks']['subtitles'][0]['id']
        self.api('player/action?action=subtitle-track&value=off','POST')
        self.until('player',lambda d:not any(row['selected'] for row in d['tracks']['subtitles']))
        self.api('player/action?action=subtitle-track&value='+str(sid),'POST')
        self.until('player',lambda d:any(row['id']==sid and row['selected'] for row in d['tracks']['subtitles']))
        self.api('seek_pct?v=50','POST')
        self.until('status',lambda d:55<=d.get('pos',0)<=70)
        self.api('toggle','POST')
        self.until('status',lambda d:d.get('paused'))
        deadline=time.monotonic()+10
        marker='/Sessions/Playing/Progress' if provider=='jellyfin' else '/:/timeline'
        while time.monotonic()<deadline and not any(e[0].startswith(marker) for e in self.events):time.sleep(.1)
        self.assertTrue(any(e[0].startswith(marker) for e in self.events),'actual provider progress request missing')
        deadline=time.monotonic()+7
        rows=[]
        while time.monotonic()<deadline:
            with sqlite3.connect(self.opal.config_root/'opal'/'opal.db') as db:
                rows=db.execute('SELECT link FROM watch_history WHERE position_secs>=55').fetchall()
            if rows:break
            time.sleep(.1)
        self.assertTrue(rows,'actual local resume must persist the sought position')
        self.assertFalse(any('fixture-jelly-token' in str(row) or 'fixture-plex-' in str(row) for row in rows))
        streams=[event for event in self.events if event[0].startswith('/Videos/' if provider=='jellyfin' else '/library/parts/')]
        self.assertTrue(streams,'direct stream must reach owned provider')
        headers={k.lower():v for k,v in streams[-1][1].items()}
        self.assertEqual(headers.get('x-emby-token' if provider=='jellyfin' else 'x-plex-token'), 'fixture-jelly-token' if provider=='jellyfin' else 'fixture-plex-server')
        self.assertNotIn('fixture-',streams[-1][0],'stream URL must not carry authentication tokens')

    def test_jellyfin_login_library_play_resume_tracks_expiry_reconnect(self):
        self.api('jellyfin/login','POST',{'server':self.base,'user':'fixture','pass':'fixture-only'})
        self.until('jellyfin',lambda d:d['connected'] and not d['loading'])
        self.api('jellyfin/libraries','POST');self.until('jellyfin',lambda d:bool(d['libraries']) and not d['loading'])
        self.api('jellyfin/browse?id=library-a','POST');self.until('jellyfin',lambda d:bool(d['items']) and not d['loading'])
        self.api('jellyfin/play?id=item-a','POST');self.playback('jellyfin')
        self.expired=True;self.api('jellyfin/libraries','POST');self.until('jellyfin',lambda d:not d['connected'])
        self.expired=False;self.api('jellyfin/login','POST',{'server':self.base,'user':'fixture','pass':'fixture-only'})
        self.until('jellyfin',lambda d:d['connected'] and not d['loading'])
        self.api('jellyfin/browse?id=library-a','POST');self.until('jellyfin',lambda d:bool(d['items']) and not d['loading'])
        before=sum(event[0].startswith('/Videos/') for event in self.events)
        self.api('jellyfin/play?id=item-a','POST')
        self.await_new_stream('/Videos/',before,'fixture-jelly-token')
        self.until('status',lambda d:d.get('active') and d.get('pos',0)>=55)
    def test_jellyfin_disconnect_cancels_inflight_login_publication(self):
        self.delay_auth=True
        self.api('jellyfin/login','POST',{'server':self.base,'user':'fixture','pass':'fixture-only'})
        self.assertTrue(self.auth_started.wait(5),'fixture must hold actual authentication request')
        self.api('jellyfin/disconnect','POST')
        self.auth_release.set()
        self.assertTrue(self.auth_response_done.wait(5))
        time.sleep(.25)  # allow the released response to reach its publication guard
        status=self.until('jellyfin',lambda d:not d['loading'])
        self.assertFalse(status['connected'],'cancelled login must never resurrect disconnected account')

    def test_plex_stable_section_identity_survives_reordered_libraries(self):
        self.until('plex',lambda d:d['connected'])
        self.api('plex/sections','POST'); initial=self.until('plex',lambda d:len(d['sections'])==2 and not d['loading'])
        selected=initial['sections'][0]
        self.reverse_sections=True
        self.api('plex/sections','POST');self.until('plex',lambda d:d['sections'][0]['title']=='Other Movies' and not d['loading'])
        target='key='+urlencode({'v':selected['key']})[2:] if 'key' in selected else 'idx=0'
        self.api('plex/open?'+target,'POST')
        current=self.until('plex',lambda d:bool(d['items']) and not d['loading'])
        self.assertEqual(current['items'][0]['title'],'Generated Movie','rendered library identity must survive new section ordering')

    def test_plex_restore_library_play_resume_tracks_expiry(self):
        self.until('plex',lambda d:d['connected'])
        self.api('plex/sections','POST');self.until('plex',lambda d:bool(d['sections']) and not d['loading'])
        self.api('plex/open?idx=0','POST');self.until('plex',lambda d:bool(d['items']) and not d['loading'])
        self.api('plex/play?id=123','POST');self.playback('plex')
        self.expired=True;self.api('plex/sections','POST');self.until('plex',lambda d:not d['connected'])
        self.opal.stop_process();self.expired=False
        profile=self.opal.config_root/'opal'
        (profile/'plex.json').write_text(json.dumps({'token':'fixture-plex-account-new','server_token':'fixture-plex-server-new','server':self.base,'name':'Reconnected fixture'}))
        self.opal.start(require_setup=False)
        self.until('plex',lambda d:d['connected'])
        self.api('plex/sections','POST');self.until('plex',lambda d:bool(d['sections']) and not d['loading'])
        self.api('plex/open?idx=0','POST');self.until('plex',lambda d:bool(d['items']) and not d['loading'])
        before=sum(event[0].startswith('/library/parts/') for event in self.events)
        self.api('plex/play?id=123','POST')
        self.await_new_stream('/library/parts/',before,'fixture-plex-server-new')
        self.until('status',lambda d:d.get('active') and d.get('pos',0)>=55)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--binary',type=Path,required=True);parser.add_argument('--port',type=int,default=41812)
    args,rest=parser.parse_known_args();live.BINARY=args.binary.resolve();live.PORT=args.port
    unittest.main(argv=[__file__,*rest],verbosity=2)
