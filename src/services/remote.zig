const std = @import("std");
const state = @import("../core/state.zig");
const c = @import("../core/c.zig");
const player = @import("../player/player.zig");

// ══════════════════════════════════════════════════════════
// Web Remote Control — JSON API for ZigZag Web UI
// API bridge on :9876, Web UI (Ziex) on :3000
// ══════════════════════════════════════════════════════════

var server_thread: ?std.Thread = null;
var running: bool = false;
pub var port: u16 = 41595;

pub fn start() void {
    if (running) return;
    running = true;
    server_thread = std.Thread.spawn(.{}, serverLoop, .{}) catch null;
}

pub fn stop() void {
    running = false;
}

pub fn isRunning() bool {
    return running;
}

fn serverLoop() void {
    const addr = std.Io.net.IpAddress.parseIp4("0.0.0.0", port) catch return;
    var server = addr.listen(@import("../core/io_global.zig").io(), .{ .reuse_address = true }) catch return;
    defer server.deinit(@import("../core/io_global.zig").io());

    std.debug.print("[remote] JSON API listening on http://0.0.0.0:{d}\n", .{port});
    std.debug.print("[remote] Web UI: cd web && zig build dev (http://0.0.0.0:3000)\n", .{});

    while (running) {
        const conn = server.accept(@import("../core/io_global.zig").io()) catch continue;
        defer conn.close(@import("../core/io_global.zig").io());
        handleRequest(conn) catch {};
    }
}

fn handleRequest(stream: std.Io.net.Stream) !void {
    var buf: [4096]u8 = undefined;
    const n = @import("../core/io_global.zig").streamReadAll(stream, &buf) catch return;
    if (n == 0) return;
    const request = buf[0..n];

    var lines = std.mem.splitScalar(u8, request, '\n');
    const first_line = lines.next() orelse return;
    var parts = std.mem.splitScalar(u8, first_line, ' ');
    _ = parts.next() orelse return; // method
    const full_path = parts.next() orelse return;

    // Parse path and query string
    var path_parts = std.mem.splitScalar(u8, full_path, '?');
    const path = path_parts.next() orelse return;
    const query = path_parts.next() orelse "";

    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        serveStaticFile(stream, "web/index.html", "text/html");
    } else if (std.mem.startsWith(u8, path, "/api/")) {
        handleApi(stream, path[4..], query);
    } else {
        const resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found";
        _ = @import("../core/io_global.zig").streamWriteAll(stream, resp) catch {};
    }
}

fn getQueryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        var kv = std.mem.splitScalar(u8, pair, '=');
        const k = kv.next() orelse continue;
        const v = kv.next() orelse continue;
        if (std.mem.eql(u8, k, key)) return v;
    }
    return null;
}

