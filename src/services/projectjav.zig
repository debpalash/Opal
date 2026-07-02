const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const logs = @import("../core/logs.zig");
const search = @import("search.zig");
const c = @import("../core/c.zig");

// ══════════════════════════════════════════════════════════
// ProjectJav Torrent Scraper
//
// When a projectjav.com/movie/ URL is entered, this module
// fetches the page HTML (via curl), extracts all magnet
// links with metadata, and presents them in a picker modal.
// ══════════════════════════════════════════════════════════

const alloc = std.heap.c_allocator;

pub const MAX_PJAV_TORRENTS = 16;

pub const PjavTorrent = struct {
    magnet: [4096]u8 = std.mem.zeroes([4096]u8),
    magnet_len: usize = 0,
    name: [256]u8 = std.mem.zeroes([256]u8),
    name_len: usize = 0,
    seeds: i32 = 0,
    leeches: i32 = 0,
    badge: [32]u8 = std.mem.zeroes([32]u8),
    badge_len: usize = 0,
    date: [16]u8 = std.mem.zeroes([16]u8),
    date_len: usize = 0,
    // Metadata from libtorrent probe
    probe_tid: i32 = -1,
    total_size: i64 = 0,     // bytes, 0 = not yet fetched
    torrent_name: [256]u8 = std.mem.zeroes([256]u8),
    torrent_name_len: usize = 0,
    probe_done: bool = false,
};

// ── Global State ──
pub var torrents: [MAX_PJAV_TORRENTS]PjavTorrent = std.mem.zeroes([MAX_PJAV_TORRENTS]PjavTorrent);
pub var torrent_count: usize = 0;
pub var modal_open: bool = false;
pub var is_fetching: std.atomic.Value(bool) = std.atomic.Value(bool).init(false); // release after torrents[]/torrent_count fully written
pub var page_title: [256]u8 = std.mem.zeroes([256]u8);
pub var page_title_len: usize = 0;
pub var probing_started: bool = false;
// Tracks the modal's open state across frames so we can clean up probe torrents
// when it is closed via window chrome (X / click-outside) rather than the Play button.
var was_open: bool = false;

/// Check if a URL is a projectjav movie page
pub fn isProjectJavUrl(url: []const u8) bool {
    return std.mem.indexOf(u8, url, "projectjav.com/movie/") != null;
}

/// Trigger async fetch + parse of a projectjav movie page
pub fn fetchTorrents(url: []const u8) void {
    if (is_fetching.load(.acquire)) return;
    if (url.len == 0 or url.len >= 2048) return;

    is_fetching.store(true, .release);
    torrent_count = 0;
    modal_open = true;
    page_title_len = 0;
    probing_started = false;

    // Copy URL to static buffer for thread safety
    const S = struct {
        var url_buf: [2048]u8 = undefined;
        var url_len: usize = 0;
    };
    const copy_len = @min(url.len, 2047);
    @memcpy(S.url_buf[0..copy_len], url[0..copy_len]);
    S.url_buf[copy_len] = 0;
    S.url_len = copy_len;

    if (std.Thread.spawn(.{}, struct {
        fn worker() void {
            defer is_fetching.store(false, .release);

            const fetch_url = S.url_buf[0..S.url_len];

            // Fetch HTML via curl
            const argv = [_][]const u8{
                "curl", "-sL",
                "-H", "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "--max-time", "15",
                fetch_url,
            };

            var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Ignore;
            _ = child.spawn() catch {
                logs.pushLog("error", "pjav", "Failed to fetch page", false);
                return;
            };

            // Read up to 2MB
            const html_buf = std.heap.c_allocator.alloc(u8, 2 * 1024 * 1024) catch return;
            defer std.heap.c_allocator.free(html_buf);
            const html_len = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, html_buf) catch 0 else 0;
            _ = child.wait() catch {};

            if (html_len < 100) {
                logs.pushLog("error", "pjav", "Empty response from page", false);
                return;
            }

            const html = html_buf[0..html_len];

            // Extract page title
            if (std.mem.indexOf(u8, html, "<title>")) |ts| {
                const cs = ts + 7;
                if (std.mem.indexOf(u8, html[cs..], "</title>")) |te| {
                    const title = html[cs .. cs + te];
                    // Strip " jav torrents - ProjectJav" suffix
                    var clean_title = title;
                    if (std.mem.indexOf(u8, title, " jav torrents")) |suf| {
                        clean_title = title[0..suf];
                    }
                    const tl = @min(clean_title.len, 255);
                    @memcpy(page_title[0..tl], clean_title[0..tl]);
                    page_title_len = tl;
                }
            }

            // Parse magnet links
            parseHtml(html);

            if (torrent_count > 0) {
                var log_buf: [64]u8 = undefined;
                const lm = std.fmt.bufPrintZ(&log_buf, "Found {d} torrents", .{torrent_count}) catch "Found torrents";
                logs.pushLog("info", "pjav", lm, false);
            } else {
                logs.pushLog("warn", "pjav", "No magnet links found on page", false);
            }
        }
    }.worker, .{})) |t| {
        t.detach();
    } else |_| {
        is_fetching.store(false, .release);
        logs.pushLog("error", "pjav", "Failed to spawn fetch thread", false);
    }
}

