#!/usr/bin/env python3
"""Run the production recap worker with synthetic watched history and a real model."""
import argparse
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
from urllib.request import Request,urlopen


def run(binary, model, port):
    with tempfile.TemporaryDirectory(prefix='opal-recap-model-') as temp:
        root=Path(temp); requests=[]; server=None; proxy=None
        with socket.socket() as s: s.bind(('127.0.0.1',port))
        log=(root/'model.log').open('w+b')
        try:
            server=subprocess.Popen(['llama-server','-m',str(Path(model).resolve()),'--host','127.0.0.1','--port',str(port),'-c','4096','--reasoning','off','--parallel','1'],stdout=log,stderr=subprocess.STDOUT)
            end=time.monotonic()+90
            while time.monotonic()<end:
                if server.poll() is not None: raise AssertionError('model server exited')
                try:
                    with urlopen(f'http://127.0.0.1:{port}/health',timeout=1) as r:
                        if r.status==200: break
                except Exception: time.sleep(.25)
            else: raise AssertionError('model health timeout')
            class Proxy(http.server.BaseHTTPRequestHandler):
                def log_message(self,*args): pass
                def do_POST(self):
                    body=self.rfile.read(int(self.headers['Content-Length'])); requests.append(json.loads(body))
                    with urlopen(Request(f'http://127.0.0.1:{port}'+self.path,data=body,headers={'Content-Type':'application/json'}),timeout=125) as r:
                        data=r.read();self.send_response(r.status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
            proxy=http.server.ThreadingHTTPServer(('127.0.0.1',0),Proxy)
            threading.Thread(target=proxy.serve_forever,daemon=True).start()
            (root/'.env').write_text(f'OPENROUTER_API_KEY=fixture\nOPENROUTER_BASE_URL=http://127.0.0.1:{proxy.server_port}/v1\nOPENROUTER_MODEL=fixture\n')
            repo=Path(__file__).resolve().parents[1]
            (root/'libtorrent_wrapper.so').symlink_to(repo/'libtorrent_wrapper.so')
            env=os.environ.copy();env.update(HOME=str(root/'home'),XDG_CONFIG_HOME=str(root/'config'),XDG_CACHE_HOME=str(root/'cache'),XDG_DATA_HOME=str(root/'data'),OPAL_HORIZON_FIXTURE_DIR=str(root),OPAL_MPV_OPTS='ao=null;vo=null')
            result=subprocess.run([str(Path(binary).resolve())],cwd=root,env=env,capture_output=True,text=True,timeout=180)
            assert result.returncode==0,result.stderr[-4000:]
            assert len(requests)==1, f'cache should avoid a second model call: {len(requests)}'
            prompt=json.dumps(requests[0])
            assert 'brass compass' in prompt,prompt
            for canary in ('UNWATCHED_CANARY','CURRENT_CANARY','FUTURE_CANARY','dragon','vanishes','father'):
                assert canary not in prompt,canary+' leaked into model input'
            recap=(root/'recap.txt').read_text()
            print('PASS: real recap worker selects watched earlier sources before submission; current/future/unwatched canaries excluded; local-model response and cache verified')
            print('Recap:',recap)
        finally:
            if proxy: proxy.shutdown();proxy.server_close()
            if server and server.poll() is None:
                server.terminate()
                try: server.wait(timeout=10)
                except subprocess.TimeoutExpired: server.kill();server.wait()
            log.close()

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--binary',required=True);p.add_argument('--model',required=True);p.add_argument('--port',type=int,default=42993)
    a=p.parse_args();run(a.binary,a.model,a.port)
