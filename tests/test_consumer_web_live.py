#!/usr/bin/env python3
"""Consumer playback and navigation against the real web bundle; no screenshots.

Uses the shared offline catalog server and a generated, local WAV. Run with
--chromium /path/to/chrome-headless-shell. No personal account or media needed.
"""
import argparse
import io
import json
import shutil
import threading
from http.server import ThreadingHTTPServer
import unittest
import wave
from urllib.parse import urlsplit

import test_web_tap_targets_live as web

buffer = io.BytesIO()
with wave.open(buffer, 'wb') as audio:
    audio.setnchannels(1)
    audio.setsampwidth(2)
    audio.setframerate(8000)
    audio.writeframes(bytes(8000 * 2 * 30))
AUDIO = buffer.getvalue()


class ConsumerHandler(web._Handler):
    def do_GET(self):
        if urlsplit(self.path).path == '/__consumer.wav':
            start, end = 0, len(AUDIO) - 1
            raw = self.headers.get('Range', '')
            if raw.startswith('bytes='):
                first, last = raw[6:].split('-', 1)
                start = int(first or 0)
                end = min(end, int(last) if last else end)
            self.send_response(206 if raw else 200)
            self.send_header('Content-Type', 'audio/wav')
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Content-Length', str(end - start + 1))
            if raw:
                self.send_header('Content-Range', f'bytes {start}-{end}/{len(AUDIO)}')
            self.end_headers()
            self.wfile.write(AUDIO[start:end + 1])
            return
        return super().do_GET()


DRIVER = r"""
(async () => {
  const checks = [], errors = [];
  window.addEventListener('error', e => errors.push(String(e.message)));
  window.addEventListener('unhandledrejection', e => errors.push(String(e.reason)));
  const check = (name, ok) => { checks.push({name, ok:!!ok}); };
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  const until = async test => { for (let n=0;n<500;n++) { if (test()) return; await sleep(20); } throw new Error('Timed out'); };
  try {
    await until(() => AUTHENTICATED);
    const pages = [...new Set(navPageButtons.map(el => el.dataset.page))];
    for (const page of pages) {
      openPage(page, {focus:false});
      check('navigation ' + page, $('page-' + page)?.classList.contains('on'));
    }
    openPage('search');
    await openShow(1399, 'The Long Night Signal');
    const origin = $('show-back'); origin.focus();
    const video = $('video'); video.muted = true;
    openStreamUrl(location.origin + '/__consumer.wav', 'A local listening session');
    await until(() => video.readyState >= 1);
    check('real generated media loaded', video.duration === 30);
    check('player takes focus', document.activeElement === $('player'));
    check('background scroll locked', document.body.classList.contains('inline-player-open'));
    $('player-speed').value = '1.5'; $('player-speed').dispatchEvent(new Event('change'));
    check('playback speed applies', video.playbackRate === 1.5);
    video.pause(); video.dispatchEvent(new Event('pause'));
    await until(() => $('player-status').textContent === 'Paused');
    video.currentTime = 0;
    check('pause feedback', $('player-status').textContent === 'Paused');
    $('player').dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowRight',bubbles:true,cancelable:true}));
    await until(() => !video.seeking);
    check('seek forward ten seconds', video.currentTime >= 9.9 && video.currentTime < 11);
    const mute = video.muted;
    $('player').dispatchEvent(new KeyboardEvent('keydown', {key:'m',bubbles:true,cancelable:true}));
    check('mute keyboard shortcut', video.muted !== mute);
    $('player-close').focus();
    $('player-close').dispatchEvent(new KeyboardEvent('keydown', {key:'Tab',bubbles:true,cancelable:true}));
    check('focus stays in player', document.activeElement === video);
    $('player').dispatchEvent(new KeyboardEvent('keydown', {key:'Escape',bubbles:true,cancelable:true}));
    check('escape closes top player', !$('player').classList.contains('on'));
    check('show beneath player survives escape', $('show-page').classList.contains('on'));
    check('focus returns to origin', document.activeElement === origin);
    check('background scroll restored', !document.body.classList.contains('inline-player-open'));
    check('closed media unloaded', !video.hasAttribute('src'));
    openStreamUrl(location.origin + '/__consumer.wav', 'Second session');
    check('speed survives media switch', video.playbackRate === 1.5);
    video.dispatchEvent(new Event('error'));
    check('failure has actionable feedback', /another source/.test($('player-status').textContent));
    $('player-close').click();
    await sleep(100);
  } catch (error) { errors.push(error.stack || String(error)); }
  const result = document.createElement('pre'); result.id = 'tap-result'; result.hidden = true;
  result.textContent = JSON.stringify({checks, errors, width:innerWidth}); document.body.append(result);
})();
"""


class ConsumerWebTest(unittest.TestCase):
    def test_consumer_navigation_and_playback(self):
        if web.CHROMIUM is None:
            self.skipTest('Pass --chromium to run the real browser tier')
        try:
            from playwright.sync_api import sync_playwright
        except ImportError:
            self.skipTest('Install playwright to drive real media without virtual time')
        old_driver = web.DRIVER
        web.DRIVER = DRIVER
        self.addCleanup(setattr, web, 'DRIVER', old_driver)
        server = ThreadingHTTPServer(('127.0.0.1', 0), ConsumerHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(executable_path=web.CHROMIUM, headless=True)
            try:
                for width in (375, 1440):
                    with self.subTest(width=width):
                        page = browser.new_page(viewport={'width':width, 'height':844})
                        browser_errors = []
                        page.on('pageerror', lambda error: browser_errors.append(str(error)))
                        try:
                            page.goto(f'http://127.0.0.1:{server.server_port}/#home')
                            page.wait_for_selector('#tap-result', state='attached', timeout=15000)
                            result = json.loads(page.locator('#tap-result').text_content())
                        finally:
                            page.close()
                        self.assertEqual(browser_errors, [])
                        self.assertEqual(result['errors'], [], json.dumps(result, indent=2))
                        self.assertGreaterEqual(len(result['checks']), 35)
                        self.assertEqual([c['name'] for c in result['checks'] if not c['ok']], [])
                        print(f"{width}px: {len(result['checks'])} consumer checks passed", flush=True)
            finally:
                browser.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--chromium')
    args, rest = parser.parse_known_args()
    web.CHROMIUM = args.chromium or shutil.which('chrome-headless-shell') or shutil.which('chromium')
    unittest.main(argv=[__file__, *rest], verbosity=2)
