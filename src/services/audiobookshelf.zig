//! Audiobookshelf client — the audio-first sibling of jellyfin.zig. Talks to a
//! self-hosted Audiobookshelf server (https://www.audiobookshelf.org) over
//! REST+JSON, streams a book/episode's audio straight into mpv, and surfaces on
//! the macOS Now Playing card (it routes through the normal load_file path via
//! browser.loadContentDirectMeta, so title/position show up for free).
//!
//! Flow (mirrors jellyfin.zig):
//!   authenticate()  → POST /login → pure.extractToken → token, then libraries
//!   fetchLibraries  → GET /api/libraries (Bearer) → pure.parseLibraries
//!   openLibrary(i)  → GET /api/libraries/{id}/items → pure.parseItems
//!   playBook(i)     → pure.streamUrl → browser.loadContentDirectMeta → mpv
//!
//! All JSON parsing + URL/header building lives in audiobookshelf_pure.zig
//! (tested); this module owns the async workers, thread-safety, and dvui render.

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const logs = @import("../core/logs.zig");
const pure = @import("audiobookshelf_pure.zig");
const http = @import("../core/http.zig");
const c = @import("../core/c.zig");
const yt_pure = @import("youtube_pure.zig");
const safeUtf8Buf = @import("../core/text.zig").safeUtf8Buf;

const alloc = @import("../core/alloc.zig").allocator;

// Detached workers publish into state.app.abs.* under this mutex; the UI thread
// reads it each frame. is_loading (atomic) only gates re-spawns.
var parse_mutex: @import("../core/sync.zig").Mutex = .{};

// ── Server-side resume state ────────────────────────────────────────────────
// playBook() streams a book immediately, then a detached worker fetches the
// server's saved position; tick() (frame loop, UI thread) issues the seek once
// mpv actually has the file open — mirrors anime_skip.zig's seek timing. All
// three fields are guarded by resume_mutex; the atomics gate the frame check.
var resume_mutex: @import("../core/sync.zig").Mutex = .{};
var resume_pending = std.atomic.Value(bool).init(false); // a book is awaiting its resume seek
var resume_decided = std.atomic.Value(bool).init(false); // the fetch worker finished (target is final)
var resume_target_secs: f64 = 0; // seek target; <= 0 means start from the beginning
var resume_item_id: [64]u8 = undefined; // the book tick() must see loaded before it seeks
var resume_item_id_len: usize = 0;

fn setLoginError(msg: []const u8) void {
    const len = @min(msg.len, state.app.abs.login_error.len);
    @memcpy(state.app.abs.login_error[0..len], msg[0..len]);
    state.app.abs.login_error_len = len;
}

fn escapeJsonStr(input: []const u8, out: *[256]u8) []const u8 {
    var o: usize = 0;
    for (input) |ch| {
        if (o + 2 > out.len) break;
        if (ch == '\\' or ch == '"') {
            out[o] = '\\';
            out[o + 1] = ch;
            o += 2;
        } else {
            out[o] = ch;
            o += 1;
        }
    }
    return out[0..o];
}

// ══════════════════════════════════════════════════════════
// Authentication
// ══════════════════════════════════════════════════════════

