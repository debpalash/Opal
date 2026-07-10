//! Podcasts tab — keyless discovery via the iTunes Search API, streamed as
//! audio through mpv. Structurally a sibling of anime.zig: search → show →
//! episode list → play. All parsing lives in podcasts_pure.zig (tested); this
//! module owns the async fetch workers, thread-safety, and dvui rendering.
//!
//! Flow:
//!   searchPodcasts(q) → curl itunes.apple.com/search?media=podcast&term=…
//!                       → pure.parseItunes → state.app.podcasts.results[]
//!   loadEpisodes(idx) → curl the show's feedUrl (RSS)
//!                       → pure.parseRssEpisodes → state.app.podcasts.episodes[]
//!   playEpisode(idx)  → browser.loadContentDirect(audio enclosure url) → mpv

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const logs = @import("../core/logs.zig");
const pure = @import("podcasts_pure.zig");
const io = @import("../core/io_global.zig");
const safeUtf8Buf = @import("../core/text.zig").safeUtf8Buf;

const alloc = @import("../core/alloc.zig").allocator;

const agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0";

// ── Thread-safety ──
// Detached workers publish into state.app.podcasts.* under `parse_mutex`, and a
// monotonic `search_gen` drops stale results so fast re-searches never show
// out-of-order data (mirrors anime.zig). The two `*_loading` flags are atomic
// (read by UI + remote threads, written by workers).
var parse_mutex: @import("../core/sync.zig").Mutex = .{};
var search_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// Query snapshot handed to the detached search worker (never read the mutable
// UI search_buf from the thread).
var query_buf: [256]u8 = undefined;
var query_len: usize = 0;

// ══════════════════════════════════════════════════════════
// Search — iTunes Search API
// ══════════════════════════════════════════════════════════

pub fn searchPodcasts(query: []const u8) void {
    if (query.len == 0) return;

    state.app.podcasts.is_loading.store(true, .release);
    state.app.podcasts.fetch_error = false;
    state.app.podcasts.selected_idx = null;
    state.app.podcasts.episode_count = 0;

    const my_gen = search_gen.fetchAdd(1, .acq_rel) + 1;

    const n = @min(query.len, query_buf.len);
    @memcpy(query_buf[0..n], query[0..n]);
    query_len = n;

    if (std.Thread.spawn(.{}, searchWorker, .{my_gen})) |t| {
        t.detach(); // never joined — detach to avoid leaking the handle
    } else |_| {
        state.app.podcasts.is_loading.store(false, .release);
    }
}

fn searchWorker(my_gen: u32) void {
    defer state.app.podcasts.is_loading.store(false, .release);

    // Snapshot the query — a newer search may overwrite query_buf mid-flight.
    var local: [256]u8 = undefined;
    const qlen = @min(query_len, local.len);
    @memcpy(local[0..qlen], query_buf[0..qlen]);

    // Percent-encode the term (space, &, =, #, ?, %, + at minimum).
    var enc: [768]u8 = undefined;
    const encoded = percentEncode(local[0..qlen], &enc);

    var url_buf: [900]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buf,
        "https://itunes.apple.com/search?media=podcast&limit=40&term={s}",
        .{encoded},
    ) catch return;

    const body = curl(url, 256 * 1024) orelse {
        state.app.podcasts.fetch_error = true;
        return;
    };
    defer alloc.free(body);

    // Bail if superseded while curl was in flight.
    if (search_gen.load(.acquire) != my_gen) return;

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (search_gen.load(.acquire) != my_gen) return; // re-check under lock

    const count = pure.parseItunes(body, &state.app.podcasts.results);
    state.app.podcasts.result_count = count;
    if (count == 0) logs.pushLog("info", "podcasts", "Search returned no shows", false) else logs.pushLog("info", "podcasts", "Podcast search done (iTunes)", false);
}

// ══════════════════════════════════════════════════════════
// Episodes — a show's RSS feed
// ══════════════════════════════════════════════════════════

