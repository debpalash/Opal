//! Downloads — ONE unified list.
//!
//! This used to be three tabs (Files / Active / History) over three unrelated
//! sources, which meant a finished torrent appeared three times and the actions
//! you could take on it depended on which tab you happened to be standing in.
//! The merge/dedup/status/sort decisions now live in `transfers_pure.zig`
//! (unit-tested in isolation); this file only *executes* them: it collects the
//! three sources into staging rows, hands them to `tp.buildRows`, and draws the
//! result with the UNION of the actions each row's handles allow.

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const c = @import("../core/c.zig");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const components = @import("../ui/components.zig");
const search = @import("search.zig");
const history = @import("history.zig");
const io_global = @import("../core/io_global.zig");
const tp = @import("transfers_pure.zig");
const vt_pure = @import("virustotal_pure.zig");
const httpdl = @import("downloads.zig");
const gallerydl = @import("gallerydl.zig");
const gdl_pure = @import("gallerydl_pure.zig");
const safeUtf8 = @import("../core/text.zig").safeUtf8;
const safeUtf8Buf = @import("../core/text.zig").safeUtf8Buf;

// ══════════════════════════════════════════════════════════
// MODULE STATE
// ══════════════════════════════════════════════════════════

var filter: tp.Filter = .all;

var rows: [tp.MAX_ROWS]tp.Row = undefined;
var order: [tp.MAX_ROWS]u16 = undefined;
var row_count: usize = 0;

/// Set after EVERY mutating action (and by the file-scan worker) to force the
/// next frame to rebuild instead of waiting out the 2Hz throttle. Written from
/// the bg scan thread → atomic.
var rows_dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
var last_build_ms: i64 = 0;

/// Expansion is keyed by row IDENTITY, not by index: the row array is rebuilt
/// (and re-sorted) twice a second, so an index would point at a different item
/// moments after the user clicked. Key = infohash, else the on-disk entry, else
/// the normalized name.
var expanded_key: [256]u8 = std.mem.zeroes([256]u8);
var expanded_key_len: usize = 0;

// Staging rows live at module scope, not on the UI stack: a tp.Row is ~700B and
// three arrays of them would be ~350KB of stack per frame.
var stage_t: [64]tp.Row = undefined;
var stage_f: [MAX_CACHED_FILES]tp.Row = undefined;
var stage_h: [state.MAX_DL_HISTORY]tp.Row = undefined;

// ══════════════════════════════════════════════════════════
// ENTRY POINT
// ══════════════════════════════════════════════════════════

pub fn renderTransfersContent() void {
    // Always runs (even while drilled into a subfolder) — torrent_poll is
    // side-effecting: it drives the streaming deadline window, so it must keep
    // ticking regardless of which sub-view is on screen.
    buildSnapshot();

    consumeVtHashResult();
    // HTTP downloader housekeeping: config sync + completed→history hand-off.
    httpdl.tick();

    renderControlBar();

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    // Drill-down into a torrent's output folder is a plain directory browse —
    // torrents and history don't live inside a subfolder, so merging there
    // would be meaningless.
    if (browse_subdir_len > 0) {
        renderFolderBrowse();
        return;
    }

    renderUnifiedList();
}

// ══════════════════════════════════════════════════════════
// SNAPSHOT — UI thread, throttled to 2Hz
// ══════════════════════════════════════════════════════════

fn buildSnapshot() void {
    const now = io_global.milliTimestamp();
    if (!rows_dirty.load(.acquire) and now - last_build_ms < 500) return;
    last_build_ms = now;
    rows_dirty.store(false, .release);

    const ses = state.torrentSession();
    const save_path = state.app.save_path_buf[0..state.app.save_path_len];

    // ── Keep the root file cache warm (only when NOT drilled into a subdir —
    // the browse view owns the cache while it is open). ──
    if (browse_subdir_len == 0) {
        const now_s = io_global.timestamp();
        if (browse_path_changed or now_s - cached_files_last_scan >= 5) {
            cached_files_last_scan = now_s;
            browse_path_changed = false;
            triggerFileScan(save_path);
        }
    }

    // ── TORRENTS ──
    var tn: usize = 0;
    const t_count = c.mpv.torrent_count(ses);
    var i: i32 = 0;
    while (i < t_count and tn < stage_t.len) : (i += 1) {
        // STABLE-SLOT model: removed torrents keep their id but report dead.
        if (c.mpv.torrent_is_alive(ses, i) == 0) continue;

        var r = tp.Row{ .origin = .torrent, .torrent_id = i };

        // EXACTLY ONE poll per torrent per rebuild (this used to run every
        // frame at ~60Hz). out_path is requested so we learn the on-disk entry
        // the torrent creates — that's what joins it to a Files row.
        var pbuf: [1024]u8 = undefined;
        pbuf[0] = 0;
        var progress: f32 = 0;
        var dl_rate: c_int = 0;
        var seeds: c_int = 0;
        const rc = c.mpv.torrent_poll(ses, i, -1, &pbuf, 1024, &progress, &dl_rate, &seeds);

        r.progress = progress;
        r.dl_rate = if (dl_rate > 0) @intCast(dl_rate) else 0;
        r.seeds = if (seeds > 0) @intCast(@min(seeds, 65535)) else 0;
        r.poll_err = rc < 0;
        r.has_metadata = rc >= 0 and pbuf[0] != 0;
        r.paused = c.mpv.torrent_is_paused(ses, i) != 0;
        const tsize = c.mpv.torrent_get_total_size(ses, i);
        r.size = if (tsize > 0) @intCast(tsize) else 0;

        var nbuf: [256]u8 = undefined;
        c.mpv.torrent_get_name(ses, i, &nbuf, 256);
        const nlen = std.mem.indexOfScalar(u8, &nbuf, 0) orelse nbuf.len;
        const name = nbuf[0..nlen];
        tp.setName(&r, name);

        // libtorrent knows the v1 infohash straight from the magnet, before any
        // metadata arrives — which is what keeps two pre-metadata magnets from
        // colliding on their identical placeholder names.
        var hbuf: [64]u8 = undefined;
        hbuf[0] = 0;
        if (c.mpv.torrent_get_infohash(ses, i, &hbuf, 64) == 0) {
            const hlen = std.mem.indexOfScalar(u8, &hbuf, 0) orelse hbuf.len;
            var ih: [tp.IH_LEN]u8 = undefined;
            if (tp.parseInfohash(hbuf[0..hlen], &ih) == tp.IH_LEN) tp.setIh(&r, &ih);
        }

        // The name is a WEAK merge key; torrent_get_name() returns the literal
        // "Fetching Metadata..." placeholder pre-metadata, and that string is
        // identical across unrelated magnets (and can even have been written to
        // history by an early remove). Never let it become a merge key.
        if (!std.mem.startsWith(u8, name, "Fetching Metadata")) {
            var nb: [tp.NORM_LEN]u8 = undefined;
            tp.setNorm(&r, nb[0..tp.normalizeName(name, &nb)]);
        }

        if (r.has_metadata) {
            const plen = std.mem.indexOfScalar(u8, &pbuf, 0) orelse pbuf.len;
            const abs = pbuf[0..plen];
            if (tp.firstPathComponentAfter(abs, save_path)) |comp| {
                tp.setDisk(&r, comp);
                // A multi-file torrent's poll path is <root>/<dir>/<file>, so a
                // '/' right after the component means the entry on disk is a dir.
                const off = @intFromPtr(comp.ptr) - @intFromPtr(abs.ptr);
                r.is_dir = off + comp.len < abs.len and abs[off + comp.len] == '/';
            }
        }

        stage_t[tn] = r;
        tn += 1;
    }

    // ── FILES (never alias the shared cache buffers: the bg scan worker
    // rewrites them under files_mutex — copy out, then release). ──
    var fn_: usize = 0;
    files_mutex.lock();
    const cache_is_root = std.mem.eql(u8, cached_files_path_buf[0..cached_files_path_len], save_path);
    if (cache_is_root) {
        var k: usize = 0;
        while (k < cached_files_count and fn_ < stage_f.len) : (k += 1) {
            const nm = cached_files_names[k][0..@min(cached_files_name_lens[k], MAX_NAME_LEN)];
            if (nm.len == 0) continue;
            var r = tp.Row{
                .origin = .file,
                .size = cached_files_sizes[k],
                .mtime = cached_files_mtimes[k],
                .is_dir = cached_files_is_dir[k],
            };
            tp.setName(&r, nm);
            tp.setDisk(&r, nm);
            var nb: [tp.NORM_LEN]u8 = undefined;
            tp.setNorm(&r, nb[0..tp.normalizeName(nm, &nb)]);
            stage_f[fn_] = r;
            fn_ += 1;
        }
    }
    files_mutex.unlock();

    // ── HISTORY ──
    var hn: usize = 0;
    var hi: usize = 0;
    while (hi < state.app.dl_history_count and hn < stage_h.len) : (hi += 1) {
        const raw = state.app.dl_history_names[hi][0..state.app.dl_history_name_lens[hi]];
        const link = state.app.dl_history_links[hi][0..state.app.dl_history_link_lens[hi]];

        var r = tp.Row{ .origin = .history, .hist_idx = @intCast(hi) };

        var ih: [tp.IH_LEN]u8 = undefined;
        if (tp.parseInfohash(link, &ih) == tp.IH_LEN) {
            tp.setIh(&r, &ih);
        } else if (tp.parseInfohash(raw, &ih) == tp.IH_LEN) {
            tp.setIh(&r, &ih);
        }

        // A raw magnet must never become the label.
        const display = if (std.mem.startsWith(u8, raw, "magnet:"))
            extractDn(raw)
        else if (raw.len == 0 and link.len > 0)
            extractDn(link)
        else
            raw;
        tp.setName(&r, display);
        var nb: [tp.NORM_LEN]u8 = undefined;
        tp.setNorm(&r, nb[0..tp.normalizeName(display, &nb)]);

        stage_h[hn] = r;
        hn += 1;
    }

    row_count = tp.buildRows(stage_t[0..tn], stage_f[0..fn_], stage_h[0..hn], &rows);
    _ = tp.sortOrder(rows[0..row_count], &order);
}

