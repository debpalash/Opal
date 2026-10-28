#!/usr/bin/env python3
"""Detect a shared audio intro in two real sibling videos without chapter metadata."""
import argparse
import array
import math
import subprocess
import time
import unittest
import wave
from pathlib import Path
import test_setup_token_live as h


def run(binary, port):
    h.BINARY=Path(binary).resolve(); h.PORT=port
    app=h.IsolatedOpal(unittest.TestCase())
    try:
        profile=app.config_root/'opal';profile.mkdir(parents=True)
        with h.database(profile/'opal.db') as db:
            db.execute('CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT)')
            db.execute("INSERT INTO config VALUES('skip_mode','1')")
        for episode in (1,2):
            pcm=array.array('h')
            for i in range(120*8000):
                t=i/8000; seed=0 if t<20 else episode*13
                note=int(t*3)+seed
                freq=180+(note*73%780)
                value=.35*math.sin(2*math.pi*freq*t)+.20*math.sin(2*math.pi*freq*1.51*t)
                pcm.append(int(value*30000))
            wav=app.root/f'{episode}.wav'
            with wave.open(str(wav),'wb') as out:
                out.setnchannels(1);out.setsampwidth(2);out.setframerate(8000);out.writeframes(pcm.tobytes())
            video=app.root/f'Fixture.S01E0{episode}.mkv'
            subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i','color=c=blue:s=160x90:r=5:d=120','-i',str(wav),'-c:v','libx264','-c:a','flac','-y',str(video)],check=True)
        token=app.start();account=h.register('fingerprint-owner',host=app.loopback_authority,setup_token=token)
        assert account.status==200
        def req(method,path,form=None):
            r=h.request(method,path,host=app.loopback_authority,origin='http://'+app.loopback_authority,form=form,extra_headers=(('Cookie',account.session_cookie()),))
            assert r.status==200,(r.status,r.body)
            return r.json()
        req('POST','/api/load',{'url':str(app.root/'Fixture.S01E01.mkv')})
        deadline=time.monotonic()+60
        while time.monotonic()<deadline:
            snap=req('GET','/api/player')
            if snap.get('skip'): break
            time.sleep(.2)
        else: raise AssertionError(snap)
        assert not snap['chapters'],snap
        assert snap['skip']['kind']=='intro',snap['skip']
        with h.database(profile/'opal.db') as db:
            assert db.execute('SELECT COUNT(*) FROM media_fingerprints').fetchone()[0]==2
        req('POST','/api/player/action?action=skip-segment')
        time.sleep(.3)
        assert req('GET','/api/player')['state']['pos']>=15
        print('PASS: real audio fingerprints find shared intro across sibling episodes and skip playback without chapters')
    finally: app.stop()

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--binary',required=True);p.add_argument('--port',type=int,default=42992)
    a=p.parse_args();run(a.binary,a.port)
