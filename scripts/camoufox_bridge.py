#!/usr/bin/env python3
"""
Browser Bridge — persistent daemon for the Opal in-app browser.

Drives one of two Playwright-compatible engines, selected with
`--engine camoufox|cloakbrowser` (default camoufox):
  * camoufox     — Firefox-based anti-detect browser
  * cloakbrowser — Chromium-based anti-detect browser (free tier; its ~200MB
                   binary auto-downloads on the first launch and is cached)
Both expose Playwright's page API, so everything below the launch branch is
engine-agnostic. A missing engine package emits {"error": ...} and exits so
the Zig side surfaces "install it in Settings" instead of hanging.

Protocol (stdin → stdout, binary):
  Commands: JSON lines on stdin
  Responses: 'J' + JSON line  or  'F' + 4-byte big-endian length + JPEG data

Streaming model (v2): a reader thread feeds commands into a queue; the single
Playwright thread drains it and runs an adaptive frame pump —
  * ~12 fps while the user is interacting or the page is visibly animating
  * ~2 fps while recently active but visually quiet
  * ~0.5 fps when idle, stopping entirely after IDLE_STOP_S of silence
Identical frames are deduped by hash so static pages cost nothing. URL/title
changes (link clicks, redirects, SPA pushState) are pushed as JSON so the
address bar follows the page without polling from the Zig side.

JSON message prefixes are a CONTRACT with the Zig reader (browser_pure.zig
classifyBridgeMsg): nav pushes serialize as {"event": "nav", ...}, navigate
responses as {"ok": true, "title": ...}, failures as {"error": ...}. Keep key
order stable (json.dumps preserves insertion order).

Run with --selftest to exercise protocol framing without launching a browser.
"""

import sys, json, struct, time, os, signal, io, pathlib, queue, threading, hashlib

os.environ.setdefault("PLAYWRIGHT_BROWSERS_PATH", "0")

# Use binary mode for stdout to avoid encoding issues with JPEG frames
stdout_lock = threading.Lock()
stdout_bin = sys.stdout.buffer

# ── Pump tuning ──
FPS_ACTIVE_INTERVAL = 0.08   # ~12 fps during interaction / animation
FPS_SETTLE_INTERVAL = 0.50   # ~2 fps shortly after activity
FPS_IDLE_INTERVAL = 2.00     # heartbeat while idle (catches slow page updates)
ACTIVE_WINDOW_S = 1.5        # stay at active rate this long after input
SETTLE_WINDOW_S = 10.0       # stay at settle rate this long after input
IDLE_STOP_S = 120.0          # stop pumping entirely after this much silence
QUALITY_ACTIVE = 70          # lower quality → lower latency while moving
QUALITY_SETTLED = 82         # crisper once the page is still

MIN_VIEW_W, MAX_VIEW_W = 320, 2560
MIN_VIEW_H, MAX_VIEW_H = 240, 1600


def send_json(obj, out=None):
    """Send a JSON response: 'J' marker + JSON + newline."""
    line = json.dumps(obj, ensure_ascii=False) + "\n"
    raw = b"J" + line.encode("utf-8")
    with stdout_lock:
        (out or stdout_bin).write(raw)
        (out or stdout_bin).flush()


def send_frame(data: bytes, out=None):
    """Send a binary frame: 'F' + 4-byte big-endian length + JPEG data."""
    header = b"F" + struct.pack(">I", len(data))
    with stdout_lock:
        (out or stdout_bin).write(header + data)
        (out or stdout_bin).flush()


# ── Anti-block scrape fetch ──
# fetchhtml / fetchapi run on a DEDICATED page in a SEPARATE browser context so
# they never disturb the user's interactive browsing page. The unblocked bytes
# come back as an 'H' frame ('H' + 4-byte BE length + raw UTF-8) — a binary
# frame rather than a JSON line so a multi-hundred-KB page needs no JSON
# escaping and the Zig reader can bulk-read it (see browser.zig 'H' handling).
# Failures come back as {"event": "fetchhtml", "error": ...} (a JSON line).
MAX_SCRAPE_BYTES = 2_000_000  # cap outerHTML / api text (matches Zig scrape_buf)

