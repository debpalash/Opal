//! Internet Radio tab — keyless station discovery via the RadioBrowser API,
//! streamed straight through mpv. Structurally a sibling of podcasts.zig, one
//! level shallower: search → station list → play. All parsing lives in
//! radio_pure.zig (tested); this module owns the async fetch worker,
//! thread-safety, and dvui rendering.
//!
//! Flow:
//!   searchRadio(q)  → curl all.api.radio-browser.info/json/stations/search?name=…
//!                     → pure.parseStations → state.app.radio.results[]
//!   playStation(i)  → browser.loadContentDirect(url_resolved | url) → mpv,
//!                     then a best-effort click-count ping to /json/url/{uuid}.

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const logs = @import("../core/logs.zig");
const pure = @import("radio_pure.zig");
const io = @import("../core/io_global.zig");
const rate_limit = @import("../core/rate_limit.zig");
const safeUtf8Buf = @import("../core/text.zig").safeUtf8Buf;

const alloc = @import("../core/alloc.zig").allocator;

const agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0";

// ── Thread-safety ──
// The detached search worker publishes into state.app.radio.* under
// `parse_mutex`, and a monotonic `search_gen` drops stale results so fast
// re-searches never show out-of-order data (mirrors podcasts.zig / anime.zig).
// The `is_loading` flag is atomic (read by UI + remote threads, written by the
// worker).
var parse_mutex: @import("../core/sync.zig").Mutex = .{};
var search_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// Query snapshot handed to the detached search worker (never read the mutable
// UI search_buf from the thread).
var query_buf: [256]u8 = undefined;
var query_len: usize = 0;

// ══════════════════════════════════════════════════════════
// Search — RadioBrowser station search
// ══════════════════════════════════════════════════════════

pub fn searchRadio(query: []const u8) void {
    if (query.len == 0) return;

    state.app.radio.is_loading.store(true, .release);
    state.app.radio.fetch_error = false;

    const my_gen = search_gen.fetchAdd(1, .acq_rel) + 1;

    // Snapshot the query BEFORE spawning — a newer search overwrites query_buf.
    const n = @min(query.len, query_buf.len);
    @memcpy(query_buf[0..n], query[0..n]);
    query_len = n;

    if (std.Thread.spawn(.{}, searchWorker, .{my_gen})) |t| {
        t.detach(); // never joined — detach to avoid leaking the handle
    } else |_| {
        state.app.radio.is_loading.store(false, .release);
    }
}

fn searchWorker(my_gen: u32) void {
    defer state.app.radio.is_loading.store(false, .release);

    // Re-snapshot the query — a newer search may overwrite query_buf mid-flight.
    var local: [256]u8 = undefined;
    const qlen = @min(query_len, local.len);
    @memcpy(local[0..qlen], query_buf[0..qlen]);

    // Percent-encode the term (space, &, =, #, ?, %, + at minimum).
    var enc: [768]u8 = undefined;
    const encoded = percentEncode(local[0..qlen], &enc);

    var url_buf: [1024]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buf,
        "https://all.api.radio-browser.info/json/stations/search?name={s}&limit=30&hidebroken=true&order=votes&reverse=true",
        .{encoded},
    ) catch return;

    // Shared public directory — be a polite citizen (≤ 1 req/sec).
    rate_limit.acquire("radiobrowser", 1.0);

    const body = curl(url, 512 * 1024) orelse {
        state.app.radio.fetch_error = true;
        return;
    };
    defer alloc.free(body);

    // Bail if superseded while curl was in flight.
    if (search_gen.load(.acquire) != my_gen) return;

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (search_gen.load(.acquire) != my_gen) return; // re-check under lock

    const count = pure.parseStations(body, &state.app.radio.results);
    state.app.radio.result_count = count;
    if (count == 0) logs.pushLog("info", "radio", "Search returned no stations", false) else logs.pushLog("info", "radio", "Radio search done (RadioBrowser)", false);
}

// ══════════════════════════════════════════════════════════
// Play — stream url_resolved (fallback url) through mpv
// ══════════════════════════════════════════════════════════

