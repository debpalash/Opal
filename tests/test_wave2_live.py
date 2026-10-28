#!/usr/bin/env python3
"""Owned loopback fixtures for signed add-ons and exported household clips."""
import argparse
import functools
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import time
import unittest
import test_setup_token_live as h


def run(binary, port):
    h.BINARY = Path(binary).resolve(); h.PORT = port
    app = h.IsolatedOpal(unittest.TestCase())
    server = None
    try:
        # OpenSSL signs fixtures; production verification is Zig Ed25519.
        openssl = '/opt/homebrew/opt/openssl@3/bin/openssl'
        if not Path(openssl).exists(): openssl = shutil.which('openssl')
        key = app.root / 'publisher.pem'
        subprocess.run([openssl,'genpkey','-algorithm','Ed25519','-out',str(key)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
        der=subprocess.check_output([openssl,'pkey','-in',str(key),'-pubout','-outform','DER'])
        public=der[-32:].hex()
        catalog={'version':1,'addons':[{'id':'fixture','name':'Fixture','version':'1','permissions':['network'],'files':[{'name':'manifest.json','content':json.dumps({'name':'Fixture','version':'1'})},{'name':'search','content':'#!/usr/bin/env lua\nprint("[]")\n'}],'panel':{'title':'Fixture panel','body':'<script>text only</script>'}}]}
        manifest=json.dumps(catalog,separators=(',',':'))
        raw=app.root/'manifest'; raw.write_text(manifest)
        signature=subprocess.check_output([openssl,'pkeyutl','-sign','-rawin','-inkey',str(key),'-in',str(raw)]).hex()
        envelope={'manifest':manifest,'signature':signature}
        repo=app.root/'repo.json'; repo.write_text(json.dumps(envelope))
        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self,*args): pass
        server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Handler,directory=str(app.root)))
        threading.Thread(target=server.serve_forever,daemon=True).start()
        token=app.start()
        claimed=h.register('wave2_owner',host=app.loopback_authority,setup_token=token)
        assert claimed.status==200
        cookie=claimed.session_cookie()
        machine=(app.config_root/'opal/api.token').read_text().strip()
        def req(method,path,form=None,machine_auth=False,status=200):
            headers=(('Authorization','Bearer '+machine),) if machine_auth else (('Cookie',cookie),)
            r=h.request(method,path,host=app.loopback_authority,origin='http://'+app.loopback_authority,form=form,extra_headers=headers)
            assert r.status==status,(path,r.status,r.body[:500])
            return r.json()
        req('POST','/api/addons/add',{'id':'publisher','url':f'http://127.0.0.1:{server.server_port}/repo.json','public_key':public})
        req('POST','/api/addons/refresh',{'id':'publisher'})
        listed=req('GET','/api/addons')['repositories'][0]
        assert listed['addons'][0]['panel']['body']=='<script>text only</script>'
        assert 'files' not in listed['addons'][0]
        install={'id':'publisher','addon':'fixture','confirmation':listed['confirmation']}
        req('POST','/api/addons/install',install,status=403)
        req('POST','/api/addons/install',{**install,'confirmation':'0'*64},machine_auth=True,status=400)
        req('POST','/api/addons/install',install,machine_auth=True)
        installed=req('GET','/api/plugins')['executables']
        plugin=next(p for p in installed if p['id']=='fixture')
        assert plugin['search'] and not plugin['trusted'],plugin
        req('POST','/api/addons/install',install,machine_auth=True,status=400)
        envelope['manifest']=manifest.replace('Fixture','Tampered')
        repo.write_text(json.dumps(envelope))
        req('POST','/api/addons/refresh',{'id':'publisher'},status=400)
        assert req('GET','/api/addons')['repositories'][0]['addons'][0]['name']=='Fixture'
        print('PASS: signed catalog, tamper rejection, revision confirmation, machine-only install, no automatic trust')
        media=app.root/'sample.mp4'
        subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i','color=c=blue:s=160x90:d=20','-c:v','libx264','-pix_fmt','yuv420p','-y',str(media)],check=True)
        req('POST','/api/load',{'url':str(media)})
        deadline=time.monotonic()+15
        while time.monotonic()<deadline:
            state=req('GET','/api/status')
            if state.get('dur',0)>19: break
            time.sleep(.1)
        req('POST','/api/moments/create',{'title':'Too long','start':'0','end':'121'},status=400)
        clip=req('POST','/api/moments/create',{'title':'Blue moment','start':'1','end':'3'})
        if os.name == 'posix':
            clip_file=app.config_root/'opal/moments'/f"{clip['id']}.mp4"
            assert clip_file.stat().st_mode & 0o777 == 0o600
            assert clip_file.parent.stat().st_mode & 0o777 == 0o700
        feed=req('GET','/api/moments')['moments']
        assert len(feed)==1 and feed[0]['title']=='Blue moment'
        assert 'path' not in feed[0] and str(app.root) not in json.dumps(feed)
        play=req('POST','/api/moments/play',{'id':clip['id']})
        r=h.request('GET',play['url'],host=app.loopback_authority)
        assert r.status==200 and len(r.body)>100
        saved=app.root/'received.mp4'; saved.write_bytes(r.body)
        duration=float(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration','-of','default=nw=1:nk=1',str(saved)]))
        assert 1.5<=duration<=2.5,duration
        req('POST','/api/moments/send',{'id':clip['id'],'peer':'http://'+app.loopback_authority,'token':machine})
        req('POST','/api/moments/delete',{'id':clip['id']})
        assert req('GET','/api/moments')['moments']==[]
        print('PASS: bounded real clip export, private household feed, signed playback, paired-token send, delete')
    finally:
        if server: server.shutdown(); server.server_close()
        app.stop()

if __name__=='__main__':
    p=argparse.ArgumentParser(); p.add_argument('--binary',default='/tmp/opal-wave2-live/bin/opal'); p.add_argument('--port',type=int,default=42988)
    a=p.parse_args();run(a.binary,a.port)
