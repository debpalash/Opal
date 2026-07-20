"""Suwayomi-Server (Tachidesk) source engine.

Opal talks to a user-run Suwayomi-Server over its REST API (`/api/v1`), which
runs the actual Mihon/Aniyomi extension APKs — so the whole extension ecosystem
works without reimplementing each engine. Structural twin of the MangaDex
engine: a keyed search → chapters → pages JSON chain, cards carry a
`suwayomi:<mangaId>` pseudo-URL routed by fetchComicThread.

Verify: the tested pure module is registered + routed (tested logic == shipped
logic), the comics engine has the Source variant + config gate + search/resolve
wiring, and the bundled manifest carries the entry.

See tests/features/harness.py for the shared @test decorator."""
from .harness import *  # noqa: F401,F403

import json
import os


@test("Suwayomi source engine", "Integration")
def test_suwayomi():
    pure = _src("src/services/manga_suwayomi_pure.zig")
    svc = _src("src/services/comics.zig")
    build = _src("build.zig")

    checks = {
        # ── Pure module: REST URL building + search/chapter/page JSON ──
        "pure module present": bool(pure),
        "pseudo-url scheme": 'pub const SCHEME = "suwayomi:"' in pure,
        "id/base security gates": "pub fn isNumericId" in pure and "pub fn isValidBase" in pure,
        "search url builder": "pub fn buildSearchUrl" in pure,
        "chapters url builder": "pub fn buildChaptersUrl" in pure,
        "page url builder": "pub fn buildPageUrl" in pure,
        "thumb absolutizer": "pub fn absolutizeThumb" in pure,
        "route round-trip": "pub fn buildRouteUrl" in pure and "pub fn mangaIdFromRoute" in pure,
        "search parse": "pub const MangaIter" in pure and "pub fn parseManga" in pure,
        "chapter/page parse": "pub fn firstChapterIndex" in pure and "pub fn pageCount" in pure,
        # Tachidesk REST paths (the shipped requests are these tested strings).
        "rest v1 paths": "/api/v1/source/" in pure and "/api/v1/manga/" in pure and "/chapter/" in pure,

        # ── comics.zig: import + Source variant + config gate ──
        "engine imported": 'const suwayomi = @import("manga_suwayomi_pure.zig")' in svc,
        "Source variant": "suwayomi }" in svc and "Source = enum" in svc,
        "config gate (base+source)": 'source_config.zig").get("suwayomi", "base")' in svc
            and 'source_config.zig").get("suwayomi", "source")' in svc,
        "inert until configured": "fn suwayomiBase()" in svc and "orelse return 0" in svc,
        # Production routes through the pure fns (tested == shipped).
        "routes through pure": all(
            f"suwayomi.{fn}(" in svc
            for fn in ("buildSearchUrl", "buildChaptersUrl", "buildChapterUrl",
                       "buildPageUrl", "mangaIdFromRoute", "parseManga",
                       "firstChapterIndex", "pageCount", "absolutizeThumb")
        ),
        # Search + reader wiring.
        "search fetch": "fn fetchSuwayomiPage(" in svc,
        "search parse": "fn parseSuwayomiResults(" in svc,
        "reader resolve": "fn loadSuwayomiPages(" in svc,
        "dispatch in thread": "suwayomi.mangaIdFromRoute(url)" in svc,
        "wired into searchWorker": "fetchSuwayomiPage(query, 1, gen, filled)" in svc,
        "wired into pagination": "fetchSuwayomiPage(query, next_page, gen, sr_count)" in svc,

        # ── Pure module registered in the zig-build-test step ──
        "test registered": 'b.path("src/services/manga_suwayomi_pure.zig")' in build,
    }

    # ── Bundled manifest carries the Suwayomi entry ──
    mpath = os.path.join(PROJECT_DIR, "plugins-manifest.json")
    manifest_ok = False
    try:
        man = json.load(open(mpath))
        for p in man.get("plugins", []):
            if p.get("id") == "suwayomi" and p.get("type") == "suwayomi" \
                    and "base" in p.get("endpoints", {}):
                manifest_ok = True
                break
    except Exception:
        manifest_ok = False
    checks["manifest suwayomi entry"] = manifest_ok

    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "Suwayomi wiring incomplete: " + ", ".join(missing)
    return "pass", "Suwayomi wired: pure(rest/search/chapters/pages) -> gated engine + reader; manifest present"
