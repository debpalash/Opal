const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const c = @import("../core/c.zig");

const alloc = @import("../core/alloc.zig").allocator;

// ══════════════════════════════════════════════════════════
// Queue Item (mirrors mpv playlist + persisted metadata)
// ══════════════════════════════════════════════════════════

pub const QueueItem = struct {
    id: i64 = 0,  // SQLite rowid
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

const MAX_QUEUE: usize = 200;
pub var queue_items: [MAX_QUEUE]QueueItem = undefined;
pub var queue_count: usize = 0;
var db: ?*c.sqlite.sqlite3 = null;
var db_initialized: bool = false;

// ══════════════════════════════════════════════════════════
// SQLite Database Management
// ══════════════════════════════════════════════════════════

pub fn initDb() void {
    if (db_initialized) return;

    const home = @import("../core/io_global.zig").getenv("HOME") orelse return;
    var path_buf: [256]u8 = undefined;
    const db_path = std.fmt.bufPrintZ(&path_buf, "{s}/.config/opal/queue.db", .{home}) catch return;
    
    // Ensure directory exists
    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "{s}/.config/opal", .{home}) catch return;
    _ = @import("../core/io_global.zig").makeDirAbsolute(dir_path) catch {};
    
    if (c.sqlite.sqlite3_open(db_path.ptr, &db) != c.sqlite.SQLITE_OK) {
        db = null;
        return;
    }
    db_initialized = true;

    // Create table
    const sql = "CREATE TABLE IF NOT EXISTS queue (" ++
        "id INTEGER PRIMARY KEY AUTOINCREMENT," ++
        "url TEXT NOT NULL," ++
        "title TEXT DEFAULT ''," ++
        "source TEXT DEFAULT 'direct'," ++
        "thumb_url TEXT DEFAULT ''," ++
        "duration INTEGER DEFAULT 0," ++
        "added_at INTEGER DEFAULT 0," ++
        "played INTEGER DEFAULT 0" ++
        ");";
    _ = c.sqlite.sqlite3_exec(db.?, sql, null, null, null);
    
    // Migration: add thumb_url column if missing
    const migrate_sql = "ALTER TABLE queue ADD COLUMN thumb_url TEXT DEFAULT '';";
    _ = c.sqlite.sqlite3_exec(db.?, migrate_sql, null, null, null);
    // (table creation moved above)
    
    loadFromDb();
}

fn loadFromDb() void {
    if (db == null) return;
    queue_count = 0;

    const sql = "SELECT id, url, title, source, duration, added_at, played, thumb_url FROM queue ORDER BY id DESC LIMIT 200;";
    var stmt: ?*c.sqlite.sqlite3_stmt = null;
    if (c.sqlite.sqlite3_prepare_v2(db.?, sql, -1, &stmt, null) != c.sqlite.SQLITE_OK) return;
    defer _ = c.sqlite.sqlite3_finalize(stmt);

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
    initDb();
    if (db == null) return;

    const sql = "INSERT INTO queue (url, title, source, thumb_url, added_at) VALUES (?1, ?2, ?3, ?4, ?5);";
    var stmt: ?*c.sqlite.sqlite3_stmt = null;
    if (c.sqlite.sqlite3_prepare_v2(db.?, sql, -1, &stmt, null) != c.sqlite.SQLITE_OK) return;
    defer _ = c.sqlite.sqlite3_finalize(stmt);

    _ = c.sqlite.sqlite3_bind_text(stmt, 1, url.ptr, @intCast(url.len), getTransient());
    _ = c.sqlite.sqlite3_bind_text(stmt, 2, title.ptr, @intCast(title.len), getTransient());
    _ = c.sqlite.sqlite3_bind_text(stmt, 3, source.ptr, @intCast(source.len), getTransient());
    _ = c.sqlite.sqlite3_bind_text(stmt, 4, thumb_url.ptr, @intCast(thumb_url.len), getTransient());
    _ = c.sqlite.sqlite3_bind_int64(stmt, 5, @import("../core/io_global.zig").timestamp());

    _ = c.sqlite.sqlite3_step(stmt);
    loadFromDb();
}

pub fn removeFromQueue(item_id: i64) void {
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
    if (db == null) return;
    _ = c.sqlite.sqlite3_exec(db.?, "DELETE FROM queue WHERE played = 1;", null, null, null);
    loadFromDb();
}

pub fn clearAll() void {
    if (db == null) return;
    _ = c.sqlite.sqlite3_exec(db.?, "DELETE FROM queue;", null, null, null);
    loadFromDb();
}

