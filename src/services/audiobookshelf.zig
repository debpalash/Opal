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
const components = @import("../ui/components.zig");
const logs = @import("../core/logs.zig");
const pure = @import("audiobookshelf_pure.zig");
const http = @import("../core/http.zig");
const c = @import("../core/c.zig");
const yt_pure = @import("youtube_pure.zig");
const safeUtf8Buf = @import("../core/text.zig").safeUtf8Buf;
const tmdb_pure = @import("tmdb_pure.zig");

const alloc = @import("../core/alloc.zig").allocator;

// Detached workers publish into state.app.abs.* under this mutex; the UI thread
// reads it each frame. is_loading (atomic) only gates re-spawns.
var parse_mutex: @import("../core/sync.zig").Mutex = .{};

pub const ConnectionSnapshot = struct {
    connected: bool,
    server: [256]u8,
    server_len: usize,
    token: [256]u8,
    token_len: usize,
    libraries: [16]pure.Library,
    library_count: usize,
};
/// Immutable credentials/library identities for independent universal searches.
pub fn connectionSnapshot() ConnectionSnapshot {
    parse_mutex.lock();
    defer parse_mutex.unlock();
    return .{ .connected = state.app.abs.connected, .server = state.app.abs.server_url, .server_len = @min(state.app.abs.server_url_len, state.app.abs.server_url.len), .token = state.app.abs.token, .token_len = @min(state.app.abs.token_len, state.app.abs.token.len), .libraries = state.app.abs.libraries, .library_count = @min(state.app.abs.library_count, state.app.abs.libraries.len) };
}
pub fn setServerUrl(server: []const u8) void {
    parse_mutex.lock();
    defer parse_mutex.unlock();
    @import("../core/text.zig").setFixedUtf8(&state.app.abs.server_url, &state.app.abs.server_url_len, server);
}

pub const CatalogSnapshot = struct {
    connected: bool,
    loading: bool,
    loading_more: bool,
    has_more: bool,
    view: []const u8,
    book_count: usize,
    library_count: usize,
    server: [256]u8,
    server_len: usize,
    library: [96]u8,
    library_len: usize,
    error_text: [128]u8,
    error_len: usize,
};
pub fn catalogSnapshot(books: []pure.Book, libraries: []pure.Library) CatalogSnapshot {
    parse_mutex.lock();
    defer parse_mutex.unlock();
    const bn = @min(state.app.abs.book_count, @min(books.len, state.app.abs.books.len));
    const ln = @min(state.app.abs.library_count, @min(libraries.len, state.app.abs.libraries.len));
    @memcpy(books[0..bn], state.app.abs.books[0..bn]);
    @memcpy(libraries[0..ln], state.app.abs.libraries[0..ln]);
    return .{ .connected = state.app.abs.connected, .loading = state.app.abs.is_loading.load(.acquire), .loading_more = loading_more.load(.acquire), .has_more = more_available and bn < state.app.abs.books.len, .view = @tagName(state.app.abs.view), .book_count = bn, .library_count = ln, .server = state.app.abs.server_url, .server_len = @min(state.app.abs.server_url_len, state.app.abs.server_url.len), .library = state.app.abs.selected_lib_name, .library_len = @min(state.app.abs.selected_lib_name_len, state.app.abs.selected_lib_name.len), .error_text = state.app.abs.login_error, .error_len = @min(state.app.abs.login_error_len, state.app.abs.login_error.len) };
}

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
// Display snapshot for the unified library mirror (same mutex, same lifetime as
// resume_item_id — the fetch worker is the only reader).
var resume_title: [200]u8 = undefined;
var resume_title_len: usize = 0;

// ── Infinite-scroll pagination (Books view) ──
// ABS `/api/libraries/{id}/items` pages are 0-based; `current_page` is the
// highest page merged into state.app.abs.books[]. `more_available` clears
// once a page returns fewer than ABS_PAGE_LIMIT items or the fixed 320-entry
// buffer fills. `loading_more` serializes append fetches so a single
// near-bottom scroll can't spawn a burst (mirrors drama.zig / comics.zig).
// Both plain vars are only ever mutated under `parse_mutex` (openLibrary's
// reset happens on the UI thread before its worker spawns, same as
// book_count=0 above it), so readers under the mutex — and the UI thread's
// render-time reads, which tolerate one frame of staleness like book_count —
// stay consistent.
var current_page: u32 = 0;
var library_generation = std.atomic.Value(u32).init(0);
var more_available: bool = true;
var loading_more: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Items per page for both the initial library-open fetch and every
/// subsequent loadMore() page — must match so a short page reliably signals
/// "no more results" (see audiobookshelf_pure.libraryItemsUrl).
const ABS_PAGE_LIMIT: u32 = 64;
const BOOK_CARD_TARGET_W: f32 = 150;
const BOOK_CARD_GAP: f32 = 4;
const BOOK_FOOTER_H: f32 = 50;
var book_covers: [320]components.CoverSlot = [_]components.CoverSlot{.{}} ** 320;

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

    state.app.abs.thread = @import("../core/workers.zig").spawnLegacy(struct {
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
            @memset(&state.app.abs.login_pass_buf, 0);
            defer @memset(&pass_buf, 0);

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
            var response_status: ?std.http.Status = null;
            const resp = http.fetch(url, &resp_buf, .{
                .method = .POST,
                .payload = body,
                .content_type = "application/json",
                .timeout_secs = 10,
                .status_out = &response_status,
            }) orelse {
                if (response_status) |status| {
                    if (pure.authRejected(@intFromEnum(status))) {
                        setLoginError("Sign-in rejected — check credentials");
                        return;
                    }
                }
                setLoginError("Server unavailable — check address and network");
                return;
            };

            var parsed_token: [256]u8 = undefined;
            defer @memset(&parsed_token, 0);
            const token = pure.parseLoginToken(alloc, resp, &parsed_token) orelse {
                setLoginError("Auth failed — check credentials");
                return;
            };

            parse_mutex.lock();
            const tlen = @min(token.len, state.app.abs.token.len);
            @memcpy(state.app.abs.token[0..tlen], token[0..tlen]);
            state.app.abs.token_len = tlen;
            state.app.abs.connected = true;
            state.app.abs.view = .Libraries;
            parse_mutex.unlock();
            state.markConfigDirty();

            fetchLibrariesSync();
        }
    }.worker, .{}) catch blk: {
        state.app.abs.is_loading.store(false, .release);
        break :blk null;
    };
    if (state.app.abs.thread) |t| @import("../core/workers.zig").release(t);
}