// ══════════════════════════════════════════════════════════
// ROW IDENTITY (expansion key + stable widget ids)
// ══════════════════════════════════════════════════════════

fn rowKey(r: *const tp.Row) []const u8 {
    if (r.ih_len > 0) return r.ihSlice();
    if (r.disk_len > 0) return r.diskSlice();
    if (r.norm_len > 0) return r.normSlice();
    return r.nameSlice();
}

/// Stable per-row widget id: dvui keys widget state (e.g. an armed confirm
/// button) by id, and the sort order moves rows around, so a positional id
/// would hand one row's armed state to another.
fn rowId(r: *const tp.Row) usize {
    return @truncate(std.hash.Wyhash.hash(0x0DA1, rowKey(r)));
}

fn isExpanded(r: *const tp.Row) bool {
    if (expanded_key_len == 0) return false;
    return std.mem.eql(u8, expanded_key[0..expanded_key_len], rowKey(r));
}

fn toggleExpanded(r: *const tp.Row) void {
    if (isExpanded(r)) {
        expanded_key_len = 0;
        return;
    }
    const k = rowKey(r);
    const n = @min(k.len, expanded_key.len);
    @memcpy(expanded_key[0..n], k[0..n]);
    expanded_key_len = n;
}

// ══════════════════════════════════════════════════════════
// CONTROL BAR — filter chips + download speed limit, one row
// ══════════════════════════════════════════════════════════

fn renderControlBar() void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = dvui.Color{ .r = 18, .g = 18, .b = 26, .a = 255 },
        .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .color_border = theme.colors.border_subtle,
    });
    defer row.deinit();

    // ── Left: filter chips (hidden while drilled into a subfolder — the
    // browse view has its own path bar and shows only that folder). ──
    if (browse_subdir_len == 0) {
        var counts: [5]usize = .{ 0, 0, 0, 0, 0 };
        tp.countsFor(rows[0..row_count], &counts);

        const chips = [_]tp.Filter{ .all, .downloading, .seeding, .on_disk, .history };
        const names = [_][]const u8{ "All", "Downloading", "Seeding", "On disk", "History" };

        for (chips, 0..) |f, k| {
            var lbuf: [32]u8 = undefined;
            const lbl = std.fmt.bufPrintZ(&lbuf, "{s} ({d})", .{ names[k], counts[k] }) catch names[k];
            const sel = filter == f;
            if (dvui.button(@src(), lbl, .{}, .{
                .id_extra = k + 90000,
                .color_fill = if (sel) theme.colors.accent else dvui.Color{ .r = 22, .g = 22, .b = 32, .a = 255 },
                .color_text = if (sel) dvui.Color{ .r = 10, .g = 10, .b = 15, .a = 255 } else theme.colors.text_secondary,
                .padding = .{ .x = 12, .y = 5, .w = 12, .h = 5 },
                .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
                .corner_radius = dvui.Rect.all(theme.radius.pill),
                .border = dvui.Rect.all(if (sel) @as(f32, 1) else @as(f32, 0)),
                .color_border = theme.colors.accent,
                .gravity_y = 0.5,
            })) {
                filter = f;
            }
        }
    }

    // ── Paste-a-URL download: the HTTP downloader otherwise only has the
    // remote API + browser interception as entry points. Reads the clipboard
    // on click; accepts http(s) URLs (magnets go to the torrent path instead). ──
    if (browse_subdir_len == 0) {
        if (dvui.button(@src(), "＋ URL", .{}, .{
            .id_extra = 90500,
            .color_fill = dvui.Color{ .r = 24, .g = 30, .b = 44, .a = 255 },
            .color_text = theme.colors.accent,
            .padding = .{ .x = 12, .y = 5, .w = 12, .h = 5 },
            .margin = .{ .x = 8, .y = 0, .w = 0, .h = 0 },
            .corner_radius = dvui.Rect.all(theme.radius.pill),
            .gravity_y = 0.5,
        })) {
            const clip = std.mem.trim(u8, dvui.clipboardText(), " \t\r\n");
            if (std.mem.startsWith(u8, clip, "http://") or std.mem.startsWith(u8, clip, "https://")) {
                // Image-gallery / art / booru URLs go to gallery-dl (hundreds of
                // sites the HTTP downloader / yt-dlp don't cover); everything
                // else falls through to the existing HTTP download path.
                if (gallerydl.enabled() and gdl_pure.shouldUseGalleryDl(clip)) {
                    _ = gallerydl.fetch(clip);
                } else if (httpdl.startUrl(clip)) {
                    state.showToast("Download started from clipboard URL");
                } else {
                    state.showToastTyped("Couldn't start that download", .err);
                }
            } else if (std.mem.startsWith(u8, clip, "magnet:")) {
                search.loadTorrentToPlayer(clip);
            } else {
                state.showToastTyped("Clipboard isn't an http(s) URL", .warning);
            }
        }
    }

    // Flexible spacer — pushes the speed limit to the right edge.
    {
        var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
        spacer.deinit();
    }

    // ── HTTP downloader totals (only when something is moving/waiting) ──
    {
        const agg = httpdl.engine.activeAndQueued();
        if (agg.active + agg.queued > 0) {
            var tb: [64]u8 = undefined;
            var rb: [24]u8 = undefined;
            const txt = std.fmt.bufPrintZ(&tb, "↓{s} · {d} active · {d} queued", .{
                httpdl.dp.fmtSpeed(agg.rate, &rb), agg.active, agg.queued,
            }) catch "";
            _ = dvui.label(@src(), "{s}", .{txt}, .{
                .gravity_y = 0.5,
                .color_text = theme.colors.accent,
                .margin = .{ .x = 0, .y = 0, .w = 12, .h = 0 },
            });
        }
    }

    // ── Right: download speed limit. ──
    _ = dvui.label(@src(), "Limit:", .{}, .{
        .gravity_y = 0.5,
        .color_text = theme.colors.text_secondary,
        .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
    });

    // Single source of truth: state.app.download_rate_limit, stored in BYTES/sec
    // (same unit as the settings + footer controls and the FFI call below).
    const limits = [_]i32{ 0, 1 * 1024 * 1024, 5 * 1024 * 1024, 20 * 1024 * 1024 };
    const labels = [_][]const u8{ "∞", "1MB/s", "5MB/s", "20MB/s" };
    for (limits, 0..) |lim, k| {
        const active = state.app.download_rate_limit == lim;
        if (dvui.button(@src(), labels[k], .{}, .{
            .id_extra = k,
            .color_fill = if (active) theme.colors.accent else dvui.Color{ .r = 24, .g = 24, .b = 34, .a = 255 },
            .color_text = if (active) dvui.Color{ .r = 10, .g = 10, .b = 15, .a = 255 } else theme.colors.text_secondary,
            .color_border = if (active) theme.colors.accent else dvui.Color{ .r = 45, .g = 45, .b = 60, .a = 200 },
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(theme.radius.pill),
            .padding = .{ .x = 12, .y = 4, .w = 12, .h = 4 },
            .margin = .{ .x = 0, .y = 0, .w = 5, .h = 0 },
            .gravity_y = 0.5,
        })) {
            state.app.download_rate_limit = lim;
            c.mpv.torrent_set_download_limit(state.torrentSession(), lim);
        }
    }
}

