#!/usr/bin/env python3
"""Isolated installed public-audio adapters; synthetic metadata and silence only."""
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

class AudioFixture(BaseHTTPRequestHandler):
    paths=[]
    def log_message(self, *_): pass
    def do_GET(self):
        path = urlsplit(self.path).path
        self.paths.append(self.path)
        base = self.server.base
        if path in ('/silence.wav','/silence-radio.wav'):
            output = io.BytesIO()
            with wave.open(output,'wb') as wav:
                wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(8000)
                wav.writeframes(b'\0\0'*80000)
            body = output.getvalue(); kind = 'audio/wav'
        elif path == '/v1/audio/':
            body = json.dumps({'result_count':1,'results':[{'id':'fixture-openverse','title':'Fixture music','creator':'Fixture author','category':'music','url':base+'/silence.wav','license_url':'https://creativecommons.org/publicdomain/zero/1.0/','attribution':'Fixture author CC0','duration':10000}]}).encode(); kind='application/json'
        elif path == '/advancedsearch.php':
            body=json.dumps({'response':{'numFound':1,'docs':[{'identifier':'fixture-release'}]}}).encode(); kind='application/json'
        elif path == '/metadata/fixture-release':
            body=json.dumps({'metadata':{'identifier':'fixture-release','title':'Fixture album','creator':'Fixture artist','licenseurl':'https://creativecommons.org/publicdomain/zero/1.0/'},'files':[{'name':'01 Fixture music.mp3'},{'name':'01 Fixture music.flac'},{'name':'release.zip'}]}).encode(); kind='application/json'
        elif path == '/channels.json':
            body=json.dumps({'channels':[{'id':'fixture','title':'Fixture radio','description':'Fixture music stream','playlists':[{'url':base+'/silence-radio.wav','format':'mp3','quality':'highest'}]}]}).encode(); kind='application/json'
        else:
            self.send_error(404); return
        self.send_response(200); self.send_header('Content-Type',kind); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)

class GitHubAudioLiveTest(unittest.TestCase):
    def setUp(self):
        self.fixture=ThreadingHTTPServer(('127.0.0.1',0),AudioFixture)
        self.fixture.base='http://127.0.0.1:'+str(self.fixture.server_port)
        threading.Thread(target=self.fixture.serve_forever,daemon=True).start()
        self.addCleanup(self.fixture.server_close); self.addCleanup(self.fixture.shutdown)
        self.opal=live.IsolatedOpal(self); self.addCleanup(self.opal.stop)
        profile=self.opal.config_root/'opal'; sources=profile/'plugins'/'sources'; sources.mkdir(parents=True)
        for provider in ('openverse','netlabels','somafm'):
            (sources/(provider+'.json')).write_text(json.dumps({'base':self.fixture.base,'_v':'1.0.0'}))
        with sqlite3.connect(profile/'opal.db') as db:
            db.execute("CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT NOT NULL DEFAULT '')")
            db.executemany('INSERT INTO config VALUES(?,?)',[('web_port',str(live.PORT)),('web_bind','loopback'),('search_sources',str((1<<9)|(1<<10))),('auto_download_subs','0'),('playback_volume','0'),('content_cache_enabled','0')])
        token=self.opal.start(); account=live.register('audio-fixture',host=self.opal.loopback_authority,setup_token=token)
        self.assertEqual(account.status,200); self.headers=(('Cookie',account.session_cookie()),)
    def api(self,path,method='GET'):
        r=live.request(method,'/api/'+path,host=self.opal.loopback_authority,extra_headers=self.headers)
        self.assertEqual(r.status,200,r.body[:512]); return r.json()
    def until(self,path,predicate):
        deadline=time.monotonic()+70
        while time.monotonic()<deadline:
            result=self.api(path)
            if predicate(result): return result
            time.sleep(.15)
        self.fail(path+' did not settle')
    def test_music_browse_sources_keep_exact_stream_and_credit(self):
        for source in (5,6):
            self.api(f'music/source?id={source}','POST'); self.api('music/search?q=Fixture','POST')
            data=self.until('music',lambda d:not d['loading'])
            self.assertEqual(data['source'],source); self.assertEqual(len(data['songs']),1,(data,AudioFixture.paths))
            row=data['songs'][0]
            self.assertIn('creativecommons.org',row['attribution'])
            if source==5:
                self.assertEqual(row['url'],self.fixture.base+'/silence.wav')
                self.api('music/play?'+urlencode({'source':source,'id':row['id']}),'POST')
                self.until('status',lambda d:d.get('active') and d.get('dur',0)>0)
            else:
                self.assertIn('01%20Fixture%20music.mp3',row['url'])
    def test_universal_independent_audio_and_radio_browse(self):
        before=self.api('music')
        self.api('unified_search?q=Fixture')
        data=self.until('unified_search',lambda d:not d['loading'])
        rows={row['provider']:row for row in data['results'] if row.get('provider') in ('openverse','netlabels','somafm')}
        self.assertEqual(set(rows),{'openverse','netlabels','somafm'},data)
        self.assertEqual(self.api('music')['songs'],before['songs'])
        for provider,row in rows.items():
            self.assertTrue(row['playable'],provider)
            if provider!='somafm': self.assertIn('creativecommons.org',row['summary'])
        self.assertFalse(self.api('status')['active'])
        self.api('unified_search/play?'+urlencode({'generation':data['generation'],'key':rows['somafm']['key']}),'POST')
        self.until('status',lambda d:d.get('active') and d.get('dur',0)>0)
        self.api('radio/search?q=Fixture')
        radio=self.until('radio',lambda d:not d['loading'])
        self.assertTrue(any(row.get('uuid')=='somafm:fixture' for row in radio['stations']))

if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--binary',required=True); parser.add_argument('--port',type=int,default=41779)
    args,rest=parser.parse_known_args(); live.BINARY=Path(args.binary).resolve(); live.PORT=args.port
    unittest.main(argv=[__file__,*rest],verbosity=2)
