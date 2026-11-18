"""Reading — light-novel SOURCE ENGINES (Madara / lightnovelwp / readwn).
See tests/features/harness.py for the shared @test decorator + helpers."""
from .harness import *  # noqa: F401,F403


@test("Light-novel source engines", "Reading")
def test_novel_source_engines():
    # ~120 light-novel sites reached by REUSING the manga parsers: Madara-novel
    # (74 sites) reuses manga_madara_pure, lightnovelwp (35) reuses
    # manga_themesia_pure — the ONLY new thing is the chapter-TEXT container.
    # readwn (7) is a small standalone parser. Each engine is source_config-gated
    # (inert until a plugin supplies its base); Wikisource stays the always-on
    # legal default.
    pure = _src("src/services/novel_sources_pure.zig")
    svc = _src("src/services/novels.zig")
    build = _src("build.zig")
    shim = _src("tests/test_features.py")

    checks = {
        # ── New pure module present + registered + routed ──
        "pure module present": bool(pure),
        "registered in build test step (at end)": 'b.path("src/services/novel_sources_pure.zig")' in build,
        "shim imports test module": "test_novel_sources" in shim,
        "service routes through pure": 'nsp = @import("novel_sources_pure.zig")' in svc,
        # ── REUSE of the manga engines (the whole point) ──
        "reuses manga_madara_pure": '@import("manga_madara_pure.zig")' in pure,
        "reuses manga_themesia_pure": '@import("manga_themesia_pure.zig")' in pure,
        "service uses reused madara search": "nsp.madara.SearchIter" in svc,
        "service uses reused madara chapters": "nsp.madara.ChapterIter" in svc,
        "service uses reused themesia browse": "nsp.themesia.buildBrowseUrl" in svc,
        # lightnovelwp anchors on its `.eplister` directory, then reuses the
        # themesia row iterator (and its container as the legacy fallback).
        "service uses reused themesia chapters": "nsp.lightnovelwpChapters(body)" in svc
            and "return themesia.chapterIter(html);" in pure,
        # ── The ONE new thing: chapter-TEXT container selectors per engine ──
        "madara .text-left selector": '"text-left"' in pure,
        "lightnovelwp epcontent selector": '"epcontent"' in pure,
        "readwn .chapter-content selector": '"chapter-content"' in pure,
        "container extractor": "pub fn containerInner" in pure and "pub fn chapterContentHtml" in pure,
        "service extracts chapter text": "nsp.chapterContentHtml(" in svc,
        # ── readwn standalone engine ──
        "readwn url builders": all(
            f"pub fn {fn}" in pure
            for fn in ("readwnBrowseUrl", "readwnSearchUrl", "readwnSearchBody")
        ),
        "readwn list/detail/chapter parse": all(
            s in pure for s in ("pub const ReadwnIter", "pub fn readwnDetails", "pub fn readwnChapters")
        ),
        "service parses readwn": "nsp.ReadwnIter" in svc and "nsp.readwnChapters" in svc,
        # ── NovelSource enum wired into search + reader dispatch ──
        "NovelSource enum": "pub const NovelSource = enum {" in pure,
        "enum variants": all(
            v in pure for v in ("wikisource", "madara_novel", "lightnovelwp", "readwn")
        ),
        "service imports enum": "const NovelSource = nsp.NovelSource;" in svc,
        "search dispatches by source": all(
            f in svc for f in ("fetchMadaraNovel", "fetchLightnovelwp", "fetchReadwn")
        ),
        "chapters dispatch by source": "switch (job.source)" in svc and "fn chaptersMadara" in svc,
        "reader dispatch by source": "fn textSourced" in svc and "job.source == .wikisource" in svc,
        # ── source_config-gated per source (inert without base) ──
        "madara_novel gated": 'source_config.get("madara_novel", "base")' in svc,
        "lightnovelwp gated": 'source_config.get("lightnovelwp", "base")' in svc,
        "readwn gated": 'source_config.get("readwn", "base")' in svc,
        "wikisource always-on default": "fetchWikisource" in svc,
        # ── Thread-safety discipline (workers publish under the existing mutex) ──
        "publishes under mutex": "parse_mutex.lock()" in svc,
        "generation guards": "search_request" in svc and "chapters_gen" in svc and "text_gen" in svc,
        "POST helper for readwn/ajax": "fn curlPost" in svc,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if not missing:
        return "pass", "novel engines: Madara(reuse)+lightnovelwp(reuse)+readwn(standalone), source_config-gated"
    return "fail", "novel source engines incomplete: " + ", ".join(missing)


@test("Reading sources: live-site repairs are routed through tested pure logic", "Reading")
def test_reading_source_repairs():
    # Nov 2026 live audit of every installed reading source. Each repair below
    # was reproduced against the real provider, fixed in a *_pure.zig sibling
    # with a regression test, and routed from the worker so tested == shipped.
    resolver = _src("src/services/resolver.zig")
    reading = _src("src/services/search_reading_pure.zig")
    novels = _src("src/services/novels.zig")
    nsp = _src("src/services/novel_sources_pure.zig")
    expanded = _src("src/services/expanded_reading_pure.zig")
    madara = _src("src/services/manga_madara_pure.zig")
    comics_pure = _src("src/services/comics_pure.zig")
    web = _src("src/services/webcomic_sources.zig")
    web_pure = _src("src/services/webcomic_sources_pure.zig")

    def fn_body(src, name):
        at = src.find("fn " + name + "(")
        return src[at:src.find("\nfn ", at + 1)] if at >= 0 else ""

    catalog = fn_body(resolver, "fetchReadingCatalog")
    checks = {
        # Wikisource / Archive texts / VNDB: universal search used the in-process
        # client with an 8 s cap and reported transport_failed for 200 answers.
        "keyless reading catalogs share one bounded fetch": all(
            "fetchReadingCatalog(" in fn_body(resolver, name)
            and 'http.zig").fetch(' not in fn_body(resolver, name)
            for name in ("resolveWikiNovels", "resolveArchiveNovels", "resolveVisualNovels")
        ),
        "catalog fetch is cancellable and classified": "workerCancellation()" in catalog
            and "policy.catalogFailure(" in catalog and "policy.CATALOG_TIMEOUT_SECS" in catalog,
        "catalog failure policy is pure-tested": "pub fn catalogFailure(" in reading
            and 'test "keyless reading catalog failures keep their real cause"' in reading,
        # NovelFire chapter URLs answer a stub pointing at the reader domain.
        "NovelFire relocation is validated purely": "pub fn novelFireRelocation(" in expanded
            and 'test "NovelFire chapter stub hands over to the reader domain for the same chapter only"' in expanded,
        "NovelFire reader follows the relocation": "expanded.novelFireRelocation(&moved_buf, chapter_url, body)" in novels,
        # Madara: stylesheet mentions hung the iterator; search rows were missed;
        # plugin asset URLs faked inline chapters so AJAX lists never loaded.
        "Madara blocks need a real class attribute": "pub fn classOwner(" in madara
            and "classOwner(html, at) orelse" in madara,
        "Madara search rows include the WordPress search template": '"c-tabs-item__content"' in madara,
        "Madara regressions are tested": 'test "regression: stylesheet mentions of the item class cannot stall or swallow results"' in madara
            and 'test "SearchIter: stock WordPress search rows (c-tabs-item__content) are results"' in madara,
        # lightnovelwp: novel grid + eplister chapter directory.
        "lightnovelwp uses its own grid and chapter directory": "nsp.LightnovelwpSearch.init(body)" in novels
            and "nsp.lightnovelwpChapters(body)" in novels
            and "pub const LightnovelwpIter" in nsp and "pub fn lightnovelwpChapters(" in nsp,
        # Poorly Drawn Lines rejects the spoofed browser UA on its images.
        "honest-UA hosts are decided by host": "HONEST_UA_HOSTS" in comics_pure and '"poorlydrawnlines."' in comics_pure
            and 'test "regression: Poorly Drawn Lines images get the app UA, not the spoofed browser UA"' in comics_pure,
        # SMBC serves real comic pages with HTTP 500.
        "SMBC error-status pages are accepted only when valid": "pub fn readableErrorPage(" in web_pure
            and "pure.readableErrorPage(provider, path, response.status) and validPage(response.body)" in web,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if not missing:
        return "pass", "reading repairs routed through pure, regression-tested logic"
    return "fail", "reading source repairs incomplete: " + ", ".join(missing)