fn parseHtml(html: []const u8) void {
    var pos: usize = 0;
    torrent_count = 0;

    while (pos < html.len and torrent_count < MAX_PJAV_TORRENTS) {
        // Find next magnet link
        const needle = "href=\"magnet:";
        const magnet_start = std.mem.indexOf(u8, html[pos..], needle) orelse break;
        const abs_magnet = pos + magnet_start + 6; // point to 'magnet:'

        // Find end of href attribute (closing quote)
        const href_end = std.mem.indexOfScalar(u8, html[abs_magnet..], '"') orelse break;
        const raw_magnet = html[abs_magnet .. abs_magnet + href_end];

        // Decode HTML entities: &amp;amp; → & (double-encoded)
        var decoded: [4096]u8 = undefined;
        const dec_len = decodeHtmlEntities(raw_magnet, &decoded);

        if (dec_len < 20) {
            pos = abs_magnet + href_end;
            continue;
        }

        var t = &torrents[torrent_count];
        t.* = std.mem.zeroes(PjavTorrent);
        t.probe_tid = -1;

        // Store magnet
        const ml = @min(dec_len, 4095);
        @memcpy(t.magnet[0..ml], decoded[0..ml]);
        t.magnet_len = ml;

        // Extract name from dn= parameter
        if (std.mem.indexOf(u8, decoded[0..dec_len], "dn=")) |dn_start| {
            const name_start = dn_start + 3;
            var name_end = dec_len;
            if (std.mem.indexOfScalarPos(u8, decoded[0..dec_len], name_start, '&')) |amp| {
                name_end = amp;
            }
            // URL-decode the name
            const raw_name = decoded[name_start..name_end];
            var name_dec: [256]u8 = undefined;
            const ndl = urlDecode(raw_name, &name_dec);
            const ncopy = @min(ndl, 255);
            @memcpy(t.name[0..ncopy], name_dec[0..ncopy]);
            t.name_len = ncopy;
        }

        // If no name extracted, use the hash as fallback label
        if (t.name_len == 0) {
            if (std.mem.indexOf(u8, decoded[0..dec_len], "btih:")) |bh| {
                const hash_start = bh + 5;
                var hash_end = hash_start;
                while (hash_end < dec_len and decoded[hash_end] != '&') hash_end += 1;
                const hl = @min(hash_end - hash_start, 40);
                @memcpy(t.name[0..hl], decoded[hash_start .. hash_start + hl]);
                t.name_len = hl;
            }
        }

        // Search FORWARD only from end of magnet href to next </tr> for metadata
        const after_magnet = abs_magnet + href_end;
        const tr_end = if (std.mem.indexOf(u8, html[after_magnet..@min(after_magnet + 2000, html.len)], "</tr>")) |te|
            after_magnet + te
        else
            @min(after_magnet + 2000, html.len);
        const context = html[after_magnet..tr_end];

        // Seeds
        if (std.mem.indexOf(u8, context, "Seeds</strong>")) |si| {
            const after_seeds = si + 14;
            if (after_seeds < context.len) {
                var sp = after_seeds;
                while (sp < context.len and (context[sp] == ' ' or context[sp] == '\n' or context[sp] == '\r')) sp += 1;
                var de = sp;
                while (de < context.len and context[de] >= '0' and context[de] <= '9') de += 1;
                if (de > sp) {
                    t.seeds = std.fmt.parseInt(i32, context[sp..de], 10) catch 0;
                }
            }
        }

        // Leeches
        if (std.mem.indexOf(u8, context, "Leechs</strong>")) |li| {
            const after_leech = li + 15;
            if (after_leech < context.len) {
                var sp = after_leech;
                while (sp < context.len and (context[sp] == ' ' or context[sp] == '\n' or context[sp] == '\r')) sp += 1;
                var de = sp;
                while (de < context.len and context[de] >= '0' and context[de] <= '9') de += 1;
                if (de > sp) {
                    t.leeches = std.fmt.parseInt(i32, context[sp..de], 10) catch 0;
                }
            }
        }

        // Badge (e.g. "Decen", "Old") — look for the LAST badge in this row context
        {
            var badge_pos: usize = 0;
            while (std.mem.indexOfPos(u8, context, badge_pos, "class=\"badge badge-")) |bi| {
                if (std.mem.indexOfPos(u8, context, bi, ">")) |gt| {
                    const badge_start = gt + 1;
                    if (std.mem.indexOfPos(u8, context, badge_start, "</span>")) |be| {
                        const badge = std.mem.trim(u8, context[badge_start..be], " \t\r\n");
                        // Only accept short badge labels (Decen, Old, New, etc.)
                        if (badge.len > 0 and badge.len <= 31 and !std.mem.startsWith(u8, badge, "<")) {
                            const bl2 = @min(badge.len, 31);
                            @memcpy(t.badge[0..bl2], badge[0..bl2]);
                            t.badge_len = bl2;
                        }
                        badge_pos = be;
                    } else break;
                } else break;
            }
        }

        // Date
        if (std.mem.indexOf(u8, context, "fa-calendar")) |ci| {
            if (std.mem.indexOfPos(u8, context, ci, "</strong>")) |cs| {
                const date_start = cs + 9;
                if (date_start < context.len) {
                    var ds = date_start;
                    while (ds < context.len and (context[ds] == ' ' or context[ds] == '\n' or context[ds] == '\r')) ds += 1;
                    var de = ds;
                    while (de < context.len and context[de] != '<' and de - ds < 15) de += 1;
                    const date_str = std.mem.trim(u8, context[ds..de], " \t\r\n");
                    const dl = @min(date_str.len, 15);
                    @memcpy(t.date[0..dl], date_str[0..dl]);
                    t.date_len = dl;
                }
            }
        }

        torrent_count += 1;
        pos = abs_magnet + href_end;
    }
}