// ══════════════════════════════════════════════════════════
// THE UNIFIED LIST
// ══════════════════════════════════════════════════════════

fn renderUnifiedList() void {
    // Direct HTTP downloads first — they're what the user just started.
    const http_shown = renderHttpRows();

    var shown: usize = 0;
    for (order[0..row_count]) |oi| {
        const r = &rows[oi];
        if (!tp.matchesFilter(r, filter)) continue;

        // renderRow returns true when it removed something — torrent ids and
        // history indices are invalidated mid-frame, so bail out at once.
        if (renderRow(r, shown)) return;
        shown += 1;

        if (isExpanded(r)) {
            if (renderExpanded(r)) return;
        }
    }

    if (shown == 0 and http_shown == 0) {
        const msg: []const u8 = switch (filter) {
            .all => "Nothing here yet. Downloads, files and history all show up in this list.",
            .downloading => "No active downloads.",
            .seeding => "Nothing is seeding.",
            .on_disk => "Download folder is empty.",
            .history => "No download history yet.",
        };
        _ = dvui.label(@src(), "{s}", .{msg}, .{
            .color_text = theme.colors.text_secondary,
            .padding = .{ .x = 14, .y = 20, .w = 0, .h = 0 },
        });
    }
}

fn statusColor(s: tp.Status) dvui.Color {
    return switch (s) {
        .downloading, .fetching => theme.colors.accent,
        .paused => theme.colors.text_tertiary,
        .errored => theme.colors.danger,
        .seeding, .complete => theme.colors.success,
        .on_disk => dvui.Color{ .r = 100, .g = 170, .b = 255, .a = 255 },
        .archived => theme.colors.text_tertiary,
    };
}

/// Draws one merged row. Returns true if it performed a removal (the caller
/// must stop iterating: ids/indices are now stale).
fn renderRow(r: *const tp.Row, i: usize) bool {
    const rid = rowId(r);
    const st = tp.statusFor(r);
    const name = r.nameSlice();
    const is_video = isVideoExt(name);
    const is_audio = isAudioExt(name);
    const active = switch (st) {
        .downloading, .fetching, .paused, .errored => true,
        else => false,
    };

    const row_bg = if (i % 2 == 0)
        dvui.Color{ .r = 18, .g = 18, .b = 26, .a = 255 }
    else
        dvui.Color{ .r = 21, .g = 21, .b = 30, .a = 255 };

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = rid,
        .expand = .horizontal,
        .background = true,
        .color_fill = row_bg,
        .padding = .{ .x = 10, .y = 7, .w = 10, .h = 7 },
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .color_border = dvui.Color{ .r = 30, .g = 30, .b = 45, .a = 140 },
    });
    defer row.deinit();

    // Status bar (colored left edge)
    {
        var bar = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = rid,
            .min_size_content = .{ .w = 3, .h = 0 },
            .expand = .vertical,
            .background = true,
            .color_fill = statusColor(st),
            .corner_radius = dvui.Rect.all(2),
            .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
            .gravity_y = 0.5,
        });
        bar.deinit();
    }

    // Icon
    {
        const ico = if (r.is_dir)
            icons.tvg.lucide.folder
        else if (is_video)
            icons.tvg.lucide.film
        else if (is_audio)
            icons.tvg.lucide.music
        else
            icons.tvg.lucide.file;
        const icol = if (r.is_dir)
            dvui.Color{ .r = 100, .g = 170, .b = 255, .a = 255 }
        else if (is_video)
            dvui.Color{ .r = 100, .g = 220, .b = 120, .a = 255 }
        else if (is_audio)
            dvui.Color{ .r = 255, .g = 180, .b = 80, .a = 255 }
        else
            theme.colors.text_tertiary;
        _ = dvui.icon(@src(), "", ico, .{}, .{
            .id_extra = rid,
            .color_text = icol,
            .min_size_content = .{ .w = 14, .h = 14 },
            .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
            .gravity_y = 0.5,
        });
    }

    // Name + progress + meta
    {
        var blk = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = rid,
            .expand = .horizontal,
            .gravity_y = 0.5,
        });
        defer blk.deinit();

        // Names are untrusted bytes (libtorrent / the filesystem): invalid UTF-8
        // panics dvui's text layout.
        var nm_buf: [tp.NAME_LEN]u8 = undefined;
        const shown_name = safeUtf8Buf(displayName(name), &nm_buf);
        // NOT `.expand = .horizontal`: dvui centers a button's label within its
        // rect, so an expanded button parks the title in the middle of the row.
        // Size to content + gravity_x = 0 keeps the name hard left, next to its
        // icon, which is where the eye looks for it in a file list.
        if (dvui.button(@src(), if (shown_name.len > 0) shown_name else "(unnamed)", .{}, .{
            .id_extra = rid,
            // gravity_x only. This button lives in a VERTICAL box, so setting
            // gravity_y (the main axis) mis-positions it and it overlaps the meta
            // line stacked beneath it — same trap documented in onboarding.zig.
            .gravity_x = 0.0,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = if (st == .archived or st == .paused) theme.colors.text_secondary else theme.colors.text_primary,
            .padding = dvui.Rect.all(0),
        })) {
            toggleExpanded(r);
        }

        if (active) {
            var frac = std.math.clamp(r.progress, 0.0, 1.0);
            _ = dvui.slider(@src(), .{ .fraction = &frac }, .{
                .id_extra = rid,
                .expand = .horizontal,
                .min_size_content = .{ .w = 10, .h = 4 },
                .color_fill = dvui.Color{ .r = 35, .g = 35, .b = 50, .a = 255 },
                .color_text = statusColor(st),
                .corner_radius = dvui.Rect.all(2),
                .margin = .{ .x = 0, .y = 3, .w = 0, .h = 0 },
            });
        }

        var meta_buf: [96]u8 = undefined;
        const meta = metaLine(r, st, &meta_buf);
        _ = dvui.label(@src(), "{s}", .{meta}, .{
            .id_extra = rid,
            .expand = .horizontal,
            .color_text = if (st == .errored) theme.colors.danger else theme.colors.text_tertiary,
            .margin = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
        });
    }

    // ── Actions: the UNION of what this row's handles allow ──
    var acts = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = rid,
        .min_size_content = .{ .w = 190, .h = 0 },
        .gravity_y = 0.5,
    });
    defer acts.deinit();

    // Play / stream the torrent.
    if (r.hasTorrent() and r.has_metadata) {
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.play, .{}, .{}, .{
            .id_extra = rid,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.success,
            .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
            .gravity_y = 0.5,
        })) {
            if (state.app.active_player_idx < state.app.players.items.len) {
                const p = state.app.players.items[state.app.active_player_idx];
                p.current_torrent_id = r.torrent_id;
                p.torrent_is_ready = false;
                p.has_metadata = false;
                p.last_load_time = 0;
                p.selected_file_idx = -1;
                p.metadata_start_time = io_global.timestamp();
            }
        }
    } else if (r.hasFile() and !r.is_dir and (is_video or is_audio)) {
        // Play the file straight off disk.
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.play, .{}, .{}, .{
            .id_extra = rid,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.success,
            .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
            .gravity_y = 0.5,
        })) {
            const save_path = state.app.save_path_buf[0..state.app.save_path_len];
            var fp: [1024]u8 = undefined;
            if (std.fmt.bufPrintZ(&fp, "{s}/{s}", .{ save_path, r.diskSlice() })) |full| {
                if (state.app.active_player_idx < state.app.players.items.len) {
                    state.app.players.items[state.app.active_player_idx].load_file(full);
                    // Record into the SHARED watch-history store (with the file
                    // path as the replay link) so it shows on the History page
                    // too, and reveal the player.
                    @import("../player/watch_history.zig").savePosition(r.diskSlice(), 1.0, full);
                    state.gotoPlayer();
                }
            } else |_| {}
        }
    }

    // Open the folder (drill down).
    if (r.hasFile() and r.is_dir) {
        if (dvui.button(@src(), "Open", .{}, .{
            .id_extra = rid,
            .color_fill = theme.colors.accent,
            .color_text = dvui.Color{ .r = 10, .g = 10, .b = 15, .a = 255 },
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
            .margin = .{ .x = 0, .y = 0, .w = 2, .h = 0 },
            .gravity_y = 0.5,
        })) {
            const d = r.diskSlice();
            const nlen = @min(d.len, browse_subdir_buf.len);
            @memcpy(browse_subdir_buf[0..nlen], d[0..nlen]);
            browse_subdir_len = nlen;
            browse_path_changed = true;
        }
    }

    // Pause / resume.
    if (r.hasTorrent()) {
        const pic = if (r.paused) icons.tvg.lucide.play else icons.tvg.lucide.pause;
        const pcol = if (r.paused) theme.colors.accent else theme.colors.text_secondary;
        if (dvui.buttonIcon(@src(), "", pic, .{}, .{}, .{
            .id_extra = rid,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = pcol,
            .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
            .gravity_y = 0.5,
        })) {
            if (c.mpv.torrent_is_alive(state.torrentSession(), r.torrent_id) != 0) {
                if (r.paused)
                    c.mpv.torrent_resume(state.torrentSession(), r.torrent_id)
                else
                    c.mpv.torrent_pause(state.torrentSession(), r.torrent_id);
            }
            rows_dirty.store(true, .release);
        }
    }

    // Re-download from the history link.
    if (r.hasHistory() and !r.hasTorrent()) {
        const hidx: usize = @intCast(r.hist_idx);
        if (hidx < state.app.dl_history_count and state.app.dl_history_link_lens[hidx] > 0) {
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.download, .{}, .{}, .{
                .id_extra = rid,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_text = theme.colors.accent,
                .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
                .gravity_y = 0.5,
            })) {
                search.loadTorrentToPlayer(state.app.dl_history_links[hidx][0..state.app.dl_history_link_lens[hidx]]);
                rows_dirty.store(true, .release);
            }
        }
    }

    // Reveal in the file manager.
    if (r.hasFile()) {
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"folder-open", .{}, .{}, .{
            .id_extra = rid,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.text_tertiary,
            .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
            .gravity_y = 0.5,
        })) {
            const save_path = state.app.save_path_buf[0..state.app.save_path_len];
            var fp: [1024]u8 = undefined;
            if (std.fmt.bufPrintZ(&fp, "{s}/{s}", .{ save_path, r.diskSlice() })) |full| {
                openInFileManager(full);
            } else |_| {}
        }
    }

    // Remove from Opal. NEVER deletes disk bytes (that lives in the expanded
    // panel behind its own confirm).
    if (components.confirmDangerButton(@src(), "Remove", rid)) {
        removeRow(r);
        return true;
    }

    return false;
}