# Cloudflare / challenge interstitial markers — while ANY of these is present in
# the title or body head, the challenge is still running; we keep polling.
CHALLENGE_MARKERS = (
    "just a moment",
    "checking your browser",
    "attention required",
    "cf-browser-verification",
    "challenge-running",
    "cf_chl_opt",
    "verifying you are human",
    "please verify you are a human",
    "enable javascript and cookies to continue",
    "ddos-guard",
)


def send_html_frame(data: bytes, out=None):
    """Send an unblocked scrape payload: 'H' + 4-byte big-endian length + bytes."""
    header = b"H" + struct.pack(">I", len(data))
    with stdout_lock:
        (out or stdout_bin).write(header + data)
        (out or stdout_bin).flush()


def looks_like_challenge(title, body_head):
    """True while a Cloudflare/DDoS-Guard interstitial is still on screen."""
    hay = ((title or "") + " " + (body_head or "")).lower()
    return any(m in hay for m in CHALLENGE_MARKERS)


def clamp_viewport(w, h):
    """Clamp a requested viewport to sane bounds (bad input → defaults)."""
    try:
        w, h = int(w), int(h)
    except (TypeError, ValueError):
        return 1280, 720
    return (
        max(MIN_VIEW_W, min(MAX_VIEW_W, w)),
        max(MIN_VIEW_H, min(MAX_VIEW_H, h)),
    )


def stdin_reader(q):
    """Reader thread: parse stdin lines into the command queue.

    Playwright's sync API is single-threaded — this thread never touches the
    page, it only feeds parsed dicts (or None on EOF) to the main loop.
    """
    reader = io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8")
    while True:
        try:
            line = reader.readline()
        except (EOFError, ValueError):
            break
        if not line:
            break  # EOF — parent died
        line = line.strip()
        if not line:
            continue
        try:
            q.put(json.loads(line))
        except json.JSONDecodeError:
            send_json({"error": "invalid json"})
    q.put(None)


class Pump:
    """Adaptive frame pump state (all methods run on the Playwright thread)."""

    def __init__(self):
        self.last_activity = time.monotonic()
        self.last_change = time.monotonic()
        # -inf = "never" — time.monotonic() can start near 0 (macOS), so 0.0
        # is NOT a safe sentinel for "no capture attempted yet".
        self.last_attempt = float("-inf")
        self.last_sent_hash = b""
        self.last_url = ""

    def poke(self):
        self.last_activity = time.monotonic()

    def force_next(self):
        """Guarantee the next capture happens immediately and is sent even if
        pixels are unchanged (navigation / resize — content certainly moved)."""
        self.last_sent_hash = b""
        self.last_attempt = float("-inf")
        self.poke()

    def interval(self):
        """Current capture interval, or None when idle-stopped."""
        now = time.monotonic()
        quiet = now - max(self.last_activity, self.last_change)
        since_input = now - self.last_activity
        if since_input < ACTIVE_WINDOW_S or now - self.last_change < ACTIVE_WINDOW_S:
            return FPS_ACTIVE_INTERVAL
        if since_input < SETTLE_WINDOW_S:
            return FPS_SETTLE_INTERVAL
        if quiet < IDLE_STOP_S:
            return FPS_IDLE_INTERVAL
        return None

    def quality(self):
        now = time.monotonic()
        moving = (now - self.last_activity) < ACTIVE_WINDOW_S
        return QUALITY_ACTIVE if moving else QUALITY_SETTLED

    def capture(self, page):
        """Take a screenshot; send it only if the pixels actually changed."""
        try:
            frame = page.screenshot(type="jpeg", quality=self.quality())
        except Exception:
            return
        digest = hashlib.md5(frame).digest()
        if digest == self.last_sent_hash:
            return
        self.last_sent_hash = digest
        self.last_change = time.monotonic()
        send_frame(frame)

    def maybe_capture(self, page, force=False):
        """Rate-gated capture: at most one screenshot per interval(). Without
        this gate a 20 Hz hover-mousemove stream drove 20 fps captures —
        above even the active budget."""
        now = time.monotonic()
        iv = self.interval()
        if not force:
            if iv is None:
                return
            if now - self.last_attempt < iv:
                return
        self.last_attempt = now
        self.capture(page)

    def seconds_until_due(self):
        """Queue-wait timeout: time until the next capture is allowed, or
        None when idle-stopped (block on the queue indefinitely)."""
        iv = self.interval()
        if iv is None:
            return None
        return max(0.0, self.last_attempt + iv - time.monotonic())

    def push_page_state(self, page):
        """Push {"title","url"} when the page navigated underneath us."""
        try:
            url = page.url or ""
        except Exception:
            return
        if url == self.last_url:
            return
        self.last_url = url
        try:
            title = page.title() or ""
        except Exception:
            title = ""
        send_json({"event": "nav", "title": title, "url": url})
        self.force_next()