/// Start background probing of all torrents via libtorrent to get file sizes
fn startProbing() void {
    if (probing_started) return;
    probing_started = true;

    const ses = state.app.torrent_ses orelse return;

    for (0..torrent_count) |idx| {
        const t = &torrents[idx];
        if (t.magnet_len == 0) continue;

        // Add magnet to get metadata
        var null_term_uri: [4096]u8 = undefined;
        @memset(&null_term_uri, 0);
        const copy_len = @min(t.magnet_len, 4095);
        @memcpy(null_term_uri[0..copy_len], t.magnet[0..copy_len]);

        const tid = c.mpv.torrent_add_magnet(ses, @ptrCast(&null_term_uri[0]), state.getSavePath());
        if (tid >= 0) {
            t.probe_tid = tid;
        }
    }
}

/// Poll probed torrents for metadata arrival
fn pollProbes() void {
    const ses = state.app.torrent_ses orelse return;

    for (0..torrent_count) |idx| {
        const t = &torrents[idx];
        if (t.probe_tid < 0 or t.probe_done) continue;

        const file_count = c.mpv.torrent_get_file_count(ses, t.probe_tid);
        if (file_count > 0) {
            t.total_size = c.mpv.torrent_get_total_size(ses, t.probe_tid);

            // Get torrent name from libtorrent
            var name_buf: [256]u8 = undefined;
            c.mpv.torrent_get_name(ses, t.probe_tid, &name_buf, 256);
            const name_len = std.mem.indexOfScalar(u8, &name_buf, 0) orelse 0;
            if (name_len > 0) {
                const nl = @min(name_len, 255);
                @memcpy(t.torrent_name[0..nl], name_buf[0..nl]);
                t.torrent_name_len = nl;
            }

            t.probe_done = true;

            // Remove the probe torrent so it doesn't stay in the session
            c.mpv.torrent_remove(ses, t.probe_tid);
            t.probe_tid = -1;
        }
    }
}

