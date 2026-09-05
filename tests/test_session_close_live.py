#!/usr/bin/env python3
"""Check that a normal close persists a reopenable session, without autoplay."""
import argparse
from pathlib import Path
import signal
import os
import sqlite3
import time
import unittest
import wave
import test_setup_token_live as live


class SessionCloseTest(unittest.TestCase):
    def test_close_saves_media_and_restart_does_not_autoplay(self):
        opal = live.IsolatedOpal(self)
        self.addCleanup(opal.stop)
        media = opal.root / "session.wav"
        with wave.open(str(media), "wb") as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(8000)
            audio.writeframes(b"\0\0" * 8000 * 60)
        token = opal.start()
        account = live.register("session-test", host=opal.loopback_authority, setup_token=token)
        self.assertEqual(account.status, 200, account.body)
        headers = (("Cookie", account.session_cookie()),)
        loaded = live.request("POST", "/api/load", host=opal.loopback_authority,
                              extra_headers=headers, form={"url": str(media)})
        self.assertEqual(loaded.status, 200, loaded.body)
        self.assertTrue(loaded.json()["ok"], loaded.body)
        time.sleep(3)
        assert opal.process is not None
        os.kill(opal.process.pid, signal.SIGTERM)
        self.assertEqual(opal.process.wait(timeout=8), 0, opal.safe_log())
        self.assertNotIn("forcing process exit", opal.safe_log())
        database = opal.config_root / "opal" / "opal.db"
        with sqlite3.connect(database) as db:
            saved = dict(db.execute("SELECT key, value FROM config WHERE key LIKE 'session_%'"))
        self.assertEqual(saved["session_saved"], "1")
        self.assertEqual(saved["session_url_0"], str(media))
        self.assertGreaterEqual(float(saved["session_position"]), 0)
        self.assertIn(saved["session_paused"], ("0", "1"))
        self.assertGreater(float(saved["session_speed"]), 0)
        opal.start(require_setup=False)
        time.sleep(2)
        status = live.request("GET", "/api/status", host=opal.loopback_authority,
                              extra_headers=headers)
        self.assertEqual(status.status, 200, status.body)
        self.assertNotIn(str(media), status.body.decode())
        os.kill(opal.process.pid, signal.SIGTERM)
        self.assertEqual(opal.process.wait(timeout=8), 0, opal.safe_log())
        with sqlite3.connect(database) as db:
            unchanged = dict(db.execute("SELECT key, value FROM config WHERE key LIKE 'session_%'"))
        self.assertEqual(unchanged, saved, "an unanswered restore must survive another close")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    live.BINARY = args.binary.resolve()
    unittest.main(argv=[__file__], verbosity=2)