def get_scrape_page(page, scrape):
    """Lazily create (and reuse) a dedicated page in a SEPARATE context so the
    anti-block fetch never touches the user's interactive page/session."""
    sp = scrape.get("page")
    if sp is not None:
        return sp
    ctx = page.context.browser.new_context()
    sp = ctx.new_page()
    sp.set_default_timeout(30000)
    scrape["ctx"] = ctx
    scrape["page"] = sp
    return sp


def wait_for_challenge_clear(sp, wait_ms):
    """Poll up to wait_ms for a Cloudflare/DDoS-Guard challenge to auto-clear,
    then return the page's outerHTML (capped). Camoufox/CloakBrowser pass the
    challenge on their own; we just wait it out."""
    try:
        budget = max(1000, min(30000, int(wait_ms)))
    except (TypeError, ValueError):
        budget = 15000
    deadline = time.monotonic() + budget / 1000.0
    while True:
        try:
            title = sp.title() or ""
        except Exception:
            title = ""
        try:
            body_head = sp.evaluate(
                "() => (document.body ? document.body.innerText : '').slice(0, 400)"
            ) or ""
        except Exception:
            body_head = ""
        if not looks_like_challenge(title, body_head):
            break
        if time.monotonic() >= deadline:
            break
        sp.wait_for_timeout(500)
    try:
        html = sp.evaluate("() => document.documentElement.outerHTML") or ""
    except Exception:
        html = ""
    return html[:MAX_SCRAPE_BYTES]


