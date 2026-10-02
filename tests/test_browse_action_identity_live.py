#!/usr/bin/env python3
"""Reject invalid or unavailable radio/music actions using an isolated headless server; no stream fetch."""
import argparse
from pathlib import Path
import sqlite3
import unittest
import test_setup_token_live as live


class BrowseActionIdentityTest(unittest.TestCase):
    def test_play_actions_require_available_content_identity(self):
        opal = live.IsolatedOpal(self)
        self.addCleanup(opal.stop)
        config = opal.config_root / "opal"
        config.mkdir(parents=True)
        with sqlite3.connect(config / "opal.db") as db:
            db.execute("CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT NOT NULL DEFAULT '')")
            db.executemany("INSERT INTO config VALUES(?,?)", [
                ("web_port", str(live.PORT)), ("web_bind", "loopback"),
                ("search_sources", "0"), ("auto_download_subs", "0"),
            ])
        token = opal.start()
        account = live.register("station-action-fixture", host=opal.loopback_authority, setup_token=token)
        self.assertEqual(account.status, 200, account.body)
        headers = (("Cookie", account.session_cookie()),)
        for query, status in (("idx=0", 400), ("uuid=", 409),
                              ("uuid=00000000-0000-0000-0000-000000000000", 409)):
            with self.subTest(query=query):
                reply = live.request("POST", "/api/radio/play?" + query,
                                     host=opal.loopback_authority, extra_headers=headers)
                self.assertEqual(reply.status, status, reply.body)
                self.assertIn("error", reply.json())
        for query, status in (("idx=0", 400), ("source=0&id=", 400),
                              ("source=255&id=old", 400), ("source=no&id=old", 400),
                              ("source=0&id=" + "x" * 129, 400), ("source=0&id=retired-track", 409)):
            with self.subTest(music=query):
                reply = live.request("POST", "/api/music/play?" + query,
                                     host=opal.loopback_authority, extra_headers=headers)
                self.assertEqual(reply.status, status, reply.body)
                self.assertIn("error", reply.json())


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--port", type=int, default=41701)
    args = parser.parse_args()
    live.BINARY = args.binary.resolve()
    live.PORT = args.port
    unittest.main(argv=[__file__], verbosity=2)