/// "remove from Opal" — drops the live torrent (and, for a history-only row,
/// the history record). Files on disk are NEVER touched here.
fn removeRow(r: *const tp.Row) void {
    if (r.hasTorrent()) {
        const id = r.torrent_id;
        // Don't duplicate an existing history record for the same item.
        if (!r.hasHistory()) history.addDownloadHistory(r.nameSlice(), "");
        c.mpv.torrent_remove(state.torrentSession(), id);
        // STABLE-SLOT model: torrent ids are never renumbered on remove, so
        // other handles stay valid — only clear the one that was deleted.
        for (state.app.players.items) |p| {
            if (p.current_torrent_id == id) {
                p.current_torrent_id = -1;
                p.torrent_is_ready = false;
                p.has_metadata = false;
                _ = c.mpv.mpv_command_string(p.mpv_ctx, "stop");
                // Also tear down the stream proxy — otherwise its accept-loop
                // thread + port linger after the torrent is deleted.
                const stream_proxy = @import("../player/stream_proxy.zig");
                if (p.proxy_handle.isValid()) {
                    stream_proxy.stopProxy(p.proxy_handle);
                    p.proxy_handle = stream_proxy.INVALID_HANDLE;
                }
            }
        }
    } else if (r.hasHistory()) {
        history.removeDownloadHistory(@intCast(r.hist_idx));
    }
    rows_dirty.store(true, .release);
    expanded_key_len = 0;
}

/// Expanded panel. Returns true if it performed a mutation that invalidates the
/// row array (the caller must stop iterating).
fn renderExpanded(r: *const tp.Row) bool {
    if (r.hasTorrent() and c.mpv.torrent_is_alive(state.torrentSession(), r.torrent_id) != 0) {
        renderExpandedFiles(r.torrent_id);
    }

    if (r.hasFile()) {
        var frow = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = rowId(r),
            .expand = .horizontal,
            .background = true,
            .color_fill = dvui.Color{ .r = 15, .g = 15, .b = 22, .a = 255 },
            .padding = .{ .x = 18, .y = 6, .w = 10, .h = 6 },
            .border = .{ .x = 3, .y = 0, .w = 0, .h = 1 },
            .color_border = theme.colors.accent,
        });
        defer frow.deinit();

        _ = dvui.label(@src(), "On disk", .{}, .{
            .id_extra = rowId(r),
            .expand = .horizontal,
            .color_text = theme.colors.text_tertiary,
            .gravity_y = 0.5,
        });

        // User-triggered VirusTotal check (single files only — a folder has no
        // one hash). Streams SHA-256/MD5 on a worker, then opens the report.
        if (!r.is_dir) {
            const hashing = VtHash.busy.load(.acquire);
            if (dvui.button(@src(), if (hashing) "Hashing…" else "Verify on VirusTotal", .{}, .{
                .id_extra = rowId(r),
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_text = if (hashing) theme.colors.text_tertiary else theme.colors.text_secondary,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
                .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
                .gravity_y = 0.5,
            }) and !hashing) {
                const save_path = state.app.save_path_buf[0..state.app.save_path_len];
                var vp: [1024]u8 = undefined;
                if (std.fmt.bufPrint(&vp, "{s}/{s}", .{ save_path, r.diskSlice() })) |full| {
                    startVtHash(full);
                } else |_| {}
            }
        }

        if (components.confirmDangerButton(@src(), "Delete files from disk", rowId(r))) {
            const save_path = state.app.save_path_buf[0..state.app.save_path_len];
            var dp: [1024]u8 = undefined;
            if (std.fmt.bufPrintZ(&dp, "{s}/{s}", .{ save_path, r.diskSlice() })) |del| {
                if (r.is_dir)
                    io_global.cwdDeleteTree(del) catch {}
                else
                    io_global.cwdDeleteFile(del) catch {};
                browse_path_changed = true;
                rows_dirty.store(true, .release);
                expanded_key_len = 0;
                state.showToast("Deleted");
                return true;
            } else |_| {}
        }
    }
    return false;
}

/// Human-readable status / meta line under the name.
fn metaLine(r: *const tp.Row, st: tp.Status, buf: []u8) []const u8 {
    const pct: u8 = @intFromFloat(std.math.clamp(r.progress * 100.0, 0.0, 100.0));
    var sz: [24]u8 = undefined;
    return switch (st) {
        .downloading => std.fmt.bufPrint(buf, "↓{s} · {d}% · {d} seeds", .{ fmtRate(r.dl_rate, &sz), pct, r.seeds }) catch "Downloading",
        .fetching => "Fetching metadata…",
        .paused => std.fmt.bufPrint(buf, "Paused · {d}%", .{pct}) catch "Paused",
        .errored => "Error",
        .seeding => if (r.size > 0)
            std.fmt.bufPrint(buf, "Seeding · {s}", .{fmtSize(r.size, &sz)}) catch "Seeding"
        else
            "Seeding",
        .complete => "Complete",
        .on_disk => if (r.is_dir)
            "Folder"
        else if (r.size > 0)
            std.fmt.bufPrint(buf, "{s}", .{fmtSize(r.size, &sz)}) catch "On disk"
        else
            "On disk",
        .archived => "Downloaded",
    };
}

fn fmtSize(bytes: u64, buf: []u8) []const u8 {
    const b = @as(f64, @floatFromInt(bytes));
    if (b >= 1073741824.0) return std.fmt.bufPrint(buf, "{d:.1} GB", .{b / 1073741824.0}) catch "?";
    if (b >= 1048576.0) return std.fmt.bufPrint(buf, "{d:.0} MB", .{b / 1048576.0}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.0} KB", .{b / 1024.0}) catch "?";
}

fn fmtRate(bytes_per_sec: u32, buf: []u8) []const u8 {
    const b = @as(f64, @floatFromInt(bytes_per_sec));
    if (b >= 1048576.0) return std.fmt.bufPrint(buf, "{d:.1} MB/s", .{b / 1048576.0}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.0} KB/s", .{b / 1024.0}) catch "?";
}

// ══════════════════════════════════════════════════════════
// HTTP DOWNLOAD ROWS (segmented downloader — services/download_engine.zig)
// ══════════════════════════════════════════════════════════

