#!/usr/bin/env python3
"""Exercise real library APIs beyond the old season/episode/watch limits."""
import argparse
from pathlib import Path
import sqlite3
import unittest
import test_setup_token_live as live


class TvLibraryTest(unittest.TestCase):
    def test_long_show_progress_and_manual_reset(self):
        opal = live.IsolatedOpal(self)
        self.addCleanup(opal.stop)
        token = opal.start()
        account = live.register("tv-regression", host=opal.loopback_authority, setup_token=token)
        self.assertEqual(account.status, 200, account.body)
        headers = (("Cookie", account.session_cookie()),)
        database = opal.config_root / "opal" / "opal.db"
        with sqlite3.connect(database) as db:
            db.execute("INSERT INTO tv_shows(tmdb_id,name,tracked,last_aired_season,last_aired_episode) VALUES(991234,'Long show fixture',1,75,600)")
            db.executemany("INSERT INTO tv_seasons VALUES(991234,?,?)", [(s, 30 if s < 75 else 600) for s in range(1, 76)])
            db.executemany("INSERT INTO tv_watched(tmdb_id,season,episode,watched) VALUES(991234,?,?,1)", [(s, e) for s in range(1, 76) for e in range(1, 31 if s < 75 else 600)])

        def mark(episode, value):
            result = live.request("POST", f"/api/library/action?action=watched&kind=tv&id=991234&season=75&episode={episode}&value={value}", host=opal.loopback_authority, extra_headers=headers)
            self.assertEqual(result.status, 200, result.body)

        def row():
            result = live.request("GET", "/api/library", host=opal.loopback_authority, extra_headers=headers)
            self.assertEqual(result.status, 200, result.body)
            return next(r for r in result.json()["items"] if r["tmdb_id"] == 991234)

        mark(599, "true")
        current = row()
        self.assertEqual((current["next_season"], current["next_episode"]), (75, 600))
        self.assertEqual(current["watched"], 2819)
        self.assertEqual(current["total"], 2820)
        mark(600, "true")
        self.assertFalse(row()["has_next"])
        watched = live.request("GET", "/api/library/watched?kind=tv&id=991234&season=75", host=opal.loopback_authority, extra_headers=headers)
        self.assertEqual(watched.status, 200, watched.body)
        self.assertEqual(len(watched.json()["episodes"]), 600)
        with sqlite3.connect(database) as db:
            db.execute("UPDATE tv_watched SET played_secs=100,position_secs=100 WHERE tmdb_id=991234 AND season=75 AND episode=600")
        mark(600, "false")
        with sqlite3.connect(database) as db:
            reset = db.execute("SELECT watched,played_secs,position_secs FROM tv_watched WHERE tmdb_id=991234 AND season=75 AND episode=600").fetchone()
        self.assertEqual(reset, (0, 0, 0))
        special = live.request("POST", "/api/library/action?action=watched&kind=tv&id=-42&season=0&episode=1&value=true", host=opal.loopback_authority, extra_headers=headers)
        self.assertEqual(special.status, 200, special.body)
        special_rows = live.request("GET", "/api/library/watched?kind=tv&id=-42&season=0", host=opal.loopback_authority, extra_headers=headers)
        self.assertEqual(special_rows.json()["episodes"], [1])


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    live.BINARY = args.binary.resolve()
    unittest.main(argv=[__file__], verbosity=2)