def apply_command(page, pump, cmd, viewport, scrape=None):
    """Execute one command. Returns False when the bridge should exit."""
    if scrape is None:
        scrape = {}
    action = cmd.get("cmd", "")

    try:
        if action == "navigate":
            url = cmd.get("url", "")
            if url:
                try:
                    page.goto(url, wait_until="domcontentloaded", timeout=20000)
                except Exception as e:
                    # Report the failure ONLY — the old code fell through to an
                    # ok/title response carrying the PREVIOUS page's URL, which
                    # silently rewrote the address bar over the user's input.
                    send_json({"error": str(e)[:200], "url": url})
                    return True
                title = ""
                try:
                    title = page.title() or ""
                except Exception:
                    pass
                final_url = page.url or url
                pump.last_url = final_url
                send_json({"ok": True, "title": title, "url": final_url})
                pump.force_next()
            else:
                send_json({"error": "no url"})

        elif action == "screenshot":
            w = cmd.get("w", viewport[0])
            h = cmd.get("h", viewport[1])
            w, h = clamp_viewport(w, h)
            if (w, h) != tuple(viewport):
                page.set_viewport_size({"width": w, "height": h})
                viewport[0], viewport[1] = w, h
                pump.force_next()  # viewport changed — pixels certainly did
            else:
                # Freshness heartbeat: capture now, let the hash dedupe decide
                # whether anything is actually sent (no forced resend).
                pump.poke()
            pump.maybe_capture(page, force=True)

        elif action == "click":
            x, y = cmd.get("x", 0), cmd.get("y", 0)
            button = cmd.get("button", "left")
            if button not in ("left", "right", "middle"):
                button = "left"
            page.mouse.click(x, y, button=button)
            pump.poke()

        elif action == "dblclick":
            page.mouse.dblclick(cmd.get("x", 0), cmd.get("y", 0))
            pump.poke()

        elif action == "scroll":
            page.mouse.wheel(cmd.get("dx", 0), cmd.get("dy", 0))
            pump.poke()

        elif action == "mousemove":
            page.mouse.move(cmd.get("x", 0), cmd.get("y", 0))
            pump.poke()

        elif action == "type":
            page.keyboard.type(cmd.get("text", ""), delay=0)
            pump.poke()

        elif action == "keypress":
            # Accepts plain keys ("Enter") and combos ("Control+a").
            key = cmd.get("key", "")
            if key:
                page.keyboard.press(key)
            pump.poke()

        elif action == "back":
            try:
                page.go_back(wait_until="domcontentloaded", timeout=15000)
            except Exception:
                pass
            pump.push_page_state(page)
            pump.force_next()

        elif action == "forward":
            try:
                page.go_forward(wait_until="domcontentloaded", timeout=15000)
            except Exception:
                pass
            pump.push_page_state(page)
            pump.force_next()

        elif action == "resize":
            w, h = clamp_viewport(cmd.get("w", 1280), cmd.get("h", 720))
            page.set_viewport_size({"width": w, "height": h})
            viewport[0], viewport[1] = w, h
            send_json({"ok": True, "w": w, "h": h})
            pump.force_next()

        elif action == "find":
            # window.find(text, caseSensitive, backwards, wrapAround) —
            # repeated calls continue from the last match. dir="prev" walks
            # backwards; the total match count comes from a body-text scan.
            text = cmd.get("text", "")
            backwards = cmd.get("dir", "next") == "prev"
            found = False
            count = 0
            if text:
                try:
                    found = bool(page.evaluate(
                        "a => window.find(a[0], false, a[1], true)",
                        [text, backwards]))
                except Exception:
                    found = False
                try:
                    count = int(page.evaluate(
                        "t => { const b = (document.body && document.body.innerText) || '';"
                        " const l = b.toLowerCase(); const q = t.toLowerCase();"
                        " let n = 0, i = 0;"
                        " while (q && (i = l.indexOf(q, i)) !== -1) { n++; i += q.length; }"
                        " return n; }", text) or 0)
                except Exception:
                    count = 0
            send_json({"ok": True, "found": found, "count": count})
            pump.force_next()  # selection highlight moved — repaint

        elif action == "readtext":
            # Reader quick action: the page's visible text for the overlay.
            # Capped so the escaped JSON line stays within the Zig reader's
            # line buffer (see browser.zig bridgeReaderThread).
            try:
                text = page.evaluate(
                    "() => (document.body && document.body.innerText) || ''") or ""
            except Exception:
                text = ""
            send_json({"event": "readtext", "text": text[:3500]})

        elif action == "zoom":
            try:
                factor = float(cmd.get("factor", 1.0))
            except (TypeError, ValueError):
                factor = 1.0
            factor = max(0.25, min(4.0, factor))
            try:
                page.evaluate("f => { document.documentElement.style.zoom = f; }", factor)
            except Exception:
                pass
            pump.force_next()

        elif action == "scrape":
            url = cmd.get("url", "")
            selector = cmd.get("selector", "")
            attr = cmd.get("attr", "textContent")
            if url:
                page.goto(url, wait_until="domcontentloaded", timeout=20000)
            elements = page.query_selector_all(selector) if selector else []
            results = []
            for el in elements[:100]:
                if attr == "textContent":
                    results.append(el.text_content() or "")
                else:
                    results.append(el.get_attribute(attr) or "")
            send_json({"ok": True, "results": results})

        elif action == "eval":
            expr = cmd.get("expr", "")
            result = page.evaluate(expr) if expr else None
            send_json({"ok": True, "result": result})

        elif action == "fetchhtml":
            # Anti-block fetch: load the URL on the dedicated scrape page, wait
            # out any Cloudflare/DDoS-Guard challenge, return the unblocked HTML
            # as an 'H' frame. The interactive page is never touched.
            url = cmd.get("url", "")
            wait_ms = cmd.get("wait", 15000)
            if not url:
                send_json({"event": "fetchhtml", "error": "no url"})
                return True
            try:
                sp = get_scrape_page(page, scrape)
                sp.goto(url, wait_until="domcontentloaded", timeout=25000)
            except Exception as e:
                send_json({"event": "fetchhtml", "error": str(e)[:180]})
                return True
            html = wait_for_challenge_clear(sp, wait_ms)
            send_html_frame(html.encode("utf-8", "replace"))

        elif action == "fetchapi":
            # Read a JSON/text API from the trusted (cookie-bearing) scrape page
            # context — so an API behind the same Cloudflare zone succeeds once
            # the site's challenge has been cleared. Result returns as an 'H'
            # frame too (same await path on the Zig side).
            url = cmd.get("url", "")
            if not url:
                send_json({"event": "fetchhtml", "error": "no url"})
                return True
            try:
                sp = get_scrape_page(page, scrape)
                text = sp.evaluate(
                    "u => fetch(u, {credentials: 'include'}).then(r => r.text())", url
                ) or ""
            except Exception as e:
                send_json({"event": "fetchhtml", "error": str(e)[:180]})
                return True
            send_html_frame(text[:MAX_SCRAPE_BYTES].encode("utf-8", "replace"))

        elif action == "quit":
            send_json({"ok": True, "bye": True})
            return False

        else:
            send_json({"error": f"unknown cmd: {action}"})

    except Exception as e:
        send_json({"error": str(e)[:200]})

    return True


