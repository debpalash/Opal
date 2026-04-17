#!/usr/bin/env python3
"""
ZigZag Extension Repo Importer
Downloads a Mangayomi-compatible extension repo index and generates
ZigZag plugin directories (search + resolve scripts) from it.

Usage: python3 import_repo.py <repo_url_or_path>
"""
import sys, json, os, stat, urllib.request

PLUGIN_DIR = os.path.expanduser("~/.config/zigzag/plugins")
EXT_DIR = os.path.expanduser("~/.config/zigzag/extensions")

# ── Madara scraper template (GET-based HTML search) ──
MADARA_SEARCH = '''#!/usr/bin/env python3
import sys,json,urllib.request,urllib.parse,re
q=sys.argv[1] if len(sys.argv)>1 else ""
if not q: print("[]"); sys.exit(0)
BASE="{base_url}"
url=f"{{BASE}}/?s={{urllib.parse.quote(q)}}&post_type=wp-manga"
req=urllib.request.Request(url,headers={{"User-Agent":"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36","Referer":BASE}})
try:
 with urllib.request.urlopen(req,timeout=12) as r: html=r.read().decode("utf-8",errors="ignore")
 results=[]
 # Madara themes: <div class="post-title"><h3..><a href="/manga/SLUG/">TITLE</a></h3></div>
 for m in re.finditer(r'post-title[^>]*>\\s*<[^>]+>\\s*<a[^>]+href="[^"]*/manga/([^/"]+)/?[^"]*"[^>]*>([^<]+)</a>',html):
  slug,title=m.groups()
  results.append({{"id":slug,"title":title.strip(),"overview":"","poster":"","episodes":0,"score":0,"year":"","type":"manga"}})
 # Get poster images if available
 posters={{}}
 for m in re.finditer(r'<a[^>]+href="[^"]*/manga/([^/"]+)/?[^"]*"[^>]*>\\s*<img[^>]+src="([^"]+)"',html):
  slug,img=m.groups()
  posters[slug]=img.strip()
 for r in results:
  if r["id"] in posters: r["poster"]=posters[r["id"]]
 print(json.dumps(results[:20]))
except Exception as e: print(json.dumps([{{"id":"err","title":str(e)}}]))
'''

MADARA_RESOLVE = '''#!/usr/bin/env python3
import sys,json,urllib.request,re,os
slug=sys.argv[1] if len(sys.argv)>1 else ""
ch=sys.argv[2] if len(sys.argv)>2 else "1"
if not slug: print(json.dumps({{"error":"no id"}})); sys.exit(1)
BASE="{base_url}"
url=f"{{BASE}}/manga/{{slug}}/chapter-{{ch}}/"
def fetch_with_urllib(url):
 req=urllib.request.Request(url,headers={{"User-Agent":"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36","Referer":BASE}})
 with urllib.request.urlopen(req,timeout=15) as r: return r.read().decode("utf-8",errors="ignore")
def fetch_with_camoufox(url):
 """Fallback: use Camoufox headless to bypass Cloudflare"""
 venv=os.path.expanduser("~/.config/zigzag/venv/bin/python3")
 if not os.path.exists(venv): return None
 import subprocess
 script="import sys;sys.path.insert(0,'.');from camoufox.sync_api import Camoufox;import pathlib;ext=pathlib.Path.home()/'.config/zigzag/extensions/captchasonic';addons=[str(ext)] if ext.is_dir() else [];b=Camoufox(headless=True,addons=addons).__enter__();p=b.new_page();p.goto('"+url+"',wait_until='domcontentloaded',timeout=20000);import time;time.sleep(2);print(p.content());b.__exit__(None,None,None)"
 r=subprocess.run([venv,"-c",script],capture_output=True,text=True,timeout=30)
 return r.stdout if r.returncode==0 else None
def extract_images(html):
 # Collect full-res URLs from both data-src (lazy) and src (eager), skip data: placeholders
 from_data_src=re.findall(r'<img[^>]+class="wp-manga-chapter-img"[^>]+data-src="\\s*(https?://[^"]+)"',html)
 from_src=re.findall(r'<img[^>]+class="wp-manga-chapter-img"[^>]+src="\\s*(https?://[^"]+)"',html)
 imgs=list(dict.fromkeys(from_src+from_data_src))  # merge, deduplicate, preserve order
 if not imgs: imgs=re.findall(r'<img[^>]+data-src="\\s*(https?://[^"]+(?:jpg|png|webp)[^"]*)"',html)
 if not imgs: imgs=re.findall(r'"(https?://[^"]+(?:/uploads/manga/|/wp-content/)[^"]+(?:jpg|png|webp)[^"]*)"',html)
 return [i.strip() for i in imgs if i.strip()]
try:
 html=fetch_with_urllib(url)
 imgs=extract_images(html)
 if not imgs:
  # Try Camoufox fallback for CF-protected sites
  sys.stderr.write("[resolve] urllib blocked, trying Camoufox...\\n")
  html2=fetch_with_camoufox(url)
  if html2: imgs=extract_images(html2)
 if imgs:
  print(json.dumps({{"url":imgs[0],"title":f"{{slug}} Ch {{ch}}","type":"manga","images":imgs}}))
 else:
  print(json.dumps({{"error":"no images found"}}))
except urllib.error.HTTPError as e:
 if e.code in (403,503):
  sys.stderr.write(f"[resolve] HTTP {{e.code}}, trying Camoufox...\\n")
  html2=fetch_with_camoufox(url)
  if html2:
   imgs=extract_images(html2)
   if imgs:
    print(json.dumps({{"url":imgs[0],"title":f"{{slug}} Ch {{ch}}","type":"manga","images":imgs}}))
    sys.exit(0)
  print(json.dumps({{"error":f"HTTP {{e.code}} - Cloudflare blocked"}}))
 else: print(json.dumps({{"error":str(e)}}))
except Exception as e: print(json.dumps({{"error":str(e)}}))
'''

