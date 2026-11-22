#!/usr/bin/env python3
"""Reliability workload and soak against an isolated headless Opal.

Measures launch, navigation, search cancellation, artwork, stream start, seek,
reader page advance and close (p50/p95), plus CPU, resident memory, worker
threads and subprocesses per phase. A soak then runs hundreds of
navigate/play/close cycles and asserts no orphan playback or subprocess,
including after the application itself exits.

All media, metadata and reader pages come from an owned loopback fixture;
external HTTPS is rejected by an owned proxy. Gating is relative: with
--baseline, a metric fails only when it exceeds the baseline by --threshold
and its unit's noise floor (tests/reliability_budget.py). Never compare
against a baseline recorded on a different machine class.

    zig build -Dheadless=true --prefix /tmp/opal-headless
    python3 tests/bench_reliability_live.py --binary /tmp/opal-headless/bin/opal \\
        --results /tmp/reliability.json --baseline docs/benchmarks/reliability-baseline.json
    python3 tests/bench_reliability_live.py --check /tmp/reliability.json \\
        --baseline docs/benchmarks/reliability-baseline.json
"""
from __future__ import annotations

import argparse
from collections import defaultdict
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import platform
import select
import shutil
import signal
import sqlite3
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, quote, urlencode, urlsplit
import zlib

import reliability_budget as budget
import test_setup_token_live as live

NAV_TABS = ("home", "history", "queue", "downloads", "settings", "plugins", "status")
READER_PAGES = 12


def png(seed):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    row = b"\0" + bytes([seed % 256, 64, 200]) * 8
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 8, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(row * 8)) + chunk(b"IEND", b""))


class Fixture(SimpleHTTPRequestHandler):
    """Owned metadata, media and reader pages. Anything else is "external"."""

    def log_message(self, *_):
        pass

    def _send(self, body, kind):
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _external(self):
        target = self.path if self.command == "CONNECT" else urlsplit(self.path).netloc
        with self.server._lock:
            self.server.external[target.rsplit(":", 1)[0] if self.command == "CONNECT" else target] += 1

    def do_CONNECT(self):
        self._external()
        self.send_response(503)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if not self.path.startswith("/"):  # absolute-URI request through the proxy
            self._external()
            self.send_error(503)
            return
        parts = urlsplit(self.path)
        path, query = parts.path, parse_qs(parts.query)
        base = self.server.base
        if path == "/v1/audio/":
            term = (query.get("q") or [""])[0]
            if term.startswith("stall"):
                return self._stall(term)
            self._send(json.dumps({"result_count": 1, "results": [{
                "id": "fixture-song", "title": "Fixture music", "creator": "Fixture artist",
                "category": "music", "url": base + "/fixture.mp4",
                "license_url": "https://creativecommons.org/publicdomain/zero/1.0/",
                "attribution": "Generated fixture", "duration": 16000}]}).encode(), "application/json")
        elif path == "/issue/fixture":
            self._send(f'<script>comicnumpages={READER_PAGES};comicloc="viewer/fixture";</script>'.encode(), "text/html")
        elif path.startswith("/viewer/fixture/") and path.endswith(".jpg"):
            self._send(png(int(path.rsplit("/", 1)[1][:-4] or 0)), "image/png")
        else:
            super().do_GET()

    def _stall(self, term):
        """Hold a provider request open until the client drops the socket."""
        started, closed = self.server.stall_events(term)
        started.set()
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            readable, _, _ = select.select([self.connection], [], [], 0.02)
            if readable:
                try:
                    if not self.connection.recv(1024):
                        break
                except OSError:
                    break
        closed.set()
        self.close_connection = True


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, directory):
        super().__init__(("127.0.0.1", 0), partial(Fixture, directory=directory))
        self.base = f"http://127.0.0.1:{self.server_port}"
        self.external = defaultdict(int)
        self._events = {}
        self._lock = threading.Lock()

    def stall_events(self, term):
        with self._lock:
            return self._events.setdefault(term, (threading.Event(), threading.Event()))


# ── Process inspection (POSIX; fields are None where unsupported) ──

def process_table():
    if os.name != "posix":
        return {}
    rows = subprocess.check_output(["ps", "-A", "-o", "pid=,ppid=,comm="], text=True)
    table = {}
    for line in rows.splitlines():
        fields = line.split(None, 2)
        if len(fields) >= 2:
            table[int(fields[0])] = (int(fields[1]), fields[2] if len(fields) > 2 else "")
    return table


def descendants(pid, table=None):
    table = process_table() if table is None else table
    found, frontier = {}, [pid]
    while frontier:
        parent = frontier.pop()
        for child, (ppid, comm) in table.items():
            if ppid == parent and child not in found:
                found[child] = comm
                frontier.append(child)
    return found


