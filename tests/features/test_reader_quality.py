"""Reading quality: bounded page cache, huge-page downscale, spread / RTL /
zoom, server-scoped resume keys, and untrusted CBZ archives + embedded links.

The logic lives in src/services/reader_pure.zig and src/services/cbz_pure.zig
(`zig build test`: test_reader_pure, test_cbz_pure). The CBZ tests run over
generated fixture archives; these checks keep the fixtures reproducible, keep
the native + web readers routed through the tested logic, and hold the theme
rules for the new controls.

See tests/features/harness.py for the shared @test decorator."""
from .harness import *  # noqa: F401,F403

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

FIXTURES = ("reader-good.cbz", "reader-traversal.cbz", "reader-corrupt.cbz", "reader-zip64.cbz", "reader-many.cbz")


@test("CBZ fixture archives regenerate byte-identically", "Reading")
def test_cbz_fixtures_reproducible():
    gen = os.path.join(PROJECT_DIR, "tests", "fixtures", "gen_cbz_fixtures.py")
    committed = os.path.join(PROJECT_DIR, "src", "services", "testdata")
    if not os.path.isfile(gen):
        return "fail", "tests/fixtures/gen_cbz_fixtures.py missing"
    out = tempfile.mkdtemp(prefix="opal-cbz-fixtures-")
    try:
        run = subprocess.run([sys.executable, "-I", gen, out], capture_output=True, text=True, timeout=60)
        if run.returncode != 0:
            return "fail", "generator failed: " + (run.stderr or run.stdout)[-300:]
        problems = []
        for name in FIXTURES:
            ours, theirs = os.path.join(out, name), os.path.join(committed, name)
            if not os.path.isfile(theirs):
                problems.append(f"{name} not committed")
                continue
            with open(ours, "rb") as a, open(theirs, "rb") as b:
                if a.read() != b.read():
                    problems.append(f"{name} differs from a fresh generation")
        if problems:
            return "fail", "; ".join(problems)
        return "pass", f"{len(FIXTURES)} CBZ fixtures match the deterministic generator"
    finally:
        shutil.rmtree(out, ignore_errors=True)