pub fn authenticate() void {
    if (state.app.abs.is_loading.load(.acquire)) return;
    state.app.abs.is_loading.store(true, .release);
    state.app.abs.login_error_len = 0;

    state.app.abs.thread = std.Thread.spawn(.{}, struct {
        fn worker() void {
            defer state.app.abs.is_loading.store(false, .release);

            // Snapshot server URL + credentials BEFORE the network call — the UI
            // thread can edit these fields (user typing) while we run; reading
            // them mid-request is a torn read. Copy up-front, use only the copies.
            var server_buf: [256]u8 = undefined;
            const server_len = @min(state.app.abs.server_url_len, server_buf.len);
            @memcpy(server_buf[0..server_len], state.app.abs.server_url[0..server_len]);
            const server = server_buf[0..server_len];

            var user_buf: [128]u8 = undefined;
            @memcpy(&user_buf, &state.app.abs.login_user_buf);
            var pass_buf: [128]u8 = undefined;
            @memcpy(&pass_buf, &state.app.abs.login_pass_buf);

            if (server.len == 0) {
                setLoginError("Server URL is empty");
                return;
            }
            const user = user_buf[0 .. std.mem.indexOfScalar(u8, &user_buf, 0) orelse user_buf.len];
            const pass = pass_buf[0 .. std.mem.indexOfScalar(u8, &pass_buf, 0) orelse pass_buf.len];
            if (user.len == 0) {
                setLoginError("Username is empty");
                return;
            }

            // POST /login  {"username":"…","password":"…"}
            var safe_user: [256]u8 = undefined;
            var safe_pass: [256]u8 = undefined;
            const su = escapeJsonStr(user, &safe_user);
            const sp = escapeJsonStr(pass, &safe_pass);
            var body_buf: [640]u8 = undefined;
            const body = std.fmt.bufPrint(&body_buf, "{{\"username\":\"{s}\",\"password\":\"{s}\"}}", .{ su, sp }) catch {
                setLoginError("Failed to build request");
                return;
            };

            var url_buf: [512]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "{s}/login", .{server}) catch return;

            var resp_buf: [32768]u8 = undefined;
            const resp = http.fetch(url, &resp_buf, .{
                .method = .POST,
                .payload = body,
                .content_type = "application/json",
                .timeout_secs = 10,
            }) orelse {
                setLoginError("Failed to connect or no response");
                return;
            };

            const token = pure.extractToken(resp) orelse {
                setLoginError("Auth failed — check credentials");
                return;
            };

            const tlen = @min(token.len, state.app.abs.token.len);
            @memcpy(state.app.abs.token[0..tlen], token[0..tlen]);
            state.app.abs.token_len = tlen;
            state.app.abs.connected = true;
            state.app.abs.view = .Libraries;
            state.markConfigDirty();

            fetchLibrariesSync();
        }
    }.worker, .{}) catch blk: {
        state.app.abs.is_loading.store(false, .release);
        break :blk null;
    };
    if (state.app.abs.thread) |t| t.detach();
}

// ══════════════════════════════════════════════════════════
// Libraries / items
// ══════════════════════════════════════════════════════════

pub fn fetchLibraries() void {
    if (state.app.abs.is_loading.load(.acquire) or !state.app.abs.connected) return;
    state.app.abs.is_loading.store(true, .release);
    state.app.abs.thread = std.Thread.spawn(.{}, struct {
        fn worker() void {
            defer state.app.abs.is_loading.store(false, .release);
            fetchLibrariesSync();
        }
    }.worker, .{}) catch blk: {
        state.app.abs.is_loading.store(false, .release);
        break :blk null;
    };
    if (state.app.abs.thread) |t| t.detach();
}

fn fetchLibrariesSync() void {
    const server = state.app.abs.server_url[0..state.app.abs.server_url_len];
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/api/libraries", .{server}) catch return;

    const body = absGet(url) orelse return;
    defer alloc.free(body);

    parse_mutex.lock();
    defer parse_mutex.unlock();
    state.app.abs.library_count = pure.parseLibraries(body, &state.app.abs.libraries);
    logs.pushLog("info", "audiobookshelf", "Libraries loaded", false);
}

/// Select library `idx` and fetch its books (switches to the Books view).
pub fn openLibrary(idx: usize) void {
    if (idx >= state.app.abs.library_count) return;
    if (state.app.abs.is_loading.load(.acquire) or !state.app.abs.connected) return;

    const lib = &state.app.abs.libraries[idx];
    const ilen = @min(lib.id_len, state.app.abs.selected_lib_id.len);
    @memcpy(state.app.abs.selected_lib_id[0..ilen], lib.id[0..ilen]);
    state.app.abs.selected_lib_id_len = ilen;
    const nlen = @min(lib.name_len, state.app.abs.selected_lib_name.len);
    @memcpy(state.app.abs.selected_lib_name[0..nlen], lib.name[0..nlen]);
    state.app.abs.selected_lib_name_len = nlen;

    state.app.abs.book_count = 0;
    state.app.abs.view = .Books;
    state.app.abs.is_loading.store(true, .release);

    state.app.abs.thread = std.Thread.spawn(.{}, struct {
        fn worker() void {
            defer state.app.abs.is_loading.store(false, .release);
            const server = state.app.abs.server_url[0..state.app.abs.server_url_len];
            const lib_id = state.app.abs.selected_lib_id[0..state.app.abs.selected_lib_id_len];

            var url_buf: [640]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "{s}/api/libraries/{s}/items?limit=64", .{ server, lib_id }) catch return;

            const body = absGet(url) orelse return;
            defer alloc.free(body);

            parse_mutex.lock();
            defer parse_mutex.unlock();
            state.app.abs.book_count = pure.parseItems(body, &state.app.abs.books);
            logs.pushLog("info", "audiobookshelf", "Books loaded", false);
        }
    }.worker, .{}) catch blk: {
        state.app.abs.is_loading.store(false, .release);
        break :blk null;
    };
    if (state.app.abs.thread) |t| t.detach();
}