// ══════════════════════════════════════════════════════════
// Libraries / items
// ══════════════════════════════════════════════════════════

pub fn fetchLibraries() void {
    if (state.app.abs.is_loading.load(.acquire) or !state.app.abs.connected) return;
    state.app.abs.is_loading.store(true, .release);
    state.app.abs.thread = @import("../core/workers.zig").spawnLegacy(struct {
        fn worker() void {
            defer state.app.abs.is_loading.store(false, .release);
            fetchLibrariesSync();
        }
    }.worker, .{}) catch blk: {
        state.app.abs.is_loading.store(false, .release);
        break :blk null;
    };
    if (state.app.abs.thread) |t| @import("../core/workers.zig").release(t);
}

fn fetchLibrariesSync() void {
    const server = state.app.abs.server_url[0..state.app.abs.server_url_len];
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/api/libraries", .{server}) catch return;

    const body = absGet(url) orelse {
        if (state.app.abs.connected) setLoginError("Failed to load libraries — check your server connection");
        return;
    };
    defer alloc.free(body);

    parse_mutex.lock();
    defer parse_mutex.unlock();
    state.app.abs.login_error_len = 0;
    state.app.abs.library_count = pure.parseLibraryPage(alloc, body, &state.app.abs.libraries) orelse {
        setLoginError("Invalid library response — check your server connection");
        return;
    };
    logs.pushLog("info", "audiobookshelf", "Libraries loaded", false);
}

/// Select library `idx` and fetch its books (switches to the Books view).
pub fn openLibrary(idx: usize) void {
    if (idx >= state.app.abs.library_count) return;
    if (state.app.abs.is_loading.load(.acquire) or !state.app.abs.connected) return;

    state.app.abs.login_error_len = 0;
    const generation = library_generation.fetchAdd(1, .acq_rel) +% 1;
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
    // Fresh library open resets pagination; the worker below re-derives
    // more_available once page 0 lands (short page / full buffer).
    current_page = 0;
    more_available = true;

    state.app.abs.thread = @import("../core/workers.zig").spawnLegacy(struct {
        fn worker(gen: u32, lib_buf: [64]u8, lib_len: usize) void {
            defer if (library_generation.load(.acquire) == gen) state.app.abs.is_loading.store(false, .release);
            var server_buf: [256]u8 = undefined;
            const server_len = @min(state.app.abs.server_url_len, server_buf.len);
            @memcpy(server_buf[0..server_len], state.app.abs.server_url[0..server_len]);
            const server = server_buf[0..server_len];
            const lib_id = lib_buf[0..lib_len];

            var url_buf: [640]u8 = undefined;
            const url = pure.libraryItemsUrl(server, lib_id, ABS_PAGE_LIMIT, 0, &url_buf) orelse return;

            const body = absGet(url) orelse {
                if (library_generation.load(.acquire) == gen and state.app.abs.connected) {
                    setLoginError("Failed to load library — check your server connection");
                    more_available = false;
                }
                return;
            };
            defer alloc.free(body);

            parse_mutex.lock();
            defer parse_mutex.unlock();
            if (library_generation.load(.acquire) != gen or !state.app.abs.connected or state.app.abs.view != .Books) return;
            const page = pure.parseItemPage(alloc, body, &state.app.abs.books) orelse {
                setLoginError("Invalid library response — retry this library");
                more_available = false;
                return;
            };
            const n = page.count;
            state.app.abs.book_count = n;
            more_available = page.consumed >= ABS_PAGE_LIMIT and n < state.app.abs.books.len;
            logs.pushLog("info", "audiobookshelf", "Books loaded", false);
        }
    }.worker, .{ generation, state.app.abs.selected_lib_id, state.app.abs.selected_lib_id_len }) catch blk: {
        state.app.abs.is_loading.store(false, .release);
        break :blk null;
    };
    if (state.app.abs.thread) |t| @import("../core/workers.zig").release(t);
}

pub fn goToLibraries() void {
    clearAudioSelection();
    _ = library_generation.fetchAdd(1, .acq_rel);
    state.app.abs.is_loading.store(false, .release);
    more_available = false;
    state.app.abs.view = .Libraries;
    state.app.abs.book_count = 0;
}

/// Infinite-scroll appender: fetch the NEXT ABS library-items page and merge
/// it onto the existing Books grid. Guarded by `loading_more` + the main
/// is_loading so a near-bottom scroll can't spawn a burst; no-op once
/// `more_available` clears (short page or the fixed 320-entry buffer filled).
/// Mirrors drama.zig's loadMore / comics.loadMoreResults.
pub fn loadMore() void {
    if (!more_available) return;
    if (state.app.abs.is_loading.load(.acquire)) return;
    if (loading_more.load(.acquire)) return;

    if (state.app.abs.book_count >= state.app.abs.books.len) {
        more_available = false;
        return;
    }
    if (loading_more.swap(true, .acq_rel)) return; // lost the race — another append in flight

    // Capture the OPEN library's id now — loading_more just flipped true, so
    // this call has exclusive claim on the capture. Passing it (plus the next
    // page number) as spawn args means the worker never re-reads
    // selected_lib_id mid-fetch, so a library switch mid-flight can't hand the
    // worker a torn/mismatched id.
    var lib_id_buf: [64]u8 = undefined;
    const lib_id_len = @min(state.app.abs.selected_lib_id_len, lib_id_buf.len);
    @memcpy(lib_id_buf[0..lib_id_len], state.app.abs.selected_lib_id[0..lib_id_len]);
    const next_page = current_page + 1;

    if (@import("../core/workers.zig").spawnLegacy(loadMoreWorker, .{ lib_id_buf, lib_id_len, next_page, library_generation.load(.acquire) })) |t| {
        @import("../core/workers.zig").release(t);
    } else |_| {
        loading_more.store(false, .release);
    }
}