/// Auto-advance: find next unplayed queue item and load into player.
pub fn playNextUnplayed(player: anytype) void {
    const extractors = @import("extractors.zig");
    initDb();
    for (queue_items[0..queue_count]) |*item| {
        if (!item.played and item.url_len > 0) {
            const raw_url = item.url[0..item.url_len];
            var norm_buf: [2048]u8 = undefined;
            const norm_url = extractors.normalizeUrl(raw_url, &norm_buf);
            var url_z: [2049]u8 = undefined;
            @memcpy(url_z[0..norm_url.len], norm_url);
            url_z[norm_url.len] = 0;
            player.load_file(@ptrCast(&url_z[0]));
            markPlayed(item.id);
            state.showToast("Playing next from queue");
            return;
        }
    }
}

// ══════════════════════════════════════════════════════════
// UI Rendering (called from drawer.zig)
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    initDb();

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
            .color_text = theme.colors.accent, .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
        });
        _ = dvui.label(@src(), "Play Queue", .{}, .{
            .color_text = theme.colors.text_primary, .gravity_y = 0.5,
        });

        { var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal }); sp.deinit(); }

        if (dvui.button(@src(), if (thumb_backfill_active.load(.acquire)) "Stop Fetch" else "Fetch Thumbs", .{}, .{
            .color_fill = if (thumb_backfill_active.load(.acquire)) dvui.Color{ .r = 80, .g = 30, .b = 30, .a = 200 } else theme.colors.accent,
            .color_text = if (thumb_backfill_active.load(.acquire)) theme.colors.danger else dvui.Color.white,
            .corner_radius = theme.dims.rad_sm, .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
            .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
        })) {
            if (thumb_backfill_active.load(.acquire)) {
                thumb_backfill_cancel.store(true, .release);
            } else {
                startThumbBackfill();
            }
        }

        if (dvui.button(@src(), "Clear All", .{}, .{
            .color_fill = dvui.Color{ .r = 80, .g = 30, .b = 30, .a = 200 }, .color_text = theme.colors.danger,
            .corner_radius = theme.dims.rad_sm, .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
            .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
        })) {
            clearAll();
        }

        if (dvui.button(@src(), "Clear Played", .{}, .{
            .color_fill = theme.colors.bg_elevated, .color_text = theme.colors.text_secondary,
            .corner_radius = theme.dims.rad_sm, .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
        })) {
            clearPlayed();
        }
    }

    // ── Now Playing from mpv ──
    renderNowPlaying();

    // ── Separator ──
    {
        var sep = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal, .background = true,
            .color_fill = theme.colors.border_subtle,
            .min_size_content = .{ .w = 0, .h = 1 }, .max_size_content = .{ .w = 0, .h = 1 },
            .margin = .{ .x = 0, .y = 8, .w = 0, .h = 8 },
        });
        sep.deinit();
    }

    // ── Persisted Queue Items ──
    if (queue_count == 0) {
        _ = dvui.label(@src(), "Queue is empty. Add tracks from Tunes or paste a link.", .{}, .{
            .color_text = theme.colors.text_secondary, .gravity_x = 0.5, .margin = dvui.Rect.all(24),
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
        .expand = .horizontal, .background = true,
        .color_fill = dvui.Color{ .r = 0, .g = 200, .b = 200, .a = 15 },
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
    });
    defer np.deinit();

    dvui.icon(@src(), "", icons.tvg.lucide.@"disc-3", .{}, .{
        .color_text = theme.colors.accent, .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 10, .h = 0 },
    });

    {
        var info = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
        defer info.deinit();

        _ = dvui.label(@src(), "NOW PLAYING", .{}, .{
            .color_text = theme.colors.accent,
        });
        _ = dvui.labelNoFmt(@src(), title, .{}, .{
            .color_text = theme.colors.text_primary, .expand = .horizontal,
        });
    }
}