/// Decode HTML entities: &amp;amp; → &, &amp; → &, etc.
fn decodeHtmlEntities(input: []const u8, out: []u8) usize {
    var oi: usize = 0;
    var i: usize = 0;
    while (i < input.len and oi < out.len) {
        if (i + 9 <= input.len and std.mem.eql(u8, input[i .. i + 9], "&amp;amp;")) {
            out[oi] = '&';
            oi += 1;
            i += 9;
        } else if (i + 5 <= input.len and std.mem.eql(u8, input[i .. i + 5], "&amp;")) {
            out[oi] = '&';
            oi += 1;
            i += 5;
        } else if (i + 4 <= input.len and std.mem.eql(u8, input[i .. i + 4], "&lt;")) {
            out[oi] = '<';
            oi += 1;
            i += 4;
        } else if (i + 4 <= input.len and std.mem.eql(u8, input[i .. i + 4], "&gt;")) {
            out[oi] = '>';
            oi += 1;
            i += 4;
        } else if (i + 6 <= input.len and std.mem.eql(u8, input[i .. i + 6], "&quot;")) {
            out[oi] = '"';
            oi += 1;
            i += 6;
        } else {
            out[oi] = input[i];
            oi += 1;
            i += 1;
        }
    }
    return oi;
}

/// URL-decode: %XX → byte, + → space
fn urlDecode(input: []const u8, out: []u8) usize {
    var oi: usize = 0;
    var i: usize = 0;
    while (i < input.len and oi < out.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = hexVal(input[i + 1]);
            const lo = hexVal(input[i + 2]);
            if (hi != null and lo != null) {
                const byte = (hi.? << 4) | lo.?;
                if (byte >= 0x80) {
                    // Multi-byte UTF-8: decode properly instead of replacing
                    // Determine codepoint length from lead byte
                    const cp_len: usize = if (byte >= 0xF0) 4 else if (byte >= 0xE0) 3 else 2;
                    // Collect all bytes of this codepoint
                    var utf8_bytes: [4]u8 = undefined;
                    utf8_bytes[0] = byte;
                    var bi: usize = 1;
                    var ii = i + 3;
                    while (bi < cp_len and ii + 2 < input.len and input[ii] == '%') {
                        const hh = hexVal(input[ii + 1]);
                        const ll = hexVal(input[ii + 2]);
                        if (hh != null and ll != null) {
                            utf8_bytes[bi] = (hh.? << 4) | ll.?;
                            bi += 1;
                            ii += 3;
                        } else break;
                    }
                    // Write the UTF-8 bytes to output
                    if (oi + bi <= out.len) {
                        @memcpy(out[oi .. oi + bi], utf8_bytes[0..bi]);
                        oi += bi;
                    }
                    i = ii;
                } else {
                    out[oi] = byte;
                    oi += 1;
                    i += 3;
                }
            } else {
                out[oi] = input[i];
                oi += 1;
                i += 1;
            }
        } else if (input[i] == '+') {
            out[oi] = ' ';
            oi += 1;
            i += 1;
        } else {
            out[oi] = input[i];
            oi += 1;
            i += 1;
        }
    }
    return oi;
}

fn hexVal(ch: u8) ?u8 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
    return null;
}

/// Format bytes into human-readable string
fn formatSize(bytes: i64, buf: []u8) []const u8 {
    const fb: f64 = @floatFromInt(bytes);
    if (fb >= 1073741824.0)
        return std.fmt.bufPrintZ(buf, "{d:.1} GB", .{fb / 1073741824.0}) catch "?"
    else if (fb >= 1048576.0)
        return std.fmt.bufPrintZ(buf, "{d:.0} MB", .{fb / 1048576.0}) catch "?"
    else if (fb >= 1024.0)
        return std.fmt.bufPrintZ(buf, "{d:.0} KB", .{fb / 1024.0}) catch "?"
    else
        return std.fmt.bufPrintZ(buf, "{d} B", .{bytes}) catch "?";
}

// ══════════════════════════════════════════════════════════
// Modal UI — Torrent Picker (theme-consistent)
// ══════════════════════════════════════════════════════════

