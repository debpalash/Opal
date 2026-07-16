"""MangaThemesia manga-source engine — the generic base-URL-driven scraper for
the ~143 sites on the WordPress "Keneisan / WPMangaThemesia" theme.
See tests/features/harness.py for the shared @test decorator + helpers."""
from .harness import *  # noqa: F401,F403


@test("MangaThemesia manga engine", "Reading")
def test_manga_themesia_engine():
    build = _src("build.zig")
    pure = _src("src/services/manga_themesia_pure.zig")
    comics = _src("src/services/comics.zig")

    problems = []

    # 1) Pure module registered in the build.zig test step (routed logic == shipped).
    if ("manga_themesia_pure.zig" not in build
            or "test_manga_themesia_pure" not in build):
        problems.append("manga_themesia_pure not registered in build.zig test step")

    # 2) Pure module exposes the MangaThemesia contract surface.
    for sym in ("pub fn buildBrowseUrl", "pub fn pickImageAttr", "pub fn parseDetails",
                "pub const SearchIter", "pub const ChapterIter", "pub fn parsePages",
                "pub fn resolveUrl"):
        if sym not in pure:
            problems.append(f"manga_themesia_pure missing {sym}")

    # 3) IMAGE-ATTR RULE: data-src → data-lazy-src → srcset → src precedence.
    if not all(a in pure for a in ('"data-src"', '"data-lazy-src"', '"srcset"', '"src"')):
        problems.append("manga_themesia_pure missing the image-attr precedence chain")

    # 4) Page parse carries BOTH the readerarea primary AND the JSON fallback.
    if "readerarea" not in pure:
        problems.append("parsePages missing the div#readerarea primary selector")
    if '"images"' not in pure:
        problems.append("parsePages missing the JS-embedded \"images\":[…] fallback")

    # 5) Browse endpoint is the ONE order-switched URL.
    if "order=" not in pure or "title=" not in pure or "&page=" not in pure:
        problems.append("buildBrowseUrl missing title/page/order params")

    # 6) comics.zig routes ALL parsing through the pure module (no drift).
    if '@import("manga_themesia_pure.zig")' not in comics:
        problems.append("comics.zig does not import manga_themesia_pure")
    for routed in ("mt.SearchIter", "mt.chapterIter", "mt.parsePages",
                   "mt.pickImageAttr", "mt.buildBrowseUrl"):
        if routed not in comics:
            problems.append(f"comics.zig does not route through {routed}")

    # 7) Source.mangathemesia added at the END of the enum + searchWorker branch.
    if "Source = enum" in comics:
        enum_body = comics.split("Source = enum", 1)[1].split("}", 1)[0]
        variants = [v.strip() for v in enum_body.strip(" {").split(",") if v.strip()]
        if "mangathemesia" not in variants:
            problems.append("mangathemesia not in the Source enum")
        elif variants[-1] != "mangathemesia":
            problems.append("mangathemesia must be the LAST Source enum variant")
    else:
        problems.append("Source enum not found in comics.zig")
    if "sourceActive(.mangathemesia)" not in comics:
        problems.append("searchWorker missing the sourceActive(.mangathemesia) branch")
    if "fetchThemesiaPage" not in comics or "parseThemesiaResults" not in comics:
        problems.append("comics.zig missing themesia fetch/parse workers")

    # 8) source_config-gated — INERT without an installed base (mirrors readallcomics).
    if 'get("mangathemesia", "base")' not in comics:
        problems.append("mangathemesia not gated behind source_config base key")

    # 9) themesia: pseudo-URL routed in fetchComicThread (like mangadex:), into the
    #    details→chapters→pages chain.
    if "mt.SCHEME" not in comics or "loadThemesiaPages" not in comics:
        problems.append("fetchComicThread does not route the themesia: scheme")
    if 'pub const SCHEME = "themesia:"' not in pure:
        problems.append("manga_themesia_pure missing the themesia: scheme constant")

    # 10) Pages route into the SAME reader pipeline (staged into page_urls +
    #     downloadPages), and image fetches carry a Referer (+ Accept) header.
    if "&state.app.comic.page_urls" not in comics:
        problems.append("loadThemesiaPages does not stage into the shared page_urls array")
    if "state.app.comic.referer_len = rl" not in comics and "referer_len = rl" not in comics:
        problems.append("loadThemesiaPages does not set the chapter Referer")
    if "Referer: {s}" not in comics:
        problems.append("page fetch does not emit a Referer header")
    if "Accept: image/avif" not in comics:
        problems.append("page fetch does not emit the browser-style Accept header")

    if problems:
        return "fail", "; ".join(problems)
    return ("pass", "MangaThemesia wired: pure parser registered + routed (browse URL, "
            "image-attr rule, search/details/chapters, readerarea + JSON page fallback), "
            "Source.mangathemesia + searchWorker branch, source_config-gated, themesia: "
            "scheme → shared reader pipeline with Referer/Accept headers")