# ── MangaReader scraper template ──
MANGAREADER_SEARCH = '''#!/usr/bin/env python3
import sys,json,urllib.request,urllib.parse,re
q=sys.argv[1] if len(sys.argv)>1 else ""
if not q: print("[]"); sys.exit(0)
BASE="{base_url}"
url=f"{{BASE}}/?s={{urllib.parse.quote(q)}}"
req=urllib.request.Request(url,headers={{"User-Agent":"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"}})
try:
 with urllib.request.urlopen(req,timeout=10) as r: html=r.read().decode("utf-8",errors="ignore")
 results=[]
 for m in re.finditer(r'href="([^"]*?/manga/([^/"]+)[^"]*)"[^>]*>.*?<img[^>]+src="([^"]*)".*?(?:title|alt)="([^"]*)"',html,re.S):
  url_m,slug,poster,title=m.groups()
  results.append({{"id":slug,"title":title.strip(),"overview":"","poster":poster,"episodes":0,"score":0,"year":"","type":"manga"}})
 if not results:
  for m in re.finditer(r'/manga/([^/"]+)[^"]*"[^>]*>[^<]*<[^>]+>([^<]+)',html):
   slug,title=m.groups()
   if len(title)>3 and slug not in ("manga","page"):
    results.append({{"id":slug,"title":title.strip(),"overview":"","poster":"","episodes":0,"score":0}})
 print(json.dumps(results[:20]))
except Exception as e: print(json.dumps([{{"id":"err","title":str(e)}}]))
'''

MANGAREADER_RESOLVE = '''#!/usr/bin/env python3
import sys,json,urllib.request,re
slug=sys.argv[1] if len(sys.argv)>1 else ""
ch=sys.argv[2] if len(sys.argv)>2 else "1"
if not slug: print(json.dumps({{"error":"no id"}})); sys.exit(1)
BASE="{base_url}"
url=f"{{BASE}}/manga/{{slug}}/chapter-{{ch}}/"
req=urllib.request.Request(url,headers={{"User-Agent":"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"}})
try:
 with urllib.request.urlopen(req,timeout=15) as r: html=r.read().decode("utf-8",errors="ignore")
 imgs=re.findall(r'<img[^>]+src="(https?://[^"]+(?:jpg|png|webp)[^"]*)"',html)
 imgs=[i.strip() for i in imgs if "logo" not in i.lower() and "icon" not in i.lower()]
 if imgs:
  print(json.dumps({{"url":imgs[0],"title":f"{{slug}} Ch {{ch}}","type":"manga","images":imgs}}))
 else:
  print(json.dumps({{"error":"no images found"}}))
except Exception as e: print(json.dumps({{"error":str(e)}}))
'''

