const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const icons = @import("icons");
const logs = @import("../core/logs.zig");

const alloc = @import("../core/alloc.zig").allocator;
const safeUtf8 = @import("../core/text.zig").safeUtf8;

fn percentEncode(input: []const u8, out: []u8) usize {
    const hex = "0123456789ABCDEF";
    var o: usize = 0;
    for (input) |ch| {
        if (o + 3 > out.len) break;
        if (ch == ' ') {
            out[o] = '+';
            o += 1;
        } else if (ch == '&' or ch == '=' or ch == '#' or ch == '?' or ch == '%' or ch == '"' or ch == '<' or ch == '>') {
            out[o] = '%';
            out[o + 1] = hex[ch >> 4];
            out[o + 2] = hex[ch & 0x0F];
            o += 3;
        } else {
            out[o] = ch;
            o += 1;
        }
    }
    return o;
}

// ══════════════════════════════════════════════════════════
// Comics Reader — readallcomics.com scraper + native viewer
// Uses curl subprocess to bypass Cloudflare
// ══════════════════════════════════════════════════════════

/// Kick off a background thread to fetch and parse a comic issue page.
pub fn loadComic(url: []const u8) void {
    if (state.app.comic.is_loading) return;
    if (url.len == 0 or url.len >= 512) return;

    // Stop any active narration
    state.app.comic.narrating = false;
    state.app.comic.show_ocr_overlay = false;

    // Store URL
    const buf_ptr: [*]const u8 = @ptrCast(&state.app.comic.url_buf[0]);
    if (url.ptr != buf_ptr) {
        @memcpy(state.app.comic.url_buf[0..url.len], url);
    }
    state.app.comic.url_len = url.len;
    state.app.comic.is_loading = true;
    state.app.comic.page_count = 0;
    state.app.comic.dl_progress = 0;
    state.app.comic.current_page = 0;

    // Clear old textures/pixels and OCR cache
    for (0..128) |i| {
        if (state.app.comic.page_textures[i]) |tex| {
            dvui.textureDestroyLater(tex);
        }
        state.app.comic.page_textures[i] = null;
        if (state.app.comic.page_pixels[i]) |px| {
            alloc.free(px);
            state.app.comic.page_pixels[i] = null;
        }
        state.app.comic.ocr_lens[i] = 0;
        state.app.comic.ocr_done[i] = false;
    }

    // Auto-switch active pane to comic_viewer
    if (state.app.active_player_idx < state.app.players.items.len) {
        state.app.players.items[state.app.active_player_idx].provider = .comic_viewer;
    }

    state.app.comic.thread = std.Thread.spawn(.{}, fetchComicThread, .{}) catch null;
}

fn fetchComicThread() void {
    const url = state.app.comic.url_buf[0..state.app.comic.url_len];

    // Try external plugins first
    if (tryPlugins(url)) {
        logs.pushLog("info", "comics", "Comic loaded via plugin", false);
        state.app.comic.is_loading = false;
        downloadPages();
        return;
    }

    // Fallback: native curl + HTML parsing
    const argv = [_][]const u8{
        "curl",       "-sL",
        "-H",         "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "--max-time", "15",
        url,
    };

    var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch {
        logs.pushLog("error", "comics", "Failed to spawn curl", true);
        state.app.comic.is_loading = false;
        return;
    };

    const html_buf = alloc.alloc(u8, 512 * 1024) catch return;
    defer alloc.free(html_buf);
    const html_bytes = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, html_buf) catch 0 else 0;
    _ = child.wait() catch {};

    if (html_bytes == 0) {
        logs.pushLog("error", "comics", "Empty response from curl", true);
        state.app.comic.is_loading = false;
        return;
    }

    const html = html_buf[0..html_bytes];

    parseTitle(html);
    parseImageUrls(html);
    parseNavLinks(html);

    logs.pushLog("info", "comics", "Comic loaded (native)", false);
    state.app.comic.is_loading = false;
    downloadPages();
}

/// Scan ~/.config/zigzag/plugins/comics/ for .lua/.py/.sh scripts,
/// execute each with url as arg1, parse JSON stdout.
fn tryPlugins(url: []const u8) bool {
    // 1) Try bundled plugins/ directory (shipped with app)
    if (tryPluginsInDir("plugins", url)) return true;

    // 2) Try user plugins directory
    const home = @import("../core/io_global.zig").getenv("HOME") orelse return false;
    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/.config/zigzag/plugins/comics", .{home}) catch return false;
    return tryPluginsInDir(dir_path, url);
}

fn tryPluginsInDir(dir_path: []const u8, url: []const u8) bool {
    var dir = @import("../core/io_global.zig").cwdOpenDir(dir_path, .{ .iterate = true }) catch return false;
    defer dir.close(@import("../core/io_global.zig").io());

    var iter = dir.iterate();
    while (iter.next(@import("../core/io_global.zig").io()) catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;

        // Determine interpreter based on extension
        const interpreter: []const u8 = if (std.mem.endsWith(u8, name, ".lua"))
            "lua"
        else if (std.mem.endsWith(u8, name, ".py"))
            "python3"
        else if (std.mem.endsWith(u8, name, ".sh"))
            "bash"
        else
            continue;

        // Build full path
        var path_buf: [512]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch continue;

        // Execute: <interpreter> <plugin_path> <url>
        const argv = [_][]const u8{ interpreter, full_path, url };
        var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        _ = child.spawn() catch continue;

        const json_buf = alloc.alloc(u8, 256 * 1024) catch continue;
        defer alloc.free(json_buf);
        const json_len = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, json_buf) catch 0 else 0;
        const term = child.wait() catch continue;

        // Plugin exited non-zero = "not my domain", try next
        if (term.exited != 0 or json_len < 10) continue;

        // Parse JSON response
        if (parsePluginJson(json_buf[0..json_len])) {
            var msg_buf: [320]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Plugin matched: {s}", .{name}) catch "Plugin matched";
            logs.pushLog("info", "comics", msg, false);
            return true;
        }
    }
    return false;
}

