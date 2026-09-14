const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const c = @import("../core/c.zig");
const layout = @import("queue_layout_pure.zig");
const playback = @import("../player/queue_playback_pure.zig");
const playlist_pure = @import("../player/playlist_pure.zig");

const alloc = @import("../core/alloc.zig").allocator;

// ══════════════════════════════════════════════════════════
// Queue Item (mirrors mpv playlist + persisted metadata)
// ══════════════════════════════════════════════════════════

pub const QueueItem = struct {
    id: i64 = 0, // SQLite rowid
    position: i64 = 0, // explicit durable display/play order
    url: [2048]u8 = std.mem.zeroes([2048]u8),
    url_len: usize = 0,
    title: [256]u8 = std.mem.zeroes([256]u8),
    title_len: usize = 0,
    source: [32]u8 = std.mem.zeroes([32]u8), // "youtube", "magnet", "direct", "m3u"
    source_len: usize = 0,
    thumb_url: [512]u8 = std.mem.zeroes([512]u8),
    thumb_url_len: usize = 0,
    // Thumbnail state (same pattern as youtube.zig)
    thumb_tex: ?dvui.Texture = null,
    thumb_pixels: ?[]u8 = null,
    thumb_w: u32 = 0,
    thumb_h: u32 = 0,
    thumb_fetching: bool = false,
    // Set once a thumbnail fetch has terminally failed, so the per-frame
    // render loop does not respawn a fetch thread for it every frame.
    thumb_failed: bool = false,
    duration: i64 = 0,
    added_at: i64 = 0,
    played: bool = false,
};

pub const MAX_QUEUE: usize = 200;
pub const Action = enum {
    @"clear-played",
    clear,
    @"move-up",
    @"move-down",
    remove,
    play,
    previous,
    next,
    @"toggle-shuffle",
    @"cycle-repeat",
};
pub var queue_items: [MAX_QUEUE]QueueItem = undefined;
pub var queue_count: usize = 0;
var data_lock = @import("../core/sync.zig").Mutex{};
var db: ?*c.sqlite.sqlite3 = null;
// 0 waiting, 1 initializing, 2 ready, 3 closing. Release/acquire publishes
// both the SQLite handle and the initial queue snapshot across threads.
var db_state = std.atomic.Value(u8).init(0);

// One full playlist can arrive from an extractor before the next UI frame.
const PENDING_CAP: usize = MAX_QUEUE;
var pending_items: [PENDING_CAP]QueueItem = undefined;
var pending_count: usize = 0;
var pending_lock = @import("../core/sync.zig").Mutex{};

const ACTION_CAP: usize = 64;
const PendingAction = struct {
    action: Action,
    item_id: ?i64,
    request_id: u64,
};
var pending_actions: [ACTION_CAP]PendingAction = undefined;
var pending_action_head: usize = 0;
var pending_action_count: usize = 0;
var action_lock = @import("../core/sync.zig").Mutex{};
var next_action_id: u64 = 1;
var completed_action_id = std.atomic.Value(u64).init(0);

var shuffle_order: [MAX_QUEUE]u32 = undefined;
var shuffle_order_len: usize = 0;
var shuffle_order_seed: u64 = 0;

// ══════════════════════════════════════════════════════════
// SQLite Database Management
// ══════════════════════════════════════════════════════════

