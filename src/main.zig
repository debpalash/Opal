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
    }
    state.app.players = .empty;
    search.search_results = .empty;

    // Init torrent session in background — DHT bootstrap takes 5-10s
    state.app.torrent_ses = null;
    if (std.Thread.spawn(.{}, struct {
        fn worker() void {
            state.app.torrent_ses = c.mpv.torrent_init();
            logs.pushLog("info", "torrent", "Torrent session ready", false);
        }
    }.worker, .{})) |t| t.detach() else |_| {}

    std.Io.Dir.cwd().createDirPath(@import("core/io_global.zig").io(), state.app.save_path_buf[0..state.app.save_path_len]) catch {};
    try state.app.players.append(@import("core/alloc.zig").allocator, try player.MediaPlayer.init(@import("core/alloc.zig").allocator));

    // Auto-start Web Remote API so the OpalMenubar helper can reach us without
    // manual Settings toggling. Default state.web_remote_enabled=true; user can
    // still disable in Settings (which calls remote.stop()).
    if (state.app.web_remote_enabled) {
        @import("services/remote.zig").start();
    }

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

            // Page-shell preview opt-in (redesign, WIP). Enable with
            // OPAL_PAGE_SHELL=1 to render the new website-like layout.
            if (@import("core/io_global.zig").getenv("OPAL_PAGE_SHELL")) |v| {
                state.app.page_shell_enabled = !(v.len == 1 and v[0] == '0');
            }
            hist.loadSearchHistory();
            hist.loadDownloadHistory();
            watch.load();
            // Load installed source endpoints (opal-plugins). No file → every
            // gated source stays inert until the user installs it.
            @import("core/source_config.zig").reload();
            @import("services/plugin_repo.zig").init(); // load saved GitHub token
            @import("services/trakt.zig").init(); // load saved Trakt credentials/token
            @import("services/plex.zig").init(); // load saved Plex token/server
            // Signal the UI thread that watch history is ready so the "resume
            // last played?" launch prompt can arm (monotonic one-way flag).
            state.app.init_history_loaded = true;
            tmdb_store.loadLists();

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

    // Register SDL Event Watch for file drops (must be on main thread)
    _ = c.sdl.SDL_EventState(c.sdl.SDL_DROPFILE, c.sdl.SDL_ENABLE);
    c.sdl.SDL_AddEventWatch(sdlEventWatch, null);

    // Locate bundled resources (engines/ etc.) so streaming works when launched
    // from /Applications (CWD "/"), not just from the project dir in dev.
    detectResourceRoot();

    // ── CLI argument handling ──
    // `opal /path/to/file.mp4` or `opal https://example.com/stream`
    // Deferred: store in buffer, appFrame loads after player is ready.
    if (dvui.App.main_init) |init_data| {
        var args_iter = init_data.minimal.args.iterate();
        _ = args_iter.next(); // skip argv[0] (binary name)
        if (args_iter.next()) |arg| {
            const len = @min(arg.len, cli_open_buf.len - 1);
            @memcpy(cli_open_buf[0..len], arg[0..len]);
            cli_open_len = len;
            std.debug.print("[CLI] Will open: {s}\n", .{cli_open_buf[0..len]});
        }
    }
}

pub fn appDeinit() void {
    // Stop conversation/voice mode
    const voice = @import("services/ai_voice.zig");
    voice.conversation_active = false;
    voice.is_recording = false;
    voice.is_speaking = false;

    // Settle in-flight download/decode workers (comic pages, comic covers, yt
    // thumbnails) before we free the buffers they publish into — otherwise the
    // leak check races their still-live tmp_buf/p_slice. Workers poll isQuitting
    // in their read loops, so this drains in well under the timeout.
    @import("core/workers.zig").beginShutdownAndDrain(800);

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
    state.app.tmdb.favorites.deinit(@import("core/alloc.zig").allocator);
    state.app.tmdb.watchlist.deinit(@import("core/alloc.zig").allocator);
    state.app.tmdb.watching.deinit(@import("core/alloc.zig").allocator);
    // Frees per-item thumb_pixels + the index-aligned date arrays, then the list.
    @import("services/youtube.zig").deinit();

    // Join search thread so its defers (free query, deinit argv) run cleanly
    search.search_abort.store(true, .release);
    if (search.search_thread) |t| t.join();
    search.search_thread = null;

    search.clearResults();
    search.search_results.deinit(@import("core/alloc.zig").allocator);

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
            .color_text = theme.colors.text_muted,
            .gravity_y = 0.5,
        });
    }

    if (!any_shown) {
        _ = dvui.label(@src(), "No commands match.", .{}, .{
            .color_text = theme.colors.text_muted,
            .gravity_x = 0.5,
            .margin = .{ .y = 12 },
        });
    }
}