/// Parse the JSON output from a comic plugin and populate state.
fn parsePluginJson(json: []const u8) bool {
    // Simple manual JSON parsing — extract "title", "pages", "next_url", "prev_url"

    // Title
    if (findJsonString(json, "\"title\":\"")) |title| {
        const len = @min(title.len, 255);
        @memcpy(state.app.comic.title[0..len], title[0..len]);
        state.app.comic.title_len = len;
    }

    // Next URL
    if (findJsonString(json, "\"next_url\":\"")) |nxt| {
        const len = @min(nxt.len, 511);
        @memcpy(state.app.comic.next_url[0..len], nxt[0..len]);
        state.app.comic.next_url_len = len;
    } else {
        state.app.comic.next_url_len = 0;
    }

    // Prev URL
    if (findJsonString(json, "\"prev_url\":\"")) |prv| {
        const len = @min(prv.len, 511);
        @memcpy(state.app.comic.prev_url[0..len], prv[0..len]);
        state.app.comic.prev_url_len = len;
    } else {
        state.app.comic.prev_url_len = 0;
    }

    // Pages array
    var count: usize = 0;
    const pages_start = std.mem.indexOf(u8, json, "\"pages\":[") orelse return false;
    var pos = pages_start + 9; // skip "pages":[

    while (pos < json.len and count < 128) {
        // Find next quoted string
        const q1 = std.mem.indexOfScalar(u8, json[pos..], '"') orelse break;
        const abs_q1 = pos + q1 + 1;
        if (abs_q1 >= json.len) break;
        const q2 = std.mem.indexOfScalar(u8, json[abs_q1..], '"') orelse break;
        const page_url = json[abs_q1 .. abs_q1 + q2];

        if (page_url.len > 10 and page_url.len < 512) {
            @memcpy(state.app.comic.page_urls[count][0..page_url.len], page_url);
            state.app.comic.page_url_lens[count] = page_url.len;
            count += 1;
        }

        pos = abs_q1 + q2 + 1;
        // Skip comma or closing bracket
        if (pos < json.len and json[pos] == ']') break;
    }

    state.app.comic.page_count = count;
    return count > 0;
}

/// Extract a simple JSON string value after a key prefix like "key":"
fn findJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, json, key) orelse return null;
    const val_start = start + key.len;
    if (val_start >= json.len) return null;
    // Find closing unescaped quote
    var i: usize = val_start;
    while (i < json.len) : (i += 1) {
        if (json[i] == '"' and (i == val_start or json[i - 1] != '\\')) {
            const val = json[val_start..i];
            if (val.len == 0) return null;
            return val;
        }
    }
    return null;
}

fn parseTitle(html: []const u8) void {
    // Look for: <title>...<title> or series name in <h1>
    if (findBetween(html, "<title>", "</title>")) |title| {
        const clean = std.mem.trimEnd(u8, title, " \t\r\n");
        const len = @min(clean.len, 255);
        @memcpy(state.app.comic.title[0..len], clean[0..len]);
        state.app.comic.title_len = len;
    }
}

fn parseImageUrls(html: []const u8) void {
    // readallcomics.com uses images hosted on bp.blogspot.com
    // Pattern: src="https://X.bp.blogspot.com/..."
    var count: usize = 0;
    var pos: usize = 0;

    while (pos < html.len and count < 128) {
        // Find img src
        const src_start = findSubstring(html[pos..], "src=\"https://") orelse break;
        const abs_start = pos + src_start + 5; // skip 'src="'
        const src_end = std.mem.indexOfScalar(u8, html[abs_start..], '"') orelse break;
        const img_url = html[abs_start .. abs_start + src_end];
        pos = abs_start + src_end;

        // Filter: only blogspot CDN images (actual comic pages)
        if (std.mem.indexOf(u8, img_url, "bp.blogspot.com") == null and
            std.mem.indexOf(u8, img_url, "blogger.googleusercontent") == null) continue;

        // Skip tiny icons/thumbnails
        if (src_end < 30) continue;

        if (img_url.len < 512) {
            @memcpy(state.app.comic.page_urls[count][0..img_url.len], img_url);
            state.app.comic.page_url_lens[count] = img_url.len;
            count += 1;
        }
    }

    state.app.comic.page_count = count;
}

fn parseNavLinks(html: []const u8) void {
    state.app.comic.next_url_len = 0;
    state.app.comic.prev_url_len = 0;

    // Look for: href="...">...Next...
    if (findLinkWithText(html, "Next")) |next_url| {
        const len = @min(next_url.len, 511);
        @memcpy(state.app.comic.next_url[0..len], next_url[0..len]);
        state.app.comic.next_url_len = len;
    }

    if (findLinkWithText(html, "Prev")) |prev_url| {
        const len = @min(prev_url.len, 511);
        @memcpy(state.app.comic.prev_url[0..len], prev_url[0..len]);
        state.app.comic.prev_url_len = len;
    }
}

fn downloadPages() void {
    // Download comic page images in PARALLEL — 8 concurrent threads
    const BATCH = 8;
    var threads: [BATCH]?std.Thread = [_]?std.Thread{null} ** BATCH;
    var page_idx: usize = 0;

    while (page_idx < state.app.comic.page_count) {
        var active: usize = 0;

        // Spawn batch of download threads
        while (active < BATCH and page_idx < state.app.comic.page_count) {
            if (state.app.comic.page_pixels[page_idx] != null or
                state.app.comic.page_url_lens[page_idx] == 0)
            {
                page_idx += 1;
                continue;
            }
            threads[active] = std.Thread.spawn(.{}, downloadSinglePage, .{page_idx}) catch null;
            active += 1;
            page_idx += 1;
        }

        // Wait for all threads in this batch
        for (0..active) |t| {
            if (threads[t]) |th| th.join();
            threads[t] = null;
        }
    }
}