pub fn initDb() void {
    if (db_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return;
    var success = false;
    defer if (!success) db_state.store(0, .release);

    var __cfg_buf_0: [512]u8 = undefined;
    const home = @import("../core/paths.zig").configDir(&__cfg_buf_0);
    var path_buf: [640]u8 = undefined;
    const db_path = std.fmt.bufPrintZ(&path_buf, "{s}/queue.db", .{home}) catch return;

    // Ensure directory exists
    var dir_buf: [640]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "{s}", .{home}) catch return;
    _ = @import("../core/io_global.zig").makeDirAbsolute(dir_path) catch {};

    const flags = c.sqlite.SQLITE_OPEN_READWRITE | c.sqlite.SQLITE_OPEN_CREATE | c.sqlite.SQLITE_OPEN_FULLMUTEX;
    if (c.sqlite.sqlite3_open_v2(db_path.ptr, &db, flags, null) != c.sqlite.SQLITE_OK) {
        db = null;
        return;
    }
    _ = c.sqlite.sqlite3_busy_timeout(db.?, 2500);
    _ = c.sqlite.sqlite3_exec(db.?, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;", null, null, null);
    @import("../core/secret_file.zig").restrictExisting(std.mem.sliceTo(db_path, 0));

    // Create table
    const sql = "CREATE TABLE IF NOT EXISTS queue (" ++
        "id INTEGER PRIMARY KEY AUTOINCREMENT," ++
        "url TEXT NOT NULL," ++
        "title TEXT DEFAULT ''," ++
        "source TEXT DEFAULT 'direct'," ++
        "thumb_url TEXT DEFAULT ''," ++
        "duration INTEGER DEFAULT 0," ++
        "added_at INTEGER DEFAULT 0," ++
        "played INTEGER DEFAULT 0," ++
        "position INTEGER NOT NULL DEFAULT 0" ++
        ");";
    _ = c.sqlite.sqlite3_exec(db.?, sql, null, null, null);

    // Migration: add thumb_url column if missing
    const migrate_sql = "ALTER TABLE queue ADD COLUMN thumb_url TEXT DEFAULT '';";
    _ = c.sqlite.sqlite3_exec(db.?, migrate_sql, null, null, null);
    _ = c.sqlite.sqlite3_exec(db.?, "ALTER TABLE queue ADD COLUMN position INTEGER NOT NULL DEFAULT 0;", null, null, null);
    // Preserve the exact legacy visible order (which was id DESC), then make
    // all future inserts append at the bottom through an explicit position.
    _ = c.sqlite.sqlite3_exec(db.?, "UPDATE queue SET position = -id WHERE position = 0;", null, null, null);

    data_lock.lock();
    defer data_lock.unlock();
    loadFromDb();
    flushPending();
    success = true;
    state.wakeUi();
}

pub fn isReady() bool {
    return db_state.load(.acquire) == 2;
}

pub fn deinit() void {
    if (db_state.swap(3, .acq_rel) == 3) return;

    // Workers are drained before this call, so ownership is stable and all
    // queue-side image resources can be released on the main thread.
    thumb_result_lock.lock();
    for (thumb_results[0..thumb_result_count]) |result| {
        if (result.pixels) |pixels| alloc.free(pixels);
    }
    thumb_result_count = 0;
    thumb_result_lock.unlock();
    for (queue_items[0..queue_count]) |*item| {
        if (item.thumb_pixels) |pixels| alloc.free(pixels);
        if (item.thumb_tex) |tex| {
            if (state.app.dvui_win) |win| win.backend.textureDestroy(tex);
        }
        item.thumb_pixels = null;
        item.thumb_tex = null;
    }
    queue_count = 0;

    if (db) |handle| {
        _ = c.sqlite.sqlite3_close_v2(handle);
        db = null;
    }
}

fn loadFromDb() void {
    if (db == null) return;
    const sql = "SELECT id, url, title, source, duration, added_at, played, thumb_url, position FROM queue ORDER BY position ASC, id ASC LIMIT 200;";
    var stmt: ?*c.sqlite.sqlite3_stmt = null;
    if (c.sqlite.sqlite3_prepare_v2(db.?, sql, -1, &stmt, null) != c.sqlite.SQLITE_OK) return;
    defer _ = c.sqlite.sqlite3_finalize(stmt);

    const old_count = queue_count;
    const old_items: ?[]QueueItem = if (old_count > 0) alloc.alloc(QueueItem, old_count) catch return else null;
    if (old_items) |items| @memcpy(items, queue_items[0..old_count]);
    defer if (old_items) |items| {
        for (items) |*old| {
            if (old.thumb_pixels) |pixels| alloc.free(pixels);
            if (old.thumb_tex) |tex| {
                if (dvui.current_window != null) dvui.textureDestroyLater(tex);
            }
        }
        alloc.free(items);
    };
    queue_count = 0;

    while (c.sqlite.sqlite3_step(stmt) == c.sqlite.SQLITE_ROW) {
        if (queue_count >= MAX_QUEUE) break;
        var item = QueueItem{};
        item.id = c.sqlite.sqlite3_column_int64(stmt, 0);

        const url_ptr: ?[*]const u8 = @ptrCast(c.sqlite.sqlite3_column_text(stmt, 1));
        if (url_ptr) |ptr| {
            const url_clen: usize = @intCast(c.sqlite.sqlite3_column_bytes(stmt, 1));
            const ulen = @min(url_clen, 2047);
            @memcpy(item.url[0..ulen], ptr[0..ulen]);
            item.url_len = ulen;
        }

        const title_ptr: ?[*]const u8 = @ptrCast(c.sqlite.sqlite3_column_text(stmt, 2));
        if (title_ptr) |ptr| {
            const title_clen: usize = @intCast(c.sqlite.sqlite3_column_bytes(stmt, 2));
            const tlen = @min(title_clen, 255);
            @memcpy(item.title[0..tlen], ptr[0..tlen]);
            item.title_len = tlen;
        }

        const src_ptr: ?[*]const u8 = @ptrCast(c.sqlite.sqlite3_column_text(stmt, 3));
        if (src_ptr) |ptr| {
            const src_clen: usize = @intCast(c.sqlite.sqlite3_column_bytes(stmt, 3));
            const slen = @min(src_clen, 31);
            @memcpy(item.source[0..slen], ptr[0..slen]);
            item.source_len = slen;
        }

        item.duration = c.sqlite.sqlite3_column_int64(stmt, 4);
        item.added_at = c.sqlite.sqlite3_column_int64(stmt, 5);
        item.played = c.sqlite.sqlite3_column_int(stmt, 6) != 0;

        const thumb_ptr: ?[*]const u8 = @ptrCast(c.sqlite.sqlite3_column_text(stmt, 7));
        if (thumb_ptr) |ptr| {
            const thumb_clen: usize = @intCast(c.sqlite.sqlite3_column_bytes(stmt, 7));
            const thlen = @min(thumb_clen, 511);
            if (thlen > 0) {
                @memcpy(item.thumb_url[0..thlen], ptr[0..thlen]);
                item.thumb_url_len = thlen;
            }
        }
        item.position = c.sqlite.sqlite3_column_int64(stmt, 8);

        // A DB reload changes metadata/order, not thumbnail ownership. Transfer
        // live resources by stable row ID and leave removed rows for cleanup.
        if (old_items) |items| {
            for (items) |*old| {
                if (old.id != item.id) continue;
                item.thumb_tex = old.thumb_tex;
                item.thumb_pixels = old.thumb_pixels;
                item.thumb_w = old.thumb_w;
                item.thumb_h = old.thumb_h;
                item.thumb_fetching = old.thumb_fetching;
                item.thumb_failed = old.thumb_failed;
                old.thumb_tex = null;
                old.thumb_pixels = null;
                break;
            }
        }

        queue_items[queue_count] = item;
        queue_count += 1;
    }
}

pub fn addToQueue(url: []const u8, title: []const u8, source: []const u8) void {
    addToQueueWithThumb(url, title, source, "");
}

fn getTransient() c.sqlite.sqlite3_destructor_type {
    @setRuntimeSafety(false);
    var transient_ptr_int: usize = std.math.maxInt(usize);
    transient_ptr_int += 0;
    return @ptrFromInt(transient_ptr_int);
}

pub fn addToQueueWithThumb(url: []const u8, title: []const u8, source: []const u8, thumb_url: []const u8) void {
    if (!validInput(url, title, source, thumb_url)) return;
    // Producers include background playlist extractors. Always stage their
    // immutable copy; only the UI thread mutates the live queue after startup.
    if (!enqueuePending(url, title, source, thumb_url))
        @import("../core/logs.zig").pushLog("error", "queue", "Pending queue is full", true);
    state.wakeUi();
}

fn validInput(url: []const u8, title: []const u8, source: []const u8, thumb_url: []const u8) bool {
    return url.len > 0 and url.len < 2048 and title.len < 256 and source.len < 32 and thumb_url.len < 512;
}

fn enqueuePending(url: []const u8, title: []const u8, source: []const u8, thumb_url: []const u8) bool {
    pending_lock.lock();
    defer pending_lock.unlock();
    if (pending_count >= PENDING_CAP) return false;
    var item = QueueItem{};
    @memcpy(item.url[0..url.len], url);
    item.url_len = url.len;
    @memcpy(item.title[0..title.len], title);
    item.title_len = title.len;
    @memcpy(item.source[0..source.len], source);
    item.source_len = source.len;
    @memcpy(item.thumb_url[0..thumb_url.len], thumb_url);
    item.thumb_url_len = thumb_url.len;
    pending_items[pending_count] = item;
    pending_count += 1;
    return true;
}

fn flushPending() void {
    pending_lock.lock();
    defer pending_lock.unlock();
    if (pending_count > 0 and db != null)
        _ = c.sqlite.sqlite3_exec(db.?, "BEGIN IMMEDIATE;", null, null, null);
    for (pending_items[0..pending_count]) |*item| {
        const url = item.url[0..item.url_len];
        const title = item.title[0..item.title_len];
        const source = item.source[0..item.source_len];
        const thumb = item.thumb_url[0..item.thumb_url_len];
        if (insertReady(url, title, source, thumb)) {
            queue_count += 1;
            @import("activity.zig").record(.queue_add, title, .{ .key = url });
        }
        item.* = .{};
    }
    if (pending_count > 0 and db != null)
        _ = c.sqlite.sqlite3_exec(db.?, "COMMIT;", null, null, null);
    pending_count = 0;
    loadFromDb();
    // Publish ready while still holding the pending lock. An add that observed
    // state=initializing either entered this batch before publication, or waits
    // and then observes ready; it can never land in an already-drained queue.
    db_state.store(2, .release);
}

/// Drain producer work on the UI thread. Called every frame even when the
/// drawer is closed, so queueing never depends on a particular view being open.
pub fn drainUi() void {
    if (!isReady()) return;

    pending_lock.lock();
    const has_adds = pending_count > 0;
    pending_lock.unlock();
    if (has_adds) {
        data_lock.lock();
        flushPending();
        data_lock.unlock();
    }

    drainPendingActions();
    drainThumbResults();
    if (backfill_refresh_pending.swap(false, .acq_rel)) {
        data_lock.lock();
        loadFromDb();
        data_lock.unlock();
    }
}

fn insertReady(url: []const u8, title: []const u8, source: []const u8, thumb_url: []const u8) bool {
    if (db == null) return false;
    if (queue_count >= MAX_QUEUE) return false;
    const sql = "INSERT INTO queue (url, title, source, thumb_url, added_at, position) " ++
        "VALUES (?1, ?2, ?3, ?4, ?5, MAX(COALESCE((SELECT MAX(position) FROM queue), 0) + 1, 1));";
    var stmt: ?*c.sqlite.sqlite3_stmt = null;
    if (c.sqlite.sqlite3_prepare_v2(db.?, sql, -1, &stmt, null) != c.sqlite.SQLITE_OK) return false;
    defer _ = c.sqlite.sqlite3_finalize(stmt);

    _ = c.sqlite.sqlite3_bind_text(stmt, 1, url.ptr, @intCast(url.len), getTransient());
    _ = c.sqlite.sqlite3_bind_text(stmt, 2, title.ptr, @intCast(title.len), getTransient());
    _ = c.sqlite.sqlite3_bind_text(stmt, 3, source.ptr, @intCast(source.len), getTransient());
    _ = c.sqlite.sqlite3_bind_text(stmt, 4, thumb_url.ptr, @intCast(thumb_url.len), getTransient());
    _ = c.sqlite.sqlite3_bind_int64(stmt, 5, @import("../core/io_global.zig").timestamp());

    return c.sqlite.sqlite3_step(stmt) == c.sqlite.SQLITE_DONE;
}

pub fn removeFromQueue(item_id: i64) void {
    data_lock.lock();
    defer data_lock.unlock();
    if (db == null) return;

    const sql = "DELETE FROM queue WHERE id = ?1;";
    var stmt: ?*c.sqlite.sqlite3_stmt = null;
    if (c.sqlite.sqlite3_prepare_v2(db.?, sql, -1, &stmt, null) != c.sqlite.SQLITE_OK) return;
    defer _ = c.sqlite.sqlite3_finalize(stmt);

    _ = c.sqlite.sqlite3_bind_int64(stmt, 1, item_id);
    _ = c.sqlite.sqlite3_step(stmt);
    loadFromDb();
}

pub fn markPlayed(item_id: i64) void {
    data_lock.lock();
    defer data_lock.unlock();
    if (db == null) return;

    const sql = "UPDATE queue SET played = 1 WHERE id = ?1;";
    var stmt: ?*c.sqlite.sqlite3_stmt = null;
    if (c.sqlite.sqlite3_prepare_v2(db.?, sql, -1, &stmt, null) != c.sqlite.SQLITE_OK) return;
    defer _ = c.sqlite.sqlite3_finalize(stmt);

    _ = c.sqlite.sqlite3_bind_int64(stmt, 1, item_id);
    _ = c.sqlite.sqlite3_step(stmt);
    loadFromDb();
}

pub fn clearPlayed() void {
    data_lock.lock();
    defer data_lock.unlock();
    if (db == null) return;
    _ = c.sqlite.sqlite3_exec(db.?, "DELETE FROM queue WHERE played = 1;", null, null, null);
    loadFromDb();
}

pub fn clearAll() void {
    data_lock.lock();
    defer data_lock.unlock();
    if (db == null) return;
    _ = c.sqlite.sqlite3_exec(db.?, "DELETE FROM queue;", null, null, null);
    loadFromDb();
}

fn shuffleOrderSlice() ?[]const u32 {
    if (!state.app.playlist_shuffle or queue_count == 0) return null;
    const seed = if (state.app.playlist_shuffle_seed != 0) state.app.playlist_shuffle_seed else 1;
    if (shuffle_order_len != queue_count or shuffle_order_seed != seed) {
        shuffle_order_len = queue_count;
        shuffle_order_seed = seed;
        playlist_pure.buildShuffleOrder(shuffle_order[0..queue_count], seed);
    }
    return shuffle_order[0..queue_count];
}

/// Shared native/remote/auto-advance decision. Stable row identity survives
/// reorder; repeat and shuffle use the same persisted policy as M3U playback.
pub fn playRelative(player: anytype, dir: i32) bool {
    if (!isReady() or queue_count == 0) return false;
    var ids: [MAX_QUEUE]i64 = undefined;
    var played: [MAX_QUEUE]bool = undefined;
    for (queue_items[0..queue_count], 0..) |*item, i| {
        ids[i] = item.id;
        played[i] = item.played;
    }
    const current_id = if (player.playback_origin == .queue) player.queue_item_id else -1;
    const target = playback.relativeIndex(
        ids[0..queue_count],
        played[0..queue_count],
        current_id,
        dir,
        state.app.playlist_repeat,
        shuffleOrderSlice(),
    ) orelse return false;
    playQueueItemOn(player, &queue_items[target]);
    return true;
}

pub fn playNextUnplayed(player: anytype) void {
    if (playRelative(player, 1)) state.showToast("Playing next from queue");
}

// ══════════════════════════════════════════════════════════
// UI Rendering (called from drawer.zig)
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    if (!isReady()) {
        _ = dvui.label(@src(), "Loading queue…", .{}, .{
            .color_text = theme.colors.text_secondary,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
        });
        return;
    }

    // Auto-trigger thumb backfill on first render
    if (!thumb_backfill_done.load(.acquire) and !thumb_backfill_active.load(.acquire) and queue_count > 0) {
        thumb_backfill_done.store(true, .release);
        // Check if any items need thumbs
        for (queue_items[0..queue_count]) |*item| {
            if (item.thumb_url_len == 0 and item.url_len > 0) {
                startThumbBackfill();
                break;
            }
        }
    }

    var content = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = dvui.Rect.all(8) });
    defer content.deinit();

    // ── Header row ──
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .x = 0, .y = 0, .w = 0, .h = 10 } });
        defer hdr.deinit();

        dvui.icon(@src(), "", icons.tvg.lucide.@"list-music", .{}, .{
            .color_text = theme.colors.accent,
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
        });
        // Capped for the same reason as the row titles: this label sits before
        // three text buttons in a horizontal box, and dvui starves later
        // siblings rather than shrinking earlier ones.
        _ = dvui.label(@src(), "Play Queue", .{}, .{
            .color_text = theme.colors.text_primary,
            .gravity_y = 0.5,
            .font = dvui.themeGet().font_heading,
            .max_size_content = .{ .w = 140, .h = std.math.floatMax(f32) },
        });

        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }

        if (dvui.button(@src(), if (thumb_backfill_active.load(.acquire)) "Stop Fetch" else "Fetch Thumbs", .{}, .{
            .color_fill = if (thumb_backfill_active.load(.acquire)) dvui.Color{ .r = 80, .g = 30, .b = 30, .a = 200 } else theme.colors.accent,
            .color_text = if (thumb_backfill_active.load(.acquire)) theme.colors.danger else dvui.Color.white,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
            .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
        })) {
            if (thumb_backfill_active.load(.acquire)) {
                thumb_backfill_cancel.store(true, .release);
            } else {
                startThumbBackfill();
            }
        }

        if (dvui.button(@src(), "Clear All", .{}, .{
            .color_fill = dvui.Color{ .r = 80, .g = 30, .b = 30, .a = 200 },
            .color_text = theme.colors.danger,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
            .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
        })) {
            clearAll();
        }

        if (dvui.button(@src(), "Clear Played", .{}, .{
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_secondary,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
        })) {
            clearPlayed();
        }
    }

    // One shared play-order policy for Queue and imported playlists. Compact
    // text controls stay understandable without icon/tooltip discovery.
    {
        const transparent = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
        var playback_bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
        });
        defer playback_bar.deinit();

        if (dvui.button(@src(), if (state.app.playlist_shuffle) "Shuffle: on" else "Shuffle: off", .{}, .{
            .color_fill = transparent,
            .color_text = if (state.app.playlist_shuffle) theme.colors.accent else theme.colors.text_secondary,
        })) _ = apply(.@"toggle-shuffle", null);

        const repeat_label: []const u8 = switch (state.app.playlist_repeat) {
            .off => "Repeat: off",
            .all => "Repeat: all",
            .one => "Repeat: one",
        };
        if (dvui.button(@src(), repeat_label, .{}, .{
            .color_fill = transparent,
            .color_text = if (state.app.playlist_repeat == .off) theme.colors.text_secondary else theme.colors.accent,
        })) _ = apply(.@"cycle-repeat", null);

        if (dvui.button(@src(), "Previous", .{}, .{ .color_fill = transparent, .color_text = theme.colors.text_secondary }))
            _ = apply(.previous, null);
        if (dvui.button(@src(), "Next", .{}, .{ .color_fill = transparent, .color_text = theme.colors.text_secondary }))
            _ = apply(.next, null);
    }

    // ── Now Playing from mpv ──
    renderNowPlaying();

    // ── Separator ──
    {
        var sep = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.border_subtle,
            .min_size_content = .{ .w = 0, .h = 1 },
            .max_size_content = .{ .w = 0, .h = 1 },
            .margin = .{ .x = 0, .y = 8, .w = 0, .h = 8 },
        });
        sep.deinit();
    }

    // ── Persisted Queue Items ──
    if (queue_count == 0) {
        _ = dvui.label(@src(), "Queue is empty. Add tracks from Tunes or paste a link.", .{}, .{
            .color_text = theme.colors.text_secondary,
            .gravity_x = 0.5,
            .margin = dvui.Rect.all(24),
        });
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_surface });
    defer scroll.deinit();

    for (queue_items[0..queue_count], 0..) |*item, idx| {
        renderQueueCard(item, idx);
    }
}

