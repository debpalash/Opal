const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const c = @import("core/c.zig");
const state = @import("core/state.zig");
const logs = @import("core/logs.zig");
const metadata_dialog = @import("ui/metadata_dialog.zig");
const player = @import("player/player.zig");
const search = @import("services/search.zig");
const transfers = @import("services/transfers.zig");
const ui = @import("ui/ui.zig");
const input = @import("ui/input.zig");
const theme = @import("ui/theme.zig");
const drawer = @import("ui/drawer.zig");
const hist = @import("services/history.zig");

// v2: rolling-window frame timing for the debug HUD.
const HUD_WINDOW: usize = 60;
var hud_samples: [HUD_WINDOW]f32 = std.mem.zeroes([HUD_WINDOW]f32);
var hud_cursor: usize = 0;
var hud_last_ms: i64 = 0;

// Window reference for SDL position/size persistence
var dvui_win: ?*dvui.Window = null;

// ── CLI open-file deferred buffer ──
// Stored in appInit, consumed in appFrame once players are ready.
var cli_open_buf: [2048]u8 = std.mem.zeroes([2048]u8);
var cli_open_len: usize = 0;
var cli_open_done: bool = false;

// One-shot latch: apply the device-aware default ui_scale on the first frame
// after config has loaded (needs dvui.windowNaturalScale(), only valid inside a
// frame). Runtime-only — recomputed each launch so moving to a different-DPI
// display picks a fresh default.
var device_scale_applied: bool = false;

pub const dvui_app: dvui.App = .{
    .config = .{ .options = .{ .size = .{ .w = 1400.0, .h = 820.0 }, .title = "Opal — Play everything" } },
    .initFn = appInit,
    .frameFn = appFrame,
    .deinitFn = appDeinit,
};

// Entry point is selected at COMPILE time. dvui's App interface comptime-
// requires `root.main == dvui.App.main` exactly (see App.zig get()), so a
// runtime dispatcher that conditionally calls dvui.App.main is impossible
// (it forms an inferred-error-set dependency loop). Instead the headless
// server build (`zig build -Dheadless=true`) swaps the entry point entirely.
// The default desktop build is byte-identical: `pub const main = dvui.App.main`.
pub const main = if (@import("build_options").headless)
    headlessEntry
else
    dvui.App.main;

fn headlessEntry(_: std.process.Init) !u8 {
    // -Dheadless builds are always headless; gate the render/bind branches.
    state.app.is_headless = true;
    try @import("headless.zig").headlessMain();
    return 0;
}

pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn, .log_level = .warn };

/// Window-independent core initialization. Shared by the windowed entry
/// (appInit) and the headless server entry (headless.headlessMain). Runs
/// every startup step that does NOT require a dvui.Window: paths, theme,
/// deps, sherpa promotion, the first MediaPlayer, the torrent worker, the
/// remote JSON API, and the background DB/library load thread. Nothing here
/// reads dvui_win / state.app.dvui_win, so the window may be assigned after.
pub fn coreInit() !void {
    // One-time legacy rename: ~/.config/zigzag → ~/.config/opal (+ cache + the
    // db file). MUST run before any path is read. Idempotent.
    @import("core/paths.zig").migrateLegacyDir();

    // Runtime initialization (env vars can't be read at comptime)
    state.initPaths();
    state.loadTmdbTokenFromEnv();

    theme.setTheme();
    logs.logs_allocator = @import("core/alloc.zig").allocator;

    // Bootstrap: fetch whisper tiny model (39MB) in background if missing.
    // Skips if already present. Binaries (apfel/ffmpeg/whisper-cpp) must
    // come via brew — we only surface install hints via deps.installCmd.
    @import("core/deps.zig").fetchWhisperModelAsync();

    // Phase 5 default-promotion — if every sherpa piece is present
    // (CLIs + STT + TTS + streaming models), switch voice backend to
    // sherpa-onnx silently. User can still override in Settings.
    {
        const deps = @import("core/deps.zig");
        const vb = @import("services/voice_backend.zig");
        if (deps.sherpaReady(deps.check())) {
            vb.active_kind = .sherpa_onnx;
        }
        // Parakeet promotion outranks it: when the self-installed
        // conversational stack (voice_setup) is present, default to the
        // fastest ASR we ship. Settings choice still overrides afterwards.
        if (@import("services/voice_setup.zig").convoReady()) {
            vb.active_kind = if (@import("services/voice_setup.zig").parakeetV3Present())
                .parakeet_tdt_v3
            else
                .parakeet_tdt_v2;
        }
    }
    state.app.players = .empty;
    search.search_results = .empty;

    // Init torrent session in background — DHT bootstrap takes 5-10s
    state.setTorrentSession(null);
    if (std.Thread.spawn(.{}, struct {
        fn worker() void {
            state.setTorrentSession(c.mpv.torrent_init());
            // Fresh session defaults to unlimited — re-apply the persisted cap
            // if config already loaded (idempotent; config load covers the
            // reverse ordering).
            state.applyDownloadLimitIfReady();
            logs.pushLog("info", "torrent", "Torrent session ready", false);
        }
    }.worker, .{})) |t| t.detach() else |_| {}

    std.Io.Dir.cwd().createDirPath(@import("core/io_global.zig").io(), state.app.save_path_buf[0..state.app.save_path_len]) catch {};
    try state.app.players.append(@import("core/alloc.zig").allocator, try player.MediaPlayer.init(@import("core/alloc.zig").allocator));

    // Web Remote API is OPT-IN: nothing listens on app start unless the user
    // enabled it (Settings › Scripts › Web Remote Control, persisted as
    // "web_remote" — config.zig starts the server on load when it's on).
    // Trade-off: the OpalMenubar helper and web/ UI can't reach the app until
    // the toggle is on.

    // Move heavy DB/migration/loading work to background so UI renders instantly
    if (std.Thread.spawn(.{}, struct {
        fn worker() void {
            // ── Unified SQLite Database ──
            const database = @import("core/db.zig");
            database.init();

            // Restore starred AI chat messages before anything else touches
            // the message array.
            @import("services/ai_chat.zig").loadStarredFromDb();

            // Migrate old flat files → SQLite (one-time, idempotent)
            const config = @import("core/config.zig");
            config.migrateFromTsv();

            const tmdb_store = @import("services/tmdb_store.zig");
            tmdb_store.migrateFromTsv();

            // ── RSS Feeds ──
            const rss = @import("services/rss.zig");
            rss.init();
            tmdb_store.migrateOldDb();

            hist.migrateSearchHistory();
            hist.migrateDownloadHistory();

            const watch = @import("player/watch_history.zig");
            watch.migrateFromTsv();

            // One-time cleanup of LLM-plumbing strings that leaked into
            // conversation_log in prior sessions (pre-filter fix). Without
            // this, "[tool_call]/[tool_response]" stubs show up in the
            // Past Sessions context and the model echoes the pattern.
            @import("services/ai_memory.zig").purgeJunkConversations();

            // Load all persistent data from SQLite
            config.load();

            // Encrypted persistent content cache: load (or generate) the local
            // key and sweep expired/oversized entries. Runs here on the bg init
            // thread so cold-start views can read cached copies immediately.
            @import("core/content_cache.zig").init();

            // Resource meters in the title bar. Samples on its own thread at 1 Hz
            // — every reading is a syscall, and a meter that costs more than the
            // thing it measures would be a bad joke.
            @import("core/sysmon.zig").start();



            // Page-shell preview opt-in (redesign, WIP). Enable with
            // OPAL_PAGE_SHELL=1 to render the new website-like layout.
            if (@import("core/io_global.zig").getenv("OPAL_PAGE_SHELL")) |v| {
                state.app.page_shell_enabled = !(v.len == 1 and v[0] == '0');
            }
            hist.loadSearchHistory();
            hist.loadDownloadHistory();
            watch.load();
            watch.checkBackup(); // arms the "Restore cleared history" affordance
            // Load installed source endpoints (opal-plugins). No file → every
            // gated source stays inert until the user installs it.
            @import("core/source_config.zig").reload();
            @import("services/plugin_repo.zig").init(); // load saved GitHub token
            @import("services/trakt.zig").init(); // load saved Trakt credentials/token
            @import("services/plex.zig").init(); // load saved Plex token/server
            // DPI-bypass proxy sidecar: config.load() above restored the flag +
            // mode, so start the loopback proxy now if the user enabled it.
            if (state.app.dpi_bypass_enabled) @import("services/dpi_bypass.zig").start();
            // Signal the UI thread that watch history is ready so the "resume
            // last played?" launch prompt can arm (monotonic one-way flag).
            state.app.init_history_loaded = true;
            tmdb_store.loadLists();

            // Route warm-up — kick the most-visited browse fetches from this bg
            // init thread so Home/Browse/Anime are already populated before the
            // user navigates there, instead of a cold network wait on first open.
            // Each warm fn spawns its own worker and is idempotent via the render
            // latches (tmdb.loaded_once / anime.has_loaded_trending /
            // is_loading / SWR stamp), so a later navigation reuses the result
            // rather than refetching; results also seed the encrypted content
            // cache for the next cold start. Best-effort: no key → fetchCurrentView
            // no-ops and the normal on-navigation fetch takes over.
            if (state.app.tmdb.api_key_len > 0 and !state.app.tmdb.loaded_once) {
                state.app.tmdb.loaded_once = true; // Home/Browse must not refetch over this
                @import("services/tmdb_api.zig").fetchCurrentView(false);
            }
            @import("services/anime.zig").loadTrendingAnime();
            @import("services/tv_calendar.zig").refreshOnce();

            // Ensure yt-dlp binary is available
            const ytdlp = @import("services/ytdlp.zig");
            ytdlp.ensureAvailable();

            // Probe GitHub for a newer release (non-blocking). Result
            // surfaces in Settings → About.
            @import("services/updater.zig").checkAsync();

            logs.pushLog("info", "init", "Background init complete", false);
        }
    }.worker, .{})) |t| t.detach() else |_| {}
}