fn loadMoreWorker(lib_id_buf: [64]u8, lib_id_len: usize, page: u32, generation: u32) void {
    defer loading_more.store(false, .release);

    const lib_id = lib_id_buf[0..lib_id_len];
    if (lib_id.len == 0) return;

    var server_buf: [256]u8 = undefined;
    const slen = @min(state.app.abs.server_url_len, server_buf.len);
    @memcpy(server_buf[0..slen], state.app.abs.server_url[0..slen]);
    const server = server_buf[0..slen];
    if (server.len == 0) return;

    var url_buf: [640]u8 = undefined;
    const url = pure.libraryItemsUrl(server, lib_id, ABS_PAGE_LIMIT, page, &url_buf) orelse return;

    const body = absGet(url) orelse {
        if (library_generation.load(.acquire) == generation and state.app.abs.connected) {
            setLoginError("Failed to load more books — reopen the library to retry");
            more_available = false;
        }
        return;
    };
    defer alloc.free(body);

    // Parse into a heap staging buffer — never a big stack buffer on a
    // spawned thread (CLAUDE.md) — before publishing under the lock.
    const items = alloc.alloc(pure.Book, ABS_PAGE_LIMIT) catch return;
    defer alloc.free(items);
    const parsed_page = pure.parseItemPage(alloc, body, items) orelse {
        if (library_generation.load(.acquire) == generation) {
            setLoginError("Invalid library page — reopen the library to retry");
            more_available = false;
        }
        return;
    };
    const n = parsed_page.count;

    parse_mutex.lock();
    defer parse_mutex.unlock();

    // The user may have switched (or left) the library while this page was in
    // flight — drop it rather than append a stale library's books onto
    // whatever is now shown.
    if (library_generation.load(.acquire) != generation or !state.app.abs.connected or state.app.abs.view != .Books or
        state.app.abs.selected_lib_id_len != lib_id_len or
        !std.mem.eql(u8, state.app.abs.selected_lib_id[0..lib_id_len], lib_id))
    {
        return;
    }

    const cap = state.app.abs.books.len;
    const base = state.app.abs.book_count;
    var written: usize = 0;
    while (written < n and base + written < cap) : (written += 1) {
        state.app.abs.books[base + written] = items[written];
    }
    state.app.abs.book_count = base + written;
    current_page = page;
    if (parsed_page.consumed < ABS_PAGE_LIMIT or state.app.abs.book_count >= cap) {
        more_available = false;
    }

    var lb: [48]u8 = undefined;
    logs.pushLog("info", "audiobookshelf", std.fmt.bufPrint(&lb, "Loaded {d} more books (p{d})", .{ n, page }) catch "Loaded more books", false);
    state.wakeUi();
}

// ══════════════════════════════════════════════════════════
// Playback
// ══════════════════════════════════════════════════════════

const AudioJob = struct {
    generation: u32 = 0,
    requested_episode: [64]u8 = std.mem.zeroes([64]u8),
    requested_episode_len: usize = 0,
    id: [64]u8 = std.mem.zeroes([64]u8),
    id_len: usize = 0,
    title: [256]u8 = std.mem.zeroes([256]u8),
    title_len: usize = 0,
    author: [160]u8 = std.mem.zeroes([160]u8),
    author_len: usize = 0,
    server: [256]u8 = std.mem.zeroes([256]u8),
    server_len: usize = 0,
    token: [256]u8 = std.mem.zeroes([256]u8),
    token_len: usize = 0,
};
const AUDIO_CAP: usize = 128;
var audio_mutex: @import("../core/sync.zig").Mutex = .{};
var audio_generation = std.atomic.Value(u32).init(0);
var audio_loading = std.atomic.Value(bool).init(false);
var audio_job: AudioJob = .{};
var audio_tracks: [AUDIO_CAP]pure.AudioTrack = [_]pure.AudioTrack{.{}} ** AUDIO_CAP;
var audio_count: usize = 0;
var audio_total: usize = 0;
var audio_visible: bool = false;
var audio_requested: ?usize = null;
var audio_resume: pure.TrackPosition = .{ .index = 0, .seconds = 0 };
var audio_request_seconds: f64 = 0;
var audio_complete_book: bool = false;
const ActiveAudio = struct {
    job: AudioJob,
    count: usize,
    index: usize,
    complete_book: bool,
    url: [2048]u8 = std.mem.zeroes([2048]u8),
    url_len: usize = 0,
    player_serial: ?u64 = null,
    opened: bool = false,
    last_position: f64 = 0,
    last_sync_ms: i64 = 0,
};
// Frame-thread owned playback plan. Browsing/hiding a selector cannot rewrite it.
var active_audio: ?ActiveAudio = null;
var active_tracks: [AUDIO_CAP]pure.AudioTrack = [_]pure.AudioTrack{.{}} ** AUDIO_CAP;

