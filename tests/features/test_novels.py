"""Reading — light-novel / web-novel reader tests.
See tests/features/harness.py for the shared @test decorator, helpers, and
run_all()."""
from .harness import *  # noqa: F401,F403
import os  # noqa: F401


@test("Light-novel reader", "Reading")
def test_novels_reader():
    # End-to-end wiring of the Novels tab: search → novel → chapter list → paged
    # text reader. Renders TEXT (not page images), the way comics renders pages.
    #
    # Verify: the pure module is registered + routed (so the tested HTML→text /
    # URL / pagination / resume logic IS the shipped logic), the drill-down UI is
    # wired (enum → nav → render dispatch), chapter navigation + resume exist, and
    # at least one working source (Wikisource, a stable keyless API) is wired.
    svc = _src("src/services/novels.zig")
    pure = _src("src/services/novels_pure.zig")
    st = _src("src/core/state.zig")
    shell = _src("src/ui/shell.zig")
    drawer = _src("src/ui/drawer.zig")
    build = _src("build.zig")

    checks = {
        # ── Pure module: HTML→text, URL builders, pagination, resume ──
        "pure module present": bool(pure),
        "pure html→text extractor": "pub fn htmlToText" in pure,
        "pure url builders": all(
            f"pub fn {fn}" in pure
            for fn in ("buildSearchUrl", "buildSubpagesUrl", "buildChapterUrl", "extractParseHtml")
        ),
        "pure pagination math": "pub fn pageSlice" in pure and "pub fn pageCount" in pure,
        "pure resume key": "pub fn formatResume" in pure and "pub fn parseResume" in pure,
        # Production routes through the pure fns (tested logic == shipped logic).
        "service routes through pure": all(
            f"pure.{fn}(" in svc
            for fn in (
                "buildSearchUrl",
                "buildSubpagesUrl",
                "buildChapterUrl",
                "extractParseHtml",
                "htmlToText",
                "chapterLabel",
                "formatResume",
                "parseResume",
            )
        ),
        # ── At least one working source: Wikisource (keyless, documented API) ──
        "wikisource source wired": 'WIKI_API = "https://en.wikisource.org/w/api.php"' in pure,
        "wikisource used in service": "Wikisource" in svc,
        # ── Drill-down UI: enum → nav → render dispatch ──
        # Membership, not position — the enum grows as tabs are appended at the END.
        "enum variant present": "Novels" in st and "pub const DrawerTab" in st,
        "state struct": "novels: struct {" in st,
        "reader text buffer": "text_buf: [131072]u8" in st,
        "view machine": "view: enum { search, chapters, reader }" in st,
        "nav host page": ".Novels => {" in st and "app.browse_source = .Novels;" in st,
        "render dispatch": '.Novels => @import("../services/novels.zig").renderContent()' in drawer,
        "rail nav entry": "renderRailTab(.Novels" in drawer,
        "shell label+icon": '.Novels => "Novels"' in shell and "book-marked" in shell,
        "browse subtab": ".Novels" in shell and "subTabs(&.{" in shell,
        # ── Service: async workers, chapter nav, resume ──
        "search worker": "pub fn searchNovels" in svc and "fn searchWorker" in svc,
        "chapter-list worker": "pub fn openNovel" in svc and "fn chaptersWorker" in svc,
        "chapter-text worker": "pub fn openChapter" in svc and "fn textWorker" in svc,
        "chapter next/prev nav": "pub fn nextChapter" in svc and "pub fn prevChapter" in svc,
        "resume persist + load": "fn saveResume" in svc and "fn loadResume" in svc,
        "resume via KV store": 'RESUME_KIND = "novel_resume"' in svc and "librarySetStatus" in svc,
        # ── Thread-safety discipline ──
        "atomic loading flags": all(
            f in svc for f in ("is_loading.store", "chapters_loading.store", "text_loading.store")
        ),
        "publishes under mutex": "parse_mutex.lock()" in svc,
        "generation guards": "search_gen" in svc and "text_gen" in svc,
        "threads detached": "_ = std.Thread.spawn(" not in svc,
        # Large fetch buffers heap-allocated (never on the worker stack).
        "heap fetch buffers": "alloc.alloc(u8, 2 * 1024 * 1024)" in svc,
        # curl only — std.http SEGVs on some ISP TLS resets (see comics.zig).
        "curl not std.http": "std.http.Client" not in svc and '"curl"' in svc,
        # ── Pure module registered in the `zig build test` step ──
        "test registered": 'b.path("src/services/novels_pure.zig")' in build,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if not missing:
        return "pass", "novels reader wired: pure(html→text/url/paginate/resume) → enum→nav→service (Wikisource)"
    return "fail", "novels wiring incomplete: " + ", ".join(missing)
