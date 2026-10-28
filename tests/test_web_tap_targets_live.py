#!/usr/bin/env python3
"""Phone tap targets on the live Web UI, measured in a real Chromium.

The CSS check in tests/features/test_theming.py only proves the rules exist.
This renders the real web/ bundle at phone width with stubbed /api JSON (search
cards + detail, Jellyfin, Plex, a show's season chips) and fails on any
visible control smaller than 40px, or on horizontal page scroll.
"""

from __future__ import annotations

import argparse
import html
import json
import os
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import threading
import unittest
from urllib.parse import urlsplit

REPO_ROOT = Path(__file__).resolve().parents[1]
WEB = REPO_ROOT / "web"
CHROMIUM: str | None = None
MIN_TAP = 40

# 1x1 PNG: posters resolve locally so no test touches the network.
PNG = bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
    "0000000d49444154789c63f8cf50000002000101e221bc330000000049454e44ae426082"
)
POSTER = "/__stub.png"

RESULTS = [
    {"source": "tmdb", "media": "tv", "id": 1399, "title": "The Long Night Signal", "year": 2021, "rating": 8.4,
     "poster_url": POSTER, "backdrop_url": POSTER, "summary": "A remote station picks up a broadcast nobody sent.",
     "key": "a1", "provider": "tmdb", "work_key": "abc1", "work_representative": True, "detail": "TV details"},
    {"source": "tmdb", "media": "movie", "id": 550, "title": "Paper Lanterns Over the Harbour of Very Long Titles",
     "year": 2019, "rating": 7.1, "poster_url": POSTER, "key": "a2", "provider": "tmdb"},
    {"source": "jellyfin", "title": "The Long Night Signal", "year": 2021, "poster_url": POSTER, "key": "a3",
     "provider": "Jellyfin", "work_key": "abc1", "queueable": True, "detail": "S01E01 · 1080p"},
    {"source": "youtube", "title": "Behind the scenes: building the signal station set", "poster_url": POSTER,
     "key": "a4", "provider": "YouTube", "queueable": True, "author": "Studio Channel"},
    {"source": "music", "title": "Night Signal (Original Score)", "author": "Composer Name", "poster_url": POSTER,
     "key": "a6", "provider": "music", "queueable": True},
    {"source": "torrent", "title": "The.Long.Night.Signal.S01.1080p.WEB-DL.x264-GROUP", "key": "a9", "provider": "yts",
     "torrent": True, "quality": 3, "seeds": 812, "leech": 33, "size_bytes": 9.4e9, "queueable": True},
    {"source": "torrent", "title": "The.Long.Night.Signal.S01E01.2160p.HDR.WEB.H265-ANOTHERGROUP", "key": "a10",
     "provider": "1337x", "torrent": True, "quality": 4, "seeds": 210, "leech": 12, "size_bytes": 4.2e9,
     "queueable": True},
]
SEARCH = {
    "generation": 7, "loading": False, "returned": len(RESULTS), "total": len(RESULTS), "results": RESULTS,
    "sources": [{"source": s, "enabled": True, "status": "timed_out" if s == "plex" else "done"}
                for s in ("tmdb", "torrent", "jellyfin", "youtube", "music", "plex")],
}
JELLYFIN = {
    "connected": True, "loading": False, "server": "http://jf.local:8096",
    "libraries": [{"id": "l1", "name": "Movies"}, {"id": "l2", "name": "TV Shows"}, {"id": "l3", "name": "Music"}],
    "items": [
        {"id": "f1", "name": "Shows", "type": "CollectionFolder", "folder": True, "image": True},
        {"id": "e1", "name": "The Long Night Signal", "type": "Series", "year": 2021, "folder": False, "image": True,
         "favorite": True, "played": False, "runtime": 3000, "progress": 900},
        {"id": "e2", "name": "Paper Lanterns Over the Harbour", "type": "Movie", "year": 2019, "folder": False,
         "image": False, "favorite": False, "played": True, "runtime": 6200},
    ],
}
PLEX = {
    "connected": True, "loading": False, "state": "connected", "server": "Home Plex", "status": "Home Plex",
    "depth": 1, "active_section": 0, "sections": [{"key": "1", "title": "Movies"}, {"key": "2", "title": "TV Shows"}],
    "items": [
        {"id": "101", "title": "Paper Lanterns Over the Harbour of Very Long Titles", "year": 2019, "type": "movie",
         "duration": 6200, "progress": 1800, "played": False, "favorite": True, "rating": 7.5},
        {"id": "102", "title": "The Long Night Signal", "year": 2021, "type": "show", "folder": True},
    ],
}
TV = {
    "name": "The Long Night Signal", "first_air_date": "2021-04-01", "vote_average": 8.4,
    "genres": [{"name": "Drama"}], "overview": "A remote station picks up a broadcast nobody sent.",
    "seasons": [{"season_number": i + 1, "episode_count": 10} for i in range(12)],
}
SEASON = {"episodes": [{"episode_number": i + 1, "name": f"Episode {i + 1}: A fairly long episode title here",
                        "overview": "Things happen at the station.", "air_date": f"2021-04-0{i + 1}"}
                       for i in range(4)]}