fn renderQueueCard(item: *QueueItem, idx: usize) void {
    const title = if (item.title_len > 0) item.title[0..item.title_len] else item.url[0..item.url_len];
    const source = item.source[0..item.source_len];

    var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = idx, .expand = .horizontal, .background = true,
        .color_fill = if (item.played) dvui.Color{ .r = 20, .g = 22, .b = 28, .a = 120 } else theme.colors.bg_surface,
        .color_border = theme.colors.border_subtle,
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
    });
    defer card.deinit();

    // ── Thumbnail ──
    if (item.thumb_url_len > 0) {
        var poster = dvui.box(@src(), .{}, .{
            .id_extra = idx + 500, .background = true,
            .color_fill = theme.colors.bg_app,
            .corner_radius = dvui.Rect.all(4),
            .min_size_content = .{ .w = 80, .h = 45 }, .max_size_content = .{ .w = 80, .h = 45 },
            .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
            .gravity_y = 0.5,
        });
        defer poster.deinit();
        
        // Create GPU texture from decoded pixels (must be on main thread)
        if (item.thumb_tex == null and item.thumb_pixels != null) {
            const num_pixels = item.thumb_w * item.thumb_h;
            const pixels_pma: []dvui.Color.PMA = @as([*]dvui.Color.PMA, @ptrCast(@alignCast(item.thumb_pixels.?.ptr)))[0..num_pixels];
            item.thumb_tex = dvui.textureCreate(pixels_pma, item.thumb_w, item.thumb_h, .linear, .rgba_32) catch null;
            if (item.thumb_tex != null) { alloc.free(item.thumb_pixels.?); item.thumb_pixels = null; }
        }
        
        if (item.thumb_tex) |*tex| {
            _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
                .id_extra = idx + 510, .expand = .both, .corner_radius = dvui.Rect.all(4),
            });
        } else {
            // Trigger background fetch (skip items already fetching or that
            // have terminally failed, so we don't respawn threads each frame)
            if (!item.thumb_fetching and !item.thumb_failed and item.thumb_url_len > 0) fetchQueueThumb(item);
            dvui.icon(@src(), "", icons.tvg.lucide.@"image", .{}, .{
                .id_extra = idx + 510, .gravity_x = 0.5, .gravity_y = 0.5,
                .color_text = theme.colors.bg_elevated,
            });
        }
    } else {
        // Source icon when no thumbnail
        const src_icon = if (std.mem.eql(u8, source, "youtube"))
            icons.tvg.lucide.@"music"
        else if (std.mem.eql(u8, source, "magnet"))
            icons.tvg.lucide.@"magnet"
        else
            icons.tvg.lucide.@"link";

        dvui.icon(@src(), "", src_icon, .{}, .{
            .id_extra = idx + 600, .color_text = if (item.played) theme.colors.text_secondary else theme.colors.accent,
            .gravity_y = 0.5, .margin = .{ .x = 0, .y = 0, .w = 10, .h = 0 },
        });
    }

    // Title + meta (must not overflow — clip long titles)
    {
        var info = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = idx + 700, .expand = .horizontal,
        });
        defer info.deinit();

        // Truncate title — shorter when thumbnail takes space
        const max_title: usize = if (item.thumb_url_len > 0) 35 else 55;
        const display_title = title[0..@min(title.len, max_title)];
        _ = dvui.labelNoFmt(@src(), display_title, .{}, .{
            .id_extra = idx + 710,
            .color_text = if (item.played) theme.colors.text_secondary else theme.colors.text_primary,
        });

        _ = dvui.label(@src(), "{s}", .{source}, .{
            .id_extra = idx + 720, .color_text = theme.colors.border_subtle,
        });
    }

    // Action buttons (fixed width, never pushed off-screen)
    {
        var acts = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = idx + 800, .gravity_y = 0.5,
            .min_size_content = .{ .w = 78, .h = 0 },
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
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"play", .{}, .{}, .{
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
    const extractors = @import("extractors.zig");
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const ap = state.app.players.items[state.app.active_player_idx];

    const raw_url = item.url[0..item.url_len];
    var norm_buf: [2048]u8 = undefined;
    const norm_url = extractors.normalizeUrl(raw_url, &norm_buf);
    var url_z: [2049]u8 = undefined;
    @memcpy(url_z[0..norm_url.len], norm_url);
    url_z[norm_url.len] = 0;

    ap.load_file(@ptrCast(&url_z[0]));
    markPlayed(item.id);
    state.showToast("Playing from queue");
}

/// Run a single UPDATE inside an already-open transaction. Returns true on
/// success (prepared + stepped to SQLITE_DONE).
fn swapStep(sql: [*c]const u8, bind1: ?i64, bind2: ?i64) bool {
    var stmt: ?*c.sqlite.sqlite3_stmt = null;
    if (c.sqlite.sqlite3_prepare_v2(db.?, sql, -1, &stmt, null) != c.sqlite.SQLITE_OK) return false;
    defer _ = c.sqlite.sqlite3_finalize(stmt);
    if (bind1) |v| _ = c.sqlite.sqlite3_bind_int64(stmt, 1, v);
    if (bind2) |v| _ = c.sqlite.sqlite3_bind_int64(stmt, 2, v);
    return c.sqlite.sqlite3_step(stmt) == c.sqlite.SQLITE_DONE;
}

/// Move the item at `idx` up (dir < 0) or down (dir > 0) one slot; persists
/// the new order. No-op at the ends. Exposed for the web remote's reorder.
pub fn moveQueueItem(idx: usize, dir: i32) void {
    if (idx >= queue_count) return;
    if (dir < 0 and idx > 0) swapQueueItems(idx, idx - 1);
    if (dir > 0 and idx + 1 < queue_count) swapQueueItems(idx, idx + 1);
}

fn swapQueueItems(idx_a: usize, idx_b: usize) void {
    if (idx_a >= queue_count or idx_b >= queue_count) return;
    if (idx_a == idx_b) return;

    // Original row IDs, before any swap. We exchange the two row IDs in the DB
    // (using -1 as a temp to dodge the PK unique constraint) so display order
    // persists, then mirror the swap in memory only after a clean COMMIT.
    const id_a = queue_items[idx_a].id;
    const id_b = queue_items[idx_b].id;

    // If there is no DB, just swap in memory (nothing to persist atomically).
    if (db == null) {
        const tmp = queue_items[idx_a];
        queue_items[idx_a] = queue_items[idx_b];
        queue_items[idx_b] = tmp;
        queue_items[idx_a].id = id_b;
        queue_items[idx_b].id = id_a;
        return;
    }

    // All three UPDATEs run inside one transaction; roll back on any failure
    // so the persisted IDs never end up half-swapped.
    if (c.sqlite.sqlite3_exec(db.?, "BEGIN;", null, null, null) != c.sqlite.SQLITE_OK) return;

    const ok = swapStep("UPDATE queue SET id = -1 WHERE id = ?1;", id_a, null) and
        swapStep("UPDATE queue SET id = ?1 WHERE id = ?2;", id_a, id_b) and
        swapStep("UPDATE queue SET id = ?1 WHERE id = -1;", id_b, null);

    if (!ok) {
        _ = c.sqlite.sqlite3_exec(db.?, "ROLLBACK;", null, null, null);
        return;
    }
    if (c.sqlite.sqlite3_exec(db.?, "COMMIT;", null, null, null) != c.sqlite.SQLITE_OK) {
        _ = c.sqlite.sqlite3_exec(db.?, "ROLLBACK;", null, null, null);
        return;
    }

    // Commit succeeded — now mirror the swap in memory, fixing up the IDs that
    // were exchanged in the DB.
    const tmp = queue_items[idx_a];
    queue_items[idx_a] = queue_items[idx_b];
    queue_items[idx_b] = tmp;
    queue_items[idx_a].id = id_b;
    queue_items[idx_b].id = id_a;
}

const thumb_cache_dir = "/tmp/opal_thumbs/queue";

fn thumbCachePath(item_id: i64, out: *[384]u8) ?[]const u8 {
    return std.fmt.bufPrintZ(out, thumb_cache_dir ++ "/{d}.jpg", .{item_id}) catch null;
}

// Cap concurrent thumbnail-fetch threads so a full queue can't spawn 200
// network threads at once. Reserved/released around each worker.
const MAX_THUMB_THREADS: i64 = 4;
var thumb_threads_active: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);

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

    // Copy ID and URL into struct statics so the thread doesn't hold a pointer
    // into the mutable queue_items array (which can be rewritten by loadFromDb).
    const S = struct {
        var item_id: i64 = 0;
        var url_buf: [512]u8 = undefined;
        var url_len: usize = 0;

        fn findById(id: i64) ?*QueueItem {
            for (queue_items[0..queue_count]) |*qi| {
                if (qi.id == id) return qi;
            }
            return null;
        }

        fn worker() void {
            defer _ = thumb_threads_active.fetchSub(1, .acq_rel);

            const id = @This().item_id;
            const url = @This().url_buf[0..@This().url_len];

            // 1) Check disk cache first
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
                if (n <= 100) { alloc.free(cached); break :blk null; }
                break :blk cached[0..n];
            };

            if (cached_body) |body| {
                defer alloc.free(body);
                decodeAndStoreById(id, body);
                return;
            }

            // 2) Download from network
            var client = std.http.Client{ .allocator = alloc, .io = @import("../core/io_global.zig").io() };
            defer client.deinit();

            const uri = std.Uri.parse(url) catch return;
            var req = client.request(.GET, uri, .{ .extra_headers = &.{ .{ .name = "Accept", .value = "image/jpeg, image/webp" } } }) catch return;
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

            // 3) Save to disk cache
            @import("../core/io_global.zig").cwdMakePath(thumb_cache_dir) catch {};
            if (thumbCachePath(id, &path_buf)) |cache_path| {
                if (@import("../core/io_global.zig").cwdCreateFile(cache_path, .{})) |cf| {
                    _ = @import("../core/io_global.zig").writeAll(cf, body) catch {};
                    cf.close(@import("../core/io_global.zig").io());
                } else |_| {}
            }

            // 4) Decode and store pixels
            decodeAndStoreById(id, body);
        }

        fn decodeAndStoreById(id: i64, body: []const u8) void {
            var w: c_int = 0;
            var h: c_int = 0;
            var comp: c_int = 0;
            const pixels = dvui.c.stbi_load_from_memory(body.ptr, @intCast(body.len), &w, &h, &comp, 4);
            if (pixels == null) return;
            defer dvui.c.stbi_image_free(pixels);

            if (w <= 0 or h <= 0) return;
            // usize-first: w*h*4 in c_int overflows on a large crafted image and
            // panics this worker thread (whole-app abort).
            const p_len: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
            const p_slice = alloc.alloc(u8, p_len) catch return;
            @memcpy(p_slice, pixels[0..p_len]);

            // Look up item by ID — safe even if array was rewritten
            if (@This().findById(id)) |ptr| {
                ptr.thumb_w = @intCast(w);
                ptr.thumb_h = @intCast(h);
                ptr.thumb_pixels = p_slice;
                ptr.thumb_fetching = false;
                ptr.thumb_failed = false;
            } else {
                // Item no longer in queue — free the decoded pixels
                alloc.free(p_slice);
            }
        }
    };

    S.item_id = item.id;
    const url = item.thumb_url[0..item.thumb_url_len];
    if (url.len > S.url_buf.len) {
        item.thumb_fetching = false;
        _ = thumb_threads_active.fetchSub(1, .acq_rel);
        return;
    }
    @memcpy(S.url_buf[0..url.len], url);
    S.url_len = url.len;

    if (std.Thread.spawn(.{}, S.worker, .{})) |t| {
        t.detach();
    } else |_| {
        item.thumb_fetching = false;
        _ = thumb_threads_active.fetchSub(1, .acq_rel);
    }
}

