"""Reading — VNDB visual-novel catalog tests.
See tests/features/harness.py for the shared @test decorator, helpers, and
run_all()."""
from .harness import *  # noqa: F401,F403


@test("VNDB visual-novel catalog", "Reading")
def test_vndb_catalog():
    # End-to-end wiring of the Visual Novels tab: a browse/info surface (like the
    # TMDB tab) over VNDB's public HTTPS JSON API. Search VNs → card grid (cover +
    # title + rating) → detail overlay (description, length, rating). VNs are NOT
    # played in-app — this is a catalog, so the one outward action is a title
    # handoff to universal search.
    #
    # NSFW SAFETY: VNDB covers carry `sexual`/`violence` flag averages (0..2). The
    # SFW filter (vndb_pure.isSfw) runs for every entry inside parseVns, so
    # sexual-flagged covers are dropped at parse time and can never render.
    #
    # Verify: the pure module is registered + routed (tested logic == shipped
    # logic), the API request is a POST to api.vndb.org with the flag fields, the
    # SFW filter is called from the parser, and enum → nav → render dispatch +
    # shell subtab are all wired.
    svc = _src("src/services/vndb.zig")
    pure = _src("src/services/vndb_pure.zig")
    st = _src("src/core/state.zig")
    shell = _src("src/ui/shell.zig")
    drawer = _src("src/ui/drawer.zig")
    build = _src("build.zig")

    checks = {
        # ── Pure module: body builders, parse, SFW filter ──
        "pure module present": bool(pure),
        "pure body builders": "pub fn buildSearchBody" in pure and "pub fn buildPopularBody" in pure,
        "pure json-escapes query": "pub fn jsonEscape" in pure,
        "pure response parser": "pub fn parseVns" in pure,
        "pure SFW filter fn": "pub fn isSfw" in pure,
        # The SFW gate is CALLED from the parser (drop sexual-flagged at parse time).
        "SFW filter routed in parseVns": "if (!isSfw(" in pure,
        # Requests the flag fields needed to filter.
        "requests image flag fields": "image.sexual" in pure and "image.violence" in pure,
        # Production routes through the pure fns (tested logic == shipped logic).
        "service routes through pure": all(
            f"pure.{fn}(" in svc
            for fn in ("buildSearchBody", "buildPopularBody", "parseVns")
        ),

        # ── Service: async POST worker, thread-safety, browse-only handoff ──
        "api.vndb.org endpoint": "https://api.vndb.org/kana/vn" in svc,
        "http POST method": '"POST"' in svc and "curlPost" in svc,
        "search worker": "pub fn searchVndb" in svc and "fn fetchWorker" in svc,
        "popular one-shot": "pub fn loadPopularOnce" in svc,
        "detail view": "fn renderDetail" in svc and "pub fn openDetail" in svc,
        "torrent/search handoff": "search.submitQuery(" in svc,
        # Thread discipline (mirrors radio.zig).
        "atomic loading flag": "is_loading.store" in svc,
        "publishes under mutex": "parse_mutex.lock()" in svc,
        "generation guard": "search_gen" in svc,
        "threads detached": "_ = std.Thread.spawn(" not in svc,
        # curl only — std.http SEGVs on some ISP TLS resets (see comics.zig).
        "curl not std.http": "std.http.Client" not in svc and '"curl"' in svc,

        # ── Enum → nav → render dispatch → shell subtab ──
        # Assert MEMBERSHIP, not position (concurrent tab additions).
        "enum variant present": "Vndb" in st and "pub const DrawerTab" in st,
        "state struct": "vndb: struct {" in st,
        # Size-agnostic: the buffer holds several infinite-scroll pages and grows
        # when the page count changes — the SFW guarantee is asserted above, at
        # the parseVns gate, not by this declaration's length.
        "results buffer (SFW-only)": "]@import(\"../services/vndb_pure.zig\").Vn" in st,
        "detail selection state": "selected_idx: ?usize" in st,
        "nav host page": ".Vndb => {" in st and "app.browse_source = .Vndb;" in st,
        "render dispatch": '.Vndb => @import("../services/vndb.zig").renderContent()' in drawer,
        "rail nav entry": "renderRailTab(.Vndb" in drawer,
        "shell label": '.Vndb => "Visual Novels"' in shell,
        "shell icon (exists in pack)": '.Vndb => icons.tvg.lucide.@"gamepad-2"' in shell,
        "browse subtab": ".Vndb" in shell and "subTabs(&.{" in shell,

        # ── Pure module registered in the `zig build test` step ──
        "test registered": 'b.path("src/services/vndb_pure.zig")' in build,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if not missing:
        return "pass", "VNDB catalog wired: pure(body/parse/SFW-filter) → POST api.vndb.org → enum→nav→service; SFW gate routed"
    return "fail", "VNDB wiring incomplete: " + ", ".join(missing)
