#!/usr/bin/env python3
"""Isolated local-index API regression tests; generated files, no media/network fetch.

Run against a freshly built headless binary:
  python3 tests/test_local_library_live.py --binary zig-out/bin/opal
"""
import argparse
from pathlib import Path
import sqlite3
import time
import unittest
from urllib.parse import urlencode
import test_setup_token_live as live


class LocalLibraryLiveTest(unittest.TestCase):
    def setUp(self):
        self.opal = live.IsolatedOpal(self)
        self.addCleanup(self.opal.stop)
        self.database = self.opal.config_root / "opal" / "opal.db"
        self.database.parent.mkdir(parents=True)
        with sqlite3.connect(self.database) as db:
            db.execute("CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT NOT NULL DEFAULT '')")
            db.executemany("INSERT INTO config VALUES(?,?)", [
                ("web_port", str(live.PORT)), ("web_bind", "loopback"),
                ("search_sources", "0"), ("auto_download_subs", "0"),
            ])
        token = self.opal.start()
        account = live.register("local-library-fixture", host=self.opal.loopback_authority, setup_token=token)
        self.assertEqual(account.status, 200, account.body)
        self.headers = (("Cookie", account.session_cookie()),)

    def request(self, method, path, form=None):
        return live.request(method, path, host=self.opal.loopback_authority,
                            extra_headers=self.headers, form=form)

    def page(self, *, q=None, offset=0, limit=64):
        params = {"offset": offset, "limit": limit}
        if q is not None:
            params["q"] = q
        result = self.request("GET", "/api/local-library?" + urlencode(params))
        self.assertEqual(result.status, 200, result.body)
        return result.json()

    def action(self, **form):
        result = self.request("POST", "/api/local-library/action", form)
        self.assertEqual(result.status, 200, result.body)
        self.assertTrue(result.json()["ok"])

    def await_total(self, total):
        deadline = time.monotonic() + 15
        last = None
        while time.monotonic() < deadline:
            last = self.page()
            if not last["scanning"] and last["total"] == total:
                return last
            time.sleep(0.02)
        self.fail(f"index did not settle at {total}: {last}")

    def test_empty_query_landing_and_invalid_query(self):
        omitted = self.page()
        explicit = self.page(q="")
        self.assertEqual(explicit["total"], omitted["total"])
        self.assertEqual(explicit["items"], omitted["items"])
        self.assertEqual(explicit["offset"], 0)
        self.assertEqual(explicit["limit"], 64)
        self.assertEqual(explicit["returned"], 0)
        self.assertFalse(explicit["has_more"])
        malformed = self.request("GET", "/api/local-library?q=%GG")
        # The shared URL decoder preserves malformed percent escapes literally.
        self.assertEqual(malformed.status, 200, malformed.body)
        self.assertEqual(malformed.json()["total"], 0)
        for query in ("limit=0", "limit=99999", "offset=-1"):
            with self.subTest(query=query):
                result = self.request("GET", "/api/local-library?" + query)
                self.assertEqual(result.status, 400, result.body)

    def test_scan_pagination_corrections_and_deleted_last_page(self):
        media = self.opal.root / "generated-media"
        media.mkdir()
        files = []
        for i in range(130):
            directory = media / ("nested" if i % 2 else "root")
            directory.mkdir(exist_ok=True)
            path = directory / f"Fixture {i:03d}.mp4"
            path.write_bytes(f"synthetic index-only fixture {i:03d}\n".encode())
            files.append(path)
        (media / "ignored.txt").write_text("not media")
        self.action(action="add-root", path=str(media))
        first = self.await_total(130)
        self.assertTrue(any(root["name"] == media.name for root in first["roots"]))
        pages = [self.page(q="", offset=offset) for offset in (0, 64, 128)]
        self.assertEqual([p["returned"] for p in pages], [64, 64, 2])
        self.assertEqual([p["has_more"] for p in pages], [True, True, False])
        self.assertEqual([p["offset"] for p in pages], [0, 64, 128])
        self.assertTrue(all(p["total"] == 130 for p in pages))
        identities = [row["id"] for page in pages for row in page["items"]]
        self.assertEqual(len(set(identities)), 130)
        self.assertTrue(all(row["size"] > 0 for page in pages for row in page["items"]))

        found = self.page(q="Fixture 042")
        self.assertEqual(found["total"], 1)
        item_id = found["items"][0]["id"]
        title = "Corrected café & space?"
        self.action(action="correct", id=str(item_id), title=title, kind="tv")
        corrected = self.page(q=title)
        self.assertEqual(corrected["total"], 1)
        self.assertEqual(corrected["items"][0]["id"], item_id)
        self.assertEqual(corrected["items"][0]["title"], title)
        self.assertEqual(corrected["items"][0]["kind"], "tv")
        self.assertEqual(self.page(q="never matches fixture")["total"], 0)

        self.action(action="scan")
        # Write app configuration immediately after submitting a scan. This
        # asserts persistence, without claiming a deterministic overlap window.
        saved = self.request("POST", "/api/settings?key=auto_download_subs&value=true")
        self.assertEqual(saved.status, 200, saved.body)
        self.await_total(130)
        self.assertEqual(self.page(q=title)["items"][0]["id"], item_id)
        self.assertEqual(saved.json()["value"], True)
        deadline = time.monotonic() + 10
        value = None
        while time.monotonic() < deadline:
            with sqlite3.connect(self.database) as db:
                value = db.execute("SELECT value FROM config WHERE key='auto_download_subs'").fetchone()
            if value and value[0] in ("1", "true"):
                break
            time.sleep(0.05)
        self.assertIn(value[0], ("1", "true"), "successful settings mutation must persist")

        for path in files[-3:]:
            path.unlink()
        self.action(action="scan")
        self.await_total(127)
        stale_page = self.page(q="", offset=128)
        self.assertEqual(stale_page["total"], 127)
        self.assertEqual(stale_page["offset"], 128)
        self.assertEqual(stale_page["returned"], 0)
        self.assertFalse(stale_page["has_more"])
        last_offset = ((stale_page["total"] - 1) // stale_page["limit"]) * stale_page["limit"]
        last = self.page(q="", offset=last_offset)
        self.assertEqual(last["offset"], 64)
        self.assertEqual(last["returned"], 63)
        self.assertFalse(last["has_more"])
        self.assertEqual(self.page(q=title)["items"][0]["id"], item_id)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--port", type=int, default=41700)
    args = parser.parse_args()
    live.BINARY = args.binary.resolve()
    live.PORT = args.port
    unittest.main(argv=[__file__], verbosity=2)