/// Load station `idx`'s stream straight into mpv. `url_resolved` is the
/// CDN-resolved audio stream mpv plays natively, so loadContentDirect (no
/// content-type routing) is used — creating a player if none exists and
/// revealing the player page. Falls back to `url` when unresolved.
pub fn playStation(idx: usize) void {
    if (idx >= state.app.radio.result_count) return;
    const s = &state.app.radio.results[idx];
    const src = if (s.url_resolved_len > 0)
        s.url_resolved[0..s.url_resolved_len]
    else
        s.url[0..s.url_len];
    if (src.len == 0) return;

    var url_buf: [512]u8 = undefined;
    const ulen = @min(src.len, url_buf.len);
    @memcpy(url_buf[0..ulen], src[0..ulen]);
    @import("browser.zig").loadContentDirect(url_buf[0..ulen]);
    logs.pushLog("info", "radio", "Streaming internet radio station", false);

    // RadioBrowser click-counting politeness — best-effort, ignore the result.
    pingClick(s.stationuuid[0..s.stationuuid_len]);
}

/// Fire-and-forget the RadioBrowser click endpoint for a station uuid so the
/// directory's popularity stats stay honest. Detached + best-effort: the uuid
/// is copied into an owned heap buffer the worker frees, so no shared/mutable
/// state is handed across the thread boundary.
fn pingClick(uuid: []const u8) void {
    if (uuid.len == 0) return;
    const owned = alloc.dupe(u8, uuid) catch return;
    if (std.Thread.spawn(.{}, clickWorker, .{owned})) |t| {
        t.detach();
    } else |_| {
        alloc.free(owned);
    }
}

fn clickWorker(uuid_owned: []u8) void {
    defer alloc.free(uuid_owned);
    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buf,
        "https://all.api.radio-browser.info/json/url/{s}",
        .{uuid_owned},
    ) catch return;
    if (curl(url, 16 * 1024)) |body| alloc.free(body); // ignore contents
}

// ══════════════════════════════════════════════════════════
// Helpers
// ══════════════════════════════════════════════════════════

/// Percent-encode `src` into `dst` (space, &, =, #, ?, %, + at minimum, plus
/// any non-alphanumeric that isn't URL-safe). Returns the encoded slice.
fn percentEncode(src: []const u8, dst: []u8) []const u8 {
    const hex = "0123456789ABCDEF";
    var out: usize = 0;
    for (src) |ch| {
        const safe = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (safe) {
            if (out + 1 > dst.len) break;
            dst[out] = ch;
            out += 1;
        } else {
            if (out + 3 > dst.len) break;
            dst[out] = '%';
            dst[out + 1] = hex[ch >> 4];
            dst[out + 2] = hex[ch & 0xF];
            out += 3;
        }
    }
    return dst[0..out];
}

/// Fetch `url` with curl into a fresh heap buffer of `cap` bytes. Returns the
/// filled slice (caller frees) or null on failure/empty. Large buffers stay off
/// the worker stack (macOS 512KB limit).
fn curl(url: []const u8, cap: usize) ?[]u8 {
    const argv = [_][]const u8{ "curl", "-sL", "-A", agent, "--max-time", "15", url };
    var child = io.Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return null;

    const buf = alloc.alloc(u8, cap) catch {
        _ = child.wait() catch {};
        return null;
    };
    const n = if (child.stdout) |*so| io.readAll(so, buf) catch 0 else 0;
    _ = child.wait() catch {};
    if (n == 0) {
        alloc.free(buf);
        return null;
    }
    return buf[0..n];
}

// ══════════════════════════════════════════════════════════
// UI (Drawer / Browse › Radio)
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    var pageroot = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer pageroot.deinit();

    renderSearchBar();

    if (state.app.radio.fetch_error) {
        _ = dvui.label(@src(), "Failed to fetch — check your connection", .{}, .{
            .color_text = theme.colors.danger,
            .padding = .{ .x = 12, .y = 8, .w = 0, .h = 0 },
        });
    }

    renderResults();
}

