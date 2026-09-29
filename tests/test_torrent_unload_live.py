#!/usr/bin/env python3
"""Exercise transfer removal, paused startup, and worker ownership through the API.

Run after a headless build::

    zig build -Dheadless=true
    python3 tests/test_torrent_unload_live.py --binary zig-out/bin/opal

Each test owns a fresh profile and an independently allocated loopback port.
The dummy infohash has no metadata or downloadable files.
"""

from __future__ import annotations

import argparse
import os
import json
import http.server
import threading
import urllib.parse
import socket
import sqlite3
from pathlib import Path
import sys
import time
import unittest

import test_setup_token_live as setup_live


BINARY: Path | None = None
MAGNET = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=OpalUnloadSmoke"


class TorrentUnloadLiveTest(unittest.TestCase):
    def setUp(self) -> None:
        if BINARY is None:
            self.skipTest("pass --binary or set OPAL_HEADLESS_BIN")
        if not BINARY.is_file():
            self.fail(f"headless binary does not exist: {BINARY}")
        setup_live.BINARY = BINARY
        self.opal = setup_live.IsolatedOpal(self)
        self.addCleanup(self.opal.stop)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            setup_live.PORT = sock.getsockname()[1]
        profile = self.opal.config_root / "opal"
        profile.mkdir(parents=True)
        with sqlite3.connect(profile / "opal.db") as conn:
            conn.execute("CREATE TABLE config(key TEXT PRIMARY KEY, value TEXT)")
            conn.executemany("INSERT INTO config VALUES (?, ?)",
                             [("web_port", str(setup_live.PORT)), ("web_bind", "loopback"),
                              ("save_path", str(self.opal.root / "downloads"))])


    def wait_for(self, predicate, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(0.05)
        self.fail("timed out waiting for transfer state")

    def test_restart_restores_torrents_paused_and_removal_stays_removed(self):
        profile = self.opal.config_root / "opal"
        with sqlite3.connect(profile / "opal.db") as conn:
            conn.execute("CREATE TABLE active_torrent_intents(identity TEXT PRIMARY KEY, paused INTEGER, added_at INTEGER DEFAULT 0)")
            conn.execute("INSERT INTO active_torrent_intents(identity,paused) VALUES(?,0)", (MAGNET.split("&dn=")[0],))
        self.opal.start()
        token = (profile / "api.token").read_text().strip()
        torrents = self.wait_for(lambda: self.api("GET", "/api/torrents", token).json()["torrents"])
        self.assertTrue(torrents[0]["paused"], torrents)
        self.assertEqual(torrents[0]["rate"], 0)
        resumed = self.api("POST", f"/api/torrents/action?action=resume&id={torrents[0]['id']}", token)
        self.assertEqual(resumed.status, 200)
        self.assertFalse(self.api("GET", "/api/torrents", token).json()["torrents"][0]["paused"])
        self.opal.stop_process()
        self.opal.start()
        torrents = self.wait_for(lambda: self.api("GET", "/api/torrents", token).json()["torrents"])
        self.assertTrue(torrents[0]["paused"], torrents)
        removed = self.api("POST", f"/api/torrents/action?action=cancel&id={torrents[0]['id']}&confirm=1", token)
        self.assertEqual(removed.status, 200)
        self.opal.stop_process()
        with sqlite3.connect(profile / "opal.db") as conn:
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM active_torrent_intents").fetchone()[0], 0)

    def test_file_removal_preserves_bytes_and_survives_restart(self):
        dest = self.opal.root / "downloads"
        dest.mkdir()
        (dest / "keep.mp4").write_bytes(b"original bytes")
        (dest / "other.mp4").write_bytes(b"other bytes")
        (dest / "cache.fastresume").write_bytes(b"internal")
        self.opal.start()
        token = (self.opal.config_root / "opal" / "api.token").read_text().strip()
        def names():
            return [f["name"] for f in self.api("GET", "/api/downloads", token).json()["files"]]
        self.assertIn("keep.mp4", names())
        self.assertNotIn("cache.fastresume", names())
        removed = self.api("POST", "/api/downloads/file-action?action=remove&file=keep.mp4", token)
        self.assertEqual(removed.status, 200, removed.body)
        self.assertNotIn("keep.mp4", names())
        self.assertIn("other.mp4", names())
        self.assertEqual((dest / "keep.mp4").read_bytes(), b"original bytes")
        self.opal.stop_process()
        self.opal.start()
        self.assertNotIn("keep.mp4", names())
        self.assertIn("other.mp4", names())

    def test_http_restore_waits_for_resume_and_completed_remove_clears_files(self):
        requests = []
        payload = b"stream-test" * 1024
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                requests.append(self.path)
                begin, end = 0, len(payload) - 1
                header = self.headers.get("Range")
                if header:
                    lo, hi = header.removeprefix("bytes=").split("-", 1)
                    begin, end = int(lo), int(hi) if hi else end
                self.send_response(206 if header else 200)
                if header:
                    self.send_header("Content-Range", f"bytes {begin}-{end}/{len(payload)}")
                self.send_header("Content-Length", str(end - begin + 1))
                self.send_header("ETag", '"test"')
                self.end_headers()
                self.wfile.write(payload[begin:end+1])
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        dest = self.opal.root / "downloads"
        dest.mkdir()
        (dest / "test.mp4.opal-part").write_bytes(payload[:128])
        (dest / "test.mp4.opal-part.json").write_text(json.dumps({
            "v": 1, "url": f"http://127.0.0.1:{server.server_port}/test.mp4",
            "etag": '\"test\"', "total": len(payload), "segments": 1, "paused": 0, "done": [128]}, separators=(",", ":")))
        self.opal.start()
        token = (self.opal.config_root / "opal" / "api.token").read_text().strip()
        def jobs(): return self.api("GET", "/api/downloads", token).json()["jobs"]
        job = self.wait_for(jobs)[0]
        self.assertEqual(job["status"], "paused", job)
        self.assertEqual(requests, [])
        resumed = self.api("POST", f"/api/downloads/action?action=resume&idx={job['idx']}&token={job['token']}", token)
        self.assertEqual(resumed.status, 200, resumed.body)
        job = self.wait_for(lambda: next((j for j in jobs() if j["status"] == "done"), None))
        self.assertEqual((dest / "test.mp4").read_bytes(), payload)
        removed = self.api("POST", f"/api/downloads/action?action=dismiss&idx={job['idx']}&token={job['token']}&confirm=1", token)
        self.assertEqual(removed.status, 200, removed.body)
        self.assertEqual(jobs(), [])
        self.assertNotIn("test.mp4", [f["name"] for f in self.api("GET", "/api/downloads", token).json()["files"]])
        self.assertEqual(self.api("GET", "/api/downloads/history", token).json()["items"], [])
        self.assertEqual((dest / "test.mp4").read_bytes(), payload)

    def test_pause_remove_does_not_reuse_a_live_worker_slot(self):
        entered, release = threading.Event(), threading.Event()
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                entered.set()
                release.wait(8)
                self.send_response(503)
                self.send_header("Content-Length", "0")
                self.end_headers()
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.addCleanup(release.set)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        (self.opal.root / "downloads").mkdir()
        self.opal.start()
        token = (self.opal.config_root / "opal" / "api.token").read_text().strip()
        def jobs(): return self.api("GET", "/api/downloads", token).json()["jobs"]
        def start(name):
            url = urllib.parse.quote(f"http://127.0.0.1:{server.server_port}/{name}", safe="")
            self.assertTrue(self.api("POST", "/api/download/url?url=" + url, token).json()["ok"])
        def action(job, name):
            response = self.api("POST", f"/api/downloads/action?action={name}&idx={job['idx']}&token={job['token']}&confirm=1", token)
            self.assertEqual(response.status, 200, response.body)
        start("old.mp4")
        self.assertTrue(entered.wait(5))
        old = jobs()[0]
        action(old, "pause")
        old = jobs()[0]
        action(old, "dismiss")
        self.assertEqual(jobs(), [])
        start("new.mp4")
        new = jobs()[0]
        self.assertNotEqual(new["idx"], old["idx"], "old coordinator still owns its slot")
        release.set()
        failed = self.wait_for(lambda: next((j for j in jobs() if j["status"] == "failed"), None))
        self.assertEqual(failed["name"], "new.mp4")
        action(failed, "dismiss")
        self.assertEqual(jobs(), [])
        self.assertFalse(list((self.opal.root / "downloads").glob("*.opal-part*")))

    def api(self, method: str, path: str, cookie: str, *, form: dict[str, str] | None = None) -> setup_live.Response:
        return setup_live.request(
            method,
            path,
            host=self.opal.loopback_authority,
            extra_headers=(("Authorization", "Bearer " + cookie),),
            form=form,
        )

    def test_cancel_unloads_active_torrent_before_removing_session(self) -> None:
        self.opal.start()
        cookie = (self.opal.config_root / "opal" / "api.token").read_text().strip()

        loaded = self.api("POST", "/api/load", cookie, form={"url": MAGNET})
        self.assertEqual(loaded.status, 200, loaded.body)
        self.assertEqual(loaded.json()["ok"], True)

        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            snapshot = self.api("GET", "/api/torrents", cookie)
            self.assertEqual(snapshot.status, 200, snapshot.body)
            torrents = snapshot.json()["torrents"]
            if torrents:
                break
            time.sleep(0.1)
        else:
            self.fail(f"magnet did not create a torrent transfer: {self.opal.safe_log()}")
        self.assertEqual(len(torrents), 1)
        playing = self.api("GET", "/api/status", cookie)
        self.assertEqual(playing.status, 200, playing.body)
        self.assertTrue(playing.json()["active"], playing.body)
        self.assertEqual(playing.json()["source"], "torrent")

        removed = self.api("POST", f"/api/torrents/action?action=cancel&id={torrents[0]['id']}&confirm=1", cookie)
        self.assertEqual(removed.status, 200, removed.body)
        self.assertEqual(removed.json(), {"ok": True})
        after = self.api("GET", "/api/status", cookie)
        self.assertEqual(after.status, 200, after.body)
        self.assertFalse(after.json()["active"], after.body)
        self.assertFalse(after.json()["loading"], after.body)
        self.assertNotEqual(after.json()["source"], "torrent")
        snapshot = self.api("GET", "/api/torrents", cookie)
        self.assertEqual(snapshot.status, 200, snapshot.body)
        self.assertEqual(snapshot.json()["torrents"], [])
        history = self.api("GET", "/api/downloads/history", cookie)
        self.assertEqual(history.json()["items"], [], history.body)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=os.environ.get("OPAL_HEADLESS_BIN"))
    options, unittest_args = parser.parse_known_args()
    if options.binary:
        BINARY = Path(options.binary).expanduser().resolve()
    unittest.main(argv=[sys.argv[0], *unittest_args], verbosity=2)