fn renderNowPlaying() void {
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const ap = state.app.players.items[state.app.active_player_idx];

    // Get media-title from mpv
    var title_ptr: [*c]u8 = null;
    _ = c.mpv.mpv_get_property(ap.mpv_ctx, "media-title", c.mpv.MPV_FORMAT_STRING, @ptrCast(&title_ptr));

    const title: []const u8 = if (title_ptr) |ptr| std.mem.span(ptr) else if (ap.source_url_len > 0) ap.source_url[0..ap.source_url_len] else "Nothing playing";
    defer if (title_ptr != null) c.mpv.mpv_free(title_ptr);

    var np = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = dvui.Color{ .r = 0, .g = 200, .b = 200, .a = 15 },
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
    });
    defer np.deinit();

    dvui.icon(@src(), "", icons.tvg.lucide.@"disc-3", .{}, .{
        .color_text = theme.colors.accent,
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 10, .h = 0 },
    });

    {
        var info = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
        defer info.deinit();

        _ = dvui.label(@src(), "NOW PLAYING", .{}, .{
            .color_text = theme.colors.accent,
        });
        _ = dvui.labelNoFmt(@src(), title, .{}, .{
            .color_text = theme.colors.text_primary,
            .expand = .horizontal,
        });
    }
}

/// The row's own horizontal padding (6 left + 6 right) plus the gap trailing the
/// thumbnail/glyph column, so the width budget accounts for chrome the text
/// column never gets to use.
const CARD_CHROME_W: f32 = 6 + 6 + 4;
/// Thumbnail column: the 80px poster plus its 6px right margin.
const CARD_THUMB_W: f32 = 80 + 6;
/// Fallback source glyph: one icon at the body font plus its 10px right margin.
const CARD_GLYPH_W: f32 = 10 + 10;
/// Move-up, move-down, play, remove.
const CARD_ACTION_COUNT: usize = 4;