pub fn goToLibraries() void {
    state.app.abs.view = .Libraries;
    state.app.abs.book_count = 0;
}

// ══════════════════════════════════════════════════════════
// Playback
// ══════════════════════════════════════════════════════════

/// Stream book `idx`'s audio into mpv. Builds the token-authed stream URL and
/// hands it to browser.loadContentDirectMeta, which creates a player if needed,
/// load_file's the URL, attaches now-playing metadata (title/author/cover), and
/// gotoPlayer()s — so the macOS Now Playing card is populated automatically.
pub fn playBook(idx: usize) void {
    if (idx >= state.app.abs.book_count) return;
    const server = state.app.abs.server_url[0..state.app.abs.server_url_len];
    const token = state.app.abs.token[0..state.app.abs.token_len];
    if (server.len == 0 or token.len == 0) return;

    // Snapshot the book's fields into locals BEFORE the play call — a concurrent
    // refetch can overwrite books[] mid-frame.
    const b = &state.app.abs.books[idx];
    var id_buf: [64]u8 = undefined;
    const idlen = @min(b.id_len, id_buf.len);
    @memcpy(id_buf[0..idlen], b.id[0..idlen]);
    var title_buf: [256]u8 = undefined;
    const tlen = @min(b.title_len, title_buf.len);
    @memcpy(title_buf[0..tlen], b.title[0..tlen]);
    var author_buf: [160]u8 = undefined;
    const alen = @min(b.author_len, author_buf.len);
    @memcpy(author_buf[0..alen], b.author[0..alen]);

    var url_buf: [1024]u8 = undefined;
    const url = pure.streamUrl(server, id_buf[0..idlen], token, &url_buf) orelse {
        state.showToast("Cannot play — invalid item id");
        return;
    };

    var cover_buf: [1024]u8 = undefined;
    const cover = pure.coverUrl(server, id_buf[0..idlen], token, &cover_buf) orelse "";

    // ── Arm server-side resume BEFORE the load ──
    // Record which book tick() should recognise as loaded, reset the target, and
    // kick the async progress fetch. tick() applies the seek once mpv reports a
    // duration (file open) — seeking earlier is a no-op. Order matters: the book
    // id must be published before loadContentDirectMeta so the id-match gate in
    // tick() (and the fetch worker's publish guard) sees this play, not a stale one.
    resume_mutex.lock();
    resume_target_secs = 0;
    const rlen = @min(idlen, resume_item_id.len);
    @memcpy(resume_item_id[0..rlen], id_buf[0..rlen]);
    resume_item_id_len = rlen;
    resume_mutex.unlock();
    resume_decided.store(false, .release);
    resume_pending.store(true, .release);
    ResumeFetch.spawn();

    @import("browser.zig").loadContentDirectMeta(url, cover, title_buf[0..tlen], author_buf[0..alen]);
    logs.pushLog("info", "audiobookshelf", "Streaming audiobook", false);
}