fn httpStatusColor(st: httpdl.engine.Status) dvui.Color {
    return switch (st) {
        .probing, .running => theme.colors.accent,
        .queued, .paused => theme.colors.text_tertiary,
        .failed => theme.colors.danger,
        .done => theme.colors.success,
        .empty, .canceling => theme.colors.text_tertiary,
    };
}

/// Draws the active HTTP downloads above the unified list. Returns how many
/// rows were shown (feeds the shared empty-state check). Snapshot is copied
/// out under the engine's mutex — no shared buffers are aliased during draw.
fn renderHttpRows() usize {
    // HTTP rows are "active transfers": show them on All and Downloading.
    if (filter != .all and filter != .downloading) return 0;

    // Snap array at module scope would be wasteful; it's small (~16 × ~700B)
    // but still too big for comfort on the UI stack alongside dvui's frames —
    // keep it static like the stage_* arrays above.
    const S = struct {
        var snaps: [httpdl.engine.MAX_DOWNLOADS]httpdl.engine.Snap = undefined;
    };
    const n = httpdl.engine.snapshot(&S.snaps);
    for (S.snaps[0..n], 0..) |*s, i| renderHttpRow(s, i);
    return n;
}

fn renderHttpRow(s: *const httpdl.engine.Snap, i: usize) void {
    const rid: usize = 46000 + s.idx * 32;
    const st = s.status;
    const active = st == .running or st == .probing;

    const row_bg = if (i % 2 == 0)
        dvui.Color{ .r = 18, .g = 18, .b = 26, .a = 255 }
    else
        dvui.Color{ .r = 21, .g = 21, .b = 30, .a = 255 };

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = rid,
        .expand = .horizontal,
        .background = true,
        .color_fill = row_bg,
        .padding = .{ .x = 10, .y = 7, .w = 10, .h = 7 },
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .color_border = dvui.Color{ .r = 30, .g = 30, .b = 45, .a = 140 },
    });
    defer row.deinit();

    // Status bar (colored left edge) — same visual language as torrent rows.
    {
        var bar = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = rid,
            .min_size_content = .{ .w = 3, .h = 0 },
            .expand = .vertical,
            .background = true,
            .color_fill = httpStatusColor(st),
            .corner_radius = dvui.Rect.all(2),
            .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
            .gravity_y = 0.5,
        });
        bar.deinit();
    }

    _ = dvui.icon(@src(), "", icons.tvg.lucide.download, .{}, .{
        .id_extra = rid,
        .color_text = httpStatusColor(st),
        .min_size_content = .{ .w = 14, .h = 14 },
        .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
        .gravity_y = 0.5,
    });

    // Name + progress + segment strip + meta
    {
        var blk = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = rid,
            .expand = .horizontal,
            .gravity_y = 0.5,
        });
        defer blk.deinit();

        var nm_buf: [256]u8 = undefined;
        const shown_name = safeUtf8Buf(s.nameSlice(), &nm_buf);
        _ = dvui.label(@src(), "{s}", .{if (shown_name.len > 0) shown_name else "(download)"}, .{
            .id_extra = rid,
            .gravity_x = 0.0,
            .color_text = if (st == .paused or st == .queued) theme.colors.text_secondary else theme.colors.text_primary,
        });

        const frac_total: f32 = if (s.total > 0)
            @min(@as(f32, @floatFromInt(s.done)) / @as(f32, @floatFromInt(s.total)), 1.0)
        else
            0;

        if (active or st == .paused or st == .failed) {
            var frac = frac_total;
            _ = dvui.slider(@src(), .{ .fraction = &frac }, .{
                .id_extra = rid,
                .expand = .horizontal,
                .min_size_content = .{ .w = 10, .h = 4 },
                .color_fill = dvui.Color{ .r = 35, .g = 35, .b = 50, .a = 255 },
                .color_text = httpStatusColor(st),
                .corner_radius = dvui.Rect.all(2),
                .margin = .{ .x = 0, .y = 3, .w = 0, .h = 0 },
            });

            // Segment mini-bars: one small fill per connection.
            if (s.seg_count > 1) {
                var segrow = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = rid + 1,
                    .margin = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
                });
                defer segrow.deinit();
                for (0..s.seg_count) |k| {
                    var cell = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .id_extra = rid + 2 + k,
                        .min_size_content = .{ .w = 26, .h = 3 },
                        .background = true,
                        .color_fill = dvui.Color{ .r = 35, .g = 35, .b = 50, .a = 255 },
                        .corner_radius = dvui.Rect.all(1),
                        .margin = .{ .x = 0, .y = 0, .w = 3, .h = 0 },
                    });
                    const w: f32 = 26.0 * @min(s.seg_frac[k], 1.0);
                    if (w > 0.5) {
                        var fill = dvui.box(@src(), .{ .dir = .horizontal }, .{
                            .id_extra = rid + 2 + k,
                            .min_size_content = .{ .w = w, .h = 3 },
                            .background = true,
                            .color_fill = httpStatusColor(st),
                            .corner_radius = dvui.Rect.all(1),
                        });
                        fill.deinit();
                    }
                    cell.deinit();
                }
            }
        }

        // Meta line: speed · % · ETA · connections (or state text).
        var meta_buf: [128]u8 = undefined;
        const pct: u8 = @intFromFloat(std.math.clamp(frac_total * 100.0, 0.0, 100.0));
        var sp: [24]u8 = undefined;
        var eb: [24]u8 = undefined;
        var szb: [24]u8 = undefined;
        const meta: []const u8 = switch (st) {
            .queued => "Queued",
            .probing => "Connecting…",
            .running => blk2: {
                const eta_txt: []const u8 = if (s.etaSecs()) |secs| httpdl.dp.fmtEta(secs, &eb) else "—";
                break :blk2 std.fmt.bufPrint(&meta_buf, "↓{s} · {d}% · ETA {s} · {d}× conn", .{
                    httpdl.dp.fmtSpeed(s.rate, &sp), pct, eta_txt, s.seg_count,
                }) catch "Downloading";
            },
            .paused => std.fmt.bufPrint(&meta_buf, "Paused · {d}%", .{pct}) catch "Paused",
            .failed => std.fmt.bufPrint(&meta_buf, "Failed: {s}", .{s.errSlice()}) catch "Failed",
            .done => if (s.total > 0)
                std.fmt.bufPrint(&meta_buf, "Complete · {s}", .{httpdl.dp.fmtBytes(s.total, &szb)}) catch "Complete"
            else
                "Complete",
            .empty, .canceling => "",
        };
        _ = dvui.label(@src(), "{s}", .{meta}, .{
            .id_extra = rid,
            .expand = .horizontal,
            .color_text = if (st == .failed) theme.colors.danger else theme.colors.text_tertiary,
            .margin = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
        });
    }

    // ── Actions ──
    var acts = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = rid,
        .min_size_content = .{ .w = 190, .h = 0 },
        .gravity_y = 0.5,
    });
    defer acts.deinit();

    // Pause / resume.
    if (active or st == .queued) {
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.pause, .{}, .{}, .{
            .id_extra = rid,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.text_secondary,
            .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
            .gravity_y = 0.5,
        })) {
            httpdl.engine.pause(s.idx, s.token);
        }
    } else if (st == .paused or st == .failed) {
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.play, .{}, .{}, .{
            .id_extra = rid,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.accent,
            .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
            .gravity_y = 0.5,
        })) {
            httpdl.engine.resumeDl(s.idx, s.token);
        }
    }

    // Remove: cancel (active — deletes partial) or dismiss (finished rows;
    // keeps the completed file on disk, drops partials of paused/failed).
    if (components.confirmDangerButton(@src(), "Remove", rid)) {
        if (active or st == .queued)
            httpdl.engine.cancel(s.idx, s.token)
        else
            httpdl.engine.dismiss(s.idx, s.token);
        rows_dirty.store(true, .release);
    }
}

// ══════════════════════════════════════════════════════════
// EXPANDED FILE LIST (per-torrent, unchanged)
// ══════════════════════════════════════════════════════════