fn renderQueueCard(item: *QueueItem, idx: usize) void {
    const title = if (item.title_len > 0) item.title[0..item.title_len] else item.url[0..item.url_len];
    const source = item.source[0..item.source_len];

    // Row width budget. Read the PARENT's content rect before opening the card
    // box — the card itself has no definite width until it has been laid out,
    // whereas the enclosing scroll area does (dvui returns 0 on the very first
    // frame, which titleCapW handles with its fallback).
    const row_w = dvui.parentGet().data().contentRect().w;
    const acts_w = layout.actionsW(dvui.themeGet().font_body.textHeight(), CARD_ACTION_COUNT);
    const leading_w: f32 = if (item.thumb_url_len > 0) CARD_THUMB_W else CARD_GLYPH_W;

    var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = idx,
        .expand = .horizontal,
        .background = true,
        .color_fill = if (item.played) dvui.Color{ .r = 20, .g = 22, .b = 28, .a = 120 } else theme.colors.bg_surface,
        .color_border = theme.colors.border_subtle,
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
    });
    defer card.deinit();

    // ── Thumbnail ──
    if (item.thumb_url_len > 0) {
        var poster = dvui.box(@src(), .{}, .{
            .id_extra = idx + 500,
            .background = true,
            .color_fill = theme.colors.bg_app,
            .corner_radius = dvui.Rect.all(4),
            .min_size_content = .{ .w = 80, .h = 45 },
            .max_size_content = .{ .w = 80, .h = 45 },
            .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
            .gravity_y = 0.5,
        });
        defer poster.deinit();

        // Create GPU texture from decoded pixels (must be on main thread)
        if (item.thumb_tex == null and item.thumb_pixels != null) {
            const num_pixels = item.thumb_w * item.thumb_h;
            const pixels_pma: []dvui.Color.PMA = @as([*]dvui.Color.PMA, @ptrCast(@alignCast(item.thumb_pixels.?.ptr)))[0..num_pixels];
            item.thumb_tex = dvui.textureCreate(pixels_pma, item.thumb_w, item.thumb_h, .linear, .rgba_32) catch null;
            if (item.thumb_tex != null) {
                alloc.free(item.thumb_pixels.?);
                item.thumb_pixels = null;
            }
        }

        if (item.thumb_tex) |*tex| {
            _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
                .id_extra = idx + 510,
                .expand = .both,
                .corner_radius = dvui.Rect.all(4),
            });
        } else {
            // Trigger background fetch (skip items already fetching or that
            // have terminally failed, so we don't respawn threads each frame)
            if (!item.thumb_fetching and !item.thumb_failed and item.thumb_url_len > 0) fetchQueueThumb(item);
            dvui.icon(@src(), "", icons.tvg.lucide.image, .{}, .{
                .id_extra = idx + 510,
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .color_text = theme.colors.bg_elevated,
            });
        }
    } else {
        // Source icon when no thumbnail
        const src_icon = if (std.mem.eql(u8, source, "youtube"))
            icons.tvg.lucide.music
        else if (std.mem.eql(u8, source, "magnet"))
            icons.tvg.lucide.magnet
        else
            icons.tvg.lucide.link;

        dvui.icon(@src(), "", src_icon, .{}, .{
            .id_extra = idx + 600,
            .color_text = if (item.played) theme.colors.text_secondary else theme.colors.accent,
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = 10, .h = 0 },
        });
    }

    // Title + meta.
    //
    // These labels MUST carry a width cap. dvui's horizontal box does not
    // squeeze children: it hands each one its full min size and subtracts from
    // the remaining budget (BoxWidget.rectFor), so a later sibling gets a
    // zero-width rect once the budget runs out. An uncapped label reports the
    // entire rendered text width as its min, which let a long title consume the
    // whole row and left the action strip below invisible — the bug this fixes.
    //
    // max_size_content clamps the REPORTED min size (WidgetData) and LabelWidget
    // ellipsizes to it, so the cap both contains the text and guarantees the
    // buttons keep their space. This replaces a fixed 35/55 BYTE truncation,
    // which measured the wrong thing (bytes, not pixels — so it neither
    // contained wide text nor scaled with the font) and could slice a multi-byte
    // UTF-8 codepoint in half, rendering a replacement glyph.
    {
        const title_w = layout.titleCapW(row_w, leading_w, acts_w, CARD_CHROME_W);
        var info = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = idx + 700,
            .expand = .horizontal,
            .max_size_content = .{ .w = title_w, .h = std.math.floatMax(f32) },
        });
        defer info.deinit();

        _ = dvui.labelNoFmt(@src(), title, .{}, .{
            .id_extra = idx + 710,
            .color_text = if (item.played) theme.colors.text_secondary else theme.colors.text_primary,
            .max_size_content = .{ .w = title_w, .h = std.math.floatMax(f32) },
        });

        _ = dvui.label(@src(), "{s}", .{source}, .{
            .id_extra = idx + 720,
            .color_text = theme.colors.border_subtle,
            .font = dvui.themeGet().font_body.withSize(theme.font_size.small),
            .max_size_content = .{ .w = title_w, .h = std.math.floatMax(f32) },
        });
    }

    // Action buttons. The reservation is derived from the live font height (see
    // queue_layout_pure.actionsW) rather than the old hardcoded 78px, which was
    // narrower than the four buttons actually need at the theme's own font size
    // and did not grow at all with UI scale.
    {
        var acts = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = idx + 800,
            .gravity_y = 0.5,
            .min_size_content = .{ .w = acts_w, .h = 0 },
        });
        defer acts.deinit();

        // Move up
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"chevron-up", .{}, .{}, .{
            .id_extra = idx + 805,
            .color_text = theme.colors.text_secondary,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        })) {
            if (idx > 0) swapQueueItems(idx - 1, idx);
        }

        // Move down
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"chevron-down", .{}, .{}, .{
            .id_extra = idx + 808,
            .color_text = theme.colors.text_secondary,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        })) {
            if (idx + 1 < queue_count) swapQueueItems(idx, idx + 1);
        }

        // Play button
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.play, .{}, .{}, .{
            .id_extra = idx + 810,
            .color_text = theme.colors.accent,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        })) {
            playQueueItem(item);
        }

        // Remove button
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"trash-2", .{}, .{}, .{
            .id_extra = idx + 820,
            .color_text = theme.colors.danger,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        })) {
            removeFromQueue(item.id);
        }
    }
}