pub const AudioSnapshot = struct {
    visible: bool,
    complete_book: bool,
    loading: bool,
    count: usize,
    total: usize,
    generation: u32,
    title: [256]u8,
    title_len: usize,
};
/// Snapshot for presenting tracks. Callers serialize only titles/episode flags.
pub fn audioSnapshot(out: []pure.AudioTrack) AudioSnapshot {
    audio_mutex.lock();
    defer audio_mutex.unlock();
    const count = @min(audio_count, out.len);
    @memcpy(out[0..count], audio_tracks[0..count]);
    return .{ .visible = audio_visible, .complete_book = audio_complete_book, .loading = audio_loading.load(.acquire), .count = count, .total = audio_total, .generation = audio_job.generation, .title = audio_job.title, .title_len = audio_job.title_len };
}
pub fn clearAudioSelection() void {
    audio_mutex.lock();
    defer audio_mutex.unlock();
    _ = audio_generation.fetchAdd(1, .acq_rel);
    audio_visible = false;
    audio_count = 0;
    audio_total = 0;
    audio_complete_book = false;
    audio_requested = null;
    @memset(&audio_job.token, 0);
    audio_job.token_len = 0;
    audio_loading.store(false, .release);
}
pub fn playBook(idx: usize) void {
    parse_mutex.lock();
    if (idx >= state.app.abs.book_count) {
        parse_mutex.unlock();
        return;
    }
    const book = state.app.abs.books[idx];
    parse_mutex.unlock();
    playBookById(book.id[0..book.id_len], book.title[0..book.title_len], book.author[0..book.author_len]);
}
/// Resolve actual audio files before playback; `/download` can be a zip archive.
pub fn playBookById(id: []const u8, title: []const u8, author: []const u8) void {
    const connection = connectionSnapshot();
    const slash = std.mem.indexOfScalar(u8, id, '/');
    const item_id = if (slash) |index| id[0..index] else id;
    const episode_id = if (slash) |index| id[index + 1 ..] else "";
    if (!connection.connected or !pure.validItemId(item_id) or item_id.len > 64 or
        (episode_id.len > 0 and (!pure.validItemId(episode_id) or episode_id.len > 64)))
    {
        state.showToast("Connect Audiobookshelf to play this item");
        return;
    }
    var job: AudioJob = .{};
    @import("../core/text.zig").setFixedUtf8(&job.id, &job.id_len, item_id);
    @import("../core/text.zig").setFixedUtf8(&job.requested_episode, &job.requested_episode_len, episode_id);
    @import("../core/text.zig").setFixedUtf8(&job.title, &job.title_len, title);
    @import("../core/text.zig").setFixedUtf8(&job.author, &job.author_len, author);
    job.server_len = connection.server_len;
    @memcpy(job.server[0..job.server_len], connection.server[0..job.server_len]);
    job.token_len = connection.token_len;
    @memcpy(job.token[0..job.token_len], connection.token[0..job.token_len]);
    if (job.server_len == 0 or job.token_len == 0) return;
    audio_mutex.lock();
    job.generation = audio_generation.fetchAdd(1, .acq_rel) +% 1;
    audio_job = job;
    audio_count = 0;
    audio_total = 0;
    audio_requested = null;
    audio_visible = true;
    audio_loading.store(true, .release);
    audio_mutex.unlock();
    state.navigateToTab(.Audiobooks);
    if (@import("../core/workers.zig").spawnLegacy(loadAudioWorker, .{job})) |thread| {
        @import("../core/workers.zig").release(thread);
    } else |_| {
        publishAudioFailure(job.generation, "Could not start audio lookup — select the item again");
        finishAudioJob(job.generation);
    }
}
fn finishAudioJob(generation: u32) void {
    audio_mutex.lock();
    defer audio_mutex.unlock();
    if (audio_generation.load(.acquire) == generation) {
        audio_loading.store(false, .release);
        state.wakeUi();
    }
}
fn publishAudioFailure(generation: u32, message: []const u8) void {
    audio_mutex.lock();
    defer audio_mutex.unlock();
    if (audio_generation.load(.acquire) == generation) setLoginError(message);
}
fn loadAudioWorker(job: AudioJob) void {
    defer finishAudioJob(job.generation);
    var url_buf: [640]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/api/items/{s}?expanded=1", .{ std.mem.trimEnd(u8, job.server[0..job.server_len], "/"), job.id[0..job.id_len] }) catch return;
    var auth_buf: [320]u8 = undefined;
    const auth = pure.bearerHeader(job.token[0..job.token_len], &auth_buf) orelse return;
    const body_buf = alloc.alloc(u8, 3 * 1024 * 1024) catch return;
    defer alloc.free(body_buf);
    const body = http.fetch(url, body_buf, .{ .accept = "application/json", .auth_header = auth, .timeout_secs = 15, .max_response = body_buf.len }) orelse {
        publishAudioFailure(job.generation, "Cannot load audio files — check server access");
        return;
    };
    const staged = alloc.alloc(pure.AudioTrack, AUDIO_CAP) catch return;
    defer alloc.free(staged);
    const page = pure.parseAudioTracks(alloc, body, job.id[0..job.id_len], staged) orelse {
        publishAudioFailure(job.generation, "This item has no playable audio files");
        return;
    };
    const complete = pure.completeBookTimeline(staged[0..page.count], page.total);
    var book_resume: pure.TrackPosition = .{ .index = 0, .seconds = 0 };
    if (complete) {
        var progress_url_buf: [640]u8 = undefined;
        if (pure.progressUrl(job.server[0..job.server_len], job.id[0..job.id_len], "", &progress_url_buf)) |progress_url| {
            var progress_buf: [16384]u8 = undefined;
            if (http.fetch(progress_url, &progress_buf, .{ .accept = "application/json", .auth_header = auth, .timeout_secs = 8 })) |progress_body| {
                const info = pure.parseProgressValue(alloc, progress_body);
                const last = staged[page.count - 1];
                const target = pure.resumeTarget(info.current_time, last.start_offset + last.duration, info.is_finished) orelse 0;
                book_resume = pure.locateBookPosition(staged[0..page.count], target) orelse book_resume;
            }
        }
    }
    audio_mutex.lock();
    defer audio_mutex.unlock();
    if (audio_generation.load(.acquire) != job.generation or !state.app.abs.connected) return;
    @memcpy(audio_tracks[0..page.count], staged[0..page.count]);
    audio_count = page.count;
    audio_total = page.total;
    audio_complete_book = complete;
    audio_resume = book_resume;
    if (job.requested_episode_len > 0) {
        for (staged[0..page.count], 0..) |track, idx| {
            if (std.mem.eql(u8, track.episode_id[0..track.episode_id_len], job.requested_episode[0..job.requested_episode_len])) {
                audio_requested = idx;
                audio_request_seconds = 0;
                break;
            }
        }
    } else if (complete) {
        audio_requested = book_resume.index;
        audio_request_seconds = book_resume.seconds;
    } else if (page.count == 1 and page.total == 1) {
        audio_requested = 0;
        audio_request_seconds = 0;
    }
    if (page.count == 0) setLoginError("This item has no playable audio files");
    state.wakeUi();
}
/// Requests playback on the frame thread, including remote/API callers.
pub fn playAudioTrack(idx: usize, generation: u32) bool {
    audio_mutex.lock();
    defer audio_mutex.unlock();
    if (generation != audio_job.generation or idx >= audio_count) return false;
    audio_requested = idx;
    audio_request_seconds = 0;
    state.wakeUi();
    return true;
}
pub fn playWholeBook(generation: u32) bool {
    audio_mutex.lock();
    defer audio_mutex.unlock();
    if (generation != audio_job.generation or !audio_complete_book) return false;
    audio_requested = audio_resume.index;
    audio_request_seconds = audio_resume.seconds;
    state.wakeUi();
    return true;
}
fn playPendingAudioTrack() void {
    audio_mutex.lock();
    const idx = audio_requested orelse {
        audio_mutex.unlock();
        return;
    };
    audio_requested = null;
    if (idx >= audio_count) {
        audio_mutex.unlock();
        return;
    }
    const job = audio_job;
    const count = audio_count;
    const complete = audio_complete_book;
    const seconds = audio_request_seconds;
    if (audio_generation.load(.acquire) != job.generation or !state.app.abs.connected) {
        audio_mutex.unlock();
        return;
    }
    if (active_audio) |prior| enqueueProgress(prior, false);
    @memcpy(active_tracks[0..count], audio_tracks[0..count]);
    active_audio = .{ .job = job, .count = count, .index = idx, .complete_book = complete };
    audio_mutex.unlock();
    loadActiveAudio(seconds);
}
fn loadActiveAudio(seconds: f64) void {
    if (active_audio == null) return;
    const plan = &active_audio.?;
    const track = active_tracks[plan.index];
    var url_buf: [2048]u8 = undefined;
    const job = plan.job;
    const url = pure.audioTrackUrl(job.server[0..job.server_len], track.content_path[0..track.content_path_len], job.token[0..job.token_len], &url_buf) orelse {
        state.showToast("This audio file URL cannot be played");
        active_audio = null;
        return;
    };
    @memcpy(plan.url[0..url.len], url);
    plan.url_len = url.len;
    plan.opened = false;
    plan.player_serial = null;
    plan.last_position = @max(0, seconds);
    plan.last_sync_ms = @import("../core/io_global.zig").monotonicMilliTimestamp();
    var cover_buf: [1024]u8 = undefined;
    const cover = pure.coverUrl(job.server[0..job.server_len], job.id[0..job.id_len], job.token[0..job.token_len], &cover_buf) orelse "";
    // Server resume was resolved to this file's local seconds before the load.
    resume_pending.store(false, .release);
    var deep_buf: [192]u8 = undefined;
    const deep = if (track.episode)
        std.fmt.bufPrint(&deep_buf, "opal://audiobookshelf/{s}/{s}", .{ job.id[0..job.id_len], track.episode_id[0..track.episode_id_len] }) catch return
    else
        std.fmt.bufPrint(&deep_buf, "opal://audiobookshelf/{s}", .{job.id[0..job.id_len]}) catch return;
    @import("browser.zig").playDirect(.{ .url = url, .history_identity = deep, .restore_target = deep, .resume_position_secs = @max(0, seconds), .art_url = cover, .title = if (track.episode) track.title[0..track.title_len] else job.title[0..job.title_len], .subtitle = job.author[0..job.author_len] });
}
const ProgressJob = struct {
    job: AudioJob,
    episode: [64]u8 = std.mem.zeroes([64]u8),
    episode_len: usize = 0,
    position: f64,
    duration: f64,
    finished: bool,
};
var progress_mutex: @import("../core/sync.zig").Mutex = .{};
var progress_jobs: [8]ProgressJob = undefined;
var progress_head: usize = 0;
var progress_count: usize = 0;
var progress_worker: bool = false;
fn enqueueProgress(plan: ActiveAudio, finished: bool) void {
    const track = active_tracks[plan.index];
    if (!plan.complete_book and !track.episode) return; // partial books cannot truthfully sync file-local time as book progress
    const duration = if (plan.complete_book) active_tracks[plan.count - 1].start_offset + active_tracks[plan.count - 1].duration else track.duration;
    const position = if (plan.complete_book) pure.bookPosition(track, plan.last_position) orelse return else @min(plan.last_position, duration);
    if (duration <= 0) return;
    var request: ProgressJob = .{ .job = plan.job, .position = position, .duration = duration, .finished = finished };
    if (track.episode) {
        request.episode = track.episode_id;
        request.episode_len = track.episode_id_len;
    }
    progress_mutex.lock();
    if (progress_count == progress_jobs.len) {
        // Keep the newest checkpoint without spawning parallel PATCH writers.
        progress_jobs[(progress_head + progress_count - 1) % progress_jobs.len] = request;
    } else {
        progress_jobs[(progress_head + progress_count) % progress_jobs.len] = request;
        progress_count += 1;
    }
    if (!progress_worker) {
        progress_worker = true;
        if (@import("../core/workers.zig").spawnLegacy(progressWorker, .{})) |thread| @import("../core/workers.zig").release(thread) else |_| progress_worker = false;
    }
    progress_mutex.unlock();
}
fn progressWorker() void {
    while (true) {
        progress_mutex.lock();
        if (progress_count == 0) {
            progress_worker = false;
            progress_mutex.unlock();
            return;
        }
        const request = progress_jobs[progress_head];
        progress_head = (progress_head + 1) % progress_jobs.len;
        progress_count -= 1;
        progress_mutex.unlock();
        const job = request.job;
        var url_buf: [768]u8 = undefined;
        const url = pure.progressUrl(job.server[0..job.server_len], job.id[0..job.id_len], request.episode[0..request.episode_len], &url_buf) orelse continue;
        var auth_buf: [320]u8 = undefined;
        const auth = pure.bearerHeader(job.token[0..job.token_len], &auth_buf) orelse continue;
        var payload: [256]u8 = undefined;
        const body = pure.progressBody(request.position, request.duration, request.finished, &payload) orelse continue;
        var response: [16384]u8 = undefined;
        if (http.fetch(url, &response, .{ .method = .PATCH, .payload = body, .content_type = "application/json", .auth_header = auth, .timeout_secs = 8 }) == null)
            logs.pushLog("info", "audiobookshelf", "Playback progress could not sync to the server", false);
        if (request.episode_len == 0) {
            var deep_buf: [192]u8 = undefined;
            const deep = std.fmt.bufPrint(&deep_buf, "opal://audiobookshelf/{s}", .{job.id[0..job.id_len]}) catch continue;
            @import("library_store.zig").upsertProgress("audiobook", job.id[0..job.id_len], job.title[0..job.title_len], "", request.position, request.duration, "", deep);
        }
    }
}
/// mpv may unload a completed file before `eof-reached` can be polled.
/// Consume the authoritative EOF event while the player still owns this load;
/// return true so generic queue/playlist advancement cannot race book tracks.
pub fn handlePlayerEof(player: anytype) bool {
    if (active_audio == null or !state.app.abs.connected) return false;
    const plan = &active_audio.?;
    const current = player.current_url[0..@min(player.current_url_len, player.current_url.len)];
    if (!std.mem.eql(u8, current, plan.url[0..plan.url_len]) or player.is_loading or player.load_error_len > 0) return false;
    if (plan.player_serial) |serial| if (serial != player.load_serial) return false;
    advanceAudioTrack(plan);
    return true;
}

