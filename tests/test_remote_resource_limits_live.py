#!/usr/bin/env python3
"""Black-box socket framing, deadline, and throttling tests for headless Opal.

Run after a headless build::

    zig build -Dheadless=true
    python3 tests/test_remote_resource_limits_live.py --binary zig-out/bin/opal

The harness always launches a fresh isolated process and refuses to connect if
the fixed test port is already occupied.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import socket
import sys
import time
import unittest

import test_setup_token_live as setup_live


DEFAULT_PORT = 41595
LOCAL_PORT = 41596
BINARY: Path | None = None


def raw_request(port: int, wire: bytes, timeout: float = 4.0) -> tuple[int, bytes, bytes]:
    sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    try:
        sock.settimeout(timeout)
        sock.sendall(wire)
        chunks: list[bytes] = []
        while True:
            block = sock.recv(8192)
            if not block:
                break
            chunks.append(block)
        response = b"".join(chunks)
    finally:
        sock.close()
    header, _, body = response.partition(b"\r\n\r\n")
    status_line = header.split(b"\r\n", 1)[0]
    status = int(status_line.split(b" ", 2)[1])
    return status, header, body


def exact_size_login(authority: str, target_size: int = 4096) -> bytes:
    base = b"username=absent&password=wrong-password&pad="
    for padding in range(target_size):
        body = base + b"x" * padding
        header = (
            b"POST /api/auth/login HTTP/1.1\r\n"
            + f"Host: {authority}\r\n".encode("ascii")
            + b"Content-Type: application/x-www-form-urlencoded\r\n"
            + f"Content-Length: {len(body)}\r\n".encode("ascii")
            + b"Connection: close\r\n\r\n"
        )
        if len(header) + len(body) == target_size:
            return header + body
    raise AssertionError("could not construct an exactly full request")


class RemoteResourceLimitsLiveTest(unittest.TestCase):
    def setUp(self) -> None:
        if BINARY is None:
            self.skipTest("pass --binary or set OPAL_HEADLESS_BIN")
        if not BINARY.is_file():
            self.fail(f"headless binary does not exist: {BINARY}")
        setup_live.BINARY = BINARY
        setup_live.PORT = DEFAULT_PORT
        self.opal = setup_live.IsolatedOpal(self)
        self.addCleanup(self.opal.stop)

    def claim_admin(self, username: str = "Admin") -> str:
        token = self.opal.start()
        response = setup_live.register(
            username,
            host=self.opal.loopback_authority,
            setup_token=token,
        )
        self.assertEqual(response.status, 200, response.body)
        self.assertEqual(response.json(), {"ok": True})
        return response.session_cookie()

    def login(self, username: str, password: str) -> setup_live.Response:
        return setup_live.request(
            "POST",
            "/api/auth/login",
            host=self.opal.loopback_authority,
            form={"username": username, "password": password},
        )

    def authenticated(self, path: str, session_cookie: str) -> setup_live.Response:
        return setup_live.request(
            "GET",
            path,
            host=self.opal.loopback_authority,
            extra_headers=(("Cookie", session_cookie),),
        )

    def test_exact_full_framing_and_transfer_encoding_rejection(self) -> None:
        self.opal.start()
        authority = self.opal.loopback_authority

        wire = exact_size_login(authority)
        self.assertEqual(len(wire), 4096)
        status, _, _ = raw_request(DEFAULT_PORT, wire)
        self.assertEqual(status, 401, "an exactly-full valid frame was rejected as oversized")

        for value in ("chunked", "identity"):
            request = (
                "POST /api/auth/login HTTP/1.1\r\n"
                f"Host: {authority}\r\n"
                f"Transfer-Encoding: {value}\r\n"
                "Connection: close\r\n\r\n"
            ).encode("ascii")
            status, _, body = raw_request(DEFAULT_PORT, request)
            self.assertEqual(status, 400, (value, body))

    def test_incomplete_declared_body_hits_body_deadline(self) -> None:
        self.opal.start()
        request = (
            "POST /api/auth/login HTTP/1.1\r\n"
            f"Host: {self.opal.loopback_authority}\r\n"
            "Content-Type: application/x-www-form-urlencoded\r\n"
            "Content-Length: 64\r\n"
            "Connection: close\r\n\r\n"
            "x"
        ).encode("ascii")
        started = time.monotonic()
        status, _, body = raw_request(DEFAULT_PORT, request, timeout=13)
        elapsed = time.monotonic() - started
        self.assertEqual(status, 408, body)
        self.assertGreaterEqual(elapsed, 9.0)
        self.assertLess(elapsed, 12.5)

        health = setup_live.request("GET", "/health", host=self.opal.loopback_authority)
        self.assertEqual(health.status, 200, health.body)

    def test_partial_clients_release_all_remote_and_local_slots(self) -> None:
        self.opal.start()

        # startLocal initializes on the startup worker; wait without sending a
        # complete request that could perturb the slot count.
        deadline = time.monotonic() + 10
        while True:
            try:
                probe = socket.create_connection(("127.0.0.1", LOCAL_PORT), timeout=0.25)
                probe.close()
                break
            except OSError:
                if time.monotonic() >= deadline:
                    self.fail("loopback scrape listener did not start")
                time.sleep(0.05)

        held: list[socket.socket] = []
        try:
            for port, count in ((DEFAULT_PORT, 64), (LOCAL_PORT, 8)):
                for _ in range(count):
                    sock = socket.create_connection(("127.0.0.1", port), timeout=2)
                    sock.settimeout(2)
                    sock.sendall(b"POST /api/auth/login HTTP/1.1\r\nHost:")
                    held.append(sock)

            # The five-second header deadline is total, not reset by partial
            # progress. Give cancellation/close a small scheduling margin.
            time.sleep(6.5)

            health = setup_live.request("GET", "/health", host=self.opal.loopback_authority)
            self.assertEqual(health.status, 200, health.body)
            status, _, _ = raw_request(
                LOCAL_PORT,
                b"GET /not-scrape HTTP/1.1\r\nHost: 127.0.0.1:41596\r\nConnection: close\r\n\r\n",
            )
            self.assertEqual(status, 404)
        finally:
            for sock in held:
                sock.close()

    def test_username_case_variants_share_lockout_and_retry_after(self) -> None:
        self.claim_admin("Admin")
        for username in ("admin", "ADMIN", "aDmIn", "Admin", "adMIN"):
            response = self.login(username, "definitely-wrong")
            self.assertEqual(response.status, 401, (username, response.body))

        blocked = self.login("ADMIN", "adversarial-pass-123")
        self.assertEqual(blocked.status, 429, blocked.body)
        headers = {name.lower(): value for name, value in blocked.headers}
        self.assertGreaterEqual(int(headers["retry-after"]), 1)
        payload = blocked.json()
        self.assertGreaterEqual(payload["retry_after"], 1)  # type: ignore[index]

    def test_per_ip_auth_budget_returns_429_with_retry_after(self) -> None:
        self.claim_admin("budget-admin")  # consumes one of the 20 IP units
        for attempt in range(19):
            response = self.login(f"unknown-{attempt}", "definitely-wrong")
            self.assertEqual(response.status, 401, (attempt, response.body))

        blocked = self.login("one-too-many", "definitely-wrong")
        self.assertEqual(blocked.status, 429, blocked.body)
        headers = {name.lower(): value for name, value in blocked.headers}
        self.assertGreaterEqual(int(headers["retry-after"]), 1)
        self.assertEqual(headers.get("cache-control"), "no-store")

    def test_expensive_budget_does_not_block_media_polling(self) -> None:
        session = self.claim_admin("expensive-admin")
        for attempt in range(24):
            response = self.authenticated(f"/api/search?q=budget-{attempt}", session)
            self.assertEqual(response.status, 200, (attempt, response.body[:200]))

        blocked = self.authenticated("/api/search?q=one-too-many", session)
        self.assertEqual(blocked.status, 429, blocked.body)
        headers = {name.lower(): value for name, value in blocked.headers}
        self.assertGreaterEqual(int(headers["retry-after"]), 1)

        # Search-result and player-status polling must stay out of the
        # expensive-work budget even after that budget is exhausted.
        search_poll = self.authenticated("/api/search", session)
        self.assertEqual(search_poll.status, 200, search_poll.body)
        self.assertNotIn("retry-after", {name.lower() for name, _ in search_poll.headers})

        status = self.authenticated("/api/status", session)
        self.assertEqual(status.status, 200, status.body)
        self.assertNotIn("retry-after", {name.lower() for name, _ in status.headers})

    def test_media_sse_and_concurrent_snapshot_contracts(self) -> None:
        cookie = self.claim_admin("snapshot-admin")

        unauth = setup_live.request(
            "GET", "/api/podcasts/poster?idx=999",
            host=self.opal.loopback_authority,
        )
        self.assertEqual(unauth.status, 401, unauth.body)
        authorized = self.authenticated("/api/podcasts/poster?idx=999", cookie)
        self.assertEqual(authorized.status, 404, authorized.body)

        # EventSource cannot attach Authorization, so prove the same-origin
        # session cookie reaches a real SSE response and yields an event.
        sock = socket.create_connection(("127.0.0.1", DEFAULT_PORT), timeout=4)
        try:
            sock.settimeout(4)
            sock.sendall((
                "GET /events HTTP/1.1\r\n"
                f"Host: {self.opal.loopback_authority}\r\n"
                f"Cookie: {cookie}\r\n"
                "Connection: close\r\n\r\n"
            ).encode("ascii"))
            wire = b""
            while b"data:" not in wire:
                wire += sock.recv(8192)
            self.assertIn(b"HTTP/1.1 200 OK", wire)
            self.assertIn(b"text/event-stream", wire)
            payload = wire.split(b"data:", 1)[1].split(b"\n\n", 1)[0].strip()
            json.loads(payload)
        finally:
            sock.close()

        # Race provider publication against independent API readers. Every
        # response must remain valid JSON with a whole generation-tagged view.
        def reader(_: int) -> int:
            response = self.authenticated("/api/podcasts", cookie)
            self.assertEqual(response.status, 200, response.body[:200])
            payload = response.json()
            self.assertIsInstance(payload["generation"], int)  # type: ignore[index]
            self.assertIsInstance(payload["results"], list)  # type: ignore[index]
            self.assertIsInstance(payload["episodes"], list)  # type: ignore[index]
            return payload["generation"]  # type: ignore[index,return-value]

        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            trigger = pool.submit(
                self.authenticated, "/api/podcasts/search?q=opal", cookie,
            )
            generations = list(pool.map(reader, range(48)))
            self.assertEqual(trigger.result(timeout=10).status, 200)
        self.assertTrue(all(generation >= 0 for generation in generations))


def parse_args() -> tuple[argparse.Namespace, list[str]]:
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument(
        "--binary",
        default=os.environ.get("OPAL_HEADLESS_BIN"),
        help="path to a -Dheadless=true Opal binary (or set OPAL_HEADLESS_BIN)",
    )
    return parser.parse_known_args()


if __name__ == "__main__":
    options, unittest_args = parse_args()
    if options.binary:
        BINARY = Path(options.binary).expanduser().resolve()
    unittest.main(argv=[sys.argv[0], *unittest_args], verbosity=2)