fn playQueueItem(item: *QueueItem) void {
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const ap = state.app.players.items[state.app.active_player_idx];
    playQueueItemOn(ap, item);
}

fn playQueueItemOn(ap: anytype, item: *QueueItem) void {
    const extractors = @import("extractors.zig");

    const raw_url = item.url[0..item.url_len];
    var norm_buf: [2048]u8 = undefined;
    const norm_url = extractors.normalizeUrl(raw_url, &norm_buf);

    ap.load(.{ .url = norm_url, .origin = .queue, .queue_item_id = item.id });
    markPlayed(item.id);
    state.showToast("Playing from queue");
}

/// Non-UI adapters use indices from a freshly-read queue snapshot. Keep the
/// actual normalization, player handoff, played marker, and toast behind the
/// same implementation as the native Queue drawer.
pub fn playQueueIndex(idx: usize) bool {
    if (idx >= queue_count) return false;
    playQueueItem(&queue_items[idx]);
    return true;
}

pub fn removeQueueIndex(idx: usize) bool {
    if (idx >= queue_count) return false;
    removeFromQueue(queue_items[idx].id);
    return true;
}

/// Typed non-UI entry point. The caller owns player lifetime because only the
/// `play` case touches it; queue persistence remains centralized here.
pub fn apply(action: Action, idx: ?usize) bool {
    switch (action) {
        .@"clear-played" => clearPlayed(),
        .clear => clearAll(),
        .@"move-up" => moveQueueItem(idx orelse return false, -1),
        .@"move-down" => moveQueueItem(idx orelse return false, 1),
        .remove => return removeQueueIndex(idx orelse return false),
        .play => return playQueueIndex(idx orelse return false),
        .previous, .next => {
            if (state.app.active_player_idx >= state.app.players.items.len) return false;
            return playRelative(
                state.app.players.items[state.app.active_player_idx],
                if (action == .next) 1 else -1,
            );
        },
        .@"toggle-shuffle" => {
            state.app.playlist_shuffle = !state.app.playlist_shuffle;
            if (state.app.playlist_shuffle)
                state.app.playlist_shuffle_seed = @intCast(@max(1, @import("../core/io_global.zig").milliTimestamp()));
            shuffle_order_len = 0;
            state.markConfigDirty();
        },
        .@"cycle-repeat" => {
            state.app.playlist_repeat = state.app.playlist_repeat.cycled();
            state.markConfigDirty();
        },
    }
    return true;
}