fn handleApi(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    // ── Non-player endpoints checked first ──
    // Search
    if (std.mem.eql(u8, api_path, "/search")) {
        apiSearch(stream, query);
        return;
    }
    if (std.mem.eql(u8, api_path, "/history")) {
        apiHistory(stream);
        return;
    }
    if (std.mem.eql(u8, api_path, "/rss")) {
        apiRssList(stream);
        return;
    }
    if (std.mem.eql(u8, api_path, "/rss/refresh")) {
        const rss = @import("rss.zig");
        const idx_str = getQueryParam(query, "idx") orelse "0";
        const idx = std.fmt.parseInt(usize, idx_str, 10) catch 0;
        rss.fetchFeed(idx);
        sendJson(stream, "{\"ok\":true}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/downloads")) {
        apiDownloads(stream, query);
        return;
    }
    if (std.mem.eql(u8, api_path, "/downloads/play")) {
        apiDownloadsPlay(stream, query);
        return;
    }
    if (std.mem.eql(u8, api_path, "/settings")) {
        apiSettingsGet(stream);
        return;
    }
    if (std.mem.eql(u8, api_path, "/settings/toggle")) {
        apiSettingsToggle(query);
        sendJson(stream, "{\"ok\":true}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/settings/open")) {
        state.app.settings_open = true;
        sendJson(stream, "{\"ok\":true,\"action\":\"settings_open\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/settings/close")) {
        state.app.settings_open = false;
        sendJson(stream, "{\"ok\":true,\"action\":\"settings_close\"}");
        return;
    }
    // TMDB
    if (std.mem.startsWith(u8, api_path, "/tmdb")) {
        apiTmdb(stream, api_path, query);
        return;
    }
    // YouTube
    if (std.mem.startsWith(u8, api_path, "/youtube")) {
        apiYoutube(stream, api_path, query);
        return;
    }
    // Anime
    if (std.mem.startsWith(u8, api_path, "/anime")) {
        apiAnime(stream, api_path, query);
        return;
    }
    // Comics
    if (std.mem.startsWith(u8, api_path, "/comics")) {
        apiComics(stream, api_path, query);
        return;
    }
    // Jellyfin
    if (std.mem.startsWith(u8, api_path, "/jellyfin")) {
        apiJellyfin(stream, api_path, query);
        return;
    }
    // Unified Search — fans out to all sources
    if (std.mem.eql(u8, api_path, "/unified_search")) {
        apiUnifiedSearch(stream, query);
        return;
    }
    if (std.mem.eql(u8, api_path, "/recommendations")) {
        sendJson(stream, "{\"items\":[]}");
        return;
    }

    // ── Player-dependent endpoints ──
    if (state.app.players.items.len == 0) {
        sendJson(stream, "{\"error\":\"no player\"}");
        return;
    }
    const ap = state.app.players.items[state.app.active_player_idx];

    // ── Player controls ──
    if (std.mem.eql(u8, api_path, "/toggle")) {
        _ = c.mpv.mpv_command_string(ap.mpv_ctx, "cycle pause");
        sendJson(stream, "{\"ok\":true,\"action\":\"toggle\"}");
    } else if (std.mem.eql(u8, api_path, "/fwd")) {
        _ = c.mpv.mpv_command_string(ap.mpv_ctx, "seek 10");
        sendJson(stream, "{\"ok\":true,\"action\":\"fwd\"}");
    } else if (std.mem.eql(u8, api_path, "/back")) {
        _ = c.mpv.mpv_command_string(ap.mpv_ctx, "seek -10");
        sendJson(stream, "{\"ok\":true,\"action\":\"back\"}");
    } else if (std.mem.eql(u8, api_path, "/vol_up")) {
        _ = c.mpv.mpv_command_string(ap.mpv_ctx, "add volume 5");
        sendJson(stream, "{\"ok\":true,\"action\":\"vol_up\"}");
    } else if (std.mem.eql(u8, api_path, "/vol_down")) {
        _ = c.mpv.mpv_command_string(ap.mpv_ctx, "add volume -5");
        sendJson(stream, "{\"ok\":true,\"action\":\"vol_down\"}");
    } else if (std.mem.eql(u8, api_path, "/mute")) {
        _ = c.mpv.mpv_command_string(ap.mpv_ctx, "cycle mute");
        sendJson(stream, "{\"ok\":true,\"action\":\"mute\"}");
    } else if (std.mem.eql(u8, api_path, "/fullscreen")) {
        state.app.fullscreen_player_idx = if (state.app.fullscreen_player_idx == null) state.app.active_player_idx else null;
        sendJson(stream, "{\"ok\":true,\"action\":\"fullscreen\"}");
    } else if (std.mem.eql(u8, api_path, "/next_audio")) {
        _ = c.mpv.mpv_command_string(ap.mpv_ctx, "cycle audio");
        sendJson(stream, "{\"ok\":true,\"action\":\"next_audio\"}");
    } else if (std.mem.eql(u8, api_path, "/next_sub")) {
        _ = c.mpv.mpv_command_string(ap.mpv_ctx, "cycle sub");
        sendJson(stream, "{\"ok\":true,\"action\":\"next_sub\"}");
    } else if (std.mem.eql(u8, api_path, "/flip")) {
        ap.toggleFlip();
        sendJson(stream, "{\"ok\":true,\"action\":\"flip\"}");
    } else if (std.mem.eql(u8, api_path, "/rotate")) {
        ap.cycleRotation();
        sendJson(stream, "{\"ok\":true,\"action\":\"rotate\"}");

    // ── Volume set ──
    } else if (std.mem.eql(u8, api_path, "/volume")) {
        if (getQueryParam(query, "v")) |v_str| {
            var cmd_buf: [64]u8 = undefined;
            const cmd = std.fmt.bufPrintZ(&cmd_buf, "set volume {s}", .{v_str}) catch return;
            _ = c.mpv.mpv_command_string(ap.mpv_ctx, cmd.ptr);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"volume\"}");

    // ── Seek by percentage ──
    } else if (std.mem.eql(u8, api_path, "/seek_pct")) {
        if (getQueryParam(query, "v")) |v_str| {
            const pct = std.fmt.parseInt(i32, v_str, 10) catch 0;
            var dur: f64 = 0;
            _ = c.mpv.mpv_get_property(ap.mpv_ctx, "duration", c.mpv.MPV_FORMAT_DOUBLE, &dur);
            if (dur > 0) {
                const target = dur * @as(f64, @floatFromInt(pct)) / 100.0;
                var cmd_buf: [64]u8 = undefined;
                const cmd = std.fmt.bufPrintZ(&cmd_buf, "seek {d:.1} absolute", .{target}) catch return;
                _ = c.mpv.mpv_command_string(ap.mpv_ctx, cmd.ptr);
            }
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"seek_pct\"}");

    // ── Load URL/magnet ──
    } else if (std.mem.eql(u8, api_path, "/load")) {
        if (getQueryParam(query, "url")) |url| {
            // URL-decode would go here; for now pass raw
            var url_buf: [2048]u8 = undefined;
            const url_z = std.fmt.bufPrintZ(&url_buf, "{s}", .{url}) catch return;
            ap.load_file(url_z.ptr);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"load\"}");

    // ── Status (enhanced) ──
    } else if (std.mem.eql(u8, api_path, "/status")) {
        var pos: f64 = 0;
        var dur: f64 = 0;
        var vol: f64 = 0;
        var paused: c_int = 0;
        _ = c.mpv.mpv_get_property(ap.mpv_ctx, "time-pos", c.mpv.MPV_FORMAT_DOUBLE, &pos);
        _ = c.mpv.mpv_get_property(ap.mpv_ctx, "duration", c.mpv.MPV_FORMAT_DOUBLE, &dur);
        _ = c.mpv.mpv_get_property(ap.mpv_ctx, "volume", c.mpv.MPV_FORMAT_DOUBLE, &vol);
        _ = c.mpv.mpv_get_property(ap.mpv_ctx, "pause", c.mpv.MPV_FORMAT_FLAG, &paused);

        // Get media title
        var title_prop: [*c]u8 = null;
        _ = c.mpv.mpv_get_property(ap.mpv_ctx, "media-title", c.mpv.MPV_FORMAT_STRING, @ptrCast(&title_prop));
        const title_str = if (title_prop != null) std.mem.span(title_prop) else "No media";

        var json: [512]u8 = undefined;
        const json_str = std.fmt.bufPrint(&json, "{{\"pos\":{d:.1},\"dur\":{d:.1},\"vol\":{d:.0},\"paused\":{s},\"title\":\"{s}\"}}", .{
            pos, dur, vol, if (paused != 0) "true" else "false", title_str,
        }) catch return;
        sendJson(stream, json_str);

    // ── Queue ──
    } else if (std.mem.eql(u8, api_path, "/queue")) {
        const queue_svc = @import("queue.zig");
        var json_buf: [8192]u8 = undefined;
        var w = std.Io.Writer.fixed(&json_buf);
        w.writeAll("{\"items\":[") catch return;
        var i: usize = 0;
        while (i < queue_svc.queue_count) : (i += 1) {
            const item = queue_svc.queue_items[i];
            if (i > 0) w.writeAll(",") catch return;
            w.print("{{\"url\":\"{s}\",\"played\":{s}}}", .{
                item.url[0..item.url_len],
                if (item.played) "true" else "false",
            }) catch return;
        }
        w.writeAll("]}") catch return;
        sendJson(stream, json_buf[0..w.end]);

    // ── Watch Party ──
    } else if (std.mem.eql(u8, api_path, "/party/host")) {
        const wp = @import("watch_party.zig");
        wp.hostParty();
        sendJson(stream, "{\"ok\":true,\"action\":\"party_host\"}");
    } else if (std.mem.eql(u8, api_path, "/party/join")) {
        if (getQueryParam(query, "ip")) |ip| {
            const wp = @import("watch_party.zig");
            wp.joinParty(ip);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"party_join\"}");
    } else if (std.mem.eql(u8, api_path, "/party/status")) {
        sendJson(stream, "{\"connected\":false}");
    } else if (std.mem.eql(u8, api_path, "/cast/devices")) {
        sendJson(stream, "{\"devices\":[]}");
    } else if (std.mem.eql(u8, api_path, "/cast/start")) {
        sendJson(stream, "{\"ok\":true,\"action\":\"cast_start\"}");
    } else {
        sendJson(stream, "{\"error\":\"unknown\"}");
    }
}

