#!/usr/bin/env python3
"""Two isolated Opal processes, real stream modes and child-profile restrictions."""
import argparse
from pathlib import Path
import shutil
import subprocess
import time
import unittest
import test_setup_token_live as h

class App:
    def __init__(self,binary,port):
        self.port=port;self.host=f'127.0.0.1:{port}';self.app=h.IsolatedOpal(unittest.TestCase())
        h.BINARY=Path(binary).resolve();h.PORT=port
        token=self.app.start(); account=h.register(f'owner-{port}',host=self.host,setup_token=token)
        assert account.status==200
        self.cookie=account.session_cookie();self.token=(self.app.config_root/'opal/api.token').read_text().strip()
    def req(self,method,path,form=None,status=200):
        h.PORT=self.port
        r=h.request(method,path,host=self.host,origin='http://'+self.host,form=form,extra_headers=(('Cookie',self.cookie),))
        assert r.status==status,(path,r.status,r.body[:500])
        return r.json()
    def wait(self,path,predicate,seconds=30):
        end=time.monotonic()+seconds;last=None
        while time.monotonic()<end:
            try:
                last=self.req('GET',path)
                if predicate(last): return last
            except (OSError,AssertionError): pass
            time.sleep(.1)
        raise AssertionError(last)
    def stop(self): self.app.stop()

def run(binary,port):
    a=b=None
    try:
        a=App(binary,port);b=App(binary,port+1)
        media=a.app.root/'generated.mp4'
        subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i','testsrc2=size=960x540:rate=15:duration=50','-f','lavfi','-i','sine=frequency=440:duration=50','-c:v','libx264','-preset','ultrafast','-c:a','aac','-movflags','+faststart','-y',str(media)],check=True)
        mkv=a.app.root/'generated.mkv'
        subprocess.run(['ffmpeg','-v','error','-i',str(media),'-c','copy','-y',str(mkv)],check=True)
        with h.database(a.app.config_root/'opal/opal.db') as db:
            for file in (media,mkv): db.execute('INSERT INTO local_media(path,root,title) VALUES(?,?,?)',(str(file),str(a.app.root),file.stem))
            ids={Path(path).suffix:rowid for rowid,path in db.execute('SELECT rowid,path FROM local_media')}
        for suffix,quality,expected in [('.mp4','original','direct'),('.mkv','original','remux'),('.mp4','480p','transcode')]:
            stream=a.req('POST','/api/stream',{'id':str(ids[suffix]),'quality':quality,'caps':'h264,aac,mp4,hls'})
            assert stream['mode']==expected,stream
            url='http://'+a.host+stream['url']
            # ffprobe consumes the actual signed stream and its HLS segments.
            probe=subprocess.run(['ffprobe','-v','error','-show_entries','stream=codec_name,height','-of','json',url],capture_output=True,text=True,timeout=60)
            assert probe.returncode==0,(expected,probe.stderr)
            decoded=subprocess.run(['ffmpeg','-v','error','-i',url,'-t','2','-f','null','-'],capture_output=True,text=True,timeout=60)
            assert decoded.returncode==0,(expected,decoded.stderr)
            if expected=='transcode':
                import json
                tracks=json.loads(probe.stdout)['streams']; assert any(x.get('height')==480 for x in tracks),tracks
                print('Encoder:',a.req('GET','/api/stream'))
            a.req('POST',stream['url'].rsplit('/',1)[0]+'/stop')
            print('PASS: signed',expected,'stream is actually decoded'+(' at 480p' if expected=='transcode' else ''))
        a.req('POST','/api/load',{'url':str(media)})
        a.wait('/api/status',lambda x:x.get('dur',0)>45)
        a.req('POST','/api/seek_pct?v=40')
        a.wait('/api/status',lambda x:19<=x.get('pos',0)<=24)
        a.req('POST','/api/handoff/send',{'peer':'http://'+b.host,'token':b.token})
        received=b.wait('/api/status',lambda x:x.get('dur',0)>45 and 19<=x.get('pos',0)<=27)
        assert received.get('active'),received
        print('PASS: two independent Opal processes hand off signed media and resume around 20 seconds')
        # The receiving instance plays through the sender's signed endpoint;
        # bring exercises the inverse authenticated request and pause offer.
        refused=b.req('GET','/api/handoff/offer',status=409)
        assert refused['error']=='this source only plays on this machine',refused
        receiver_media=b.app.root/'receiver.mp4';shutil.copyfile(media,receiver_media)
        b.req('POST','/api/load',{'url':str(receiver_media)})
        b.wait('/api/status',lambda x:x.get('dur',0)>45)
        b.req('POST','/api/seek_pct?v=40')
        b.wait('/api/status',lambda x:19<=x.get('pos',0)<=24)
        a.req('POST','/api/handoff/bring',{'peer':'http://'+b.host,'token':b.token})
        a.wait('/api/status',lambda x:x.get('dur',0)>45 and x.get('pos',0)>=19)
        print('PASS: bring retrieves playback from the receiver on this Mac')
        with h.database(a.app.config_root/'opal/opal.db') as db:
            doc=db.execute("INSERT INTO recall_docs(source,source_key,kind,title,body,link) VALUES('local','moment-fixture','movie','Harbor mystery','brass compass',?) RETURNING id",(str(media),)).fetchone()[0]
            moment=db.execute('INSERT INTO recall_moments(doc_id,start_ms,end_ms,text) VALUES(?,32000,37000,?) RETURNING id',(doc,'They discover the brass compass beside the harbor.')).fetchone()[0]
            db.execute('INSERT INTO recall_moments_fts(rowid,text) VALUES(?,?)',(moment,'They discover the brass compass beside the harbor.'))
        found=a.req('GET','/api/recall?q=brass%20compass')
        assert any(row['id']==moment for row in found['moments']),found
        result=a.req('POST','/api/recall/play',{'moment':str(moment)})
        assert result['start_secs']==32,result
        a.wait('/api/status',lambda x:x.get('dur',0)>45 and 31<=x.get('pos',0)<=38)
        print('PASS: indexed subtitle moment search starts actual playback at 32 seconds')
        kid=a.req('POST','/api/profiles/create',{'name':'Child fixture','kid':'1'})
        a.req('POST','/api/profiles/switch',{'id':kid['id']})
        a.wait('/api/profiles',lambda x:x['active']==kid['id'],45)
        a.req('GET','/api/moments',status=403)
        written=a.req('POST','/api/settings?key=nsfw_filter&value=false')
        assert written['value'] is True,written
        a.req('POST','/api/settings/toggle?key=nsfw_filter')
        a.wait('/api/settings',lambda x: 'nsfw_filter' in str(x))
        time.sleep(.3)
        settings=a.req('GET','/api/settings')
        # Actual schema uses named setting descriptors; inspect the matching row.
        def setting(value):
            if isinstance(value,dict):
                if 'nsfw_filter' in value and isinstance(value['nsfw_filter'],bool): return value['nsfw_filter']
                if value.get('key',value.get('name'))=='nsfw_filter': return value.get('value')
                for child in value.values():
                    found=setting(child)
                    if found is not None: return found
            if isinstance(value,list):
                for child in value:
                    found=setting(child)
                    if found is not None: return found
        assert setting(settings) is True,settings
        print('PASS: child profile rejects shared clips and prevents both NSFW disable routes')
    finally:
        if b: b.stop()
        if a: a.stop()

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--binary',required=True);p.add_argument('--port',type=int,default=42994)
    args=p.parse_args();run(args.binary,args.port)