/// Run a single UPDATE inside an already-open transaction. Returns true on
/// success (prepared + stepped to SQLITE_DONE).
fn swapStep(position: i64, id: i64) bool {
    var stmt: ?*c.sqlite.sqlite3_stmt = null;
    if (c.sqlite.sqlite3_prepare_v2(db.?, "UPDATE queue SET position = ?1 WHERE id = ?2;", -1, &stmt, null) != c.sqlite.SQLITE_OK) return false;
    defer _ = c.sqlite.sqlite3_finalize(stmt);
    _ = c.sqlite.sqlite3_bind_int64(stmt, 1, position);
    _ = c.sqlite.sqlite3_bind_int64(stmt, 2, id);
    return c.sqlite.sqlite3_step(stmt) == c.sqlite.SQLITE_DONE;
}

/// Copy a coherent snapshot for non-UI adapters without exposing mutable queue
/// storage across threads. The caller owns `out` and may serialize it unlocked.
pub fn snapshotItems(out: []QueueItem) usize {
    data_lock.lock();
    defer data_lock.unlock();
    const count = @min(queue_count, out.len);
    @memcpy(out[0..count], queue_items[0..count]);
    return count;
}

/// Stage a remote action by stable row identity. Indices are presentation
/// coordinates and may change before the UI thread applies the request.
pub fn requestAction(action: Action, idx: ?usize) ?u64 {
    var item_id: ?i64 = null;
    const needs_item = switch (action) {
        .play, .remove, .@"move-up", .@"move-down" => true,
        else => false,
    };
    if (needs_item) {
        data_lock.lock();
        defer data_lock.unlock();
        const i = idx orelse return null;
        if (i >= queue_count) return null;
        item_id = queue_items[i].id;
    }

    action_lock.lock();
    defer action_lock.unlock();
    if (pending_action_count >= ACTION_CAP) return null;
    const request_id = next_action_id;
    next_action_id +%= 1;
    if (next_action_id == 0) next_action_id = 1;
    const tail = (pending_action_head + pending_action_count) % ACTION_CAP;
    pending_actions[tail] = .{ .action = action, .item_id = item_id, .request_id = request_id };
    pending_action_count += 1;
    state.wakeUi();
    return request_id;
}

/// Remote connection workers wait briefly for the UI-thread receipt so their
/// immediate follow-up snapshot cannot race the mutation they just requested.
pub fn waitAction(request_id: u64, timeout_ms: i64) bool {
    const io = @import("../core/io_global.zig");
    const deadline = io.monotonicMilliTimestamp() + @max(timeout_ms, 1);
    while (completed_action_id.load(.acquire) < request_id) {
        if (io.monotonicMilliTimestamp() >= deadline) return false;
        io.sleep(2 * std.time.ns_per_ms);
    }
    return true;
}

fn indexById(id: i64) ?usize {
    for (queue_items[0..queue_count], 0..) |*item, i| {
        if (item.id == id) return i;
    }
    return null;
}

fn drainPendingActions() void {
    while (true) {
        action_lock.lock();
        if (pending_action_count == 0) {
            action_lock.unlock();
            return;
        }
        const request = pending_actions[pending_action_head];
        pending_action_head = (pending_action_head + 1) % ACTION_CAP;
        pending_action_count -= 1;
        action_lock.unlock();

        if (request.action == .clear or request.action == .@"clear-played" or
            request.action == .previous or request.action == .next or
            request.action == .@"toggle-shuffle" or request.action == .@"cycle-repeat")
        {
            _ = apply(request.action, null);
            completed_action_id.store(request.request_id, .release);
            continue;
        }
        if (request.item_id) |id| {
            if (indexById(id)) |idx| _ = apply(request.action, idx);
        }
        completed_action_id.store(request.request_id, .release);
    }
}

/// Move the item at `idx` up (dir < 0) or down (dir > 0) one slot; persists
/// the new order. No-op at the ends. Exposed for the web remote's reorder.
pub fn moveQueueItem(idx: usize, dir: i32) void {
    if (idx >= queue_count) return;
    if (dir < 0 and idx > 0) swapQueueItems(idx, idx - 1);
    if (dir > 0 and idx + 1 < queue_count) swapQueueItems(idx, idx + 1);
}