fn renderSearchBar() void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer row.deinit();

    _ = dvui.icon(@src(), "", icons.tvg.lucide.radio, .{}, .{
        .color_text = theme.colors.accent,
        .min_size_content = theme.iconSize(.md),
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
    });

    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = &state.app.radio.search_buf },
        .placeholder = "Search radio stations…",
    }, .{
        .expand = .horizontal,
        .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
        .color_fill = theme.colors.bg_elevated,
        .color_text = theme.colors.text_primary,
        .corner_radius = theme.dims.rad_sm,
        .gravity_y = 0.5,
    });
    const entered = te.enter_pressed;
    te.deinit();

    const go = dvui.button(@src(), "Go", .{}, .{
        .color_fill = theme.colors.accent,
        .color_text = dvui.Color.white,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
        .margin = .{ .x = 6, .y = 0, .w = 0, .h = 0 },
        .gravity_y = 0.5,
    });

    if (entered or go) {
        const q = std.mem.sliceTo(&state.app.radio.search_buf, 0);
        if (q.len > 0) searchRadio(q);
    }

    if (state.app.radio.is_loading.load(.acquire)) {
        _ = dvui.label(@src(), "…", .{}, .{ .color_text = theme.colors.warning, .gravity_y = 0.5 });
    }
}

fn renderResults() void {
    if (state.app.radio.result_count == 0) {
        if (!state.app.radio.is_loading.load(.acquire)) {
            _ = dvui.label(@src(), "Search for a station to get started", .{}, .{
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

    for (0..state.app.radio.result_count) |i| {
        const s = &state.app.radio.results[i];
        var name_buf: [160]u8 = undefined;
        const name = safeUtf8Buf(s.name[0..s.name_len], &name_buf);

        var rowbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .color_border = theme.colors.border_subtle,
            .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
            .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
        });
        defer rowbox.deinit();

        _ = dvui.icon(@src(), "", icons.tvg.lucide.radio, .{}, .{
            .id_extra = i + 1000,
            .color_text = theme.colors.text_tertiary,
            .min_size_content = theme.iconSize(.sm),
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
        });

        {
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = i + 2000,
                .expand = .horizontal,
            });
            defer col.deinit();

            _ = dvui.label(@src(), "{s}", .{name}, .{
                .id_extra = i + 3000,
                .color_text = theme.colors.text_primary,
                .expand = .horizontal,
            });

            // Meta: codec · bitrate · country · tags.
            var meta_buf: [200]u8 = undefined;
            var mw = std.Io.Writer.fixed(&meta_buf);
            var wrote = false;
            if (s.codec_len > 0) {
                mw.writeAll(s.codec[0..s.codec_len]) catch {};
                wrote = true;
            }
            if (s.bitrate > 0) {
                if (wrote) mw.writeAll("  ·  ") catch {};
                mw.print("{d} kbps", .{s.bitrate}) catch {};
                wrote = true;
            }
            if (s.country_len > 0) {
                if (wrote) mw.writeAll("  ·  ") catch {};
                mw.writeAll(s.country[0..s.country_len]) catch {};
                wrote = true;
            }
            if (s.tags_len > 0) {
                if (wrote) mw.writeAll("  ·  ") catch {};
                mw.writeAll(s.tags[0..@min(s.tags_len, 60)]) catch {};
                wrote = true;
            }
            if (wrote) {
                var safe_meta: [200]u8 = undefined;
                _ = dvui.label(@src(), "{s}", .{safeUtf8Buf(meta_buf[0..mw.end], &safe_meta)}, .{
                    .id_extra = i + 4000,
                    .color_text = theme.colors.text_tertiary,
                    .padding = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
                });
            }
        }

        if (dvui.buttonIcon(@src(), "Play", icons.tvg.lucide.play, .{}, .{}, .{
            .id_extra = i + 5000,
            .color_fill = theme.colors.accent,
            .color_text = dvui.Color.white,
            .corner_radius = theme.dims.rad_sm,
            .gravity_y = 0.5,
        })) {
            playStation(i);
        }
    }
}
