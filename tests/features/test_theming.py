"""Auto-split from tests/test_features.py — Theming / UI Standards / Browser tests.
Byte-for-byte identical test bodies; see tests/features/harness.py for the
shared @test decorator, helpers, and run_all()."""
from .harness import *  # noqa: F401,F403
import os, sys, subprocess, sqlite3, socket, time, json  # noqa: F401

@test("Theme Presets Defined", "Theming")
def test_theme_presets():
    theme_file = os.path.join(PROJECT_DIR, "src/ui/theme.zig")
    if not os.path.exists(theme_file):
        return "fail", "theme.zig not found"
    with open(theme_file) as f:
        content = f.read()
    presets = []
    for name in ["midnight", "abyss", "phantom", "nord", "solarized", "rose", "ember"]:
        if f".{name}" in content or f'"{name}"' in content:
            presets.append(name)
    if len(presets) == 7:
        return "pass", f"7 presets: {', '.join(presets)}"
    return "warn", f"Only {len(presets)}/7 presets found"


@test("Theme Cycle Function", "Theming")
def test_theme_cycle():
    theme_file = os.path.join(PROJECT_DIR, "src/ui/theme.zig")
    with open(theme_file) as f:
        content = f.read()
    if "pub fn cycleTheme" in content and "pub fn setPreset" in content:
        return "pass", "cycleTheme + setPreset defined"
    return "fail", "Missing theme functions"


@test("Icon Size System", "Theming")
def test_icon_sizes():
    theme_file = os.path.join(PROJECT_DIR, "src/ui/theme.zig")
    with open(theme_file) as f:
        content = f.read()
    if "pub const IconSize" in content and "pub fn iconSize" in content:
        return "pass", "IconSize enum + iconSize() defined"
    return "fail", "Missing icon size system"


@test("Theme Palette Button", "Theming")
def test_palette_button():
    # Palette cycle button lives in the header toolbar (header.zig),
    # wired to theme.cycleTheme().
    header_file = os.path.join(PROJECT_DIR, "src/ui/header.zig")
    with open(header_file) as f:
        content = f.read()
    if "palette" in content and "cycleTheme" in content:
        return "pass", "Palette button wired to cycleTheme"
    return "fail", "No palette button"


@test("Settings Theme Picker", "Theming")
def test_settings_picker():
    settings_file = os.path.join(PROJECT_DIR, "src/ui/settings.zig")
    with open(settings_file) as f:
        content = f.read()
    if "ThemePreset" in content and "setPreset" in content:
        return "pass", "Theme picker in settings"
    return "fail", "No theme picker in settings"


@test("Compiles: camoufox_bridge.py", "Browser")
def test_camoufox_bridge_compiles():
    path = os.path.join(PROJECT_DIR, "scripts", "camoufox_bridge.py")
    if not os.path.exists(path):
        return "fail", "script missing"
    r = subprocess.run(
        [sys.executable, "-m", "py_compile", path],
        capture_output=True, text=True, timeout=30,
    )
    if r.returncode == 0:
        return "pass", "py_compile OK"
    return "fail", r.stderr[:80]


@test("Bridge protocol selftest", "Browser")
def test_camoufox_bridge_selftest():
    # --selftest exercises J/F frame framing, viewport clamps and the adaptive
    # pump cadence model WITHOUT importing camoufox — runs on any machine.
    path = os.path.join(PROJECT_DIR, "scripts", "camoufox_bridge.py")
    if not os.path.exists(path):
        return "fail", "script missing"
    r = subprocess.run(
        [sys.executable, path, "--selftest"],
        capture_output=True, text=True, timeout=15,
    )
    if r.returncode == 0:
        return "pass", "framing + pump model OK"
    return "fail", (r.stderr or r.stdout).strip()[:80]


@test("Browser bookmarks SQL matches schema", "Browser")
def test_browser_bookmarks_sql():
    # browser.zig persists Browse › Web bookmarks in the browser_bookmarks
    # table. Same source-extracted SQL-vs-schema check as the poster cache —
    # a column rename or SQL typo would silently no-op bookmarks.
    import re
    browser_src = open(os.path.join(PROJECT_DIR, "src/services/browser.zig")).read()
    db_src = open(os.path.join(PROJECT_DIR, "src/core/db.zig")).read()

    lines = db_src.splitlines()
    start = next((i for i, l in enumerate(lines)
                  if "CREATE TABLE IF NOT EXISTS browser_bookmarks" in l), None)
    if start is None:
        return "fail", "browser_bookmarks CREATE TABLE not found in db.zig"
    sql_lines = []
    for l in lines[start:]:
        stripped = l.strip().lstrip("\\")
        sql_lines.append(stripped)
        if stripped == ")":
            break
    create_sql = "\n".join(sql_lines)

    stmts = re.findall(r'"((?:INSERT|SELECT|DELETE)[^"]+browser_bookmarks[^"]*)"', browser_src)
    if len(stmts) < 3:
        return "fail", f"expected >=3 browser_bookmarks statements, found {len(stmts)}"

    conn = sqlite3.connect(":memory:")
    conn.execute(create_sql)
    for sql in stmts:
        n_params = len(set(re.findall(r"\?\d+", sql)))
        params = tuple("x" for _ in range(n_params))
        conn.execute(sql, params)
    conn.close()
    return "pass", f"{len(stmts)} statements OK against schema"


