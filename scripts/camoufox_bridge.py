#!/usr/bin/env python3
"""
Camoufox Bridge — persistent daemon for the Opal in-app browser.

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


def apply_command(page, pump, cmd, viewport):
    """Execute one command. Returns False when the bridge should exit."""
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
            # repeated calls continue from the last match.
            text = cmd.get("text", "")
            found = False
            if text:
                try:
                    found = bool(page.evaluate(
                        "t => window.find(t, false, false, true)", text))
                except Exception:
                    found = False
            send_json({"ok": True, "found": found})
            pump.poke()

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


def main():
    from camoufox.sync_api import Camoufox

    viewport = [1280, 720]

    ext = extensions_dir()
    addons = [str(ext)] if ext else []

    sys.stderr.write(f"[camoufox-bridge] Starting Camoufox (addons={len(addons)})...\n")
    sys.stderr.flush()

    cmd_q = queue.Queue()

    with Camoufox(headless=True, addons=addons) as browser:
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

        sys.stderr.write("[camoufox-bridge] Browser ready.\n")
        sys.stderr.flush()

        send_json({"ready": True})

        t = threading.Thread(target=stdin_reader, args=(cmd_q,), daemon=True)
        t.start()

        pump = Pump()
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
                    if not apply_command(page, pump, c, viewport):
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
        sys.stderr.write(f"[camoufox-bridge] Fatal: {e}\n")
        sys.exit(1)