fn renderExpandedFiles(torrent_id: i32) void {
    const ui: usize = @intCast(torrent_id);
    const f_count = c.mpv.torrent_get_file_count(state.torrentSession(), torrent_id);
    if (f_count <= 0) return;

    // Header for expanded section
    {
        var xhdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = dvui.Color{ .r = 14, .g = 14, .b = 22, .a = 255 },
            .padding = .{ .x = 18, .y = 4, .w = 10, .h = 4 },
            .border = .{ .x = 3, .y = 0, .w = 0, .h = 1 },
            .color_border = theme.colors.accent,
        });
        defer xhdr.deinit();
        _ = dvui.label(@src(), "Files", .{}, .{ .color_text = theme.colors.text_tertiary, .expand = .horizontal });
        _ = dvui.label(@src(), "Size", .{}, .{ .color_text = theme.colors.text_tertiary, .min_size_content = .{ .w = 56, .h = 0 } });
        _ = dvui.label(@src(), "Progress", .{}, .{ .color_text = theme.colors.text_tertiary, .min_size_content = .{ .w = 80, .h = 0 } });
        _ = dvui.label(@src(), "Priority", .{}, .{ .color_text = theme.colors.text_tertiary });
    }

    var f_idx: i32 = 0;
    while (f_idx < f_count) : (f_idx += 1) {
        const fi: usize = @intCast(f_idx);
        const cid = fi + ui * 1000 + 31000;

        var f_name: [256]u8 = undefined;
        c.mpv.torrent_get_file_name(state.torrentSession(), torrent_id, f_idx, &f_name, 256);
        const f_len = std.mem.indexOfScalar(u8, &f_name, 0) orelse 255;
        const f_prog = c.mpv.torrent_get_file_progress(state.torrentSession(), torrent_id, f_idx);
        const f_size = c.mpv.torrent_get_file_size(state.torrentSession(), torrent_id, f_idx);

        var frow = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = cid,
            .expand = .horizontal,
            .background = true,
            .color_fill = dvui.Color{ .r = 15, .g = 15, .b = 22, .a = 255 },
            .padding = .{ .x = 18, .y = 6, .w = 10, .h = 6 },
            .border = .{ .x = 3, .y = 0, .w = 0, .h = 1 },
            .color_border = theme.colors.accent,
            .gravity_y = 0.5,
        });
        defer frow.deinit();

        // Play file
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.play, .{}, .{}, .{
            .id_extra = cid + 100,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.success,
            .padding = .{ .x = 3, .y = 3, .w = 6, .h = 3 },
            .gravity_y = 0.5,
        })) {
            if (state.app.active_player_idx < state.app.players.items.len) {
                const p = state.app.players.items[state.app.active_player_idx];
                p.current_torrent_id = torrent_id;
                p.selected_file_idx = f_idx;
                p.torrent_is_ready = false;
                p.has_metadata = true;
                p.last_load_time = 0;
            }
        }

        // Filename — libtorrent file names are byte strings (Shift-JIS/latin-1/
        // truncated mid-codepoint), and invalid UTF-8 drawn to dvui panics the
        // whole app. Validate like the sibling displayName() path does.
        _ = dvui.label(@src(), "{s}", .{safeUtf8(f_name[0..f_len])}, .{
            .id_extra = cid + 200,
            .expand = .horizontal,
            .color_text = theme.colors.text_primary,
            .gravity_y = 0.5,
        });

        // Size
        {
            var sbuf: [16]u8 = undefined;
            const mb = @as(f64, @floatFromInt(f_size)) / 1048576.0;
            const s = if (mb > 1024)
                std.fmt.bufPrintZ(&sbuf, "{d:.1}G", .{mb / 1024.0}) catch "?"
            else
                std.fmt.bufPrintZ(&sbuf, "{d:.0}M", .{mb}) catch "?";
            _ = dvui.label(@src(), "{s}", .{s}, .{
                .id_extra = cid + 300,
                .color_text = theme.colors.text_tertiary,
                .min_size_content = .{ .w = 56, .h = 0 },
                .gravity_y = 0.5,
            });
        }

        // Progress
        {
            var pct = @as(f32, @floatCast(f_prog));
            _ = dvui.slider(@src(), .{ .fraction = &pct }, .{
                .id_extra = cid + 400,
                .min_size_content = .{ .w = 80, .h = 5 },
                .color_fill = dvui.Color{ .r = 30, .g = 30, .b = 45, .a = 255 },
                .color_text = theme.colors.accent,
                .corner_radius = dvui.Rect.all(2),
                .gravity_y = 0.5,
            });
        }

        // Priority
        if (dvui.button(@src(), "Skip", .{}, .{
            .id_extra = cid + 500,
            .color_fill = dvui.Color{ .r = 50, .g = 20, .b = 20, .a = 255 },
            .color_text = theme.colors.text_secondary,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
            .margin = .{ .x = 4, .y = 0, .w = 2, .h = 0 },
            .gravity_y = 0.5,
        })) {
            c.mpv.torrent_set_file_priority(state.torrentSession(), torrent_id, f_idx, 0);
        }

        if (dvui.button(@src(), "High", .{}, .{
            .id_extra = cid + 600,
            .color_fill = dvui.Color{ .r = 20, .g = 45, .b = 20, .a = 255 },
            .color_text = theme.colors.success,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
            .margin = .{ .x = 0, .y = 0, .w = 2, .h = 0 },
            .gravity_y = 0.5,
        })) {
            c.mpv.torrent_set_file_priority(state.torrentSession(), torrent_id, f_idx, 7);
        }
    }
}

// ══════════════════════════════════════════════════════════
// FOLDER DRILL-DOWN — plain directory browse (subdir only)
// ══════════════════════════════════════════════════════════