fn downloadSinglePage(i: usize) void {
    const url = state.app.comic.page_urls[i][0..state.app.comic.page_url_lens[i]];
    if (url.len == 0) return;

    const argv = [_][]const u8{
        "curl",       "-sL",
        "-H",         "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",
        "--max-time", "15",
        url,
    };

    var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return;

    const max_img = 5 * 1024 * 1024;
    const tmp_buf = alloc.alloc(u8, max_img) catch return;
    defer alloc.free(tmp_buf);
    var total: usize = 0;

    if (child.stdout) |*stdout| {
        while (total < max_img) {
            const n = @import("../core/io_global.zig").read(stdout, tmp_buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
    }
    _ = child.wait() catch {};

    if (total > 100) {
        const pixels = alloc.dupe(u8, tmp_buf[0..total]) catch return;
        state.app.comic.page_pixels[i] = pixels;
        state.app.comic.dl_progress += 1;
    }
}

// ══════════════════════════════════════════════════════════
// Search readallcomics.com
// ══════════════════════════════════════════════════════════

// ── Comic search results (parsed from the readallcomics search page) ──
const MAX_SEARCH_RESULTS = 40;
var sr_urls: [MAX_SEARCH_RESULTS][256]u8 = undefined;
var sr_url_lens: [MAX_SEARCH_RESULTS]usize = std.mem.zeroes([MAX_SEARCH_RESULTS]usize);
var sr_titles: [MAX_SEARCH_RESULTS][160]u8 = undefined;
var sr_title_lens: [MAX_SEARCH_RESULTS]usize = std.mem.zeroes([MAX_SEARCH_RESULTS]usize);
var sr_count: usize = 0;
var sr_searching: bool = false;
var loaded_default: bool = false;
var sr_query_buf: [256]u8 = undefined;
var sr_query_len: usize = 0;

pub fn searchResultCount() usize {
    return sr_count;
}

pub fn searchComics(query: []const u8) void {
    if (sr_searching or query.len == 0 or query.len >= sr_query_buf.len) return;
    sr_searching = true;
    sr_count = 0;
    @memcpy(sr_query_buf[0..query.len], query);
    sr_query_len = query.len;
    const t = std.Thread.spawn(.{}, searchWorker, .{}) catch {
        sr_searching = false;
        return;
    };
    t.detach();
}

fn searchWorker() void {
    defer sr_searching = false;
    const query = sr_query_buf[0..sr_query_len];

    var encoded_query: [512]u8 = undefined;
    const enc_len = percentEncode(query, &encoded_query);
    var url_buf: [640]u8 = undefined;
    const url = std.fmt.bufPrintZ(&url_buf, "https://readallcomics.com/?story={s}&s=&type=comic", .{encoded_query[0..enc_len]}) catch return;

    const argv = [_][]const u8{
        "curl",       "-sL",
        "-H",         "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "--max-time", "15",
        url,
    };
    var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return;
    const html_buf = alloc.alloc(u8, 512 * 1024) catch return;
    defer alloc.free(html_buf);
    const n = if (child.stdout) |*so| @import("../core/io_global.zig").readAll(so, html_buf) catch 0 else 0;
    _ = child.wait() catch {};
    if (n == 0) return;
    parseSearchResults(html_buf[0..n]);
    logs.pushLog("info", "comics", "Comic search results parsed", false);
}

/// Best-effort: pull issue links from the readallcomics search page. Each result
/// is an anchor to a single-segment slug, e.g.
///   <a href="https://readallcomics.com/some-comic-001/">Some Comic 001</a>
fn parseSearchResults(html: []const u8) void {
    var count: usize = 0;
    var pos: usize = 0;
    const needle = "href=\"https://readallcomics.com/";
    while (pos < html.len and count < MAX_SEARCH_RESULTS) {
        const h = findSubstring(html[pos..], needle) orelse break;
        const href_start = pos + h + 6; // skip 'href="'
        const href_end = std.mem.indexOfScalar(u8, html[href_start..], '"') orelse break;
        const link = html[href_start .. href_start + href_end];
        pos = href_start + href_end;

        const prefix = "https://readallcomics.com/";
        if (link.len <= prefix.len) continue;
        if (std.mem.indexOfScalar(u8, link, '?') != null) continue;
        const tail = link[prefix.len..];
        if (std.mem.startsWith(u8, tail, "category") or std.mem.startsWith(u8, tail, "page")) continue;
        // single-segment slug (one trailing slash, no inner '/')
        const slug = std.mem.trimEnd(u8, tail, "/");
        if (slug.len == 0 or std.mem.indexOfScalar(u8, slug, '/') != null) continue;
        // Comic issue slugs always carry a number (issue # / year); this filters
        // out footer/nav links (privacy-policy, legal-disclamer, …).
        var has_digit = false;
        for (slug) |ch| {
            if (std.ascii.isDigit(ch)) {
                has_digit = true;
                break;
            }
        }
        if (!has_digit) continue;

        // Anchor text = title (between the next '>' and '</a>').
        const gt = std.mem.indexOfScalar(u8, html[pos..], '>') orelse continue;
        const title_start = pos + gt + 1;
        const close = findSubstring(html[title_start..], "</a>") orelse continue;
        var title = std.mem.trim(u8, html[title_start .. title_start + close], " \t\r\n");
        if (title.len == 0 or title.len > 159 or std.mem.indexOfScalar(u8, title, '<') != null) title = slug;

        if (count > 0 and std.mem.eql(u8, sr_urls[count - 1][0..sr_url_lens[count - 1]], link)) continue;

        const ulen = @min(link.len, 255);
        @memcpy(sr_urls[count][0..ulen], link[0..ulen]);
        sr_url_lens[count] = ulen;
        const tlen = @min(title.len, 159);
        @memcpy(sr_titles[count][0..tlen], title[0..tlen]);
        sr_title_lens[count] = tlen;
        count += 1;
    }
    sr_count = count;
}

// ══════════════════════════════════════════════════════════
// UI Rendering
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    // First open shows a default popular feed so the tab isn't blank (the
    // search box stays free for anything else).
    if (!loaded_default and sr_count == 0 and !sr_searching and state.app.comic.search_buf[0] == 0 and state.app.comic.title_len == 0) {
        loaded_default = true;
        searchComics("spider-man");
    }

    // Full-page root so loading/empty branches fill width/height.
    var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer page.deinit();

    // Search bar
    {
        var search_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
            .background = true,
            .color_fill = theme.colors.bg_header,
        });
        defer search_row.deinit();

        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.comic.search_buf } }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 200, .h = 20 },
            .color_fill = theme.colors.bg_input,
            .color_border = theme.colors.border_input,
            .color_text = theme.colors.text_main,
            .border = dvui.Rect.all(1),
            .corner_radius = theme.dims.rad_sm,
        });
        const enter_pressed = te.enter_pressed;
        te.deinit();

        const clicked = dvui.button(@src(), "Load", .{}, .{
            .color_fill = theme.colors.accent,
            .color_text = dvui.Color.white,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
            .margin = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
        });
        if (clicked or enter_pressed) {
            const input = std.mem.sliceTo(&state.app.comic.search_buf, 0);
            if (input.len > 0) {
                if (std.mem.startsWith(u8, input, "http")) {
                    loadComic(input);
                } else {
                    searchComics(input);
                }
            }
        }
    }

    // Quick links
    {
        var links_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 2, .w = 8, .h = 4 },
        });
        defer links_row.deinit();

        if (dvui.button(@src(), "Invincible #1", .{}, .{
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.accent,
            .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
        })) {
            loadComic("https://readallcomics.com/invincible-001/");
        }
        if (dvui.button(@src(), "The Boys #1", .{}, .{
            .id_extra = 1,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.accent,
            .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
        })) {
            loadComic("https://readallcomics.com/the-boys-001-2006/");
        }
        if (dvui.button(@src(), "Saga #1", .{}, .{
            .id_extra = 2,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.accent,
            .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
        })) {
            loadComic("https://readallcomics.com/saga-001-2012/");
        }
    }

    // Search results — clickable list; pick one to load it as a comic.
    if (sr_searching) {
        _ = dvui.label(@src(), "Searching…", .{}, .{ .color_text = theme.colors.accent, .padding = .{ .x = 12, .y = 8, .w = 0, .h = 0 } });
        return;
    }
    if (sr_count > 0 and state.app.comic.page_count == 0 and !state.app.comic.is_loading) {
        var list = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_drawer });
        defer list.deinit();
        for (0..sr_count) |i| {
            if (dvui.button(@src(), safeUtf8(sr_titles[i][0..sr_title_lens[i]]), .{}, .{
                .id_extra = i + 44000,
                .expand = .horizontal,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_text = theme.colors.text_main,
                .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
                .color_border = theme.colors.border_drawer,
                .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
            })) {
                loadComic(sr_urls[i][0..sr_url_lens[i]]);
                sr_count = 0;
            }
        }
        return;
    }

    // Loading indicator
    if (state.app.comic.is_loading) {
        _ = dvui.label(@src(), "Loading comic...", .{}, .{
            .color_text = theme.colors.accent,
            .padding = .{ .x = 12, .y = 8, .w = 0, .h = 0 },
        });
        return;
    }

    if (state.app.comic.page_count == 0) {
        _ = dvui.label(@src(), "Enter a readallcomics.com URL or search", .{}, .{
            .color_text = theme.colors.text_muted,
            .padding = .{ .x = 12, .y = 20, .w = 0, .h = 0 },
        });
        return;
    }

    // ── Comic Loaded: Show controls in drawer ──

    // Title + page info
    {
        var info_row = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 8, .w = 12, .h = 4 },
        });
        defer info_row.deinit();

        if (state.app.comic.title_len > 0) {
            _ = dvui.label(@src(), "{s}", .{safeUtf8(state.app.comic.title[0..state.app.comic.title_len])}, .{
                .color_text = theme.colors.text_main,
            });
        }

        var page_buf: [64]u8 = undefined;
        const page_str = std.fmt.bufPrintZ(&page_buf, "Page {d} of {d}", .{
            state.app.comic.current_page + 1, state.app.comic.page_count,
        }) catch "?";
        _ = dvui.label(@src(), "{s}", .{page_str}, .{
            .color_text = theme.colors.text_muted,
        });
    }

    // Page Navigation
    {
        var nav_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 4, .w = 12, .h = 4 },
        });
        defer nav_row.deinit();

        if (state.app.comic.current_page > 0) {
            if (dvui.button(@src(), "← Prev", .{}, .{
                .id_extra = 30,
                .color_fill = theme.colors.bg_glass,
                .color_text = theme.colors.text_main,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
                .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
            })) {
                state.app.comic.current_page -= 1;
                state.app.comic.scroll_to_page = true;
            }
        }

        if (state.app.comic.current_page + 1 < state.app.comic.page_count) {
            if (dvui.button(@src(), "Next →", .{}, .{
                .id_extra = 31,
                .color_fill = theme.colors.bg_glass,
                .color_text = theme.colors.text_main,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
            })) {
                state.app.comic.current_page += 1;
                state.app.comic.scroll_to_page = true;
            }
        }
    }

    // ── TTS & OCR Controls ──
    {
        var ctrl_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
            .background = true,
            .color_fill = theme.colors.bg_header,
            .border = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
            .color_border = theme.colors.divider,
        });
        defer ctrl_row.deinit();

        // OCR this page
        if (dvui.button(@src(), "OCR Page", .{}, .{
            .id_extra = 40,
            .color_fill = if (state.app.comic.show_ocr_overlay) theme.colors.accent else theme.colors.bg_glass,
            .color_text = if (state.app.comic.show_ocr_overlay) dvui.Color.white else theme.colors.text_main,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
            .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
        })) {
            ocrCurrentPage();
        }

        // Narrate toggle
        if (dvui.button(@src(), if (state.app.comic.narrating) "Stop" else "Narrate", .{}, .{
            .id_extra = 41,
            .color_fill = if (state.app.comic.narrating) theme.colors.danger else theme.colors.accent,
            .color_text = dvui.Color.white,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
        })) {
            toggleNarration();
        }
    }

    // Show narration status
    if (state.app.comic.narrating) {
        _ = dvui.label(@src(), "Narrating page {d}...", .{state.app.comic.narrate_page + 1}, .{
            .color_text = theme.colors.accent,
            .padding = .{ .x = 12, .y = 4, .w = 0, .h = 0 },
        });
    }

    // Show OCR text if available
    {
        const pg = state.app.comic.current_page;
        if (pg < 128 and state.app.comic.ocr_done[pg]) {
            const tlen = state.app.comic.ocr_lens[pg];
            if (tlen > 0) {
                var ocr_box = dvui.box(@src(), .{ .dir = .vertical }, .{
                    .expand = .horizontal,
                    .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
                });
                defer ocr_box.deinit();

                _ = dvui.label(@src(), "Page Text:", .{}, .{
                    .color_text = theme.colors.accent,
                    .margin = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
                });

                var scroll = dvui.scrollArea(@src(), .{}, .{
                    .expand = .horizontal,
                    .min_size_content = .{ .w = 100, .h = 80 },
                    .max_size_content = .{ .w = std.math.floatMax(f32), .h = 200 },
                    .background = true,
                    .color_fill = dvui.Color{ .r = 10, .g = 10, .b = 14, .a = 255 },
                    .corner_radius = theme.dims.rad_sm,
                    .padding = dvui.Rect.all(8),
                });
                defer scroll.deinit();

                _ = dvui.label(@src(), "{s}", .{state.app.comic.ocr_texts[pg][0..tlen]}, .{
                    .color_text = theme.colors.text_main,
                });
            } else {
                _ = dvui.label(@src(), "No text detected on this page", .{}, .{
                    .color_text = theme.colors.text_muted,
                    .padding = .{ .x = 12, .y = 8, .w = 0, .h = 0 },
                });
            }
        }
    }
}