// ── Resume fetch worker (struct{var}: copies inputs before spawn) ───────────
// GET /api/me/progress/{id}, route the body through pure.resumeTargetFromJson,
// and publish the seek target (guarded so a rapid second play can't land an old
// book's position on the new one). Always resolves `resume_decided` so tick()
// never waits forever — a failed/empty fetch just leaves target 0 (start at 0).
const ResumeFetch = struct {
    var busy: bool = false;

    fn spawn() void {
        if (@This().busy) return; // a fetch is in flight; it already reads the latest id
        @This().busy = true;
        if (std.Thread.spawn(.{}, @This().run, .{})) |t| {
            t.detach();
        } else |_| {
            @This().busy = false;
            resume_decided.store(true, .release); // nothing else will resolve it
        }
    }

    fn run() void {
        defer resume_decided.store(true, .release);
        defer @This().busy = false;

        // Snapshot the book id this fetch is for; publish only if it's still current.
        resume_mutex.lock();
        const idl = @min(resume_item_id_len, resume_item_id.len);
        var id_local: [64]u8 = undefined;
        @memcpy(id_local[0..idl], resume_item_id[0..idl]);
        resume_mutex.unlock();
        if (idl == 0 or !pure.validItemId(id_local[0..idl])) return;

        const server = state.app.abs.server_url[0..state.app.abs.server_url_len];
        if (server.len == 0) return;

        var url_buf: [640]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/api/me/progress/{s}", .{ server, id_local[0..idl] }) catch return;

        // 404/empty (unstarted item) → absGet null → start at 0, silently.
        const body = absGet(url) orelse {
            logs.pushLog("info", "audiobookshelf", "No saved progress — starting at 0", false);
            return;
        };
        defer alloc.free(body);

        const target = pure.resumeTargetFromJson(body) orelse return; // null → leave target 0

        resume_mutex.lock();
        if (resume_item_id_len == idl and std.mem.eql(u8, resume_item_id[0..idl], id_local[0..idl]))
            resume_target_secs = target;
        resume_mutex.unlock();
    }
};

/// Frame-loop hook (UI thread): once the fetch worker has decided AND mpv has the
/// resumed book open, seek to the server-saved second exactly once. Cheap no-op
/// unless a resume is pending. Mirrors anime_skip.tick()'s seek timing + path.
pub fn tick() void {
    if (!resume_pending.load(.acquire)) return;
    if (!resume_decided.load(.acquire)) return; // fetch still running
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const p = state.app.players.items[state.app.active_player_idx];

    resume_mutex.lock();
    const idl = @min(resume_item_id_len, resume_item_id.len);
    var id_local: [64]u8 = undefined;
    @memcpy(id_local[0..idl], resume_item_id[0..idl]);
    const target = resume_target_secs;
    resume_mutex.unlock();

    // Only act once the active player has actually loaded THIS book — a play of
    // something else in the meantime abandons the pending resume.
    const cur = p.current_url[0..p.current_url_len];
    if (idl == 0 or std.mem.indexOf(u8, cur, id_local[0..idl]) == null) {
        resume_pending.store(false, .release);
        return;
    }

    // Wait until mpv reports a duration (file open); seeking before that is a no-op.
    var dur: f64 = 0;
    _ = c.mpv.mpv_get_property(p.mpv_ctx, "duration", c.mpv.MPV_FORMAT_DOUBLE, &dur);
    if (dur <= 1) return; // not open yet — try next frame

    resume_pending.store(false, .release); // one-shot

    if (target > 1) {
        var seek_buf: [64]u8 = undefined;
        const cmd = std.fmt.bufPrintZ(&seek_buf, "seek {d:.1} absolute", .{target}) catch return;
        _ = c.mpv.mpv_command_string(p.mpv_ctx, cmd.ptr);
        var ts_buf: [16]u8 = undefined;
        const ts = yt_pure.formatDuration(@intFromFloat(target), &ts_buf);
        var toast_buf: [64]u8 = undefined;
        const toast = std.fmt.bufPrint(&toast_buf, "Resumed at {s}", .{ts}) catch return;
        state.showToast(toast);
        logs.pushLog("info", "audiobookshelf", "Resumed at server-saved position", false);
    } else {
        logs.pushLog("info", "audiobookshelf", "Starting from the beginning", false);
    }
}

/// Disconnect + clear session (keeps the server URL so reconnect is one field).
pub fn disconnect() void {
    state.app.abs.connected = false;
    state.app.abs.token_len = 0;
    state.app.abs.library_count = 0;
    state.app.abs.book_count = 0;
    state.app.abs.view = .Libraries;
    state.markConfigDirty();
}

