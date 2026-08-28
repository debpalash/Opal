#!/usr/bin/env python3
"""Repeatedly stop a real headless server while requests/workers are active."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import unittest

import test_setup_token_live as setup_live


BINARY: Path | None = None


class ShutdownLiveTest(unittest.TestCase):
    def test_repeated_shutdown_with_network_work_and_partial_clients(self) -> None:
        if BINARY is None or not BINARY.is_file():
            self.skipTest("pass --binary or set OPAL_HEADLESS_BIN")
        setup_live.BINARY = BINARY

        for iteration in range(3):
            opal = setup_live.IsolatedOpal(self)
            slow_clients: list[socket.socket] = []
            try:
                setup_token = opal.start()
                claimed = setup_live.register(
                    f"shutdown-{iteration}",
                    host=opal.loopback_authority,
                    setup_token=setup_token,
                )
                self.assertEqual(claimed.status, 200, claimed.body)
                cookie = claimed.session_cookie()

                # Start real provider workers. These commands return immediately;
                # the owned supervisor must cancel/join their network work.
                for path in (
                    "/api/podcasts/search?q=opal",
                    "/api/anime/search?q=opal",
                    "/api/youtube/search?q=opal",
                ):
                    response = setup_live.request(
                        "GET", path, host=opal.loopback_authority,
                        extra_headers=(("Cookie", cookie),),
                    )
                    self.assertEqual(response.status, 200, (path, response.body[:200]))

                # Keep connection handlers inside their bounded header read too.
                for _ in range(8):
                    sock = socket.create_connection(("127.0.0.1", setup_live.PORT), timeout=2)
                    sock.sendall(b"GET /api/status HTTP/1.1\r\nHost:")
                    slow_clients.append(sock)

                assert opal.process is not None
                os.killpg(opal.process.pid, signal.SIGTERM)
                try:
                    return_code = opal.process.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    self.fail(f"iteration {iteration}: shutdown did not join active work\n{opal.safe_log()}")
                self.assertIn(return_code, (0, -signal.SIGTERM), opal.safe_log())
                opal.process = None
            finally:
                for sock in slow_clients:
                    sock.close()
                opal.stop()


def main() -> int:
    global BINARY
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path)
    args = parser.parse_args()
    env_binary = os.environ.get("OPAL_HEADLESS_BIN")
    BINARY = (args.binary or (Path(env_binary) if env_binary else None))
    if BINARY is not None:
        BINARY = BINARY.resolve()
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ShutdownLiveTest)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
