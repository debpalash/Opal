#!/usr/bin/env python3
"""Isolated socket regression for static-body lifetime and HTTP validators.

Run after a headless build:
    python3 tests/test_static_assets_live.py --binary zig-out/bin/opal

A fresh XDG config listens on 41699. No existing session is paired or modified.
Packaged mode stages copied public assets and an executable-relative resource
root; the launcher changes directory before exec so the real startup probe runs.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from html.parser import HTMLParser
import os
from pathlib import Path
import re
import shlex
import shutil
import sqlite3
import sys
import unittest
from urllib.parse import urlsplit

import test_setup_token_live as harness

PORT = 41699
BINARY: Path | None = None
REPO_ROOT = Path(__file__).resolve().parents[1]


class ShellAssets(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.paths: set[str] = set()

    def handle_starttag(self, tag: str, attributes: list[tuple[str, str | None]]) -> None:
        attrs = dict(attributes)
        value = attrs.get("src") if tag == "script" else attrs.get("href") if tag == "link" else None
        if not value:
            return
        address = urlsplit(value)
        if not address.scheme and not address.netloc:
            self.paths.add("/" + address.path.lstrip("/"))


def asset_table() -> list[tuple[str, str, str, str, str]]:
    """Use the server's explicit allowlist, then independently compare its wire bytes."""
    source = (REPO_ROOT / "src/services/remote_static.zig").read_text(encoding="utf-8")
    pattern = re.compile(
        r'\.route = "([^"]+)", \.bundled = "([^"]+)", \.dev = "([^"]+)", '
        r'\.content_type = "([^"]+)", \.cache = \.(\w+)'
    )
    entries = pattern.findall(source)
    if not entries:
        raise AssertionError("static allowlist was not found")
    return entries


