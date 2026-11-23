//! /api/cast/control and /api/cast/status: remote control of the active
//! Chromecast / DLNA cast for the web couch-mode picker and agents. Dispatched
//! from remote.zig's apiPartyCast (no player lock needed). Runs on the
//! connection thread; cast_net bounds every receiver exchange.
//!
//!   GET|POST /cast/control?action=play|pause|toggle|stop|seek|forward|back[&pos=<secs>]
//!   GET      /cast/status   {casting,state,position,duration,device,title,last_error}

const std = @import("std");
const wire = @import("remote_http.zig");
const txt = @import("../core/text.zig");
const alloc = @import("../core/alloc.zig").allocator;
const cast = @import("cast.zig");
const pure = @import("cast_pure.zig");

pub fn handle(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) bool {
    if (std.mem.eql(u8, api_path, "/cast/control")) {
        controlRoute(stream, query);
        return true;
    }
    if (std.mem.eql(u8, api_path, "/cast/status")) {
        statusRoute(stream);
        return true;
    }
    return false;
}

fn sendResult(stream: std.Io.net.Stream, refusal: ?[]const u8) void {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print("{{\"ok\":{s},\"action\":\"cast_control\"", .{if (refusal == null) "true" else "false"}) catch return;
    if (refusal) |why| {
        w.writeAll(",\"error\":\"") catch return;
        wire.writeJsonString(&w, why);
        w.writeAll("\"") catch return;
    }
    w.writeAll("}") catch return;
    wire.sendJson(stream, w.buffered());
}

fn controlRoute(stream: std.Io.net.Stream, query: []const u8) void {
    var dec: [16]u8 = undefined;
    const raw = wire.queryParam(query, "action") orelse "";
    const action = wire.urlDecode(raw, &dec) orelse "";
    const ctl = pure.Control.parse(action) orelse
        return sendResult(stream, "action must be play, pause, toggle, stop, seek, forward or back");
    const pos: ?f64 = if (wire.queryParam(query, "pos")) |p| (std.fmt.parseFloat(f64, p) catch null) else null;
    sendResult(stream, cast.control(ctl, pos));
}

fn statusRoute(stream: std.Io.net.Stream) void {
    const st = alloc.create(cast.Status) catch return;
    defer alloc.destroy(st);
    st.* = .{};
    cast.status(st);
    var json_buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&json_buf);
    w.print("{{\"casting\":{s},\"state\":\"{s}\",\"position\":{d:.1},\"duration\":{d:.1},\"device\":", .{
        if (st.casting) "true" else "false",
        @tagName(st.state),
        st.position,
        st.duration,
    }) catch return;
    if (st.has_device) {
        w.writeAll("{\"name\":\"") catch return;
        wire.writeJsonString(&w, txt.safeUtf8(st.device.nameSlice()));
        w.print("\",\"protocol\":\"{s}\"}}", .{@tagName(st.device.protocol)}) catch return;
    } else w.writeAll("null") catch return;
    w.writeAll(",\"title\":\"") catch return;
    wire.writeJsonString(&w, txt.safeUtf8(st.titleText()));
    // Not "error": the web client rejects any response carrying a non-empty one.
    w.writeAll("\",\"last_error\":\"") catch return;
    wire.writeJsonString(&w, txt.safeUtf8(st.errText()));
    w.writeAll("\"}") catch return;
    wire.sendJson(stream, w.buffered());
}
