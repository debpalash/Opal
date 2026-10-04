#!/usr/bin/env python3
"""Measured Opal workflows with owned metadata/media and isolated profiles.

Cold means a fresh application profile, not an emptied OS filesystem cache.
Playback readiness means decoded media and advancing position, not first frame.
No timing assertion is shared across machines; correctness is always asserted.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import os
from pathlib import Path
import platform
import shutil
import sqlite3
import statistics
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from urllib.parse import urlencode, urlsplit

import test_setup_token_live as live


def summarize(values):
    ordered = sorted(values)
    return {"samples": len(values), "p50_ms": round(statistics.median(values), 3),
            "p95_ms": round(ordered[max(0, math.ceil(len(ordered) * .95) - 1)], 3)}


class Fixture(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_CONNECT(self):
        self.send_response(503)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/v1/audio/":
            body = json.dumps({"result_count": 1, "results": [{
                "id": "fixture-song", "title": "Fixture music", "creator": "Fixture artist",
                "category": "music", "url": self.server.base + "/fixture.mp4",
                "license_url": "https://creativecommons.org/publicdomain/zero/1.0/",
                "attribution": "Generated fixture", "duration": 16000,
            }]}).encode()
        elif path == "/channels.json":
            body = json.dumps({"channels": [{"id": "fixture", "title": "Fixture radio",
                "description": "Fixture music", "playlists": [{"url": self.server.base + "/fixture.mp4",
                    "format": "mp3", "quality": "highest"}]}]}).encode()
        else:
            return super().do_GET()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def resident_kib(pid):
    if platform.system() == "Linux":
        return int(Path(f"/proc/{pid}/statm").read_text().split()[1]) * os.sysconf("SC_PAGE_SIZE") // 1024
    if platform.system() == "Darwin":
        return int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)], text=True).strip())
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--port", type=int, default=41831)
    parser.add_argument("--repetitions", type=int, default=20)
    parser.add_argument("--startup-pairs", type=int, default=5)
    parser.add_argument("--results", required=True, type=Path)
    args = parser.parse_args()
    if args.repetitions < 2 or args.startup_pairs < 1:
        parser.error("at least two repetitions and one startup pair are required")
    live.BINARY = args.binary.resolve()
    live.PORT = args.port
    timings = defaultdict(list)
    memory = defaultdict(list)
    check = unittest.TestCase()
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        parser.error("ffmpeg is required to generate the owned media fixture")
    with tempfile.TemporaryDirectory(prefix="opal-media-benchmark-") as temporary:
        media = Path(temporary)
        shutil.copyfile(live.REPO_ROOT / "src/core/testdata/lossless-cover.webp", media / "cover.webp")
        subprocess.run([ffmpeg, "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24",
                        "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-t", "16",
                        "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac",
                        "-movflags", "+faststart", str(media / "fixture.mp4")], check=True, timeout=30)
        for index in range(args.repetitions):
            try:
                os.link(media / "fixture.mp4", media / f"fixture-{index}.mp4")
            except OSError:
                shutil.copyfile(media / "fixture.mp4", media / f"fixture-{index}.mp4")
        fixture = ThreadingHTTPServer(("127.0.0.1", 0), partial(Fixture, directory=str(media)))
        fixture.base = f"http://127.0.0.1:{fixture.server_port}"
        threading.Thread(target=fixture.serve_forever, daemon=True).start()
        try:
            proxy = {"HTTPS_PROXY": fixture.base, "https_proxy": fixture.base,
                     "NO_PROXY": "localhost,127.0.0.1,::1", "no_proxy": "localhost,127.0.0.1,::1",
                     "ALL_PROXY": "", "all_proxy": ""}
            for session in range(args.startup_pairs):
                opal = live.IsolatedOpal(check)
                try:
                    profile = opal.config_root / "opal"
                    sources = profile / "plugins/sources"
                    sources.mkdir(parents=True)
                    for source in ("openverse", "somafm"):
                        (sources / f"{source}.json").write_text(json.dumps({"base": fixture.base, "_v": "1.0.0"}))
                    with sqlite3.connect(profile / "opal.db") as db:
                        db.execute("CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT NOT NULL DEFAULT '')")
                        db.executemany("INSERT INTO config VALUES(?,?)", [("web_port", str(live.PORT)),
                            ("web_bind", "loopback"), ("web_remote", "1"), ("search_sources", str((1 << 9) | (1 << 10))),
                            ("auto_download_subs", "0"), ("playback_volume", "0"), ("content_cache_enabled", "0")])
                    with patch.dict(os.environ, proxy):
                        started = time.perf_counter()
                        token = opal.start()
                        timings["fresh_profile_health"].append((time.perf_counter() - started) * 1000)
                        account = live.register("benchmark", host=opal.loopback_authority, setup_token=token)
                        check.assertEqual(account.status, 200)
                        headers = (("Cookie", account.session_cookie()),)
                        opal.stop_process()
                        started = time.perf_counter()
                        opal.start(require_setup=False)
                        timings["existing_profile_health"].append((time.perf_counter() - started) * 1000)

                    def request(path, method="GET"):
                        response = live.request(method, path, host=opal.loopback_authority, extra_headers=headers)
                        check.assertEqual(response.status, 200, response.body[:256])
                        return response

                    def wait(path, predicate):
                        deadline = time.monotonic() + 20
                        while time.monotonic() < deadline:
                            value = request(path).json()
                            if predicate(value):
                                return value
                            time.sleep(.005)
                        detail = {key: value.get(key) for key in ("active", "loading", "paused", "pos", "dur", "error")}
                        raise AssertionError("benchmark workflow did not settle: " + path + " " + json.dumps(detail))

                    def rss(label):
                        value = resident_kib(opal.process.pid)
                        if value is not None:
                            memory[label].append(value)

                    rss("ready")
                    if session:
                        continue
                    for index in range(args.repetitions):
                        started = time.perf_counter()
                        request("/api/unified_search?" + urlencode({"q": f"Fixture {index}"}))
                        data = wait("/api/unified_search", lambda value: any(row.get("provider") == "openverse" for row in value["results"]))
                        timings["first_owned_search_result"].append((time.perf_counter() - started) * 1000)
                        check.assertTrue(any(row.get("playable") for row in data["results"]))
                        wait("/api/unified_search", lambda value: not value["loading"])
                    rss("after_search")
                    for index in range(args.repetitions):
                        started = time.perf_counter()
                        request("/api/open?" + urlencode({"url": fixture.base + f"/fixture-{index}.mp4", "title": f"Generated benchmark media {index}",
                            "art": fixture.base + f"/cover.webp?sample={index}"}), "POST")
                        wait("/api/status", lambda value: value.get("active") and not value.get("loading")
                             and value.get("dur", 0) >= 15 and .1 <= value.get("pos", 0) < 3)
                        timings["open_to_advancing_playback"].append((time.perf_counter() - started) * 1000)
                        for label in ("first_cover_proxy_bytes", "repeat_cover_proxy_bytes"):
                            started = time.perf_counter()
                            image = request("/now-playing/art")
                            timings[label].append((time.perf_counter() - started) * 1000)
                            check.assertTrue(image.body.startswith(b"RIFF") and image.body[8:12] == b"WEBP")
                        request("/api/toggle", "POST")
                        wait("/api/status", lambda value: value.get("paused"))
                        # Use a different target each time, preventing an old paused snapshot from satisfying the measurement.
                        percent = 25 if index % 2 else 65
                        target = 16 * percent / 100
                        started = time.perf_counter()
                        request(f"/api/seek_pct?v={percent}", "POST")
                        wait("/api/status", lambda value: value.get("paused") and abs(value.get("pos", -100) - target) < .4)
                        timings["paused_seek_acknowledgment"].append((time.perf_counter() - started) * 1000)
                        # Opal preserves pause when replacing media. Begin the
                        # next open from playing so this measures load readiness.
                        request("/api/toggle", "POST")
                        wait("/api/status", lambda value: not value.get("paused"))
                    rss("after_media")
                finally:
                    opal.stop()
        finally:
            fixture.shutdown()
            fixture.server_close()
    report = {"platform": platform.platform(), "binary": str(live.BINARY),
              "method": {"media": "generated 16s color bars/silent audio; 32x32 synthetic lossless WebP",
                         "network": "loopback fixtures; external HTTPS rejected by owned proxy",
                         "poll_interval_ms": 5, "startup_poll_interval_ms": 100,
                         "cold_start": "fresh profile, OS cache retained",
                         "playback": "duration validated and position advancing; not first visible frame",
                         "artwork": "encoded bytes through actual Opal proxy/cache; native GPU is measured separately"},
              "timings": {key: summarize(values) for key, values in timings.items()},
              "resident_memory_kib": {key: {"samples": len(values), "median": statistics.median(values), "max": max(values)}
                                      for key, values in memory.items()}}
    args.results.parent.mkdir(parents=True, exist_ok=True)
    args.results.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
