const std = @import("std");
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

// Window reference for SDL position/size persistence
var dvui_win: ?*dvui.Window = null;

pub const dvui_app: dvui.App = .{
    .config = .{ .options = .{ .size = .{ .w = 1400.0, .h = 820.0 }, .title = "⚡ ZigZag Media Console" } },
    .initFn = appInit,
    .frameFn = appFrame,
    .deinitFn = appDeinit,
};

pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn, .log_level = .warn };

fn appInit(win: *dvui.Window) !void {
    // Store window ref for position/size persistence
    dvui_win = win;

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
    _ = std.Thread.spawn(.{}, struct {
        fn worker() void {
            state.app.torrent_ses = c.mpv.torrent_init();
            logs.pushLog("info", "torrent", "Torrent session ready", false);
        }
    }.worker, .{}) catch {};

    std.Io.Dir.cwd().createDirPath(@import("core/io_global.zig").io(), state.app.save_path_buf[0..state.app.save_path_len]) catch {};
    try state.app.players.append(@import("core/alloc.zig").allocator, try player.MediaPlayer.init(@import("core/alloc.zig").allocator));
    
    // Register SDL Event Watch for file drops (must be on main thread)
    _ = c.sdl.SDL_EventState(c.sdl.SDL_DROPFILE, c.sdl.SDL_ENABLE);
    c.sdl.SDL_AddEventWatch(sdlEventWatch, null);

    // Move heavy DB/migration/loading work to background so UI renders instantly
    _ = std.Thread.spawn(.{}, struct {
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
            hist.loadSearchHistory();
            hist.loadDownloadHistory();
            watch.load();
            tmdb_store.loadLists();

            // Ensure yt-dlp binary is available
            const ytdlp = @import("services/ytdlp.zig");
            ytdlp.ensureAvailable();

            logs.pushLog("info", "init", "Background init complete", false);
        }
    }.worker, .{}) catch {};
}

