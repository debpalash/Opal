//! Novel catalog and reader snapshots for the web companion.
const std = @import("std");
const txt = @import("../core/text.zig");
const wire = @import("remote_http.zig");
const getQueryParam = wire.queryParam;
const urlDecode = wire.urlDecode;
const sendJson = wire.sendJson;
const sendJsonStatus = wire.sendJsonStatus;
const escJsonWrite = wire.writeJsonString;

pub fn apiNovels(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    const nov = @import("novels.zig");
    if (std.mem.eql(u8, api_path, "/novels/back")) {
        nov.back();
        sendJson(stream, "{\"ok\":true}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/novels/more")) {
        nov.loadMore();
        sendJson(stream, "{\"ok\":true}");
        return;
    }

    if (std.mem.eql(u8, api_path, "/novels/search")) {
        if (getQueryParam(query, "q")) |q| {
            var decoded: [256]u8 = undefined;
            nov.searchNovels(txt.safeUtf8(urlDecode(q, &decoded) orelse q));
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"novel_search\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/novels/open")) {
        const idx = std.fmt.parseInt(usize, getQueryParam(query, "idx") orelse "999", 10) catch 999;
        if (idx >= nov.resultCount()) {
            sendJsonStatus(stream, "404 Not Found", "{\"error\":\"no such novel\"}");
            return;
        }
        nov.openNovel(idx);
        sendJson(stream, "{\"ok\":true,\"action\":\"novel_open\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/novels/chapter")) {
        const idx = std.fmt.parseInt(usize, getQueryParam(query, "idx") orelse "999", 10) catch 999;
        if (idx >= nov.chapterCount()) {
            sendJsonStatus(stream, "404 Not Found", "{\"error\":\"no such chapter\"}");
            return;
        }
        nov.openChapter(idx);
        sendJson(stream, "{\"ok\":true,\"action\":\"novel_chapter\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/novels/next")) {
        nov.nextChapter();
        sendJson(stream, "{\"ok\":true,\"action\":\"novel_next\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/novels/prev")) {
        nov.prevChapter();
        sendJson(stream, "{\"ok\":true,\"action\":\"novel_prev\"}");
        return;
    }

    const a = @import("../core/alloc.zig").allocator;
    const n = a.create(nov.ReaderSnapshot) catch return;
    defer a.destroy(n);
    nov.copyReaderSnapshot(n);
    // Size from the immutable view, including worst-case JSON escapes. Large
    // enriched catalogs must not silently cut off chapter lists or reader text.
    var json_cap: usize = 8192 + (n.text_len + n.work_title_len + n.chapter_label_len) * 6;
    for (n.results[0..n.result_count]) |*row| {
        json_cap += (row.title().len + row.url().len + row.metadata.author().len +
            row.metadata.overview().len + row.metadata.cover().len) * 6 + 128;
    }
    for (n.chapter_title_lens[0..n.chapter_count]) |length| json_cap += length * 6 + 32;
    const json_buf = a.alloc(u8, json_cap) catch return;
    defer a.free(json_buf);
    var w = std.Io.Writer.fixed(json_buf);
    w.print("{{\"view\":\"{s}\",\"loading\":{s},\"chapters_loading\":{s},\"text_loading\":{s},\"error\":{s},\"title\":\"", .{
        @tagName(n.view),
        if (n.loading) "true" else "false",
        if (n.chapters_loading) "true" else "false",
        if (n.text_loading) "true" else "false",
        if (n.fetch_error) "true" else "false",
    }) catch return;
    escJsonWrite(&w, txt.safeUtf8(n.work_title[0..@min(n.work_title_len, n.work_title.len)]));
    w.writeAll("\",\"chapter_label\":\"") catch return;
    escJsonWrite(&w, txt.safeUtf8(n.chapter_label[0..@min(n.chapter_label_len, n.chapter_label.len)]));
    w.print("\",\"current_chapter\":{d},\"truncated\":{s},\"results\":[", .{
        n.current_chapter,
        if (n.text_truncated) "true" else "false",
    }) catch return;

    var i: usize = 0;
    const rn = n.result_count;
    while (i < rn) : (i += 1) {
        const row = &n.results[i];
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"title\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(row.title()));
        w.writeAll("\",\"url\":\"") catch return;
        escJsonWrite(&w, row.url());
        w.writeAll("\",\"author\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(row.metadata.author()));
        w.writeAll("\",\"overview\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(row.metadata.overview()));
        w.writeAll("\",\"cover\":\"") catch return;
        escJsonWrite(&w, row.metadata.cover());
        w.print("\",\"year\":{d},\"source\":{d}}}", .{ row.metadata.year, row.source }) catch return;
    }
    w.writeAll("],\"chapters\":[") catch return;
    i = 0;
    const cn = n.chapter_count;
    while (i < cn) : (i += 1) {
        const chapter_title = n.chapter_titles[i][0..n.chapter_title_lens[i]];
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"title\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(chapter_title));
        w.writeAll("\"}") catch return;
    }
    w.writeAll("],\"text\":\"") catch return;
    escJsonWrite(&w, txt.safeUtf8(n.text_buf[0..@min(n.text_len, n.text_buf.len)]));
    w.print("\",\"has_more\":{s},\"loading_more\":{s},\"search_generation\":{d},\"chapter_generation\":{d},\"text_generation\":{d}}}", .{
        if (n.has_more) "true" else "false",
        if (n.loading_more) "true" else "false",
        n.search_generation,
        n.chapter_generation,
        n.text_generation,
    }) catch return;
    sendJson(stream, json_buf[0..w.end]);
}