/// Dropdown chat panel — floats below navbar input, overlays video.
/// User dismisses via close (X) button OR by clearing input + idle state.
fn renderChatDropdown() void {
    const ai_chat_mod = @import("services/ai_chat.zig");
    const voice_mod = @import("services/ai_voice.zig");

    // Anchor near top, centered horizontally, fixed max width.
    const vw = dvui.windowRectPixels().w;
    const w: f32 = @min(780, vw * 0.75);
    const x: f32 = (vw - w) / 2;

    const ns = dvui.windowNaturalScale();
    var drop_rect = dvui.Rect{ .x = x / ns, .y = 52 / ns, .w = w / ns, .h = 340 / ns };
    var fw = dvui.floatingWindow(@src(), .{
        .rect = &drop_rect,
        .stay_above_parent_window = false,
    }, .{
        .background = true,
        .color_fill = dvui.Color{ .r = 14, .g = 14, .b = 20, .a = 245 },
        .color_border = theme.colors.accent,
        .border = dvui.Rect.all(1),
        .corner_radius = dvui.Rect.all(10),
        .box_shadow = .{
            .color = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 180 },
            .offset = .{ .x = 0, .y = 6 },
            .fade = 24,
        },
    });
    defer fw.deinit();

    var pad = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 14, .y = 10, .w = 14, .h = 10 },
    });
    defer pad.deinit();

    // Top row: Seeing chip + close X
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .h = 6 },
            .gravity_y = 0.5,
        });
        defer row.deinit();

        if (state.app.players.items.len > 0 and state.app.active_player_idx < state.app.players.items.len) {
            const ap = state.app.players.items[state.app.active_player_idx];
            var title_buf: [128]u8 = undefined;
            const tl = ap.getMediaTitle(&title_buf);
            if (tl > 0) {
                _ = dvui.icon(@src(), "", @import("icons").tvg.lucide.bot, .{}, .{
                    .color_text = theme.colors.accent,
                    .min_size_content = .{ .w = 14, .h = 14 },
                    .margin = .{ .w = 6 },
                    .gravity_y = 0.5,
                });
                _ = dvui.label(@src(), "Seeing: {s}", .{title_buf[0..tl]}, .{
                    .color_text = theme.colors.text_muted,
                    .gravity_y = 0.5,
                });
            }
        }
        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }
        if (dvui.buttonIcon(@src(), "", @import("icons").tvg.lucide.x, .{}, .{}, .{
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = dvui.Color{ .r = 220, .g = 90, .b = 90, .a = 255 },
            .border = dvui.Rect.all(0),
            .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
            .min_size_content = .{ .w = 16, .h = 16 },
        })) {
            ai_chat_mod.is_bubble_open = false;
        }
    }

    // Status line
    const phase_txt: ?[]const u8 = switch (voice_mod.conv_phase) {
        .listening => "Listening…",
        .transcribing => "Transcribing…",
        .thinking => "Thinking…",
        .speaking => "Speaking…",
        .idle => blk: {
            const chat_phase_label = ai_chat_mod.phaseLabel(ai_chat_mod.phase);
            if (chat_phase_label.len > 0) break :blk chat_phase_label;
            break :blk null;
        },
    };
    if (phase_txt) |txt| {
        _ = dvui.label(@src(), "〰 {s}", .{txt}, .{
            .color_text = theme.colors.accent,
            .margin = .{ .y = 2 },
        });
    }

    // Last 5 messages, scrollable. background=false so the overlay's own dark
    // fill shows through — otherwise the scrollArea paints dvui's default
    // (light) theme background and an empty conversation renders as a white box.
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = false,
    });
    defer scroll.deinit();

    const start: usize = if (ai_chat_mod.message_count > 5) ai_chat_mod.message_count - 5 else 0;
    var mi: usize = start;
    while (mi < ai_chat_mod.message_count) : (mi += 1) {
        const m = ai_chat_mod.messages[mi];
        if (m.text_len == 0) continue;
        if (m.role == .system) continue;
        const is_user = m.role == .user;
        var msg_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = mi + 90000,
            .expand = .horizontal,
            .margin = .{ .y = 3 },
            .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
            .background = true,
            .color_fill = if (is_user)
                dvui.Color{ .r = 26, .g = 26, .b = 38, .a = 255 }
            else
                dvui.Color{ .r = 16, .g = 20, .b = 28, .a = 255 },
            .corner_radius = dvui.Rect.all(6),
        });
        defer msg_box.deinit();
        // Header row: role label + regenerate on AI replies
        {
            var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = mi + 91500,
                .expand = .horizontal,
            });
            defer hdr.deinit();
            _ = dvui.label(@src(), "{s}", .{if (is_user) "You" else "AI"}, .{
                .id_extra = mi,
                .color_text = if (is_user) theme.colors.accent else theme.colors.text_muted,
            });
            if (!is_user) {
                {
                    var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
                    sp.deinit();
                }
                if (dvui.buttonIcon(@src(), "", @import("icons").tvg.lucide.star, .{}, .{}, .{
                    .id_extra = mi + 91700,
                    .color_text = if (m.starred)
                        dvui.Color{ .r = 255, .g = 200, .b = 80, .a = 255 }
                    else
                        theme.colors.text_muted,
                    .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .border = dvui.Rect.all(0),
                    .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
                    .min_size_content = .{ .w = 12, .h = 12 },
                })) {
                    ai_chat_mod.toggleStar(mi);
                }
                if (dvui.buttonIcon(@src(), "", @import("icons").tvg.lucide.@"rotate-ccw", .{}, .{}, .{
                    .id_extra = mi + 91800,
                    .color_text = theme.colors.text_muted,
                    .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .border = dvui.Rect.all(0),
                    .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
                    .min_size_content = .{ .w = 12, .h = 12 },
                })) {
                    ai_chat_mod.regenerateFrom(mi);
                }
            }
        }
        var mtbuf: [2048]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{@import("core/text.zig").safeUtf8Buf(m.text[0..m.text_len], &mtbuf)}, .{
            .id_extra = mi + 1,
            .color_text = theme.colors.text_main,
        });
    }

    // Torrent / stream result cards (fast-path output)
    ai_chat_mod.renderInlineResults();
}