fn appDeinit() void {
    // Stop conversation/voice mode
    const voice = @import("services/ai_voice.zig");
    voice.conversation_active = false;
    voice.is_recording = false;
    voice.is_speaking = false;

    // Clean up players natively to prevent memory leaks
    if (state.app.players.items.len > 0) {
        for (state.app.players.items) |p| {
            p.deinit(@import("core/alloc.zig").allocator);
        }
        state.app.players.deinit(@import("core/alloc.zig").allocator);
    }
    
    // Clean up UI arrays
    state.app.tmdb.results.deinit(@import("core/alloc.zig").allocator);
    state.app.tmdb.favorites.deinit(@import("core/alloc.zig").allocator);
    state.app.tmdb.watchlist.deinit(@import("core/alloc.zig").allocator);
    state.app.tmdb.watching.deinit(@import("core/alloc.zig").allocator);
    state.app.yt.results.deinit(@import("core/alloc.zig").allocator);
    
    search.clearResults();
    search.search_results.deinit(@import("core/alloc.zig").allocator);
    

    // Kill any spawned child processes that may still be running
    const kill_targets = [_][]const u8{
        "aplay.*zigzag",
        "kittentts",
        "zigzag-stt",
        "zigzag-tts-server",
        "zigzag-stt-server",
        "zigzag-voice-server",
        "rec.*zigzag_ai_mic",
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
        .{ .key = "/play ",       .desc = "Search + play best match — play iron man 3" },
        .{ .key = "/find ",       .desc = "Search only, show results" },
        .{ .key = "/watch ",      .desc = "Alias for /play" },
        .{ .key = "/pause",       .desc = "Pause current playback",        .instant = true, .send_as = "pause" },
        .{ .key = "/resume",      .desc = "Resume playback",                .instant = true, .send_as = "play" },
        .{ .key = "/seek ",       .desc = "Jump to time — /seek 1:23" },
        .{ .key = "/volume ",     .desc = "Set volume 0-100" },
        .{ .key = "/mute",        .desc = "Toggle mute",                    .instant = true, .send_as = "mute" },
        .{ .key = "/fullscreen",  .desc = "Toggle fullscreen",              .instant = true, .send_as = "fullscreen" },
        .{ .key = "/subtitles",   .desc = "Cycle subtitle tracks",          .instant = true, .send_as = "next subtitle" },
        .{ .key = "/queue ",      .desc = "Add URL to queue" },
        .{ .key = "/next",        .desc = "Next episode / playlist item",   .instant = true, .send_as = "next episode" },
        .{ .key = "/recommend ",  .desc = "TMDB-based suggestions" },
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

        if (state.app.players.items.len > 0) {
            const ap = state.app.players.items[state.app.active_player_idx];
            var title_buf: [128]u8 = undefined;
            const tl = ap.getMediaTitle(&title_buf);
            if (tl > 0) {
                _ = dvui.icon(@src(), "", @import("icons").tvg.lucide.@"bot", .{}, .{
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
        { var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal }); sp.deinit(); }
        if (dvui.buttonIcon(@src(), "", @import("icons").tvg.lucide.@"x", .{}, .{}, .{
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

    // Last 5 messages, scrollable
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
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
                { var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal }); sp.deinit(); }
                if (dvui.buttonIcon(@src(), "", @import("icons").tvg.lucide.@"star", .{}, .{}, .{
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
        _ = dvui.label(@src(), "{s}", .{m.text[0..m.text_len]}, .{
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
    if (state.app.players.items.len > 0) {
        const ap = state.app.players.items[state.app.active_player_idx];
        var title_buf: [128]u8 = undefined;
        const tl = ap.getMediaTitle(&title_buf);
        if (tl > 0) {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .margin = .{ .y = 2 },
                .gravity_y = 0.5,
            });
            defer row.deinit();
            _ = dvui.icon(@src(), "", @import("icons").tvg.lucide.@"bot", .{}, .{
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
        _ = dvui.label(@src(), "{s}", .{m.text[0..m.text_len]}, .{
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

    // Session restore: rehydrate players from last exit, paused.
    // Config loads async on a worker thread, so we re-check each frame
    // until session_restore_count becomes non-zero, then run once.
    if (!state.app.session_restore_done and state.app.session_restore_count > 0) {
        state.app.session_restore_done = true;
        const browser = @import("services/browser.zig");
        var i: usize = 0;
        while (i < state.app.session_restore_count) : (i += 1) {
            const url_len = state.app.session_restore_lens[i];
            if (url_len == 0 or url_len >= 2048) continue;
            const p = player.MediaPlayer.init(@import("core/alloc.zig").allocator) catch continue;
            // Start paused; mpv honors the pause property across loadfile.
            _ = c.mpv.mpv_set_property_string(p.mpv_ctx, "pause", "yes");
            state.app.players.append(@import("core/alloc.zig").allocator, p) catch {
                p.deinit(@import("core/alloc.zig").allocator);
                continue;
            };
            state.app.active_player_idx = state.app.players.items.len - 1;
            const url = state.app.session_restore_urls[i][0..url_len];
            browser.loadContent(url);
        }
        if (state.app.players.items.len > 0) {
            state.app.active_player_idx = 0;
            logs.pushLog("info", "session", "Restored previous session (paused)", false);
        }
    }

    // Process dropped files
    if (state.app.dropped_file_ready) {
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
                        "start", "0",
                    );
                    state.app.players.items[state.app.active_player_idx].load_file(@ptrCast(&state.app.dropped_file_path[0]));
                    logs.pushLog("info", "open", "Loaded dropped file", false);
                    state.showToast("Playing dropped file");
                }
            }
        }
        state.app.dropped_file_lock.unlock();
    }

    // Process deferred player removal (safe: before any rendering)
    if (state.app.pending_remove_player_idx >= 0) {
        const idx = @as(usize, @intCast(state.app.pending_remove_player_idx));
        if (idx < state.app.players.items.len) {
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
            }
        }
        state.app.pending_remove_player_idx = -1;
    }

    // Auto-save config every ~2 seconds (frame-counter throttled, no per-frame syscall)
    {
        const S = struct { var frame_ctr: u32 = 0; };
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
        const TitleState = struct { var title_ctr: u32 = 0; };
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
                        const wt = std.fmt.bufPrintZ(&win_title, "\xe2\x9a\xa1 {s} \xe2\x80\x94 ZigZag", .{name_buf[0..name_len]}) catch null;
                        if (wt) |t| {
                            c.sdl.SDL_SetWindowTitle(sw, t.ptr);
                        }
                    } else {
                        c.sdl.SDL_SetWindowTitle(sw, "\xe2\x9a\xa1 ZigZag Media Console");
                    }
                }
            }
        }
    }

    player.updateTorrentBackgroundTasks();

    // Screensaver inhibit: mpv's stop-screensaver requires a VO; we use SW render,
    // so SDL handles it. Toggle when any player is actively playing (not paused).
    {
        const S = struct { var disabled: bool = false; var tick: u8 = 0; };
        S.tick +%= 1;
        if (S.tick % 30 == 0) {
            var any_playing = false;
            for (state.app.players.items) |p| {
                if (p.current_url_len == 0) continue;
                var paused: c_int = 1;
                _ = c.mpv.mpv_get_property(p.mpv_ctx, "pause", c.mpv.MPV_FORMAT_FLAG, &paused);
                if (paused == 0) { any_playing = true; break; }
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
        }
    }
    
    if (has_mouse_movement) {
        state.app.overlay_hide_timer = 0;
        state.app.show_cell_overlay = true;
    } else {
        state.app.overlay_hide_timer += 1;
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

    if (state.app.fullscreen_player_idx == null) {
        ui.renderHeader();
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
                grid_inner.deinit();
            }
            
            // Language Learning subtitle bar (non-expanding, below grid)
            {
                const lang_learn = @import("services/lang_learn.zig");
                lang_learn.pollSubtitle();
                lang_learn.renderSubtitleBar();
            }
            
            grid_area.deinit();
        }

        // 2. Tabbed Drawer (non-expanding, fixed width on right side)
        drawer.renderDrawer();
    }
    
    // 3. Global Status Bottom Tray (hide when player controls overlay is active)
    if (state.app.fullscreen_player_idx == null and !state.app.show_cell_overlay) {
        ui.renderGlobalBottomTray();
    }

    // ── Layer 2: Floating Overlays & Modals ──
    metadata_dialog.renderMetadataDialog();
    search.renderNsfwModal();
    @import("services/projectjav.zig").renderModal();
    
    const settings = @import("ui/settings.zig");
    settings.renderSettingsModal();
    settings.renderCheatSheet();
    settings.renderMediaInfo();
    settings.renderDepsModal();

    // First-run deps check — open setup modal once if something is missing.
    if (!state.app.deps_modal_checked) {
        state.app.deps_modal_checked = true;
        const d = @import("core/deps.zig").check();
        if (!(d.apfel and d.ffmpeg and d.whisper)) {
            state.app.deps_modal_open = true;
        }
    }

    ui.renderWorkspaceModals();
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
            const is_thinking = ai_chat_mod.is_generating;
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

    return .ok;
}