def cpu_ms(pid):
    if platform.system() == "Linux":
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        return (int(fields[11]) + int(fields[12])) * 1000 / os.sysconf("SC_CLK_TCK")
    if os.name == "posix":
        text = subprocess.check_output(["ps", "-o", "time=", "-p", str(pid)], text=True).strip()
        seconds = 0.0
        for part in text.replace("-", ":").split(":"):
            seconds = seconds * 60 + float(part)
        return seconds * 1000
    return None


def worker_threads(pid):
    if platform.system() == "Linux":
        return len(os.listdir(f"/proc/{pid}/task"))
    if platform.system() == "Darwin":
        return len(subprocess.check_output(["ps", "-M", "-p", str(pid)], text=True).splitlines()) - 1
    return None


def resident_kib(pid):
    if platform.system() == "Linux":
        return int(Path(f"/proc/{pid}/statm").read_text().split()[1]) * os.sysconf("SC_PAGE_SIZE") // 1024
    if os.name == "posix":
        return int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)], text=True).strip())
    return None


def alive(pid, comm):
    entry = process_table().get(pid)
    return entry is not None and entry[1] == comm


class Workload:
    def __init__(self, args, fixture, media):
        self.args, self.fixture, self.media = args, fixture, media
        self.check = unittest.TestCase()
        self.timings = defaultdict(list)
        self.resources = {}
        self.seen_children = {}
        self.cpu_mark = 0.0
        self.opal = None
        self.headers = ()

    # ── HTTP helpers ──
    def request(self, path, method="GET", expect=200):
        response = live.request(method, path, host=self.opal.loopback_authority, extra_headers=self.headers)
        self.check.assertEqual(response.status, expect, f"{method} {path}: {response.body[:256]!r}")
        return response

    def api(self, path, method="GET"):
        return self.request("/api/" + path, method).json()

    def wait(self, path, predicate, timeout=20):
        deadline = time.monotonic() + timeout
        value = None
        while time.monotonic() < deadline:
            value = self.api(path)
            if predicate(value):
                return value
            time.sleep(0.005)
        raise TimeoutError(f"{path} did not settle: {json.dumps(value)[:400]}")

    def timed(self, step, action):
        started = time.perf_counter()
        result = action()
        self.timings[step].append((time.perf_counter() - started) * 1000)
        return result

    # ── Resource snapshots ──
    def snapshot(self, phase):
        pid = self.opal.process.pid
        children = descendants(pid)
        self.seen_children.update(children)
        total = cpu_ms(pid)
        delta = None if total is None else round(total - self.cpu_mark, 1)
        if total is not None:
            self.cpu_mark = total
        self.resources[phase] = {"cpu_ms": delta, "rss_kib": resident_kib(pid),
                                 "workers": worker_threads(pid), "subprocesses": len(children)}

    # ── Phases ──
    def launch(self):
        profile = self.opal.config_root / "opal"
        sources = profile / "plugins/sources"
        sources.mkdir(parents=True)
        for source in ("openverse", "comicbookplus"):
            (sources / f"{source}.json").write_text(json.dumps({"base": self.fixture.base, "_v": "1.0.0"}))
        with live.database(profile / "opal.db") as db:
            db.execute("CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT NOT NULL DEFAULT '')")
            db.executemany("INSERT INTO config VALUES(?,?)", [
                ("web_port", str(live.PORT)), ("web_bind", "loopback"), ("web_remote", "1"),
                ("search_sources", str(1 << 9)), ("auto_download_subs", "0"), ("playback_volume", "0"),
                ("content_cache_enabled", "0"), ("dpi_bypass_enabled", "0")])
        for index in range(self.args.launches):
            if index:
                self.opal.stop_process()
            self.timed("launch", lambda first=index == 0: self.opal.start(require_setup=first))
        self.headers = (("Authorization", "Bearer " + (profile / "api.token").read_text().strip()),)
        self.cpu_mark = 0.0  # "ready" reports CPU used by the final launch itself
        self.snapshot("ready")

    def navigate(self):
        for _ in range(self.args.repetitions):
            for tab in NAV_TABS:
                self.timed("navigate", lambda tab=tab: self.api(tab))
        self.snapshot("after_navigate")

    def search_cancel(self):
        for index in range(self.args.repetitions):
            term = f"stall-{index}"
            started, closed = self.fixture.stall_events(term)
            self.api("unified_search?" + urlencode({"q": term}))
            self.check.assertTrue(started.wait(10), "provider request never reached the fixture")
            generation = self.wait("unified_search", lambda v: v["loading"])["generation"]

            def cancel():
                self.api(f"unified_search/cancel?generation={generation}", "POST")
                self.wait("unified_search", lambda v: not v["loading"], timeout=5)
                self.check.assertTrue(closed.wait(5), "cancel left the provider socket open")
            self.timed("search_cancel", cancel)
        self.snapshot("after_search")

    def stream(self):
        for index in range(self.args.repetitions):
            art = self.fixture.base + f"/cover.webp?sample={index}"
            url = self.fixture.base + f"/fixture-{index % 4}.mp4"

            def start():
                self.api("open?" + urlencode({"url": url, "title": f"Reliability {index}", "art": art}), "POST")
                self.wait("status", lambda v: v.get("active") and not v.get("loading")
                          and v.get("dur", 0) >= 15 and 0.1 <= v.get("pos", 0) < 3)
            self.timed("stream_start", start)
            for step in ("art_first", "art_repeat"):
                image = self.timed(step, lambda: self.request("/now-playing/art"))
                self.check.assertTrue(image.body.startswith(b"RIFF") and image.body[8:12] == b"WEBP")
            self.api("toggle", "POST")
            self.wait("status", lambda v: v.get("paused"))
            percent = 25 if index % 2 else 65
            target = 16 * percent / 100

            def seek():
                self.api(f"seek_pct?v={percent}", "POST")
                self.wait("status", lambda v: v.get("paused") and abs(v.get("pos", -100) - target) < 0.4)
            self.timed("seek", seek)
            self.api("toggle", "POST")
            self.wait("status", lambda v: not v.get("paused"))
            self.timed("close", self.close_player)
        self.snapshot("after_stream")

    def close_player(self):
        self.api("player/action?action=close", "POST")
        self.wait("status", lambda v: not v.get("active"), timeout=10)

    def reader(self):
        loads = max(1, self.args.repetitions // (READER_PAGES - 1))
        for _ in range(max(2, loads)):
            self.api("comics/load?url=" + quote("comicbookplus:/issue/fixture", safe=""))
            self.wait("comics", lambda v: not v["loading"] and v["pages"] == READER_PAGES
                      and v["downloaded"] >= READER_PAGES, timeout=30)
            for page in range(1, READER_PAGES):
                image = self.timed("reader_page_advance", lambda page=page: self.request(f"/api/comics/page?i={page}"))
                self.check.assertTrue(image.body.startswith(b"\x89PNG"))
            self.api("comics/close")
            self.wait("comics", lambda v: v["pages"] == 0 and not v["loading"], timeout=10)
        self.snapshot("after_reader")

    def soak(self):
        pid = self.opal.process.pid
        before = descendants(pid)
        failed = orphan_players = 0
        for cycle in range(self.args.soak_cycles):
            try:
                self.api("home")
                self.api("open?path=" + quote(str(self.media / f"soak-{cycle % 2}.wav"), safe=""), "POST")
                self.wait("status", lambda v: v.get("active") and not v.get("loading") and v.get("pos", 0) > 0)
            except (TimeoutError, AssertionError, OSError):
                failed += 1
            try:
                self.close_player()
            except (TimeoutError, AssertionError, OSError):
                orphan_players += 1
        try:
            leftover = self.wait("status", lambda v: not v.get("active"), timeout=5)
            self.check.assertFalse(leftover.get("active"))
        except (TimeoutError, AssertionError):
            orphan_players += 1
        deadline = time.monotonic() + 5
        while budget.orphans(before, descendants(pid)) and time.monotonic() < deadline:
            time.sleep(0.1)
        lingering = budget.orphans(before, descendants(pid))
        self.snapshot("after_soak")
        return {"cycles": self.args.soak_cycles, "failed_cycles": failed,
                "orphan_players": orphan_players, "lingering_after_close": len(lingering)}

    def shutdown(self):
        """Graceful quit of the app alone (never the process group), then look
        for any subprocess it ever spawned that outlived it."""
        process = self.opal.process
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
            return None
        self.opal.process = None
        time.sleep(0.2)
        return sorted(pid for pid, comm in self.seen_children.items() if alive(pid, comm))


def run(args):
    load_before = [round(v, 2) for v in os.getloadavg()]
    if not shutil.which("ffmpeg"):
        raise SystemExit("ffmpeg is required to generate the owned media fixture")
    with tempfile.TemporaryDirectory(prefix="opal-reliability-") as temporary:
        media = Path(temporary)
        shutil.copyfile(live.REPO_ROOT / "src/core/testdata/lossless-cover.webp", media / "cover.webp")
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24",
                        "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-t", "16",
                        "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac",
                        "-movflags", "+faststart", str(media / "fixture.mp4")], check=True, timeout=30)
        for index in range(4):
            shutil.copyfile(media / "fixture.mp4", media / f"fixture-{index}.mp4")
        for index in range(2):
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=8000:cl=mono",
                            "-t", "30", str(media / f"soak-{index}.wav")], check=True, timeout=30)
        fixture = FixtureServer(str(media))
        threading.Thread(target=fixture.serve_forever, daemon=True).start()
        proxy = {"HTTPS_PROXY": fixture.base, "https_proxy": fixture.base,
                 "HTTP_PROXY": fixture.base, "http_proxy": fixture.base,
                 "NO_PROXY": "localhost,127.0.0.1,::1", "no_proxy": "localhost,127.0.0.1,::1",
                 "ALL_PROXY": "", "all_proxy": ""}
        workload = Workload(args, fixture, media)
        workload.opal = live.IsolatedOpal(workload.check)
        try:
            with patch.dict(os.environ, proxy):
                workload.launch()
            workload.navigate()
            workload.search_cancel()
            workload.stream()
            workload.reader()
            soak = workload.soak()
            survivors = workload.shutdown()
        finally:
            workload.opal.stop()
            fixture.shutdown()
            fixture.server_close()
    soak["orphan_subprocesses"] = soak.pop("lingering_after_close") + (len(survivors) if survivors is not None else 1)
    soak["clean_exit"] = survivors is not None
    return {
        "schema": budget.SCHEMA, "platform": platform.platform(), "binary": str(live.BINARY),
        "ambient_load_average": {"before": load_before, "after": [round(v, 2) for v in os.getloadavg()]},
        "config": {"repetitions": args.repetitions, "launches": args.launches,
                   "soak_cycles": args.soak_cycles, "reader_pages": READER_PAGES, "nav_tabs": list(NAV_TABS)},
        "method": {"network": "loopback fixtures; proxied external requests rejected and counted",
                   "launch": "first launch is a fresh profile, later launches reuse it; 100 ms health polling",
                   "poll_interval_ms": 5,
                   "search_cancel": "cancel POST until loading clears and the stalled provider socket closes",
                   "stream_start": "open until duration known and position advancing; not first visible frame",
                   "reader_page_advance": "next downloaded page bytes through /api/comics/page",
                   "close": "player close action until status reports no active player",
                   "cpu_ms": "process CPU time consumed during the phase",
                   "workers": "OS threads of the Opal process", "subprocesses": "live descendant processes"},
        "latency_ms": {step: budget.summarize(values) for step, values in workload.timings.items()},
        "resources": workload.resources,
        "soak": soak,
        # Background services that tried to leave the loopback fixture. All
        # were refused by the owned proxy; recorded, not gated.
        "rejected_external": dict(sorted(fixture.external.items())),
    }