fn sendJson(stream: std.Io.net.Stream, json: []const u8) void {
    var header: [256]u8 = undefined;
    const h = std.fmt.bufPrint(&header, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nContent-Length: {d}\r\n\r\n", .{json.len}) catch return;
    _ = @import("../core/io_global.zig").streamWriteAll(stream, h) catch {};
    _ = @import("../core/io_global.zig").streamWriteAll(stream, json) catch {};
}

fn serveStaticFile(stream: std.Io.net.Stream, path: []const u8, content_type: []const u8) void {
    const alloc = @import("../core/alloc.zig").allocator;
    const file = @import("../core/io_global.zig").cwdOpenFile(path, .{}) catch {
        const resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found";
        _ = @import("../core/io_global.zig").streamWriteAll(stream, resp) catch {};
        return;
    };
    defer file.close(@import("../core/io_global.zig").io());
    const stat = file.stat(@import("../core/io_global.zig").io()) catch return;
    const body = @import("../core/io_global.zig").readToEndAlloc(file, alloc, 512 * 1024) catch return;
    defer alloc.free(body);

    var header: [512]u8 = undefined;
    const h = std.fmt.bufPrint(&header, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {d}\r\n\r\n", .{content_type, stat.size}) catch return;
    _ = @import("../core/io_global.zig").streamWriteAll(stream, h) catch {};
    _ = @import("../core/io_global.zig").streamWriteAll(stream, body) catch {};
}

fn urlDecode(src: []const u8, buf: []u8) ?[]const u8 {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len and o < buf.len) {
        if (src[i] == '%' and i + 2 < src.len) {
            buf[o] = std.fmt.parseInt(u8, src[i+1..i+3], 16) catch {
                buf[o] = src[i];
                i += 1;
                o += 1;
                continue;
            };
            i += 3;
            o += 1;
        } else if (src[i] == '+') {
            buf[o] = ' ';
            i += 1;
            o += 1;
        } else {
            buf[o] = src[i];
            i += 1;
            o += 1;
        }
    }
    if (o == 0) return null;
    return buf[0..o];
}

fn escJsonSlice(s: []const u8) []const u8 {
    return s;
}

// ══════════════════════════════════════════════════
// Non-player API handlers
// ══════════════════════════════════════════════════

fn apiSearch(stream: std.Io.net.Stream, query: []const u8) void {
    if (getQueryParam(query, "q")) |q| {
        const search_svc = @import("search.zig");
        var decoded: [256]u8 = undefined;
        const dq = urlDecode(q, &decoded) orelse q;
        search_svc.triggerSearch(dq);
    }
    const search_svc = @import("search.zig");
    search_svc.search_results_mutex.lock();
    defer search_svc.search_results_mutex.unlock();
    var json_buf: [32768]u8 = undefined;
    var w = std.Io.Writer.fixed(&json_buf);
    w.writeAll("{\"results\":[") catch return;
    var count: usize = 0;
    for (search_svc.search_results.items) |r| {
        if (count > 0) w.writeAll(",") catch return;
        w.print("{{\"title\":\"{s}\",\"size\":\"{s}\",\"seeds\":\"{s}\",\"source\":\"{s}\",\"magnet\":\"{s}\"}}", .{
            escJsonSlice(r.name), escJsonSlice(r.size), escJsonSlice(r.seeds),
            escJsonSlice(r.engine), escJsonSlice(r.link),
        }) catch return;
        count += 1;
        if (count >= 50) break;
    }
    w.writeAll("],\"searching\":") catch return;
    w.writeAll(if (search_svc.is_searching) "true" else "false") catch return;
    w.writeAll("}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

fn apiHistory(stream: std.Io.net.Stream) void {
    var json_buf: [16384]u8 = undefined;
    var w = std.Io.Writer.fixed(&json_buf);
    w.writeAll("{\"items\":[") catch return;
    var hi: usize = 0;
    while (hi < state.app.search_history_count) : (hi += 1) {
        const q = state.app.search_history_buf[hi][0..state.app.search_history_len[hi]];
        if (hi > 0) w.writeAll(",") catch return;
        w.print("\"{s}\"", .{escJsonSlice(q)}) catch return;
    }
    w.writeAll("]}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

fn apiRssList(stream: std.Io.net.Stream) void {
    const rss = @import("rss.zig");
    var json_buf: [32768]u8 = undefined;
    var w = std.Io.Writer.fixed(&json_buf);
    w.writeAll("{\"feeds\":[") catch return;
    for (0..rss.feed_count) |fi| {
        const f = &rss.feeds[fi];
        if (fi > 0) w.writeAll(",") catch return;
        w.print("\"{s}\"", .{f.name[0..f.name_len]}) catch return;
    }
    w.writeAll("],\"items\":[") catch return;
    for (0..rss.item_count) |ri| {
        const item = &rss.items[ri];
        if (ri > 0) w.writeAll(",") catch return;
        w.print("{{\"title\":\"{s}\",\"seeds\":{d},\"peers\":{d},\"size\":{d},\"magnet\":\"{s}\"}}", .{
            escJsonSlice(item.title[0..item.title_len]),
            item.seeds, item.peers, item.size_bytes,
            escJsonSlice(item.magnet[0..item.magnet_len]),
        }) catch return;
    }
    w.writeAll("],\"fetching\":") catch return;
    w.writeAll(if (rss.is_fetching) "true" else "false") catch return;
    w.writeAll("}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

fn apiDownloads(stream: std.Io.net.Stream, query: []const u8) void {
    const paths = @import("../core/paths.zig");
    var path_buf: [512]u8 = undefined;
    const dl_path = if (state.app.save_path_len > 0)
        state.app.save_path_buf[0..state.app.save_path_len]
    else
        paths.defaultSavePath(&path_buf);

    const subdir = getQueryParam(query, "dir") orelse "";
    var full_path_buf: [1024]u8 = undefined;
    const browse_path = if (subdir.len > 0)
        std.fmt.bufPrintZ(&full_path_buf, "{s}/{s}", .{ dl_path, subdir }) catch dl_path
    else
        dl_path;

    var json_buf: [32768]u8 = undefined;
    var w = std.Io.Writer.fixed(&json_buf);
    w.print("{{\"path\":\"{s}\",\"files\":[", .{escJsonSlice(browse_path)}) catch return;

    var dir = @import("../core/io_global.zig").cwdOpenDir(browse_path, .{ .iterate = true }) catch {
        w.writeAll("],\"error\":\"cannot open directory\"}") catch return;
        sendJson(stream, json_buf[0..w.end]);
        return;
    };
    defer dir.close(@import("../core/io_global.zig").io());

    var iter = dir.iterate();
    var count: usize = 0;
    while (iter.next(@import("../core/io_global.zig").io()) catch null) |entry| {
        if (count >= 100) break;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (std.mem.endsWith(u8, entry.name, ".torrent")) continue;
        if (std.mem.endsWith(u8, entry.name, ".parts")) continue;
        if (count > 0) w.writeAll(",") catch return;
        const is_dir = entry.kind == .directory;
        var size: u64 = 0;
        if (!is_dir) {
            if (dir.openFile(@import("../core/io_global.zig").io(), entry.name, .{})) |file| {
                if (file.stat(@import("../core/io_global.zig").io())) |st| { size = st.size; } else |_| {}
                file.close(@import("../core/io_global.zig").io());
            } else |_| {}
        }
        w.print("{{\"name\":\"{s}\",\"is_dir\":{s},\"size\":{d}}}", .{
            escJsonSlice(entry.name),
            if (is_dir) "true" else "false",
            size,
        }) catch return;
        count += 1;
    }
    w.writeAll("]}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

fn apiDownloadsPlay(stream: std.Io.net.Stream, query: []const u8) void {
    if (getQueryParam(query, "file")) |file_raw| {
        const paths = @import("../core/paths.zig");
        var path_buf: [512]u8 = undefined;
        const dl_path = if (state.app.save_path_len > 0)
            state.app.save_path_buf[0..state.app.save_path_len]
        else
            paths.defaultSavePath(&path_buf);
        var decoded: [512]u8 = undefined;
        const file_name = urlDecode(file_raw, &decoded) orelse file_raw;
        var full_buf: [1024]u8 = undefined;
        if (std.fmt.bufPrintZ(&full_buf, "{s}/{s}", .{ dl_path, file_name })) |full_path| {
            if (state.app.players.items.len > 0) {
                const plyr = state.app.players.items[state.app.active_player_idx];
                plyr.load_file(full_path.ptr);
            }
        } else |_| {}
    }
    sendJson(stream, "{\"ok\":true}");
}

fn apiSettingsGet(stream: std.Io.net.Stream) void {
    var json_buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&json_buf);
    w.print("{{\"auto_advance\":{s},\"incognito\":{s},\"sponsorblock\":{s},\"nsfw_filter\":{s}}}", .{
        if (state.app.auto_advance) "true" else "false",
        if (state.app.incognito_mode) "true" else "false",
        if (state.app.sponsorblock_enabled) "true" else "false",
        if (state.app.nsfw_filter_enabled) "true" else "false",
    }) catch return;
    sendJson(stream, json_buf[0..w.end]);
}

fn apiSettingsToggle(query: []const u8) void {
    if (getQueryParam(query, "key")) |key| {
        if (std.mem.eql(u8, key, "auto_advance")) {
            state.app.auto_advance = !state.app.auto_advance;
        } else if (std.mem.eql(u8, key, "incognito")) {
            state.app.incognito_mode = !state.app.incognito_mode;
        } else if (std.mem.eql(u8, key, "sponsorblock")) {
            state.app.sponsorblock_enabled = !state.app.sponsorblock_enabled;
        } else if (std.mem.eql(u8, key, "nsfw_filter")) {
            state.app.nsfw_filter_enabled = !state.app.nsfw_filter_enabled;
        }
    }
}

fn apiTmdb(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    if (std.mem.eql(u8, api_path, "/tmdb/search")) {
        if (getQueryParam(query, "q")) |q| {
            var decoded: [256]u8 = undefined;
            const dq = urlDecode(q, &decoded) orelse q;
            // Copy to tmdb search buf and trigger
            const slen = @min(dq.len, 127);
            @memcpy(state.app.tmdb.search_buf[0..slen], dq[0..slen]);
            state.app.tmdb.search_buf[slen] = 0;
            state.app.tmdb.view = .Search;
            state.app.tmdb.page = 1;
            const tmdb_api = @import("tmdb_api.zig");
            tmdb_api.fetchCurrentView(false);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"tmdb_search\"}");
        return;
    }
    // Return current TMDB results
    var json_buf: [32768]u8 = undefined;
    var w = std.Io.Writer.fixed(&json_buf);
    w.writeAll("{\"items\":[") catch return;
    const items = &state.app.tmdb.results;
    for (items.items, 0..) |item, idx| {
        if (idx > 0) w.writeAll(",") catch return;
        if (idx >= 30) break;
        const rating_pct = @as(u8, @intFromFloat(std.math.clamp(item.rating * 10.0, 0.0, 100.0)));
        w.print("{{\"id\":{d},\"title\":\"{s}\",\"year\":\"{s}\",\"rating\":{d},\"type\":\"{s}\",\"overview\":\"{s}\"}}", .{
            item.id,
            escJsonSlice(item.title[0..item.title_len]),
            escJsonSlice(item.year[0..item.year_len]),
            rating_pct,
            escJsonSlice(item.media_type[0..item.media_type_len]),
            escJsonSlice(item.overview[0..@min(item.overview_len, 200)]),
        }) catch return;
    }
    w.writeAll("],\"loading\":") catch return;
    w.writeAll(if (state.app.tmdb.is_loading) "true" else "false") catch return;
    w.writeAll(",\"has_key\":") catch return;
    w.writeAll(if (state.app.tmdb.api_key_len > 0) "true" else "false") catch return;
    w.writeAll("}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

fn apiYoutube(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    if (std.mem.eql(u8, api_path, "/youtube/search")) {
        if (getQueryParam(query, "q")) |q| {
            var decoded: [256]u8 = undefined;
            const dq = urlDecode(q, &decoded) orelse q;
            const slen = @min(dq.len, 127);
            @memcpy(state.app.yt.search_buf[0..slen], dq[0..slen]);
            state.app.yt.search_buf[slen] = 0;
            const yt = @import("youtube.zig");
            yt.fetchYoutube(state.app.yt.search_buf[0..slen]);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"yt_search\"}");
        return;
    }
    // Return current results
    var json_buf: [32768]u8 = undefined;
    var w = std.Io.Writer.fixed(&json_buf);
    w.writeAll("{\"items\":[") catch return;
    for (state.app.yt.results.items, 0..) |item, idx| {
        if (idx > 0) w.writeAll(",") catch return;
        if (idx >= 30) break;
        const dur_min = @divTrunc(item.duration, 60);
        const dur_sec = @rem(item.duration, 60);
        w.print("{{\"id\":\"{s}\",\"title\":\"{s}\",\"channel\":\"{s}\",\"dur_min\":{d},\"dur_sec\":{d},\"views\":{d}}}", .{
            escJsonSlice(item.video_id[0..item.video_id_len]),
            escJsonSlice(item.title[0..item.title_len]),
            escJsonSlice(item.uploader[0..item.uploader_len]),
            dur_min, dur_sec, item.views,
        }) catch return;
    }
    w.writeAll("],\"loading\":") catch return;
    w.writeAll(if (state.app.yt.is_loading) "true" else "false") catch return;
    w.writeAll("}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

fn apiAnime(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    if (std.mem.eql(u8, api_path, "/anime/search")) {
        if (getQueryParam(query, "q")) |q| {
            var decoded: [256]u8 = undefined;
            const dq = urlDecode(q, &decoded) orelse q;
            const anime_svc = @import("anime.zig");
            anime_svc.searchAnime(dq);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"anime_search\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/anime/episodes")) {
        if (getQueryParam(query, "idx")) |idx_str| {
            const idx = std.fmt.parseInt(usize, idx_str, 10) catch 0;
            const anime_svc = @import("anime.zig");
            anime_svc.loadEpisodes(idx);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"load_episodes\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/anime/play")) {
        if (getQueryParam(query, "ep")) |ep| {
            var decoded: [16]u8 = undefined;
            const ep_str = urlDecode(ep, &decoded) orelse ep;
            const anime_svc = @import("anime.zig");
            anime_svc.playEpisode(ep_str);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"play_episode\"}");
        return;
    }
    // Return results + episodes
    var json_buf: [16384]u8 = undefined;
    var w = std.Io.Writer.fixed(&json_buf);
    w.writeAll("{\"results\":[") catch return;
    for (0..state.app.anime.result_count) |ri| {
        const r = state.app.anime.results[ri];
        if (r.name_len == 0) continue;
        if (ri > 0) w.writeAll(",") catch return;
        w.print("{{\"name\":\"{s}\",\"episodes\":{d}}}", .{
            escJsonSlice(r.name[0..r.name_len]), r.episodes,
        }) catch return;
    }
    w.writeAll("],\"episodes\":[") catch return;
    for (0..state.app.anime.episode_count) |ei| {
        const ep_len = state.app.anime.episode_list_lens[ei];
        if (ep_len == 0) continue;
        if (ei > 0) w.writeAll(",") catch return;
        w.print("\"{s}\"", .{state.app.anime.episode_list[ei][0..ep_len]}) catch return;
    }
    w.writeAll("],\"selected\":") catch return;
    if (state.app.anime.selected_idx) |si| {
        w.print("{d}", .{si}) catch return;
    } else {
        w.writeAll("null") catch return;
    }
    w.writeAll(",\"loading\":") catch return;
    w.writeAll(if (state.app.anime.is_loading) "true" else "false") catch return;
    w.writeAll(",\"stream_loading\":") catch return;
    w.writeAll(if (state.app.anime.stream_loading) "true" else "false") catch return;
    w.writeAll("}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

fn apiComics(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    if (std.mem.eql(u8, api_path, "/comics/load")) {
        if (getQueryParam(query, "url")) |url| {
            var decoded: [512]u8 = undefined;
            const comic_url = urlDecode(url, &decoded) orelse url;
            const comics_svc = @import("comics.zig");
            comics_svc.loadComic(comic_url);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"load_comic\"}");
        return;
    }
    // Return current state
    var json_buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&json_buf);
    w.print("{{\"loading\":{s},\"pages\":{d},\"current\":{d},\"url\":\"{s}\"}}", .{
        if (state.app.comic.is_loading) "true" else "false",
        state.app.comic.page_count,
        state.app.comic.current_page,
        escJsonSlice(state.app.comic.url_buf[0..state.app.comic.url_len]),
    }) catch return;
    sendJson(stream, json_buf[0..w.end]);
}

fn apiJellyfin(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    const jf = @import("jellyfin.zig");

    if (std.mem.eql(u8, api_path, "/jellyfin/login")) {
        // Set server URL, username, password then authenticate
        if (getQueryParam(query, "server")) |s| {
            var decoded: [256]u8 = undefined;
            const sv = urlDecode(s, &decoded) orelse s;
            const slen = @min(sv.len, 255);
            @memcpy(state.app.jf.server_url[0..slen], sv[0..slen]);
            state.app.jf.server_url_len = slen;
        }
        if (getQueryParam(query, "user")) |u| {
            var decoded: [128]u8 = undefined;
            const uv = urlDecode(u, &decoded) orelse u;
            const ulen = @min(uv.len, 127);
            @memcpy(state.app.jf.login_user_buf[0..ulen], uv[0..ulen]);
            state.app.jf.login_user_buf[ulen] = 0;
        }
        if (getQueryParam(query, "pass")) |p| {
            var decoded: [128]u8 = undefined;
            const pv = urlDecode(p, &decoded) orelse p;
            const plen = @min(pv.len, 127);
            @memcpy(state.app.jf.login_pass_buf[0..plen], pv[0..plen]);
            state.app.jf.login_pass_buf[plen] = 0;
        }
        jf.authenticate();
        sendJson(stream, "{\"ok\":true,\"action\":\"login\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/jellyfin/disconnect")) {
        jf.disconnect();
        sendJson(stream, "{\"ok\":true,\"action\":\"disconnect\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/jellyfin/libraries")) {
        jf.fetchLibraries();
        sendJson(stream, "{\"ok\":true,\"action\":\"fetch_libraries\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/jellyfin/browse")) {
        if (getQueryParam(query, "id")) |id| {
            var decoded: [64]u8 = undefined;
            const pid = urlDecode(id, &decoded) orelse id;
            jf.fetchItems(pid);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"browse\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/jellyfin/search")) {
        if (getQueryParam(query, "q")) |q| {
            var decoded: [256]u8 = undefined;
            const dq = urlDecode(q, &decoded) orelse q;
            const slen = @min(dq.len, 255);
            @memcpy(state.app.jf.search_buf[0..slen], dq[0..slen]);
            state.app.jf.search_buf[slen] = 0;
            jf.searchItems();
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"search\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/jellyfin/play")) {
        if (getQueryParam(query, "id")) |id| {
            var decoded: [64]u8 = undefined;
            const pid = urlDecode(id, &decoded) orelse id;
            jf.playItem(pid);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"play\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/jellyfin/play_audio")) {
        if (getQueryParam(query, "id")) |id| {
            var decoded: [64]u8 = undefined;
            const pid = urlDecode(id, &decoded) orelse id;
            jf.playAudioItem(pid);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"play_audio\"}");
        return;
    }

    // Default: return full status
    var json_buf: [32768]u8 = undefined;
    var w = std.Io.Writer.fixed(&json_buf);
    w.writeAll("{\"connected\":") catch return;
    w.writeAll(if (state.app.jf.connected) "true" else "false") catch return;
    w.writeAll(",\"loading\":") catch return;
    w.writeAll(if (state.app.jf.is_loading) "true" else "false") catch return;

    // Login error
    if (state.app.jf.login_error_len > 0) {
        w.print(",\"error\":\"{s}\"", .{escJsonSlice(state.app.jf.login_error[0..state.app.jf.login_error_len])}) catch return;
    }

    // Libraries
    w.writeAll(",\"libraries\":[") catch return;
    for (0..state.app.jf.library_count) |li| {
        const lib = state.app.jf.libraries[li];
        if (li > 0) w.writeAll(",") catch return;
        w.print("{{\"id\":\"{s}\",\"name\":\"{s}\",\"type\":\"{s}\"}}", .{
            escJsonSlice(lib.id[0..lib.id_len]),
            escJsonSlice(lib.name[0..lib.name_len]),
            escJsonSlice(lib.collection_type[0..lib.collection_type_len]),
        }) catch return;
    }

    // Items
    w.writeAll("],\"items\":[") catch return;
    for (0..state.app.jf.item_count) |ii| {
        const item = state.app.jf.items[ii];
        if (ii > 0) w.writeAll(",") catch return;
        const runtime_sec = @divTrunc(item.runtime_ticks, 10_000_000);
        w.print("{{\"id\":\"{s}\",\"name\":\"{s}\",\"type\":\"{s}\",\"year\":{d},\"folder\":{s},\"runtime\":{d}}}", .{
            escJsonSlice(item.id[0..item.id_len]),
            escJsonSlice(item.name[0..item.name_len]),
            escJsonSlice(item.media_type[0..item.media_type_len]),
            item.year,
            if (item.is_folder) "true" else "false",
            runtime_sec,
        }) catch return;
    }
    w.writeAll("]}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

// ══════════════════════════════════════════════════════════
// Unified Search — "Google for Media"
// Triggers search across all sources and returns merged results.
// Call with ?q=<query> to trigger. Call without to just read current results.
// ══════════════════════════════════════════════════════════

fn apiUnifiedSearch(stream: std.Io.net.Stream, query: []const u8) void {
    if (getQueryParam(query, "q")) |q| {
        var decoded: [256]u8 = undefined;
        const dq = urlDecode(q, &decoded) orelse q;
        const slen = @min(dq.len, 255);

        // 1. Trigger torrent search
        const search_svc = @import("search.zig");
        search_svc.triggerSearch(dq);

        // 2. Trigger TMDB search (if API key set)
        if (state.app.tmdb.api_key_len > 0) {
            @memcpy(state.app.tmdb.search_buf[0..slen], dq[0..slen]);
            state.app.tmdb.search_buf[slen] = 0;
            state.app.tmdb.view = .Search;
            state.app.tmdb.page = 1;
            const tmdb_api = @import("tmdb_api.zig");
            tmdb_api.fetchCurrentView(false);
        }

        // 3. Trigger YouTube search
        @memcpy(state.app.yt.search_buf[0..slen], dq[0..slen]);
        state.app.yt.search_buf[slen] = 0;
        const yt = @import("youtube.zig");
        const yt_qlen = std.mem.indexOfScalar(u8, &state.app.yt.search_buf, 0) orelse state.app.yt.search_buf.len;
        yt.fetchYoutube(state.app.yt.search_buf[0..yt_qlen]);

        // 4. Trigger Anime search
        @memcpy(state.app.anime.search_buf[0..slen], dq[0..slen]);
        state.app.anime.search_buf[slen] = 0;
        const anime = @import("anime.zig");
        const anime_qlen = std.mem.indexOfScalar(u8, &state.app.anime.search_buf, 0) orelse state.app.anime.search_buf.len;
        anime.searchAnime(state.app.anime.search_buf[0..anime_qlen]);

        // 5. Trigger Jellyfin search (if connected)
        if (state.app.jf.connected) {
            @memcpy(state.app.jf.search_buf[0..slen], dq[0..slen]);
            state.app.jf.search_buf[slen] = 0;
            const jf = @import("jellyfin.zig");
            jf.searchItems();
        }
    }

    // ── Collect results from all sources ──
    var json_buf: [65536]u8 = undefined;
    var w = std.Io.Writer.fixed(&json_buf);

    // Track loading state across all sources
    const search_svc = @import("search.zig");
    const any_loading = search_svc.is_searching or
        state.app.tmdb.is_loading or
        state.app.yt.is_loading or
        state.app.anime.is_loading or
        state.app.jf.is_loading;

    w.writeAll("{\"loading\":") catch return;
    w.writeAll(if (any_loading) "true" else "false") catch return;
    w.writeAll(",\"results\":[") catch return;

    var total: usize = 0;

    // ── Torrent results ──
    {
        search_svc.search_results_mutex.lock();
        defer search_svc.search_results_mutex.unlock();
        for (search_svc.search_results.items) |r| {
            if (total > 0) w.writeAll(",") catch return;
            w.print("{{\"source\":\"torrent\",\"title\":\"{s}\",\"detail\":\"{s} · {s} seeds\",\"action\":\"magnet\",\"data\":\"{s}\"}}", .{
                escJsonSlice(r.name),
                escJsonSlice(r.size),
                escJsonSlice(r.seeds),
                escJsonSlice(r.link),
            }) catch return;
            total += 1;
            if (total >= 80) break;
        }
    }

    // ── TMDB results ──
    if (state.app.tmdb.api_key_len > 0) {
        for (state.app.tmdb.results.items, 0..) |item, idx| {
            if (idx >= 10) break;
            if (total > 0) w.writeAll(",") catch return;
            const rating_pct = @as(u8, @intFromFloat(std.math.clamp(item.rating * 10.0, 0.0, 100.0)));
            w.print("{{\"source\":\"tmdb\",\"title\":\"{s}\",\"detail\":\"{s} · {d}%\",\"action\":\"tmdb_detail\",\"data\":\"{d}\"}}", .{
                escJsonSlice(item.title[0..item.title_len]),
                escJsonSlice(item.year[0..item.year_len]),
                rating_pct,
                item.id,
            }) catch return;
            total += 1;
        }
    }

    // ── YouTube results ──
    for (state.app.yt.results.items) |yt_item| {
        if (total >= 80) break;
        if (yt_item.title_len == 0) continue;
        if (total > 0) w.writeAll(",") catch return;
        w.print("{{\"source\":\"youtube\",\"title\":\"{s}\",\"detail\":\"{s}\",\"action\":\"yt_play\",\"data\":\"{s}\"}}", .{
            escJsonSlice(yt_item.title[0..yt_item.title_len]),
            escJsonSlice(yt_item.uploader[0..yt_item.uploader_len]),
            escJsonSlice(yt_item.video_id[0..yt_item.video_id_len]),
        }) catch return;
        total += 1;
    }

    // ── Anime results ──
    for (0..state.app.anime.result_count) |ai| {
        if (total >= 80) break;
        const a_item = state.app.anime.results[ai];
        if (a_item.name_len == 0) continue;
        if (total > 0) w.writeAll(",") catch return;
        w.print("{{\"source\":\"anime\",\"title\":\"{s}\",\"detail\":\"Anime\",\"action\":\"anime_detail\",\"data\":\"{s}\"}}", .{
            escJsonSlice(a_item.name[0..a_item.name_len]),
            escJsonSlice(a_item.id[0..a_item.id_len]),
        }) catch return;
        total += 1;
    }

    // ── Jellyfin results ──
    if (state.app.jf.connected) {
        for (0..state.app.jf.item_count) |ji| {
            if (total >= 80) break;
            const jf_item = state.app.jf.items[ji];
            if (jf_item.name_len == 0) continue;
            if (total > 0) w.writeAll(",") catch return;
            const act: []const u8 = if (jf_item.is_folder) "jf_browse" else "jf_play";
            w.print("{{\"source\":\"jellyfin\",\"title\":\"{s}\",\"detail\":\"{s}\",\"action\":\"{s}\",\"data\":\"{s}\"}}", .{
                escJsonSlice(jf_item.name[0..jf_item.name_len]),
                escJsonSlice(jf_item.media_type[0..jf_item.media_type_len]),
                act,
                escJsonSlice(jf_item.id[0..jf_item.id_len]),
            }) catch return;
            total += 1;
        }
    }

    w.writeAll("]}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}
