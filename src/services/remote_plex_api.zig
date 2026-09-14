//! Plex web companion projection and typed actions.
const std = @import("std");
const plex = @import("plex.zig");
const wire = @import("remote_http.zig");
const txt = @import("../core/text.zig");

pub fn handle(stream: std.Io.net.Stream, method: []const u8, path: []const u8, query: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "/plex")) return false;
    if (std.mem.eql(u8, path, "/plex")) {
        if (wire.requireMethod(stream, method, "GET")) status(stream);
        return true;
    }
    if (!wire.requireMethod(stream, method, "POST")) return true;
    if (std.mem.eql(u8, path, "/plex/connect")) plex.connect() else if (std.mem.eql(u8, path, "/plex/disconnect")) plex.disconnect() else if (std.mem.eql(u8, path, "/plex/sections")) plex.fetchSections() else if (std.mem.eql(u8, path, "/plex/more")) plex.loadMore() else if (std.mem.eql(u8, path, "/plex/back")) {
        if (!plex.browseBack()) return conflict(stream, "already at sections");
    } else if (std.mem.eql(u8, path, "/plex/open")) {
        const idx = std.fmt.parseInt(usize, wire.queryParam(query, "idx") orelse "", 10) catch return badRequest(stream, "invalid section");
        if (idx >= plex.section_count) return conflict(stream, "section unavailable");
        plex.fetchItems(idx);
    } else if (std.mem.eql(u8, path, "/plex/open_item")) {
        var id_buf: [64]u8 = undefined;
        const id = decodeId(query, &id_buf) orelse return badRequest(stream, "missing item id");
        if (!plex.openChild(id)) return conflict(stream, "item unavailable");
    } else if (std.mem.eql(u8, path, "/plex/play")) {
        var id_buf: [64]u8 = undefined;
        const id = decodeId(query, &id_buf) orelse return badRequest(stream, "missing item id");
        if (!plex.playByRatingKey(id)) return conflict(stream, "item unavailable");
    } else return badRequest(stream, "unknown Plex action");
    wire.sendJson(stream, "{\"ok\":true}");
    return true;
}

fn decodeId(query: []const u8, out: *[64]u8) ?[]const u8 {
    const raw = wire.queryParam(query, "id") orelse return null;
    return wire.urlDecode(raw, out) orelse raw;
}

fn badRequest(stream: std.Io.net.Stream, message: []const u8) bool {
    var body: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&body, "{{\"ok\":false,\"error\":\"{s}\"}}", .{message}) catch "{\"ok\":false}";
    wire.sendJsonStatus(stream, "400 Bad Request", json);
    return true;
}

fn conflict(stream: std.Io.net.Stream, message: []const u8) bool {
    var body: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&body, "{{\"ok\":false,\"error\":\"{s}\"}}", .{message}) catch "{\"ok\":false}";
    wire.sendJsonStatus(stream, "409 Conflict", json);
    return true;
}

fn status(stream: std.Io.net.Stream) void {
    const allocator = @import("../core/alloc.zig").allocator;
    const json = allocator.alloc(u8, 192 * 1024) catch return;
    defer allocator.free(json);
    var w = std.Io.Writer.fixed(json);
    w.print("{{\"connected\":{s},\"loading\":{s},\"state\":\"{s}\",\"active_section\":{d},\"depth\":{d},\"server\":\"", .{
        if (plex.isConnected()) "true" else "false", if (plex.is_loading.load(.acquire)) "true" else "false",
        @tagName(plex.conn_state.load(.acquire)),    plex.active_section,
        plex.nav_depth,
    }) catch return;
    wire.writeJsonString(&w, txt.safeUtf8(plex.server_name[0..@min(plex.server_name_len, plex.server_name.len)]));
    w.writeAll("\",\"pin\":\"") catch return;
    wire.writeJsonString(&w, txt.safeUtf8(plex.pin_code[0..@min(plex.pin_code_len, plex.pin_code.len)]));
    w.writeAll("\",\"status\":\"") catch return;
    wire.writeJsonString(&w, txt.safeUtf8(plex.status_msg[0..@min(plex.status_msg_len, plex.status_msg.len)]));
    w.writeAll("\",\"sections\":[") catch return;
    for (plex.sections[0..@min(plex.section_count, plex.sections.len)], 0..) |*section, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"title\":\"") catch return;
        wire.writeJsonString(&w, txt.safeUtf8(section.title[0..@min(section.title_len, section.title.len)]));
        w.writeAll("\"}") catch return;
    }
    w.writeAll("],\"items\":[") catch return;
    for (plex.items[0..@min(plex.item_count, plex.items.len)], 0..) |*item, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"title\":\"") catch return;
        wire.writeJsonString(&w, txt.safeUtf8(item.title[0..@min(item.title_len, item.title.len)]));
        w.writeAll("\",\"id\":\"") catch return;
        wire.writeJsonString(&w, item.rating_key[0..@min(item.rating_key_len, item.rating_key.len)]);
        w.writeAll("\",\"year\":\"") catch return;
        wire.writeJsonString(&w, txt.safeUtf8(item.year[0..@min(item.year_len, item.year.len)]));
        w.writeAll("\",\"type\":\"") catch return;
        wire.writeJsonString(&w, item.media_type[0..@min(item.media_type_len, item.media_type.len)]);
        w.print("\",\"folder\":{s},\"progress\":{d},\"duration\":{d},\"played\":{s}}}", .{
            if (item.is_folder) "true" else "false",      @divTrunc(item.view_offset_ms, 1000), @divTrunc(item.duration_ms, 1000),
            if (item.view_count > 0) "true" else "false",
        }) catch return;
    }
    w.writeAll("]}") catch return;
    wire.sendJson(stream, json[0..w.end]);
}