// ══════════════════════════════════════════════════════════
// Main Pane Content Rendering (full-area comic viewer)
// Called from ui.zig grid cell when provider == .comic_viewer
// ══════════════════════════════════════════════════════════

pub fn renderPaneContent(pane_idx: usize) void {
    _ = pane_idx;

    if (state.app.comic.is_loading) {
        // Show download progress
        var prog_buf: [64]u8 = undefined;
        const prog_str = std.fmt.bufPrintZ(&prog_buf, "Loading comic... {d}/{d} pages", .{
            state.app.comic.dl_progress, state.app.comic.page_count,
        }) catch "Loading...";
        _ = dvui.label(@src(), "{s}", .{prog_str}, .{
            .color_text = theme.colors.accent,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .expand = .both,
        });
        return;
    }

    // Title bar + navigation + controls
    {
        var nav_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 6, .y = 3, .w = 6, .h = 3 },
            .background = true,
            .color_fill = dvui.Color{ .r = 18, .g = 18, .b = 22, .a = 245 },
        });
        defer nav_row.deinit();

        // Prev issue
        if (state.app.comic.prev_url_len > 0) {
            if (dvui.button(@src(), "«", .{}, .{
                .color_fill = theme.colors.accent,
                .color_text = dvui.Color.white,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
            })) {
                loadComic(state.app.comic.prev_url[0..state.app.comic.prev_url_len]);
            }
        }

        // Title
        if (state.app.comic.title_len > 0) {
            _ = dvui.label(@src(), "{s}", .{safeUtf8(state.app.comic.title[0..state.app.comic.title_len])}, .{
                .color_text = theme.colors.text_main,
                .expand = .horizontal,
                .gravity_x = 0.5,
            });
        }

        // Page info + progress
        {
            var info_buf: [64]u8 = undefined;
            const info = if (state.app.comic.view_mode == .single_page)
                std.fmt.bufPrintZ(&info_buf, "{d}/{d}", .{ state.app.comic.current_page + 1, state.app.comic.page_count }) catch "?"
            else
                std.fmt.bufPrintZ(&info_buf, "{d}pp {d}↓", .{ state.app.comic.page_count, state.app.comic.dl_progress }) catch "?";
            _ = dvui.label(@src(), "{s}", .{info}, .{
                .color_text = theme.colors.text_muted,
                .padding = .{ .x = 4, .y = 0, .w = 2, .h = 0 },
            });
        }

        // View mode toggle
        {
            const mode_icon = if (state.app.comic.view_mode == .scroll) icons.tvg.lucide.@"scroll-text" else icons.tvg.lucide.@"book-open";
            if (dvui.buttonIcon(@src(), "comic-view-mode", mode_icon, .{}, .{}, .{
                .id_extra = 10,
                .color_fill = theme.colors.bg_glass,
                .color_text = theme.colors.text_main,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
                .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
            })) {
                state.app.comic.view_mode = if (state.app.comic.view_mode == .scroll) .single_page else .scroll;
            }
        }

        // Page navigation (works in both modes)
        if (state.app.comic.current_page > 0) {
            if (dvui.button(@src(), "‹", .{}, .{
                .id_extra = 11,
                .color_fill = theme.colors.bg_glass,
                .color_text = theme.colors.text_main,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 5, .y = 2, .w = 5, .h = 2 },
                .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
            })) {
                state.app.comic.current_page -= 1;
                state.app.comic.scroll_to_page = true;
            }
        }
        if (state.app.comic.current_page + 1 < state.app.comic.page_count) {
            if (dvui.button(@src(), "›", .{}, .{
                .id_extra = 12,
                .color_fill = theme.colors.bg_glass,
                .color_text = theme.colors.text_main,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 5, .y = 2, .w = 5, .h = 2 },
                .margin = .{ .x = 1, .y = 0, .w = 0, .h = 0 },
            })) {
                state.app.comic.current_page += 1;
                state.app.comic.scroll_to_page = true;
            }
        }

        // Next issue
        if (state.app.comic.next_url_len > 0) {
            if (dvui.button(@src(), "»", .{}, .{
                .id_extra = 1,
                .color_fill = theme.colors.accent,
                .color_text = dvui.Color.white,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
                .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
            })) {
                loadComic(state.app.comic.next_url[0..state.app.comic.next_url_len]);
            }
        }

        // Spacer to push narration controls to the right
        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }

        // OCR text toggle
        if (dvui.buttonIcon(@src(), "comic-ocr", icons.tvg.lucide.@"scan-text", .{}, .{}, .{
            .id_extra = 20,
            .color_fill = if (state.app.comic.show_ocr_overlay) theme.colors.accent else theme.colors.bg_glass,
            .color_text = if (state.app.comic.show_ocr_overlay) dvui.Color.white else theme.colors.text_main,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 5, .y = 2, .w = 5, .h = 2 },
            .margin = .{ .x = 1, .y = 0, .w = 0, .h = 0 },
        })) {
            ocrCurrentPage();
        }

        // Narrate toggle
        if (dvui.buttonIcon(@src(), "comic-narrate", if (state.app.comic.narrating) icons.tvg.lucide.@"circle-stop" else icons.tvg.lucide.@"volume-2", .{}, .{}, .{
            .id_extra = 21,
            .color_fill = if (state.app.comic.narrating) theme.colors.accent else theme.colors.bg_glass,
            .color_text = if (state.app.comic.narrating) dvui.Color.white else theme.colors.text_main,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 5, .y = 2, .w = 5, .h = 2 },
            .margin = .{ .x = 1, .y = 0, .w = 0, .h = 0 },
        })) {
            toggleNarration();
        }

        // Close (back to mpv)
        if (dvui.button(@src(), "X", .{}, .{
            .id_extra = 2,
            .color_fill = dvui.Color{ .r = 60, .g = 20, .b = 20, .a = 200 },
            .color_text = theme.colors.danger,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 5, .y = 2, .w = 5, .h = 2 },
            .margin = .{ .x = 3, .y = 0, .w = 0, .h = 0 },
        })) {
            // Stop narration if active
            state.app.comic.narrating = false;
            state.app.comic.show_ocr_overlay = false;
            if (state.app.active_player_idx < state.app.players.items.len) {
                state.app.players.items[state.app.active_player_idx].provider = .mpv;
            }
        }
    }

    // Content area
    // When narrating, force single page mode for reliable page advancement
    if (state.app.comic.scroll_to_page) {
        state.app.comic.scroll_to_page = false;
        if (state.app.comic.view_mode == .scroll) {
            state.app.comic.view_mode = .single_page;
        }
    }

    if (state.app.comic.view_mode == .single_page) {
        // Single page mode
        var sp_scroll = dvui.scrollArea(@src(), .{}, .{
            .expand = .both,
            .background = true,
            .color_fill = dvui.Color{ .r = 8, .g = 8, .b = 10, .a = 255 },
        });
        defer sp_scroll.deinit();

        // Get available width from scroll area for proper image scaling
        const avail_w = sp_scroll.data().contentRect().w;

        const pg = state.app.comic.current_page;
        if (pg < state.app.comic.page_count) {
            decodePageTexture(pg);
            if (state.app.comic.page_textures[pg]) |tex| {
                const tw = state.app.comic.page_widths[pg];
                const th = state.app.comic.page_heights[pg];
                // Fit-to-width: scale image to fill available width, maintain aspect ratio
                const display_w = if (avail_w > 10) avail_w - 4 else @as(f32, @floatFromInt(tw));
                const scale = display_w / @as(f32, @floatFromInt(tw));
                const display_h = @as(f32, @floatFromInt(th)) * scale;
                _ = dvui.image(@src(), .{ .source = .{ .texture = tex } }, .{
                    .id_extra = pg + 10000,
                    .min_size_content = .{ .w = display_w, .h = display_h },
                    .gravity_x = 0.5,
                    .gravity_y = 0.0,
                });
            } else {
                _ = dvui.label(@src(), "Downloading...", .{}, .{
                    .color_text = theme.colors.text_muted,
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .expand = .both,
                });
            }
        }
    } else {
        // Scroll mode — all pages stacked vertically
        var scroll = dvui.scrollArea(@src(), .{}, .{
            .expand = .both,
            .background = true,
            .color_fill = dvui.Color{ .r = 8, .g = 8, .b = 10, .a = 255 },
        });
        defer scroll.deinit();

        // Get available width from scroll area
        const avail_w = scroll.data().contentRect().w;

        // Only render pages near current page to avoid GPU memory exhaustion
        const render_start = if (state.app.comic.current_page > 2) state.app.comic.current_page - 2 else 0;
        const render_end = @min(state.app.comic.current_page + 5, state.app.comic.page_count);

        for (0..state.app.comic.page_count) |pg| {
            var page_box = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = pg,
                .gravity_x = 0.5,
                .padding = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
            });
            defer page_box.deinit();

            // Only decode/render pages in the visible window
            if (pg < render_start or pg >= render_end) {
                // Placeholder for off-screen pages — keep layout space
                var h_buf: [48]u8 = undefined;
                const h_lbl = std.fmt.bufPrintZ(&h_buf, "Page {d}", .{pg + 1}) catch "...";
                _ = dvui.label(@src(), "{s}", .{h_lbl}, .{
                    .id_extra = pg + 12000,
                    .color_text = theme.colors.text_muted,
                    .gravity_x = 0.5,
                    .min_size_content = .{ .w = 100, .h = 200 },
                });
                continue;
            }

            decodePageTexture(pg);

            if (state.app.comic.page_textures[pg]) |tex| {
                const tw = state.app.comic.page_widths[pg];
                const th = state.app.comic.page_heights[pg];
                // Fit-to-width: scale image to fill available width, maintain aspect ratio
                const display_w = if (avail_w > 10) avail_w - 4 else @as(f32, @floatFromInt(tw));
                const scale_s = display_w / @as(f32, @floatFromInt(tw));
                const display_h = @as(f32, @floatFromInt(th)) * scale_s;
                _ = dvui.image(@src(), .{ .source = .{ .texture = tex } }, .{
                    .id_extra = pg + 10000,
                    .min_size_content = .{ .w = display_w, .h = display_h },
                    .gravity_x = 0.5,
                });
            } else if (state.app.comic.page_pixels[pg] == null) {
                var lbl_buf: [48]u8 = undefined;
                const lbl = std.fmt.bufPrintZ(&lbl_buf, "Page {d} downloading...", .{pg + 1}) catch "?";
                _ = dvui.label(@src(), "{s}", .{lbl}, .{
                    .id_extra = pg + 11000,
                    .color_text = theme.colors.text_muted,
                    .gravity_x = 0.5,
                    .padding = .{ .x = 0, .y = 20, .w = 0, .h = 20 },
                });
            }
        }
    }

    // ═══════════════════════════════════════════════════════
    // OCR Text Overlay (shows extracted text at bottom)
    // ═══════════════════════════════════════════════════════
    if (state.app.comic.show_ocr_overlay) {
        const pg = state.app.comic.current_page;
        if (pg < 128 and state.app.comic.ocr_done[pg]) {
            const text_len = state.app.comic.ocr_lens[pg];
            var ocr_panel = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .background = true,
                .color_fill = dvui.Color{ .r = 10, .g = 10, .b = 14, .a = 230 },
                .color_border = theme.colors.accent,
                .border = .{ .x = 0, .y = 1, .w = 0, .h = 0 },
                .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
                .max_size_content = .{ .w = 0, .h = 120 },
            });
            defer ocr_panel.deinit();

            var ocr_scroll = dvui.scrollArea(@src(), .{}, .{
                .expand = .both,
            });
            defer ocr_scroll.deinit();

            if (text_len > 0) {
                _ = dvui.label(@src(), "{s}", .{state.app.comic.ocr_texts[pg][0..text_len]}, .{
                    .id_extra = 30000,
                    .color_text = theme.colors.text_main,
                });
            } else {
                _ = dvui.label(@src(), "No text detected on this page", .{}, .{
                    .id_extra = 30001,
                    .color_text = theme.colors.text_muted,
                });
            }
        } else if (pg < 128 and !state.app.comic.ocr_done[pg]) {
            _ = dvui.label(@src(), "Running OCR...", .{}, .{
                .id_extra = 30002,
                .color_text = theme.colors.accent,
                .padding = .{ .x = 10, .y = 4, .w = 0, .h = 4 },
            });
        }
    }

    // Narration indicator
    if (state.app.comic.narrating) {
        _ = dvui.label(@src(), "Narrating...", .{}, .{
            .id_extra = 30010,
            .color_text = theme.colors.accent,
            .padding = .{ .x = 10, .y = 3, .w = 0, .h = 3 },
            .background = true,
            .color_fill = dvui.Color{ .r = 10, .g = 10, .b = 14, .a = 200 },
        });
    }
}