/// DEPRECATED: inline dock. Kept unused to avoid churn; renderChatDropdown
/// is the floating variant actually used.
fn renderInlineChatDock() void {
    const ai_chat_mod = @import("services/ai_chat.zig");
    const voice_mod = @import("services/ai_voice.zig");

    var dock = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = dvui.Color{ .r = 14, .g = 14, .b = 20, .a = 240 },
        .color_border = dvui.Color{ .r = 40, .g = 40, .b = 55, .a = 200 },
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
        .max_size_content = .{ .w = std.math.floatMax(f32), .h = 260 },
    });
    defer dock.deinit();

    // Seeing chip
    if (state.app.players.items.len > 0 and state.app.active_player_idx < state.app.players.items.len) {
        const ap = state.app.players.items[state.app.active_player_idx];
        var title_buf: [128]u8 = undefined;
        const tl = ap.getMediaTitle(&title_buf);
        if (tl > 0) {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .margin = .{ .y = 2 },
                .gravity_y = 0.5,
            });
            defer row.deinit();
            _ = dvui.icon(@src(), "", @import("icons").tvg.lucide.bot, .{}, .{
                .color_text = @import("ui/theme.zig").colors.accent,
                .min_size_content = .{ .w = 14, .h = 14 },
                .margin = .{ .w = 6 },
                .gravity_y = 0.5,
            });
            _ = dvui.label(@src(), "Seeing: {s}", .{title_buf[0..tl]}, .{
                .color_text = @import("ui/theme.zig").colors.text_muted,
                .gravity_y = 0.5,
            });
        }
    }

    // Status line
    const phase_txt: ?[]const u8 = switch (voice_mod.conv_phase) {
        .listening => "Listening…",
        .transcribing => "Transcribing…",
        .thinking => "Thinking…",
        .speaking => "Speaking…",
        .idle => blk: {
            const chat_phase_label = ai_chat_mod.phaseLabel(ai_chat_mod.phase);
            if (chat_phase_label.len > 0) break :blk chat_phase_label;
            break :blk null;
        },
    };
    if (phase_txt) |txt| {
        _ = dvui.label(@src(), "〰 {s}", .{txt}, .{
            .color_text = @import("ui/theme.zig").colors.accent,
            .margin = .{ .y = 2 },
        });
    }

    // Last 3 messages
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = 80 },
        .max_size_content = .{ .w = std.math.floatMax(f32), .h = 180 },
    });
    defer scroll.deinit();

    const start: usize = if (ai_chat_mod.message_count > 3) ai_chat_mod.message_count - 3 else 0;
    var mi: usize = start;
    while (mi < ai_chat_mod.message_count) : (mi += 1) {
        const m = ai_chat_mod.messages[mi];
        if (m.text_len == 0) continue;
        if (m.role == .system) continue;
        const is_user = m.role == .user;
        var msg_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = mi + 80000,
            .expand = .horizontal,
            .margin = .{ .y = 2 },
            .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
            .background = true,
            .color_fill = if (is_user)
                dvui.Color{ .r = 26, .g = 26, .b = 38, .a = 255 }
            else
                dvui.Color{ .r = 16, .g = 20, .b = 28, .a = 255 },
            .corner_radius = dvui.Rect.all(6),
        });
        defer msg_box.deinit();
        _ = dvui.label(@src(), "{s}", .{if (is_user) "You" else "AI"}, .{
            .id_extra = mi,
            .color_text = if (is_user) @import("ui/theme.zig").colors.accent else @import("ui/theme.zig").colors.text_muted,
        });
        var mtbuf2: [2048]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{@import("core/text.zig").safeUtf8Buf(m.text[0..m.text_len], &mtbuf2)}, .{
            .id_extra = mi + 1,
            .color_text = @import("ui/theme.zig").colors.text_main,
        });
    }
}

