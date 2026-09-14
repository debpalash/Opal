//! Named collection HTTP boundary.
const std = @import("std");
const wire = @import("remote_http.zig");
const service = @import("collections.zig");

pub fn handle(stream: std.Io.net.Stream, method: []const u8, path: []const u8, query: []const u8) bool {
    if (std.mem.eql(u8, path, "/collections")) {
        if (wire.requireMethod(stream, method, "GET")) list(stream);
        return true;
    }
    if (std.mem.eql(u8, path, "/collections/action")) {
        if (wire.requireMethod(stream, method, "POST")) action(stream, query);
        return true;
    }
    return false;
}

fn list(stream: std.Io.net.Stream) void {
    var rows: [service.MAX_COLLECTIONS]service.Summary = undefined;
    const count = service.list(&rows);
    var json: [16 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&json);
    w.writeAll("{\"items\":[") catch return;
    for (rows[0..count], 0..) |*row, index| {
        if (index > 0) w.writeAll(",") catch return;
        w.print("{{\"id\":{d},\"name\":\"", .{row.id}) catch return;
        wire.writeJsonString(&w, row.name[0..row.name_len]);
        w.print("\",\"count\":{d},\"updated_at\":{d}}}", .{ row.item_count, row.updated_at }) catch return;
    }
    w.writeAll("]}") catch return;
    wire.sendJson(stream, json[0..w.end]);
}

fn action(stream: std.Io.net.Stream, query: []const u8) void {
    const name = wire.queryParam(query, "action") orelse "";
    var ok = false;
    if (std.mem.eql(u8, name, "save")) {
        var name_buf: [192]u8 = undefined;
        const value = if (wire.queryParam(query, "name")) |raw| (wire.urlDecode(raw, &name_buf) orelse "") else "";
        ok = service.saveQueue(value);
    } else {
        const id = std.fmt.parseInt(i64, wire.queryParam(query, "id") orelse "", 10) catch 0;
        if (std.mem.eql(u8, name, "append")) ok = service.enqueue(id, false) else if (std.mem.eql(u8, name, "replace")) ok = service.enqueue(id, true) else if (std.mem.eql(u8, name, "remove")) {
            if (!std.mem.eql(u8, wire.queryParam(query, "confirm") orelse "", "1")) {
                wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"remove requires confirm=1\"}");
                return;
            }
            ok = service.remove(id);
        } else {
            wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"unknown collection action\"}");
            return;
        }
    }
    if (!ok) {
        wire.sendJsonStatus(stream, "409 Conflict", "{\"error\":\"collection action could not be applied\"}");
        return;
    }
    wire.sendJson(stream, "{\"ok\":true}");
}