class StaticAssetsLiveTest(unittest.TestCase):
    def setUp(self) -> None:
        if BINARY is None:
            self.skipTest("pass --binary or set OPAL_HEADLESS_BIN")
        if not BINARY.is_file():
            self.fail(f"headless binary does not exist: {BINARY}")
        harness.PORT = PORT
        self.opal = harness.IsolatedOpal(self)
        self.addCleanup(self.opal.stop)
        config = self.opal.config_root / "opal"
        config.mkdir(parents=True)
        with sqlite3.connect(config / "opal.db") as connection:
            connection.execute("CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT NOT NULL DEFAULT '')")
            connection.executemany("INSERT INTO config VALUES(?,?)", [
                ("web_port", str(PORT)), ("web_bind", "loopback"),
                ("search_sources", "0"), ("auto_download_subs", "0"),
            ])
        self.assets = asset_table()
        self.expected = {route: (REPO_ROOT / dev).read_bytes() for route, _, dev, _, _ in self.assets}
        self.original_binary = harness.BINARY
        self.addCleanup(setattr, harness, "BINARY", self.original_binary)

    def start(self, *, packaged: bool = False) -> None:
        assert BINARY is not None
        executable = BINARY
        if packaged:
            if os.name != "posix":
                self.skipTest("packaged resource probe fixture uses a POSIX exec launcher")
            package = self.opal.root / "package"
            self.package_root = package
            (package / "bin").mkdir(parents=True)
            (package / "engines").mkdir()
            # This marker is consulted by detectResourceRoot; no source plugin is run.
            (package / "engines/nova2.py").write_text("# isolated static-resource marker\n")
            executable = package / "bin/opal"
            shutil.copy2(BINARY, executable)
            for route, bundled, _, _, _ in self.assets:
                target = package / "web" / bundled
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(self.expected[route])
            # Keep executable-relative wrapper lookup working for packaged builds.
            wrapper = REPO_ROOT / "libtorrent_wrapper.so"
            if wrapper.is_file():
                frameworks = package / "Frameworks"
                frameworks.mkdir()
                shutil.copy2(wrapper, frameworks / wrapper.name)
            empty_cwd = self.opal.root / "empty-working-directory"
            empty_cwd.mkdir()
            # macOS can retain a bare dylib install name instead of @rpath.
            # Supply that copied dependency in the isolated CWD as well.
            if wrapper.is_file():
                shutil.copy2(wrapper, empty_cwd / wrapper.name)
            launcher = self.opal.root / "launch-packaged.sh"
            launcher.write_text(
                "#!/bin/sh\nset -eu\ncd " + shlex.quote(str(empty_cwd))
                + "\nexec " + shlex.quote(str(executable)) + "\n",
                encoding="utf-8",
            )
            launcher.chmod(0o700)
            executable = launcher
        harness.BINARY = executable
        self.opal.start(require_setup=False)
        self.assert_alive()

    def get(self, route: str, **kwargs: object) -> harness.Response:
        return harness.request("GET", route, host=self.opal.loopback_authority, **kwargs)

    def assert_alive(self) -> None:
        assert self.opal.process is not None
        self.assertIsNone(self.opal.process.poll(), "Opal exited while serving public assets")
        self.assertEqual(self.get("/health").status, 200)

    def assert_asset(self, route: str, mime: str, policy: str, *, packaged: bool) -> harness.Response:
        response = self.get(route)  # Deliberately no cookie, API token or setup token.
        self.assertEqual(response.status, 200, route)
        self.assertEqual(response.body, self.expected[route], f"corrupt or freed asset body: {route}")
        self.assertEqual(response.header_values("content-type"), [mime], route)
        self.assertEqual(response.header_values("content-length"), [str(len(response.body))], route)
        self.assertEqual(response.header_values("x-content-type-options"), ["nosniff"], route)
        cache = response.header_values("cache-control")
        self.assertEqual(len(cache), 1, f"missing or merged Cache-Control header: {route}")
        self.assertIn({"no_store": "no-store", "revalidate": "must-revalidate", "immutable": "immutable"}[policy], cache[0])
        if packaged:
            etags = response.header_values("etag")
            self.assertEqual(len(etags), 1, route)
            self.assertRegex(etags[0], r'^"[0-9a-f]{16}"$', f"ETag contains an adjacent header: {route}")
        else:
            self.assertEqual(response.header_values("etag"), [], "development responses must not reuse packaged cached bytes")
        if route in ("/", "/index.html"):
            self.assertEqual(response.header_values("referrer-policy"), ["no-referrer"])
            self.assertEqual(len(response.header_values("content-security-policy")), 1)
        self.assert_alive()
        return response

    def test_development_shell_and_every_allowlisted_asset_are_exact_and_alive(self) -> None:
        self.start()
        for route, _, _, mime, policy in self.assets:
            with self.subTest(route=route):
                self.assert_asset(route, mime, policy, packaged=False)
        shell = ShellAssets()
        shell.feed(self.get("/").body.decode("utf-8"))
        self.assertIn("/js/access.js", shell.paths)
        self.assertIn("/js/source-details.js", shell.paths)
        allowed = {entry[0] for entry in self.assets}
        self.assertTrue(shell.paths <= allowed, f"shell references unavailable assets: {shell.paths - allowed}")
        for path in sorted(shell.paths):
            self.assertEqual(self.get(path).body, self.expected[path], path)
        # A dev request must still send the current body rather than a false 304.
        response = self.get("/js/access.js", extra_headers=(("If-None-Match", "*"),))
        self.assertEqual(response.status, 200)
        self.assertEqual(response.body, self.expected["/js/access.js"])
        self.assert_alive()

    def test_parallel_development_asset_reads_do_not_free_inflight_bodies(self) -> None:
        self.start()
        routes = [entry[0] for entry in self.assets] * 2
        with ThreadPoolExecutor(max_workers=4) as workers:
            responses = list(workers.map(self.get, routes))
        for route, response in zip(routes, responses):
            self.assertEqual(response.status, 200, route)
            self.assertEqual(response.body, self.expected[route], route)
        self.assert_alive()

    def test_packaged_resource_assets_have_separate_headers_and_working_etags(self) -> None:
        self.start(packaged=True)
        for route, _, _, mime, policy in self.assets:
            with self.subTest(route=route):
                original = self.assert_asset(route, mime, policy, packaged=True)
                etag = original.header_values("etag")[0]
                if route == "/js/access.js":
                    # A packaged process retains immutable asset bytes. Mutate
                    # only the copied fixture file, never repository assets.
                    cached_path = self.package_root / "web/js/access.js"
                    cached_path.write_bytes(original.body + b"\n/* isolated fixture replacement */\n")
                for match in (etag, "W/" + etag, '"unrelated", ' + etag, '"unrelated,opaque-tag", ' + etag, "*"):
                    cached = self.get(route, extra_headers=(("If-None-Match", match),))
                    self.assertEqual(cached.status, 304, (route, match))
                    self.assertEqual(cached.body, b"", route)
                    self.assertEqual(cached.header_values("etag"), [etag], route)
                    self.assertEqual(len(cached.header_values("cache-control")), 1, route)
                for different in ('"different"', '"prefix*not-this-tag"', '"unrelated,opaque-tag"', '"different", *'):
                    changed = self.get(route, extra_headers=(("If-None-Match", different),))
                    self.assertEqual(changed.status, 200, (route, different))
                    self.assertEqual(changed.body, original.body, route)
        self.assert_alive()


def parse_args() -> tuple[argparse.Namespace, list[str]]:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=os.environ.get("OPAL_HEADLESS_BIN"))
    parser.add_argument("--port", type=int, default=41699)
    return parser.parse_known_args()


if __name__ == "__main__":
    options, unittest_args = parse_args()
    PORT = options.port
    if options.binary:
        BINARY = Path(options.binary).expanduser().resolve()
    unittest.main(argv=[sys.argv[0], *unittest_args], verbosity=2)
