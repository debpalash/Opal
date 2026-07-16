const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const icons = @import("icons");
const alloc = @import("../core/alloc.zig").allocator;
const pure = @import("playlist_pure.zig");
const m3u = @import("m3u.zig");
const io_global = @import("../core/io_global.zig");
const logs = @import("../core/logs.zig");

const transparent = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

var filter_buf: [128]u8 = std.mem.zeroes([128]u8);

// Cached filter match set — the substring scan over the whole playlist is
// O(n*m) and was previously recomputed every frame. We only rebuild it when
// the filter text or the entry list (pointer/len) actually changes.
var filter_cache_text: [128]u8 = std.mem.zeroes([128]u8);
var filter_cache_len: usize = 0;
var filter_cache_ptr: usize = 0;
var filter_cache_count: usize = 0;
var filter_cache_valid: bool = false;
var filter_matches: std.ArrayListUnmanaged(bool) = .empty;

const PlaylistTab = enum { playlist, queue };
var active_tab: PlaylistTab = .queue;

/// Free module-level caches (called from appDeinit — keeps the shutdown
/// leak check clean).
pub fn deinitModule() void {
    filter_matches.deinit(alloc);
    shuffle_order.deinit(alloc);
}

pub fn renderDrawer() void {
    if (!state.app.playlist_drawer_open) return;

    // Use same width as main drawer for consistency
    const w = state.app.drawer_width_px;
    
    var drawer_box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .expand = .vertical,
        .min_size_content = .{ .w = 350, .h = 0 },
        .max_size_content = .{ .w = w, .h = std.math.floatMax(f32) },
        .border = dvui.Rect{ .x=1, .y=0, .w=0, .h=0 },
        .color_border = theme.colors.border_subtle,
        .box_shadow = .{ .color = dvui.Color{ .r=0, .g=0, .b=0, .a=160 }, .offset = .{ .x=-2, .y=0 }, .fade = 16.0 },
    });
    defer drawer_box.deinit();

    // Header with tabs
    {
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = dvui.Rect.all(10),
            .background = true,
            .color_fill = theme.colors.bg_app,
            .color_border = theme.colors.border_subtle,
            .border = .{ .x=0, .y=0, .w=0, .h=1 },
        });
        defer head.deinit();

        // Queue tab
        if (dvui.button(@src(), "Queue", .{}, .{
            .color_fill = if (active_tab == .queue) theme.colors.accent else dvui.Color{ .r=0, .g=0, .b=0, .a=0 },
            .color_text = if (active_tab == .queue) theme.colors.bg_app else theme.colors.text_secondary,
            .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
            .corner_radius = theme.dims.rad_sm,
            .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
        })) {
            active_tab = .queue;
        }

        // Playlist tab
        if (dvui.button(@src(), "Playlist", .{}, .{
            .color_fill = if (active_tab == .playlist) theme.colors.accent else dvui.Color{ .r=0, .g=0, .b=0, .a=0 },
            .color_text = if (active_tab == .playlist) theme.colors.bg_app else theme.colors.text_secondary,
            .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
            .corner_radius = theme.dims.rad_sm,
        })) {
            active_tab = .playlist;
        }

        { var s = dvui.box(@src(), .{}, .{ .expand = .horizontal }); s.deinit(); }
        
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"x", .{}, .{}, theme.optIconBtnDanger())) {
            state.app.playlist_drawer_open = false;
        }
    }

    switch (active_tab) {
        .queue => renderQueueTab(),
        .playlist => renderPlaylistTab(),
    }
}

// ══════════════════════════════════════════════════════════
// Queue Tab (extracted videos from yt-dlp)
// ══════════════════════════════════════════════════════════

fn renderQueueTab() void {
    const queue_mod = @import("../services/queue.zig");
    queue_mod.renderContent();
}

// ══════════════════════════════════════════════════════════
// Playback control — shuffle / repeat / advance
// (decision logic lives in playlist_pure.zig; this is the wiring)
// ══════════════════════════════════════════════════════════

// Shuffle permutation over the CURRENT playlist — rebuilt when the entry
// count changes or shuffle is toggled on. UI-thread only (drawer + the
// player event pump both run on the frame thread).
var shuffle_order: std.ArrayListUnmanaged(u32) = .empty;

