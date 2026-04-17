#!/usr/bin/env python3
"""
Camoufox Bridge — persistent daemon for ZigZag browser integration.

Protocol (stdin → stdout, binary):
  Commands: JSON lines on stdin
  Responses: 'J' + JSON line  or  'F' + 4-byte big-endian length + JPEG data

Every interaction (navigate, click, scroll, type, keypress) automatically
sends a fresh screenshot frame back — no separate screencast thread needed.
"""

import sys, json, struct, time, os, signal, io, pathlib

os.environ.setdefault("PLAYWRIGHT_BROWSERS_PATH", "0")

# Use binary mode for stdout to avoid encoding issues with JPEG frames
stdout_lock = __import__("threading").Lock()
stdout_bin = sys.stdout.buffer


def send_json(obj):
    """Send a JSON response: 'J' marker + JSON + newline."""
    line = json.dumps(obj, ensure_ascii=False) + "\n"
    raw = b"J" + line.encode("utf-8")
    with stdout_lock:
        stdout_bin.write(raw)
        stdout_bin.flush()


def send_frame(data: bytes):
    """Send a binary frame: 'F' + 4-byte big-endian length + JPEG data."""
    header = b"F" + struct.pack(">I", len(data))
    with stdout_lock:
        stdout_bin.write(header + data)
        stdout_bin.flush()


def take_screenshot(page, quality=80):
    """Take a screenshot and send it as a frame."""
    try:
        frame = page.screenshot(type="jpeg", quality=quality)
        send_frame(frame)
    except Exception:
        pass


def main():
    from camoufox.sync_api import Camoufox

    viewport_w = 1280
    viewport_h = 720

    # CaptchaSonic extension — always loaded for captcha bypass
    ext_dir = pathlib.Path.home() / ".config/zigzag/extensions/captchasonic"
    addons = [str(ext_dir)] if ext_dir.is_dir() else []

    sys.stderr.write(f"[camoufox-bridge] Starting Camoufox (addons={len(addons)})...\n")
    sys.stderr.flush()

    with Camoufox(headless=True, addons=addons) as browser:
        page = browser.new_page()
        page.set_viewport_size({"width": viewport_w, "height": viewport_h})
        page.set_default_timeout(30000)

        sys.stderr.write("[camoufox-bridge] Browser ready.\n")
        sys.stderr.flush()

        # Signal readiness to ZigZag
        send_json({"ready": True})

        # Read commands from stdin (line-buffered)
        stdin_reader = io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8")

        while True:
            try:
                line = stdin_reader.readline()
            except (EOFError, ValueError):
                break
            if not line:
                break  # EOF — parent died

            line = line.strip()
            if not line:
                continue

            try:
                cmd = json.loads(line)
            except json.JSONDecodeError:
                send_json({"error": "invalid json"})
                continue

            action = cmd.get("cmd", "")

            try:
                if action == "navigate":
                    url = cmd.get("url", "")
                    if url:
                        page.goto(url, wait_until="domcontentloaded", timeout=20000)
                        title = page.title() or ""
                        final_url = page.url or url
                        send_json({"ok": True, "title": title, "url": final_url})
                        # Auto-send screenshot after navigation
                        time.sleep(0.3)  # let page settle
                        take_screenshot(page)
                    else:
                        send_json({"error": "no url"})

                elif action == "screenshot":
                    w = cmd.get("w", viewport_w)
                    h = cmd.get("h", viewport_h)
                    if w != viewport_w or h != viewport_h:
                        page.set_viewport_size({"width": w, "height": h})
                        viewport_w, viewport_h = w, h
                    take_screenshot(page, quality=80)

                elif action == "click":
                    x, y = cmd.get("x", 0), cmd.get("y", 0)
                    button = cmd.get("button", "left")
                    page.mouse.click(x, y, button=button)
                    time.sleep(0.2)
                    take_screenshot(page)

                elif action == "dblclick":
                    x, y = cmd.get("x", 0), cmd.get("y", 0)
                    page.mouse.dblclick(x, y)
                    time.sleep(0.2)
                    take_screenshot(page)

                elif action == "scroll":
                    dx, dy = cmd.get("dx", 0), cmd.get("dy", 0)
                    page.mouse.wheel(dx, dy)
                    time.sleep(0.1)
                    take_screenshot(page, quality=75)

                elif action == "mousemove":
                    x, y = cmd.get("x", 0), cmd.get("y", 0)
                    page.mouse.move(x, y)
                    # No auto-screenshot for mousemove (too frequent)

                elif action == "type":
                    text = cmd.get("text", "")
                    page.keyboard.type(text, delay=0)
                    time.sleep(0.1)
                    take_screenshot(page)

                elif action == "keypress":
                    key = cmd.get("key", "")
                    if key:
                        page.keyboard.press(key)
                    time.sleep(0.15)
                    take_screenshot(page)

                elif action == "back":
                    page.go_back()
                    title = page.title() or ""
                    send_json({"ok": True, "title": title, "url": page.url})
                    time.sleep(0.3)
                    take_screenshot(page)

                elif action == "forward":
                    page.go_forward()
                    title = page.title() or ""
                    send_json({"ok": True, "title": title, "url": page.url})
                    time.sleep(0.3)
                    take_screenshot(page)

                elif action == "resize":
                    w, h = cmd.get("w", 1280), cmd.get("h", 720)
                    page.set_viewport_size({"width": w, "height": h})
                    viewport_w, viewport_h = w, h
                    send_json({"ok": True})
                    take_screenshot(page)

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
                    break

                else:
                    send_json({"error": f"unknown cmd: {action}"})

            except Exception as e:
                err_msg = str(e)[:200]
                send_json({"error": err_msg})


if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
    except Exception as e:
        sys.stderr.write(f"[camoufox-bridge] Fatal: {e}\n")
        sys.exit(1)
