"""Audiobookshelf client — feature wiring test.
See tests/features/harness.py for the shared @test decorator + helpers."""
from .harness import *  # noqa: F401,F403
import os  # noqa: F401


@test("Audiobookshelf client", "Reading")
def test_audiobookshelf():
    # The Audiobookshelf client (self-hosted audiobooks/podcasts) is the
    # audio-first sibling of the Jellyfin client: login → token → libraries →
    # items → stream into mpv. Parsing + URL/header building live in the tested
    # pure module; the service owns workers/threading/render. GUI draw code is
    # not unit-testable, so this pins the wiring instead.
    pure = _src("src/services/audiobookshelf_pure.zig")
    svc = _src("src/services/audiobookshelf.zig")
    st = _src("src/core/state.zig")
    cfg = _src("src/core/config.zig")
    drawer = _src("src/ui/drawer.zig")
    shell = _src("src/ui/shell.zig")
    settings = _src("src/ui/settings.zig")
    build = _src("build.zig")
    if not pure or not svc:
        return "fail", "audiobookshelf_pure.zig / audiobookshelf.zig missing"

    checks = {
        # ── Pure module: parsing + URL building, tested + registered ──
        "pure registered in build.zig": "src/services/audiobookshelf_pure.zig" in build,
        "pure has tests": pure.count('test "') >= 5,
        "pure parses login token": "pub fn extractToken(" in pure,
        "pure parses libraries": "pub fn parseLibraries(" in pure,
        "pure parses items": "pub fn parseItems(" in pure,
        "pure builds stream url": "pub fn streamUrl(" in pure,
        "pure builds bearer header": "pub fn bearerHeader(" in pure,
        "pure parses progress": "pub fn parseProgressSeconds(" in pure,
        "pure gates item id (injection)": "pub fn validItemId(" in pure,
        # Production routes through the tested pure fns (no drift).
        "service routes through pure": all(f in svc for f in (
            "pure.extractToken", "pure.parseLibraries", "pure.parseItems",
            "pure.streamUrl", "pure.bearerHeader")),

        # ── State: DrawerTab + per-tab struct ──
        "DrawerTab.Audiobooks present": "Audiobooks" in st and "pub const DrawerTab" in st,
        "per-tab state struct": "abs: struct {" in st,
        "state uses pure records": "audiobookshelf_pure.Library" in st and "audiobookshelf_pure.Book" in st,

        # ── Config: connection keys persisted ──
        "config saves server+token": all(k in cfg for k in (
            '"abs_server_url"', '"abs_token"', '"abs_connected"')),

        # ── Drawer: nav entry + render dispatch ──
        "drawer nav entry": "renderRailTab(.Audiobooks," in drawer,
        "render dispatch": ".Audiobooks => @import(\"../services/audiobookshelf.zig\").renderContent()" in drawer,
        "renderContent exists": "pub fn renderContent() void" in svc,

        # ── Shell: label + icon + browse sub-tab ──
        "shell label + icon": '.Audiobooks => "Audiobooks"' in shell and ".Audiobooks => icons" in shell,
        "browse sub-tab": ".Audiobooks," in shell or ".Audiobooks }" in shell,

        # ── Playback: stream URL → load_file → gotoPlayer (Now Playing card) ──
        "play routes through load_file/gotoPlayer": (
            "pub fn playBook(" in svc
            and "loadContentDirectMeta(" in svc),
        # loadContentDirectMeta is the shared audio path that load_file's the URL,
        # sets now-playing metadata, and calls state.gotoPlayer().
        "shared audio path calls gotoPlayer": "state.gotoPlayer();" in _src("src/services/browser.zig"),

        # ── Threading: atomic loading flag + detached worker + mutex publish ──
        "atomic loading flag": "is_loading.load(.acquire)" in svc and "is_loading.store(true, .release)" in svc,
        "detached worker": "std.Thread.spawn" in svc and ".detach()" in svc,
        "publish under mutex": "parse_mutex.lock()" in svc,
        # Player access is guarded via the shared browser helper's len check.

        # ── Settings: Audiobookshelf connection section (Network tab) ──
        "settings connection section": "renderAudiobookshelfSection(" in settings,
        "settings test connection": '"Test Connection"' in settings,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "audiobookshelf wiring incomplete: " + ", ".join(missing[:5])
    return "pass", "ABS client: tested pure parsers, DrawerTab wired, streams via mpv + Now Playing"