# ── MangaBox (Manganato/Mangakakalot) ──
MANGABOX_SEARCH = '''#!/usr/bin/env python3
import sys,json,urllib.request,urllib.parse,re
q=sys.argv[1] if len(sys.argv)>1 else ""
if not q: print("[]"); sys.exit(0)
BASE="{base_url}"
sq=re.sub(r"[^a-zA-Z0-9 ]","",q).replace(" ","_").lower()
url=f"{{BASE}}/search/story/{{urllib.parse.quote(sq)}}"
req=urllib.request.Request(url,headers={{"User-Agent":"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36","Referer":BASE}})
try:
 with urllib.request.urlopen(req,timeout=10) as r: html=r.read().decode("utf-8",errors="ignore")
 results=[]
 for m in re.finditer(r'<h3[^>]*>\s*<a[^>]+href="([^"]+)"[^>]*title="([^"]*)"',html,re.S):
  link,title=m.groups()
  slug=link.rstrip("/").split("/")[-1]
  results.append({{"id":slug,"title":title.strip(),"overview":"","poster":"","episodes":0,"score":0}})
 if not results:
  for m in re.finditer(r'href="([^"]+)"[^>]*>\s*<img[^>]+alt="([^"]*)"',html,re.S):
   link,title=m.groups()
   slug=link.rstrip("/").split("/")[-1]
   if title.strip(): results.append({{"id":slug,"title":title.strip(),"overview":"","poster":"","episodes":0,"score":0}})
 print(json.dumps(results[:20]))
except Exception as e: print(json.dumps([{{"id":"err","title":str(e)}}]))
'''

MANGABOX_RESOLVE = MANGAREADER_RESOLVE  # Similar HTML structure

TEMPLATES = {
    "madara": (MADARA_SEARCH, MADARA_RESOLVE),
    "mangareader": (MANGAREADER_SEARCH, MANGAREADER_RESOLVE),
    "mangabox": (MANGABOX_SEARCH, MANGABOX_RESOLVE),
}

def make_plugin(entry):
    name = entry["name"]
    base_url = entry["baseUrl"].rstrip("/")
    type_source = entry.get("typeSource", "")
    lang = entry.get("lang", "en")
    
    if type_source not in TEMPLATES:
        return False
    
    search_tpl, resolve_tpl = TEMPLATES[type_source]
    
    # Create safe directory name
    safe_name = name.lower().replace(" ", "-").replace(".", "").replace("(", "").replace(")", "")
    safe_name = "".join(c for c in safe_name if c.isalnum() or c == "-")[:40]
    plugin_path = os.path.join(PLUGIN_DIR, f"ext-{safe_name}")
    
    os.makedirs(plugin_path, exist_ok=True)
    
    # manifest.json
    manifest = {
        "name": name,
        "version": entry.get("version", "0.1.0"),
        "description": f"{type_source} manga source ({lang})",
        "author": "mangayomi-extensions",
        "type": "manga",
        "lang": lang,
        "baseUrl": base_url,
        "typeSource": type_source,
    }
    with open(os.path.join(plugin_path, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    
    # search script
    search_path = os.path.join(plugin_path, "search")
    with open(search_path, "w") as f:
        f.write(search_tpl.format(base_url=base_url))
    os.chmod(search_path, os.stat(search_path).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    
    # resolve script
    resolve_path = os.path.join(plugin_path, "resolve")
    with open(resolve_path, "w") as f:
        f.write(resolve_tpl.format(base_url=base_url))
    os.chmod(resolve_path, os.stat(resolve_path).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    
    return True

def main():
    # Load repo
    repo_path = os.path.join(EXT_DIR, "anymex-repo.json")
    if len(sys.argv) > 1:
        src = sys.argv[1]
        if src.startswith("http"):
            os.makedirs(EXT_DIR, exist_ok=True)
            print(f"Downloading repo from {src}...")
            urllib.request.urlretrieve(src, repo_path)
        else:
            repo_path = src
    
    if not os.path.exists(repo_path):
        print(f"No repo found at {repo_path}")
        print("Usage: python3 import_repo.py <repo_url>")
        sys.exit(1)
    
    with open(repo_path) as f:
        data = json.load(f)
    
    print(f"Loaded {len(data)} extensions from repo")
    
    # Filter: English, supported typeSource, non-NSFW
    supported = [e for e in data 
                 if e.get("typeSource") in TEMPLATES 
                 and e.get("lang") == "en"
                 and not e.get("isNsfw", False)]
    
    print(f"Supported English sources: {len(supported)}")
    
    created = 0
    for entry in supported:
        if make_plugin(entry):
            print(f"  + {entry['name']} ({entry['typeSource']})")
            created += 1
    
    print(f"\nCreated {created} plugins in {PLUGIN_DIR}")
    print("Restart ZigZag to see new sources in the plugin tab.")

if __name__ == "__main__":
    main()