def gate(report, baseline_path, threshold):
    problems = budget.validate(report)
    regressions = []
    if baseline_path:
        regressions = budget.compare(json.loads(Path(baseline_path).read_text()), report, threshold)
    else:
        regressions = budget.compare({}, report, threshold)
    peak_load = max(max(v) for v in report.get("ambient_load_average", {"_": [0]}).values())
    if peak_load > (os.cpu_count() or 1):
        print(f"WARNING: load average peaked at {peak_load} on {os.cpu_count()} CPUs; "
              "timing regressions may be contention, rerun on a quiet machine", file=sys.stderr)
    for problem in problems:
        print("INVALID:", problem, file=sys.stderr)
    for item in regressions:
        print(f"REGRESSION: {item['metric']}: {item['baseline']} -> {item['current']} ({item['reason']})", file=sys.stderr)
    return 1 if problems or regressions else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--port", type=int, default=41833)
    parser.add_argument("--repetitions", type=int, default=20)
    parser.add_argument("--launches", type=int, default=5)
    parser.add_argument("--soak-cycles", type=int, default=200)
    parser.add_argument("--results", type=Path)
    parser.add_argument("--baseline", type=Path, help="gate against this report (relative budget)")
    parser.add_argument("--threshold", type=float, default=budget.DEFAULT_THRESHOLD,
                        help="allowed relative increase over baseline (default %(default)s)")
    parser.add_argument("--check", type=Path, help="gate an existing report; does not launch Opal")
    args = parser.parse_args(argv)
    if args.threshold < 0:
        parser.error("--threshold must be non-negative")
    if args.check:
        return gate(json.loads(args.check.read_text()), args.baseline, args.threshold)
    if not args.binary or not args.results:
        parser.error("--binary and --results are required unless --check is given")
    if args.repetitions < 2 or args.launches < 2 or args.soak_cycles < budget.MIN_SOAK_CYCLES:
        parser.error(f"need >= 2 repetitions, >= 2 launches and >= {budget.MIN_SOAK_CYCLES} soak cycles")
    if os.name != "posix":
        parser.error("process accounting needs a POSIX host")
    live.BINARY = args.binary.resolve()
    live.PORT = args.port
    report = run(args)
    args.results.parent.mkdir(parents=True, exist_ok=True)
    args.results.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return gate(report, args.baseline, args.threshold)


if __name__ == "__main__":
    sys.exit(main())