def stub(path: str, query: str) -> object:
    if path == "/auth/status":
        return {"authed": True}
    if path.startswith("/unified_search/preview"):
        return {"status": "none", "generation": 7}
    if path.startswith("/unified_search"):
        return SEARCH
    if path == "/jellyfin":
        return JELLYFIN
    if path == "/plex":
        return PLEX
    if path.startswith("/tv/recent"):
        return {"found": True, "season": 1, "episode": 4, "label": "S01E04 · Episode 4", "watched": False}
    if path == "/tv":
        return SEASON if "season=" in query else TV
    if path.startswith("/library/watched"):
        return {"episodes": [1], "tracked": True}
    return {}


# Drives the real page through each surface and writes the measurements into
# <pre id="tap-result"> for --dump-dom. Mirrors the Playwright probe used when
# the phone tap targets were raised (#126).
DRIVER = r"""
(() => {
const sleep = ms => new Promise(r => setTimeout(r, ms));
const measure = () => {
  const W = innerWidth, small = [];
  let checked = 0;
  const vis = el => { const s = getComputedStyle(el), r = el.getBoundingClientRect();
    return s.visibility !== 'hidden' && s.display !== 'none' && r.width > 0 && r.height > 0 && !el.closest('[hidden],[inert]'); };
  const scroller = el => { for (let a = el.parentElement; a; a = a.parentElement) {
    const ox = getComputedStyle(a).overflowX; if (['auto','scroll','hidden','clip'].includes(ox)) return a; } return null; };
  const desc = el => el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') +
    (typeof el.className === 'string' && el.className.trim() ? '.' + el.className.trim().split(/\s+/).slice(0, 2).join('.') : '') +
    ' "' + (el.textContent || el.value || el.getAttribute('aria-label') || '').trim().slice(0, 24) + '"';
  for (const el of document.querySelectorAll('body *')) {
    if (!vis(el) || el.closest('#pair-screen,#tap-result')) continue;
    if (!el.matches('button,a[href],select,input:not([type=hidden]),[role=button],summary,label.switch')) continue;
    const r = el.getBoundingClientRect(), sc = scroller(el);
    if (sc && sc !== document.body && sc !== document.documentElement) {
      const b = sc.getBoundingClientRect(); if (r.right < b.left || r.left > b.right) continue;  // scrolled out of view
    }
    if (el.tagName === 'A' && getComputedStyle(el).display === 'inline') continue;  // prose links
    checked++;
    if (r.height < MIN_TAP || r.width < MIN_TAP) small.push(desc(el) + ` ${Math.round(r.width)}x${Math.round(r.height)}`);
  }
  return { checked, overflow: document.documentElement.scrollWidth - W, small };
};
const report = {}, errors = [];
window.addEventListener('error', e => errors.push(String(e.message)));
// `proof` selects an element only the stubbed data can render; it must be laid
// out, so an empty surface fails instead of passing with nothing to measure.
const step = async (name, proof, fn) => {
  try { await fn(); } catch (e) { errors.push(name + ': ' + e.message); }
  report[name] = { ...measure(), rendered: [...document.querySelectorAll(proof)].some(el => el.getClientRects().length > 0) };
};
(async () => {
  await sleep(500);
  await step('search', '#results .search-card-title', async () => { openPage('search'); $('q').value = 'The Long Night Signal'; await runSearch(); await sleep(800);
    const shelf = document.querySelector('.search-release-shelf'); if (shelf) shelf.open = true; });
  await step('search-detail', '#search-detail #search-detail-close', async () => { const t = document.querySelector('.search-card-title'); if (t) t.click(); await sleep(800); });
  await step('jellyfin', '#jf-items .card', async () => { openPage('jf'); await sleep(1500); });
  await step('plex', '#page-plex .result', async () => { openPage('plex'); await sleep(2500); });
  await step('show', '#season-chips button', async () => { openPage('home'); await openDetails('tv', 1399, 'The Long Night Signal', ''); await sleep(1500); });
  await step('horizon-home', '#moment-title', async () => { openPage('home'); document.querySelectorAll('#page-home details').forEach(d => d.open = true); await sleep(200); });
  await step('horizon-setup', '#addon-key', async () => { openPage('setup'); document.querySelectorAll('#page-setup details').forEach(d => d.open = true); await sleep(200); });
  const out = document.createElement('pre'); out.id = 'tap-result'; out.hidden = true;
  out.textContent = JSON.stringify({ width: innerWidth, report, errors });
  document.body.appendChild(out);
})();
})();
""".replace("MIN_TAP", str(MIN_TAP))