pub fn loadEpisodes(idx: usize) void {
    if (idx >= state.app.podcasts.result_count) return;
    if (state.app.podcasts.episodes_loading.load(.acquire)) return;

    state.app.podcasts.selected_idx = idx;
    state.app.podcasts.episode_count = 0;
    state.app.podcasts.fetch_error = false;
    state.app.podcasts.episodes_loading.store(true, .release);

    // Copy the selected show's name (episode-view header) + feed url for the
    // worker so it never reads results[] as it may be reordered by a new search.
    const p = &state.app.podcasts.results[idx];
    const nlen = @min(p.name_len, state.app.podcasts.selected_name.len);
    @memcpy(state.app.podcasts.selected_name[0..nlen], p.name[0..nlen]);
    state.app.podcasts.selected_name_len = nlen;

    const S = struct {
        var feed: [300]u8 = undefined;
        var feed_len: usize = 0;
        fn worker() void {
            defer state.app.podcasts.episodes_loading.store(false, .release);
            const url = @This().feed[0..@This().feed_len];
            if (url.len == 0) return;
            const body = curl(url, 1024 * 1024) orelse {
                state.app.podcasts.fetch_error = true;
                return;
            };
            defer alloc.free(body);
            parse_mutex.lock();
            defer parse_mutex.unlock();
            const n = pure.parseRssEpisodes(body, &state.app.podcasts.episodes);
            state.app.podcasts.episode_count = n;
            logs.pushLog("info", "podcasts", "Episodes loaded (RSS)", false);
        }
    };
    const flen = @min(p.feed_url_len, S.feed.len);
    @memcpy(S.feed[0..flen], p.feed_url[0..flen]);
    S.feed_len = flen;

    if (std.Thread.spawn(.{}, S.worker, .{})) |t| {
        t.detach(); // never joined — detach to avoid leaking the handle
    } else |_| {
        state.app.podcasts.episodes_loading.store(false, .release);
    }
}

// ══════════════════════════════════════════════════════════
// Play — stream the audio enclosure URL through mpv
// ══════════════════════════════════════════════════════════

/// Load episode `idx`'s audio enclosure URL straight into mpv. The URL is a
/// direct audio stream, so loadContentDirect (no content-type routing) is used
/// — creating a player if none exists and revealing the player page.
pub fn playEpisode(idx: usize) void {
    if (idx >= state.app.podcasts.episode_count) return;
    const e = &state.app.podcasts.episodes[idx];
    if (e.audio_url_len == 0) return;
    var url_buf: [512]u8 = undefined;
    const ulen = @min(e.audio_url_len, url_buf.len);
    @memcpy(url_buf[0..ulen], e.audio_url[0..ulen]);
    @import("browser.zig").loadContentDirect(url_buf[0..ulen]);
    logs.pushLog("info", "podcasts", "Streaming podcast episode", false);
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
// UI (Drawer / Browse › Podcasts)
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    var pageroot = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer pageroot.deinit();

    renderSearchBar();

    if (state.app.podcasts.fetch_error) {
        _ = dvui.label(@src(), "Failed to fetch — check your connection", .{}, .{
            .color_text = theme.colors.danger,
            .padding = .{ .x = 12, .y = 8, .w = 0, .h = 0 },
        });
    }

    if (state.app.podcasts.selected_idx == null) {
        renderResults();
    } else {
        renderEpisodes();
    }
}

fn renderSearchBar() void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer row.deinit();

    _ = dvui.icon(@src(), "", icons.tvg.lucide.podcast, .{}, .{
        .color_text = theme.colors.accent,
        .min_size_content = theme.iconSize(.md),
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
    });

    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = &state.app.podcasts.search_buf },
        .placeholder = "Search podcasts…",
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
        const q = std.mem.sliceTo(&state.app.podcasts.search_buf, 0);
        if (q.len > 0) searchPodcasts(q);
    }

    if (state.app.podcasts.is_loading.load(.acquire)) {
        _ = dvui.label(@src(), "…", .{}, .{ .color_text = theme.colors.warning, .gravity_y = 0.5 });
    }
}

