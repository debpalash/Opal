"""Download for offline + progress sync, the window drag handle, and the two
iOS fixes (tv_play picker, playback-torrent disk guard)."""
from .harness import *  # noqa: F401,F403


@test("Offline downloads route every rule through offline_pure", "Integration")
def test_offline_wiring():
    pure = _src("src/services/offline_pure.zig")
    client = _src("src/services/offline.zig")
    server = _src("src/services/offline_server.zig")
    ui = _src("src/ui/offline_ui.zig")
    build = _src("build.zig")
    checks = {
        "pure registered": 'b.path("src/services/offline_pure.zig")' in build,
        "state machine": "pub fn transition(" in pure and "it.apply(.start)" in client
            and "it.apply(.bytes_complete)" in client,
        "quota enforced": "pure.admit(" in client and "pure.exceedsQuota(" in client,
        "range resume": "pure.rangeHeader(have" in client and "pure.planResponse(" in client
            and '.truncate = false' in client,
        "size verified before playable": "pure.verifySize(" in client
            and _between(client, "fn verifyItem", "fn ").find("renameAbsolute") > 0
            # The received byte count must never become the expected size.
            and ".total = total orelse 0" in client and ".total = have" not in client,
        "token stays in the header": "pure.serverFileUrl(" in client and '"Authorization"' in client
            and "t=" not in _between(pure, "pub fn serverFileUrl", "pub fn serverListUrl"),
        "progress captured locally": "pure.localWrite(" in client,
        "client reconciles server winner": "pure.reconcile(" in client,
        "server merges": "pure.merge(" in server and "savePositionFull(" in server,
        "route registered": 'offline_server.zig").handle(' in _src("src/services/remote.zig"),
        "ticks wired": 'services/offline.zig").tick()' in _src("src/app_services.zig")
            and 'services/offline_server.zig").tick()' in _src("src/app_services.zig"),
        "panel on Downloads": 'offline_ui.zig").render()' in _src("src/ui/drawer.zig"),
        "themed widgets only": "dvui.button(" not in ui and "components.actionButton(" in ui
            and "components.confirmDangerButton(" in ui,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "offline wiring incomplete: " + ", ".join(missing)
    return "pass", "queue/quota/Range/verify/merge all via offline_pure; server route + UI wired"


@test("Window drag handle uses the pure hit-test on every desktop OS", "Integration")
def test_drag_handle():
    header = _src("src/ui/header.zig")
    titlebar = _src("src/ui/titlebar.zig")
    pure = _src("src/ui/titlebar_hit_pure.zig")
    checks = {
        "TODO removed": "TODO(drag-handle)" not in header,
        "header registers its title cluster": "setHeaderDragRect(left.data().borderRectScale().r)" in header,
        "hit-test via pure classify": "hit_pure.classify(" in titlebar,
        "installed beyond Windows": "hit_pure.platformSupported(builtin.os.tag, builtin.abi)" in titlebar
            and "SDL_SetWindowHitTest(win, hitTest, null)" in titlebar,
        "stale handle cleared each frame": "header_drag_rect = .{};" in _between(titlebar, "pub fn ensureEnabled", "\n}\n"),
        "pure test registered": 'b.path("src/ui/titlebar_hit_pure.zig")' in _src("build.zig"),
        "mobile excluded": "!abi.isAndroid()" in pure and ".ios" not in _between(pure, "pub fn platformSupported", "\n}\n"),
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "drag handle incomplete: " + ", ".join(missing)
    return "pass", "header title cluster drags via SDL hit-test (macOS, Windows, Linux)"


@test("iOS fixes: id-addressed episode packs auto-play; playback torrents skip the disk fit check", "Integration")
def test_ios_fixes():
    tmdb = _src("src/services/tmdb.zig")
    rank = _src("src/services/resolver_rank.zig")
    policy = _src("src/services/transfer_policy_pure.zig")
    checks = {
        "picker gets episode_exact": ".episode_exact = rank.episodeExact(it.source == .stremio" in tmdb,
        "picker accepts it": "candidate.episode_exact" in _between(rank, "pub fn pickForStartup", "\n}\n"),
        "picker regression test": "regression: tv_play picker" in rank,
        "disk guard treats interactive as a stream": "f.streaming or f.interactive" in _between(policy, "pub fn diskVerdict", "\n}\n"),
        "disk guard regression test": "regression: phone stream stall" in policy,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "iOS fixes missing: " + ", ".join(missing)
    return "pass", "pickForStartup + diskVerdict fixed with regression tests"