fn renderFolderBrowse() void {
    const save_path = state.app.save_path_buf[0..state.app.save_path_len];
    var effective_buf: [1024]u8 = undefined;
    const effective_path = std.fmt.bufPrintZ(&effective_buf, "{s}/{s}", .{ save_path, browse_subdir_buf[0..browse_subdir_len] }) catch save_path;

    // Rescan immediately on a path change, otherwise at most every 5s.
    const now = io_global.timestamp();
    if (browse_path_changed or now - cached_files_last_scan >= 5) {
        cached_files_last_scan = now;
        browse_path_changed = false;
        triggerFileScan(effective_path); // non-blocking — bg thread updates cache
    }

    // Snapshot file-cache state under the mutex so the bg scan thread
    // can't update it mid-render (the bg thread writes under files_mutex).
    files_mutex.lock();
    const snap_count = cached_files_count;
    const snap_error = cached_files_error;
    files_mutex.unlock();

    // Path bar — clickable breadcrumb opens folder in Finder/Files
    {
        var prow = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = dvui.Color{ .r = 16, .g = 16, .b = 24, .a = 255 },
            .padding = .{ .x = 6, .y = 4, .w = 10, .h = 4 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 2 },
        });
        defer prow.deinit();

        var lbuf: [256]u8 = undefined;
        const lbl = std.fmt.bufPrintZ(&lbuf, "  {s}  ({d} items)", .{ effective_path, snap_count }) catch effective_path;
        var lsafe: [256]u8 = undefined;
        if (dvui.button(@src(), safeUtf8Buf(lbl, &lsafe), .{}, .{
            .expand = .horizontal,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.text_secondary,
            .border = dvui.Rect.all(0),
            .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
            .gravity_y = 0.5,
        })) {
            openInFileManager(effective_path);
        }
        if (dvui.button(@src(), "← Up", .{}, .{
            .color_fill = dvui.Color{ .r = 35, .g = 35, .b = 50, .a = 255 },
            .color_text = theme.colors.accent,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
            .gravity_y = 0.5,
        })) {
            if (std.mem.lastIndexOfScalar(u8, browse_subdir_buf[0..browse_subdir_len], '/')) |pos| {
                browse_subdir_len = pos;
            } else {
                browse_subdir_len = 0;
            }
            browse_path_changed = true;
            rows_dirty.store(true, .release);
        }
    }

    if (snap_count == 0) {
        if (snap_error) {
            _ = dvui.label(@src(), "Cannot open folder", .{}, .{
                .color_text = theme.colors.danger,
                .padding = .{ .x = 14, .y = 14, .w = 0, .h = 0 },
            });
        } else {
            _ = dvui.label(@src(), "Folder is empty.", .{}, .{
                .color_text = theme.colors.text_secondary,
                .padding = .{ .x = 14, .y = 14, .w = 0, .h = 0 },
            });
        }
        return;
    }

    var fi: usize = 0;
    while (fi < snap_count) : (fi += 1) {
        const name = cached_files_names[fi][0..cached_files_name_lens[fi]];
        const is_dir = cached_files_is_dir[fi];
        const fsize = cached_files_sizes[fi];
        const is_video = isVideoExt(name);
        const is_audio = isAudioExt(name);

        const row_bg = if (fi % 2 == 0)
            dvui.Color{ .r = 18, .g = 18, .b = 26, .a = 255 }
        else
            dvui.Color{ .r = 21, .g = 21, .b = 30, .a = 255 };

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = fi + 20000,
            .expand = .horizontal,
            .background = true,
            .color_fill = row_bg,
            .padding = .{ .x = 10, .y = 7, .w = 10, .h = 7 },
            .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
            .color_border = dvui.Color{ .r = 30, .g = 30, .b = 45, .a = 140 },
        });
        defer row.deinit();

        // Icon
        const ficon = if (is_dir) icons.tvg.lucide.folder else if (is_video) icons.tvg.lucide.film else if (is_audio) icons.tvg.lucide.music else icons.tvg.lucide.file;
        const icol = if (is_dir) dvui.Color{ .r = 100, .g = 170, .b = 255, .a = 255 } else if (is_video) dvui.Color{ .r = 100, .g = 220, .b = 120, .a = 255 } else if (is_audio) dvui.Color{ .r = 255, .g = 180, .b = 80, .a = 255 } else theme.colors.text_tertiary;
        _ = dvui.icon(@src(), "", ficon, .{}, .{
            .id_extra = fi + 20100,
            .color_text = icol,
            .min_size_content = .{ .w = 14, .h = 14 },
            .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
            .gravity_y = 0.5,
        });

        // Name. safeUtf8Buf (not the safeUtf8 inside displayName): `name` aliases
        // the cached_files buffer that the bg scan worker rewrites under
        // files_mutex, so validating a slice into the live buffer can still let
        // dvui re-read mutated bytes mid-frame. Snapshot a stable copy here.
        var nm_buf: [256]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{safeUtf8Buf(displayName(name), &nm_buf)}, .{
            .id_extra = fi + 20200,
            .expand = .horizontal,
            .color_text = theme.colors.text_primary,
            .gravity_y = 0.5,
        });

        // Sticky action overlay — fixed width so actions always visible
        var acts = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = fi + 20700,
            .background = true,
            .color_fill = row_bg,
            .border = .{ .x = 1, .y = 0, .w = 0, .h = 0 },
            .color_border = dvui.Color{ .r = 80, .g = 60, .b = 100, .a = 80 },
            .padding = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
            .margin = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 110, .h = 0 },
        });
        defer acts.deinit();

        if (!is_dir and fsize > 0) {
            var sbuf: [16]u8 = undefined;
            _ = dvui.label(@src(), "{s}", .{fmtSize(fsize, &sbuf)}, .{
                .id_extra = fi + 20300,
                .color_text = theme.colors.text_tertiary,
                .min_size_content = .{ .w = 38, .h = 0 },
                .gravity_y = 0.5,
                .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
            });
        }

        if (is_dir) {
            if (dvui.button(@src(), "Open", .{}, .{
                .id_extra = fi + 20400,
                .color_fill = theme.colors.accent,
                .color_text = dvui.Color{ .r = 10, .g = 10, .b = 15, .a = 255 },
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
                .gravity_y = 0.5,
            })) {
                if (std.fmt.bufPrint(browse_subdir_buf[browse_subdir_len..], "/{s}", .{name})) |app| {
                    browse_subdir_len += app.len;
                } else |_| {}
                browse_path_changed = true;
            }
        } else {
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.play, .{}, .{}, .{
                .id_extra = fi + 20500,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_text = theme.colors.success,
                .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
                .gravity_y = 0.5,
            })) {
                var fp: [1024]u8 = undefined;
                if (std.fmt.bufPrintZ(&fp, "{s}/{s}", .{ effective_path, name })) |full| {
                    if (state.app.active_player_idx < state.app.players.items.len) {
                        state.app.players.items[state.app.active_player_idx].load_file(full);
                        @import("../player/watch_history.zig").savePosition(name, 1.0, full);
                        state.gotoPlayer();
                    }
                } else |_| {}
            }
        }

        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"trash-2", .{}, .{}, .{
            .id_extra = fi + 20600,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = dvui.Color{ .r = 160, .g = 60, .b = 60, .a = 200 },
            .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
            .gravity_y = 0.5,
        })) {
            var dp: [1024]u8 = undefined;
            if (std.fmt.bufPrintZ(&dp, "{s}/{s}", .{ effective_path, name })) |del| {
                if (is_dir) io_global.cwdDeleteTree(del) catch {} else io_global.cwdDeleteFile(del) catch {};
                browse_path_changed = true;
                rows_dirty.store(true, .release);
                state.showToast("Deleted");
            } else |_| {}
        }
    }
}

// ══════════════════════════════════════════════════════════
// HELPERS
// ══════════════════════════════════════════════════════════

// ── VirusTotal verify (user-triggered, hash-only — nothing is uploaded) ──
//
// A worker thread streams the file through SHA-256 + MD5 (files can be many
// GB, so never slurp), logs both digests to the in-app Logs tab, and hands the
// SHA-256 back to the UI thread, which opens the virustotal.com report page in
// the system browser. The app itself never contacts VirusTotal.
const VtHash = struct {
    var busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    var done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    var ok: bool = false; // written before done.release, read after done.acquire
    var path_buf: [1024]u8 = undefined;
    var path_len: usize = 0;
    var sha_hex: [64]u8 = undefined;

    fn worker() void {
        const Self = @This();
        const logs = @import("../core/logs.zig");
        const alloc = @import("../core/alloc.zig").allocator;
        Self.ok = false;
        defer {
            Self.done.store(true, .release);
            Self.busy.store(false, .release);
            dvui.refresh(null, @src(), null);
        }

        const path = Self.path_buf[0..Self.path_len];
        // 256KB stream buffer — heap, never on a spawned thread's stack.
        const buf = alloc.alloc(u8, 256 * 1024) catch return;
        defer alloc.free(buf);

        const file = io_global.openFileAbsolute(path, .{}) catch {
            logs.pushLog("error", "virustotal", "Could not open file for hashing", true);
            return;
        };
        defer io_global.closeFile(file);

        var sha = std.crypto.hash.sha2.Sha256.init(.{});
        var md5 = std.crypto.hash.Md5.init(.{});
        while (true) {
            const n = io_global.read(file, buf) catch {
                logs.pushLog("error", "virustotal", "Read error while hashing", true);
                return;
            };
            if (n == 0) break;
            sha.update(buf[0..n]);
            md5.update(buf[0..n]);
        }

        var sha_dig: [32]u8 = undefined;
        var md5_dig: [16]u8 = undefined;
        sha.final(&sha_dig);
        md5.final(&md5_dig);
        hexLower(&sha_dig, &Self.sha_hex);
        var md5_hex: [32]u8 = undefined;
        hexLower(&md5_dig, &md5_hex);

        // Log both digests so the user can copy them from the Logs tab.
        var line: [128]u8 = undefined;
        if (std.fmt.bufPrint(&line, "SHA-256: {s}", .{Self.sha_hex})) |t| {
            logs.pushLog("info", "virustotal", t, false);
        } else |_| {}
        if (std.fmt.bufPrint(&line, "MD5: {s}", .{md5_hex})) |t| {
            logs.pushLog("info", "virustotal", t, false);
        } else |_| {}

        Self.ok = true;
    }
};

fn hexLower(bytes: []const u8, out: []u8) void {
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
}

/// Explicit user action only — never called automatically.
fn startVtHash(path: []const u8) void {
    if (VtHash.busy.swap(true, .acq_rel)) return; // already hashing
    VtHash.done.store(false, .release);
    // Copy the path into the struct static BEFORE spawning — never hand a
    // detached thread a pointer into a frame-local buffer.
    const plen = @min(path.len, VtHash.path_buf.len);
    @memcpy(VtHash.path_buf[0..plen], path[0..plen]);
    VtHash.path_len = plen;
    const t = std.Thread.spawn(.{}, VtHash.worker, .{}) catch {
        VtHash.busy.store(false, .release);
        state.showToast("Could not start hashing");
        return;
    };
    t.detach();
    state.showToast("Hashing for VirusTotal…");
}

/// UI thread, once per frame: open the VT file report once the worker is done.
fn consumeVtHashResult() void {
    if (!VtHash.done.load(.acquire)) return;
    VtHash.done.store(false, .release);
    if (VtHash.ok) {
        var url_buf: [128]u8 = undefined;
        @import("../ui/settings.zig").openExternal(vt_pure.fileUrl(VtHash.sha_hex[0..], &url_buf));
        state.showToast("Opened VirusTotal report");
    } else {
        state.showToast("Hashing failed — see Logs");
    }
}

