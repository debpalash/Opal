#!/usr/bin/env python3
"""Isolated Horizon API regression: profile restart, recall and signed streaming."""
import argparse
import json
from pathlib import Path
import subprocess
import time
import unittest
import test_setup_token_live as h


def run(binary, port):
    h.BINARY = Path(binary).resolve()
    h.PORT = port
    app = h.IsolatedOpal(unittest.TestCase())
    try:
        token = app.start()
        response = h.register('horizon_owner', host=app.loopback_authority, setup_token=token)
        assert response.status == 200, response.status
        cookie = response.session_cookie()
        def request(method, path, form=None):
            return h.request(method, path, host=app.loopback_authority, origin='http://' + app.loopback_authority, form=form, extra_headers=(('Cookie', cookie),))
        def good(response):
            assert response.status == 200, (response.status, response.body)
            return response.json()
        assert good(request('GET', '/api/profiles'))['active'] == 'default'
        media = app.root / 'sample.mp4'
        subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=blue:s=160x90:d=3', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-y', str(media)], check=True)
        db = app.config_root / 'opal' / 'opal.db'
        with h.database(db) as conn:
            conn.execute('INSERT INTO local_media(path,root,title) VALUES(?,?,?)', (str(media), str(app.root), 'Horizon sample'))
            mid = conn.execute('SELECT rowid FROM local_media WHERE path=?', (str(media),)).fetchone()[0]
            conn.execute("INSERT INTO recall_docs(source,source_key,kind,title,body) VALUES('local','fixture','movie','Horizon sample','blue sky fixture')")
            rid = conn.execute("SELECT id FROM recall_docs WHERE source_key='fixture'").fetchone()[0]
            conn.execute('INSERT INTO recall_fts(rowid,title,body) VALUES(?,?,?)', (rid, 'Horizon sample', 'blue sky fixture'))
        found = good(request('GET', '/api/recall?q=Horizon'))
        assert any(row['title'] == 'Horizon sample' for row in found['docs']), found
        stream = good(request('POST', '/api/stream', {'id':str(mid), 'caps':'h264,aac,mp4,hls'}))
        media_response = request('GET', stream['url'])
        assert media_response.status == 200, media_response.status
        assert media_response.body, 'empty stream'
        prefix = stream['url'].rsplit('/', 1)[0]
        good(request('POST', prefix + '/progress', {'pos':'1', 'dur':'3'}))
        good(request('POST', prefix + '/stop'))
        assert request('GET', stream['url']).status == 404
        print('PASS: Recall returns seeded title; signed stream serves media, accepts progress and stops')
        created = good(request('POST', '/api/profiles/create', {'name':'Test "Profile"', 'pin':'1234'}))
        response = request('POST', '/api/profiles/switch', {'id':created['id'], 'pin':'0000'})
        assert response.status == 401, response.status
        switched = good(request('POST', '/api/profiles/switch', {'id':created['id'], 'pin':'1234'}))
        assert switched['restarting']
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            try:
                current = good(request('GET', '/api/profiles'))
                if current['active'] == created['id']:
                    break
            except (OSError, AssertionError):
                pass
            time.sleep(.25)
        else:
            raise AssertionError('profile restart did not restore authenticated access; exit=' + str(app.process.poll()) + '\n' + app.safe_log())
        assert good(request('GET', '/api/recall?q=Horizon'))['docs'] == [], 'profile recall data leaked'
        print('PASS: wrong PIN rejected; restart preserves account and isolates Recall data')
    finally:
        app.stop()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', default='zig-out/bin/opal')
    parser.add_argument('--port', type=int, default=42984)
    args = parser.parse_args()
    run(args.binary, args.port)
