#!/usr/bin/env python3
"""Opt-in real-provider reading flow in a fresh HOME/XDG profile.

Requires --live-providers: this contacts Standard Ebooks and WuxiaClick plus
the existing public book workers. It never reads the user's profile or app.
"""
import argparse
import json
from pathlib import Path
import sqlite3
import time
import unittest
from urllib.parse import urlencode
import test_setup_token_live as live


class GitHubReadingLiveTest(unittest.TestCase):
    def setUp(self):
        self.opal = live.IsolatedOpal(self)
        self.addCleanup(self.opal.stop)
        profile = self.opal.config_root / "opal"
        sources = profile / "plugins" / "sources"
        sources.mkdir(parents=True)
        for provider, base in (("standardebooks", "https://standardebooks.org"),
                               ("wuxiaclick", "https://wuxia.click")):
            (sources / f"{provider}.json").write_text(json.dumps({"base": base}), encoding="utf-8")
        with sqlite3.connect(profile / "opal.db") as db:
            db.execute("CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT NOT NULL DEFAULT '')")
            db.executemany("INSERT INTO config VALUES(?,?)", [
                ("web_port", str(live.PORT)), ("web_bind", "loopback"),
                ("search_sources", str(1 << 12)), ("auto_download_subs", "0"),
                ("content_cache_enabled", "0"),
            ])
        token = self.opal.start()
        account = live.register("github-reading-fixture", host=self.opal.loopback_authority, setup_token=token)
        self.assertEqual(account.status, 200, account.body)
        self.headers = (("Cookie", account.session_cookie()),)
        self.until("setup", lambda data: data.get("has_sources") is True, timeout=20)

    def api(self, path, *, method="GET"):
        reply = live.request(method, "/api/" + path, host=self.opal.loopback_authority,
                             extra_headers=self.headers)
        self.assertEqual(reply.status, 200, reply.body[:1024])
        return reply.json()

    def until(self, path, predicate, timeout=70):
        deadline = time.monotonic() + timeout
        latest = None
        while time.monotonic() < deadline:
            latest = self.api(path)
            if predicate(latest):
                return latest
            time.sleep(0.15)
        self.fail(f"{path} did not settle: loading={latest.get('loading')}, "
                  f"error={latest.get('error')}, chapters={len(latest.get('chapters', []))}")

    def test_universal_reading_identity_opens_real_directory_and_prose(self):
        try:
            self.check_universal_reading_flow()
        finally:
            # unittest does not call cleanups after KeyboardInterrupt; always
            # terminate this owned profile even when a long live probe stops.
            self.opal.stop()

    def check_universal_reading_flow(self):
        untouched = self.api("novels")
        self.assertEqual(untouched["results"], [])
        for provider, query in (("standardebooks", "pride and prejudice"),
                                ("wuxiaclick", "dragon dragon dragon")):
            with self.subTest(provider=provider):
                self.api("unified_search?" + urlencode({"q": query}))
                results = self.until("unified_search", lambda data: not data["loading"])
                matches = [row for row in results["results"]
                           if row.get("source") == "novels"
                           and row.get("provider") == provider]
                providers = sorted({row.get("provider", "") for row in results["results"]})
                self.assertTrue(matches, f"{provider}: no actual searchable work; "
                                f"returned={len(results['results'])}, providers={providers}, "
                                f"statuses={results.get('sources', [])}")
                selected = matches[0]
                self.assertTrue(selected["title"])
                self.assertTrue(selected.get("poster_url"), f"{provider}: missing real advertised artwork")
                print(f"{provider}: universal search returned {len(matches)} real works", flush=True)
                before = self.api("novels")
                self.api("unified_search/play?" + urlencode({
                    "generation": results["generation"], "key": selected["key"],
                }), method="POST")
                directory = self.until("novels", lambda data:
                    data["title"] == selected["title"] and not data["chapters_loading"]
                    and bool(data["chapters"]))
                self.assertFalse(directory["error"])
                self.assertEqual(directory["results"], before["results"],
                                 "universal reader action must not overwrite Browse results")
                self.assertEqual(directory["search_generation"], before["search_generation"])
                chapter = next((i for i, row in enumerate(directory["chapters"])
                                if row["title"] == "I"), 0)
                self.api(f"novels/chapter?idx={chapter}")
                prose = self.until("novels", lambda data: not data["text_loading"]
                                   and bool(data["text"]))
                self.assertFalse(prose["error"])
                self.assertGreater(len(prose["text"]), 100)
                self.assertNotIn("Checking your browser", prose["text"])
                print(f"{provider}: {len(matches)} works, {len(directory['chapters'])} chapters, "
                      f"{len(prose['text'])} text characters", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--port", type=int, default=41707)
    parser.add_argument("--live-providers", action="store_true", required=True)
    args = parser.parse_args()
    live.BINARY = args.binary.resolve()
    live.PORT = args.port
    unittest.main(argv=[__file__], verbosity=2)
