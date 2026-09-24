#!/usr/bin/env python3
"""Verify torrent cancellation removes the active stream, not only its transfer.

Run after a headless build::

    zig build -Dheadless=true
    python3 tests/test_torrent_unload_live.py --binary zig-out/bin/opal

The test owns a fresh profile and refuses to attach to an existing listener.
The dummy infohash has no metadata or downloadable files.
"""

from __future__ import annotations

import argparse
import os
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

    def api(self, method: str, path: str, cookie: str, *, form: dict[str, str] | None = None) -> setup_live.Response:
        return setup_live.request(
            method,
            path,
            host=self.opal.loopback_authority,
            extra_headers=(("Cookie", cookie),),
            form=form,
        )

    def test_cancel_unloads_active_torrent_before_removing_session(self) -> None:
        token = self.opal.start()
        registered = setup_live.register("unload-admin", host=self.opal.loopback_authority, setup_token=token)
        self.assertEqual(registered.status, 200, registered.body)
        cookie = registered.session_cookie()

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


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=os.environ.get("OPAL_HEADLESS_BIN"))
    options, unittest_args = parser.parse_known_args()
    if options.binary:
        BINARY = Path(options.binary).expanduser().resolve()
    unittest.main(argv=[sys.argv[0], *unittest_args], verbosity=2)