class _Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(WEB), **kwargs)

    def log_message(self, format: str, *args: object) -> None:
        pass

    def _send(self, body: bytes, ctype: str) -> None:
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        url = urlsplit(self.path)
        if url.path in ("/", "/index.html"):
            page = (WEB / "index.html").read_text(encoding="utf-8")
            page = page.replace("</body>", "<script src=\"/__driver.js\"></script></body>", 1)
            return self._send(page.encode(), "text/html; charset=utf-8")
        if url.path == "/__driver.js":
            return self._send(DRIVER.encode(), "text/javascript")
        if url.path == POSTER or url.path.startswith("/api/jellyfin/poster"):
            return self._send(PNG, "image/png")
        if url.path == "/service-worker.js":
            self.send_error(404)
            return
        if url.path.startswith("/api/"):
            return self._send(json.dumps(stub(url.path[4:], url.query)).encode(), "application/json")
        return super().do_GET()

    def do_POST(self) -> None:  # noqa: N802
        self._send(b"{}", "application/json")


def render(width: int) -> dict:
    server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    with tempfile.TemporaryDirectory(prefix="opal-tap-live-") as profile:
        proc = subprocess.Popen(
            [CHROMIUM, "--headless=new", "--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage",
             "--disable-background-networking", "--disable-component-update", "--disable-extensions",
             "--disable-sync", "--no-first-run", "--hide-scrollbars", f"--user-data-dir={profile}",
             f"--window-size={width},844", "--virtual-time-budget=20000", "--dump-dom",
             f"http://127.0.0.1:{server.server_port}/#home"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
        )
        try:
            stdout, stderr = proc.communicate(timeout=60)
        except subprocess.TimeoutExpired:
            # Same reaping as test_web_dom_live: a stray zygote can outlive --dump-dom.
            proc.kill() if os.name == "nt" else os.killpg(proc.pid, signal.SIGKILL)
            stdout, stderr = proc.communicate()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
    marker = '<pre id="tap-result" hidden="">'
    if marker not in stdout:
        raise AssertionError(f"driver produced no result (exit {proc.returncode}):\n{stderr[-2000:]}")
    return json.loads(html.unescape(stdout.split(marker, 1)[1].split("</pre>", 1)[0]))


class WebTapTargetsLiveTest(unittest.TestCase):
    maxDiff = None

    def test_phone_controls_are_tap_sized_and_page_never_scrolls_sideways(self) -> None:
        if CHROMIUM is None:
            self.skipTest("Chromium is not installed; browser tier dependency is explicit")
        for width in (375, 390):
            with self.subTest(width=width):
                result = render(width)
                self.assertEqual(result["width"], width, "viewport did not take the phone width")
                self.assertEqual(result["errors"], [], "page script errors while driving the UI")
                self.assertEqual(set(result["report"]), {"search", "search-detail", "jellyfin", "plex", "show", "horizon-home", "horizon-setup"})
                problems = []
                for surface, m in result["report"].items():
                    if not m["rendered"]:
                        problems.append(f"{surface}: stubbed content never rendered")
                    if m["overflow"] > 0:
                        problems.append(f"{surface}: page scrolls sideways by {m['overflow']}px")
                    problems += [f"{surface}: {s}" for s in m["small"]]
                self.assertEqual(problems, [], f"controls under {MIN_TAP}px or sideways scroll at {width}px")


def main() -> int:
    global CHROMIUM
    parser = argparse.ArgumentParser()
    parser.add_argument("--chromium")
    args, rest = parser.parse_known_args()
    CHROMIUM = args.chromium or next(
        (path for name in ("chrome-headless-shell", "chromium", "chromium-browser", "google-chrome")
         if (path := shutil.which(name))), None)
    return 0 if unittest.main(argv=[__file__, *rest], exit=False).result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
