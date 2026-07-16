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
        "service uses reused themesia chapters": "nsp.themesia.chapterIter" in svc,
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
        "chapters dispatch by source": "switch (open_source)" in svc and "fn chaptersMadara" in svc,
        "reader dispatch by source": "fn textSourced" in svc and "open_source == .wikisource" in svc,
        # ── source_config-gated per source (inert without base) ──
        "madara_novel gated": 'source_config.get("madara_novel", "base")' in svc,
        "lightnovelwp gated": 'source_config.get("lightnovelwp", "base")' in svc,
        "readwn gated": 'source_config.get("readwn", "base")' in svc,
        "wikisource always-on default": "fetchWikisource" in svc,
        # ── Thread-safety discipline (workers publish under the existing mutex) ──
        "publishes under mutex": "parse_mutex.lock()" in svc,
        "generation guards": "search_gen" in svc and "chapters_gen" in svc and "text_gen" in svc,
        "POST helper for readwn/ajax": "fn curlPost" in svc,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if not missing:
        return "pass", "novel engines: Madara(reuse)+lightnovelwp(reuse)+readwn(standalone), source_config-gated"
    return "fail", "novel source engines incomplete: " + ", ".join(missing)