/// Decode a single page from JPEG bytes → dvui.Texture (if not already done)
fn decodePageTexture(pg: usize) void {
    if (state.app.comic.page_pixels[pg] != null and state.app.comic.page_textures[pg] == null) {
        const raw = state.app.comic.page_pixels[pg].?;
        var w: c_int = 0;
        var h: c_int = 0;
        var channels: c_int = 0;
        const rgba = dvui.c.stbi_load_from_memory(
            raw.ptr,
            @as(c_int, @intCast(raw.len)),
            &w,
            &h,
            &channels,
            4,
        );
        if (rgba != null and w > 0 and h > 0) {
            const uw: u32 = @intCast(w);
            const uh: u32 = @intCast(h);
            const pixel_count = @as(usize, uw) * @as(usize, uh);
            const pma_slice: [*]const dvui.Color.PMA = @ptrCast(@alignCast(rgba));
            if (dvui.textureCreate(pma_slice[0..pixel_count], uw, uh, .linear, .rgba_32)) |tex| {
                state.app.comic.page_textures[pg] = tex;
                state.app.comic.page_widths[pg] = uw;
                state.app.comic.page_heights[pg] = uh;
            } else |_| {}
            dvui.c.stbi_image_free(rgba);
        }
    }
}
// ══════════════════════════════════════════════════════════
// OCR + TTS Narration
// ══════════════════════════════════════════════════════════