/// Find the directory holding bundled runtime resources (engines/, scripts/, …).
/// Dev launches already have these reachable from the CWD; a /Applications launch
/// has CWD "/", so fall back to the macOS bundle's Resources dir via
/// SDL_GetBasePath. Result stored in state.app.resource_root (empty = use CWD).
fn detectResourceRoot() void {
    const io_g = @import("core/io_global.zig");
    // Dev / launched-from-project: engines/ is already reachable from the CWD.
    if (io_g.cwdAccess("engines/nova2.py", .{})) |_| return else |_| {}

    // Bundled: SDL_GetBasePath() → "<App>/Contents/Resources/" (trailing slash).
    const base = c.sdl.SDL_GetBasePath();
    if (base == null) return;
    defer c.sdl.SDL_free(base);
    const base_slice = std.mem.span(base);
    if (base_slice.len == 0 or base_slice.len >= state.app.resource_root.len) return;

    // Commit only if engines/ actually lives there.
    var probe: [1100]u8 = undefined;
    const probe_path = std.fmt.bufPrint(&probe, "{s}engines/nova2.py", .{base_slice}) catch return;
    io_g.cwdAccess(probe_path, .{}) catch return;

    @memcpy(state.app.resource_root[0..base_slice.len], base_slice);
    state.app.resource_root_len = base_slice.len;
    logs.pushLog("info", "init", "Using bundled resource root", false);
}

fn appInit(win: *dvui.Window) !void {
    // ── CLI argument handling (before anything heavy starts) ──
    // `opal /path/to/file.mp4` or `opal https://example.com/stream`
    // Deferred: store in buffer, appFrame loads after player is ready.
    if (dvui.App.main_init) |init_data| {
        // Windows requires the allocating iterator (argv arrives as one
        // WTF-16 command line that must be split); POSIX iterates in place.
        var args_iter = if (builtin.os.tag == .windows)
            init_data.minimal.args.iterateAllocator(@import("core/alloc.zig").allocator) catch return
        else
            init_data.minimal.args.iterate();
        defer args_iter.deinit(); // no-op on POSIX
        _ = args_iter.next(); // skip argv[0] (binary name)
        if (args_iter.next()) |arg| {
            const len = @min(arg.len, cli_open_buf.len - 1);
            @memcpy(cli_open_buf[0..len], arg[0..len]);
            cli_open_len = len;
            std.debug.print("[CLI] Will open: {s}\n", .{cli_open_buf[0..len]});
        }
    }

    // Single-instance: if another Opal already serves the local JSON API, hand
    // it our argument and quit instead of opening a second window. Connection
    // failure (no instance, or Web Remote off) → normal startup below.
    if (cli_open_len > 0 and forwardToRunningInstance(cli_open_buf[0..cli_open_len])) {
        std.debug.print("[CLI] Forwarded to running instance, exiting.\n", .{});
        std.process.exit(0);
    }

    // Record THIS (UI/render) thread so theme.applyToDvui can tell UI-thread
    // calls from background-worker calls (config.load → setPreset). Must run
    // before coreInit spawns the DB/library worker that applies the saved theme.
    theme.markUiThread();

    // Window-independent startup first. Nothing in coreInit reads dvui_win,
    // so assigning the window afterwards is safe (and lets headless mode
    // reuse coreInit without a window).
    try coreInit();

    // Store window ref for position/size persistence
    dvui_win = win;
    // Also mirror into state.app so worker threads (mpv render-update
    // callback, etc.) can wake the UI via dvui.refresh from any thread.
    state.app.dvui_win = win;

    // Seed the chrome idle clock so the control overlay starts visible for the
    // usual idle window instead of instantly hidden (last_mouse_move_ms == 0
    // would read as "idle for 56 years").
    state.app.last_mouse_move_ms = @import("core/io_global.zig").milliTimestamp();

    // Register SDL Event Watch for file drops (must be on main thread)
    _ = c.sdl.SDL_EventState(c.sdl.SDL_DROPFILE, c.sdl.SDL_ENABLE);
    c.sdl.SDL_AddEventWatch(sdlEventWatch, null);

    // Locate bundled resources (engines/ etc.) so streaming works when launched
    // from /Applications (CWD "/"), not just from the project dir in dev.
    detectResourceRoot();
}

/// Second-instance forwarding: POST our file/URL argument to an already-
/// running Opal's JSON API (remote.zig /api/open) and return true so the
/// caller exits instead of starting a second UI. Authenticates with the same
/// bearer token the running instance persists to <configDir>/api.token —
/// readable here because both instances run as the same user. Any failure
/// (nothing listening, no token, non-2xx) → false → normal startup. A
/// 127.0.0.1 connect succeeds or is refused immediately, so no explicit
/// timeout plumbing is needed.
fn forwardToRunningInstance(arg: []const u8) bool {
    const io_g = @import("core/io_global.zig");
    const sip = @import("services/single_instance_pure.zig");

    var dir_buf: [512]u8 = undefined;
    var tok_path_buf: [768]u8 = undefined;
    const tok_path = std.fmt.bufPrint(&tok_path_buf, "{s}/api.token", .{
        @import("core/paths.zig").configDir(&dir_buf),
    }) catch return false;
    var tok_file = io_g.openFileAbsolute(tok_path, .{}) catch return false;
    var tok_buf: [32]u8 = undefined; // TOKEN_HEX_LEN in remote.zig
    const tok_n = io_g.readAll(tok_file, &tok_buf) catch 0;
    tok_file.close(io_g.io());
    if (tok_n != tok_buf.len) return false;

    var url_buf: [6300]u8 = undefined; // worst case: 2048 arg bytes ×3 encoded
    const url = sip.buildOpenUrl(@import("services/remote.zig").port, arg, &url_buf) orelse return false;
    var auth_buf: [48]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{tok_buf[0..tok_n]}) catch return false;

    var client = std.http.Client{ .allocator = @import("core/alloc.zig").allocator, .io = io_g.io() };
    defer client.deinit();
    const uri = std.Uri.parse(url) catch return false;
    var req = client.request(.POST, uri, .{ .extra_headers = &.{
        .{ .name = "Authorization", .value = auth },
    } }) catch return false;
    defer req.deinit();
    // POST requires a body path in 0.16's client (sendBodiless asserts) —
    // send an explicit empty body / Content-Length: 0.
    var empty_body: [0]u8 = .{};
    req.sendBodyComplete(&empty_body) catch return false;
    var redirect_buf: [4096]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return false;
    return response.head.status.class() == .success;
}

