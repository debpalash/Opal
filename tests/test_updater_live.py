#!/usr/bin/env python3
"""Exercise the real updater through an isolated server and a fake curl."""
import argparse
import json
import os
import signal
from pathlib import Path
import sys
import time
import unittest
from unittest.mock import patch

import test_setup_token_live as live


class UpdaterTest(unittest.TestCase):
    def test_large_release_and_failed_refresh(self):
        opal = live.IsolatedOpal(self)
        self.addCleanup(opal.stop)
        fakebin = opal.root / "bin"
        fakebin.mkdir()
        response = opal.root / "release.json"
        release = {
            "body": "release notes " * 1500,
            "tag_name": "v99.0.0",
            "assets": [
                {"name": "Opal-99.0.0-macos-arm64.dmg",
                 "browser_download_url": "https://github.com/debpalash/Opal/releases/download/v99.0.0/Opal-99.0.0-macos-arm64.dmg"},
                {"name": "SHA256SUMS.txt",
                 "browser_download_url": "https://github.com/debpalash/Opal/releases/download/v99.0.0/SHA256SUMS.txt"},
            ],
        }
        response.write_text(json.dumps(release))
        helper = fakebin / "curl"
        helper.write_text(
            "#!" + sys.executable + "\n"
            "import os, sys, time\n"
            "if any('api.github.com/repos/debpalash/Opal/releases/latest' in a for a in sys.argv):\n"
            "    data = open(os.environ['OPAL_TEST_RELEASE'], 'rb').read()\n"
            "    if data == b'SLOW':\n"
            "        open(os.environ['OPAL_TEST_RELEASE'] + '.pid', 'w').write(str(os.getpid()))\n"
            "        time.sleep(120)\n"
            "    sys.stdout.buffer.write(data)\n"
            "else:\n"
            "    sys.exit(22)\n"
        )
        helper.chmod(0o755)
        with patch.dict(os.environ, {
            "PATH": str(fakebin) + os.pathsep + os.environ["PATH"],
            "OPAL_TEST_RELEASE": str(response),
        }):
            token = opal.start()
        registered = live.register("update-test", host=opal.loopback_authority, setup_token=token)
        self.assertEqual(registered.status, 200, registered.body)
        headers = (("Cookie", registered.session_cookie()),)

        def check():
            result = live.request("GET", "/api/about?action=check",
                                  host=opal.loopback_authority, extra_headers=headers)
            self.assertEqual(result.status, 200, result.body)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                status = live.request("GET", "/api/about", host=opal.loopback_authority,
                                      extra_headers=headers).json()
                if not status["checking"]:
                    return status
                time.sleep(0.05)
            self.fail("update check did not finish")

        status = check()
        self.assertEqual(status["latest"], "99.0.0")
        self.assertTrue(status["has_update"])
        self.assertEqual(status["error"], "")
        response.write_text('{"tag_name":')
        status = check()
        self.assertEqual(status["error"], "invalid release response")
        self.assertEqual(status["latest"], "99.0.0")
        response.write_text("x" * (256 * 1024 + 1))
        status = check()
        self.assertTrue(status["error"])
        self.assertEqual(status["latest"], "99.0.0")
        response.write_text("SLOW")
        live.request("GET", "/api/about?action=check", host=opal.loopback_authority,
                     extra_headers=headers)
        marker = Path(str(response) + ".pid")
        deadline = time.monotonic() + 5
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(marker.exists(), "slow update helper never started")
        child_pid = int(marker.read_text())
        assert opal.process is not None
        # Signal only Opal: its cancellation must terminate the helper.
        os.kill(opal.process.pid, signal.SIGTERM)
        self.assertEqual(opal.process.wait(timeout=8), 0, opal.safe_log())
        self.assertNotIn("forcing process exit", opal.safe_log())
        with self.assertRaises(ProcessLookupError):
            os.kill(child_pid, 0)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    live.BINARY = args.binary.resolve()
    unittest.main(argv=[sys.argv[0]], verbosity=2)