// Native ONNX Runtime OCR via C wrapper
const ocr_c = @cImport({
    @cInclude("ocr_ort.h");
});

var ocr_initialized: bool = false;

fn ensureOcrInit() bool {
    if (ocr_initialized) return true;

    // Model paths: prefer PP-OCRv5 (much better accuracy), fall back to v4
    const det_path = "models/ppocr_det_v5.onnx";
    const rec_path = "models/ppocr_rec_v5.onnx";
    const dict_path = "models/en_dict_v5.txt";

    const ret = ocr_c.ocr_init(det_path, rec_path, dict_path);
    if (ret != 0) {
        logs.pushLog("error", "comics", "OCR init failed — check models/ directory", true);
        return false;
    }
    ocr_initialized = true;
    logs.pushLog("info", "comics", "OCR initialized (PP-OCRv5 ONNX)", false);
    return true;
}

/// Run OCR on a comic page using native ONNX Runtime.
/// Decodes JPEG→RGBA, passes pixels to C wrapper, caches result.
pub fn ocrPage(pg: usize) void {
    if (pg >= state.app.comic.page_count) return;
    if (state.app.comic.ocr_done[pg]) return;

    const raw = state.app.comic.page_pixels[pg] orelse return;

    if (!ensureOcrInit()) {
        state.app.comic.ocr_done[pg] = true;
        return;
    }

    // Decode JPEG to RGBA
    var w: c_int = 0;
    var h: c_int = 0;
    var channels: c_int = 0;
    const rgba = dvui.c.stbi_load_from_memory(
        raw.ptr,
        @as(c_int, @intCast(raw.len)),
        &w,
        &h,
        &channels,
        4,
    );
    if (rgba == null or w <= 0 or h <= 0) {
        state.app.comic.ocr_done[pg] = true;
        return;
    }
    defer dvui.c.stbi_image_free(rgba);

    // Run OCR via C wrapper
    const result = ocr_c.ocr_recognize_rgba(
        @ptrCast(rgba),
        w,
        h,
    );

    if (result != null) {
        const text: [*:0]const u8 = result.?;
        const text_slice = std.mem.span(text);
        const trimmed = std.mem.trim(u8, text_slice, " \t\r\n");
        const len = @min(trimmed.len, 4095);
        @memcpy(state.app.comic.ocr_texts[pg][0..len], trimmed[0..len]);
        state.app.comic.ocr_lens[pg] = len;
        ocr_c.ocr_free_text(result);
    }
    state.app.comic.ocr_done[pg] = true;
}