fn rebuildShuffleOrder(count: usize) void {
    shuffle_order.resize(alloc, count) catch return;
    // Deterministic given a seed (tests seed playlist_pure directly);
    // production seeds from the wall clock.
    pure.buildShuffleOrder(shuffle_order.items, @bitCast(io_global.milliTimestamp()));
}

fn shuffleOrderSlice(count: usize) ?[]const u32 {
    if (!state.app.playlist_shuffle or count == 0) return null;
    if (shuffle_order.items.len != count) rebuildShuffleOrder(count);
    if (shuffle_order.items.len != count) return null; // resize failed
    return shuffle_order.items;
}

pub const AdvanceResult = enum { started, end_of_playlist, not_playlist };

/// Advance the M3U playlist on player `p` (dir > 0 → next, < 0 → previous).
/// The index decision routes through playlist_pure.nextIndex/prevIndex so
/// repeat one/all/off and the seeded shuffle behave exactly as tested.
/// `.not_playlist` means what's playing didn't come from the playlist —
/// callers fall back to their old behavior (queue auto-advance).
pub fn advance(p: anytype, dir: i32) AdvanceResult {
    const pl = state.app.playlist orelse return .not_playlist;
    const count = pl.entries.items.len;
    if (count == 0) return .not_playlist;
    const cur = findCurrent(p, pl) orelse return .not_playlist;
    const order = shuffleOrderSlice(count);
    const target = if (dir >= 0)
        pure.nextIndex(cur, count, state.app.playlist_repeat, order)
    else
        pure.prevIndex(cur, count, state.app.playlist_repeat, order);
    const idx = target orelse return .end_of_playlist;
    playEntryOn(p, idx);
    return .started;
}

fn findCurrent(p: anytype, pl: *const m3u.M3UPlaylist) ?usize {
    const url = p.source_url[0..p.source_url_len];
    if (url.len == 0) return null;
    for (pl.entries.items, 0..) |e, i|
        if (std.mem.eql(u8, e.url, url)) return i;
    return null;
}

fn playEntryOn(p: anytype, idx: usize) void {
    const pl = state.app.playlist orelse return;
    if (idx >= pl.entries.items.len) return;
    const entry = pl.entries.items[idx];
    p.current_torrent_id = -1;
    p.is_torrent = false;
    const copy_len = @min(entry.url.len, p.source_url.len - 1);
    @memcpy(p.source_url[0..copy_len], entry.url[0..copy_len]);
    p.source_url[copy_len] = 0;
    p.source_url_len = copy_len;
    p.load_file(@ptrCast(p.source_url[0..copy_len].ptr));
}

/// Swap entry `idx` one slot up (dir < 0) or down (dir > 0). No-op at ends.
fn moveEntry(idx: usize, dir: i32) void {
    const pl = state.app.playlist orelse return;
    const items = pl.entries.items;
    if (idx >= items.len) return;
    const j: usize = if (dir < 0)
        (if (idx == 0) return else idx - 1)
    else
        (if (idx + 1 >= items.len) return else idx + 1);
    std.mem.swap(m3u.M3UEntry, &items[idx], &items[j]);
    filter_cache_valid = false; // cached match flags are per-index
}

/// Export the current playlist as M3U to ~/.config/opal/playlists/.
fn savePlaylist() void {
    const pl = state.app.playlist orelse return;
    const text = pl.serialize(alloc) catch {
        logs.pushLog("error", "m3u", "Playlist save failed: out of memory", true);
        return;
    };
    defer alloc.free(text);

    var cfg_buf: [512]u8 = undefined;
    const cfg = @import("../core/paths.zig").configDir(&cfg_buf);
    var dir_buf: [600]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/playlists", .{cfg}) catch return;
    io_global.makeDirAbsolute(dir_path) catch {}; // already exists → fine
    var path_buf: [700]u8 = undefined;
    const file_path = std.fmt.bufPrint(&path_buf, "{s}/playlist-{d}.m3u", .{
        dir_path, io_global.timestamp(),
    }) catch return;

    const f = io_global.createFileAbsolute(file_path, .{}) catch {
        logs.pushLog("error", "m3u", "Playlist save failed: cannot create file", true);
        return;
    };
    defer io_global.closeFile(f);
    io_global.writeAll(f, text) catch {
        logs.pushLog("error", "m3u", "Playlist save failed: write error", true);
        return;
    };
    logs.pushLog("info", "m3u", file_path, false); // exact save location
    state.showToast("Playlist saved (see Logs for path)");
}

