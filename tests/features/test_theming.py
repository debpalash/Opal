"""Auto-split from tests/test_features.py — Theming / UI Standards / Browser tests.
Byte-for-byte identical test bodies; see tests/features/harness.py for the
shared @test decorator, helpers, and run_all()."""
from .harness import *  # noqa: F401,F403
import os, sys, subprocess, sqlite3, socket, time, json  # noqa: F401
import re


@test("Small theme text stays readable on raised surfaces", "Theming")
def test_theme_caption_contrast():
    # Check the shipped tokens directly: captions use these opaque colors, so
    # testing a second copied palette would miss future theme regressions.
    with open(os.path.join(PROJECT_DIR, "src/ui/theme.zig")) as f:
        content = f.read()

    def luminance(rgb):
        def linear(value):
            value /= 255
            return value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4
        return sum(linear(v) * weight for v, weight in zip(rgb, (0.2126, 0.7152, 0.0722)))

    palettes = re.findall(r"const (\w+)_colors = ThemeColors\{(.*?)\n\};", content, re.S)
    if len(palettes) != 7:
        return "fail", f"Expected seven shipped palettes, found {len(palettes)}"
    failures = []
    for name, body in palettes:
        colors = {key: tuple(map(int, values)) for key, *values in re.findall(
            r"\.(\w+) = \.\{ \.r = (\d+), \.g = (\d+), \.b = (\d+)", body)}
        for text in ("text_primary", "text_secondary", "text_tertiary"):
            for background in ("bg_app", "bg_surface", "bg_pressed", "bg_hover", "bg_elevated", "bg_selected"):
                foreground_lum, background_lum = luminance(colors[text]), luminance(colors[background])
                ratio = (max(foreground_lum, background_lum) + 0.05) / (min(foreground_lum, background_lum) + 0.05)
                if ratio < 4.5:
                    failures.append(f"{name}.{text}/{background}: {ratio:.2f}:1")
    return ("fail", "; ".join(failures)) if failures else ("pass", "126 shipped text/surface pairs meet 4.5:1")

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
        "settings picker + per-engine status": ('"Browser engine"' in st
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


@test("Every widget follows the active theme (no bare-options dvui widgets)", "Theming")
def test_no_unthemed_widgets():
    """RULE (CLAUDE.md): a raw dvui widget with empty options paints with dvui's
    built-in palette, not Opal's — near-invisible text on dark presets, and it
    ignores theme switching. Use the themed helpers in ui/components.zig.

    Regression: the Settings > Web UI page shipped six bare dvui.button calls
    whose labels were unreadable on every dark preset."""
    import re, os
    # Bare options = both the widget-opts and layout-opts structs empty.
    bare = re.compile(r"dvui\.(button|buttonIcon)\([^;]*?\.\{\},\s*\.\{\}\)", re.S)
    offenders = []
    for root, _dirs, files in os.walk(os.path.join(PROJECT_DIR, "src")):
        for f in files:
            if not f.endswith(".zig"):
                continue
            path = os.path.join(root, f)
            rel = os.path.relpath(path, PROJECT_DIR)
            for i, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
                # Doc comments legitimately quote the anti-pattern.
                if line.lstrip().startswith("//"):
                    continue
                if bare.search(line):
                    offenders.append(f"{rel}:{i}")
    if offenders:
        return "fail", "unthemed widgets (use components.actionButton/iconButton): " + ", ".join(offenders[:8])
    return "pass", "no bare-options dvui widgets — all buttons route through themed helpers"


def _font_codepoints(path):
    """Codepoints covered by a TrueType font's cmap (formats 4 and 12)."""
    import struct
    data = open(path, "rb").read()
    num_tables = struct.unpack(">H", data[4:6])[0]
    base = None
    for i in range(num_tables):
        tag, _cs, off, _ln = struct.unpack(">4sIII", data[12 + 16 * i:28 + 16 * i])
        if tag == b"cmap":
            base = off
    cps = set()
    if base is None:
        return cps
    n = struct.unpack(">H", data[base + 2:base + 4])[0]
    for i in range(n):
        _pid, _eid, off = struct.unpack(">HHI", data[base + 4 + 8 * i:base + 12 + 8 * i])
        o = base + off
        fmt = struct.unpack(">H", data[o:o + 2])[0]
        if fmt == 4:
            segx2 = struct.unpack(">H", data[o + 6:o + 8])[0]
            segs = segx2 // 2
            ends = struct.unpack(">%dH" % segs, data[o + 14:o + 14 + segx2])
            starts = struct.unpack(">%dH" % segs, data[o + 16 + segx2:o + 16 + 2 * segx2])
            for a, b in zip(starts, ends):
                cps.update(range(a, b + 1))
        elif fmt == 12:
            groups = struct.unpack(">I", data[o + 12:o + 16])[0]
            for g in range(groups):
                a, b, _ = struct.unpack(">III", data[o + 16 + 12 * g:o + 28 + 12 * g])
                cps.update(range(a, b + 1))
    return cps


@test("UI strings only use glyphs the UI font has (no tofu)", "Theming")
def test_no_tofu_glyphs():
    """RULE (CLAUDE.md): symbols like ▶ ● ← → ✕ ⟳ ▾ are absent from the UI font
    (Noto Sans) and render as tofu boxes. Use a lucide icon beside the label.

    Regression: Drama "← Back"/"▶ Play", Transfers "← Up", the resume prompt's
    "✕", ProjectJAV "●"/"⟳", Comics "▾ Load more", and "Settings → X" hints."""
    import re
    cps = _font_codepoints(os.path.join(PROJECT_DIR, "src/assets/fonts/NotoSans-Regular.ttf"))
    if len(cps) < 1000:
        return "fail", "could not read NotoSans cmap"

    def cjk(ch):
        o = ord(ch)
        return (0x1100 <= o <= 0x11FF or 0x2E80 <= o <= 0x9FFF or 0xAC00 <= o <= 0xD7AF
                or 0xF900 <= o <= 0xFAFF or 0xFF00 <= o <= 0xFFEF)

    # JSON/HTTP code paths never reach the UI font.
    skip_files = ("remote.zig", "remote_http.zig", "mcp_main.zig")
    lit = re.compile(r'"((?:[^"\\]|\\.)*)"')
    offenders = []
    for root, _dirs, files in os.walk(os.path.join(PROJECT_DIR, "src")):
        for f in files:
            if not f.endswith(".zig") or f in skip_files or f.endswith("_pure.zig") or "_test" in f:
                continue
            path = os.path.join(root, f)
            rel = os.path.relpath(path, PROJECT_DIR)
            for i, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
                if line.lstrip().startswith("//"):
                    continue
                for m in lit.finditer(line):
                    text = m.group(1)
                    # \u{XXXX} escapes count too.
                    text += "".join(chr(int(h, 16)) for h in re.findall(r"\\u\{([0-9a-fA-F]+)\}", text))
                    bad = sorted({ch for ch in text if ord(ch) > 127 and ord(ch) not in cps and not cjk(ch)})
                    if bad:
                        offenders.append(f"{rel}:{i} {''.join(bad)}")
    if offenders:
        return "fail", "glyphs missing from UI font (use a lucide icon): " + ", ".join(offenders[:8])
    return "pass", f"every UI string literal renders in Noto Sans ({len(cps)} codepoints)"


@test("Transparent-fill buttons give hover/press feedback", "Theming")
def test_transparent_buttons_hover():
    """dvui derives hover/press by lightening color_fill, and lighten(transparent)
    is still transparent — a transparent button with no explicit
    color_fill_hover gives zero pointer feedback.

    Regression: ~90 icon/text buttons (Transfers row actions, Queue, Jellyfin,
    header omnibox icons, AI chat, playlist panel…) did nothing on hover."""
    import re
    call = re.compile(r"dvui\.(button|buttonIcon)\(@src\(\)")
    transparent = re.compile(r"\.color_fill = (?:dvui\.Color\{ \.r = 0, \.g = 0, \.b = 0, \.a = 0 \}|theme\.transparent|transparent|invisible|dvui\.Color\.transparent)\s*,")
    offenders = []
    for root, _dirs, files in os.walk(os.path.join(PROJECT_DIR, "src")):
        for f in files:
            if not f.endswith(".zig") or "_test" in f:
                continue
            path = os.path.join(root, f)
            src = open(path, encoding="utf-8", errors="replace").read()
            for m in call.finditer(src):
                depth, j = 0, src.index("(", m.start())
                while True:
                    ch = src[j]
                    if ch == "(":
                        depth += 1
                    elif ch == ")":
                        depth -= 1
                        if depth == 0:
                            break
                    j += 1
                body = src[m.start():j]
                # A full-card invisible hit target (label "" + expand .both)
                # sits over artwork; filling it on hover would hide the card.
                if '"", .{}, .{' in body and ".expand = .both" in body:
                    continue
                if transparent.search(body) and "color_fill_hover" not in body:
                    rel = os.path.relpath(path, PROJECT_DIR)
                    offenders.append(f"{rel}:{src.count(chr(10), 0, m.start()) + 1}")
    if offenders:
        return "fail", f"{len(offenders)} transparent buttons without color_fill_hover: " + ", ".join(offenders[:8])
    return "pass", "every transparent-fill button sets an explicit hover fill"


@test("Labels on accent fills use text_on_accent, not white", "Theming")
def test_accent_text_contrast():
    """Every preset pairs its accent with a dark text_on_accent. Hardcoded
    dvui.Color.white on an accent fill (Plugins Install, Comics/Anime/TMDB
    active chips, RSS/VNDB/Plex primary buttons…) was low-contrast and
    inconsistent with actionButton(.primary)."""
    import re
    opt = re.compile(r"\.color_fill = (if \(([^)]*)\) )?theme\.colors\.accent\b[^\n]*\n\s*(?:\.color_fill_\w+ = [^\n]*\n\s*)*\.color_text = (if \(([^)]*)\) )?dvui\.Color\.white")
    offenders = []
    for root, _dirs, files in os.walk(os.path.join(PROJECT_DIR, "src")):
        for f in files:
            if not f.endswith(".zig") or "_test" in f or f in ("browser.zig", "wanted_ui.zig"):
                continue
            path = os.path.join(root, f)
            src = open(path, encoding="utf-8", errors="replace").read()
            for m in opt.finditer(src):
                if (m.group(2) or "") == (m.group(4) or ""):
                    offenders.append(f"{os.path.relpath(path, PROJECT_DIR)}:{src.count(chr(10), 0, m.start()) + 1}")
    if offenders:
        return "fail", "white text on accent fill (use theme.colors.text_on_accent): " + ", ".join(offenders[:8])
    return "pass", "accent fills carry text_on_accent"


@test("dvui style palettes map onto the active preset", "Theming")
def test_dvui_styles_follow_preset():
    """theme.applyToDvui must override dvui's per-style palettes. Left at the
    Adwaita defaults, menu-item hovers and checkbox ticks painted Adwaita blue
    and a button with only color_fill set fell back to Adwaita control colors.
    Also guards the primary actionButton hover: it used bg_hover under
    text_on_accent, so the label vanished under the pointer."""
    with open(os.path.join(PROJECT_DIR, "src/ui/theme.zig")) as f:
        theme_src = f.read()
    body = theme_src.split("fn applyToDvui", 1)[-1].split("\n}\n", 1)[0]
    missing = [s for s in ("t.control", "t.window", "t.highlight", "t.err") if s not in body]
    with open(os.path.join(PROJECT_DIR, "src/ui/components.zig")) as f:
        comp = f.read()
    fills = comp.split("fn actionFills", 1)
    if len(fills) < 2:
        missing.append("components.actionFills")
    else:
        primary = fills[1].split("}", 1)[0]
        if "bg_hover" in primary or "accent_primary" not in primary:
            missing.append("primary hover must stay on the accent hue")
        for fn in ("pub fn actionButton", "pub fn iconActionButton"):
            seg = comp.split(fn, 1)[-1].split("\npub fn", 1)[0]
            if "actionFills(" not in seg:
                missing.append(f"{fn.split()[-1]} not routed through actionFills")
    if missing:
        return "fail", "; ".join(missing)
    return "pass", "control/window/highlight/err styles + action button fills follow the preset"


@test("Web search-row buttons are 40px tap targets", "Theming")
def test_web_search_row_tap_targets():
    """Regression: bare buttons in .search-row (Go/Ask/Add, Logs Refresh/Clear,
    Plex sign-in) were unstyled text, measured 20x40 / 22px tall at 375px."""
    import re
    css = open(os.path.join(PROJECT_DIR, "web/styles/app.css"), encoding="utf-8").read()
    m = re.search(r"\.search-row>button\{([^}]*)\}", css)
    if not m:
        return "fail", "no .search-row>button rule in web/styles/app.css"
    body = m.group(1)
    h = re.search(r"min-height:(\d+)px", body)
    w = re.search(r"min-width:(\d+)px", body)
    if not h or int(h.group(1)) < 40 or not w or int(w.group(1)) < 40:
        return "fail", ".search-row>button must set min-width/min-height >= 40px"
    blk = re.search(r"@media \(pointer:coarse\),\(max-width:599px\)\{(.*?)\n\}", css, re.S)
    if not blk:
        return "fail", "no phone/touch tap-target @media block"
    need = [".card .jf-card-actions button", ".result .m button", ".search-sort select",
            ".browse-filters select", ".chips button", ".sect.fold", ".open-media summary",
            ".source-manager summary",
            # measured 34-37px at 375/390 before the phone override (watch cards/toolbar, queue rows)
            ".watch-actions button", ".watch-actions select", ".watch-view-controls select",
            ".watch-view-controls button", ".queue-actions button", ".transfer-actions button",
            "input[type=range]",
            # live search cards: titles 19/38px, release-shelf summary 36px at 375/390
            ".search-card-title", ".search-release-shelf>summary",
            # folded-source expander on search cards (summary is not a button)
            ".search-row-sources>summary"]
    rules = re.findall(r"([^{}]+)\{([^}]*)\}", blk.group(1))
    missing = [sel for sel in need if not any(sel in [x.strip() for x in sels.split(",")]
               and re.search(r"(min-height|height):(4\d|[5-9]\d)px", body) for sels, body in rules)]
    if missing:
        return "fail", "phone tap targets < 40px: " + ", ".join(missing)
    return "pass", ".search-row + card/select/chip/fold/summary tap targets >= 40px on touch"


@test("Web CSS only references defined custom properties", "Theming")
def test_web_css_vars_defined():
    """An undefined var() silently falls back (inherit / transparent). Regression:
    the active destination button used var(--bg) — light text on the light
    accent — and the YouTube embed bar used var(--bg-1) (no background)."""
    import re, glob
    sources = [os.path.join(PROJECT_DIR, "web/index.html")]
    sources += glob.glob(os.path.join(PROJECT_DIR, "web/styles/*.css"))
    sources += glob.glob(os.path.join(PROJECT_DIR, "web/js/*.js"))
    text = "".join(open(p, encoding="utf-8", errors="replace").read() for p in sources)
    defined = set(re.findall(r"(--[\w-]+)\s*:", text)) | set(re.findall(r"setProperty\(\s*'(--[\w-]+)'", text))
    undefined = sorted({name for name, fallback in re.findall(r"var\((--[\w-]+)\s*(,)?", text)
                        if name not in defined and not fallback})
    if undefined:
        return "fail", "undefined CSS custom properties: " + ", ".join(undefined)
    return "pass", f"{len(defined)} custom properties, all references resolve"


@test("Theme colors are read per-frame, not cached at module scope", "Theming")
def test_no_hardcoded_ui_colors():
    """A `const c = theme.colors.x` at module scope freezes the color at load,
    so switching theme leaves stale colors behind. Raw Color literals in UI code
    are the same problem — they exist in exactly one preset's palette."""
    import re, os
    lit = re.compile(r"dvui\.Color\{\s*\.r\s*=")
    offenders = []
    for root, _dirs, files in os.walk(os.path.join(PROJECT_DIR, "src", "ui")):
        for f in files:
            if not f.endswith(".zig"):
                continue
            path = os.path.join(root, f)
            rel = os.path.relpath(path, PROJECT_DIR)
            for i, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
                if line.lstrip().startswith("//"):
                    continue
                # theme.zig IS the palette; transparent is colorless by design.
                if rel.endswith("theme.zig") or ".a = 0 }" in line or "transparent" in line:
                    continue
                if lit.search(line):
                    offenders.append(f"{rel}:{i}")
    if offenders:
        return "warn", f"{len(offenders)} raw Color literal(s) in ui/ — prefer theme.colors.*: " + ", ".join(offenders[:6])
    return "pass", "no raw Color literals in ui/ — colors come from theme.colors.*"


@test("Text on accent fills meets WCAG AA in every preset", "Theming")
def test_on_accent_contrast():
    # text_on_accent labels every accent-filled button/chip and dvui's
    # highlighted menu rows. Solarized's dark ink landed at 2.97:1 on its
    # muted-orange accent; every preset must clear 4.5:1.
    src = _src("src/ui/theme.zig")

    def lum(c):
        def ch(v):
            v /= 255
            return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
        return 0.2126 * ch(c[0]) + 0.7152 * ch(c[1]) + 0.0722 * ch(c[2])

    low, seen = [], 0
    for m in re.finditer(r"const (\w+)_colors = ThemeColors\{(.*?)\n\};", src, re.S):
        def color(key):
            hit = re.search(r"\." + key + r" = \.\{ \.r = (\d+), \.g = (\d+), \.b = (\d+)", m.group(2))
            return tuple(map(int, hit.groups())) if hit else None
        fg, bg = color("text_on_accent"), color("accent")
        if not fg or not bg:
            continue
        seen += 1
        a, b = sorted((lum(fg), lum(bg)), reverse=True)
        ratio = (a + 0.05) / (b + 0.05)
        if ratio < 4.5:
            low.append(f"{m.group(1)} {ratio:.2f}:1")
    if seen == 0:
        return "fail", "no presets parsed from theme.zig"
    if low:
        return "fail", "text_on_accent below 4.5:1 on accent: " + ", ".join(low)
    return "pass", f"{seen} presets clear 4.5:1 on accent fills"


@test("Web phone tap targets hold in a real browser", "Theming")
def test_web_tap_targets_live_wired():
    """The CSS check above proves the rules exist; tests/test_web_tap_targets_live.py
    proves they win in a rendered page. It needs Chromium, so CI runs it in the
    browser-dom job — this keeps that step from being dropped."""
    ci = _src(".github/workflows/ci.yml")
    if "python3 tests/test_web_tap_targets_live.py --chromium" not in ci:
        return "fail", "browser-dom CI job no longer runs the live tap-target test"
    if not os.path.exists(os.path.join(PROJECT_DIR, "tests", "test_web_tap_targets_live.py")):
        return "fail", "tests/test_web_tap_targets_live.py is missing"
    return "pass", "browser-dom CI renders search, Jellyfin, Plex and show surfaces at 375/390px"



def _palettes():
    """{preset: {token: (r,g,b,a)}} parsed from the shipped theme.zig."""
    src = _src("src/ui/theme.zig")
    out = {}
    for name, body in re.findall(r"const (\w+)_colors = ThemeColors\{(.*?)\n\};", src, re.S):
        out[name] = {k: tuple(map(int, v)) for k, *v in re.findall(
            r"\.(\w+) = \.\{ \.r = (\d+), \.g = (\d+), \.b = (\d+), \.a = (\d+)", body)}
    return out


def _ratio(a, b):
    def lum(c):
        def ch(v):
            v /= 255
            return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
        return 0.2126 * ch(c[0]) + 0.7152 * ch(c[1]) + 0.0722 * ch(c[2])
    x, y = sorted((lum(a), lum(b)), reverse=True)
    return (x + 0.05) / (y + 0.05)


@test("Theme surfaces give distinct rest/hover/pressed/selected states", "Theming")
def test_theme_state_ladder():
    """Regression: bg_hover == bg_elevated in every preset, so hovering a raised
    control gave no feedback and components hand-rolled lighten(6) offsets."""
    pals = _palettes()
    if len(pals) != 7:
        return "fail", f"expected 7 palettes, parsed {len(pals)}"
    bad = []
    for name, c in pals.items():
        ladder = [c[k][:3] for k in ("bg_app", "bg_surface", "bg_pressed", "bg_elevated", "bg_hover")]
        lums = [_ratio(x, (0, 0, 0)) for x in ladder]
        if any(b <= a for a, b in zip(lums, lums[1:])):
            bad.append(f"{name}: app<surface<pressed<elevated<hover not strictly increasing")
        if c["bg_selected"][:3] in ladder:
            bad.append(f"{name}: bg_selected duplicates a neutral step")
        if c["accent_hover"] == c["accent"] or c["accent_pressed"] == c["accent"]:
            bad.append(f"{name}: accent hover/pressed not distinct")
    return ("fail", "; ".join(bad)) if bad else ("pass", "7 presets: 5-step ladder + selected + accent states distinct")


@test("Accent, focus ring and semantic tokens meet WCAG in every preset", "Theming")
def test_theme_semantic_contrast():
    """text_on_accent must survive hover/pressed fills (4.5:1); accent glyphs and
    the focus ring are non-text UI (3:1 on bg_surface); status pills put the
    semantic fg on its *_bg (4.5:1)."""
    low = []
    for name, c in _palettes().items():
        g = lambda k: c[k][:3]
        for fill in ("accent", "accent_hover", "accent_pressed"):
            if _ratio(g("text_on_accent"), g(fill)) < 4.5:
                low.append(f"{name}.text_on_accent/{fill}")
        for k in ("accent", "focus_ring"):
            if _ratio(g(k), g("bg_surface")) < 3.0:
                low.append(f"{name}.{k}/bg_surface")
        for sem in ("danger", "success", "warning"):
            if _ratio(g(sem), g(sem + "_bg")) < 4.5:
                low.append(f"{name}.{sem}/{sem}_bg")
    return ("fail", ", ".join(low)) if low else ("pass", "on-accent x3, accent+focus 3:1, semantic/_bg 4.5:1 in 7 presets")


@test("Web theme mirrors every native preset", "Theming")
def test_web_theme_presets():
    """The web UI paints with the desktop's preset: app.css has one token block
    per theme.zig preset (midnight = :root) with the native accent/surfaces, and
    core.js applies the preset from /api/settings."""
    css = _src("web/styles/app.css")
    core = _src("web/js/core.js")
    pals = _palettes()
    hx = lambda c: "#%02x%02x%02x" % c[:3]
    bad = []
    blocks = {}
    for sel, body in re.findall(r"(:root(?:\[data-theme=\"\w+\"\])?)\{([^}]*)\}", css):
        m = re.search(r'"(\w+)"', sel)
        name = m.group(1) if m else "midnight"
        if "--accent:" in body:
            blocks[name] = dict(re.findall(r"(--[\w-]+):([^;]+);", body))
    for name, c in pals.items():
        b = blocks.get(name)
        if not b:
            bad.append(f"no CSS block for {name}")
            continue
        for var, tok in (("--accent", "accent"), ("--bg-app", "bg_app"), ("--bg-surface", "bg_surface"),
                         ("--bg-hover", "bg_hover"), ("--text-1", "text_primary"), ("--on-accent", "text_on_accent"),
                         ("--danger-bg", "danger_bg"), ("--focus-ring", "focus_ring")):
            if b.get(var, "").strip().lower() != hx(c[tok]):
                bad.append(f"{name} {var}={b.get(var)} != {hx(c[tok])}")
    keysets = {frozenset(b) for b in blocks.values()}
    if len(keysets) > 1:
        bad.append("preset blocks define different variable sets")
    if "function applyTheme" not in core or "syncThemeFromDesktop()" not in core:
        bad.append("core.js does not apply the desktop preset")
    return ("fail", "; ".join(bad[:6])) if bad else ("pass", f"{len(blocks)} CSS preset blocks match theme.zig")