// ══════════════════════════════════════════════════════════
// Thumbnail Backfill (for items added before thumb support)
// ══════════════════════════════════════════════════════════

var thumb_backfill_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var thumb_backfill_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var thumb_backfill_cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn startThumbBackfill() void {
    if (thumb_backfill_active.load(.acquire)) return;
    thumb_backfill_active.store(true, .release);
    thumb_backfill_cancel.store(false, .release);
    state.showToast("Fetching thumbnails...");

    if (std.Thread.spawn(.{}, struct {
        fn worker() void {
            defer {
                thumb_backfill_active.store(false, .release);
                state.showToast("Thumbnail fetch complete");
            }

            // Collect items needing thumbnails
            var ids: [MAX_QUEUE]i64 = undefined;
            var urls: [MAX_QUEUE][2048]u8 = undefined;
            var url_lens: [MAX_QUEUE]usize = undefined;
            var need_count: usize = 0;

            for (queue_items[0..queue_count]) |*item| {
                if (item.thumb_url_len == 0 and item.url_len > 0) {
                    ids[need_count] = item.id;
                    @memcpy(urls[need_count][0..item.url_len], item.url[0..item.url_len]);
                    url_lens[need_count] = item.url_len;
                    need_count += 1;
                    if (need_count >= MAX_QUEUE) break;
                }
            }

            if (need_count == 0) return;

            for (0..need_count) |i| {
                if (thumb_backfill_cancel.load(.acquire)) {
                    state.showToast("Thumbnail fetch cancelled");
                    return;
                }
                const url = urls[i][0..url_lens[i]];
                
                // yt-dlp --get-thumbnail <url> (bundled/system binary — bare
                // "yt-dlp" isn't on the GUI process PATH).
                const argv = [_][]const u8{
                    @import("ytdlp.zig").binary(), "--get-thumbnail",
                    "--no-warnings", "--no-check-certificates",
                    "--cookies-from-browser", "firefox",
                    url,
                };

                var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
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
        t.detach();
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

    // Update in-memory item too
    for (queue_items[0..queue_count]) |*item| {
        if (item.id == item_id) {
            const tlen = @min(thumb_url.len, 511);
            @memcpy(item.thumb_url[0..tlen], thumb_url[0..tlen]);
            item.thumb_url_len = tlen;
            item.thumb_fetching = false;
            break;
        }
    }
}