pub fn appDeinit() void {
    // Stop conversation/voice mode
    const voice = @import("services/ai_voice.zig");
    voice.conversation_active.store(false, .release);
    voice.is_recording.store(false, .release);
    voice.is_speaking.store(false, .release);

    // Settle in-flight download/decode workers (comic pages, comic covers, yt
    // thumbnails) before we free the buffers they publish into — otherwise the
    // leak check races their still-live tmp_buf/p_slice. Workers poll isQuitting
    // in their read loops, so this drains in well under the timeout.
    @import("core/workers.zig").beginShutdownAndDrain(800);

    // Drop the macOS Now Playing card before the players go away (no-op elsewhere).
    @import("player/media_remote.zig").clear();

    // Clean up players natively to prevent memory leaks
    for (state.app.players.items) |p| {
        p.deinit(@import("core/alloc.zig").allocator);
    }
    state.app.players.deinit(@import("core/alloc.zig").allocator);

    // Free any poster pixel buffers the renderer never consumed, then arrays.
    @import("services/tmdb.zig").freeImageBuffers();
    // Free downloaded comic page pixels (decoded-but-unviewed pages keep their
    // heap buffer until the texture is uploaded).
    @import("services/comics.zig").freeComicPages();
    // Free search-result cover pixels the renderer never uploaded.
    @import("services/comics.zig").freeSearchCovers();

    // Clean up UI arrays
    state.app.tmdb.results.deinit(@import("core/alloc.zig").allocator);
    state.app.tmdb.pending_results.deinit(@import("core/alloc.zig").allocator);
    state.app.tmdb.favorites.deinit(@import("core/alloc.zig").allocator);
    state.app.tmdb.watchlist.deinit(@import("core/alloc.zig").allocator);
    state.app.tmdb.watching.deinit(@import("core/alloc.zig").allocator);
    // Stop the embedded Suwayomi server (if Opal launched one) so no JVM is left
    // orphaned after exit.
    @import("services/suwayomi_server.zig").stopEmbedded();
    // Frees per-item thumb_pixels + the index-aligned date arrays, then the list.
    @import("services/youtube.zig").deinit();
    // Playlist drawer caches (filter match flags + shuffle order).
    @import("player/playlist.zig").deinitModule();

    // Join search thread so its defers (free query, deinit argv) run cleanly
    search.search_abort.store(true, .release);
    if (search.search_thread) |t| t.join();
    search.search_thread = null;

    search.clearResults();
    search.search_results.deinit(@import("core/alloc.zig").allocator);

    // Tear down the DPI-bypass proxy sidecar (no-op if it was never started).
    @import("services/dpi_bypass.zig").stop();

    // Kill any spawned child processes that may still be running
    const kill_targets = [_][]const u8{
        "aplay.*opal",
        "kittentts",
        "opal-stt",
        "opal-tts-server",
        "opal-stt-server",
        "opal-voice-server",
        "rec.*opal_ai_mic",
    };

    for (kill_targets) |target| {
        var child = @import("core/io_global.zig").Child.init(
            &.{ "pkill", "-f", target },
            @import("core/alloc.zig").allocator,
        );
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        _ = child.spawnAndWait() catch {};
    }

    // llama-server (AI backend)
    const server = @import("services/ai_server.zig");
    server.stopServer();

    // Release the process-global keep-alive HTTP client (pooled connections)
    // so the leak report below stays at 0. Workers are already stopped here.
    @import("core/http.zig").deinit();

    // Free log entries to prevent GPA leak reports
    logs.deinit();

    // Trigger GeneralPurposeAllocator leak dump on exit
    @import("core/alloc.zig").deinit();
}

fn hexVal(ch: u8) ?u8 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
    return null;
}

fn isDirectory(path: []const u8) bool {
    if (path.len == 0) return false;
    var dir = if (path[0] == '/')
        @import("core/io_global.zig").openDirAbsolute(path, .{ .iterate = false }) catch return false
    else
        @import("core/io_global.zig").cwdOpenDir(path, .{ .iterate = false }) catch return false;
    dir.close(@import("core/io_global.zig").io());
    return true;
}

const media_exts = [_][]const u8{ ".mp4", ".mkv", ".avi", ".webm", ".mov", ".flv", ".ts", ".mp3", ".flac", ".wav", ".ogg", ".m4a", ".opus" };

fn isMediaFile(name: []const u8) bool {
    for (media_exts) |ext| {
        if (name.len > ext.len and std.ascii.eqlIgnoreCase(name[name.len - ext.len ..], ext)) return true;
    }
    return false;
}

fn scanDirForMedia(pl: *@import("player/m3u.zig").M3UPlaylist, dir_path: []const u8) void {
    var dir = if (dir_path.len > 0 and dir_path[0] == '/')
        @import("core/io_global.zig").openDirAbsolute(dir_path, .{ .iterate = true }) catch return
    else
        @import("core/io_global.zig").cwdOpenDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close(@import("core/io_global.zig").io());
    var it = dir.iterate();
    while (it.next(@import("core/io_global.zig").io()) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!isMediaFile(entry.name)) continue;
        // Build full absolute path
        var full_buf: [4096]u8 = undefined;
        const full_path = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        pl.entries.append(pl.allocator, .{
            .title = pl.allocator.dupe(u8, entry.name) catch continue,
            .url = pl.allocator.dupe(u8, full_path) catch continue,
            .logoUrl = null,
            .group = pl.allocator.dupe(u8, "Local") catch null,
        }) catch {};
    }
}

fn sdlEventWatch(_: ?*anyopaque, event: [*c]c.sdl.SDL_Event) callconv(.c) c_int {
    const t = event.*.type;
    // Log drops or unknown things to see what Wayland is sending
    if (t >= c.sdl.SDL_DROPFILE and t <= c.sdl.SDL_DROPCOMPLETE) {
        std.debug.print("[SDL_EVENT] Wayland event type: {d}\n", .{t});
    }

    if (t == c.sdl.SDL_DROPFILE) {
        state.app.dropped_file_lock.lock();
        defer state.app.dropped_file_lock.unlock();
        if (event.*.drop.file) |file_c_str| {
            var span = std.mem.span(file_c_str);
            if (std.mem.startsWith(u8, span, "file://")) {
                span = span[7..];
            }
            // URL-decode %XX sequences (e.g. %20 → space)
            var decoded: [2048]u8 = undefined;
            var di: usize = 0;
            var si: usize = 0;
            while (si < span.len and di < decoded.len - 1) {
                if (span[si] == '%' and si + 2 < span.len) {
                    const hi = hexVal(span[si + 1]);
                    const lo = hexVal(span[si + 2]);
                    if (hi != null and lo != null) {
                        decoded[di] = hi.? * 16 + lo.?;
                        di += 1;
                        si += 3;
                        continue;
                    }
                }
                decoded[di] = span[si];
                di += 1;
                si += 1;
            }
            std.debug.print("[SDL_DROP] Got dropped file: {s}\n", .{decoded[0..di]});
            @memcpy(state.app.dropped_file_path[0..di], decoded[0..di]);
            state.app.dropped_file_path[di] = 0;
            state.app.dropped_file_len = di;
            state.app.dropped_file_ready = true;
            c.sdl.SDL_free(file_c_str);
        }
    }
    return 1;
}

