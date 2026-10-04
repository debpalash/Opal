//! Comics catalog and reader HTTP adapters; shared wire helpers, owner-thread actions.
const std = @import("std");
const state = @import("../core/state.zig");
const txt = @import("../core/text.zig");
const wire = @import("remote_http.zig");
const getQueryParam = wire.queryParam;
const urlDecode = wire.urlDecode;
const sendJson = wire.sendJson;
const sendJsonStatus = wire.sendJsonStatus;
const escJsonWrite = wire.writeJsonString;

pub fn apiComics(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    if (std.mem.eql(u8, api_path, "/comics/more")) {
        @import("comics.zig").loadMoreResults();
        sendJson(stream, "{\"ok\":true}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/comics/load")) {
        if (getQueryParam(query, "url")) |url| {
            var decoded: [512]u8 = undefined;
            const comic_url = urlDecode(url, &decoded) orelse url;
            const comics_svc = @import("comics.zig");
            // Defer to the UI thread: loadComic frees textures via dvui (UI-only).
            comics_svc.requestLoad(comic_url);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"load_comic\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/comics/search")) {
        const q = getQueryParam(query, "q") orelse "";
        var decoded: [256]u8 = undefined;
        const term = txt.safeUtf8(urlDecode(q, &decoded) orelse q);
        const comics_svc = @import("comics.zig");
        if (getQueryParam(query, "source")) |source| {
            if (!comics_svc.searchComicsFrom(term, source)) {
                sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"comic source is unknown or not installed\"}");
                return;
            }
        } else comics_svc.searchComics(term);
        sendJson(stream, "{\"ok\":true,\"action\":\"comic_search\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/comics/results")) {
        const comics_svc = @import("comics.zig");
        const comics_pure = @import("comics_pure.zig");
        comics_svc.loadPopularOnce();
        const a = @import("../core/alloc.zig").allocator;
        const rows = a.alloc(comics_svc.OwnedSearchRow, comics_svc.MAX_SEARCH_RESULTS) catch {
            sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"comic snapshot unavailable\"}");
            return;
        };
        defer a.free(rows);
        const count = comics_svc.copySearchSnapshot(rows);
        var field_bytes: usize = 0;
        for (rows[0..count]) |row| field_bytes += row.title_len + row.url_len + row.cover_len;
        const json_buf = a.alloc(u8, comics_pure.catalogJsonCapacity(count, field_bytes)) catch {
            sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"comic response unavailable\"}");
            return;
        };
        defer a.free(json_buf);
        var w = std.Io.Writer.fixed(json_buf);
        w.print("{{\"loading_more\":{s},\"has_more\":{s},\"loading\":{s},\"source\":\"{s}\",\"xkcd_installed\":{s},\"smbc_installed\":{s},\"results\":", .{
            if (comics_svc.loadingMoreResults()) "true" else "false",
            if (comics_svc.hasMoreResults()) "true" else "false",
            if (comics_svc.searching()) "true" else "false",
            comics_svc.selectedSourceName(),
            if (@import("../core/source_config.zig").has("xkcd")) "true" else "false",
            if (@import("../core/source_config.zig").has("smbc")) "true" else "false",
        }) catch {
            sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"comic serialization failed\"}");
            return;
        };
        comics_pure.writeCatalogRows(&w, rows[0..count]) catch {
            sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"comic serialization failed\"}");
            return;
        };
        w.writeByte('}') catch {
            sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"comic serialization failed\"}");
            return;
        };
        sendJson(stream, json_buf[0..w.end]);
        return;
    }
    if (std.mem.eql(u8, api_path, "/comics/close")) {
        // closeComic frees dvui textures → UI thread only; requestClose defers.
        @import("comics.zig").requestClose();
        sendJson(stream, "{\"ok\":true,\"action\":\"close_comic\"}");
        return;
    }
    // Return current state. `downloaded` vs `pages` is what the reader polls to
    // know which /api/comics/page?i= indices will answer 200 rather than 404.
    const cm = &state.app.comic;
    const reader_loading = cm.is_loading.load(.acquire) or cm.pending_load.load(.acquire) or cm.pending_close.load(.acquire);
    const a = @import("../core/alloc.zig").allocator;
    const json_buf = a.alloc(u8, 96 * 1024) catch return;
    defer a.free(json_buf);
    var w = std.Io.Writer.fixed(json_buf);
    w.print("{{\"loading\":{s},\"pages\":{d},\"downloaded\":{d},\"current\":{d},\"has_next\":{s},\"has_prev\":{s},\"title\":\"", .{
        if (reader_loading) "true" else "false",
        cm.page_count,
        cm.dl_progress.load(.acquire),
        cm.current_page,
        if (cm.next_url_len > 0) "true" else "false",
        if (cm.prev_url_len > 0) "true" else "false",
    }) catch return;
    escJsonWrite(&w, txt.safeUtf8(cm.title[0..@min(cm.title_len, cm.title.len)]));
    w.writeAll("\",\"url\":\"") catch return;
    escJsonWrite(&w, cm.url_buf[0..cm.url_len]);
    w.writeAll("\",\"next_url\":\"") catch return;
    escJsonWrite(&w, cm.next_url[0..@min(cm.next_url_len, cm.next_url.len)]);
    w.writeAll("\",\"prev_url\":\"") catch return;
    escJsonWrite(&w, cm.prev_url[0..@min(cm.prev_url_len, cm.prev_url.len)]);
    w.writeAll("\",\"chapters\":[") catch return;
    const comics_svc = @import("comics.zig");
    if (@import("comics_pure.zig").mangaIdFromRoute(cm.url_buf[0..@min(cm.url_len, cm.url_buf.len)]) != null and !reader_loading) {
        var i: usize = 0;
        while (comics_svc.mangaDexChapterRow(i)) |row| : (i += 1) {
            if (i > 0) w.writeAll(",") catch return;
            w.writeAll("{\"title\":\"") catch return;
            escJsonWrite(&w, txt.safeUtf8(row.title()));
            w.writeAll("\",\"url\":\"") catch return;
            escJsonWrite(&w, row.route());
            w.print("\",\"selected\":{s}}}", .{if (row.selected) "true" else "false"}) catch return;
        }
    }
    w.writeAll("],\"ready_pages\":[") catch return;
    var ready_count: usize = 0;
    for (0..@min(cm.page_count, cm.page_pixels.len)) |idx| {
        if (!comics_svc.pageReady(idx)) continue;
        if (ready_count > 0) w.writeAll(",") catch return;
        w.print("{d}", .{idx}) catch return;
        ready_count += 1;
    }
    w.writeAll("]}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}
