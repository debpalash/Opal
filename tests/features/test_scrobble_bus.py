"""Unified scrobble bus and the MockIo test seam for io_global modules."""
import re
from pathlib import Path

from .harness import *  # noqa: F401,F403

_ROOT = Path(__file__).resolve().parents[2]
_TRACKERS = ("trakt.zig", "simkl.zig", "anilist.zig")


@test("Player code reaches trackers only through the scrobble bus", "Integration")
def test_no_direct_tracker_calls_from_player():
    offenders = []
    for path in sorted((_ROOT / "src" / "player").glob("*.zig")):
        text = path.read_text(encoding="utf-8", errors="replace")
        for name in _TRACKERS:
            if name in text:
                offenders.append(f"{path.name} imports {name}")
    # Outside player/, only the sinks module may deliver watch events.
    call = re.compile(r"\b(markWatched(Movie|Episode)|markUnwatched(Movie|Episode)|updateProgress|scrobbleLive)\(")
    allowed = {"scrobble_sinks.zig", "trakt.zig", "simkl.zig", "anilist.zig"}
    for path in sorted((_ROOT / "src").rglob("*.zig")):
        if path.name in allowed:
            continue
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.lstrip().startswith("//"):
                continue
            if call.search(line) and any(t.split(".")[0] + "." in line or t in line for t in _TRACKERS):
                offenders.append(f"{path.relative_to(_ROOT)}: {line.strip()[:80]}")
    if offenders:
        return "fail", "direct tracker calls bypass the bus: " + "; ".join(offenders)
    return "pass", "player/ has no Trakt/SIMKL/AniList imports; only scrobble_sinks.zig delivers"


@test("Scrobble bus is wired: one tick, every mark, registered sinks", "Integration")
def test_scrobble_bus_wiring():
    bus = _src("src/core/scrobble_bus.zig")
    pure = _src("src/core/scrobble_pure.zig")
    sinks = _src("src/services/scrobble_sinks.zig")
    player = _src("src/player/player.zig")
    trakt = _src("src/services/trakt.zig")
    build = _src("build.zig")
    checks = {
        "pure rules": "pub fn watchedDue" in pure and "watched_ratio: f64 = 0.8" in pure
            and "debounce_ms" in pure and "pub const Dedupe" in pure,
        "bus runs the pure session": "s.step(" in bus and "dedupe.admit(" in bus
            and "pure.routes(" in bus,
        "bus is core-only": not any(t in bus for t in _TRACKERS),
        "per-frame player tick": "fn scrobbleTick()" in player
            and "scrobbleTick();" in _between(player, "pub fn updateTorrentBackgroundTasks", "for (state.app.players.items) |p| {"),
        "history removal": 'scrobble_bus.zig").mark(.movie(catalog_tmdb_id), false)' in _src("src/player/watch_history.zig"),
        "episode commit": 'scrobble_bus.zig").mark(.tvEpisode(' in _src("src/services/tv_library.zig"),
        "anime progress": 'scrobble_bus.zig").mark(.anime(r.anilist_id' in _src("src/services/anime.zig"),
        "sinks registered at startup": 'scrobble_sinks.zig").install()' in _src("src/main.zig")
            and all(f".tracker = .{t}" in sinks for t in ("trakt", "simkl", "anilist")),
        "trakt live scrobble is id-based": "liveScrobblePayload(" in sinks
            and "pub fn scrobbleLive(" in trakt and '"movie":{{"title"' not in trakt,
        "unit tests registered": 'b.path("src/core/scrobble_pure.zig")' in build
            and 'b.path("src/io_seam_tests.zig")' in build,
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "scrobble bus incomplete: " + ", ".join(missing)
    return "pass", "player tick + all marks -> bus -> Trakt/SIMKL/AniList sinks"


@test("MockIo seam backs io_global only in test builds", "Build")
def test_mock_io_seam():
    iog = _src("src/core/io_global.zig")
    mock = _src("src/core/mock_io.zig")
    root = _src("src/io_seam_tests.zig")
    wp = _src("src/core/work_pool.zig")
    checks = {
        "mock is test-only": '@compileError("mock_io.zig is test-only")' in mock,
        "seam is comptime-gated": "const MockIo = if (builtin.is_test)" in iog
            and iog.count("if (comptime builtin.is_test) if (activeMock())") >= 5,
        "fs wrappers use the seam": "std.Io.Dir.cwd()." not in iog and "fn cwdDir()" in iog,
        "work_pool runs for real": "TODO: cross-boundary test" not in wp
            and 'core/work_pool.zig")' in root,
        "a services/ module crosses the boundary": 'services/remote_http.zig")' in root,
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "MockIo seam incomplete: " + ", ".join(missing)
    return "pass", "fake clock + virtual sleep + temp-dir CWD; production unaffected"
