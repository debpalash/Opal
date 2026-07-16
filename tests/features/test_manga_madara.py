"""Madara manga-source engine tests — one generic, base-URL-driven scraper for
the WordPress "Madara" theme that ~332 Mihon/Tachiyomi sites share.
See tests/features/harness.py for the shared @test decorator + helpers.

The HTML/URL PARSING itself is exercised against embedded real-ish Madara
snippets in `zig build test` (test_manga_madara_pure): search grid, details,
chapter list, page-break images, the image-attr precedence rule incl. srcset,
relative→absolute resolve, and a malformed/truncated no-crash sweep. This test
verifies the WIRING: the pure module is registered + routed, the source is
gated behind source_config (inert without a base), and the reader pipeline is
reused. Live scraping is manual (no live Madara host in CI)."""
from .harness import *  # noqa: F401,F403


@test("Madara manga engine", "Reading")
def test_manga_madara_engine():
    build = _src("build.zig")
    pure = _src("src/services/manga_madara_pure.zig")
    comics = _src("src/services/comics.zig")

    problems = []

    # 1) Pure module registered in the build.zig test step (at the end).
    if "manga_madara_pure.zig" not in build or "test_manga_madara_pure" not in build:
        problems.append("manga_madara_pure not registered in build.zig test step")

    # 2) Pure module exposes the contract: builders, image-attr rule, resolve,
    #    the grid/chapter/page scanners, details + data-id, and the route scheme.
    needed = (
        "pub fn buildPopularUrl", "pub fn buildSearchUrl", "pub fn buildAjaxBody",
        "pub fn pickImageAttr", "pub fn resolveUrl", "pub fn parseDetails",
        "pub fn dataIdFromHolder", "pub const SearchIter", "pub const ChapterIter",
        "pub const PageIter", "pub fn parsePages", "pub fn mangaUrlFromRoute",
        "pub fn isProtected",
    )
    for sym in needed:
        if sym not in pure:
            problems.append(f"manga_madara_pure missing {sym}")

    # The image-attr precedence rule must list all five attrs in priority order.
    for attr in ("data-src", "data-lazy-src", "srcset", "data-cfsrc", "src="):
        if attr not in pure:
            problems.append(f"image-attr rule missing {attr}")

    # 3) comics.zig routes THROUGH the pure module (no drift) — the shipped parse
    #    IS the tested parse.
    if '@import("manga_madara_pure.zig")' not in comics:
        problems.append("comics.zig does not import manga_madara_pure")
    for call in ("madara.SearchIter", "madara.parseDetails", "madara.ChapterIter",
                 "madara.PageIter", "madara.resolveUrl", "madara.mangaUrlFromRoute",
                 "madara.buildSearchUrl"):
        if call not in comics:
            problems.append(f"comics.zig does not route through {call}")

    # 4) Source.madara added at the END of the enum + a searchWorker branch.
    if "madara }" not in comics and "madara,}" not in comics.replace(" ", ""):
        problems.append("Source.madara not added at the end of the enum")
    if "fetchMadaraPage" not in comics or "parseMadaraResults" not in comics:
        problems.append("comics.zig missing Madara search fetch/parse fns")
    if "sourceActive(.madara)" not in comics:
        problems.append("searchWorker has no sourceActive(.madara) branch")

    # 5) source_config-gated: inert without a base (exactly like readallcomics).
    if 'get("madara", "base")' not in comics or "fn madaraBase" not in comics:
        problems.append("Madara base not read from source_config (should be inert without it)")
    if "madaraBase() != null" not in comics:
        problems.append("searchWorker does not gate Madara on an installed base")

    # 6) The reader chain: a madara:<mangaUrl> route resolves into the SAME reader
    #    pipeline MangaDex uses (loadMadaraPages stages page_urls → downloadPages).
    if "loadMadaraPages" not in comics:
        problems.append("comics.zig missing loadMadaraPages reader chain")
    if "mangaUrlFromRoute(url)" not in comics:
        problems.append("fetchComicThread does not dispatch the madara: route")
    if "state.app.comic.page_urls" not in comics or "downloadPages" not in comics:
        problems.append("Madara pages do not stage into the shared reader pipeline")

    # 7) Image requests carry a Referer (many Madara CDNs 403 without it): the
    #    reader stashes the chapter URL and the page-fetch worker sends it.
    if "state.app.comic.referer_len" not in comics or "Referer: " not in comics:
        problems.append("Madara page fetch does not send a Referer header")

    # 8) The AJAX chapter fallback (admin-ajax.php with the XMLHttpRequest marker).
    if "manga_get_chapters" not in pure or "X-Requested-With: XMLHttpRequest" not in comics:
        problems.append("Madara AJAX chapter-list fallback not wired")

    # 9) v1 skips the AES chapter-protector path (detect + skip, not implement).
    if "chapter-protector-data" not in pure or "isProtected" not in comics:
        problems.append("AES chapter-protector path is not detected/skipped")

    if problems:
        return "fail", "; ".join(problems)
    return ("pass", "Madara engine wired: pure parser routed (builders + image-attr rule + "
            "grid/chapter/page scanners), Source.madara + searchWorker branch, source_config-gated "
            "(inert without base), madara: route → shared reader pipeline, Referer on page fetches, "
            "AJAX chapter fallback, AES-protector path skipped")