fn advanceAudioTrack(plan: *ActiveAudio) void {
    plan.last_position = active_tracks[plan.index].duration;
    const final = !plan.complete_book or plan.index + 1 >= plan.count;
    enqueueProgress(plan.*, final);
    if (!final) {
        plan.index += 1;
        loadActiveAudio(0);
    } else active_audio = null;
}

fn tickAudioTimeline() void {
    if (active_audio == null) return;
    const plan = &active_audio.?;
    if (!state.app.abs.connected) {
        enqueueProgress(plan.*, false);
        active_audio = null;
        return;
    }
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const player = state.app.players.items[state.app.active_player_idx];
    const current = player.current_url[0..@min(player.current_url_len, player.current_url.len)];
    if (!std.mem.eql(u8, current, plan.url[0..plan.url_len])) {
        if (plan.opened) {
            logs.pushLog("info", "audiobookshelf", "Playback switched; saving outgoing book progress", false);
            enqueueProgress(plan.*, false);
            active_audio = null;
        }
        return;
    }
    if (plan.player_serial) |serial| {
        if (serial != player.load_serial) {
            logs.pushLog("info", "audiobookshelf", "Playback replaced; saving outgoing book progress", false);
            enqueueProgress(plan.*, false);
            active_audio = null;
            return;
        }
    } else plan.player_serial = player.load_serial;
    var duration: f64 = 0;
    if (c.mpv.mpv_get_property(player.mpv_ctx, "duration", c.mpv.MPV_FORMAT_DOUBLE, &duration) >= 0 and duration > 0) plan.opened = true;
    var position: f64 = 0;
    if (c.mpv.mpv_get_property(player.mpv_ctx, "time-pos", c.mpv.MPV_FORMAT_DOUBLE, &position) >= 0 and std.math.isFinite(position) and position >= 0)
        plan.last_position = position;
    var eof: c_int = 0;
    _ = c.mpv.mpv_get_property(player.mpv_ctx, "eof-reached", c.mpv.MPV_FORMAT_FLAG, &eof);
    const now = @import("../core/io_global.zig").monotonicMilliTimestamp();
    if (pure.shouldAdvanceTrack(plan.opened, !player.is_loading, eof != 0, player.load_error_len > 0)) {
        advanceAudioTrack(plan);
    } else if (plan.opened and now - plan.last_sync_ms >= 10000) {
        enqueueProgress(plan.*, false);
        plan.last_sync_ms = now;
    }
}
fn renderAudioSelection() bool {
    audio_mutex.lock();
    const visible = audio_visible;
    const title_buf = audio_job.title;
    const title_len = audio_job.title_len;
    const generation = audio_job.generation;
    const count = audio_count;
    const total = audio_total;
    const complete = audio_complete_book;
    audio_mutex.unlock();
    if (!visible) return false;
    var column = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer column.deinit();
    if (components.actionButton(@src(), "Back to library", .secondary, 91001)) {
        clearAudioSelection();
        return true;
    }
    _ = dvui.label(@src(), "{s}", .{title_buf[0..title_len]}, .{ .color_text = theme.colors.text_primary });
    if (audio_loading.load(.acquire)) {
        dvui.spinner(@src(), .{ .color_text = theme.colors.accent, .min_size_content = theme.iconSize(.md) });
        return true;
    }
    _ = dvui.label(@src(), "Choose a track or episode · {d} available of {d}", .{ count, total }, .{ .color_text = theme.colors.text_secondary });
    if (complete and components.actionButton(@src(), "Play book from saved position", .primary, 91002)) _ = playWholeBook(generation);
    if (complete) _ = dvui.label(@src(), "Book tracks advance automatically and resume across files.", .{}, .{ .color_text = theme.colors.text_secondary });
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .color_fill = theme.colors.bg_surface, .background = true });
    defer scroll.deinit();
    for (0..count) |idx| {
        audio_mutex.lock();
        const track = audio_tracks[idx];
        audio_mutex.unlock();
        if (components.actionButton(@src(), track.title[0..track.title_len], .secondary, 91100 + idx)) _ = playAudioTrack(idx, generation);
    }
    return true;
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
        if (@import("../core/workers.zig").spawnLegacy(@This().run, .{})) |t| {
            @import("../core/workers.zig").release(t);
        } else |_| {
            @This().busy = false;
            resume_decided.store(true, .release); // nothing else will resolve it
        }
    }

    fn run() void {
        defer resume_decided.store(true, .release);
        defer @This().busy = false;

        // Snapshot the book id + display fields this fetch is for; publish only
        // if the id is still current.
        resume_mutex.lock();
        const idl = @min(resume_item_id_len, resume_item_id.len);
        var id_local: [64]u8 = undefined;
        @memcpy(id_local[0..idl], resume_item_id[0..idl]);
        var title_local: [200]u8 = undefined;
        const tl = @min(resume_title_len, title_local.len);
        @memcpy(title_local[0..tl], resume_title[0..tl]);
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

        // Mirror the SERVER's saved position (the authority for this vertical)
        // into the unified read-model so home's Continue rail carries audiobooks.
        // Done before the resume decision so a finished/near-zero book still
        // refreshes its row (library_pure decides what belongs on the rail).
        const info = pure.parseProgress(body);
        if (idl > 0 and tl > 0) {
            @import("library_store.zig").upsertProgress(
                "audiobook",
                id_local[0..idl],
                title_local[0..tl],
                "",
                info.current_time orelse 0,
                info.duration orelse 0,
                "",
                id_local[0..idl],
            );
        }

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
    playPendingAudioTrack();
    tickAudioTimeline();
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
    clearAudioSelection();
    parse_mutex.lock();
    defer parse_mutex.unlock();
    _ = library_generation.fetchAdd(1, .acq_rel);
    state.app.abs.connected = false;
    @memset(&state.app.abs.token, 0);
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
    var response_status: ?std.http.Status = null;
    const resp = http.fetch(url, resp_buf, .{
        .timeout_secs = 15,
        .accept = "application/json",
        .auth_header = auth,
        .status_out = &response_status,
    }) orelse {
        if (response_status) |status| {
            if (pure.authRejected(@intFromEnum(status))) expireAuthSession();
        }
        return null;
    };

    const result = alloc.alloc(u8, resp.len) catch return null;
    @memcpy(result, resp);
    return result;
}