fn swapQueueItems(idx_a: usize, idx_b: usize) void {
    data_lock.lock();
    defer data_lock.unlock();
    if (idx_a >= queue_count or idx_b >= queue_count) return;
    if (idx_a == idx_b) return;

    // Row IDs are stable item identity; only explicit position changes. The old
    // implementation swapped primary keys, making identity refer to different
    // content after a reorder.
    const id_a = queue_items[idx_a].id;
    const id_b = queue_items[idx_b].id;
    const pos_a = queue_items[idx_a].position;
    const pos_b = queue_items[idx_b].position;

    // If there is no DB, just swap in memory (nothing to persist atomically).
    if (db == null) {
        const tmp = queue_items[idx_a];
        queue_items[idx_a] = queue_items[idx_b];
        queue_items[idx_b] = tmp;
        queue_items[idx_a].position = pos_a;
        queue_items[idx_b].position = pos_b;
        return;
    }

    // Both position updates are transactional, so order cannot half-swap.
    if (c.sqlite.sqlite3_exec(db.?, "BEGIN;", null, null, null) != c.sqlite.SQLITE_OK) return;

    const ok = swapStep(pos_b, id_a) and swapStep(pos_a, id_b);

    if (!ok) {
        _ = c.sqlite.sqlite3_exec(db.?, "ROLLBACK;", null, null, null);
        return;
    }
    if (c.sqlite.sqlite3_exec(db.?, "COMMIT;", null, null, null) != c.sqlite.SQLITE_OK) {
        _ = c.sqlite.sqlite3_exec(db.?, "ROLLBACK;", null, null, null);
        return;
    }

    // Commit succeeded — mirror order while preserving stable row IDs.
    const tmp = queue_items[idx_a];
    queue_items[idx_a] = queue_items[idx_b];
    queue_items[idx_b] = tmp;
    queue_items[idx_a].position = pos_a;
    queue_items[idx_b].position = pos_b;
}

/// Queue thumbnail cache. Was "/tmp/opal_thumbs/queue" — absent on Windows, so
/// queue thumbnails were silently dead there (issue #21). Resolved lazily
/// because paths.cacheFile needs a buffer.
fn thumbCacheDir(buf: []u8) []const u8 {
    return @import("../core/paths.zig").cacheFile(buf, "thumbs/queue");
}

fn thumbCachePath(item_id: i64, out: *[384]u8) ?[]const u8 {
    var dir_buf: [512]u8 = undefined;
    return std.fmt.bufPrintZ(out, "{s}/{d}.jpg", .{ thumbCacheDir(&dir_buf), item_id }) catch null;
}

// Cap concurrent thumbnail-fetch threads so a full queue can't spawn 200
// network threads at once. Reserved/released around each worker.
const MAX_THUMB_THREADS: i64 = 4;
var thumb_threads_active: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);

const ThumbJob = struct {
    item_id: i64,
    url: [512]u8,
    url_len: usize,
};

const ThumbResult = struct {
    item_id: i64,
    pixels: ?[]u8 = null,
    width: u32 = 0,
    height: u32 = 0,
    failed: bool = true,
};

const THUMB_RESULT_CAP: usize = 16;
var thumb_results: [THUMB_RESULT_CAP]ThumbResult = undefined;
var thumb_result_count: usize = 0;
var thumb_result_lock = @import("../core/sync.zig").Mutex{};

fn publishThumbResult(result: ThumbResult) void {
    thumb_result_lock.lock();
    defer thumb_result_lock.unlock();
    if (thumb_result_count >= THUMB_RESULT_CAP) {
        if (result.pixels) |pixels| alloc.free(pixels);
        return;
    }
    thumb_results[thumb_result_count] = result;
    thumb_result_count += 1;
    state.wakeUi();
}

fn drainThumbResults() void {
    thumb_result_lock.lock();
    defer thumb_result_lock.unlock();
    for (thumb_results[0..thumb_result_count]) |result| {
        var consumed = false;
        for (queue_items[0..queue_count]) |*item| {
            if (item.id != result.item_id) continue;
            if (item.thumb_pixels) |old| alloc.free(old);
            item.thumb_pixels = result.pixels;
            item.thumb_w = result.width;
            item.thumb_h = result.height;
            item.thumb_fetching = false;
            item.thumb_failed = result.failed;
            consumed = true;
            break;
        }
        if (!consumed) if (result.pixels) |pixels| alloc.free(pixels);
    }
    thumb_result_count = 0;
}

fn decodeThumb(item_id: i64, body: []const u8) ?ThumbResult {
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    const pixels = dvui.c.stbi_load_from_memory(body.ptr, @intCast(body.len), &w, &h, &comp, 4);
    if (pixels == null) return null;
    defer dvui.c.stbi_image_free(pixels);
    if (w <= 0 or h <= 0) return null;

    const pixel_count = std.math.mul(usize, @intCast(w), @intCast(h)) catch return null;
    if (pixel_count > 16 * 1024 * 1024) return null;
    const p_len = std.math.mul(usize, pixel_count, 4) catch return null;
    const owned = alloc.alloc(u8, p_len) catch return null;
    @memcpy(owned, pixels[0..p_len]);
    return .{
        .item_id = item_id,
        .pixels = owned,
        .width = @intCast(w),
        .height = @intCast(h),
        .failed = false,
    };
}