// ══════════════════════════════════════════════════════════
// Playlist Tab (M3U / IPTV channels)
// ══════════════════════════════════════════════════════════

fn renderPlaylistTab() void {
    // Empty state
    if (state.app.playlist == null) {
        var empty_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .gravity_x = 0.5, .gravity_y = 0.5, .padding = dvui.Rect.all(24) });
        _ = dvui.label(@src(), "No playlist loaded.", .{}, .{ .color_text = theme.colors.text_secondary });
        _ = dvui.label(@src(), "Drop an .m3u file or folder here.", .{}, .{ .color_text = theme.colors.text_secondary });
        empty_box.deinit();
        return;
    }

    const pl = state.app.playlist.?;

    // Filter bar
    {
        var filter_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
        });
        defer filter_row.deinit();
        
        dvui.icon(@src(), "", icons.tvg.lucide.@"search", .{}, .{ .color_text = theme.colors.text_secondary, .gravity_y = 0.5, .margin = .{ .x=0, .y=0, .w=6, .h=0 } });
        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &filter_buf } }, .{
            .expand = .horizontal,
            .color_fill = theme.colors.bg_elevated,
            .color_border = theme.colors.border_subtle,
            .color_text = theme.colors.text_primary,
            .border = dvui.Rect.all(1),
            .corner_radius = theme.dims.rad_sm,
        });
        te.deinit();
    }

    // Toolbar: shuffle | repeat (off→all→one) | prev/next | save
    {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 0, .w = 12, .h = 4 },
        });
        defer bar.deinit();

        if (dvui.buttonIcon(@src(), "pl-shuffle", icons.tvg.lucide.shuffle, .{}, .{}, .{
            .color_text = if (state.app.playlist_shuffle) theme.colors.accent else theme.colors.text_secondary,
            .color_fill = transparent,
        })) {
            state.app.playlist_shuffle = !state.app.playlist_shuffle;
            // Fresh permutation each time shuffle turns on.
            if (state.app.playlist_shuffle) rebuildShuffleOrder(pl.entries.items.len);
            state.app.config_dirty = true;
        }

        const rep = state.app.playlist_repeat;
        const rep_icon = if (rep == .one) icons.tvg.lucide.@"repeat-1" else icons.tvg.lucide.repeat;
        if (dvui.buttonIcon(@src(), "pl-repeat", rep_icon, .{}, .{}, .{
            .color_text = if (rep == .off) theme.colors.text_secondary else theme.colors.accent,
            .color_fill = transparent,
        })) {
            state.app.playlist_repeat = rep.cycled();
            state.app.config_dirty = true;
        }

        // Prev / Next — same pure advance path the auto-advance uses.
        if (dvui.buttonIcon(@src(), "pl-prev", icons.tvg.lucide.@"skip-back", .{}, .{}, .{
            .color_text = theme.colors.text_secondary,
            .color_fill = transparent,
        })) {
            if (state.app.active_player_idx < state.app.players.items.len)
                _ = advance(state.app.players.items[state.app.active_player_idx], -1);
        }
        if (dvui.buttonIcon(@src(), "pl-next", icons.tvg.lucide.@"skip-forward", .{}, .{}, .{
            .color_text = theme.colors.text_secondary,
            .color_fill = transparent,
        })) {
            if (state.app.active_player_idx < state.app.players.items.len)
                _ = advance(state.app.players.items[state.app.active_player_idx], 1);
        }

        { var s = dvui.box(@src(), .{}, .{ .expand = .horizontal }); s.deinit(); }

        if (dvui.buttonIcon(@src(), "pl-save", icons.tvg.lucide.save, .{}, .{}, .{
            .color_text = theme.colors.text_secondary,
            .color_fill = transparent,
        })) {
            savePlaylist();
        }
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .margin = dvui.Rect.all(12) });
    defer scroll.deinit();

    var list = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    defer list.deinit();

    // Get filter text
    const filter_len = std.mem.indexOfScalar(u8, &filter_buf, 0) orelse 0;
    const filter_text = filter_buf[0..filter_len];

    // Get current player's URL for active highlighting
    var active_url: []const u8 = "";
    if (state.app.active_player_idx < state.app.players.items.len) {
        const ap = state.app.players.items[state.app.active_player_idx];
        active_url = ap.source_url[0..ap.source_url_len];
    }

    // Rebuild the filter match cache only when the filter text or the entry
    // list actually changed. Keeps per-frame cost O(visible) instead of O(n*m).
    {
        const entries_ptr = @intFromPtr(pl.entries.items.ptr);
        const entries_count = pl.entries.items.len;
        const cache_hit = filter_cache_valid and
            filter_cache_len == filter_len and
            filter_cache_ptr == entries_ptr and
            filter_cache_count == entries_count and
            std.mem.eql(u8, filter_cache_text[0..filter_cache_len], filter_text);
        if (!cache_hit) {
            filter_matches.clearRetainingCapacity();
            filter_matches.ensureTotalCapacity(alloc, entries_count) catch {};
            for (pl.entries.items) |entry| {
                var matched = true;
                if (filter_len > 0) {
                    const title_match = caseContains(entry.title, filter_text);
                    const group_match = if (entry.group) |g| caseContains(g, filter_text) else false;
                    matched = title_match or group_match;
                }
                filter_matches.append(alloc, matched) catch {};
            }
            @memcpy(filter_cache_text[0..filter_len], filter_text);
            filter_cache_len = filter_len;
            filter_cache_ptr = entries_ptr;
            filter_cache_count = entries_count;
            filter_cache_valid = true;
        }
    }

    var rendered: usize = 0;
    for (pl.entries.items, 0..) |entry, i| {
        // Filter: skip entries that don't match (cached above)
        if (filter_len > 0) {
            if (i >= filter_matches.items.len or !filter_matches.items[i]) continue;
        }

        // Cap visible items for performance
        if (rendered >= 500) {
            _ = dvui.label(@src(), "... and more (refine filter)", .{}, .{ .color_text = theme.colors.text_secondary });
            break;
        }
        rendered += 1;

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
        });
        defer row.deinit();

        const group_str = entry.group orelse "Unknown";
        var label_buf: [128]u8 = undefined;
        v_title_trunc: {
            const safe_len = @min(entry.title.len, 80);
            const safe_grp = @min(group_str.len, 30);
            const res = std.fmt.bufPrintZ(&label_buf, "{s}\n{s}", .{
                entry.title[0..safe_len],
                group_str[0..safe_grp]
            }) catch {
                label_buf[0] = 0;
                break :v_title_trunc;
            };
            _ = res;
        }

        const is_active = active_url.len > 0 and std.mem.eql(u8, active_url, entry.url);
        const bg_color = if (is_active) theme.colors.accent else theme.colors.bg_surface;
        const fg_color = if (is_active) theme.colors.bg_app else theme.colors.text_primary;
        
        // Title/group are trimmed at byte boundaries (can cut a codepoint) and
        // come from untrusted M3U/IPTV playlists — validate before dvui draws it
        // (invalid UTF-8 panics the whole app).
        const lbl_slice = label_buf[0 .. std.mem.indexOfScalar(u8, &label_buf, 0) orelse 0];
        const clicked = dvui.button(@src(), @import("../core/text.zig").safeUtf8(lbl_slice), .{}, .{
            .id_extra = i,
            .expand = .horizontal,
            .color_fill = bg_color,
            .color_text = fg_color,
            .corner_radius = theme.dims.rad_sm,
            .gravity_x = 0.0,
        });

        if (clicked and state.app.active_player_idx < state.app.players.items.len) {
            playEntryOn(state.app.players.items[state.app.active_player_idx], i);
        }

        // Reorder: move up / move down (no-ops at the ends).
        if (dvui.buttonIcon(@src(), "pl-move-up", icons.tvg.lucide.@"chevron-up", .{}, .{}, .{
            .id_extra = i,
            .color_text = if (i > 0) theme.colors.text_secondary else theme.colors.border_subtle,
            .color_fill = transparent,
            .gravity_y = 0.5,
        })) {
            moveEntry(i, -1);
        }
        if (dvui.buttonIcon(@src(), "pl-move-down", icons.tvg.lucide.@"chevron-down", .{}, .{}, .{
            .id_extra = i,
            .color_text = if (i + 1 < pl.entries.items.len) theme.colors.text_secondary else theme.colors.border_subtle,
            .color_fill = transparent,
            .gravity_y = 0.5,
        })) {
            moveEntry(i, 1);
        }
    }
}

fn caseContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}