def extensions_dir():
    """CaptchaSonic extension dir (paths.zig migrates pre-rename installs to
    ~/.config/opal before anything can spawn this bridge)."""
    d = pathlib.Path.home() / ".config/opal/extensions/captchasonic"
    return d if d.is_dir() else None


def parse_engine(argv):
    """Extract the --engine value from argv; unknown/missing → camoufox."""
    engine = "camoufox"
    if "--engine" in argv:
        i = argv.index("--engine")
        if i + 1 < len(argv):
            engine = argv[i + 1]
    return engine if engine in ("camoufox", "cloakbrowser") else "camoufox"


def launch_engine(engine):
    """Launch the selected engine. Returns (browser, close_fn).

    Both engines are drop-in Playwright API providers, so run_session() is
    engine-agnostic. An ImportError here means the package isn't installed —
    surface it through the protocol (the Zig side shows it) and exit.
    """
    if engine == "cloakbrowser":
        try:
            from cloakbrowser import launch
        except ImportError:
            send_json({"error": "cloakbrowser not installed — install it in Settings"})
            sys.exit(1)
        # Free tier; first launch downloads the ~200MB Chromium binary (cached).
        browser = launch(headless=True, humanize=True)

        def close():
            try:
                browser.close()
            except Exception:
                pass

        return browser, close

    try:
        from camoufox.sync_api import Camoufox
    except ImportError:
        send_json({"error": "camoufox not installed — install it in Settings"})
        sys.exit(1)
    ext = extensions_dir()
    addons = [str(ext)] if ext else []
    cm = Camoufox(headless=True, addons=addons)
    browser = cm.__enter__()

    def close():
        try:
            cm.__exit__(None, None, None)
        except Exception:
            pass

    return browser, close


def main():
    engine = parse_engine(sys.argv)
    viewport = [1280, 720]

    sys.stderr.write(f"[browser-bridge] Starting {engine}...\n")
    sys.stderr.flush()

    browser, close = launch_engine(engine)
    try:
        run_session(browser, viewport)
    finally:
        close()