/// Toggle auto-narration mode
pub fn toggleNarration() void {
    if (state.app.comic.narrating) {
        // Stop narration
        state.app.comic.narrating = false;
        logs.pushLog("info", "comics", "Narration stopped", false);
    } else {
        // Start narration from current page
        state.app.comic.narrating = true;
        state.app.comic.narrate_page = state.app.comic.current_page;

        if (state.app.comic.narrate_thread) |t| t.join();
        state.app.comic.narrate_thread = std.Thread.spawn(.{}, narrationThread, .{}) catch {
            state.app.comic.narrating = false;
            logs.pushLog("error", "comics", "Failed to start narration thread", true);
            return;
        };
        logs.pushLog("info", "comics", "Narration started", false);
    }
}

/// Filter OCR text to extract only speech bubble dialogue.
/// Strips sound effects (BOOM, CRASH), page numbers, credits, watermarks.
fn filterDialogue(raw: []const u8, out: *[4096]u8) usize {
    var pos: usize = 0;

    // Process line by line
    var line_start: usize = 0;
    for (raw, 0..) |ch, i| {
        if (ch == '\n' or i == raw.len - 1) {
            const end = if (ch == '\n') i else i + 1;
            if (end > line_start) {
                const line = std.mem.trim(u8, raw[line_start..end], " \t\r\n");
                if (isDialogueLine(line)) {
                    // Append to output
                    const space_needed = line.len + 1; // +1 for space separator
                    if (pos + space_needed < 4096) {
                        if (pos > 0) {
                            out[pos] = ' ';
                            pos += 1;
                        }
                        @memcpy(out[pos .. pos + line.len], line);
                        pos += line.len;
                    }
                }
            }
            line_start = i + 1;
        }
    }

    return pos;
}

/// Determine if an OCR text line is likely speech bubble dialogue (not SFX/credits/noise).
fn isDialogueLine(line: []const u8) bool {
    if (line.len < 2) return false;

    // Skip bare numbers (page numbers)
    var all_digits = true;
    for (line) |c| {
        if (!std.ascii.isDigit(c) and c != ' ' and c != '-' and c != '.') {
            all_digits = false;
            break;
        }
    }
    if (all_digits) return false;

    // Skip website/credit markers
    const noise_markers = [_][]const u8{
        "http",      ".com",          ".net",             ".org",             "www.",
        "©",
        "copyright", "readallcomics", "readcomicsonline", "chapter",          "vol.",
        "volume",    "issue",         "next chapter",     "previous chapter", "bookmark",
        "comment",   "loading",
    };
    var lower_buf: [256]u8 = undefined;
    const lower_len = @min(line.len, 255);
    for (0..lower_len) |i| lower_buf[i] = std.ascii.toLower(line[i]);
    const lower = lower_buf[0..lower_len];

    for (noise_markers) |marker| {
        if (std.mem.indexOf(u8, lower, marker) != null) return false;
    }

    // Count properties
    var upper_count: usize = 0;
    var lower_count: usize = 0;
    var alpha_count: usize = 0;
    var word_count: usize = 1;
    var prev_space = false;

    for (line) |c| {
        if (std.ascii.isUpper(c)) {
            upper_count += 1;
            alpha_count += 1;
        } else if (std.ascii.isLower(c)) {
            lower_count += 1;
            alpha_count += 1;
        }

        if (c == ' ') {
            if (!prev_space) word_count += 1;
            prev_space = true;
        } else {
            prev_space = false;
        }
    }

    if (alpha_count == 0) return false;

    // Single-word ALL-CAPS with 2-8 chars = SFX (BOOM, CRASH, WHAM, THUD, etc.)
    if (word_count == 1 and upper_count == alpha_count and alpha_count >= 2 and alpha_count <= 10) {
        // Common SFX patterns — reject them
        const sfx_patterns = [_][]const u8{
            "BOOM",    "CRASH",  "WHAM",   "THUD",   "BANG",    "CRACK",
            "SPLASH",  "WHOOSH", "SLAM",   "SMASH",  "POW",     "ZAP",
            "THWACK",  "CLANG",  "SNAP",   "CLICK",  "THUMP",   "ROAR",
            "SCREECH", "SWOOSH", "RUMBLE", "CRUNCH", "SHATTER", "KABOOM",
            "BLAM",    "FWOOSH", "KRACK",  "SKREEE",
        };
        for (sfx_patterns) |sfx| {
            if (std.mem.eql(u8, line, sfx)) return false;
        }
        // Other all-caps single words under 5 chars are also likely SFX
        if (alpha_count <= 5) return false;
    }

    // Two-word ALL-CAPS with total < 12 chars: likely SFX too (HA HA, NO NO)
    if (word_count == 2 and upper_count == alpha_count and alpha_count < 12) {
        return false;
    }

    // Multi-word text with mixed case or longer sentences = dialogue
    // ALL-CAPS multi-word is OK if it's 3+ words (dialogue often in caps in comics)
    if (word_count >= 2 and alpha_count >= 4) return true;

    // Single word with lowercase = likely dialogue fragment
    if (lower_count > 0 and alpha_count >= 3) return true;

    return false;
}

