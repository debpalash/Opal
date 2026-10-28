#!/usr/bin/env python3
"""Real mpv chapter skip, handoff and whisper caption smoke in an owned profile."""
import argparse
from pathlib import Path
import subprocess
import time
import unittest
from urllib.parse import parse_qs
import test_setup_token_live as h


def run(binary, port, model):
    h.BINARY = Path(binary).resolve()
    h.PORT = port
    app = h.IsolatedOpal(unittest.TestCase())
    try:
        profile = app.config_root / 'opal'
        profile.mkdir(parents=True)
        with h.database(profile / 'opal.db') as conn:
            conn.execute('CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT)')
            conn.execute("INSERT INTO config VALUES('skip_mode','1')")
        models = profile / 'models'
        models.mkdir()
        (models / 'ggml-tiny.en.bin').symlink_to(Path(model).resolve())
        speech = app.root / 'speech.aiff'
        subprocess.run(['say', '-o', str(speech), 'Welcome to the library. Today we are testing live captions. The blue sky is clear. Please remember this sentence.'], check=True)
        chapters = app.root / 'chapters.txt'
        chapters.write_text(';FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=12000\ntitle=Opening\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=12000\nEND=80000\ntitle=Story\n')
        media = app.root / 'caption-test.mkv'
        subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i','color=c=blue:s=160x90:r=10:d=80','-stream_loop','-1','-i',str(speech),'-i',str(chapters),'-map_metadata','2','-map_chapters','2','-map','0:v','-map','1:a','-t','80','-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac','-y',str(media)],check=True)
        token = app.start()
        claimed = h.register('media_owner',host=app.loopback_authority,setup_token=token)
        assert claimed.status == 200
        cookie=claimed.session_cookie()
        def req(method,path,form=None):
            response=h.request(method,path,host=app.loopback_authority,origin='http://'+app.loopback_authority,form=form,extra_headers=(('Cookie',cookie),))
            assert response.status == 200,(response.status,response.body)
            return response.json()
        def wait_for(predicate,seconds=20):
            deadline=time.monotonic()+seconds
            last=None
            while time.monotonic()<deadline:
                last=req('GET','/api/player')
                if predicate(last): return last
                time.sleep(.2)
            raise AssertionError(str(last))
        req('POST','/api/load',{'url':str(media)})
        wait_for(lambda p:p.get('skip',{} ) and p['skip']['kind']=='intro')
        req('POST','/api/player/action?action=skip-segment')
        wait_for(lambda p:p['state']['pos']>=12)
        print('PASS: embedded opening chapter produces skip action and seeks to story')
        offer=req('GET','/api/handoff/offer')
        # An offer must carry a signed URL, never a local path.
        assert str(app.root) not in str(offer),offer
        payload={k:v[0] for k,v in parse_qs(offer['payload']).items()}
        assert '/api/stream/' in payload['source']
        req('POST','/api/handoff',payload)
        wait_for(lambda p:p['state']['pos']>=float(payload['pos']) and p['state']['dur']>70)
        print('PASS: signed handoff is accepted and resumes playback')
        req('POST','/api/player/action?action=live-captions&value=true')
        snap=wait_for(lambda p:p.get('subtitle_discovery',{}).get('babel',{}).get('live_cues',0)>2,90)
        assert snap['tracks']['subtitles'],snap
        print('PASS: whisper live captions publish cues and attach an mpv subtitle track')
        # Coverage must advance beyond one chunk, exercising overlapping extraction.
        initial=snap['subtitle_discovery']['babel']['live_cues']
        wait_for(lambda p:p.get('subtitle_discovery',{}).get('babel',{}).get('live_cues',0)>initial,90)
        print('PASS: live captions advance across overlapping chunks; local handoff offer is signed')
    finally:
        app.stop()


if __name__=='__main__':
    p=argparse.ArgumentParser()
    p.add_argument('--binary',default='zig-out/bin/opal')
    p.add_argument('--port',type=int,default=42985)
    p.add_argument('--model',required=True)
    a=p.parse_args()
    run(a.binary,a.port,a.model)