def run_session(browser, viewport):
    """The engine-agnostic protocol loop — one copy for both engines."""
    cmd_q = queue.Queue()

    page = browser.new_page()
    page.set_viewport_size({"width": viewport[0], "height": viewport[1]})
    page.set_default_timeout(30000)

    # Popups (target=_blank, window.open) fold back into the single pane:
    # the handler only records (popup, first_seen) — the main loop
    # navigates, since Playwright sync objects must stay on this thread's
    # control flow. Folding is DEFERRED until the popup's navigation
    # commits (its url is "about:blank" for the first ticks) or 3s pass.
    popups = []
    try:
        page.context.on("page", lambda p: popups.append((p, time.monotonic())))
    except Exception:
        pass

    # Download interception: the handler only RECORDS the Download object —
    # the main loop forwards {"event":"download",...} to Zig (which hands it
    # to Opal's downloader) and cancels the in-browser transfer.
    downloads = []
    try:
        page.on("download", lambda d: downloads.append(d))
    except Exception:
        pass

    sys.stderr.write("[browser-bridge] Browser ready.\n")
    sys.stderr.flush()

    send_json({"ready": True})

    t = threading.Thread(target=stdin_reader, args=(cmd_q,), daemon=True)
    t.start()

    pump = Pump()
    # Dedicated anti-block scrape context/page (created lazily on first
    # fetchhtml/fetchapi) — isolated from the interactive `page` above.
    scrape = {}
    running = True
    eof = False

    while running and not eof:
        timeout = pump.seconds_until_due()
        try:
            cmd = cmd_q.get(timeout=timeout) if timeout is not None else cmd_q.get()
        except queue.Empty:
            cmd = "tick"

        if cmd is None:
            break  # stdin EOF, nothing pending

        if cmd != "tick":
            # Drain bursts (scroll storms) before capturing, coalescing
            # consecutive scrolls into one wheel call. An EOF sentinel in
            # the drain only STOPS further reads — commands already
            # dequeued still execute (a final eval/quit written right
            # before stdin closed must not be dropped).
            batch = [cmd]
            while True:
                try:
                    nxt = cmd_q.get_nowait()
                except queue.Empty:
                    break
                if nxt is None:
                    eof = True
                    break
                batch.append(nxt)

            i = 0
            while i < len(batch) and running:
                c = batch[i]
                if c.get("cmd") == "scroll":
                    dx, dy = c.get("dx", 0), c.get("dy", 0)
                    while i + 1 < len(batch) and batch[i + 1].get("cmd") == "scroll":
                        i += 1
                        dx += batch[i].get("dx", 0)
                        dy += batch[i].get("dy", 0)
                    c = {"cmd": "scroll", "dx": dx, "dy": dy}
                if not apply_command(page, pump, c, viewport, scrape):
                    running = False
                i += 1

        # Fold popups whose navigation has committed; give up after 3s.
        still_pending = []
        for p, seen in popups:
            try:
                purl = p.url
                if purl and purl != "about:blank":
                    p.close()
                    page.goto(purl, wait_until="domcontentloaded", timeout=20000)
                    pump.force_next()
                elif time.monotonic() - seen > 3.0:
                    p.close()
                else:
                    still_pending.append((p, seen))
            except Exception:
                pass
        popups[:] = still_pending

        # Forward intercepted downloads to Zig, then cancel them here —
        # Opal's own downloader takes over from the URL.
        for d in downloads:
            try:
                send_json({
                    "event": "download",
                    "url": d.url or "",
                    "filename": d.suggested_filename or "",
                })
            except Exception:
                pass
            try:
                d.cancel()
            except Exception:
                pass
        downloads[:] = []

        pump.push_page_state(page)
        pump.maybe_capture(page)


