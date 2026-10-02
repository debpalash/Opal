//! Podcast snapshots and logs: copy feature state before socket writes.
const std = @import("std");
const txt = @import("../core/text.zig");
const logs = @import("../core/logs.zig");
const wire = @import("remote_http.zig");
const getQueryParam = wire.queryParam;
const urlDecode = wire.urlDecode;
const sendJson = wire.sendJson;
const sendJsonStatus = wire.sendJsonStatus;
const escJsonWrite = wire.writeJsonString;

pub fn apiPodcasts(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    const podcasts_svc = @import("podcasts.zig");
    if (std.mem.eql(u8, api_path, "/podcasts/search")) {
        if (getQueryParam(query, "q")) |q| {
            var decoded: [256]u8 = undefined;
            const dq = urlDecode(q, &decoded) orelse q;
            podcasts_svc.searchPodcasts(dq);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"podcast_search\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/podcasts/episodes")) {
        if (getQueryParam(query, "idx")) |idx_str| {
            const idx = std.fmt.parseInt(usize, idx_str, 10) catch 0;
            podcasts_svc.loadEpisodes(idx);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"load_episodes\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/podcasts/play")) {
        const idx = std.fmt.parseInt(usize, getQueryParam(query, "idx") orelse "", 10) catch {
            sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"episode index required\"}");
            return;
        };
        const generation = std.fmt.parseInt(u64, getQueryParam(query, "generation") orelse "", 10) catch {
            sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"generation required\"}");
            return;
        };
        if (!podcasts_svc.playEpisodeAtGeneration(idx, generation)) {
            sendJsonStatus(stream, "409 Conflict", "{\"error\":\"episode selection changed; refresh and retry\"}");
            return;
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"play_episode\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/podcasts/page")) {
        const generation = std.fmt.parseInt(u64, getQueryParam(query, "generation") orelse "", 10) catch {
            sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"generation required\"}");
            return;
        };
        podcasts_svc.changeEpisodePage(generation, std.mem.eql(u8, getQueryParam(query, "direction") orelse "next", "next"));
    }
    // GET /podcasts → results + episodes for the current show.
    podcasts_svc.loadPopularOnce();
    const allocator = @import("../core/alloc.zig").allocator;
    const view = allocator.create(podcasts_svc.Snapshot) catch {
        sendJsonStatus(stream, "503 Service Unavailable", "{\"error\":\"podcast snapshot unavailable\"}");
        return;
    };
    defer allocator.destroy(view);
    podcasts_svc.copySnapshot(view);
    const json_buf = allocator.alloc(u8, @sizeOf(podcasts_svc.Snapshot) * 6 + 8192) catch {
        sendJsonStatus(stream, "503 Service Unavailable", "{\"error\":\"podcast view unavailable\"}");
        return;
    };
    defer allocator.free(json_buf);
    var w = std.Io.Writer.fixed(json_buf);
    w.print("{{\"generation\":{d},\"fetch_error\":{s},\"episodes_failed\":{s},\"results\":[", .{ view.generation, if (view.fetch_error) "true" else "false", if (view.episodes_failed) "true" else "false" }) catch return;
    for (0..view.result_count) |ri| {
        const r = view.results[ri];
        if (r.name_len == 0) continue;
        if (ri > 0) w.writeAll(",") catch return;
        w.writeAll("{\"name\":\"") catch return;
        escJsonWrite(&w, r.name[0..r.name_len]);
        w.writeAll("\",\"artist\":\"") catch return;
        escJsonWrite(&w, r.artist[0..@min(r.artist_len, r.artist.len)]);
        // `art` tells the web client whether to request the cover proxy
        // (/api/podcasts/poster?idx=…) or fall back to a placeholder tile.
        w.writeAll("\",\"art\":") catch return;
        w.writeAll(if (r.artwork_len > 0) "true" else "false") catch return;
        w.writeAll("}") catch return;
    }
    w.writeAll("],\"episodes\":[") catch return;
    for (0..view.episode_count) |ei| {
        const e = view.episodes[ei];
        if (e.title_len == 0) continue;
        if (ei > 0) w.writeAll(",") catch return;
        w.writeAll("{\"title\":\"") catch return;
        escJsonWrite(&w, e.title[0..e.title_len]);
        w.writeAll("\",\"date\":\"") catch return;
        escJsonWrite(&w, e.date[0..e.date_len]);
        w.writeAll("\",\"duration\":\"") catch return;
        escJsonWrite(&w, e.duration[0..e.duration_len]);
        w.writeAll("\",\"url\":\"") catch return;
        escJsonWrite(&w, e.audio_url[0..@min(e.audio_url_len, e.audio_url.len)]);
        w.writeAll("\"}") catch return;
    }
    w.writeAll("],\"selected\":") catch return;
    if (view.selected_idx) |si| {
        w.print("{d}", .{si}) catch return;
    } else {
        w.writeAll("null") catch return;
    }
    w.print(",\"episode_offset\":{d},\"episode_total\":{d}", .{ view.episode_offset, view.episode_total }) catch return;
    w.writeAll(",\"loading\":") catch return;
    w.writeAll(if (view.loading) "true" else "false") catch return;
    w.writeAll(",\"episodes_loading\":") catch return;
    w.writeAll(if (view.episodes_loading) "true" else "false") catch return;
    w.writeAll("}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

pub fn apiLogs(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    const a = @import("../core/alloc.zig").allocator;

    if (std.mem.eql(u8, api_path, "/logs/clear")) {
        logs.clear();
        sendJson(stream, "{\"ok\":true,\"action\":\"logs_clear\"}");
        return;
    }

    const errors_only = std.mem.eql(u8, getQueryParam(query, "errors") orelse "", "1");
    // Newest-N window: the ring holds 1024 entries and a browser wants the tail.
    const limit = std.fmt.parseInt(usize, getQueryParam(query, "limit") orelse "200", 10) catch 200;

    // 1024 entries can exceed 256KB of text — heap, never the thread stack.
    const json_buf = a.alloc(u8, 512 * 1024) catch return;
    defer a.free(json_buf);
    var w = std.Io.Writer.fixed(json_buf);
    w.writeAll("{\"entries\":[") catch return;

    logs.lockRead();
    const total = logs.logCount();
    // Walk oldest→newest but start late enough to emit at most `limit` rows.
    var idx: usize = if (total > limit) total - limit else 0;
    var emitted: usize = 0;
    while (idx < total) : (idx += 1) {
        const e = logs.getLog(idx);
        if (errors_only and !e.is_error) continue;
        if (emitted > 0) w.writeAll(",") catch break;
        emitted += 1;
        w.print("{{\"ts\":{d},\"error\":{s},\"level\":\"", .{
            e.timestamp,
            if (e.is_error) "true" else "false",
        }) catch break;
        escJsonWrite(&w, txt.safeUtf8(e.level));
        w.writeAll("\",\"prefix\":\"") catch break;
        escJsonWrite(&w, txt.safeUtf8(e.prefix));
        w.writeAll("\",\"text\":\"") catch break;
        // Log text is untrusted (mpv stderr, scraper output) — invalid UTF-8
        // here would produce a response the browser refuses to parse.
        escJsonWrite(&w, txt.safeUtf8(e.text));
        w.writeAll("\"}") catch break;
    }
    logs.unlockRead();

    w.writeAll("]}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}
