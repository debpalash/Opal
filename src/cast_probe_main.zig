//! `opal-cast-probe` — drives the app's native casting client (cast_net.zig,
//! the same code the app runs) against LOOPBACK fake receivers, for the
//! integration tests in tests/features/test_cast_native.py. It refuses any
//! non-loopback target, so a test can never discover, cast to or command a
//! real TV, speaker or Chromecast on the LAN.
//!
//!   opal-cast-probe mdns <127.x.x.x> <port> [wait_ms]
//!   opal-cast-probe ssdp <127.x.x.x> <port> [wait_ms]
//!   opal-cast-probe cc   <127.x.x.x> <port> load <url> [start] [content-type] [title]
//!   opal-cast-probe cc   <127.x.x.x> <port> play|pause|stop|status|seek <secs>
//!   opal-cast-probe dlna <http://127.x.x.x:port/control> load <url> [start] [mime] [title]
//!   opal-cast-probe dlna <http://127.x.x.x:port/control> play|pause|stop|status|seek <secs>
//!
//! Prints one JSON object per result on stdout.
const std = @import("std");
const net = @import("services/cast_net.zig");
const cv2 = @import("services/cast_v2_pure.zig");
const dlna = @import("services/dlna_pure.zig");
const pure = @import("services/cast_pure.zig");

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("opal-cast-probe: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn requireLoopback(host: []const u8) void {
    if (!pure.isLoopbackHost(host)) fail("refusing non-loopback target {s}", .{host});
}

fn writeResult(w: *std.Io.Writer, r: net.Result) !void {
    try w.print("{{\"ok\":{},\"state\":\"{s}\",\"position\":{d:.3},\"duration\":{d:.3},\"error\":", .{ r.ok, @tagName(r.state), r.position, r.duration });
    try cv2.writeJsonString(w, r.err);
    try w.writeAll("}\n");
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    var out_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    const mode = args.next() orelse fail("usage: see src/cast_probe_main.zig", .{});
    if (std.mem.eql(u8, mode, "mdns") or std.mem.eql(u8, mode, "ssdp")) {
        const host = args.next() orelse fail("host required", .{});
        requireLoopback(host);
        const port = std.fmt.parseInt(u16, args.next() orelse fail("port required", .{}), 10) catch fail("bad port", .{});
        const wait = std.fmt.parseInt(i64, args.next() orelse "1500", 10) catch 1500;
        const dest = std.Io.net.IpAddress.parseIp4(host, port) catch fail("bad address", .{});
        if (std.mem.eql(u8, mode, "mdns")) {
            var found: [pure.max_devices]cv2.Found = undefined;
            const n = net.discoverChromecasts(dest, wait, &found);
            for (found[0..n]) |*f| {
                const d = pure.fromChromecast(f);
                try w.writeAll("{\"name\":");
                try cv2.writeJsonString(w, d.nameSlice());
                try w.writeAll(",\"ip\":");
                try cv2.writeJsonString(w, d.ipSlice());
                try w.print(",\"port\":{d},\"id\":", .{d.port});
                try cv2.writeJsonString(w, d.identSlice());
                try w.writeAll("}\n");
            }
        } else {
            var found: [8]dlna.Renderer = undefined;
            const n = net.discoverRenderers(dest, wait, &found);
            for (found[0..n]) |*r| {
                const d = pure.fromRenderer(r);
                try w.writeAll("{\"name\":");
                try cv2.writeJsonString(w, d.nameSlice());
                try w.writeAll(",\"ip\":");
                try cv2.writeJsonString(w, d.ipSlice());
                try w.writeAll(",\"control\":");
                try cv2.writeJsonString(w, d.controlSlice());
                try w.writeAll(",\"id\":");
                try cv2.writeJsonString(w, d.identSlice());
                try w.writeAll("}\n");
            }
        }
        return;
    }

    if (std.mem.eql(u8, mode, "cc")) {
        const host = args.next() orelse fail("host required", .{});
        requireLoopback(host);
        const port = std.fmt.parseInt(u16, args.next() orelse fail("port required", .{}), 10) catch fail("bad port", .{});
        const verb = args.next() orelse fail("verb required", .{});
        const goal: cv2.Goal = if (std.mem.eql(u8, verb, "load")) blk: {
            const url = args.next() orelse fail("url required", .{});
            const start = std.fmt.parseFloat(f64, args.next() orelse "0") catch 0;
            const ctype = args.next() orelse pure.contentTypeFor(url);
            break :blk .{ .load = .{ .url = url, .start_secs = start, .content_type = ctype, .title = args.next() orelse "", .hls_fmp4 = std.mem.eql(u8, ctype, "application/x-mpegURL") } };
        } else if (std.mem.eql(u8, verb, "seek"))
            .{ .seek = std.fmt.parseFloat(f64, args.next() orelse fail("secs required", .{})) catch fail("bad secs", .{}) }
        else if (std.mem.eql(u8, verb, "play")) .play else if (std.mem.eql(u8, verb, "pause")) .pause else if (std.mem.eql(u8, verb, "stop")) .stop else if (std.mem.eql(u8, verb, "status")) .status else fail("unknown verb {s}", .{verb});
        try writeResult(w, net.chromecast(host, port, goal, 8000));
        return;
    }

    if (std.mem.eql(u8, mode, "dlna")) {
        const control = args.next() orelse fail("control URL required", .{});
        const u = dlna.parseHttpUrl(control) orelse fail("bad control URL", .{});
        requireLoopback(u.host);
        const verb = args.next() orelse fail("verb required", .{});
        const goal: net.DlnaGoal = if (std.mem.eql(u8, verb, "load")) blk: {
            const url = args.next() orelse fail("url required", .{});
            const start = std.fmt.parseFloat(f64, args.next() orelse "0") catch 0;
            const mime = args.next() orelse pure.contentTypeFor(url);
            break :blk .{ .load = .{ .url = url, .start_secs = start, .mime = mime, .title = args.next() orelse "" } };
        } else if (std.mem.eql(u8, verb, "seek"))
            .{ .seek = std.fmt.parseFloat(f64, args.next() orelse fail("secs required", .{})) catch fail("bad secs", .{}) }
        else if (std.mem.eql(u8, verb, "play")) .play else if (std.mem.eql(u8, verb, "pause")) .pause else if (std.mem.eql(u8, verb, "stop")) .stop else if (std.mem.eql(u8, verb, "status")) .status else fail("unknown verb {s}", .{verb});
        try writeResult(w, net.dlnaRun(control, goal));
        return;
    }
    fail("unknown mode {s}", .{mode});
}