pub fn renderModal() void {
    if (!modal_open) {
        // Detect a close via window chrome (X / click-outside flips modal_open
        // without going through the Play button's cleanup). Clean up orphaned
        // probe torrents exactly once on the open -> closed transition.
        if (was_open) {
            cleanupProbes();
            probing_started = false;
            was_open = false;
        }
        return;
    }
    was_open = true;

    // Start probing once fetch is done and we have torrents
    if (!is_fetching.load(.acquire) and torrent_count > 0 and !probing_started) {
        startProbing();
    }

    // Poll metadata for probes
    if (probing_started) {
        pollProbes();
    }

    var win = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &modal_open,
    }, .{
        .min_size_content = .{ .w = 520, .h = 200 },
        .max_size_content = .{ .w = 700, .h = 600 },
        .color_fill = theme.colors.bg_elevated,
        .color_border = theme.colors.border_subtle,
        .corner_radius = theme.dims.rad_lg,
        .border = dvui.Rect.all(1),
        .box_shadow = .{ .color = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 160 }, .offset = .{ .x = 0, .y = 4 }, .fade = 20.0 },
    });
    defer win.deinit();

    // Title bar
    const title_text = if (page_title_len > 0) page_title[0..page_title_len] else "Select Torrent";
    var th_buf: [256]u8 = undefined;
    const title_te = @import("../core/text.zig").safeUtf8Buf(title_text, &th_buf);
    win.dragAreaSet(dvui.windowHeader(title_te, "", &modal_open));

    // Loading state
    if (is_fetching.load(.acquire)) {
        _ = dvui.label(@src(), "⟳ Fetching torrents...", .{}, .{
            .color_text = theme.colors.accent,
            .gravity_x = 0.5,
            .padding = .{ .x = 0, .y = 24, .w = 0, .h = 24 },
        });
        return;
    }

    // No results
    if (torrent_count == 0) {
        _ = dvui.label(@src(), "No torrents found on this page.", .{}, .{
            .color_text = theme.colors.text_secondary,
            .gravity_x = 0.5,
            .padding = .{ .x = 0, .y = 24, .w = 0, .h = 24 },
        });
        return;
    }

    // Count label
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 6, .w = 12, .h = 4 },
        });
        defer hdr.deinit();

        var count_buf: [48]u8 = undefined;
        const count_str = std.fmt.bufPrintZ(&count_buf, "{d} torrent(s) available", .{torrent_count}) catch "Torrents";
        _ = dvui.label(@src(), "{s}", .{count_str}, .{
            .color_text = theme.colors.text_secondary,
        });

        { var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal }); sp.deinit(); }

        // Probing status
        var all_done = true;
        for (0..torrent_count) |idx| {
            if (!torrents[idx].probe_done and torrents[idx].probe_tid >= 0) {
                all_done = false;
                break;
            }
        }
        if (probing_started and !all_done) {
            _ = dvui.label(@src(), "loading sizes...", .{}, .{
                .color_text = theme.colors.text_tertiary,
            });
        }
    }

    // Divider
    { var d = dvui.box(@src(), .{}, theme.optDivider()); d.deinit(); }

    // Torrent list
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .color_fill = theme.colors.bg_surface,
        .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
    });
    defer scroll.deinit();

    for (0..torrent_count) |idx| {
        const t = &torrents[idx];
        if (t.magnet_len == 0) continue;

        // Card — using theme optCard pattern
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = idx + 5000,
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .color_border = theme.colors.border_subtle,
            .border = dvui.Rect.all(1),
            .corner_radius = theme.dims.rad_md,
            .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 },
            .margin = .{ .x = 4, .y = 3, .w = 4, .h = 3 },
        });
        defer card.deinit();

        // Row 1: name (prefer torrent name from metadata if available)
        {
            const display_name = if (t.torrent_name_len > 0)
                t.torrent_name[0..t.torrent_name_len]
            else if (t.name_len > 0)
                t.name[0..t.name_len]
            else
                "Unknown";
            // Torrent metadata names are untrusted byte strings (often non-UTF-8
            // or truncated mid-codepoint) — drawing invalid UTF-8 to dvui panics
            // the whole app. Validate before display.
            _ = dvui.label(@src(), "{s}", .{@import("../core/text.zig").safeUtf8(display_name)}, .{
                .id_extra = idx + 5100,
                .color_text = theme.colors.text_primary,
                .expand = .horizontal,
                .padding = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
            });
        }

        // Row 2: meta chips + play button
        {
            var meta = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = idx + 5200,
                .expand = .horizontal,
            });
            defer meta.deinit();

            // Health dot
            const h_color = if (t.seeds >= 50)
                dvui.Color{ .r = 40, .g = 200, .b = 100, .a = 255 }
            else if (t.seeds >= 10)
                dvui.Color{ .r = 120, .g = 200, .b = 80, .a = 255 }
            else if (t.seeds >= 2)
                dvui.Color{ .r = 220, .g = 180, .b = 50, .a = 255 }
            else
                dvui.Color{ .r = 220, .g = 60, .b = 60, .a = 255 };

            _ = dvui.label(@src(), "●", .{}, .{
                .id_extra = idx + 5300,
                .color_text = h_color,
                .gravity_y = 0.5,
                .padding = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
            });

            // Seeds
            var seeds_buf: [16]u8 = undefined;
            const seeds_str = std.fmt.bufPrintZ(&seeds_buf, "S:{d}", .{t.seeds}) catch "S:?";
            _ = dvui.label(@src(), "{s}", .{seeds_str}, .{
                .id_extra = idx + 5400,
                .color_text = theme.colors.success,
                .gravity_y = 0.5,
            });

            _ = dvui.label(@src(), " · ", .{}, .{
                .id_extra = idx + 5500,
                .color_text = theme.colors.text_tertiary,
                .gravity_y = 0.5,
            });

            // Leeches
            var leech_buf: [16]u8 = undefined;
            const leech_str = std.fmt.bufPrintZ(&leech_buf, "L:{d}", .{t.leeches}) catch "L:?";
            _ = dvui.label(@src(), "{s}", .{leech_str}, .{
                .id_extra = idx + 5600,
                .color_text = theme.colors.danger,
                .gravity_y = 0.5,
            });

            // Size (from libtorrent probe)
            if (t.total_size > 0) {
                _ = dvui.label(@src(), " · ", .{}, .{
                    .id_extra = idx + 5650,
                    .color_text = theme.colors.text_tertiary,
                    .gravity_y = 0.5,
                });

                var size_buf: [24]u8 = undefined;
                const size_str = formatSize(t.total_size, &size_buf);
                _ = dvui.label(@src(), "{s}", .{size_str}, .{
                    .id_extra = idx + 5660,
                    .color_text = theme.colors.accent,
                    .gravity_y = 0.5,
                });
            } else if (!t.probe_done and t.probe_tid >= 0) {
                _ = dvui.label(@src(), " · ", .{}, .{
                    .id_extra = idx + 5650,
                    .color_text = theme.colors.text_tertiary,
                    .gravity_y = 0.5,
                });
                _ = dvui.label(@src(), "...", .{}, .{
                    .id_extra = idx + 5660,
                    .color_text = theme.colors.text_tertiary,
                    .gravity_y = 0.5,
                });
            }

            // Badge
            if (t.badge_len > 0) {
                _ = dvui.label(@src(), " · ", .{}, .{
                    .id_extra = idx + 5700,
                    .color_text = theme.colors.text_tertiary,
                    .gravity_y = 0.5,
                });

                const badge_color = if (std.mem.eql(u8, t.badge[0..t.badge_len], "Decen"))
                    theme.colors.accent
                else if (std.mem.eql(u8, t.badge[0..t.badge_len], "New"))
                    theme.colors.success
                else
                    theme.colors.text_secondary;

                _ = dvui.label(@src(), "{s}", .{@import("../core/text.zig").safeUtf8(t.badge[0..t.badge_len])}, .{
                    .id_extra = idx + 5750,
                    .color_text = badge_color,
                    .gravity_y = 0.5,
                });
            }

            // Date
            if (t.date_len > 0) {
                _ = dvui.label(@src(), " · ", .{}, .{
                    .id_extra = idx + 5800,
                    .color_text = theme.colors.text_tertiary,
                    .gravity_y = 0.5,
                });
                _ = dvui.label(@src(), "{s}", .{@import("../core/text.zig").safeUtf8(t.date[0..t.date_len])}, .{
                    .id_extra = idx + 5850,
                    .color_text = theme.colors.text_tertiary,
                    .gravity_y = 0.5,
                });
            }

            // Spacer
            { var sp = dvui.box(@src(), .{}, .{ .id_extra = idx + 5900, .expand = .horizontal }); sp.deinit(); }

            // Play button — accent style
            if (dvui.button(@src(), "▶ Play", .{}, .{
                .id_extra = idx + 6000,
                .color_fill = theme.colors.accent,
                .color_text = theme.colors.bg_app,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 14, .y = 5, .w = 14, .h = 5 },
            })) {
                // Clean up remaining probes before playing
                cleanupProbes();
                search.loadTorrentToPlayer(t.magnet[0..t.magnet_len]);
                modal_open = false;
                state.showToast("Loading torrent...");
            }
        }
    }
}

/// Remove all probe torrents from session when closing/playing
fn cleanupProbes() void {
    const ses = state.app.torrent_ses orelse return;
    for (0..torrent_count) |idx| {
        const t = &torrents[idx];
        if (t.probe_tid >= 0) {
            c.mpv.torrent_remove(ses, t.probe_tid);
            t.probe_tid = -1;
        }
    }
}