/// Slash command menu — shows a floating list of known commands when
/// input starts with '/'. Click fills the input with the command.
fn renderSlashMenu() void {
    const text_len = std.mem.indexOfScalar(u8, &state.app.magnet_buf, 0) orelse state.app.magnet_buf.len;
    if (text_len == 0) return;
    if (state.app.magnet_buf[0] != '/') return;

    const Cmd = struct {
        key: []const u8,
        desc: []const u8,
        /// Single-word no-arg command — clicking runs it immediately
        /// via ai_chat's unified submit (which routes through
        /// tryInstantCommand). Commands with a trailing space require
        /// user input after — just fill the box, don't execute.
        instant: bool = false,
        /// Plain-text form to dispatch (drops the '/').
        send_as: []const u8 = "",
    };
    const cmds = [_]Cmd{
        .{ .key = "/play ", .desc = "Search + play best match — play iron man 3" },
        .{ .key = "/find ", .desc = "Search only, show results" },
        .{ .key = "/watch ", .desc = "Alias for /play" },
        .{ .key = "/pause", .desc = "Pause current playback", .instant = true, .send_as = "pause" },
        .{ .key = "/resume", .desc = "Resume playback", .instant = true, .send_as = "play" },
        .{ .key = "/seek ", .desc = "Jump to time — /seek 1:23" },
        .{ .key = "/volume ", .desc = "Set volume 0-100" },
        .{ .key = "/mute", .desc = "Toggle mute", .instant = true, .send_as = "mute" },
        .{ .key = "/fullscreen", .desc = "Toggle fullscreen", .instant = true, .send_as = "fullscreen" },
        .{ .key = "/subtitles", .desc = "Cycle subtitle tracks", .instant = true, .send_as = "next subtitle" },
        .{ .key = "/queue ", .desc = "Add URL to queue" },
        .{ .key = "/next", .desc = "Next episode / playlist item", .instant = true, .send_as = "next episode" },
        .{ .key = "/recommend ", .desc = "TMDB-based suggestions" },
    };

    const typed = state.app.magnet_buf[0..text_len];
    const lower = blk: {
        var lb: [128]u8 = undefined;
        const n = @min(typed.len, lb.len);
        for (0..n) |i| lb[i] = std.ascii.toLower(typed[i]);
        break :blk lb[0..n];
    };

    const vw = dvui.windowRectPixels().w;
    const w: f32 = @min(560, vw * 0.6);
    const x: f32 = (vw - w) / 2;
    const ns = dvui.windowNaturalScale();
    var rect = dvui.Rect{ .x = x / ns, .y = 56 / ns, .w = w / ns, .h = 240 / ns };

    var fw = dvui.floatingWindow(@src(), .{
        .rect = &rect,
        .stay_above_parent_window = false,
    }, .{
        .background = true,
        .color_fill = dvui.Color{ .r = 14, .g = 14, .b = 20, .a = 248 },
        .color_border = theme.colors.accent,
        .border = dvui.Rect.all(1),
        .corner_radius = dvui.Rect.all(10),
    });
    defer fw.deinit();

    var pad = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
    });
    defer pad.deinit();

    _ = dvui.label(@src(), "Commands", .{}, .{
        .color_text = theme.colors.accent,
        .margin = .{ .h = 6 },
    });

    var any_shown = false;
    for (cmds, 0..) |cmd, i| {
        // Prefix-filter by typed input
        const prefix_len = @min(lower.len, cmd.key.len);
        if (!std.mem.startsWith(u8, cmd.key, lower[0..prefix_len])) continue;
        any_shown = true;

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand = .horizontal,
            .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
        });
        defer row.deinit();

        if (dvui.button(@src(), cmd.key, .{}, .{
            .id_extra = i,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.accent,
            .border = dvui.Rect.all(0),
            .padding = .{ .x = 4, .y = 0, .w = 4, .h = 0 },
            .min_size_content = .{ .w = 140, .h = 0 },
            .gravity_y = 0.5,
        })) {
            if (cmd.instant and cmd.send_as.len > 0) {
                // Clear the input, dispatch through ai_chat with the
                // plain-text form so fast-path / tryInstantCommand fires.
                @memset(&state.app.magnet_buf, 0);
                const ai_chat = @import("services/ai_chat.zig");
                const n = @min(cmd.send_as.len, ai_chat.input_buf.len - 1);
                @memset(&ai_chat.input_buf, 0);
                @memcpy(ai_chat.input_buf[0..n], cmd.send_as[0..n]);
                ai_chat.input_len = n;
                ai_chat.trySendMessage();
            } else {
                @memset(&state.app.magnet_buf, 0);
                @memcpy(state.app.magnet_buf[0..cmd.key.len], cmd.key);
            }
        }
        _ = dvui.label(@src(), "{s}", .{cmd.desc}, .{
            .id_extra = i + 100,
            .color_text = theme.colors.text_secondary,
            .gravity_y = 0.5,
        });
    }

    if (!any_shown) {
        _ = dvui.label(@src(), "No commands match.", .{}, .{
            .color_text = theme.colors.text_secondary,
            .gravity_x = 0.5,
            .margin = .{ .y = 12 },
        });
    }
}

/// One-shot: open the window centered and at a comfortable, non-fullscreen size
/// (~72%×82% of the display work area). The dvui default (a fixed 1400×820) is
/// nearly full-width on a HiDPI panel whose logical desktop is small, so it read
/// as "fullscreen". Runs once, on the first frame the SDL window is available.
var window_centered = false;
fn centerWindowOnce(sdl_win: ?*c.sdl.SDL_Window) void {
    if (window_centered) return;
    const sw = sdl_win orelse return;
    window_centered = true;
    c.sdl.SDL_RestoreWindow(sw); // never start maximized
    const di = c.sdl.SDL_GetWindowDisplayIndex(sw);
    var b: c.sdl.SDL_Rect = undefined;
    if (c.sdl.SDL_GetDisplayUsableBounds(di, &b) != 0) return;
    const tw: c_int = @intFromFloat(@as(f32, @floatFromInt(b.w)) * 0.72);
    const th: c_int = @intFromFloat(@as(f32, @floatFromInt(b.h)) * 0.82);
    c.sdl.SDL_SetWindowSize(sw, tw, th);
    c.sdl.SDL_SetWindowPosition(sw, b.x + @divTrunc(b.w - tw, 2), b.y + @divTrunc(b.h - th, 2));
}

