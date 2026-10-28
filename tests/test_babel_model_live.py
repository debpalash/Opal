#!/usr/bin/env python3
"""Translate real embedded subtitles through an owned, loopback-only llama server."""
import argparse
import json
import os
import socket
import subprocess
import time
import unittest
from pathlib import Path
from urllib.request import urlopen
import test_setup_token_live as h


def run(binary, model, port, model_port, embeddings=False):
    h.BINARY = Path(binary).resolve(); h.PORT = port
    app = h.IsolatedOpal(unittest.TestCase())
    server = None
    original_root = h.REPO_ROOT
    log = None
    old_embed = os.environ.get("OPAL_EMBED_URL")
    try:
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', model_port))
        profile = app.config_root / 'opal'; profile.mkdir(parents=True)
        with h.database(profile/'opal.db') as db:
            db.execute('CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT)')
            db.executemany('INSERT INTO config VALUES(?,?)', [
                ('ai_backend','cloud'), ('ai_cloud_provider','openrouter'),
                ('babel_translate_lang','es'), ('auto_download_subs','0'), ('search_sources','0')])
        # The cloud adapter points only at our local model; no credentials or
        # environment from the repository are read and Opal does not own llama.
        (app.root/'.env').write_text(f'OPENROUTER_API_KEY=local-fixture\nOPENROUTER_BASE_URL=http://127.0.0.1:{model_port}/v1\nOPENROUTER_MODEL=fixture\n')
        (app.root/'libtorrent_wrapper.so').symlink_to(original_root/'libtorrent_wrapper.so')
        h.REPO_ROOT = app.root
        log = (app.root/'model.log').open('w+b')
        os.environ['OPAL_EMBED_URL'] = f'http://127.0.0.1:{model_port}/v1/embeddings'
        server = subprocess.Popen(['llama-server','-m',str(Path(model).resolve()),'--host','127.0.0.1','--port',str(model_port),'-c','4096','--reasoning','off','--parallel','1'] + (['--embedding','--pooling','mean'] if embeddings else []),stdout=log,stderr=subprocess.STDOUT)
        deadline=time.monotonic()+90
        while time.monotonic()<deadline:
            if server.poll() is not None: raise AssertionError('local model server exited')
            try:
                with urlopen(f'http://127.0.0.1:{model_port}/health',timeout=1) as response:
                    if response.status==200: break
            except Exception: time.sleep(.25)
        else: raise AssertionError('local model server unavailable')
        srt=app.root/'source.srt';srt.write_text('1\n00:00:00,000 --> 00:00:08,000\nHello, my friend.\n\n2\n00:00:08,000 --> 00:00:16,000\nThe blue sky is beautiful.\n')
        media=app.root/'translation.mkv'
        subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i','color=c=blue:s=160x90:d=180','-i',str(srt),'-map','0:v','-map','1:s','-c:v','libx264','-c:s','srt','-disposition:s:0','default','-y',str(media)],check=True)
        token=app.start(); account=h.register('model-owner',host=app.loopback_authority,setup_token=token)
        assert account.status==200
        def req(method,path,form=None):
            r=h.request(method,path,host=app.loopback_authority,origin='http://'+app.loopback_authority,form=form,extra_headers=(('Cookie',account.session_cookie()),))
            assert r.status==200,(r.status,r.body)
            return r.json()
        if embeddings:
            with h.database(profile/'opal.db') as db:
                db.execute('INSERT INTO local_media(path,root,title) VALUES(?,?,?)',(str(media),str(app.root),'Beautiful blue sky'))
            deadline=time.monotonic()+90
            while time.monotonic()<deadline:
                with h.database(profile/'opal.db') as db:
                    row=db.execute("SELECT value FROM recall_meta WHERE key='embed_dim'").fetchone()
                    count=db.execute('SELECT COUNT(*) FROM recall_docs WHERE embedded=1').fetchone()[0]
                if row and int(row[0])>0 and count: break
                time.sleep(.5)
            else: raise AssertionError('index never persisted real embeddings')
            found=req('GET','/api/recall?q=beautiful')
            assert found['vectors'] and found['docs'],found
            print('PASS: real local model embeddings persist in the vector index and are used by Recall search (integration, not ranking-quality evaluation)')
            return
        req('POST','/api/load',{'url':str(media)})
        deadline=time.monotonic()+20
        while time.monotonic()<deadline:
            snap=req('GET','/api/player')
            if snap.get('tracks',{}).get('subtitles'): break
            time.sleep(.2)
        req('POST','/api/player/action?action=subtitle-translate')
        deadline=time.monotonic()+150
        while time.monotonic()<deadline:
            snap=req('GET','/api/player'); status=snap.get('subtitle_discovery',{}).get('babel',{}).get('translate_status','')
            if status.startswith('Translated'): break
            if status.startswith('Translation failed'): raise AssertionError(status)
            time.sleep(.5)
        else: raise AssertionError(snap)
        translated=[p for p in app.root.rglob('*.es.srt')]
        assert translated, (status,list(app.root.rglob('*.srt')))
        text=translated[0].read_text()
        assert 'Hola' in text and '00:00:08,000' in text,(status,text)
        assert '0 kept original' in status,status
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            snap=req('GET','/api/player')
            if len(snap['tracks']['subtitles'])>=2: break
            time.sleep(.1)
        else: raise AssertionError('translated track was not attached')
        print('PASS: real local model translates two embedded cues into Spanish, retains timing, and attaches the translated track')
    finally:
        app.stop()
        h.REPO_ROOT=original_root
        if old_embed is None: os.environ.pop("OPAL_EMBED_URL",None)
        else: os.environ["OPAL_EMBED_URL"]=old_embed
        if server and server.poll() is None:
            server.terminate()
            try: server.wait(timeout=10)
            except subprocess.TimeoutExpired: server.kill();server.wait()
        if log: log.close()

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--binary',required=True);p.add_argument('--model',required=True);p.add_argument('--port',type=int,default=42990);p.add_argument('--model-port',type=int,default=42991)
    p.add_argument('--embeddings',action='store_true')
    a=p.parse_args();run(a.binary,a.model,a.port,a.model_port,a.embeddings)