@test("browser_pure registered in zig tests", "Browser")
def test_browser_pure_registered():
    # The smart-address / keypress-forwarding / routing logic must stay in the
    # `zig build test` gate (its tests run via the folded Zig unit suite).
    build_zig = os.path.join(PROJECT_DIR, "build.zig")
    with open(build_zig) as f:
        content = f.read()
    if "browser_pure.zig" in content:
        return "pass", "in build.zig test step"
    return "fail", "browser_pure.zig missing from build.zig"


@test("No Emojis in UI", "UI Standards")
def test_no_emoji():
    # Hard project rule: SVG (lucide TVG) icons only, never emojis. Scans
    # string LITERALS in native .zig (comments + \\x escapes are exempt; test
    # files excluded). Any emoji inside a "..." literal is a UI offender.
    offenders = []
    for root, _, files in os.walk(os.path.join(PROJECT_DIR, "src")):
        for f in files:
            if not f.endswith(".zig") or f.endswith("_test.zig"):
                continue
            p = os.path.join(root, f)
            for i, line in enumerate(open(p, encoding="utf-8").read().splitlines(), 1):
                for lit in _re.findall(r'"[^"\n]*"', line):
                    if _EMOJI.search(lit):
                        rel = os.path.relpath(p, PROJECT_DIR)
                        offenders.append(f"{rel}:{i}")
                        break
    if offenders:
        return "fail", f"{len(offenders)} emoji literal(s): " + ", ".join(offenders[:4])
    return "pass", "no emoji in UI string literals"


@test("Browser: CloakBrowser engine + upgrades", "Browser")
def test_browser_cloak_engine():
    br = _src("src/services/browser.zig")
    bp = _src("src/services/browser_pure.zig")
    py = _src("scripts/camoufox_bridge.py")
    cfg = _src("src/core/config.zig")
    st = _src("src/ui/settings.zig")
    dbz = _src("src/core/db.zig")

    # The bridge must compile and its protocol selftest (incl. --engine
    # parsing) must pass — no browser launch involved.
    bridge_path = os.path.join(PROJECT_DIR, "scripts", "camoufox_bridge.py")
    r = subprocess.run([sys.executable, "-m", "py_compile", bridge_path],
                       capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        return "fail", "bridge py_compile: " + r.stderr[:60]
    r = subprocess.run([sys.executable, bridge_path, "--selftest"],
                       capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        return "fail", "bridge selftest: " + (r.stderr or r.stdout)[:60]

    checks = {
        # ── Part 1: engine option ──
        "engine enum is pure + parsed": ("pub const Engine = enum { camoufox, cloakbrowser }" in bp
                                         and "pub fn engineFromString" in bp
                                         and "pure.Engine" in br),
        "config key round-trips": cfg.count('"browser_engine"') >= 2,
        "settings picker + per-engine status": ('"Browser Engine"' in st
                                                and "CloakBrowser" in st
                                                and "engineReady" in st
                                                and "killBridge" in st),
        "installer branches per engine": ('"--upgrade", pkg' in br
                                          and '"camoufox", "fetch"' in br
                                          and "first launch downloads ~200 MB" in br),
        "bridge handles both engines": ("from cloakbrowser import launch" in py
                                        and "from camoufox.sync_api import Camoufox" in py
                                        and "def parse_engine" in py
                                        and "humanize=True" in py),
        "zig passes engine argv": '"--engine", @tagName(engine)' in br,
        "missing engine surfaces, no hang": ("not installed — install it in Settings" in py
                                             and "if (!bridge_ready.load(.acquire))" in br
                                             and "InstallState.failed" in br),
        # ── Part 2: feature upgrades ──
        "find: prev/next + match count": ('\\"dir\\":\\"{s}\\"' in br
                                          and 'cmd.get("dir", "next")' in py
                                          and '"count": count' in py
                                          and "find_count" in br
                                          and '"No matches"' in br),
        "zoom: per-site persistence": ("browser_zoom" in dbz
                                       and "loadZoomFor" in br
                                       and "saveZoomFor" in br
                                       and "pub fn urlHost" in bp),
        "downloads: intercepted + handed off": ('page.on("download"' in py
                                                and '"event": "download"' in py
                                                and "enqueueBrowserDownload" in br
                                                and "addDownloadHistory" in br
                                                and "pub fn sanitizeFilename" in bp),
        "history: recorded + autocomplete": ("browser_history" in dbz
                                             and "recordVisit" in br
                                             and "pub fn historyMatchScore" in bp
                                             and "pure.historyMatchScore" in br
                                             and "dvui.suggestion(" in br),
        "reader: text overlay": ('"readtext"' in py
                                 and "renderReaderOverlay" in br
                                 and "requestReadText" in br
                                 and "pub fn jsonUnescape" in bp),
        "pure module unit-tested": "browser_pure.zig" in _src("build.zig"),
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing: " + ", ".join(bad)
    return "pass", "engine picker + find/zoom/downloads/history/reader wired"
