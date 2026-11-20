"""HeanCms / Iken manga-source engine tests.
See tests/features/harness.py for the shared @test decorator + helpers.

The HeanCms/Iken family is a base-URL-driven pure-JSON API (modern Next.js manhwa
sites; ~12+ share the shape). The parsing/URL logic lives in the tested pure
module src/services/manga_heancms_pure.zig (exercised against embedded JSON
samples in `zig build test` → test_manga_heancms_pure); this feature test asserts
the wiring: pure module registered + routed, Source.heancms + searchWorker branch,
source_config-gated, the API-host derivation + paywall-skip + both page shapes,
and that pages route into the shared comics reader pipeline."""
from .harness import *  # noqa: F401,F403


@test("HeanCms manga engine", "Reading")
def test_manga_heancms_engine():
    build = _src("build.zig")
    pure = _src("src/services/manga_heancms_pure.zig")
    comics = _src("src/services/comics.zig")

    problems = []

    # 1) Pure module registered in the build.zig test step.
    if "manga_heancms_pure.zig" not in build or "test_manga_heancms_pure" not in build:
        problems.append("manga_heancms_pure not registered in build.zig test step")

    # 2) Pure module implements the HeanCms contract surface.
    for fn in ("pub fn apiHostFromBase", "pub fn buildQueryUrl", "pub fn buildDetailUrl",
               "pub fn buildChapterListUrl", "pub fn buildPagesUrl", "pub fn parseSeriesEntry",
               "pub fn parseSeriesDetail", "pub fn firstFreeChapter", "pub fn pagesNode",
               "pub fn absolutizeCover", "pub fn slugFromRoute", "pub fn buildRouteUrl"):
        if fn not in pure:
            problems.append(f"pure module missing {fn}")

    # 3) API-host derivation (:// → ://api.) and the heancms: reader-route scheme.
    if '"://api."' not in pure and "://api." not in pure:
        problems.append("apiHostFromBase :// → ://api. derivation missing")
    if 'HC_SCHEME = "heancms:"' not in pure:
        problems.append("heancms:<slug> route scheme missing")

    # 4) Paywall handling: price>0 chapters are skipped (free == price == 0).
    if "price == 0" not in pure or "firstFreeChapter" not in pure:
        problems.append("paywall (price>0) skip logic missing in pure module")

    # 5) Both page-image shapes handled: new chapter_data.images + old data[].
    if '"\\"images\\""' not in pure and '"images"' not in pure:
        problems.append("pagesNode new-shape (images) handling missing")
    if "chapter_data" not in pure:
        problems.append("pure module does not document/handle the chapter_data.images shape")

    # 6) The bracket-glob trap: tags_ids must be percent-encoded (%5B%5D), never [].
    if "tags_ids=%5B%5D" not in pure:
        problems.append("tags_ids not percent-encoded (curl glob-abort trap)")

    # 7) comics.zig routes THROUGH the pure module (no drift).
    if '@import("manga_heancms_pure.zig")' not in comics:
        problems.append("comics.zig does not import manga_heancms_pure")
    for call in ("heancms.slugFromRoute", "heancms.buildQueryUrl", "heancms.parseSeriesEntry",
                 "heancms.firstFreeChapter", "heancms.pagesNode", "heancms.absolutizeCover"):
        if call not in comics:
            problems.append(f"comics.zig does not route through {call}")

    # 8) Source.heancms added at the END of the enum + searchWorker branch.
    if not _re.search(r"const\s+Source\s*=\s*enum(?:\s*\([^)]*\))?\s*\{[^}]*\bheancms\b", comics):
        problems.append("Source.heancms not added to the enum")
    if not all(token in comics for token in ("sourceActive(src)", "Source.heancms", ".heancms => fetchHeancmsPage(q, wave.page, gen, 0)", "runComicWave(gen, 1)", "runComicWave(gen, next_page)")) or "fetchHeancmsPage" not in comics:
        problems.append("searchWorker HeanCms branch (sourceActive(.heancms) → fetchHeancmsPage) missing")

    # 9) source_config-gated — inert until a plugin installs the "heancms" base.
    if 'get("heancms", "base")' not in comics:
        problems.append("HeanCms not gated behind source_config heancms/base")

    # 10) Pages route into the SAME reader pipeline (heancms: → loadHeancmsPages →
    #     shared downloadPages) via the pseudo-URL scheme, like mangadex:.
    if "fn loadHeancmsPages" not in comics:
        problems.append("loadHeancmsPages reader-chain loader missing")
    if not (comics.count("downloadPages(gen)") >= 1 and "loadHeancmsPages(slug, heancms.chapterIdFromRoute(url))" in comics):
        problems.append("HeanCms pages not routed into the shared downloadPages pipeline")

    # 11) Iken flavour (the API the catalog's sites migrated to): pure builders +
    #     parsers exist, and comics.zig tries Iken first for search AND reader,
    #     keeping the legacy chain as the shape-detected fallback.
    for fn in ("pub fn buildIkenQueryUrl", "pub fn buildIkenPostUrl", "pub fn buildIkenChapterListUrl",
               "pub fn buildIkenPagesUrl", "pub fn parseIkenPost", "pub fn firstFreeIkenChapter",
               "pub const IkenImageIter", "pub fn isIkenQuery", "pub fn isIkenPost"):
        if fn not in pure:
            problems.append(f"pure module missing {fn}")
    for call in ("heancms.buildIkenQueryUrl", "heancms.isIkenQuery", "heancms.parseIkenPost",
                 "heancms.buildIkenPostUrl", "heancms.isIkenPost", "heancms.IkenNavigation",
                 "heancms.buildIkenChapterListPageUrl", "heancms.buildIkenChapterRoute",
                 "heancms.buildIkenPagesUrl", "heancms.IkenImageIter", "loadIkenPages(api, cdn, slug, chapter_id)"):
        if call not in comics:
            problems.append(f"comics.zig does not route through {call}")

    # 12) Iken chapter navigation: the list is PAGED past the first 100 chapters
    #     (tested ikenNextSkip + totalChapterCount drive the loop, no ad-hoc
    #     `count < TAKE` stop), and the requested chapter's free neighbours become
    #     the shared reader's prev/next routes (same prev_url/next_url toolbar
    #     controls MangaDex uses). Regression tests named for both bugs exist.
    for fn in ("pub fn ikenNextSkip", "pub fn ikenTotalChapterCount", "pub const IKEN_CHAPTER_CAP",
               "pub const IkenNavigation", "pub fn buildIkenChapterRoute", "pub fn chapterIdFromRoute"):
        if fn not in pure:
            problems.append(f"pure module missing {fn}")
    for name in ("regression: Iken reader opened only the first free chapter",
                 "regression: Iken chapter list read only the first 100 chapters"):
        if f'test "{name}' not in pure:
            problems.append(f"missing regression test '{name}'")
    iken = comics[comics.find("fn loadIkenPages"):]
    iken = iken[:iken.find("\nfn ", 1)]
    if "heancms.ikenNextSkip(skip, count, heancms.ikenTotalChapterCount(" not in iken:
        problems.append("loadIkenPages does not page the chapter list through ikenNextSkip")
    if "count < heancms.IKEN_CHAPTER_TAKE" in iken:
        problems.append("loadIkenPages still stops after the first short/100-chapter page")
    if not all(t in iken for t in ("nav.previous", "nav.next", "state.app.comic.prev_url_len = route.len",
                                    "state.app.comic.next_url_len = route.len")):
        problems.append("Iken prev/next not wired into the reader's prev_url/next_url")
    if "loadComic(comic.prev_url[0..comic.prev_url_len])" not in comics or \
       "loadComic(comic.next_url[0..comic.next_url_len])" not in comics:
        problems.append("reader toolbar prev/next controls missing")

    if problems:
        return "fail", "; ".join(problems)
    return ("pass", "HeanCms engine wired: pure module registered + routed, Source.heancms + "
            "searchWorker branch, source_config-gated, api-host derivation + paywall skip + "
            "both page shapes, pages route into the shared comics reader, Iken chapter "
            "list paged past 100 + free prev/next chapter routes")