fn renderResults() void {
    if (state.app.podcasts.result_count == 0) {
        if (!state.app.podcasts.is_loading.load(.acquire)) {
            _ = dvui.label(@src(), "Search for a show to get started", .{}, .{
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

    for (0..state.app.podcasts.result_count) |i| {
        const p = &state.app.podcasts.results[i];
        var name_buf: [160]u8 = undefined;
        const name = safeUtf8Buf(p.name[0..p.name_len], &name_buf);

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

        _ = dvui.icon(@src(), "", icons.tvg.lucide.podcast, .{}, .{
            .id_extra = i + 1000,
            .color_text = theme.colors.text_tertiary,
            .min_size_content = theme.iconSize(.sm),
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
        });

        _ = dvui.label(@src(), "{s}", .{name}, .{
            .id_extra = i + 2000,
            .color_text = theme.colors.text_primary,
            .expand = .horizontal,
            .gravity_y = 0.5,
        });

        if (dvui.button(@src(), "Episodes", .{}, .{
            .id_extra = i + 3000,
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.accent,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
            .gravity_y = 0.5,
        })) {
            loadEpisodes(i);
        }
    }
}

fn renderEpisodes() void {
    // Header: back button + show title.
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
            state.app.podcasts.selected_idx = null;
            state.app.podcasts.episode_count = 0;
            return;
        }

        var title_buf: [160]u8 = undefined;
        const title = safeUtf8Buf(
            state.app.podcasts.selected_name[0..state.app.podcasts.selected_name_len],
            &title_buf,
        );
        _ = dvui.label(@src(), "{s}", .{title}, .{
            .color_text = theme.colors.text_primary,
            .expand = .horizontal,
            .gravity_y = 0.5,
        });

        if (state.app.podcasts.episodes_loading.load(.acquire)) {
            _ = dvui.label(@src(), "Loading…", .{}, .{ .color_text = theme.colors.warning, .gravity_y = 0.5 });
        }
    }

    if (state.app.podcasts.episode_count == 0) {
        if (!state.app.podcasts.episodes_loading.load(.acquire)) {
            _ = dvui.label(@src(), "No episodes found", .{}, .{
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

    for (0..state.app.podcasts.episode_count) |i| {
        const e = &state.app.podcasts.episodes[i];
        var title_buf: [200]u8 = undefined;
        const title = safeUtf8Buf(e.title[0..e.title_len], &title_buf);

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

        {
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = i + 3000,
                .expand = .horizontal,
            });
            defer col.deinit();

            _ = dvui.label(@src(), "{s}", .{title}, .{
                .id_extra = i + 4000,
                .color_text = theme.colors.text_primary,
                .expand = .horizontal,
            });

            // Meta: date · duration.
            if (e.date_len > 0 or e.duration_len > 0) {
                var meta_buf: [64]u8 = undefined;
                var mw = std.Io.Writer.fixed(&meta_buf);
                if (e.date_len > 0) mw.writeAll(e.date[0..@min(e.date_len, 32)]) catch {};
                if (e.date_len > 0 and e.duration_len > 0) mw.writeAll("  ·  ") catch {};
                if (e.duration_len > 0) mw.writeAll(e.duration[0..e.duration_len]) catch {};
                var safe_meta: [64]u8 = undefined;
                _ = dvui.label(@src(), "{s}", .{safeUtf8Buf(meta_buf[0..mw.end], &safe_meta)}, .{
                    .id_extra = i + 5000,
                    .color_text = theme.colors.text_tertiary,
                    .padding = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
                });
            }
        }

        if (dvui.buttonIcon(@src(), "Play", icons.tvg.lucide.play, .{}, .{}, .{
            .id_extra = i + 6000,
            .color_fill = theme.colors.accent,
            .color_text = dvui.Color.white,
            .corner_radius = theme.dims.rad_sm,
            .gravity_y = 0.5,
        })) {
            playEpisode(i);
        }
    }
}
