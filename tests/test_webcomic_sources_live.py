#!/usr/bin/env python3
"""Owned local metadata + original generated pixels, real Search→Opal reader actions."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sqlite3
import struct
import threading
import time
import unittest
from urllib.parse import urlencode, urlsplit
import zlib
import test_setup_token_live as live

def png():
    def chunk(kind, data):
        return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',2,2,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(b'\0'+b'\xff\0\0'*2+b'\0'+b'\0\xff\0'*2))+chunk(b'IEND',b'')
PIXELS=png()
class Fixture(BaseHTTPRequestHandler):
    def log_message(self,*_): pass
    def do_GET(self):
        path=urlsplit(self.path).path; base=self.server.base
        if path=='/archive/':
            body=b"<div id='middleContainer'><a href='/12/' title='2026-10-04'>Fixture comic</a></div>"; kind='text/html'
        elif path=='/12/info.0.json':
            body=json.dumps({'num':12,'safe_title':'Fixture comic','img':base+'/comics/xkcd.png','alt':'Fixture hover text'}).encode();kind='application/json'
        elif path=='/comic/rss':
            body=(f"<rss><item><title><![CDATA[Fixture SMBC comic]]></title><link>{base}/comic/fixture</link><description><![CDATA[<img src='{base}/comics/smbc.png'>]]></description></item></rss>").encode();kind='application/rss+xml'
        elif path=='/comic/fixture':
            body=f"<img id='cc-comic' src='{base}/comics/smbc.png' title='Fixture hover'><img src='{base}/comics/bonus.png'>".encode();kind='text/html'
        elif path in ('/comics/xkcd.png','/comics/smbc.png'):
            body=PIXELS;kind='image/png'
        else: self.send_error(404); return
        self.send_response(200);self.send_header('Content-Type',kind);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
class WebcomicSources(unittest.TestCase):
    def setUp(self):
        self.fixture=ThreadingHTTPServer(('127.0.0.1',0),Fixture);self.fixture.base=f'http://127.0.0.1:{self.fixture.server_port}'
        threading.Thread(target=self.fixture.serve_forever,daemon=True).start()
        self.addCleanup(self.fixture.server_close);self.addCleanup(self.fixture.shutdown)
        self.opal=live.IsolatedOpal(self);self.addCleanup(self.opal.stop)
        profile=self.opal.config_root/'opal';sources=profile/'plugins'/'sources';sources.mkdir(parents=True)
        for provider in ('xkcd','smbc'):(sources/(provider+'.json')).write_text(json.dumps({'base':self.fixture.base,'_v':'1.0.0'}))
        with sqlite3.connect(profile/'opal.db') as db:
            db.execute("CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT NOT NULL DEFAULT '')")
            db.executemany('INSERT INTO config VALUES(?,?)',[('web_port',str(live.PORT)),('web_bind','loopback'),('search_sources','32'),('auto_download_subs','0'),('content_cache_enabled','0')])
        token=self.opal.start();account=live.register('comic-fixture',host=self.opal.loopback_authority,setup_token=token)
        self.assertEqual(account.status,200);self.headers=(('Cookie',account.session_cookie()),)
    def api(self,path,method='GET'):
        r=live.request(method,'/api/'+path,host=self.opal.loopback_authority,extra_headers=self.headers)
        self.assertEqual(r.status,200,r.body[:512]);return r.json()
    def until(self,path,predicate):
        end=time.monotonic()+65
        while time.monotonic()<end:
            data=self.api(path)
            if predicate(data):return data
            time.sleep(.1)
        self.fail(f'{path} did not settle: {data}')
    def check_reader(self,provider,query):
        self.api('comics/search?'+urlencode({'q':query,'source':provider}))
        initial=self.until('comics/results',lambda d:not d['loading'] and d['source']==provider and len(d['results'])==1)
        before=initial['results']
        self.api('unified_search?'+urlencode({'q':query}))
        data=self.until('unified_search',lambda d:not d['loading'])
        rows=[r for r in data['results'] if r.get('provider')==provider]
        self.assertEqual(len(rows),1,data)
        row=rows[0];self.assertEqual(row['poster_url'],self.fixture.base+'/comics/'+provider+'.png')
        self.assertFalse(row['playable']);self.assertTrue(row['summary'])
        self.api('unified_search/play?'+urlencode({'generation':data['generation'],'key':row['key']}),'POST')
        self.until('comics',lambda d:d.get('pages')==1 and d.get('downloaded',0)>0 and not d['loading'])
        image=live.request('GET','/api/comics/page?i=0',host=self.opal.loopback_authority,extra_headers=self.headers)
        self.assertEqual(image.status,200);self.assertEqual(image.body,PIXELS)
        self.assertEqual(self.api('comics/results')['results'],before)
        self.api('comics/search?'+urlencode({'q':query,'source':provider}))
        browse=self.until('comics/results',lambda d:not d['loading'])
        self.assertEqual(browse['source'],provider)
        self.assertTrue(browse[provider+'_installed'])
        self.assertFalse(browse['has_more'])
        self.assertEqual(len(browse['results']),1)
        self.assertTrue(browse['results'][0]['url'].startswith(provider+':'))
        denied=live.request('GET','/api/comics/search?q=Fixture&source=unknown',host=self.opal.loopback_authority,extra_headers=self.headers)
        self.assertEqual(denied.status,400)
    def test_xkcd_archive_numeric_search_reaches_real_reader(self):self.check_reader('xkcd','12')
    def test_smbc_recent_search_reaches_full_main_panel_reader(self):self.check_reader('smbc','Fixture SMBC')
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--binary',required=True);parser.add_argument('--port',type=int,default=41807)
    args,rest=parser.parse_known_args();live.BINARY=Path(args.binary).resolve();live.PORT=args.port
    unittest.main(argv=[__file__,*rest],verbosity=2)