fn expireAuthSession() void {
    clearAudioSelection();
    parse_mutex.lock();
    if (!state.app.abs.connected) {
        parse_mutex.unlock();
        return;
    }
    _ = library_generation.fetchAdd(1, .acq_rel);
    state.app.abs.is_loading.store(false, .release);
    state.app.abs.connected = false;
    @memset(&state.app.abs.token, 0);
    state.app.abs.token_len = 0;
    state.app.abs.library_count = 0;
    state.app.abs.book_count = 0;
    state.app.abs.view = .Libraries;
    const message = "Session expired — sign in again";
    @memcpy(state.app.abs.login_error[0..message.len], message);
    state.app.abs.login_error_len = message.len;
    current_page = 0;
    more_available = false;
    parse_mutex.unlock();
    state.markConfigDirty();
    state.wakeUi();
}

// ══════════════════════════════════════════════════════════
// UI (Browse › Audiobooks)
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    if (!state.app.abs.connected) {
        renderLoginForm();
        return;
    }
    if (state.app.abs.login_error_len > 0) {
        var error_buf: [256]u8 = undefined;
        const error_text = safeUtf8Buf(state.app.abs.login_error[0..@min(state.app.abs.login_error_len, state.app.abs.login_error.len)], &error_buf);
        _ = dvui.label(@src(), "{s}", .{error_text}, .{ .color_text = theme.colors.danger, .padding = dvui.Rect.all(8) });
    }
    if (renderAudioSelection()) return;
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
        _ = dvui.label(@src(), "Audiobookshelf", .{}, .{ .color_text = theme.colors.text_primary, .font = dvui.themeGet().font_heading, .gravity_y = 0.5 });
        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }
        if (state.app.abs.is_loading.load(.acquire)) {
            dvui.spinner(@src(), .{ .color_text = theme.colors.accent, .min_size_content = theme.iconSize(.md), .gravity_y = 0.5 });
        }
        if (components.iconButton(@src(), icons.tvg.lucide.@"log-out", "Disconnect Audiobookshelf", false)) disconnect();
    }

    if (state.app.abs.library_count == 0 and !state.app.abs.is_loading.load(.acquire)) {
        components.emptyState(icons.tvg.lucide.@"book-audio", "No libraries found", "Add an audiobook library in Audiobookshelf, then refresh.");
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
        if (components.iconButton(@src(), icons.tvg.lucide.@"arrow-left", "Back to libraries", false)) {
            goToLibraries();
            return;
        }
        var title_buf: [96]u8 = undefined;
        const title = safeUtf8Buf(state.app.abs.selected_lib_name[0..state.app.abs.selected_lib_name_len], &title_buf);
        _ = dvui.label(@src(), "{s}", .{title}, .{ .color_text = theme.colors.text_primary, .font = dvui.themeGet().font_heading, .expand = .horizontal, .gravity_y = 0.5 });
        if (state.app.abs.is_loading.load(.acquire)) {
            dvui.spinner(@src(), .{ .color_text = theme.colors.accent, .min_size_content = theme.iconSize(.md), .gravity_y = 0.5 });
        }
    }

    if (state.app.abs.book_count == 0 and more_available and !state.app.abs.is_loading.load(.acquire)) loadMore();
    if (state.app.abs.book_count == 0) {
        if (!state.app.abs.is_loading.load(.acquire) and !loading_more.load(.acquire)) {
            components.emptyState(icons.tvg.lucide.@"book-audio", "No audiobooks here", "Choose another library or add books in Audiobookshelf.");
            return;
        }
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    const count = @min(state.app.abs.book_count, state.app.abs.books.len);
    const rect_w = scroll.data().rect.w;
    const avail_w: f32 = @max(240, (if (rect_w > 1) rect_w else 900) - 8);
    const cols: usize = @max(1, @as(usize, @intFromFloat(avail_w / BOOK_CARD_TARGET_W)));
    const cols_f: f32 = @floatFromInt(cols);
    const card_w: f32 = @max(104, (avail_w - cols_f * 2 * BOOK_CARD_GAP) / cols_f);
    const poster_h = card_w * 1.45;
    const row_h = poster_h + BOOK_FOOTER_H + 2 * BOOK_CARD_GAP;
    const total_rows = (count + cols - 1) / cols;
    if (count == 0) {
        components.coverSkeletonGrid(@src(), 77000, cols, card_w, poster_h, BOOK_FOOTER_H, 3);
        return;
    }
    const win = tmdb_pure.visibleRows(total_rows, row_h, scroll.si.viewport.y, scroll.si.viewport.h, 2);
    if (win.first > 0) {
        var sp = dvui.box(@src(), .{}, .{
            .id_extra = 79998,
            .min_size_content = .{ .w = 1, .h = row_h * @as(f32, @floatFromInt(win.first)) },
        });
        sp.deinit();
    }

    var r: usize = win.first;
    while (r < win.last) : (r += 1) {
        const base = r * cols;
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = base + 78000, .expand = .horizontal });
        defer row.deinit();
        var col: usize = 0;
        while (col < cols and base + col < count) : (col += 1)
            renderBookCard(base + col, card_w, poster_h);
    }

    if (win.last < total_rows) {
        var sp = dvui.box(@src(), .{}, .{
            .id_extra = 79999,
            .min_size_content = .{ .w = 1, .h = row_h * @as(f32, @floatFromInt(total_rows - win.last)) },
        });
        sp.deinit();
    }

    // Infinite scroll: fetch + append the next ABS library-items page as the
    // user nears the bottom. Bounded by more_available + loading_more so one
    // scroll can't spawn a burst; `underfilled` keeps paging when the first
    // page is shorter than the viewport. Mirrors services/drama.zig.
    if (more_available) {
        const loading = loading_more.load(.acquire);
        const max_y = scroll.si.scrollMax(.vertical);
        const near_bottom = max_y > 0 and scroll.si.viewport.y >= max_y - 800;
        const underfilled = max_y <= 0 and state.app.abs.book_count > 0;
        if ((near_bottom or underfilled) and !loading and !state.app.abs.is_loading.load(.acquire)) {
            loadMore();
        }
        if (loading or underfilled) {
            dvui.spinner(@src(), .{
                .color_text = theme.colors.accent,
                .min_size_content = theme.iconSize(.lg),
                .gravity_x = 0.5,
                .margin = dvui.Rect.all(12),
            });
            state.wakeUi(); // wake until the worker's items land
        }
    }
}