/// Background narration: OCR current page → TTS → wait → advance → repeat
fn narrationThread() void {
    // NOTE: `narrating` is read without synchronization — the worst case is
    // one extra loop iteration before we notice cancellation.  Acceptable
    // because the thread performs no destructive writes once cancelled.
    const ai_voice = @import("ai_voice.zig");

    // Ensure TTS server is warmed up (with timeout so we don't block forever)
    ai_voice.ensureTtsServer();

    while (state.app.comic.narrating) {
        const pg = state.app.comic.narrate_page;
        if (pg >= state.app.comic.page_count) {
            // Reached end of comic
            state.app.comic.narrating = false;
            logs.pushLog("info", "comics", "Narration complete (end of issue)", false);
            break;
        }

        // Wait for page image to be downloaded
        var wait: usize = 0;
        while (state.app.comic.page_pixels[pg] == null and wait < 100 and state.app.comic.narrating) : (wait += 1) {
            @import("../core/io_global.zig").sleep(100 * std.time.ns_per_ms);
        }
        if (!state.app.comic.narrating) break;
        if (state.app.comic.page_pixels[pg] == null) {
            // Skip page if still not downloaded
            state.app.comic.narrate_page += 1;
            continue;
        }

        // Update visible page to match narration + trigger scroll
        state.app.comic.current_page = pg;
        state.app.comic.scroll_to_page = true; // Signal render loop to scroll

        // OCR the page
        ocrPage(pg);

        // Get the text and filter to dialogue only
        const text_len = state.app.comic.ocr_lens[pg];
        var had_dialogue = false;

        if (text_len > 0) {
            const text = state.app.comic.ocr_texts[pg][0..text_len];

            // Filter: extract only speech bubble dialogue, skip SFX/credits/noise
            var dialogue_buf: [4096]u8 = undefined;
            const dialogue_len = filterDialogue(text, &dialogue_buf);

            if (dialogue_len > 0) {
                had_dialogue = true;

                // Wait for any existing speech to finish
                while (ai_voice.is_speaking and state.app.comic.narrating) {
                    @import("../core/io_global.zig").sleep(50 * std.time.ns_per_ms);
                }
                if (!state.app.comic.narrating) break;

                // Speak the filtered dialogue
                ai_voice.speakResponse(dialogue_buf[0..dialogue_len]);

                // Wait for TTS to finish
                while (ai_voice.is_speaking and state.app.comic.narrating) {
                    @import("../core/io_global.zig").sleep(50 * std.time.ns_per_ms);
                }
                if (!state.app.comic.narrating) break;
            }
        }

        // Pause between pages:
        //   - Pages with dialogue: 1 second (TTS already provided viewing time)
        //   - Pages without dialogue: 3 seconds (give user time to read/view)
        const pause_iters: usize = if (had_dialogue) 10 else 30;
        var pause: usize = 0;
        while (pause < pause_iters and state.app.comic.narrating) : (pause += 1) {
            @import("../core/io_global.zig").sleep(100 * std.time.ns_per_ms);
        }

        // Advance to next page
        if (state.app.comic.narrating) {
            state.app.comic.narrate_page += 1;
        }
    }

    state.app.comic.narrating = false;
}

/// Run OCR on current page in background (for "show text" button)
pub fn ocrCurrentPage() void {
    const pg = state.app.comic.current_page;
    if (pg >= state.app.comic.page_count) return;
    if (state.app.comic.ocr_done[pg]) {
        state.app.comic.show_ocr_overlay = !state.app.comic.show_ocr_overlay;
        return;
    }

    if (state.app.comic.ocr_thread) |t| t.join();
    state.app.comic.ocr_thread = std.Thread.spawn(.{}, struct {
        fn run(page: usize) void {
            ocrPage(page);
            state.app.comic.show_ocr_overlay = true;
        }
    }.run, .{pg}) catch null;
}

// ══════════════════════════════════════════════════════════
// String search helpers
// ══════════════════════════════════════════════════════════

fn findSubstring(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, haystack, needle);
}

fn findBetween(html: []const u8, start_tag: []const u8, end_tag: []const u8) ?[]const u8 {
    const s = std.mem.indexOf(u8, html, start_tag) orelse return null;
    const content_start = s + start_tag.len;
    const e = std.mem.indexOf(u8, html[content_start..], end_tag) orelse return null;
    return html[content_start .. content_start + e];
}

fn findLinkWithText(html: []const u8, text: []const u8) ?[]const u8 {
    // Find: href="URL"...>...text...
    var pos: usize = 0;
    while (pos < html.len) {
        const text_pos = std.mem.indexOf(u8, html[pos..], text) orelse return null;
        const abs_text = pos + text_pos;

        // Look backwards for href="
        const search_start = if (abs_text > 500) abs_text - 500 else 0;
        const before = html[search_start..abs_text];

        // Find last href=" before this text
        var last_href: ?usize = null;
        var scan: usize = 0;
        while (scan < before.len) {
            if (std.mem.indexOf(u8, before[scan..], "href=\"")) |h| {
                last_href = search_start + scan + h + 6;
                scan += h + 1;
            } else break;
        }

        if (last_href) |href_start| {
            if (std.mem.indexOfScalar(u8, html[href_start..], '"')) |href_end| {
                return html[href_start .. href_start + href_end];
            }
        }

        pos = abs_text + text.len;
    }
    return null;
}