fn appFrame() !dvui.App.Result {
    // Suppress dvui's debug widget outline (red 1px rect) — shows when
    // debug.widget_id matches a rendered widget. Can get stuck if user
    // accidentally toggles dvui debug panel.
    dvui.currentWindow().debug.widget_id = .zero;

    // Apply any theme change requested off the UI thread (config.load runs
    // theme.setPreset on the background worker, which can't touch dvui directly).
    theme.reapplyIfPending();

    // Resume prompt (replaces the old silent session restore): once watch history
    // has loaded, arm a one-shot banner offering to reopen the most-recent item
    // instead of auto-reopening it. Cold start only — skip if something already
    // plays (e.g. a CLI/file-arg open). See resume_pure for the predicate.
    if (!state.app.resume_prompt_checked and state.app.init_history_loaded) {
        state.app.resume_prompt_checked = true;
        state.app.session_restore_done = true;
        const wh = @import("player/watch_history.zig");
        const rp = @import("player/resume_pure.zig");
        if (state.app.players.items.len == 0 and wh.count > 0 and
            rp.isResumable(wh.entries[0].link_len, wh.entries[0].percent))
        {
            const e = &wh.entries[0]; // load() orders by updated_at DESC → most recent
            const link = e.link[0..e.link_len];
            // Don't offer a dead resume for a local file deleted between sessions.
            const is_local = link.len > 0 and (link[0] == '/' or std.mem.startsWith(u8, link, "file://"));
            const exists = if (is_local) blk: {
                const fs_path = if (std.mem.startsWith(u8, link, "file://")) link[7..] else link;
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
                state.app.resume_prompt_label_len = rp.cleanTitle(e.name[0..e.name_len], &state.app.resume_prompt_label);
                state.app.resume_prompt_pct = @intFromFloat(std.math.clamp(e.percent, 0, 100));
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

    // Drain a deferred comic-load requested by the remote API thread (loadComic
    // frees textures via dvui, which is UI-thread-only).
    @import("services/comics.zig").drainPendingLoad();

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
    // Update window title with now-playing media name (~2x per second)
    {
        const TitleState = struct {
            var title_ctr: u32 = 0;
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

                    if (name_len > 0) {
                        var win_title: [300]u8 = undefined;
                        const wt = std.fmt.bufPrintZ(&win_title, "\xe2\x9a\xa1 {s} \xe2\x80\x94 Opal", .{name_buf[0..name_len]}) catch null;
                        if (wt) |t| {
                            c.sdl.SDL_SetWindowTitle(sw, t.ptr);
                        }
                    } else {
                        c.sdl.SDL_SetWindowTitle(sw, "\xe2\x9a\xa1 Opal \xe2\x80\x94 Play everything");
                    }
                }
            }
        }
    }

    player.updateTorrentBackgroundTasks();

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

    input.processGlobalInputs();

    // Auto-hide overlays on mouse idle
    var has_mouse_movement = false;
    for (dvui.events()) |*e| {
        if (e.evt == .mouse and e.evt.mouse.action == .motion) {
            has_mouse_movement = true;
            state.app.last_mouse_x = e.evt.mouse.p.x;
            state.app.last_mouse_y = e.evt.mouse.p.y;
            state.app.last_mouse_move_ms = @import("core/io_global.zig").milliTimestamp();
        }
    }

    if (has_mouse_movement) {
        state.app.overlay_hide_timer = 0;
        state.app.show_cell_overlay = true;
    } else {
        if (state.app.overlay_hide_timer < 1000) state.app.overlay_hide_timer += 1;
        // ~3 seconds at 60fps
        if (state.app.overlay_hide_timer > 180) {
            state.app.show_cell_overlay = false;
        }
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

    var scale_w = dvui.scale(@src(), .{ .scale = &state.app.ui_scale }, .{ .expand = .both });
    defer scale_w.deinit();

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
            break :blk @import("ui/chrome_autohide.zig").shouldHideChrome(.{
                .playing_video = playing_video,
                .typing = text_len > 0,
                .idle_ms = now_ms - state.app.last_mouse_move_ms,
                .threshold_ms = 2500,
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

    // First-run deps check — open setup modal once if something is missing.
    if (!state.app.deps_modal_checked) {
        state.app.deps_modal_checked = true;
        const d = @import("core/deps.zig").check();
        if (!(d.apfel and d.ffmpeg and d.whisper)) {
            state.app.deps_modal_open = true;
        }
    }

    ui.renderWorkspaceModals();
    @import("ui/footer.zig").renderResumePrompt();
    ui.renderToast();

    // ── AI Chat: input-extension dropdown.
    // Behaves like the input box with chat history attached:
    // shows ONLY while user is typing, voice mode is live, or
    // an AI response is currently streaming. Hides as soon as
    // user clears input + no activity, even if messages linger.
    if (state.app.fullscreen_player_idx == null) {
        const header_mod = @import("ui/header.zig");
        if (!header_mod.shouldUrlInputBeInGrid()) {
            const ai_chat_mod = @import("services/ai_chat.zig");
            const voice_mod = @import("services/ai_voice.zig");
            const text_len = std.mem.indexOfScalar(u8, &state.app.magnet_buf, 0) orelse state.app.magnet_buf.len;
            const is_typing = text_len > 0;
            const voice_active = voice_mod.conv_phase != .idle or voice_mod.is_recording;
            const is_thinking = ai_chat_mod.is_generating.load(.acquire);
            if (is_typing or voice_active or is_thinking) {
                renderChatDropdown();
            }
            // Slash-command autocomplete popover — shows only when input
            // first char is '/'. Independent of the chat dropdown.
            renderSlashMenu();
        }
    }

    // Reset Drag state on global release
    for (dvui.events()) |*e| {
        if (e.evt == .mouse and e.evt.mouse.action == .release and e.evt.mouse.button == .left) {
            state.app.dragging_magnet_len = 0;
        }
    }

    // Continuous refresh: when any player is actively playing (not paused),
    // request another frame immediately so the video texture keeps updating.
    // Without this, dvui only redraws on input events and the video freezes.
    for (state.app.players.items) |p| {
        if (p.provider == .mpv) {
            // Cached via mpv property observer (A4) — no per-frame IPC.
            if (!p.cached_paused) {
                dvui.refresh(null, @src(), null);
                break;
            }
        }
    }

    if (builtin.mode == .Debug) renderHudOverlay();

    return .ok;
}

// v2: lightweight frame-time overlay. Debug builds only — ~30 LOC, no allocs.
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

    var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .gravity_x = 1.0,
        .gravity_y = 0.0,
        .margin = .{ .x = 0, .y = 4, .w = 8, .h = 0 },
        .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
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