def selftest():
    """Protocol framing checks — no camoufox import, safe on any machine."""
    failures = []

    class Sink:
        def __init__(self):
            self.data = b""

        def write(self, b):
            self.data += b

        def flush(self):
            pass

    # J-frame: marker + JSON + newline
    s = Sink()
    send_json({"ready": True}, out=s)
    if not (s.data.startswith(b"J") and s.data.endswith(b"\n")):
        failures.append("send_json framing")
    if json.loads(s.data[1:].decode("utf-8")) != {"ready": True}:
        failures.append("send_json roundtrip")

    # F-frame: marker + 4-byte BE length + payload
    s = Sink()
    payload = b"\xff\xd8jpegdata"
    send_frame(payload, out=s)
    if s.data[:1] != b"F" or struct.unpack(">I", s.data[1:5])[0] != len(payload) or s.data[5:] != payload:
        failures.append("send_frame framing")

    # H-frame (anti-block scrape payload): marker + 4-byte BE length + bytes
    s = Sink()
    html = "<html><body>ok</body></html>".encode("utf-8")
    send_html_frame(html, out=s)
    if s.data[:1] != b"H" or struct.unpack(">I", s.data[1:5])[0] != len(html) or s.data[5:] != html:
        failures.append("send_html_frame framing")

    # Challenge detection: interstitials flagged, real content passes through.
    if not looks_like_challenge("Just a moment...", ""):
        failures.append("challenge detect title")
    if not looks_like_challenge("", "Checking your browser before accessing"):
        failures.append("challenge detect body")
    if looks_like_challenge("My Comic — Chapter 12", "Page 1 of 20"):
        failures.append("challenge false positive")
    if looks_like_challenge("", ""):
        failures.append("challenge empty")

    # fetchhtml/fetchapi arg parsing: url + wait defaulting, no-url error path.
    fc = {"cmd": "fetchhtml", "url": "https://x/y", "wait": 8000}
    if fc.get("cmd") != "fetchhtml" or fc.get("url") != "https://x/y" or fc.get("wait", 15000) != 8000:
        failures.append("fetchhtml arg parse")
    if {"cmd": "fetchhtml"}.get("wait", 15000) != 15000:
        failures.append("fetchhtml wait default")
    if {"cmd": "fetchapi", "url": ""}.get("url", "") != "":
        failures.append("fetchapi no-url")
    if MAX_SCRAPE_BYTES < 1_000_000:
        failures.append("scrape cap too small")

    # Viewport clamping
    if clamp_viewport(0, 0) != (MIN_VIEW_W, MIN_VIEW_H):
        failures.append("clamp min")
    if clamp_viewport(99999, 99999) != (MAX_VIEW_W, MAX_VIEW_H):
        failures.append("clamp max")
    if clamp_viewport("bad", None) != (1280, 720):
        failures.append("clamp bad input")
    if clamp_viewport(1920, 1080) != (1920, 1080):
        failures.append("clamp passthrough")

    # Pump cadence model
    p = Pump()
    if p.interval() != FPS_ACTIVE_INTERVAL:
        failures.append("pump active rate after init")
    p.last_activity -= SETTLE_WINDOW_S + 1
    p.last_change = p.last_activity
    if p.interval() != FPS_IDLE_INTERVAL:
        failures.append("pump idle rate")
    p.last_activity -= IDLE_STOP_S
    p.last_change = p.last_activity
    if p.interval() is not None:
        failures.append("pump idle stop")
    p.poke()
    if p.interval() != FPS_ACTIVE_INTERVAL:
        failures.append("pump reactivate")

    # Engine argv parsing — unknown engines must fall back, never crash.
    if parse_engine(["x"]) != "camoufox":
        failures.append("engine default")
    if parse_engine(["x", "--engine", "cloakbrowser"]) != "cloakbrowser":
        failures.append("engine cloakbrowser")
    if parse_engine(["x", "--engine", "camoufox"]) != "camoufox":
        failures.append("engine camoufox")
    if parse_engine(["x", "--engine", "netscape"]) != "camoufox":
        failures.append("engine unknown fallback")
    if parse_engine(["x", "--engine"]) != "camoufox":
        failures.append("engine missing value")

    # Capture rate gate: fresh pump is due immediately; after an attempt the
    # next capture waits out the active interval.
    p2 = Pump()
    if p2.seconds_until_due() != 0.0:
        failures.append("pump due at init")
    p2.last_attempt = time.monotonic()
    due = p2.seconds_until_due()
    if due is None or not (0.0 < due <= FPS_ACTIVE_INTERVAL):
        failures.append("pump rate gate")
    p2.last_activity -= IDLE_STOP_S + SETTLE_WINDOW_S + 1
    p2.last_change = p2.last_activity
    if p2.seconds_until_due() is not None:
        failures.append("pump due when idle-stopped")

    if failures:
        sys.stderr.write("selftest FAIL: " + ", ".join(failures) + "\n")
        return 1
    print("selftest ok")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
    except Exception as e:
        sys.stderr.write(f"[browser-bridge] Fatal: {e}\n")
        sys.exit(1)