// ══════════════════════════════════════════════════════════
// HTTP helper (Bearer GET)
// ══════════════════════════════════════════════════════════

fn absGet(url: []const u8) ?[]u8 {
    const token = state.app.abs.token[0..state.app.abs.token_len];
    var auth_buf: [320]u8 = undefined;
    const auth = pure.bearerHeader(token, &auth_buf) orelse return null;

    const resp_buf = alloc.alloc(u8, 512 * 1024) catch return null;
    defer alloc.free(resp_buf);
    const resp = http.fetch(url, resp_buf, .{
        .timeout_secs = 15,
        .accept = "application/json",
        .auth_header = auth,
    }) orelse return null;

    const result = alloc.alloc(u8, resp.len) catch return null;
    @memcpy(result, resp);
    return result;
}

// ══════════════════════════════════════════════════════════
// UI (Browse › Audiobooks)
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    if (!state.app.abs.connected) {
        renderLoginForm();
        return;
    }
    switch (state.app.abs.view) {
        .Libraries => renderLibraries(),
        .Books => renderBooks(),
    }
}

fn renderLoginForm() void {
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    {
        var hdr = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .x = 16, .y = 20, .w = 16, .h = 16 },
        });
        defer hdr.deinit();
        _ = dvui.label(@src(), "Audiobookshelf", .{}, .{ .color_text = theme.colors.accent });
        _ = dvui.label(@src(), "Connect to your self-hosted Audiobookshelf server", .{}, .{
            .color_text = theme.colors.text_secondary,
            .padding = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
        });
    }

    var form = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = 16, .y = 0, .w = 16, .h = 0 },
    });
    defer form.deinit();

    if (state.app.abs.server_url_len == 0) {
        const default = "http://localhost:13378";
        @memcpy(state.app.abs.server_url[0..default.len], default);
        state.app.abs.server_url_len = default.len;
    }

    _ = labeledEntry("Server URL", &state.app.abs.server_url, false, 1);
    _ = labeledEntry("Username", &state.app.abs.login_user_buf, false, 2);
    const enter = labeledEntry("Password", &state.app.abs.login_pass_buf, true, 3);

    state.app.abs.server_url_len = std.mem.indexOfScalar(u8, &state.app.abs.server_url, 0) orelse state.app.abs.server_url_len;

    if (state.app.abs.login_error_len > 0) {
        _ = dvui.label(@src(), "{s}", .{state.app.abs.login_error[0..state.app.abs.login_error_len]}, .{
            .color_text = theme.colors.danger,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
        });
    }

    if (!state.app.abs.is_loading.load(.acquire)) {
        const connect = dvui.button(@src(), "Connect", .{}, .{
            .expand = .horizontal,
            .color_fill = theme.colors.accent,
            .color_text = theme.colors.text_on_accent,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = theme.spacing.sm },
        });
        if (connect or enter) authenticate();
    } else {
        _ = dvui.label(@src(), "Connecting…", .{}, .{
            .expand = .horizontal,
            .color_text = theme.colors.text_secondary,
            .gravity_x = 0.5,
            .padding = .{ .x = 0, .y = 10, .w = 0, .h = 10 },
        });
    }
}

/// A labelled text-entry row; returns enter_pressed. `id` disambiguates the
/// dvui widget ids across the three fields.
fn labeledEntry(label: []const u8, buf: []u8, password: bool, id: usize) bool {
    _ = dvui.label(@src(), "{s}", .{label}, .{
        .id_extra = id,
        .color_text = theme.colors.text_secondary,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
    });
    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = buf },
        .password_char = if (password) "•" else null,
    }, .{
        .id_extra = id,
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .color_border = theme.colors.border_subtle,
        .border = dvui.Rect.all(1),
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
    });
    const entered = te.enter_pressed;
    te.deinit();
    return entered;
}