fn renderBookCard(i: usize, card_w: f32, poster_h: f32) void {
    const b = &state.app.abs.books[i];
    var title_buf: [256]u8 = undefined;
    const title = safeUtf8Buf(b.title[0..b.title_len], &title_buf);
    var author_buf: [160]u8 = undefined;
    const author = safeUtf8Buf(b.author[0..b.author_len], &author_buf);

    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = i + 80000,
        .min_size_content = .{ .w = card_w, .h = poster_h + BOOK_FOOTER_H },
        .max_size_content = .{ .w = card_w, .h = poster_h + BOOK_FOOTER_H },
        .margin = dvui.Rect.all(BOOK_CARD_GAP),
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .color_fill_hover = theme.colors.bg_hover,
        .corner_radius = dvui.Rect.all(theme.radius.md),
    });
    defer card.deinit();

    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{}, .{
        .id_extra = i + 81000,
        .background = true,
        .color_fill = theme.colors.bg_elevated,
        .corner_radius = dvui.Rect.all(theme.radius.md),
        .min_size_content = .{ .w = card_w, .h = poster_h },
        .max_size_content = .{ .w = card_w, .h = poster_h },
        .padding = dvui.Rect.all(0),
    });
    bw.processEvents();
    bw.drawBackground();
    var cover_buf: [1024]u8 = undefined;
    const cover = pure.coverUrl(
        state.app.abs.server_url[0..state.app.abs.server_url_len],
        b.id[0..b.id_len],
        state.app.abs.token[0..state.app.abs.token_len],
        &cover_buf,
    ) orelse "";
    components.coverArt(@src(), i + 82000, &book_covers[i], cover, icons.tvg.lucide.@"book-audio", theme.radius.md);
    const clicked = bw.clicked();
    bw.drawFocus();
    bw.deinit();
    if (clicked) playBook(i);

    _ = dvui.label(@src(), "{s}", .{title}, .{
        .id_extra = i + 83000,
        .color_text = theme.colors.text_primary,
        .font = dvui.themeGet().font_heading.withSize(theme.font_size.small),
        .min_size_content = .{ .w = card_w, .h = 20 },
        .max_size_content = .{ .w = card_w, .h = 20 },
        .padding = .{ .x = 5, .y = 5, .w = 5, .h = 0 },
    });
    _ = dvui.label(@src(), "{s}", .{if (author.len > 0) author else "Audiobook"}, .{
        .id_extra = i + 84000,
        .color_text = theme.colors.text_tertiary,
        .font = dvui.themeGet().font_body.withSize(theme.font_size.small),
        .min_size_content = .{ .w = card_w, .h = 18 },
        .max_size_content = .{ .w = card_w, .h = 18 },
        .padding = .{ .x = 5, .y = 0, .w = 5, .h = 4 },
    });
}