@test("Reader routes through reader_pure / cbz_pure", "Reading")
def test_reader_routes_through_pure():
    build = _src("build.zig")
    comics = _src("src/services/comics.zig")
    cbz = _src("src/services/cbz_pure.zig")
    reader = _src("src/services/reader_pure.zig")
    remote = _src("src/services/remote_comics_api.zig")
    opds = _src("src/services/opds.zig")
    state = _src("src/core/state.zig")
    problems = []

    for mod in ("reader_pure", "cbz_pure"):
        if f'b.path("src/services/{mod}.zig")' not in build or f"test_{mod}" not in build:
            problems.append(f"{mod} not registered in build.zig test step")
    for fn in ("pub fn pickEviction", "pub fn downscaleFactor", "pub fn boxDownscaleInPlace", "pub fn spreadAt",
               "pub fn displayOrder", "pub fn stepPage", "pub fn keyDirection", "pub fn displaySize",
               "pub fn urlResumeKey", "pub fn pseResumeKey", "pub fn sanitizeEntryPath", "pub fn naturalLess",
               "pub fn isSafeLink", "pub fn localArchivePath"):
        if fn not in reader:
            problems.append(f"reader_pure missing {fn}")
    if "reader.sanitizeEntryPath(" not in cbz or "reader.naturalLess(" not in cbz:
        problems.append("cbz_pure does not sanitise / order entries through reader_pure")
    for name in FIXTURES:
        if f'@embedFile("testdata/{name}")' not in cbz:
            problems.append(f"cbz_pure tests do not embed {name}")

    # Native reader: every decision goes through the tested functions.
    wiring = {
        "page cache budget": "reader_pure.pickEviction(",
        "neighbour prefetch": "reader_pure.prefetchAllowed(",
        "huge-page downscale": "reader_pure.boxDownscaleInPlace(",
        "downscale in decode worker": "downscaleHugePage(image)",
        "spread order": "reader_pure.displayOrder(",
        "page stepping": "reader_pure.stepPage(",
        "RTL key mapping": "reader_pure.keyDirection(",
        "zoom sizing": "reader_pure.displaySize(",
        "mode cycle": "reader_pure.nextMode(",
        "URL resume key": "reader_pure.urlResumeKey(",
        "PSE resume key": "reader_pure.pseResumeKey(",
        "placeholder status": "reader_pure.pageStatus(",
        "CBZ open": "cbz_pure.Archive.open(",
        "CBZ page collection": "cbz_pure.collectPages(",
        "corrupt entry placeholder": "markPageFailed(i, gen)",
        "CBZ route": "reader_pure.localArchivePath(url)",
    }
    for label, needle in wiring.items():
        if needle not in comics:
            problems.append(f"comics.zig: {label} not routed ({needle})")
    if comics.count("reader_pure.isSafeLink(") < 5:
        problems.append("comics.zig does not validate every scraped next/prev/page link")
    if "armPendingResume(state.app.comic.title" in comics:
        problems.append("OPDS-PSE resume still keyed on the display title")
    if "view_mode: reader_pure.Mode" not in state or "rtl: bool" not in state or "zoom: f32" not in state:
        problems.append("comic state lacks mode/rtl/zoom")
    if "localArchivePath(comic_url)" not in remote or "403 Forbidden" not in remote:
        problems.append("remote /comics/load does not refuse local archive routes")
    if "isSafeLink(href)" not in opds:
        problems.append("OPDS image hrefs reach the reader unvalidated")

    if problems:
        return "fail", "; ".join(problems)
    return "pass", "cache, downscale, spread/RTL, zoom, resume keys, CBZ + link safety all routed through pure modules"


def _toolbar(comics):
    start = comics.find("pub fn renderReaderToolbar(")
    end = comics.find("pub fn renderPaneContent(", start)
    return comics[start:end] if start >= 0 and end > start else ""


@test("Reader controls follow the theme", "Reading")
def test_reader_controls_themed():
    comics = _src("src/services/comics.zig")
    bar = _toolbar(comics)
    problems = []
    if not bar:
        return "fail", "renderReaderToolbar not found"
    for icon in ('@"columns-2"', '@"rectangle-vertical"', '@"arrow-right-left"', '@"zoom-in"', '@"zoom-out"'):
        if f"icons.tvg.lucide.{icon}" not in bar:
            problems.append(f"toolbar lacks lucide icon {icon}")
    # New controls use the themed readerButton / readerMenuItem helpers.
    for label in ('"Zoom in"', '"Zoom out"', '"Reset zoom"'):
        if label not in bar:
            problems.append(f"toolbar lacks {label}")
    if re.search(r"dvui\.(button|buttonIcon)\([^;]*?\.\{\},\s*\.\{\}\)", bar, re.S):
        problems.append("bare-options dvui button in the reader toolbar")
    if "dvui.Color{" in bar:
        problems.append("hardcoded color in the reader toolbar")
    for lit in re.findall(r'"([^"\\]*(?:\\.[^"\\]*)*)"', bar):
        if any(ord(c) > 127 for c in lit):
            problems.append(f"non-ASCII glyph in toolbar label {lit!r}")
    html = _src("web/index.html")
    m = re.search(r'<div class="search-row cx-view-controls">(.*?)</div>', html, re.S)
    if not m:
        problems.append("web reader view controls missing")
    elif any(ord(c) > 127 for c in m.group(1)):
        problems.append("web reader controls use glyphs instead of words")
    css = _src("web/styles/app.css")
    ctl = "\n".join(line for line in css.splitlines() if "cx-view-controls" in line or "#cx-pages" in line)
    if re.search(r"#[0-9a-fA-F]{3,8}\b", ctl):
        problems.append("web reader CSS hardcodes a color")
    if problems:
        return "fail", "; ".join(problems)
    return "pass", "mode/RTL/zoom controls use themed helpers, lucide icons, no glyphs or literal colors"


