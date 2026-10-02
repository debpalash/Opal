#!/usr/bin/env python3
"""Optional local benchmark; generated fixtures, fresh HOME/XDG, no external media."""
import sys,sqlite3,time,statistics,json,unittest
from pathlib import Path
from urllib.parse import quote
sys.path.insert(0,str(Path(__file__).resolve().parent))
import test_setup_token_live as live
import argparse
parser=argparse.ArgumentParser(description="Measure Watching full and conditional responses against an isolated headless instance")
parser.add_argument('--binary',type=Path,required=True)
parser.add_argument('--port',type=int,default=41702)
args=parser.parse_args()
live.BINARY=args.binary.resolve();live.PORT=args.port
opal=live.IsolatedOpal(unittest.TestCase())
try:
 config=opal.config_root/'opal';config.mkdir(parents=True,exist_ok=True)
 with sqlite3.connect(config/'opal.db') as db:
  db.execute("CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT NOT NULL DEFAULT '')")
  db.executemany('INSERT INTO config VALUES(?,?)',[('web_port',str(live.PORT)),('web_bind','loopback'),('search_sources','0'),('auto_download_subs','0')])
 token=opal.start(); account=live.register('watch-measure',host=opal.loopback_authority,setup_token=token);assert account.status==200
 headers=(("Cookie",account.session_cookie()),)
 with sqlite3.connect(config/'opal.db') as db:
  for i in range(200):
   ident=880000+i
   db.execute('INSERT INTO tv_shows(tmdb_id,name,tracked,last_aired_season,last_aired_episode) VALUES(?,?,1,1,8)',(ident,f'Fixture {i:03d} '+('context '*12)))
   db.execute('INSERT INTO tv_seasons VALUES(?,1,8)',(ident,))
   db.execute('INSERT INTO tv_watched(tmdb_id,season,episode,watched) VALUES(?,1,1,1)',(ident,))
 def get(path):return live.request('GET',path,host=opal.loopback_authority,extra_headers=headers)
 r=live.request('POST','/api/library/action?action=watched&kind=tv&id=880000&season=1&episode=1&value=true',host=opal.loopback_authority,extra_headers=headers);assert r.status==200,r.body
 path='/api/library?filter=all&kind=all&sort=title&offset=0&limit=96'
 r=get(path);obj=r.json();assert len(obj['items'])==96 and obj['total']==200,obj
 since=path+'&since='+quote(obj['version'],safe='')
 data={'full':[],'unchanged':[]};sizes={}
 for i in range(40):
  for mode,url in [('full',path),('unchanged',since)][::1 if i%2==0 else -1]:
   t=time.perf_counter_ns();r=get(url);elapsed=(time.perf_counter_ns()-t)/1e6
   assert r.status==200;rj=r.json()
   if mode=='full':assert len(rj['items'])==96 and rj['total']==200
   else:assert rj['unchanged'] is True and rj['version']==obj['version']
   data[mode].append(elapsed);sizes[mode]=len(r.body)
 print(json.dumps({'fixture':{'tracked_shows':200,'page_rows':96,'repetitions_each':40,'measurement':'HTTP loopback request wall time; warm cache; alternating order'},'results':{m:{'bytes':sizes[m],'median_ms':round(statistics.median(v),3),'p95_ms':round(sorted(v)[37],3)} for m,v in data.items()}},indent=2))
finally:opal.stop()
