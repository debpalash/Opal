#!/usr/bin/env python3
"""Adversarial black-box tests for first-admin setup-token handling.

This test is intentionally opt-in: it starts the supplied *headless* Opal
binary with fresh HOME/XDG directories and claims the first account.  It never
connects to an existing listener, and it does not participate in the fast
source-inspection feature suite.

Run after building the headless binary::

    zig build -Dheadless=true
    python3 tests/test_setup_token_live.py --binary zig-out/bin/opal

Use --port to select an unused isolated server port (default 41595). The
harness seeds that port into its private profile before startup and rejects an
existing listener. Only Python's standard library is required.
"""

from __future__ import annotations

import argparse
import concurrent.futures
from contextlib import contextmanager
import errno
import http.client
import json
import os
from pathlib import Path
import re
import signal
import socket
import sqlite3
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse


DEFAULT_PORT = 41595
SETUP_HEADER = "X-Opal-Setup-Token"
TOKEN_RE = re.compile(r"\A[0-9a-f]{64}\Z")
REPO_ROOT = Path(__file__).resolve().parents[1]
BINARY: Path | None = None
PORT = DEFAULT_PORT


@contextmanager
def database(path):
    """Commit/roll back and close a fixture DB before process start or cleanup.

    sqlite3's own context manager ends the transaction but retains the handle,
    which prevents deleting the isolated profile on Windows.
    """
    connection = sqlite3.connect(path)
    try:
        with connection:
            yield connection
    finally:
        connection.close()


class Response:
    def __init__(self, status: int, headers: list[tuple[str, str]], body: bytes):
        self.status = status
        self.headers = headers
        self.body = body

    def json(self) -> object:
        return json.loads(self.body.decode("utf-8"))

    def header_values(self, name: str) -> list[str]:
        return [value for key, value in self.headers if key.lower() == name.lower()]

    def session_cookie(self) -> str:
        values = self.header_values("set-cookie")
        if len(values) != 1:
            raise AssertionError(f"expected one Set-Cookie header, got {values!r}")
        return values[0].split(";", 1)[0]


def request(
    method: str,
    path: str,
    *,
    host: str,
    origin: str | None = None,
    setup_token: str | None = None,
    form: dict[str, str] | None = None,
    extra_headers: tuple[tuple[str, str], ...] = (),
) -> Response:
    """Send a request while retaining exact control of Host and Origin."""
    body = None
    headers: list[tuple[str, str]] = [("Host", host), ("Connection", "close")]
    if origin is not None:
        headers.append(("Origin", origin))
    if setup_token is not None:
        headers.append((SETUP_HEADER, setup_token))
    headers.extend(extra_headers)
    if form is not None:
        body = urllib.parse.urlencode(form).encode("ascii")
        headers.extend(
            [
                ("Content-Type", "application/x-www-form-urlencoded"),
                ("Content-Length", str(len(body))),
            ]
        )

    # bcrypt in a Debug binary can exceed four seconds on a busy CI host.
    # This is a test-client deadline; production authentication is unchanged.
    auth_request = path.split("?", 1)[0] in (
        "/api/auth/register", "/api/auth/login", "/api/access/users/create",
    )
    conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=15 if auth_request else 4)
    try:
        conn.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
        for key, value in headers:
            conn.putheader(key, value)
        conn.endheaders(body)
        response = conn.getresponse()
        return Response(response.status, response.getheaders(), response.read())
    finally:
        conn.close()


def register(
    username: str,
    *,
    host: str,
    origin: str | None = None,
    setup_token: str | None = None,
    extra_headers: tuple[tuple[str, str], ...] = (),
) -> Response:
    return request(
        "POST",
        "/api/auth/register",
        host=host,
        origin=origin,
        setup_token=setup_token,
        form={"username": username, "password": "adversarial-pass-123"},
        extra_headers=extra_headers,
    )