fn thumbWorker(job: ThumbJob) void {
    defer _ = thumb_threads_active.fetchSub(1, .acq_rel);
    var published = false;
    defer if (!published) publishThumbResult(.{ .item_id = job.item_id });

    const id = job.item_id;
    const url = job.url[0..job.url_len];
    var path_buf: [384]u8 = undefined;
    const cached_body = blk: {
        const cache_path = thumbCachePath(id, &path_buf) orelse break :blk null;
        const file = @import("../core/io_global.zig").cwdOpenFile(cache_path, .{}) catch break :blk null;
        defer file.close(@import("../core/io_global.zig").io());
        const stat = file.stat(@import("../core/io_global.zig").io()) catch break :blk null;
        if (stat.size <= 100 or stat.size >= 2 * 1024 * 1024) break :blk null;
        const cached = alloc.alloc(u8, stat.size) catch break :blk null;
        const n = @import("../core/io_global.zig").readAll(file, cached) catch {
            alloc.free(cached);
            break :blk null;
        };
        if (n <= 100) {
            alloc.free(cached);
            break :blk null;
        }
        break :blk cached[0..n];
    };

    if (cached_body) |body| {
        defer alloc.free(body);
        if (decodeThumb(id, body)) |result| {
            publishThumbResult(result);
            published = true;
        }
        return;
    }

    var client = @import("../core/http.zig").newClient();
    defer client.deinit();
    const uri = std.Uri.parse(url) catch return;
    var req = client.request(.GET, uri, .{ .extra_headers = &.{.{ .name = "Accept", .value = "image/jpeg, image/webp" }} }) catch return;
    defer req.deinit();
    req.sendBodiless() catch return;
    var redirect_buf: [8192]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return;
    if (response.head.status != .ok) return;
    var transfer_buf: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var rdr = response.readerDecompressing(&transfer_buf, &decompress, &.{});
    const body = rdr.allocRemaining(alloc, std.Io.Limit.limited(2 * 1024 * 1024)) catch return;
    defer alloc.free(body);
    if (body.len < 100) return;

    var tdir_buf: [512]u8 = undefined;
    @import("../core/io_global.zig").cwdMakePath(thumbCacheDir(&tdir_buf)) catch {};
    if (thumbCachePath(id, &path_buf)) |cache_path| {
        if (@import("../core/io_global.zig").cwdCreateFile(cache_path, .{})) |cf| {
            _ = @import("../core/io_global.zig").writeAll(cf, body) catch {};
            cf.close(@import("../core/io_global.zig").io());
        } else |_| {}
    }
    if (decodeThumb(id, body)) |result| {
        publishThumbResult(result);
        published = true;
    }
}

fn fetchQueueThumb(item: *QueueItem) void {
    if (item.thumb_url_len == 0 or item.thumb_fetching or item.thumb_failed) return;

    // Reserve a thread slot; if we're at the cap, leave the item untouched so
    // a later frame retries once a slot frees (it is NOT marked failed).
    const prev = thumb_threads_active.fetchAdd(1, .acq_rel);
    if (prev >= MAX_THUMB_THREADS) {
        _ = thumb_threads_active.fetchSub(1, .acq_rel);
        return;
    }

    item.thumb_fetching = true;
    var job: ThumbJob = .{ .item_id = item.id, .url = undefined, .url_len = item.thumb_url_len };
    const url = item.thumb_url[0..item.thumb_url_len];
    @memcpy(job.url[0..url.len], url);
    @import("../core/workers.zig").spawn(thumbWorker, .{job}) catch {
        item.thumb_fetching = false;
        _ = thumb_threads_active.fetchSub(1, .acq_rel);
    };
}

// ══════════════════════════════════════════════════════════
// Thumbnail Backfill (for items added before thumb support)
// ══════════════════════════════════════════════════════════

var thumb_backfill_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var thumb_backfill_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var thumb_backfill_cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var backfill_refresh_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn startThumbBackfill() void {
    if (thumb_backfill_active.load(.acquire)) return;
    thumb_backfill_active.store(true, .release);
    thumb_backfill_cancel.store(false, .release);
    state.showToast("Fetching thumbnails...");

    if (@import("../core/workers.zig").spawnLegacy(struct {
        fn worker() void {
            defer {
                thumb_backfill_active.store(false, .release);
                backfill_refresh_pending.store(true, .release);
                state.wakeUi();
                state.showToast("Thumbnail fetch complete");
            }

            // Collect items needing thumbnails
            var ids: [MAX_QUEUE]i64 = undefined;
            var urls: [MAX_QUEUE][2048]u8 = undefined;
            var url_lens: [MAX_QUEUE]usize = undefined;
            var need_count: usize = 0;

            data_lock.lock();
            for (queue_items[0..queue_count]) |*item| {
                if (item.thumb_url_len == 0 and item.url_len > 0) {
                    ids[need_count] = item.id;
                    @memcpy(urls[need_count][0..item.url_len], item.url[0..item.url_len]);
                    url_lens[need_count] = item.url_len;
                    need_count += 1;
                    if (need_count >= MAX_QUEUE) break;
                }
            }
            data_lock.unlock();

            if (need_count == 0) return;

            for (0..need_count) |i| {
                if (thumb_backfill_cancel.load(.acquire)) {
                    state.showToast("Thumbnail fetch cancelled");
                    return;
                }
                const url = urls[i][0..url_lens[i]];

                // yt-dlp --get-thumbnail <url> (bundled/system binary — bare
                // "yt-dlp" isn't on the GUI process PATH).
                const argv_policy = @import("ytdlp_argv_pure.zig");
                var argv_storage: argv_policy.Argv = undefined;
                const argv = argv_policy.build(@import("ytdlp.zig").binary(), url, .thumbnail, "", &argv_storage);

                var child = @import("../core/io_global.zig").Child.init(argv, alloc);
                child.stdout_behavior = .Pipe;
                child.stderr_behavior = .Ignore;
                child.spawn() catch continue;

                var out_buf: [1024]u8 = undefined;
                const n = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, &out_buf) catch 0 else 0;
                _ = child.wait() catch {};

                if (n > 10) {
                    // Trim trailing newline
                    var thumb_len = n;
                    while (thumb_len > 0 and (out_buf[thumb_len - 1] == '\n' or out_buf[thumb_len - 1] == '\r')) thumb_len -= 1;
                    if (thumb_len > 0) {
                        updateThumbUrl(ids[i], out_buf[0..thumb_len]);
                    }
                }

                // Small delay to avoid rate limiting
                @import("../core/io_global.zig").sleep(500_000_000); // 500ms
            }
        }
    }.worker, .{})) |t| {
        @import("../core/workers.zig").release(t);
    } else |_| {
        thumb_backfill_active.store(false, .release);
    }
}

fn updateThumbUrl(item_id: i64, thumb_url: []const u8) void {
    if (db == null) return;

    const sql = "UPDATE queue SET thumb_url = ?1 WHERE id = ?2;";
    var stmt: ?*c.sqlite.sqlite3_stmt = null;
    if (c.sqlite.sqlite3_prepare_v2(db.?, sql, -1, &stmt, null) != c.sqlite.SQLITE_OK) return;
    defer _ = c.sqlite.sqlite3_finalize(stmt);

    _ = c.sqlite.sqlite3_bind_text(stmt, 1, thumb_url.ptr, @intCast(thumb_url.len), getTransient());
    _ = c.sqlite.sqlite3_bind_int64(stmt, 2, item_id);
    _ = c.sqlite.sqlite3_step(stmt);
}