fn appFrame() !dvui.App.Result {
    // Suppress dvui's debug widget outline (red 1px rect) — shows when
    // debug.widget_id matches a rendered widget. Can get stuck if user
    // accidentally toggles dvui debug panel.
    dvui.currentWindow().debug.widget_id = .zero;

    // Apply any theme change requested off the UI thread (config.load runs
    // theme.setPreset on the background worker, which can't touch dvui directly).
    theme.reapplyIfPending();

    // Device-aware default scale — applied once, after config load, when the
    // user hasn't pinned a manual scale. dvui already multiplies by the display
    // DPI (natural_scale); this picks a compact-but-readable density on top,
    // biased denser on high-DPI panels. windowNaturalScale() is only valid
    // inside a frame, so this can't live in appInit.
    if (!device_scale_applied and state.app.config_loaded.load(.acquire)) {
        device_scale_applied = true;
        if (state.app.ui_scale_auto) {
            state.app.ui_scale = @import("core/scale_pure.zig").deviceScale(dvui.windowNaturalScale());
        }
    }

    // Reset the per-frame widget-id sequence counters (sectionHeader / divider /
    // statusPill). Without this every one of those widgets is a "first frame"
    // id for dvui, which force-refreshes — a permanent full-rate repaint while
    // Settings or any status pill is on screen.
    @import("ui/components.zig").beginFrame();
    @import("ui/settings.zig").beginFrame();

    // Consume a navigation queued from a worker thread (AI tools, resolver).
    state.applyPendingNav();

    // Swap in TMDB pages staged by fetch workers (UI thread owns `results`;
    // workers staging + this apply is what keeps the render loop's iteration
    // safe — see state.zig tmdb.results comment).
    @import("services/tmdb_api.zig").applyPendingResults();

    // Poll the native file-open dialog worker. This used to live in the legacy
    // header (renderHeader), which never runs in the default page shell — so
    // Ctrl+O picked a file that then silently never loaded.
    ui.pollFileOpen();

    // One-time AI service wiring (voice transcript/error callbacks + zombie
    // server sweep). Previously lived only in the AI tab's render fn, which
    // lost all callers when chat moved to Home — voice conversations then
    // dropped every transcript into a null callback. Idempotent.
    @import("services/ai_chat.zig").ensureInit();

    // Resume prompt (replaces the old silent session restore): once watch history
    // has loaded, arm a one-shot banner offering to reopen the most-recent item
    // instead of auto-reopening it. Cold start only — skip if something already
    // plays (e.g. a CLI/file-arg open). See resume_pure for the predicate.
    if (!state.app.resume_prompt_checked and state.app.init_history_loaded) {
        state.app.resume_prompt_checked = true;
        state.app.session_restore_done = true;
        const wh = @import("player/watch_history.zig");
        const rp = @import("player/resume_pure.zig");
        const whp = @import("player/watch_history_pure.zig");
        // Seconds-accurate rows gate on the exact position (>=30s in, <95% of
        // duration); legacy percent-only rows keep the old percent predicate.
        const offer = state.app.players.items.len == 0 and wh.count > 0 and blk: {
            const e0 = &wh.entries[0];
            if (e0.link_len == 0) break :blk false;
            if (e0.position_secs > 0) break :blk whp.resumeEligible(e0.position_secs, e0.duration_secs);
            break :blk rp.isResumable(e0.link_len, e0.percent);
        };
        if (offer) {
            const e = &wh.entries[0]; // load() orders by updated_at DESC → most recent
            const link = e.link[0..e.link_len];
            // Don't offer a dead resume for a local file deleted between sessions.
            const exists = if (whp.localFsPath(link)) |fs_path| blk: {
                const io_g = @import("core/io_global.zig");
                if (io_g.openFileAbsolute(fs_path, .{})) |f| {
                    f.close(io_g.io());
                    break :blk true;
                } else |_| break :blk false;
            } else true;
            if (exists) {
                const ll = @min(link.len, state.app.resume_prompt_link.len);
                @memcpy(state.app.resume_prompt_link[0..ll], link[0..ll]);
                state.app.resume_prompt_link_len = ll;
                state.app.resume_prompt_label_len = rp.cleanTitle(whp.displayName(e.name[0..e.name_len]), &state.app.resume_prompt_label);
                state.app.resume_prompt_pct = @intFromFloat(std.math.clamp(e.percent, 0, 100));
                state.app.resume_prompt_pos_secs = e.position_secs;
                state.app.resume_prompt_active = true;
            }
        }
    }

    // Process dropped files
    state.app.dropped_file_lock.lock();
    if (state.app.dropped_file_ready) {
        state.app.dropped_file_ready = false;
        if (state.app.dropped_file_len > 0 and state.app.active_player_idx < state.app.players.items.len) {
            const fpath = state.app.dropped_file_path[0..state.app.dropped_file_len];
            if (std.mem.endsWith(u8, fpath, ".m3u") or std.mem.endsWith(u8, fpath, ".m3u8")) {
                // It's an M3U file, load it!
                const m3u = @import("player/m3u.zig");
                if (state.app.playlist) |pl| {
                    const mut_pl = @constCast(pl);
                    mut_pl.deinit();
                    @import("core/alloc.zig").allocator.destroy(mut_pl);
                }
                const new_pl = @import("core/alloc.zig").allocator.create(m3u.M3UPlaylist) catch null;
                if (new_pl) |pl| {
                    pl.* = m3u.M3UPlaylist.init(@import("core/alloc.zig").allocator);
                    pl.loadFile(@import("core/io_global.zig").io(), fpath) catch {};
                    state.app.playlist = pl;
                    state.app.playlist_drawer_open = true;
                    logs.pushLog("info", "m3u", "Loaded M3U playlist", false);
                    state.showToast("Playlist loaded!");
                }
            } else if (isDirectory(fpath)) {
                // Folder drop — scan for media files and build auto-playlist
                const m3u = @import("player/m3u.zig");
                if (state.app.playlist) |pl| {
                    const mut_pl = @constCast(pl);
                    mut_pl.deinit();
                    @import("core/alloc.zig").allocator.destroy(mut_pl);
                }
                const new_pl = @import("core/alloc.zig").allocator.create(m3u.M3UPlaylist) catch null;
                if (new_pl) |pl| {
                    pl.* = m3u.M3UPlaylist.init(@import("core/alloc.zig").allocator);
                    scanDirForMedia(pl, fpath);
                    if (pl.entries.items.len > 0) {
                        state.app.playlist = pl;
                        state.app.playlist_drawer_open = true;
                        logs.pushLog("info", "folder", "Scanned folder for media", false);
                        state.showToast("Folder loaded as playlist!");
                    } else {
                        pl.deinit();
                        @import("core/alloc.zig").allocator.destroy(pl);
                        state.app.playlist = null;
                        logs.pushLog("warn", "folder", "No media files found", false);
                    }
                }
            } else if (@import("services/browser_pure.zig").routeContent(fpath) == .torrent) {
                // A dropped .torrent is metadata, not media — handing it to mpv
                // just errors out. Only the torrent route is taken from the
                // (unit-tested) router here; every other shape keeps the existing
                // straight-to-mpv drop behavior below.
                @import("services/search.zig").addTorrentFileToEngine(fpath);
                logs.pushLog("info", "open", "Loaded dropped .torrent", false);
                state.showToast("Adding torrent...");
            } else {
                // Clear resume position so dropped file starts fresh
                _ = c.mpv.mpv_set_option_string(
                    state.app.players.items[state.app.active_player_idx].mpv_ctx,
                    "start",
                    "0",
                );
                state.app.players.items[state.app.active_player_idx].load_file(@ptrCast(&state.app.dropped_file_path[0]));
                logs.pushLog("info", "open", "Loaded dropped file", false);
                state.showToast("Playing dropped file");
            }
        }
    }
    state.app.dropped_file_lock.unlock();

    // Process CLI file argument (deferred from appInit)
    if (!cli_open_done and cli_open_len > 0 and state.app.players.items.len > 0) {
        cli_open_done = true;
        const fpath = cli_open_buf[0..cli_open_len];
        if (state.app.active_player_idx < state.app.players.items.len) {
            const browser = @import("services/browser.zig");
            browser.loadContent(fpath);
            logs.pushLog("info", "open", "Loaded file from CLI", false);
            state.showToast("Playing from CLI");
        }
    }

    // Process a path forwarded by a second `opal <file>` launch (remote
    // /api/open). Snapshot under the lock, release, then do the UI-thread work.
    {
        var fwd_buf: [2048]u8 = undefined;
        var fwd_len: usize = 0;
        var type_buf: [16]u8 = undefined;
        var type_len: usize = 0;
        var title_buf: [512]u8 = undefined;
        var title_len: usize = 0;
        var art_buf: [1024]u8 = undefined;
        var art_len: usize = 0;
        var sub_buf: [256]u8 = undefined;
        var sub_len: usize = 0;
        state.app.remote_open_lock.lock();
        if (state.app.remote_open_ready) {
            state.app.remote_open_ready = false;
            fwd_len = state.app.remote_open_len;
            @memcpy(fwd_buf[0..fwd_len], state.app.remote_open_path[0..fwd_len]);
            type_len = state.app.remote_open_type_len;
            @memcpy(type_buf[0..type_len], state.app.remote_open_type[0..type_len]);
            title_len = state.app.remote_open_title_len;
            @memcpy(title_buf[0..title_len], state.app.remote_open_title[0..title_len]);
            art_len = state.app.remote_open_art_len;
            @memcpy(art_buf[0..art_len], state.app.remote_open_art[0..art_len]);
            sub_len = state.app.remote_open_subtitle_len;
            @memcpy(sub_buf[0..sub_len], state.app.remote_open_subtitle[0..sub_len]);
            // One-shot: clear the meta so a later bare open doesn't reuse it.
            state.app.remote_open_type_len = 0;
            state.app.remote_open_title_len = 0;
            state.app.remote_open_art_len = 0;
            state.app.remote_open_subtitle_len = 0;
        }
        state.app.remote_open_lock.unlock();
        if (fwd_len > 0) {
            const url = fwd_buf[0..fwd_len];
            const kind = type_buf[0..type_len];
            if (std.mem.eql(u8, kind, "queue")) {
                // "Queue in Opal" — add to the watch queue instead of playing.
                const title = if (title_len > 0) title_buf[0..title_len] else url;
                @import("services/queue.zig").addToQueue(url, title, "extension");
                logs.pushLog("info", "queue", "Queued from browser extension", false);
                state.showToast("Queued in Opal");
            } else if (title_len > 0 or art_len > 0 or sub_len > 0) {
                // Rich-metadata send: show a proper now-playing card.
                const browser = @import("services/browser.zig");
                browser.loadContentDirectMeta(url, art_buf[0..art_len], title_buf[0..title_len], sub_buf[0..sub_len]);
                logs.pushLog("info", "open", "Opened from browser extension", false);
                state.showToast("Playing in Opal");
            } else {
                const browser = @import("services/browser.zig");
                browser.loadContent(url);
                logs.pushLog("info", "open", "Opened from second instance", false);
                state.showToast("Playing forwarded file");
            }
        }
    }

    // Drain a deferred comic-load requested by the remote API thread (loadComic
    // frees textures via dvui, which is UI-thread-only).
    @import("services/comics.zig").drainPendingLoad();

    // Keep an in-progress podcast episode mirrored into library_items (its
    // position is already persisted by the mpv path; this gives it a real
    // `podcast` row). Self-throttled — cheap to call every frame.
    @import("services/podcasts.zig").tickNowPlaying();

    // Process deferred player removal (safe: before any rendering)
    if (state.app.pending_remove_player_idx >= 0) {
        const idx = @as(usize, @intCast(state.app.pending_remove_player_idx));
        if (idx < state.app.players.items.len) {
            // Lock against the remote API thread, which may be driving mpv on a
            // captured *MediaPlayer right now (use-after-free otherwise).
            state.players_mutex.lock();
            defer state.players_mutex.unlock();
            var p_rem = state.app.players.orderedRemove(idx);
            // Save URL for Ctrl+Shift+T undo
            if (p_rem.current_url_len > 0 and p_rem.current_url_len <= 2048) {
                state.pushClosedUrl(p_rem.current_url[0..p_rem.current_url_len]);
            }
            p_rem.deinit(@import("core/alloc.zig").allocator);
            if (state.app.active_player_idx >= state.app.players.items.len and state.app.players.items.len > 0) {
                state.app.active_player_idx = state.app.players.items.len - 1;
            } else if (state.app.active_player_idx > idx and state.app.active_player_idx > 0) {
                state.app.active_player_idx -= 1;
            }
            if (state.app.players.items.len == 0) {
                state.app.active_player_idx = 0;
                // Page shell: the Player route now has nothing to render — leave
                // it for the last non-player page (or Home) so closing the player
                // doesn't drop the user on an empty grid.
                if (state.app.page_shell_enabled) state.app.router.leavePlayer();
            }
        }
        state.app.pending_remove_player_idx = -1;
    }

    // Single-media invariant — the multi-stream / "add screen" grid feature is
    // retired: only one player may exist at a time. If extras slipped in (an
    // append-based open path, session restore), keep the active one and tear the
    // rest down HERE, at the safe pre-render point — mpv deinit must not race the
    // render thread, which is why removal is deferred to the frame top.
    if (state.app.players.items.len > 1) {
        // Lock against the remote API thread (see the deferred-removal block above).
        state.players_mutex.lock();
        defer state.players_mutex.unlock();
        const keep = @min(state.app.active_player_idx, state.app.players.items.len - 1);
        var i: usize = state.app.players.items.len;
        while (i > 0) {
            i -= 1;
            if (i == keep) continue;
            var p_rem = state.app.players.orderedRemove(i);
            p_rem.deinit(@import("core/alloc.zig").allocator);
        }
        state.app.active_player_idx = 0;
    }

    // Auto-save config every ~2 seconds (frame-counter throttled, no per-frame syscall)
    {
        const S = struct {
            var frame_ctr: u32 = 0;
        };
        S.frame_ctr +%= 1;
        if (S.frame_ctr % 120 == 0) {
            const config = @import("core/config.zig");
            config.saveIfDirty();

            // Window state: capture periodically for config save (not every frame)
            if (dvui_win) |win| {
                const sdl_win: ?*c.sdl.SDL_Window = @ptrCast(win.backend.impl.window);
                state.app.win_restore_pending = false;
                var wx: c_int = 0;
                var wy: c_int = 0;
                var ww: c_int = 0;
                var wh: c_int = 0;
                c.sdl.SDL_GetWindowPosition(sdl_win, &wx, &wy);
                c.sdl.SDL_GetWindowSize(sdl_win, &ww, &wh);
                if (ww > 100 and wh > 100) {
                    state.app.win_x = wx;
                    state.app.win_y = wy;
                    state.app.win_w = ww;
                    state.app.win_h = wh;
                }
            }
        }
    }
    // Update window title with now-playing media name (checked ~2x per second,
    // but SDL_SetWindowTitle — a real window-property round-trip on macOS/X11 —
    // only fires when the formatted title actually changed).
    {
        const TitleState = struct {
            var title_ctr: u32 = 0;
            var last_title: [300]u8 = std.mem.zeroes([300]u8);
            var last_len: usize = 0;
        };
        TitleState.title_ctr +%= 1;
        if (TitleState.title_ctr % 30 == 0) {
            if (dvui_win) |win| {
                const sdl_win: ?*c.sdl.SDL_Window = @ptrCast(win.backend.impl.window);
                if (sdl_win) |sw| {
                    var name_buf: [256]u8 = undefined;
                    var name_len: usize = 0;

                    if (state.app.players.items.len > 0 and state.app.active_player_idx < state.app.players.items.len) {
                        const active_p = state.app.players.items[state.app.active_player_idx];

                        name_len = active_p.getMediaTitle(&name_buf);
                    }

                    // The resource meters go IN the title bar — as text, because
                    // SDL2 gives us no drawable surface up there (see
                    // sysmon_pure.titleMeters). The OS renders the title string in
                    // that bar, so the meters ride along with it.
                    var meter_buf: [160]u8 = undefined;
                    var meters: []const u8 = "";
                    {
                        const sysmon = @import("core/sysmon.zig");
                        const sp = @import("core/sysmon_pure.zig");
                        const snap = sysmon.get();
                        // Not until the first delta lands: a confident "CPU 0%" is
                        // worse than no meter at all.
                        if (snap.valid) {
                            meters = sp.titleMeters(
                                snap.app_cpu_pct,
                                snap.app_mem_rss,
                                snap.sys_mem_total,
                                snap.app_threads,
                                snap.app_energy,
                                &meter_buf,
                            );
                        }
                    }

                    var win_title: [300]u8 = undefined;
                    const wt: ?[:0]u8 = if (name_len > 0)
                        std.fmt.bufPrintZ(&win_title, "{s} \xe2\x80\x94 Opal{s}", .{ name_buf[0..name_len], meters }) catch null
                    else
                        std.fmt.bufPrintZ(&win_title, "Opal \xe2\x80\x94 Play everything{s}", .{meters}) catch null;
                    if (wt) |t| {
                        if (!std.mem.eql(u8, t, TitleState.last_title[0..TitleState.last_len])) {
                            c.sdl.SDL_SetWindowTitle(sw, t.ptr);
                            @memcpy(TitleState.last_title[0..t.len], t);
                            TitleState.last_len = t.len;
                        }
                    }
                }
            }
        }
    }

    player.updateTorrentBackgroundTasks();

    // Native macOS Now Playing + hardware media keys: drain pending remote
    // commands (play/pause/seek from media keys, AirPods, Control Center)
    // onto the active player and refresh the system Now Playing card.
    // Compiles to a no-op on non-macOS.
    @import("player/media_remote.zig").frameTick();

    // Anime-Skip: auto-skip crowdsourced intro/recap/credits segments on the
    // active anime player (no-op unless anime-skip is enabled + markers loaded
    // + the active player is anime-sourced).
    @import("services/anime_skip.zig").tick();

    // Audiobookshelf: seek a freshly-opened book to its server-saved position
    // (no-op unless a resume is pending + the fetch resolved + mpv has the file).
    @import("services/audiobookshelf.zig").tick();

    // Screensaver inhibit: mpv's stop-screensaver requires a VO; we use SW render,
    // so SDL handles it. Toggle when any player is actively playing (not paused).
    {
        const S = struct {
            var disabled: bool = false;
            var tick: u8 = 0;
        };
        S.tick +%= 1;
        if (S.tick % 30 == 0) {
            var any_playing = false;
            for (state.app.players.items) |p| {
                if (p.current_url_len == 0) continue;
                var paused: c_int = 1;
                _ = c.mpv.mpv_get_property(p.mpv_ctx, "pause", c.mpv.MPV_FORMAT_FLAG, &paused);
                if (paused == 0) {
                    any_playing = true;
                    break;
                }
            }
            if (any_playing and !S.disabled) {
                c.sdl.SDL_DisableScreenSaver();
                S.disabled = true;
            } else if (!any_playing and S.disabled) {
                c.sdl.SDL_EnableScreenSaver();
                S.disabled = false;
            }
        }
    }

    // Global Key Handlers (Process at start of frame to ensure state is ready for render)
    for (dvui.events()) |*e| {
        if (e.evt == .window and e.evt.window.action == .close) {
            // Save config on exit to persist window position
            const config = @import("core/config.zig");
            config.save();
            return .close;
        }
    }

    // Custom title bar's close button (set during last frame's render).
    if (@import("ui/titlebar.zig").close_requested) {
        @import("core/config.zig").save();
        return .close;
    }

    input.processGlobalInputs();

    // Track mouse motion — feeds the shared chrome idle clock.
    for (dvui.events()) |*e| {
        if (e.evt == .mouse and e.evt.mouse.action == .motion) {
            state.app.last_mouse_x = e.evt.mouse.p.x;
            state.app.last_mouse_y = e.evt.mouse.p.y;
            state.app.last_mouse_move_ms = @import("core/io_global.zig").milliTimestamp();
        }
    }

    // Control-overlay visibility follows the same WALL-CLOCK idle threshold as
    // every other chrome layer (chrome_autohide). The old version counted
    // frames ("~3s at 60fps"), which drifted under the gated repaint loop —
    // at video-callback rate a 24fps stream stretched the hide delay, and the
    // overlay hid on a different clock than the nav/control-bar fade.
    //
    // Three deliberate extensions of the bare threshold:
    //  • + FADE_MS so the control bar's 220ms fade-out (footer.zig) actually
    //    renders before the gate stops drawing the overlay entirely;
    //  • held while the active player is PAUSED (controls must not vanish
    //    under a paused video — the old frame counter got this by accident,
    //    because paused playback stopped generating frames);
    //  • held while a picker popover is open (its anchor bar must stay).
    {
        const autohide = @import("ui/chrome_autohide.zig");
        const idle_ms = @import("core/io_global.zig").milliTimestamp() - state.app.last_mouse_move_ms;
        var hold = @import("ui/footer.zig").pickerOpen();
        if (!hold and state.app.active_player_idx < state.app.players.items.len) {
            hold = state.app.players.items[state.app.active_player_idx].cached_paused;
        }
        state.app.show_cell_overlay = hold or idle_ms < autohide.DEFAULT_THRESHOLD_MS + autohide.FADE_MS;
    }

    // Seek sync: when active player seeks, sync all others
    if (state.app.seek_sync and state.app.players.items.len > 1 and state.app.active_player_idx < state.app.players.items.len) {
        var master_pos: f64 = 0;
        _ = c.mpv.mpv_get_property(state.app.players.items[state.app.active_player_idx].mpv_ctx, "time-pos", c.mpv.MPV_FORMAT_DOUBLE, &master_pos);
        for (state.app.players.items, 0..) |p, i| {
            if (i != state.app.active_player_idx) {
                var their_pos: f64 = 0;
                _ = c.mpv.mpv_get_property(p.mpv_ctx, "time-pos", c.mpv.MPV_FORMAT_DOUBLE, &their_pos);
                const drift = @abs(master_pos - their_pos);
                if (drift > 0.5) {
                    var cmd: [64]u8 = undefined;
                    if (std.fmt.bufPrintZ(&cmd, "seek {d:.2} absolute", .{master_pos})) |cv| {
                        _ = c.mpv.mpv_command_string(p.mpv_ctx, cv.ptr);
                    } else |_| {}
                }
            }
        }
    }
    var app_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .color_fill = theme.colors.bg_app });
    defer app_box.deinit();

    // Custom (borderless) window title bar — drawn at the very top, at native
    // scale (outside the ui_scale wrapper below), before all other chrome.
    // No-op unless active (Windows + state.app.custom_titlebar).
    {
        const titlebar = @import("ui/titlebar.zig");
        if (dvui_win) |win| {
            const sdl_win: ?*c.sdl.SDL_Window = @ptrCast(win.backend.impl.window);
            centerWindowOnce(sdl_win);
            titlebar.ensureEnabled(sdl_win);
        }
        titlebar.render();
    }

    var scale_w = dvui.scale(@src(), .{ .scale = &state.app.ui_scale }, .{ .expand = .both });
    defer scale_w.deinit();

    // First-run wizard — modal over whatever shell renders below; no-op once
    // onboarded (persisted) or before config load resolves the flag.
    @import("ui/onboarding.zig").render();

    if (state.app.page_shell_enabled) {
        // New website-like page shell (redesign). Behind a flag until parity.
        try @import("ui/shell.zig").render();
    } else {
        // Auto-hide the navbar + bottom tray once the mouse goes idle during
        // video playback, so the video gets the whole window (the player control
        // bar already self-hides on the same idle clock — footer.zig). Any mouse
        // motion bumps last_mouse_move_ms (above) and reveals the chrome again.
        const hide_chrome = blk: {
            var playing_video = false;
            if (state.app.active_player_idx < state.app.players.items.len) {
                const ap = state.app.players.items[state.app.active_player_idx];
                playing_video = ap.texture != null and !ap.cached_paused;
            }
            const text_len = std.mem.indexOfScalar(u8, &state.app.magnet_buf, 0) orelse state.app.magnet_buf.len;
            const now_ms = @import("core/io_global.zig").milliTimestamp();
            const autohide = @import("ui/chrome_autohide.zig");
            break :blk autohide.shouldHideChrome(.{
                .playing_video = playing_video,
                .typing = text_len > 0,
                .idle_ms = now_ms - state.app.last_mouse_move_ms,
                .threshold_ms = autohide.DEFAULT_THRESHOLD_MS,
            });
        };

        // Immersive = give the video the whole window: hide ALL chrome (navbar,
        // tab bar, drawer, language bar, bottom tray). True in fullscreen, or once
        // the mouse goes idle during playback. Mouse motion reveals it again.
        const immersive = state.app.fullscreen_player_idx != null or hide_chrome;

        if (!immersive) {
            ui.renderHeader();
            ui.renderTabBar();
        }

        // Horizontal split: grid takes remaining space, drawer takes fixed width on the right
        {
            var main_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
            defer main_row.deinit();

            // 1. Grid Player Area + Language Learning bar (takes remaining width)
            {
                var grid_area = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });

                // Main video grid (expands)
                {
                    var grid_inner = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
                    try ui.renderGrid();
                    ui.renderLiquidGlassOverlay();
                    ui.renderStatsOverlay();
                    grid_inner.deinit();
                }

                // Language Learning subtitle bar (non-expanding, below grid) —
                // hidden in immersive playback so the video reaches the bottom edge.
                if (!immersive) {
                    const lang_learn = @import("services/lang_learn.zig");
                    lang_learn.pollSubtitle();
                    lang_learn.renderSubtitleBar();
                }

                grid_area.deinit();
            }

            // 2. Tabbed Drawer (fixed width, right side) — hidden in immersive
            // playback so the video gets the full window width.
            if (!immersive) drawer.renderDrawer();
        }

        // 3. Global Status Bottom Tray (hidden in immersive playback and when the
        // player controls overlay is active)
        if (!immersive and !state.app.show_cell_overlay) {
            ui.renderGlobalBottomTray();
        }
    } // end else — legacy header+grid+drawer layout

    // ── Layer 2: Floating Overlays & Modals ──
    metadata_dialog.renderMetadataDialog();
    search.renderNsfwModal();
    @import("services/projectjav.zig").renderModal();

    const settings = @import("ui/settings.zig");
    settings.renderSettingsModal();
    settings.renderCheatSheet();
    settings.renderMediaInfo();
    settings.renderDepsModal();
    @import("ui/footer.zig").renderSubPicker();

    // The optional-deps "Setup" modal is NO LONGER auto-opened at first run:
    // its checklist is macOS/brew-centric (apfel/ffmpeg/whisper) and just nagged
    // on Windows, where those aren't present. It's now opened on demand from
    // Settings › AI & Voice (the "Optional dependencies" button → deps_modal_open).

    ui.renderWorkspaceModals();
    @import("ui/footer.zig").renderResumePrompt();
    ui.renderToast();

    // Slash-command autocomplete popover — shows only when the omnibox input's
    // first char is '/'. (The omnibox chat overlay that used to render here was
    // removed — AI conversations live on the Home page, home.zig chat mode.)
    if (state.app.fullscreen_player_idx == null) {
        const header_mod = @import("ui/header.zig");
        if (!header_mod.shouldUrlInputBeInGrid()) {
            renderSlashMenu();
        }
    }

    // Reset Drag state on global release
    for (dvui.events()) |*e| {
        if (e.evt == .mouse and e.evt.mouse.action == .release and e.evt.mouse.button == .left) {
            state.app.dragging_magnet_len = 0;
        }
    }

    // Keep the on-screen scrubber/overlay ticking during playback — but only
    // while the control chrome is actually visible, and THROTTLED to ~30fps.
    // Video FRAMES already repaint on their own via mpv's render-update callback
    // (player.mpvRenderUpdateCallback → thread-safe dvui.refresh); this tick just
    // keeps the scrubber/hover animating between frames (and drives audio-only
    // playback, which has no video frames). The old code called dvui.refresh
    // EVERY frame, so on a 120Hz ProMotion display the whole UI tree was
    // re-laid-out 120×/s while the mouse was active — ~1800 idle wake-ups and
    // the bulk of the playback CPU. A 33ms re-arming timer caps it to 30fps
    // (plenty smooth for chrome) and lets the loop idle between ticks. Once the
    // chrome auto-hides (mouse idle > 2.5s) it stops entirely → pure video-fps.
    // `cached_paused` is observer-cached (no per-frame IPC).
    const chrome_live = (@import("core/io_global.zig").milliTimestamp() - state.app.last_mouse_move_ms) < @import("ui/chrome_autohide.zig").DEFAULT_THRESHOLD_MS;
    if (chrome_live) {
        for (state.app.players.items) |p| {
            if (p.provider == .mpv and !p.cached_paused) {
                const tick_id = dvui.Id.extendId(null, @src(), 0);
                if (dvui.timerDoneOrNone(tick_id)) dvui.timer(tick_id, 33_000);
                break;
            }
        }
    }

    // Frame-time HUD: Debug builds AND opt-in (OPAL_HUD=1).
    //
    // It is opt-in because it has to overlay the chrome to be seen, and the only
    // conventional spot (top-right) is where the header's search field lives — so
    // an always-on HUD just parks a black box on the search bar. Nothing is lost
    // by defaulting it off: it never actually rendered until now (it was laid out
    // with zero height — see renderHudOverlay), so no workflow depends on it.
    if (builtin.mode == .Debug and
        @import("core/io_global.zig").getenv("OPAL_HUD") != null) renderHudOverlay();

    return .ok;
}

