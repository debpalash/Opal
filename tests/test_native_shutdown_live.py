#!/usr/bin/env python3
"""Opt-in macOS native idle shutdown regression; fresh HOME/XDG and unused port.

Build native first, then run with --binary zig-out/bin/opal. --launcher can
instead name a prebuilt zig-build-run wrapper, exercising its parent exit too.
No existing Opal listener or user profile is accessed.
"""
import argparse
import http.server
import threading
import urllib.parse
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import time
import unittest

import test_setup_token_live as harness


@unittest.skipUnless(sys.platform == "darwin", "macOS SDL2 idle event-pump regression")
class NativeShutdownLive(unittest.TestCase):
    def test_sigterm_closes_idle_desktop_and_its_launcher(self):
        opal = harness.IsolatedOpal(self)
        self.addCleanup(opal.stop)
        profile = opal.config_root / "opal"
        profile.mkdir(parents=True)
        with sqlite3.connect(profile / "opal.db") as connection:
            connection.execute("CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT)")
            connection.executemany("INSERT INTO config VALUES(?,?)", [
                ("web_port", str(harness.PORT)), ("web_bind", "loopback"),
                ("web_remote", "1"), ("search_sources", "0"),
                ("auto_download_subs", "0"), ("dpi_bypass_enabled", "0"),
            ])
        token = opal.start()
        account = harness.register("native-idle-fixture", host=opal.loopback_authority,
                                   setup_token=token)
        self.assertEqual(account.status, 200)
        status = harness.request("GET", "/api/status", host=opal.loopback_authority,
                                 extra_headers=(("Cookie", account.session_cookie()),))
        self.assertEqual(status.status, 200)
        # Let the initial layout/animation settle into the native event wait.
        time.sleep(4)
        self.assertIsNone(opal.process.poll())
        owned = []
        for line in subprocess.check_output(["ps", "-axo", "pid=,pgid=,comm="], text=True).splitlines():
            fields = line.strip().split(None, 2)
            if len(fields) == 3 and int(fields[1]) == opal.process.pid and fields[2].endswith("/opal"):
                owned.append(int(fields[0]))
        self.assertEqual(len(owned), 1, "exact native PID missing from owned process group")
        os.kill(owned[0], signal.SIGTERM)
        try:
            result = opal.process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.fail("idle desktop did not process SIGTERM within 15 seconds\n" + opal.safe_log())
        self.assertEqual(result, 0, opal.safe_log())
        for failure in ("file_hash FileNotFound", "forcing process exit", "memory address", "widget is not closed within its parent"):
            self.assertNotIn(failure, opal.safe_log())

    def test_stalled_media_open_closes_without_catalog_retry_delay(self):
        entered, release = threading.Event(), threading.Event()

        class Slow(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                entered.set()
                release.wait(15)

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Slow)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.addCleanup(release.set)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        opal = harness.IsolatedOpal(self)
        self.addCleanup(opal.stop)
        profile = opal.config_root / "opal"
        profile.mkdir(parents=True)
        with sqlite3.connect(profile / "opal.db") as db:
            db.execute("CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT)")
            db.executemany("INSERT INTO config VALUES(?,?)", [
                ("web_port", str(harness.PORT)), ("web_bind", "loopback"),
                ("web_remote", "1"), ("dpi_bypass_enabled", "0"),
            ])
        opal.start()
        token = (profile / "api.token").read_text().strip()
        headers = (("Authorization", "Bearer " + token),)
        url = f"http://127.0.0.1:{server.server_port}/stalled.mp4"
        response = harness.request("POST", "/api/open?path=" + urllib.parse.quote(url, safe=""),
                                   host=opal.loopback_authority, extra_headers=headers)
        self.assertEqual(response.status, 200)
        self.assertTrue(entered.wait(10), "media network read never started")
        started = time.monotonic()
        os.kill(opal.process.pid, signal.SIGTERM)
        self.assertEqual(opal.process.wait(timeout=3), 0, opal.safe_log())
        print(f"stalled-media shutdown: {time.monotonic() - started:.3f}s", flush=True)
        self.assertNotIn("forcing process exit", opal.safe_log())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    launch = parser.add_mutually_exclusive_group(required=True)
    launch.add_argument("--binary", type=Path)
    launch.add_argument("--launcher", type=Path)
    parser.add_argument("--port", type=int, default=41749)
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("--port must be between 1 and 65535")
    harness.PORT = args.port
    harness.BINARY = (args.binary or args.launcher).resolve()
    if not harness.BINARY.is_file():
        parser.error("native binary/launcher must exist")
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(NativeShutdownLive))
    raise SystemExit(0 if result.wasSuccessful() else 1)