fn renderLibraries() void {
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
            .background = true,
            .color_fill = theme.colors.bg_surface,
        });
        defer hdr.deinit();
        _ = dvui.label(@src(), "Audiobookshelf", .{}, .{ .color_text = theme.colors.accent, .gravity_y = 0.5 });
        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }
        if (state.app.abs.is_loading.load(.acquire)) {
            _ = dvui.label(@src(), "…", .{}, .{ .color_text = theme.colors.warning, .gravity_y = 0.5 });
        }
        if (dvui.buttonIcon(@src(), "disconnect", icons.tvg.lucide.@"log-out", .{}, .{}, .{
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_secondary,
            .padding = dvui.Rect.all(5),
            .corner_radius = theme.dims.rad_sm,
        })) disconnect();
    }

    if (state.app.abs.library_count == 0 and !state.app.abs.is_loading.load(.acquire)) {
        _ = dvui.label(@src(), "No libraries found", .{}, .{
            .color_text = theme.colors.text_secondary,
            .padding = .{ .x = 12, .y = 20, .w = 0, .h = 0 },
        });
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    for (0..state.app.abs.library_count) |i| {
        const lib = &state.app.abs.libraries[i];
        var name_buf: [96]u8 = undefined;
        const name = safeUtf8Buf(lib.name[0..lib.name_len], &name_buf);
        if (dvui.button(@src(), name, .{}, .{
            .id_extra = i,
            .expand = .horizontal,
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_primary,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 },
            .margin = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
        })) openLibrary(i);
    }
}

fn renderBooks() void {
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
            .background = true,
            .color_fill = theme.colors.bg_surface,
        });
        defer hdr.deinit();
        if (dvui.buttonIcon(@src(), "Back", icons.tvg.lucide.@"arrow-left", .{}, .{}, .{
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_secondary,
            .corner_radius = theme.dims.rad_sm,
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
        })) {
            goToLibraries();
            return;
        }
        var title_buf: [96]u8 = undefined;
        const title = safeUtf8Buf(state.app.abs.selected_lib_name[0..state.app.abs.selected_lib_name_len], &title_buf);
        _ = dvui.label(@src(), "{s}", .{title}, .{ .color_text = theme.colors.text_primary, .expand = .horizontal, .gravity_y = 0.5 });
        if (state.app.abs.is_loading.load(.acquire)) {
            _ = dvui.label(@src(), "Loading…", .{}, .{ .color_text = theme.colors.warning, .gravity_y = 0.5 });
        }
    }

    if (state.app.abs.book_count == 0) {
        if (!state.app.abs.is_loading.load(.acquire)) {
            _ = dvui.label(@src(), "No books in this library", .{}, .{
                .color_text = theme.colors.text_secondary,
                .padding = .{ .x = 12, .y = 20, .w = 0, .h = 0 },
            });
        }
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    for (0..state.app.abs.book_count) |i| {
        const b = &state.app.abs.books[i];
        var title_buf: [256]u8 = undefined;
        const title = safeUtf8Buf(b.title[0..b.title_len], &title_buf);
        var author_buf: [160]u8 = undefined;
        const author = safeUtf8Buf(b.author[0..b.author_len], &author_buf);

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .color_border = theme.colors.border_subtle,
            .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
            .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
        });
        defer row.deinit();

        _ = dvui.icon(@src(), "", icons.tvg.lucide.@"book-audio", .{}, .{
            .id_extra = i + 1000,
            .color_text = theme.colors.accent,
            .min_size_content = theme.iconSize(.md),
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
        });

        {
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = i + 2000, .expand = .horizontal });
            defer col.deinit();
            _ = dvui.label(@src(), "{s}", .{title}, .{
                .id_extra = i + 3000,
                .color_text = theme.colors.text_primary,
                .expand = .horizontal,
            });
            if (author.len > 0) {
                _ = dvui.label(@src(), "{s}", .{author}, .{
                    .id_extra = i + 4000,
                    .color_text = theme.colors.text_tertiary,
                    .expand = .horizontal,
                });
            }
        }

        if (dvui.buttonIcon(@src(), "Play", icons.tvg.lucide.play, .{}, .{}, .{
            .id_extra = i + 5000,
            .color_fill = theme.colors.accent,
            .color_text = dvui.Color.white,
            .corner_radius = theme.dims.rad_sm,
            .gravity_y = 0.5,
        })) playBook(i);
    }
}
