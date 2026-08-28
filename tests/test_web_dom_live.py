#!/usr/bin/env python3
"""Behavior-level Web UI DOM hardening test in a real Chromium process."""

from __future__ import annotations

import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import tempfile
import threading
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
CHROMIUM: str | None = None


class WebDomLiveTest(unittest.TestCase):
    def test_hostile_provider_markup_never_reaches_the_live_dom(self) -> None:
        if CHROMIUM is None:
            self.skipTest("Chromium is not installed; browser tier dependency is explicit")

        document = f"""<!doctype html><meta charset=utf-8>
<div id=probe></div><pre id=result></pre>
<script src=\"/core.js\"></script>
<script>
window.__opalExecuted = false;
const provider = `<img src=x onerror=\"window.__opalExecuted=true\">` +
  `<a href=\"javascript:window.__opalExecuted=true\" onclick=\"window.__opalExecuted=true\">quoted ' value</a>` +
  `<iframe srcdoc=\"<script>window.__opalExecuted=true<\\/script>\"></iframe>` +
  `<svg><a xlink:href=\"javascript:window.__opalExecuted=true\">bad</a></svg>`;
document.getElementById('probe').innerHTML = provider;
const probe = document.getElementById('probe');
const quoted = `title'\" data-action=\"delete\" onclick=\"window.__opalExecuted=true`;
probe.insertAdjacentHTML('beforeend', `<button title="${{escAttr(quoted)}}">${{escText(quoted)}}</button>`);
const encodedButton = probe.querySelector('button');
const executable = probe.querySelector('script,iframe,object,embed,form') ||
  [...probe.querySelectorAll('*')].some(node => [...node.attributes].some(attr =>
    attr.name.toLowerCase().startsWith('on') || /^(?:javascript|vbscript):/i.test(attr.value)));
document.getElementById('result').textContent = JSON.stringify({{
  executed: window.__opalExecuted,
  executable: Boolean(executable),
  text: probe.textContent,
  title: encodedButton && encodedButton.title,
  injectedAction: encodedButton && encodedButton.hasAttribute('data-action'),
}});
</script>"""

        with tempfile.TemporaryDirectory(prefix="opal-dom-live-") as root:
            page = Path(root) / "case.html"
            page.write_text(document, encoding="utf-8")
            shutil.copy(REPO_ROOT / "web/js/core.js", Path(root) / "core.js")

            class QuietHandler(SimpleHTTPRequestHandler):
                def log_message(self, format: str, *args: object) -> None:
                    pass

            server = ThreadingHTTPServer(
                ("127.0.0.1", 0), partial(QuietHandler, directory=root)
            )
            server_thread = threading.Thread(target=server.serve_forever, daemon=True)
            server_thread.start()
            page_url = f"http://127.0.0.1:{server.server_port}/case.html"
            proc = subprocess.Popen(
                [
                    CHROMIUM,
                    "--headless=new",
                    "--no-sandbox",
                    "--disable-gpu",
                    "--disable-dev-shm-usage",
                    "--disable-background-networking",
                    "--disable-component-update",
                    "--disable-crash-reporter",
                    "--disable-default-apps",
                    "--disable-extensions",
                    "--disable-sync",
                    "--metrics-recording-only",
                    "--no-first-run",
                    f"--user-data-dir={Path(root) / 'chrome-profile'}",
                    "--virtual-time-budget=1500",
                    "--dump-dom",
                    page_url,
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            try:
                try:
                    stdout, stderr = proc.communicate(timeout=15)
                except subprocess.TimeoutExpired as expired:
                    # Ubuntu's Chromium package occasionally leaves a zygote
                    # alive after --dump-dom emitted the complete document.
                    # Reap the private process group and validate that output.
                    os.killpg(proc.pid, signal.SIGKILL)
                    tail_out, tail_err = proc.communicate()

                    def as_text(value: str | bytes | None) -> str:
                        return value.decode("utf-8", "replace") if isinstance(value, bytes) else (value or "")

                    stdout = as_text(expired.stdout) + as_text(tail_out)
                    stderr = as_text(expired.stderr) + as_text(tail_err)
            finally:
                server.shutdown()
                server.server_close()
                server_thread.join(timeout=2)
            if proc.returncode not in (0, -signal.SIGKILL) and '<pre id="result">' not in stdout:
                self.fail(f"Chromium exited with {proc.returncode}:\n{stderr[-2000:]}")
        marker = '<pre id="result">'
        self.assertIn(marker, stdout, stderr[-2000:])
        payload = stdout.split(marker, 1)[1].split("</pre>", 1)[0]
        result = json.loads(payload.replace("&quot;", '"').replace("&amp;", "&"))
        self.assertFalse(result["executed"])
        self.assertFalse(result["executable"])
        self.assertFalse(result["injectedAction"])
        self.assertEqual(result["title"], "title'\" data-action=\"delete\" onclick=\"window.__opalExecuted=true")
        self.assertIn("quoted ' value", result["text"])


def main() -> int:
    global CHROMIUM
    parser = argparse.ArgumentParser()
    parser.add_argument("--chromium")
    args = parser.parse_args()
    CHROMIUM = args.chromium or next(
        (path for name in ("chromium", "chromium-browser", "google-chrome")
         if (path := shutil.which(name))),
        None,
    )
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(WebDomLiveTest)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
