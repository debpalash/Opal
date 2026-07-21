"""Auto-split from tests/test_features.py — Stability tests.
Byte-for-byte identical test bodies; see tests/features/harness.py for the
shared @test decorator, helpers, and run_all()."""
from .harness import *  # noqa: F401,F403
import os, sys, subprocess, sqlite3, socket, time, json  # noqa: F401

@test("Log Severity By Level", "Stability")
def test_log_severity_by_level():
    # Info/debug/warn logs must not render red: pushLog derives the error flag
    # from `level`, not the inconsistently-set call-site is_error bool (dozens
    # of "info" logs passed true, painting the whole Logs view red).
    lg = _src("src/core/logs.zig")
    if ("effective_error" in lg and 'eqlIgnoreCase(level, "info")' in lg
            and ".is_error = effective_error" in lg):
        return "pass", "log severity derived from level (info/warn/debug never error-red)"
    return "fail", "log severity still keyed on inconsistent is_error bool"


@test("Torrent File Safety: skip executables/archives", "Stability")
def test_torrent_file_safety():
    # A mislabeled/malicious torrent shipping a big .exe/.rar as its largest
    # file must NOT be auto-selected (fed mpv garbage) or auto-opened (malware).
    # The player picks the largest PLAYABLE file via the tested classifier and
    # aborts with a warning when the torrent has no media.
    me = _src("src/core/media_ext.zig")
    pl = _src("src/player/player.zig")
    checks = {
        "classifier": "pub fn isPlayable" in me and "pub fn isExecutableOrArchive" in me,
        "risky set": '"exe"' in me and '"rar"' in me and '"zip"' in me and '"iso"' in me,
        "auto-select uses it": "isPlayable" in pl and "isExecutableOrArchive" in pl,
        "aborts on no media": "-2" in pl and "possible malware" in pl,
        "advance skips non-media": pl.count("media_ext.isPlayable") >= 2,
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "non-media torrent files skipped; executables never auto-opened"
    return "fail", f"missing: {missing}"


@test("Player Init Applies Field Defaults", "Stability")
def test_player_init_defaults():
    # Regression: MediaPlayer.init does `allocator.create` (undefined memory) +
    # field-by-field assignment, so struct-declaration DEFAULTS are NOT applied.
    # Forgotten fields read 0xaa garbage — a garbage dialogue_head/count drove an
    # out-of-bounds crash in updateDialogueRing on the first subtitle. Guard the
    # whole class: every default-valued field MUST be assigned in init.
    import re
    p = _src("src/player/player.zig")
    decl = p.split("pub const MediaPlayer = struct", 1)[-1].split("pub fn init", 1)[0]
    init_body = p.split("pub fn init", 1)[-1].split("return self;", 1)[0]
    default_fields = re.findall(r"^    ([a-zA-Z_]\w*)\s*:\s*[^,]*=\s", decl, re.M)
    missed = [f for f in default_fields
              if not re.search(r"self\." + re.escape(f) + r"\b", init_body)]
    if missed:
        return "fail", "init never assigns default field(s): " + ", ".join(missed[:8])
    return "pass", f"all {len(default_fields)} default-valued fields assigned in init"


@test("Stream Resources Resolvable When Bundled", "Stability")
def test_stream_resource_root():
    # Regression: `python3 engines/nova2.py` (torrent search) is spawned with a
    # RELATIVE path, so a /Applications launch (CWD "/") found nothing → "loading
    # stream not working". Fix: a resource root (SDL_GetBasePath bundle Resources)
    # used as the child cwd, plus engines/ copied into the .app bundle.
    st = _src("src/core/state.zig")
    rv = _src("src/services/resolver.zig")
    sr = _src("src/services/search.zig")
    mn = _src("src/main.zig")
    sh = os.path.join(PROJECT_DIR, "scripts/build-app.sh")
    sh_txt = open(sh).read() if os.path.exists(sh) else ""
    checks = {
        "state.resourceRoot helper": "pub fn resourceRoot()" in st,
        "startup detection": "detectResourceRoot" in mn and "SDL_GetBasePath" in mn,
        "resolver uses cwd": "child.cwd = state.resourceRoot()" in rv,
        "search uses cwd": "child.cwd = state.resourceRoot()" in sr,
        "bundle copies engines/": "Contents/Resources/engines" in sh_txt,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "stream resource wiring missing: " + ", ".join(missing)
    return "pass", "resource-root cwd wired for nova2 + engines/ bundled"


@test("Source Endpoints Externalized To Plugins", "Stability")
def test_sources_externalized():
    # Neutral-player: connector CODE stays in the app, but source URLs/creds are
    # migrated to opal-plugins and read via core/source_config. No installed
    # endpoint → the source is inert. Guard that the migrated sources route
    # through source_config.get and no longer hardcode their URL builder.
    sc = _src("src/core/source_config.zig")
    rv = _src("src/services/resolver.zig")
    sr = _src("src/services/search.zig")
    cm = _src("src/services/comics.zig")
    checks = {
        "source_config.get exists": "pub fn get(" in sc and "plugins/sources" in sc,
        "1337x via config": 'get("1337x"' in rv,
        "yts via config": 'get("yts"' in rv,
        "eztv via config": 'get("eztv"' in sr,
        "readallcomics via config": 'get("readallcomics"' in rv and 'get("readallcomics"' in cm,
        # The old hardcoded URL builders must be gone (validators may remain).
        "no hardcoded 1337x search": '"https://1337x.to/search' not in rv,
        "no hardcoded yts api": "yts.mx/api/v2/list_movies" not in rv,
        "no hardcoded eztv api": "eztvx.to/api/get-torrents" not in sr,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "source externalization gaps: " + ", ".join(missing)
    return "pass", "1337x/yts/eztv/readallcomics endpoints read from installed plugins"


@test("Legal Direct-Play Sources (NASA / Commons / IA-Audio)", "Stability")
def test_legal_directplay_sources():
    # Three legal, DEFAULT-ON direct-play search sources mirror the Internet
    # Archive worker: NASA library, Wikimedia Commons, and an intent-aware IA
    # AUDIO path. Each rides the .stremio source variant (HTTP-direct mpv), runs
    # with NO source_config marker (default-on), and routes JSON parsing through
    # a tested *_pure sibling.
    rv = _src("src/services/resolver.zig")
    npu = _src("src/services/nasa_pure.zig")
    cpu = _src("src/services/commons_pure.zig")
    apu = _src("src/services/archive_pure.zig")
    bz = open(os.path.join(PROJECT_DIR, "build.zig")).read()
    checks = {
        # NASA worker + endpoint + two-stage best-mp4 pick
        "resolveNasa worker": "fn resolveNasa(" in rv,
        "nasa status atomic": "status_nasa" in rv,
        "nasa spawned under stremio": "Spawn.go(resolveNasa, &status_nasa)" in rv,
        "nasa in checkAllDone": "status_nasa.load(.acquire) != .searching" in rv,
        "nasa endpoint": "images-api.nasa.gov/search" in rv,
        "nasa_pure pickBestMp4": "pub fn pickBestMp4(" in npu and "pub fn iterateItems(" in npu,
        "nasa_pure registered": "nasa_pure.zig" in bz,
        # Wikimedia Commons worker + single-fetch endpoint + pages{} parse
        "resolveCommons worker": "fn resolveCommons(" in rv,
        "commons status atomic": "status_commons" in rv,
        "commons spawned under stremio": "Spawn.go(resolveCommons, &status_commons)" in rv,
        "commons in checkAllDone": "status_commons.load(.acquire) != .searching" in rv,
        "commons endpoint": "commons.wikimedia.org/w/api.php" in rv,
        "commons UA policy": "https://github.com/debpalash/Opal" in rv,
        "commons_pure iteratePages": "pub fn iteratePages(" in cpu and "stripFilePrefix" in cpu,
        "commons_pure registered": "commons_pure.zig" in bz,
        # IA audio: intent-aware, no new worker, librivox/etree, VBR>ogg>flac
        "IA audio intent gate": "isAudioIntent" in rv and "pub fn isAudioIntent(" in apu,
        "IA audio best file": "pub fn pickBestAudioFile(" in apu and "pickBestAudioFile(meta)" in rv,
        "IA audio collections": "librivoxaudio" in rv and "etree" in rv,
        "IA default path intact": "mediatype:(movies)" in rv,
        "no bare audio in default": "mediatype:(audio)" not in rv,
        # Default-on: none of the three gate on a source_config marker.
        "nasa not marker-gated": 'get("nasa"' not in rv,
        "commons not marker-gated": 'get("commons"' not in rv,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "legal direct-play wiring gaps: " + ", ".join(missing)
    return "pass", "NASA + Commons + IA-audio wired, default-on, *_pure-routed"


@test("Content Plugin Sandbox Hardened", "Stability")
def test_plugin_sandbox_hardened():
    # Lua content-plugin sandbox: allow_unsafe must require a USER trust marker
    # (plugin can't self-declare its way out), the prelude nils escape vectors
    # (debug library, os.getenv, package paths), and native plugins warn when
    # untrusted. Decision logic lives in plugins_pure.runMode (unit-tested).
    pg = _src("src/services/plugins.zig")
    pgp = _src("src/services/plugins_pure.zig")
    # Prelude closes the debug-library escape + env/package surface.
    prelude_hardened = all(
        s in pg for s in ("debug=nil", "os.getenv=nil", 'package.path=""', 'package.cpath=""')
    )
    # allow_unsafe now gated behind a user-created marker, routed via pure runMode.
    gated = (
        "user_trusted" in pg
        and '".trusted"' in pg
        and "runMode(" in pg
        and "untrustedNative(" in pg
        and "and p.user_trusted" in pg  # allow_unsafe honored only WITH user trust
    )
    # Pure decision + regression tests present.
    pure_ok = (
        "pub fn runMode(" in pgp
        and "pub fn untrustedNative(" in pgp
        and 'test "runMode sandboxes Lua' in pgp
    )
    if not prelude_hardened:
        return "fail", "Lua prelude missing debug/getenv/package hardening"
    if not gated:
        return "fail", "allow_unsafe not gated behind user trust marker via runMode"
    if not pure_ok:
        return "fail", "plugins_pure runMode/tests missing"
    return "pass", "user-trust gate + hardened prelude + native warn, pure-tested"


@test("Playback Repaint Gated + Async UI Wakes", "Stability")
def test_smoothness_repaint():
    # Phase 1 smoothness (GUI/thread-only wiring — verified by presence):
    #  1. the continuous playback refresh no longer runs every frame — it's gated
    #     on the control chrome being visible (mouse active), so immersive watching
    #     falls back to callback-driven, video-fps repaints instead of 60Hz relayout.
    #  2. poster decode workers wake the UI (dvui.refresh) so posters don't pop in
    #     only on incidental repaints.
    #  3. AI chat streaming wakes the UI per token chunk so live text renders.
    mn = _src("src/main.zig")
    ps = _src("src/core/poster.zig")
    ac = _src("src/services/ai_context.zig")
    if "chrome_live" not in mn or "DEFAULT_THRESHOLD_MS" not in mn:
        return "fail", "playback refresh not gated on chrome visibility (main.zig)"
    if "dvui_win" not in ps or "dvui.refresh(win" not in ps:
        return "fail", "poster worker does not wake the UI after decode"
    if "dvui_win" not in ac or "refresh(win" not in ac:
        return "fail", "AI streaming does not wake the UI"
    return "pass", "playback repaint gated; poster + AI-stream wakes wired"


@test("Frame Loop: Seq Ids Reset + Deferred Nav", "Stability")
def test_frame_loop_integrity():
    # Phase 4 (GUI/thread wiring — verified by presence):
    #  1. components.beginFrame() resets the sectionHeader/divider/statusPill
    #     id sequence every frame — without it every one of those widgets is a
    #     "first frame" id and dvui force-refreshes, pinning the app at full
    #     repaint rate whenever Settings or a status pill is visible.
    #  2. navigateToTab from worker threads is deferred through an atomic and
    #     applied on the UI thread (router history writes raced the render read).
    #  3. The native file-open dialog is polled unconditionally in appFrame —
    #     it used to be polled only by the legacy header, so Ctrl+O results were
    #     silently dropped in the default page shell.
    mn = _src("src/main.zig")
    cp = _src("src/ui/components.zig")
    st = _src("src/core/state.zig")
    if "pub fn beginFrame" not in cp or 'components.zig").beginFrame()' not in mn:
        return "fail", "per-frame id sequence reset not wired (components.beginFrame)"
    if "pending_nav" not in st or "applyPendingNav" not in mn:
        return "fail", "worker navigation not deferred to the UI thread"
    if "ui.pollFileOpen()" not in mn:
        return "fail", "file-open dialog not polled from appFrame"
    return "pass", "seq-id reset + deferred nav + file-open poll wired"


@test("Threads Detached (project-wide)", "Stability")
def test_threads_detached():
    # Discarded `_ = std.Thread.spawn(...)` leaks the pthread handle (CLAUDE.md);
    # every spawn must store + detach (or join). Repo-wide sweep is complete, so
    # this guard now walks ALL of src/ and fails if the pattern ever returns.
    offenders = []
    src = os.path.join(PROJECT_DIR, "src")
    for root, _, files in os.walk(src):
        for fn in files:
            if not fn.endswith(".zig"):
                continue
            p = os.path.join(root, fn)
            for i, line in enumerate(open(p).read().splitlines(), 1):
                if "_ = std.Thread.spawn(" in line:
                    offenders.append(f"{os.path.relpath(p, PROJECT_DIR)}:{i}")
    if offenders:
        return "fail", "leaked thread handle(s): " + ", ".join(offenders[:6])
    return "pass", "no discarded std.Thread.spawn handles in src/"


@test("TMDB Fetch Stages Results Off-Thread", "Stability")
def test_tmdb_fetch_stages_results():
    # Regression guard for the renderCatalogRail out-of-bounds crash
    # (2026-07-03): the detached fetch worker cleared/appended the LIVE
    # state.app.tmdb.results list while the UI thread iterated it mid-frame.
    # The fix: workers parse into a local list and stage it (pending_results,
    # under results_mutex); ONLY the UI thread mutates `results`, via
    # applyPendingResults() at frame start.
    api = open(os.path.join(PROJECT_DIR, "src/services/tmdb_api.zig")).read()
    parse_src = open(os.path.join(PROJECT_DIR, "src/services/tmdb_parse.zig")).read()
    main_src = open(os.path.join(PROJECT_DIR, "src/main.zig")).read()
    for needle in ("pending_results", "results_mutex", "fn applyPendingResults"):
        if needle not in api:
            return "fail", f"tmdb_api.zig lost the staged-results swap ({needle})"
    # The live-list clear may exist ONLY inside applyPendingResults (UI thread).
    clear = "results.clearRetainingCapacity()"
    before_apply = api.split("fn applyPendingResults")[0]
    if clear in before_apply.replace("pending_" + clear, ""):
        return "fail", "fetch worker clears the live results list again (UI-render race)"
    if "state.app.tmdb.results.append" in parse_src:
        return "fail", "tmdb_parse.zig appends to the live results list (must parse into `out`)"
    if "applyPendingResults()" not in main_src:
        return "fail", "appFrame no longer applies staged TMDB pages (applyPendingResults)"
    return "pass", "fetch worker stages into pending_results; UI thread owns live list"


@test("SQLite Opened Serialized (Thread-Safe)", "Stability")
def test_sqlite_serialized():
    # The one shared connection is used by the UI thread and background
    # workers; it MUST be opened SQLITE_OPEN_FULLMUTEX (serialized) or
    # concurrent access segfaults inside sqlite3Prepare — the file-open
    # launch crash (DiagnosticReports 2026-07-03 22:06).
    db = open(os.path.join(PROJECT_DIR, "src/core/db.zig")).read()
    if "sqlite3_open_v2" not in db or "SQLITE_OPEN_FULLMUTEX" not in db:
        return "fail", "db.zig no longer opens the connection serialized (FULLMUTEX)"
    return "pass", "shared sqlite connection opened SQLITE_OPEN_FULLMUTEX"


@test("Poster Pixels Freed With C Allocator", "Stability")
def test_poster_pixel_allocator():
    # core/poster.zig fetchAsync allocates pixel buffers with the C allocator;
    # freeing them with the global DebugAllocator aborts the app (freeLarge
    # assert — the 2026-07-03 shutdown crash in freeImageBuffers).
    tmdb = open(os.path.join(PROJECT_DIR, "src/services/tmdb.zig")).read()
    fib = tmdb.split("pub fn freeImageBuffers")[1].split("\n}")[0]
    if "std.heap.c_allocator.free" not in fib:
        return "fail", "freeImageBuffers no longer frees poster pixels via the C allocator"
    if "alloc.free(px)" in fib:
        return "fail", "freeImageBuffers frees c_alloc pixels with the debug allocator again"
    return "pass", "fetchAsync-owned poster pixels freed with the matching C allocator"


@test("Windows Port: Source Invariants", "Stability")
def test_windows_port_invariants():
    # The x86_64-windows-gnu port is comptime-gated (windows arms never run
    # natively), so guard its load-bearing invariants at source level. The
    # real gate is `zig build -Dtarget=x86_64-windows-gnu` reaching the link
    # stage with zero sema errors; these checks catch accidental regressions
    # of the arms that made that possible.
    build = _src("build.zig")
    if "MINGW_PREFIX" not in build:
        return "fail", "build.zig lost the MINGW_PREFIX env handling for Windows"
    if "torrent_wrapper.dll" not in build:
        return "fail", "build.zig no longer produces torrent_wrapper.dll on Windows"
    if "libmpv.dll.a" not in build or "libsqlite3.dll.a" not in build or "libonnxruntime.dll.a" not in build:
        return "fail", "build.zig lost the MinGW .dll.a import-lib objects (zig -l search never finds lib{name}.dll.a)"
    iog = _src("src/core/io_global.zig")
    if 'extern "kernel32" fn Sleep' not in iog:
        return "fail", "io_global.sleep lost its kernel32 Sleep arm (nanosleep does not exist on Windows)"
    if "terminateProcess" not in iog or "TerminateProcess" not in iog:
        return "fail", "io_global lost the portable terminateProcess helper"
    sync = _src("src/core/sync.zig")
    if "SRWLockExclusive" not in sync:
        return "fail", "sync.Mutex lost its SRWLOCK arm (std.c.pthread_mutex_t is void on Windows)"
    paths = _src("src/core/paths.zig")
    if "APPDATA" not in paths or "LOCALAPPDATA" not in paths:
        return "fail", "paths.zig lost the %APPDATA%/%LOCALAPPDATA% Windows arms"
    # posix kill/raw nanosleep outside io_global are Windows compile blockers.
    sl = _src("src/services/streamlink.zig")
    if "std.posix.kill" in sl:
        return "fail", "streamlink regressed to std.posix.kill (breaks Windows compile); use io_global.terminateProcess"
    return "pass", "MINGW_PREFIX + dll.a link + win arms in io_global/sync/paths intact"


@test("Torrent streaming: readiness gate + per-container index", "Stability")
def test_stream_readiness_gate():
    # A 1080p MKV at 11% with 69 seeds sat black at 00:00 forever. Two bugs:
    #
    #  1. mpv was launched as soon as ONE piece existed. But mpv's Matroska
    #     demuxer SEEKS TO EOF during open to read the Cues + Tags, so it blocked
    #     inside demux_mkv_open() before creating a single track, waiting on bytes
    #     nothing had prioritized. Head progress was irrelevant.
    #  2. The proxy TRUNCATED the body on a read timeout after promising a
    #     Content-Length. ffmpeg cannot tell a read error from EOF, so mpv decided
    #     the file had ended and gave up -- which is why downloading more never
    #     helped.
    cp = _src("src/player/container_pure.zig")
    gate = _src("src/player/stream_gate.zig")
    pl = _src("src/player/player.zig")
    px = _src("src/player/stream_proxy.zig")
    cpp = _src("src/torrent_wrapper.cpp")
    hdr = _src("src/torrent_wrapper.h")
    gr = _src("src/ui/grid.zig")
    bz = _src("build.zig")

    checks = {
        # Different containers demand different bytes -- that IS the feature.
        "per-container plan": ("pub fn initialPlan(" in cp and "pub fn refine(" in cp
                               and "pub fn needsTail(" in cp),
        "mkv reads its own SeekHead": "fn mkvIndexOffset(" in cp,
        "mp4 finds moov (faststart => no tail)": "fn mp4MoovOffset(" in cp,
        "avi finds idx1": "fn aviIndexOffset(" in cp,
        # Linear formats must NOT be made to wait for a tail that doesn't exist.
        "ts/flv need no tail": ".ts, .flv => false" in cp,
        # Byte-sized, never piece-sized: "last 5 pieces" is 5MB at 1MB pieces and
        # 80MB at 16MB pieces.
        "tail measured in bytes": "TAIL_FALLBACK_BYTES" in cp,
        "pure registered": "container_pure.zig" in bz,

        # The gate itself.
        "gate exists": "pub fn isReady(" in gate and "container_pure.zig" in gate,
        # It must wait on as LITTLE as possible. Waiting for the whole head + the
        # index was correct but needlessly slow: an 8 MB/s torrent still showed
        # "Buffering 87%". Playback now waits only for START_BYTES; the rest of the
        # head and the index at EOF keep racing at top priority behind it, which is
        # safe only because the tail is now prioritized and the proxy no longer
        # truncates (the two things that caused the original black screen).
        "starts on a small head, not the whole thing": ("START_BYTES" in cp
                                                        and "cp.START_BYTES" in gate),
        "index keeps racing after start": "index still racing" in gate,
        "player waits on the gate": "stream_gate.zig" in pl and "gate.isReady(" in pl,
        "no more instant start": "START PLAYBACK IMMEDIATELY" not in pl,

        # C++ byte-range primitives the gate needs.
        "range primitives": all(f in hdr and f in cpp for f in (
            "torrent_range_ready", "torrent_prioritize_range", "torrent_range_progress")),
        # Priorities BEFORE deadlines: prioritize_pieces() calls
        # remove_time_critical_pieces(), so the reverse order silently drops them.
        "priorities before deadlines": (cpp.index("prioritize_pieces(prios)")
                                        < cpp.index("set_piece_deadline(lt::piece_index_t(p), dl)")),

        # Never truncate a body we promised a Content-Length for.
        "proxy never truncates": "aborting so the player reconnects" in px,
        # A network timeout reaches ffmpeg as a fake EOF.
        "no network timeout": '"network-timeout", "0"' in pl,

        # The bar must report readiness, not whole-torrent progress.
        "buffer bar shows readiness": "gate.bufferPercent(" in gr,

        # CRASH REGRESSION: load_file blanks the video texture, but `pixels` is
        # allocated at video_w*video_h while the texture is created in grid.zig at
        # the current RENDER size. dvui's Texture.update hard-@panics on a length
        # mismatch (it is not a catchable error, so the `catch {}` was decoration),
        # so reloading a file while a texture was alive aborted the process with
        # "Texture size and supplied Content did not match". Slice to the texture.
        "texture update sliced to texture size": ("const npix = @as(usize, tex.width) * @as(usize, tex.height);" in pl
                                                  and "self.pixels[0..npix]" in pl),
        # A read of 0 is a legitimate EOF; only a NEGATIVE read is a failure that
        # must abort the connection. Treating 0 as failure aborted every clean end.
        "eof is not an error": "if (read == 0) break;" in px and "if (read < 0) {" in px,
        # A mid-stream buffering reload must resume where it was, not fall back to
        # the coarse watch-history percent (which visibly jumps playback backwards).
        "buffering reload keeps position": '"percent-pos", c.mpv.MPV_FORMAT_DOUBLE, &cur_pct' in pl,
        # REGRESSION: loadfile used to implicitly end the previous file. Now that we
        # wait for a readable head before calling it, nothing stopped the old media
        # -- picking a new episode left the PREVIOUS one playing, audio and all,
        # behind the buffering overlay with its timeline still ticking.
        "new torrent stops the old playback": ('mpv_command_string(p.mpv_ctx, "stop")'
                                               in _src("src/services/search.zig")),
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "missing: " + ", ".join(missing)
    return "pass", "head+index gate, per-container tail (mkv/mp4/avi/ts), no truncation"


@test("Title-bar resource meters", "Stability")
def test_sysmeter():
    # CPU / MEM / THR / NRG in the OS title bar, folded into the window title as
    # text. There is no dvui widget: SDL2 gives no drawable surface up there.
    mon = _src("src/core/sysmon.zig")
    pur = _src("src/core/sysmon_pure.zig")
    sh = _src("src/ui/shell.zig")
    mn = _src("src/main.zig")
    bz = _src("build.zig")
    checks = {
        "sampler exists": "pub fn start() void" in mon and "pub fn get() Snapshot" in mon,
        "started at launch": 'core/sysmon.zig").start()' in mn,
        # The meters are NOT a dvui widget any more — they're text in the window
        # title, so there is no in-app strip to mount (and no duplicate row).
        "no duplicate in-app strip": "renderTitleStrip" not in sh,
        # Every reading is a syscall. Sampling per-frame on the UI thread would
        # cost more than the thing it measures.
        "sampled off-thread at 1Hz": ("std.Thread.spawn" in mon and ".detach()" in mon
                                      and "io.sleep(1000 * std.time.ns_per_ms)" in mon),
        # CPU is a RATE: it needs two samples. The first tick can only guess, so
        # the meters hide rather than show a confident zero (or a 100% spike).
        "no reading before a real delta": "valid" in mon and "snap.valid" in mn,
        # Thresholds/clamping/formatting are decided in the tested pure module.
        "decisions are pure + tested": all(f in pur for f in
                                           ("pub fn frac(", "pub fn levelOf(", "pub fn energyImpact(",
                                            "pub fn fmtBytes(")),
        "title routes through pure": all(f in pur for f in ("cpuMetric(", "memMetric(", "titleMeters(")),
        "pure registered": "sysmon_pure.zig" in bz,
        # mach hands us VM-allocated arrays and thread ports. Leaking them every
        # second inside the thing that MEASURES leaks would be quite the own goal.
        "mach allocations freed": ("vm_deallocate" in mon and "mach_port_deallocate" in mon),
        # Real syscalls, not a stub.
        "real syscalls": all(f in mon for f in ("host_statistics64", "host_processor_info",
                                                "task_threads", "TASK_POWER_INFO")),
        # Energy has no public power API; deriving it from CPU alone would be a
        # plausible-but-wrong number, so wakeups go in and it's labelled a score.
        "energy is honest": "wakeups" in pur and "not watts" in pur,
        "clock via io_global": "std.time.timestamp" not in mon,
        # The meters render IN the OS title bar — as TEXT, folded into the window
        # title. SDL2 gives no drawable surface up there: the content view can be
        # extended under the title bar, but SDL keeps rendering into the old,
        # shorter rect, so dvui's y=0 never moves (measured: SDL reported 1244x771
        # before AND after). What the OS does render there is the title string.
        "meters in the window title": "titleMeters" in _src("src/main.zig"),
        "bar glyph per metric": "barGlyph" in pur,
        # A partial run ("CPU ▃ 12%   MEM ▅ 1.2") would read as a bug, and the
        # title must survive regardless — so a short buffer yields nothing.
        "no truncated meter run": 'catch ""' in pur,
        # No confident "CPU 0%" before the first delta lands.
        "hidden until first sample": "snap.valid" in _src("src/main.zig"),
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "missing: " + ", ".join(missing)
    return "pass", "CPU/MEM/THR/NRG meters: 1Hz off-thread sampler, tested thresholds"


@test("Search subprocesses reaped on shutdown", "Stability")
def test_search_workers_reaped():
    # A superseded/detached nova2.py torrent search can outlive a clean exit and
    # orphan its Python multiprocessing pool. appDeinit sweeps them; dev.sh too.
    sr = _src("src/services/search.zig")
    mn = _src("src/main.zig")
    dev = _src("dev.sh")
    checks = {
        "reapWorkers exists": "pub fn reapWorkers(" in sr and "engines/nova2.py" in sr,
        "os-gated pkill": '"pkill"' in sr and "builtin.os.tag" in sr,
        "appDeinit calls it": "search.reapWorkers()" in mn,
        "dev.sh reaps too": "pkill -f engines/nova2.py" in dev,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "reap wiring incomplete: " + ", ".join(missing)
    return "pass", "nova2.py search workers reaped on clean shutdown (appDeinit + dev.sh)"