@test("Web reader spread / RTL order matches reader_pure", "Reading")
def test_web_reader_parity():
    node = shutil.which("node")
    if not node:
        return "skip", "node not installed"
    media = _src("web/js/media.js")
    start = media.find("const comicView = ")
    end = media.find("function applyComicView(", start)
    if start < 0 or end < 0:
        return "fail", "web reader layout functions missing"
    # Same cases as the reader_pure.zig tests.
    cases = {
        "spread": [[0, 10, [0, None]], [1, 10, [1, 2]], [2, 10, [1, 2]], [9, 10, [9, None]], [4, 5, [3, 4]], [99, 10, [9, None]]],
        "order": [[3, 10, False, [3, 4]], [3, 10, True, [4, 3]], [0, 10, True, [0]]],
        "step": [["single", 3, 10, "next", 4], ["single", 9, 10, "next", None], ["spread", 0, 10, "next", 1],
                 ["spread", 1, 10, "next", 3], ["spread", 2, 10, "next", 3], ["spread", 9, 10, "next", None],
                 ["spread", 4, 10, "previous", 1], ["spread", 2, 10, "previous", 0], ["spread", 0, 10, "previous", None]],
        "keys": [["ArrowLeft", False, "previous"], ["ArrowLeft", True, "next"], ["ArrowRight", True, "previous"], ["k", True, "next"], ["j", True, "previous"]],
        "zoom": [[100, 4], [0.1, 0.5], [1, 1]],
    }
    script = media[start:end] + """
const cases = %s; const bad = [];
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
for (const [p, c, want] of cases.spread) if (!eq(comicSpreadAt(p, c), want)) bad.push('spread ' + p);
for (const [p, c, rtl, want] of cases.order) if (!eq(comicDisplayOrder(comicSpreadAt(p, c), rtl), want)) bad.push('order ' + p + rtl);
for (const [m, p, c, d, want] of cases.step) if (comicStep(m, p, c, d) !== want) bad.push('step ' + m + p + d);
for (const [k, rtl, want] of cases.keys) if (comicKeyDirection(k, rtl) !== want) bad.push('key ' + k + rtl);
for (const [z, want] of cases.zoom) if (comicClampZoom(z) !== want) bad.push('zoom ' + z);
console.log(JSON.stringify(bad));
""" % json.dumps(cases)
    run = subprocess.run([node, "-e", script], capture_output=True, text=True, timeout=30)
    if run.returncode != 0:
        return "fail", "node failed: " + run.stderr[-300:]
    bad = json.loads(run.stdout.strip() or "[]")
    if bad:
        return "fail", "web reader diverges from reader_pure: " + ", ".join(bad)
    return "pass", "web spread pairing, RTL order, stepping, keys and zoom match reader_pure"


@test("Local .cbz files open in the reader from drop, CLI and file association", "Reader")
def test_local_cbz_open_routes():
    pure = _src("src/services/reader_pure.zig")
    browser = _src("src/services/browser.zig")
    main = _src("src/main.zig")
    checks = {
        "pure route check is tested": "pub fn isLocalComicArchive(" in pure and 'test "local comic archives route to the reader, not mpv"' in pure,
        "loadContent (CLI/forwarded/file assoc) routes .cbz to the reader":
            'if (@import("reader_pure.zig").isLocalComicArchive(url)) {\n        @import("comics.zig").loadCbzFile(url);' in browser,
        "drag-drop routes .cbz before mpv": 'isLocalComicArchive(fpath)) {\n                    @import("services/comics.zig").loadCbzFile(fpath);' in main,
    }
    bad = [k for k, ok in checks.items() if not ok]
    return ("fail", ", ".join(bad)) if bad else ("pass", "drop, CLI and forwarded opens send absolute .cbz paths to loadCbzFile")