// v2: lightweight frame-time overlay. Debug + OPAL_HUD=1 — ~30 LOC, no allocs.
fn renderHudOverlay() void {
    const io_g = @import("core/io_global.zig");
    const t = io_g.milliTimestamp();
    if (hud_last_ms != 0) {
        const dt: f32 = @floatFromInt(t - hud_last_ms);
        hud_samples[hud_cursor] = dt;
        hud_cursor = (hud_cursor + 1) % HUD_WINDOW;
    }
    hud_last_ms = t;

    var sum: f32 = 0;
    var peak: f32 = 0;
    for (hud_samples) |s| {
        sum += s;
        if (s > peak) peak = s;
    }
    const avg = sum / @as(f32, @floatFromInt(HUD_WINDOW));
    const last = hud_samples[(hud_cursor + HUD_WINDOW - 1) % HUD_WINDOW];

    var buf: [64]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "{d:.1} ms  avg {d:.1}  peak {d:.0}", .{ last, avg, peak }) catch return;

    // Position EXPLICITLY via .rect — do not ask the parent for space.
    //
    // This runs at the end of appFrame, i.e. as a root-level child added AFTER
    // the main UI's vertically-expanded child. dvui's BasicLayout gives such a
    // child NO space (layout.zig rectFor: `seen_expanded`), so the HUD collapsed
    // to height 0 — the frame-time readout has never actually been visible. dvui
    // flags that layout mistake by setting debug.widget_id, which outlines the
    // offending widget in RED; a zero-height outline is clamped to 1px, so the
    // bug surfaced as a mysterious red 1px line under the player chrome (Debug
    // builds only — hence never in release). The dvui complaint is a log.debug,
    // which log_level=.warn filters out, so nothing ever said why.
    //
    // Setting options.rect makes WidgetData.init skip parent.rectFor() entirely
    // (WidgetData.zig:37) — no space request, no red flag, and a real size.
    // Right side, BELOW the header: y=4 parks it on the header's search field
    // (that black box with green digits over "Ask, search, or paste a link"), and
    // anchoring to wr.h puts it off-screen — the rect is in the ScaleWidget's
    // coordinate space, not screen space. h=26 (not 20): at 20 the box was
    // shorter than its own line height and sliced the digits in half.
    const wr = dvui.windowRect();
    const hud_w: f32 = 210;
    const hud_h: f32 = 26;
    var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .rect = .{ .x = @max(0, wr.w - hud_w - 8), .y = 64, .w = hud_w, .h = hud_h },
        .padding = .{ .x = 6, .y = 3, .w = 6, .h = 3 },
        .corner_radius = dvui.Rect.all(4),
        .background = true,
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 160 },
    });
    defer box.deinit();
    // Inherit font from dvui's current theme (an empty Font{} has no name and
    // triggers the "Font not in dvui database, using fallback" warning).
    _ = dvui.label(@src(), "{s}", .{txt}, .{
        .color_text = dvui.Color{ .r = 0, .g = 255, .b = 100, .a = 255 },
    });
}
