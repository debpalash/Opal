"""Reading — live-action Asian drama + tokusatsu browse module tests.
See tests/features/harness.py for the shared @test decorator, helpers, and
run_all()."""
from .harness import *  # noqa: F401,F403


@test("Asian drama + tokusatsu", "Reading")
def test_drama_module():
    # End-to-end wiring of the Drama tab: TMDB catalog grid → detail → play (via
    # the universal resolver), with tokusatsu folded in as a second content lane.
    #
    # Verify: the pure module is registered + routed (tested logic == shipped
    # logic), the drill-down UI is wired (enum → nav → render dispatch → subtab),
    # play routes through load_file/gotoPlayer, the drama/toku split exists, and
    # at least one working source (TMDB discover/search) is wired.
    svc = _src("src/services/drama.zig")
    pure = _src("src/services/drama_pure.zig")
    st = _src("src/core/state.zig")
    shell = _src("src/ui/shell.zig")
    drawer = _src("src/ui/drawer.zig")
    build = _src("build.zig")

    checks = {
        # ── Pure module: parsing, classification, query building ──
        "pure module present": bool(pure),
        "pure discover parser": "pub fn parseDiscover" in pure,
        "pure origin classify (split)": "pub fn classifyOrigin" in pure and "pub fn classifyLang" in pure,
        "pure tokusatsu classify (split)": "pub fn isTokusatsu" in pure,
        "pure discover path builder": "pub fn discoverPath" in pure,
        "pure resolver query": "pub fn buildResolverQuery" in pure,
        "pure segment enum": "pub const Segment = enum { drama, tokusatsu }" in pure,
        # Production routes through the pure fns.
        "service routes through pure": all(
            f"drama_pure.{fn}(" in svc
            for fn in ("parseDiscover", "discoverPath", "buildResolverQuery")
        ),
        "service uses classification": "originLabel" in svc and "is_toku" in svc,
        # ── At least one working source: TMDB discover/search (stable) ──
        "tmdb discover source": "/3/discover/tv" in pure,
        "tmdb search fallback": "/3/search/tv" in pure,
        "tmdb api reused": "tmdbApiInto" in svc,
        # Tokusatsu best-effort surface (official YouTube channels).
        "tokusatsu channels": "pub fn tokusatsuChannels" in pure and "youtube.com" in pure,
        # ── Drill-down UI: enum → nav → render dispatch → subtab ──
        "enum variant present": "Drama" in st and "pub const DrawerTab" in st,
        "state struct": "drama: struct {" in st,
        "drama result type": "pub const DramaResult = struct {" in st,
        "nav host page": ".Drama => {" in st and "app.browse_source = .Drama;" in st,
        "render dispatch": '.Drama => @import("../services/drama.zig").renderContent()' in drawer,
        "rail nav entry": "renderRailTab(.Drama" in drawer,
        "shell label": '.Drama => "Asian Drama"' in shell,
        "shell icon (exists in pack)": ".Drama => icons.tvg.lucide." in shell and "clapperboard" in shell,
        "browse subtab": ".Drama" in shell and "subTabs(&.{" in shell,
        # ── Drama vs Tokusatsu split present (segment lane) ──
        "segment state": "segment: u8" in st,
        "segment switch UI": "fn setSegment" in svc and "segChip" in svc,
        "drop-toku split in fetch": "drop_toku" in svc,
        # ── Play routes through load_file + gotoPlayer (guarded) ──
        "play worker": "pub fn playSelected" in svc,
        "play via resolver": "resolver.resolve(" in svc,
        "play load_file": "load_file(" in svc,
        "play gotoPlayer": "state.gotoPlayer()" in svc,
        "player idx guard": "active_player_idx >= state.app.players.items.len" in svc,
        # ── Thread-safety discipline ──
        "atomic loading flags": "is_loading.store" in svc and "stream_loading.store" in svc,
        "publishes under mutex": "pending_mutex.lock()" in svc,
        "generation guard": "fetch_gen" in svc,
        "threads detached (no un-detached spawn)": "_ = std.Thread.spawn(" not in svc,
        "heap fetch buffer": "alloc.alloc(u8, 256 * 1024)" in svc,
        # ── Pure module registered in the `zig build test` step ──
        "test registered": 'b.path("src/services/drama_pure.zig")' in build,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if not missing:
        return "pass", "drama+toku wired: pure(parse/classify/split) → enum→nav→service (TMDB), play→resolver→load_file/gotoPlayer"
    return "fail", "drama wiring incomplete: " + ", ".join(missing)
