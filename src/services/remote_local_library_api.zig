//! Safe management boundary for the persistent local-media index.
const std = @import("std");
const wire = @import("remote_http.zig");
const library = @import("local_library.zig");

pub fn handle(stream: std.Io.net.Stream, method: []const u8, path: []const u8, query: []const u8, body: []const u8) bool {
    if (std.mem.eql(u8, path, "/local-library")) {
        if (wire.requireMethod(stream, method, "GET")) list(stream, query);
        return true;
    }
    if (std.mem.eql(u8, path, "/local-library/action")) {
        if (wire.requireMethod(stream, method, "POST")) action(stream, query, body);
        return true;
    }
    return false;
}

fn list(stream: std.Io.net.Stream, query: []const u8) void {
    var query_buf: [512]u8 = undefined;
    const text = if (wire.queryParam(query, "q")) |raw| (wire.urlDecode(raw, &query_buf) orelse "") else "";
    const duplicates = std.mem.eql(u8, wire.queryParam(query, "duplicates") orelse "", "1");
    var rows: [library.MAX_RESULTS]library.Item = undefined;
    const count = library.search(text, duplicates, &rows);
    const alloc = @import("../core/alloc.zig").allocator;
    const json = alloc.alloc(u8, 48 * 1024) catch return;
    defer alloc.free(json);
    var w = std.Io.Writer.fixed(json);
    w.print("{{\"scanning\":{s},\"items\":[", .{if (library.scanning.load(.acquire)) "true" else "false"}) catch return;
    for (rows[0..count], 0..) |*row, index| {
        if (index > 0) w.writeAll(",") catch return;
        w.print("{{\"id\":{d},\"title\":\"", .{row.id}) catch return;
        wire.writeJsonString(&w, row.title[0..row.title_len]);
        w.writeAll("\",\"kind\":\"") catch return;
        wire.writeJsonString(&w, row.kind[0..row.kind_len]);
        w.print("\",\"size\":{d},\"copies\":{d}}}", .{ row.size, row.duplicate_count }) catch return;
    }
    w.writeAll("],\"roots\":[") catch return;
    var roots: [library.MAX_ROOTS]library.Root = undefined;
    const root_count = library.listRoots(&roots);
    for (roots[0..root_count], 0..) |*root, index| {
        if (index > 0) w.writeAll(",") catch return;
        const path = root.path[0..root.path_len];
        var start: usize = 0;
        for (path, 0..) |ch, i| if (ch == '/' or ch == '\\') {
            start = i + 1;
        };
        w.print("{{\"id\":{d},\"name\":\"", .{root.id}) catch return;
        wire.writeJsonString(&w, if (start < path.len) path[start..] else "Library folder");
        w.writeAll("\"}") catch return;
    }
    w.writeAll("]}") catch return;
    wire.sendJson(stream, json[0..w.end]);
}

fn action(stream: std.Io.net.Stream, query: []const u8, body: []const u8) void {
    const name = wire.queryParam(body, "action") orelse wire.queryParam(query, "action") orelse "";
    if (std.mem.eql(u8, name, "scan")) {
        library.scanAsync();
        wire.sendJson(stream, "{\"ok\":true}");
        return;
    }
    if (std.mem.eql(u8, name, "add-root")) {
        var path_buf: [2048]u8 = undefined;
        const raw = wire.queryParam(body, "path") orelse {
            wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"folder path required\"}");
            return;
        };
        const path = wire.urlDecode(raw, &path_buf) orelse "";
        if (!library.addRoot(path)) {
            wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"folder is unavailable\"}");
            return;
        }
        library.scanAsync();
        wire.sendJson(stream, "{\"ok\":true}");
        return;
    }
    if (std.mem.eql(u8, name, "remove-root")) {
        const id = std.fmt.parseInt(i64, wire.queryParam(body, "id") orelse wire.queryParam(query, "id") orelse "", 10) catch 0;
        if (!library.removeRoot(id)) {
            wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"library folder not found\"}");
            return;
        }
        wire.sendJson(stream, "{\"ok\":true}");
        return;
    }
    if (!std.mem.eql(u8, name, "correct")) {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"unknown local-library action\"}");
        return;
    }
    const id = std.fmt.parseInt(i64, wire.queryParam(body, "id") orelse wire.queryParam(query, "id") orelse "", 10) catch 0;
    var title_buf: [512]u8 = undefined;
    var kind_buf: [32]u8 = undefined;
    const title = if (wire.queryParam(body, "title") orelse wire.queryParam(query, "title")) |raw| (wire.urlDecode(raw, &title_buf) orelse "") else "";
    const kind = if (wire.queryParam(body, "kind") orelse wire.queryParam(query, "kind")) |raw| (wire.urlDecode(raw, &kind_buf) orelse "") else "";
    if (!library.correct(id, title, kind)) {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"invalid metadata correction\"}");
        return;
    }
    wire.sendJson(stream, "{\"ok\":true}");
}