// Open a directory in the OS file manager (Finder / Explorer / xdg-open).
fn openInFileManager(path: []const u8) void {
    const builtin = @import("builtin");
    const cmd: []const u8 = switch (builtin.target.os.tag) {
        .macos => "open",
        .windows => "explorer",
        else => "xdg-open",
    };
    var child = io_global.Child.init(&.{ cmd, path }, @import("../core/alloc.zig").allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch {};
}

// Strip scrape-site prefixes like "www.uindex.org - " or "[rarbg.to] - " from filenames.
fn displayName(name: []const u8) []const u8 {
    // Pattern 1: leading "www.*.tld[.tld] <sep> "
    if (std.mem.startsWith(u8, name, "www.")) {
        if (std.mem.indexOfAny(u8, name, " -_")) |_| {
            // Find first ' - ' (space-dash-space) or ' -' separator after TLD
            if (std.mem.indexOf(u8, name, " - ")) |sep| {
                const after = name[sep + 3 ..];
                if (after.len > 0) return safeUtf8(std.mem.trimStart(u8, after, " -_"));
            }
        }
    }
    // Pattern 2: bracket tag at start "[site] - title" or "[site] title"
    if (name.len > 0 and name[0] == '[') {
        if (std.mem.indexOfScalar(u8, name, ']')) |close| {
            const after = std.mem.trimStart(u8, name[close + 1 ..], " -_");
            if (after.len > 0) return safeUtf8(after);
        }
    }
    return safeUtf8(name);
}

// Extract display name from magnet dn= param, or truncate hash
fn extractDn(magnet: []const u8) []const u8 {
    if (std.mem.indexOf(u8, magnet, "dn=")) |pos| {
        const after = magnet[pos + 3 ..];
        const end = std.mem.indexOfScalar(u8, after, '&') orelse after.len;
        if (end > 0) return after[0..end];
    }
    if (std.mem.indexOf(u8, magnet, "btih:")) |pos| {
        const after = magnet[pos + 5 ..];
        const end = std.mem.indexOfScalar(u8, after, '&') orelse after.len;
        if (end > 0) return after[0..@min(end, 20)];
    }
    return if (magnet.len > 36) magnet[0..36] else magnet;
}

fn isVideoExt(name: []const u8) bool {
    const exts = [_][]const u8{ ".mp4", ".mkv", ".avi", ".webm", ".mov", ".flv", ".ts", ".wmv", ".m4v" };
    for (exts) |ext| if (name.len > ext.len and std.ascii.eqlIgnoreCase(name[name.len - ext.len ..], ext)) return true;
    return false;
}

fn isAudioExt(name: []const u8) bool {
    const exts = [_][]const u8{ ".mp3", ".flac", ".wav", ".ogg", ".m4a", ".opus", ".aac", ".wma" };
    for (exts) |ext| if (name.len > ext.len and std.ascii.eqlIgnoreCase(name[name.len - ext.len ..], ext)) return true;
    return false;
}

// ══════════════════════════════════════════════════════════
// FILE CACHE
// ══════════════════════════════════════════════════════════

const MAX_CACHED_FILES = 200;
const MAX_NAME_LEN = 256;

var cached_files_names: [MAX_CACHED_FILES][MAX_NAME_LEN]u8 = undefined;
var cached_files_name_lens: [MAX_CACHED_FILES]usize = std.mem.zeroes([MAX_CACHED_FILES]usize);
var cached_files_is_dir: [MAX_CACHED_FILES]bool = std.mem.zeroes([MAX_CACHED_FILES]bool);
var cached_files_sizes: [MAX_CACHED_FILES]u64 = std.mem.zeroes([MAX_CACHED_FILES]u64);
var cached_files_mtimes: [MAX_CACHED_FILES]i64 = std.mem.zeroes([MAX_CACHED_FILES]i64);
var cached_files_count: usize = 0;
var cached_files_last_scan: i64 = 0;
var cached_files_error: bool = false;
/// Which directory the cache currently holds. The unified list only merges the
/// cache when it holds the ROOT download dir — while the user is drilled into a
/// subfolder the cache holds that subfolder instead.
var cached_files_path_buf: [1024]u8 = std.mem.zeroes([1024]u8);
var cached_files_path_len: usize = 0;

var browse_subdir_buf: [1024]u8 = std.mem.zeroes([1024]u8);
var browse_subdir_len: usize = 0;
var browse_path_changed: bool = true;

// Background scan mutex — prevents render thread from blocking on dir I/O
var files_mutex: @import("../core/sync.zig").Mutex = .{};
var files_scanning: bool = false;
var files_scan_path_buf: [1024]u8 = std.mem.zeroes([1024]u8);
var files_scan_path_len: usize = 0;

fn bgRefreshFiles(_: void) void {
    files_mutex.lock();
    const plen = files_scan_path_len;
    var pbuf: [1024]u8 = undefined;
    @memcpy(pbuf[0..plen], files_scan_path_buf[0..plen]);
    files_mutex.unlock();

    const path = pbuf[0..plen];
    var cnt: usize = 0;
    var tmp_names: [MAX_CACHED_FILES][MAX_NAME_LEN]u8 = undefined;
    var tmp_lens: [MAX_CACHED_FILES]usize = std.mem.zeroes([MAX_CACHED_FILES]usize);
    var tmp_dirs: [MAX_CACHED_FILES]bool = std.mem.zeroes([MAX_CACHED_FILES]bool);
    var tmp_sizes: [MAX_CACHED_FILES]u64 = std.mem.zeroes([MAX_CACHED_FILES]u64);
    var tmp_mtimes: [MAX_CACHED_FILES]i64 = std.mem.zeroes([MAX_CACHED_FILES]i64);

    var dir = io_global.cwdOpenDir(path, .{ .iterate = true }) catch {
        files_mutex.lock();
        cached_files_count = 0;
        cached_files_error = true;
        cached_files_path_len = plen;
        @memcpy(cached_files_path_buf[0..plen], path);
        files_scanning = false;
        files_mutex.unlock();
        rows_dirty.store(true, .release);
        return;
    };
    defer dir.close(io_global.io());
    var iter = dir.iterate();
    while (iter.next(io_global.io()) catch null) |entry| {
        if (cnt >= MAX_CACHED_FILES) break;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (std.mem.endsWith(u8, entry.name, ".torrent")) continue;
        if (std.mem.endsWith(u8, entry.name, ".parts")) continue;
        // In-flight HTTP downloads (data + resume sidecar) — the downloader
        // shows these as live rows; listing them as files would double them.
        if (std.mem.endsWith(u8, entry.name, ".opal-part")) continue;
        if (std.mem.endsWith(u8, entry.name, ".opal-part.json")) continue;
        const nlen = @min(entry.name.len, MAX_NAME_LEN);
        @memcpy(tmp_names[cnt][0..nlen], entry.name[0..nlen]);
        tmp_lens[cnt] = nlen;
        tmp_dirs[cnt] = entry.kind == .directory;
        tmp_sizes[cnt] = 0;
        tmp_mtimes[cnt] = 0;
        // mtime feeds the unified list's "most recently finished first" sort.
        if (dir.statFile(io_global.io(), entry.name, .{}) catch null) |st| {
            if (entry.kind == .file) tmp_sizes[cnt] = st.size;
            tmp_mtimes[cnt] = @intCast(@divTrunc(st.mtime.nanoseconds, 1_000_000_000));
        }
        cnt += 1;
    }

    files_mutex.lock();
    cached_files_names = tmp_names;
    cached_files_name_lens = tmp_lens;
    cached_files_is_dir = tmp_dirs;
    cached_files_sizes = tmp_sizes;
    cached_files_mtimes = tmp_mtimes;
    cached_files_count = cnt;
    cached_files_error = false;
    cached_files_path_len = plen;
    @memcpy(cached_files_path_buf[0..plen], path);
    files_scanning = false;
    files_mutex.unlock();

    // A fresh listing changes the merge — force a rebuild on the next frame.
    rows_dirty.store(true, .release);
}

fn triggerFileScan(path: []const u8) void {
    files_mutex.lock();
    if (files_scanning) {
        files_mutex.unlock();
        return;
    }
    files_scanning = true;
    const plen = @min(path.len, files_scan_path_buf.len);
    @memcpy(files_scan_path_buf[0..plen], path[0..plen]);
    files_scan_path_len = plen;
    files_mutex.unlock();
    const t = std.Thread.spawn(.{}, bgRefreshFiles, .{{}}) catch {
        files_mutex.lock();
        files_scanning = false;
        files_mutex.unlock();
        return;
    };
    t.detach();
}

// Watch history is now unified in player/watch_history.zig (persistent, shared
// with the History page) — the old session-only store here was removed.
