"""Phase S1 — the `-Dheadless` build links no GUI stack.

`-Dheadless` swaps dvui for `src/core/dvui_headless.zig` and drops the SDL2 link,
so the server image needs no X11/GL/pulse/asound. These are source-level guards:
the binding assertion is CI's `ldd` grep inside the container (docker.yml), since
macOS can't validate a Linux image.

See tests/features/harness.py for the shared @test decorator + _src()."""
from .harness import *  # noqa: F401,F403


@test("Headless build links no dvui/SDL", "Headless")
def test_slim_build_gate():
    build = _src("build.zig")
    checks = {
        # The swap itself.
        "dvui stub swapped in": 'b.path("src/core/dvui_headless.zig")' in build
            and 'exe.root_module.addImport("dvui", stub)' in build,
        "real dvui only when not headless": 'addImport("dvui", dvui_dep.module("dvui_sdl2"))' in build
            and "} else if (!headless) {" in build,
        "sdl2 link gated": build.count('linkSystemLibrary("SDL2"' ) == 1
            and build.index("} else if (!headless) {") < build.index('linkSystemLibrary("SDL2"'),
        # poster.zig decodes cover art through dvui.c.stbi_* — reuse dvui's OWN
        # vendored source so the decoder can't drift from the desktop build.
        "stb_image vendored from dvui": 'dvui_dep.path("vendor/stb/stb_image_impl.c")' in build
            and 'dvui_dep.path("vendor/stb")' in build,
        # media_remote.m was the last thing pulling in ObjC/Foundation, which
        # the desktop build got transitively from dvui's bundled SDL2.
        "macos media_remote desktop-only": "if (!headless) {\n            exe.root_module.addCSourceFile(" in build
            and 'linkFramework("MediaPlayer"' in build,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "slim build gate incomplete: " + ", ".join(missing)
    return "pass", "build.zig: -Dheadless → dvui stub + vendored stb, no SDL2/ObjC link"


@test("dvui headless stub covers exactly the reachable surface", "Headless")
def test_dvui_stub_surface():
    stub = _src("src/core/dvui_headless.zig")
    # Every symbol the headless-reachable graph (main, state, poster, player,
    # comics) actually references. Widening this list means the desktop and
    # server builds have started to diverge — gate the CALLER instead.
    surface = [
        "pub const c = @cImport(", "stb_image.h",       # poster.zig image decode
        "pub const Window = opaque {}",                  # state.dvui_win
        "pub var current_window",                        # comics.zig texture-free guard
        "pub const Texture = struct",                    # ?Texture fields everywhere
        "pub fn update(tex: *Texture",                   # player.zig frame upload
        "pub fn textureCreate(",                         # poster.zig
        "pub const textureDestroyLater",                 # poster.zig
        "pub const PMA = extern struct",                 # player.zig frame buffers
        "pub const black: PMA",
        "pub fn refresh(",                               # cross-thread UI pokes
        "pub const App = struct",                        # main.zig panic/logFn
        "pub const panic", "pub const logFn",
    ]
    missing = [s for s in surface if s not in stub]
    if missing:
        return "fail", "dvui stub missing: " + ", ".join(missing)
    # Color.PMA is reinterpreted over decoded RGBA and mpv frame buffers — a
    # non-extern layout would silently corrupt pixels rather than fail to build.
    if "pub const Color = extern struct" not in stub:
        return "fail", "Color must be extern (layout is reinterpreted by poster/player)"
    return "pass", f"dvui stub: {len(surface)} reachable symbols, nothing drawn"


@test("Headless-reachable dvui call sites are comptime-gated", "Headless")
def test_headless_call_gates():
    theme = _src("src/ui/theme.zig")
    tmdb = _src("src/services/tmdb.zig")
    mr = _src("src/player/media_remote.zig")
    mn = _src("src/main.zig")
    checks = {
        # coreInit → setTheme → applyToDvui. Already returned early off the UI
        # thread; comptime keeps the widget-side symbols out of the server build.
        "theme apply gated": "fn applyToDvui() void {\n    // Headless links no dvui" in theme
            and '@import("build_options").headless) return;' in theme,
        # Reachable from fetchDiscover, which a headless server does run.
        "gallery scroll gated": "pub fn resetGalleryScroll() void {" in tmdb
            and '@import("build_options").headless) return;' in tmdb,
        # clear() runs from appDeinit; the externs live in media_remote.m, which
        # build.zig no longer compiles headless.
        "now-playing gated": "const enabled = builtin.os.tag == .macos and !@import(\"build_options\").headless;" in mr
            and mr.count("if (!enabled) return;") >= 2,
        # detectResourceRoot's SDL_GetBasePath — a server resolves from CWD/XDG.
        "resource root gated": "SDL_GetBasePath" in mn
            and '@import("build_options").headless) return;\n    const base = c.sdl.SDL_GetBasePath();' in mn,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "ungated headless call sites: " + ", ".join(missing)
    return "pass", "theme, gallery scroll, now-playing, resource root all comptime-gated"


@test("Docker image drops the S0 GUI stopgap packages", "Headless")
def test_docker_slim_runtime():
    import os as _os
    def rd(p):
        fp = _os.path.join(PROJECT_DIR, p)
        return open(fp).read() if _os.path.exists(fp) else ""
    df = rd("Dockerfile")
    wf = rd(".github/workflows/docker.yml")
    gui_pkgs = ["libx11-6", "libxext6", "libxrandr2", "libxcursor1", "libpulse0", "libasound2", "libgl1"]
    still_there = [p for p in gui_pkgs if p in df]
    checks = {
        "stopgap removed": not still_there,
        # Still needed: torrent/stream path and the nova2 scrapers.
        "runtime deps kept": all(p in df for p in ("libmpv2", "libsqlite3-0", "libtorrent-rasterbar2.0", "ffmpeg", "python3")),
        # macOS can't validate a Linux image — this grep IS the S1 acceptance test.
        "ldd gate is hard": "ldd /usr/local/bin/opal" in wf
            and "sdl|libx11|libxext|libgl|libpulse|libasound" in wf
            and "exit 1" in wf,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        detail = "; ".join(missing)
        if still_there:
            detail += f" (still installed: {', '.join(still_there)})"
        return "fail", "docker slim runtime incomplete: " + detail
    return "pass", "Dockerfile: no X11/GL/pulse/asound; CI fails if they return"