class IsolatedOpal:
    def __init__(self, testcase: unittest.TestCase):
        self.testcase = testcase
        self.temp = tempfile.TemporaryDirectory(prefix="opal-setup-live-")
        self.root = Path(self.temp.name)
        self.config_root = self.root / "xdg-config"
        self.setup_path = self.config_root / "opal" / "setup.token"
        self.log = tempfile.TemporaryFile(mode="w+b")
        self.process: subprocess.Popen[bytes] | None = None
        self.setup_token: str | None = None

    def preseed_setup_file(self, contents: str) -> None:
        self.setup_path.parent.mkdir(parents=True, exist_ok=True)
        self.setup_path.write_text(contents, encoding="ascii")
        if os.name == "posix":
            self.setup_path.chmod(0o600)

    def start(self, *, require_setup: bool = True, https_proxy: bool = False) -> str:
        assert BINARY is not None
        self._require_free_port()
        for directory in (
            self.config_root,
            self.root / "xdg-cache",
            self.root / "xdg-data",
            self.root / "home",
        ):
            directory.mkdir(parents=True, exist_ok=True)

        # Every launch uses its own durable port configuration. Existing
        # fixture settings survive restart; a conflicting seed is a test bug.
        profile = self.config_root / "opal"
        profile.mkdir(parents=True, exist_ok=True)
        with database(profile / "opal.db") as connection:
            connection.execute("CREATE TABLE IF NOT EXISTS config(key TEXT PRIMARY KEY, value TEXT)")
            connection.execute("INSERT OR IGNORE INTO config(key,value) VALUES ('web_port',?)", (str(PORT),))
            actual_port = connection.execute("SELECT value FROM config WHERE key='web_port'").fetchone()[0]
            self.testcase.assertEqual(str(actual_port), str(PORT), "isolated profile port differs from request port")

        env = os.environ.copy()
        env.update(
            {
                "HOME": str(self.root / "home"),
                "USERPROFILE": str(self.root / "home"),
                "APPDATA": str(self.config_root),
                "LOCALAPPDATA": str(self.root / "xdg-cache"),
                "XDG_CONFIG_HOME": str(self.config_root),
                "XDG_CACHE_HOME": str(self.root / "xdg-cache"),
                "XDG_DATA_HOME": str(self.root / "xdg-data"),
                "OPAL_HEADLESS": "1",
                # CI has no audio device. Exercise real decoding and playback
                # through null output, independent of host mpv overrides.
                "OPAL_MPV_OPTS": "ao=null",
            }
        )
        env.pop("OPAL_WEB_BIND", None)
        env["OPAL_HTTPS_PROXY"] = "1" if https_proxy else "0"
        env.pop("DISPLAY", None)
        env.pop("WAYLAND_DISPLAY", None)
        self.process = subprocess.Popen(
            [str(BINARY)],
            cwd=REPO_ROOT,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=self.log,
            stderr=subprocess.STDOUT,
            start_new_session=os.name == "posix",
            creationflags=(subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW) if os.name == "nt" else 0,
        )

        deadline = time.monotonic() + 30
        last_error: Exception | None = None
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                self.testcase.fail(
                    f"headless Opal exited with {self.process.returncode}:\n{self.safe_log()}"
                )
            try:
                health = request("GET", "/health", host=self.loopback_authority)
                if health.status == 200:
                    break
            except (ConnectionError, OSError, http.client.HTTPException) as error:
                last_error = error
            time.sleep(0.1)
        else:
            self.testcase.fail(
                f"headless Opal did not become healthy ({last_error!r}):\n{self.safe_log()}"
            )

        if not require_setup:
            return ""

        while time.monotonic() < deadline and not self.setup_path.is_file():
            time.sleep(0.05)
        self.testcase.assertTrue(
            self.setup_path.is_file(),
            f"setup token was not created at {self.setup_path}\n{self.safe_log()}",
        )
        self.testcase.assertEqual(
            self.setup_path.stat().st_size, 64, "setup.token must be exactly 64 bytes"
        )
        token = self.setup_path.read_text(encoding="ascii")
        self.testcase.assertRegex(token, TOKEN_RE)
        if os.name == "posix":
            mode = stat.S_IMODE(self.setup_path.stat().st_mode)
            self.testcase.assertEqual(mode, 0o600, "setup.token must be owner-only")
        self.setup_token = token
        return token

    @property
    def loopback_authority(self) -> str:
        return f"127.0.0.1:{PORT}"

    def assert_token_unconsumed(self, expected: str) -> None:
        self.testcase.assertTrue(self.setup_path.is_file())
        self.testcase.assertEqual(
            self.setup_path.read_text(encoding="ascii"), expected
        )

    def safe_log(self) -> str:
        text = self._read_log()
        if self.setup_token:
            text = text.replace(self.setup_token, "[REDACTED]")
        return text[-12000:]

    def log_contains(self, needle: str) -> bool:
        """Check a secret without ever returning/logging the unredacted text."""
        return needle in self._read_log()

    def _read_log(self) -> str:
        self.log.flush()
        self.log.seek(0)
        return self.log.read().decode("utf-8", errors="replace")

    def stop(self) -> None:
        self.stop_process()
        self.log.close()
        self.temp.cleanup()

    def stop_process(self) -> None:
        if self.process is not None and self.process.poll() is None:
            if os.name == "nt":
                # Kill only this owned child and its descendants. Windows has
                # no POSIX killpg; terminating the parent leaks curl sidecars.
                subprocess.run(["taskkill", "/PID", str(self.process.pid), "/T", "/F"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8, check=False)
                self.process.wait(timeout=3)
                self.process = None
                return
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
                self.process.wait(timeout=8)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                if self.process.poll() is None:
                    os.killpg(self.process.pid, signal.SIGKILL)
                    self.process.wait(timeout=3)
        self.process = None

    @staticmethod
    def _require_free_port() -> None:
        # A connect check catches wildcard listeners even on Darwin, where
        # SO_REUSEADDR permits a distinct loopback listener on the same port.
        # Send no bytes: this is solely an occupancy check, never an API call.
        exclusive = getattr(socket, "SO_EXCLUSIVEADDRUSE", None)
        if exclusive is None:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as connection:
                connection.settimeout(0.5)
                result = connection.connect_ex(("127.0.0.1", PORT))
                if result == 0:
                    raise unittest.SkipTest(
                        f"127.0.0.1:{PORT} is already in use; refusing to test an existing server"
                    )
                if result != errno.ECONNREFUSED:
                    raise unittest.SkipTest(
                        f"cannot establish that 127.0.0.1:{PORT} is unused (socket error {result})"
                    )
        probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            # Windows' timeout connect_ex can report WSAEWOULDBLOCK even for
            # an unused port. Exclusive bind checks ownership directly and
            # rejects wildcard listeners without waiting for TCP retries.
            probe.setsockopt(socket.SOL_SOCKET, exclusive if exclusive is not None else socket.SO_REUSEADDR, 1)
            probe.bind(("127.0.0.1", PORT))
            # Also catch bound sockets that have not begun listening yet.
            probe.listen(1)
        except OSError as error:
            raise unittest.SkipTest(
                f"127.0.0.1:{PORT} is already in use; refusing to test an existing server"
            ) from error
        finally:
            probe.close()


class PortCollisionGuardTest(unittest.TestCase):
    def test_bound_non_listening_port_is_rejected(self) -> None:
        global PORT
        previous = PORT
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as bound:
            bound.bind(("127.0.0.1", 0))
            PORT = bound.getsockname()[1]
            try:
                with self.assertRaises(unittest.SkipTest):
                    IsolatedOpal._require_free_port()
            finally:
                PORT = previous

    def test_wildcard_listener_is_rejected_before_start(self) -> None:
        global PORT
        previous = PORT
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind(("0.0.0.0", 0))
            listener.listen(1)
            PORT = listener.getsockname()[1]
            try:
                with self.assertRaises(unittest.SkipTest):
                    IsolatedOpal._require_free_port()
            finally:
                PORT = previous

    def test_unused_port_is_accepted(self) -> None:
        global PORT
        previous = PORT
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as temporary:
            temporary.bind(("127.0.0.1", 0))
            PORT = temporary.getsockname()[1]
        try:
            IsolatedOpal._require_free_port()
        finally:
            PORT = previous


class FixtureDatabaseTest(unittest.TestCase):
    def test_database_commits_and_closes_before_profile_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture.db'
            with database(path) as connection:
                connection.execute('CREATE TABLE fixture(value)')
                connection.execute('INSERT INTO fixture VALUES(7)')
            with self.assertRaises(sqlite3.ProgrammingError):
                connection.execute('SELECT 1')
            with database(path) as reader:
                self.assertEqual(reader.execute('SELECT value FROM fixture').fetchone(), (7,))
            path.unlink()


class SetupTokenLiveTest(unittest.TestCase):
    def setUp(self) -> None:
        if BINARY is None:
            self.skipTest("pass --binary or set OPAL_HEADLESS_BIN")
        if not BINARY.is_file():
            self.fail(f"headless binary does not exist: {BINARY}")
        self.opal = IsolatedOpal(self)
        self.addCleanup(self.opal.stop)

    def test_rejections_do_not_consume_token_and_success_is_one_time(self) -> None:
        setup_token = self.opal.start()
        authority = self.opal.loopback_authority

        status = request("GET", "/api/auth/status", host=authority)
        self.assertEqual(status.status, 200, status.body)
        self.assertNotIn(setup_token.encode("ascii"), status.body)
        self.assertNotIn(setup_token, repr(status.headers))
        self.assertTrue(status.json()["needs_setup"])  # type: ignore[index]

        page = request("GET", "/", host=authority)
        page_headers = {key.lower(): value for key, value in page.headers}
        self.assertEqual(page.status, 200, page.body[:200])
        self.assertNotIn(setup_token.encode("ascii"), page.body)
        self.assertNotIn(setup_token, repr(page.headers))
        self.assertEqual(page_headers.get("cache-control"), "no-store")
        self.assertEqual(page_headers.get("referrer-policy"), "no-referrer")

        # A browser-simple form submission cannot set the dedicated header.
        simple = register(
            "simple-form",
            host=authority,
            origin=f"http://{authority}",
        )
        self.assertEqual(simple.status, 403, simple.body)
        self.opal.assert_token_unconsumed(setup_token)

        missing = register("missing-token", host=authority)
        self.assertEqual(missing.status, 403, missing.body)
        self.opal.assert_token_unconsumed(setup_token)

        wrong = "0" * 64 if setup_token != "0" * 64 else "f" * 64
        rejected = register("wrong-token", host=authority, setup_token=wrong)
        self.assertEqual(rejected.status, 403, rejected.body)
        self.opal.assert_token_unconsumed(setup_token)

        uppercase = setup_token.upper()
        self.assertNotEqual(uppercase, setup_token, "random token was unexpectedly digit-only")
        rejected_case = register("uppercase-token", host=authority, setup_token=uppercase)
        self.assertEqual(rejected_case.status, 403, rejected_case.body)
        self.opal.assert_token_unconsumed(setup_token)

        duplicate = register(
            "duplicate-token",
            host=authority,
            setup_token=setup_token,
            extra_headers=((SETUP_HEADER, setup_token),),
        )
        self.assertEqual(duplicate.status, 403, duplicate.body)
        self.opal.assert_token_unconsumed(setup_token)

        cross_origin = register(
            "evil-origin",
            host=authority,
            origin="http://attacker.example",
            setup_token=setup_token,
        )
        self.assertEqual(cross_origin.status, 403, cross_origin.body)
        self.opal.assert_token_unconsumed(setup_token)

        invalid_host = register(
            "dns-host",
            host=f"opal.example:{PORT}",
            setup_token=setup_token,
        )
        self.assertEqual(invalid_host.status, 403, invalid_host.body)
        self.opal.assert_token_unconsumed(setup_token)

        claimed = register("first-admin", host=authority, setup_token=setup_token)
        self.assertEqual(claimed.status, 200, claimed.body)
        self.assertEqual(claimed.json(), {"ok": True})
        cookie_headers = claimed.header_values("set-cookie")
        self.assertEqual(len(cookie_headers), 1)
        cookie = cookie_headers[0]
        self.assertIn("opal_session=", cookie)
        self.assertIn("HttpOnly", cookie)
        self.assertIn("SameSite=Strict", cookie)
        self.assertIn("Path=/", cookie)
        self.assertNotIn(setup_token, cookie)
        session_cookie = claimed.session_cookie()
        authenticated_status = request(
            "GET",
            "/api/auth/status",
            host=authority,
            extra_headers=(("Cookie", session_cookie),),
        )
        self.assertTrue(authenticated_status.json()["authed"])  # type: ignore[index]
        self.assertFalse(self.opal.setup_path.exists(), "token file survived successful claim")

        replay = register("replay", host=authority, setup_token=setup_token)
        self.assertEqual(replay.status, 403, replay.body)

        final_status = request("GET", "/api/auth/status", host=authority)
        self.assertEqual(final_status.status, 200, final_status.body)
        self.assertFalse(final_status.json()["needs_setup"])  # type: ignore[index]
        self.assertNotIn(setup_token.encode("ascii"), final_status.body)
        self.assertFalse(self.opal.log_contains(setup_token), "setup token leaked to process log")

    def test_concurrent_lan_claim_has_exactly_one_winner(self) -> None:
        setup_token = self.opal.start()
        # Connect over loopback but exercise the accepted numeric-LAN authority.
        authority = f"192.168.50.20:{PORT}"
        origin = f"http://{authority}"
        barrier = threading.Barrier(3)

        def contender(username: str) -> Response:
            barrier.wait(timeout=5)
            return register(
                username,
                host=authority,
                origin=origin,
                setup_token=setup_token,
            )

        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(contender, "racer-a"), pool.submit(contender, "racer-b")]
            barrier.wait(timeout=5)
            responses = [future.result(timeout=20) for future in futures]

        self.assertEqual(sorted(response.status for response in responses), [200, 403])
        winners = [response for response in responses if response.status == 200]
        self.assertEqual(len(winners), 1)
        self.assertEqual(winners[0].json(), {"ok": True})
        self.assertTrue(winners[0].session_cookie().startswith("opal_session="))
        self.assertFalse(self.opal.setup_path.exists(), "winning claim did not consume token")

    def test_browser_extension_origin_can_present_capability(self) -> None:
        setup_token = self.opal.start()
        claimed = register(
            "extension-admin",
            host=self.opal.loopback_authority,
            origin="chrome-extension://abcdefghijklmnopabcdefghijklmnop",
            setup_token=setup_token,
        )
        self.assertEqual(claimed.status, 200, claimed.body)
        self.assertEqual(claimed.json(), {"ok": True})
        self.assertTrue(claimed.session_cookie().startswith("opal_session="))
        self.assertFalse(self.opal.setup_path.exists(), "extension claim did not consume token")

    def test_unclaimed_token_survives_restart(self) -> None:
        first = self.opal.start()
        self.opal.stop_process()
        second = self.opal.start()
        self.assertEqual(second, first, "restart rotated an unclaimed setup token")

        claimed = register(
            "restart-admin",
            host=self.opal.loopback_authority,
            setup_token=second,
        )
        self.assertEqual(claimed.status, 200, claimed.body)
        self.assertFalse(self.opal.setup_path.exists())

    def test_overlong_persisted_token_is_replaced_not_truncated(self) -> None:
        invalid = "a" * 65
        self.opal.preseed_setup_file(invalid)
        generated = self.opal.start()
        self.assertRegex(generated, TOKEN_RE)
        self.assertNotEqual(generated, invalid[:64])
        self.assertEqual(self.opal.setup_path.stat().st_size, 64)


def parse_args() -> tuple[argparse.Namespace, list[str]]:
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument(
        "--binary",
        default=os.environ.get("OPAL_HEADLESS_BIN"),
        help="path to a -Dheadless=true Opal binary (or set OPAL_HEADLESS_BIN)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=DEFAULT_PORT,
        help="unused port seeded into the isolated server profile (default: 41595)",
    )
    return parser.parse_known_args()


if __name__ == "__main__":
    options, unittest_args = parse_args()
    if not 1 <= options.port <= 65535:
        raise SystemExit("--port must be between 1 and 65535")
    PORT = options.port
    if options.binary:
        BINARY = Path(options.binary).expanduser().resolve()
    unittest.main(argv=[sys.argv[0], *unittest_args], verbosity=2)
