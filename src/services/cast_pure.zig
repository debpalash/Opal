//! Pure cast helpers: parse `catt scan` / `atvscript scan` output, build the
//! argv for each tool, and vet the media URL. cast.zig routes through these so
//! the tested logic is the shipped logic.
//!
//! Tool syntax (verified against catt 0.13.0 and pyatv 0.18.0 sources):
//!   catt scan                      -> "Scanning Chromecasts..." then
//!                                     "<host> - <name> - <manufacturer> <model>"
//!   catt -d <ip> cast <url>        (-d takes NAME_OR_IP)
//!   catt -d <ip> stop
//!   atvscript scan                 -> one JSON object:
//!     {"result":"success","devices":[{"name","address","identifier",
//!      "all_identifiers","device_info",{..},"services":[{"protocol","port"}]}]}
//!   atvremote --id <identifier> play_url=<url>
//!     (blocks until playback ends; a local path is served by pyatv itself;
//!      stopping = closing that connection, i.e. ending the process)

const std = @import("std");

pub const Protocol = enum { chromecast, airplay };

pub const max_devices = 16;

pub const CastDevice = struct {
    protocol: Protocol = .chromecast,
    name: [64]u8 = std.mem.zeroes([64]u8),
    name_len: usize = 0,
    ip: [46]u8 = std.mem.zeroes([46]u8),
    ip_len: usize = 0,
    /// Tool-specific target: catt `-d` value (the IP) / pyatv `--id` identifier.
    ident: [64]u8 = std.mem.zeroes([64]u8),
    ident_len: usize = 0,

    pub fn nameSlice(self: *const CastDevice) []const u8 {
        return self.name[0..@min(self.name_len, self.name.len)];
    }
    pub fn ipSlice(self: *const CastDevice) []const u8 {
        return self.ip[0..@min(self.ip_len, self.ip.len)];
    }
    pub fn identSlice(self: *const CastDevice) []const u8 {
        return self.ident[0..@min(self.ident_len, self.ident.len)];
    }
    /// Same physical target (protocol + tool identifier).
    pub fn sameTarget(self: *const CastDevice, other: *const CastDevice) bool {
        return self.protocol == other.protocol and std.mem.eql(u8, self.identSlice(), other.identSlice());
    }
};

fn setField(buf: []u8, len: *usize, value: []const u8) void {
    const n = @min(value.len, buf.len);
    @memcpy(buf[0..n], value[0..n]);
    len.* = n;
}

pub fn makeDevice(protocol: Protocol, name: []const u8, ip: []const u8, ident: []const u8) CastDevice {
    var d = CastDevice{ .protocol = protocol };
    setField(&d.name, &d.name_len, name);
    setField(&d.ip, &d.ip_len, ip);
    setField(&d.ident, &d.ident_len, ident);
    return d;
}

fn looksLikeIp(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| {
        if (!(std.ascii.isHex(ch) or ch == '.' or ch == ':')) return false;
    }
    return std.mem.indexOfScalar(u8, s, '.') != null or std.mem.indexOfScalar(u8, s, ':') != null;
}

/// Append devices parsed from `catt scan` stdout to `out[count..]`; returns
/// the new count. Accepts the real "<ip> - <name> - <model>" lines and the
/// older "<name> - <ip>[:port]" form; banner / blank lines are skipped.
pub fn parseCattScan(text: []const u8, out: []CastDevice, count: usize) usize {
    var n = count;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n >= out.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        const dash = std.mem.indexOf(u8, line, " - ") orelse continue;
        const first = std.mem.trim(u8, line[0..dash], " ");
        const rest = line[dash + 3 ..];
        var name: []const u8 = undefined;
        var ip: []const u8 = undefined;
        if (looksLikeIp(first)) {
            ip = first;
            const end = std.mem.indexOf(u8, rest, " - ") orelse rest.len;
            name = std.mem.trim(u8, rest[0..end], " ");
        } else {
            name = first;
            const r = std.mem.trim(u8, rest, " ");
            ip = if (std.mem.lastIndexOfScalar(u8, r, ':')) |col| r[0..col] else r;
            if (!looksLikeIp(ip)) continue;
        }
        if (name.len == 0 or ip.len == 0) continue;
        out[n] = makeDevice(.chromecast, name, ip, ip);
        n += 1;
    }
    return n;
}

fn str(v: std.json.Value, key: []const u8) []const u8 {
    if (v != .object) return "";
    const f = v.object.get(key) orelse return "";
    return if (f == .string) f.string else "";
}

fn hasAirPlay(dev: std.json.Value) bool {
    if (dev != .object) return false;
    const services = dev.object.get("services") orelse return false;
    if (services != .array) return false;
    for (services.array.items) |s| {
        if (std.ascii.eqlIgnoreCase(str(s, "protocol"), "airplay")) return true;
    }
    return false;
}

/// Append AirPlay-capable devices from `atvscript scan` JSON to `out[count..]`;
/// returns the new count. Devices without an "airplay" service (pure MRP /
/// Companion / RAOP speakers) are skipped — play_url needs AirPlay video.
pub fn parseAtvscriptScan(gpa: std.mem.Allocator, text: []const u8, out: []CastDevice, count: usize) usize {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return count;
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{}) catch return count;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return count;
    if (!std.mem.eql(u8, str(root, "result"), "success")) return count;
    const devs = root.object.get("devices") orelse return count;
    if (devs != .array) return count;
    var n = count;
    for (devs.array.items) |d| {
        if (n >= out.len) break;
        if (!hasAirPlay(d)) continue;
        const ident = str(d, "identifier");
        if (ident.len == 0 or ident.len > 64) continue;
        const name = str(d, "name");
        out[n] = makeDevice(.airplay, if (name.len > 0) name else "Apple TV", str(d, "address"), ident);
        n += 1;
    }
    return n;
}

pub const catt_scan_argv = [_][]const u8{ "catt", "scan" };
pub const atv_scan_argv = [_][]const u8{ "atvscript", "scan" };

/// Fixed-capacity argv whose slices borrow from the device, the URL and
/// `arg_buf` — keep all three alive while the child runs.
pub const Argv = struct {
    items: [5][]const u8 = undefined,
    len: usize = 0,
    pub fn slice(self: *const Argv) []const []const u8 {
        return self.items[0..self.len];
    }
};

fn argvOf(parts: []const []const u8) Argv {
    var a = Argv{};
    for (parts, 0..) |p, i| a.items[i] = p;
    a.len = parts.len;
    return a;
}

/// argv to start casting `url` to `dev`. AirPlay needs "play_url=<url>" as one
/// argument, written into `arg_buf`; null when it does not fit.
pub fn castArgv(dev: *const CastDevice, url: []const u8, arg_buf: []u8) ?Argv {
    return switch (dev.protocol) {
        .chromecast => argvOf(&.{ "catt", "-d", dev.identSlice(), "cast", url }),
        .airplay => blk: {
            const arg = std.fmt.bufPrint(arg_buf, "play_url={s}", .{url}) catch break :blk null;
            break :blk argvOf(&.{ "atvremote", "--id", dev.identSlice(), arg });
        },
    };
}

/// argv for an explicit stop command, or null when stopping is done by ending
/// the cast process (AirPlay: pyatv's stop() just closes the play_url session).
pub fn stopArgv(dev: *const CastDevice) ?Argv {
    return switch (dev.protocol) {
        .chromecast => argvOf(&.{ "catt", "-d", dev.identSlice(), "stop" }),
        .airplay => null,
    };
}

/// Host part of a URL ("" when there is no "scheme://").
fn urlHost(url: []const u8) []const u8 {
    const sep = std.mem.indexOf(u8, url, "://") orelse return "";
    var rest = url[sep + 3 ..];
    if (std.mem.indexOfAny(u8, rest, "/?#")) |e| rest = rest[0..e];
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| rest = rest[at + 1 ..];
    if (rest.len > 0 and rest[0] == '[') {
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return rest;
        return rest[1..close];
    }
    if (std.mem.indexOfScalar(u8, rest, ':')) |col| rest = rest[0..col];
    return rest;
}

/// True for URLs only this machine can open (localhost / 127.x / ::1 / 0.0.0.0)
/// — a Chromecast or Apple TV fetching them would hit itself.
pub fn isLoopbackUrl(url: []const u8) bool {
    const host = urlHost(url);
    if (host.len == 0) return false;
    return std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.startsWith(u8, host, "127.") or
        std.mem.eql(u8, host, "::1") or
        std.mem.eql(u8, host, "0.0.0.0");
}

pub const msg_no_media = "No video loaded to cast";
pub const msg_loopback = "Can't cast a localhost stream: the receiver can't reach this machine's loopback address. Cast a local file or a network URL instead.";
pub const msg_no_device = "Unknown cast device. Scan again.";
pub const msg_url_too_long = "URL too long to cast";

/// Why `url` cannot be cast, or null when it can. Local file paths are fine:
/// catt and pyatv both serve them over HTTP themselves.
pub fn castRefusal(url: []const u8) ?[]const u8 {
    if (url.len == 0) return msg_no_media;
    if (isLoopbackUrl(url)) return msg_loopback;
    return null;
}

/// "chromecast" / "airplay" for JSON.
pub fn protocolName(p: Protocol) []const u8 {
    return @tagName(p);
}

/// Toast for a scan where neither tool could be launched.
pub const msg_install = "Casting needs catt (pip install catt) for Chromecast or pyatv (pip install pyatv) for AirPlay";

// ── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "catt scan: real catt 0.13 output (ip - name - model) with banner" {
    var out: [max_devices]CastDevice = undefined;
    const text =
        \\Scanning Chromecasts...
        \\192.168.1.20 - Living Room TV - Google Inc. Chromecast Ultra
        \\192.168.1.31 - Kitchen speaker - Google Inc. Google Home
        \\
    ;
    const n = parseCattScan(text, &out, 0);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("Living Room TV", out[0].nameSlice());
    try testing.expectEqualStrings("192.168.1.20", out[0].ipSlice());
    try testing.expectEqualStrings("192.168.1.20", out[0].identSlice());
    try testing.expectEqual(Protocol.chromecast, out[0].protocol);
    try testing.expectEqualStrings("Kitchen speaker", out[1].nameSlice());
}

test "catt scan: legacy name - ip:port form and garbage lines" {
    var out: [max_devices]CastDevice = undefined;
    const n = parseCattScan("Den - 10.0.0.5:8009\r\nnot a device line\nError - something bad\n", &out, 0);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualStrings("Den", out[0].nameSlice());
    try testing.expectEqualStrings("10.0.0.5", out[0].ipSlice());
}

test "catt scan: respects capacity and appends after existing count" {
    var out: [2]CastDevice = undefined;
    out[0] = makeDevice(.airplay, "x", "1.1.1.1", "id");
    const n = parseCattScan("1.2.3.4 - A - m\n1.2.3.5 - B - m\n", &out, 1);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("A", out[1].nameSlice());
    try testing.expectEqual(Protocol.airplay, out[0].protocol);
}

test "atvscript scan: keeps AirPlay devices, skips speakers without airplay" {
    var out: [max_devices]CastDevice = undefined;
    const text =
        \\{"result": "success", "datetime": "2026-01-01T00:00:00+00:00", "devices": [
        \\ {"name": "Vardagsrum", "address": "10.0.10.81", "identifier": "6D797FD3-3538-427E-A47B-A32FC6CF3A69",
        \\  "all_identifiers": ["6D797FD3-3538-427E-A47B-A32FC6CF3A69", "AA:BB:CC:DD:EE:FF"],
        \\  "device_info": {"mac": "AA:BB:CC:DD:EE:FF", "model": "Gen4K", "model_str": "Apple TV 4K", "operating_system": "TvOS", "version": "17.0"},
        \\  "services": [{"protocol": "mrp", "port": 49152}, {"protocol": "airplay", "port": 7000}]},
        \\ {"name": "HomePod", "address": "10.0.10.90", "identifier": "HP1",
        \\  "services": [{"protocol": "raop", "port": 7000}, {"protocol": "companion", "port": 49153}]}
        \\]}
    ;
    const n = parseAtvscriptScan(testing.allocator, text, &out, 0);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(Protocol.airplay, out[0].protocol);
    try testing.expectEqualStrings("Vardagsrum", out[0].nameSlice());
    try testing.expectEqualStrings("10.0.10.81", out[0].ipSlice());
    try testing.expectEqualStrings("6D797FD3-3538-427E-A47B-A32FC6CF3A69", out[0].identSlice());
}

test "atvscript scan: failure result, bad JSON and empty input add nothing" {
    var out: [max_devices]CastDevice = undefined;
    try testing.expectEqual(@as(usize, 0), parseAtvscriptScan(testing.allocator, "{\"result\":\"failure\",\"error\":\"x\"}", &out, 0));
    try testing.expectEqual(@as(usize, 3), parseAtvscriptScan(testing.allocator, "not json", &out, 3));
    try testing.expectEqual(@as(usize, 0), parseAtvscriptScan(testing.allocator, "\n", &out, 0));
    try testing.expectEqual(@as(usize, 0), parseAtvscriptScan(testing.allocator, "{\"result\":\"success\",\"devices\":[{\"name\":\"n\",\"identifier\":\"\",\"services\":[{\"protocol\":\"airplay\",\"port\":7000}]}]}", &out, 0));
}

test "castArgv: catt targets by IP, atvremote by identifier with play_url=" {
    var buf: [256]u8 = undefined;
    const cc = makeDevice(.chromecast, "TV", "192.168.1.20", "192.168.1.20");
    const a = castArgv(&cc, "https://x.test/v.mp4", &buf).?;
    const want_cc = [_][]const u8{ "catt", "-d", "192.168.1.20", "cast", "https://x.test/v.mp4" };
    try testing.expectEqual(want_cc.len, a.slice().len);
    for (want_cc, a.slice()) |w, g| try testing.expectEqualStrings(w, g);

    const ap = makeDevice(.airplay, "ATV", "10.0.0.2", "AA:BB");
    const b = castArgv(&ap, "/Users/me/Movies/a b.mkv", &buf).?;
    const want_ap = [_][]const u8{ "atvremote", "--id", "AA:BB", "play_url=/Users/me/Movies/a b.mkv" };
    try testing.expectEqual(want_ap.len, b.slice().len);
    for (want_ap, b.slice()) |w, g| try testing.expectEqualStrings(w, g);

    var tiny: [8]u8 = undefined;
    try testing.expect(castArgv(&ap, "https://x.test/v.mp4", &tiny) == null);
}

test "stopArgv: catt stop for Chromecast, process end for AirPlay" {
    const cc = makeDevice(.chromecast, "TV", "192.168.1.20", "192.168.1.20");
    const s = stopArgv(&cc).?;
    const want = [_][]const u8{ "catt", "-d", "192.168.1.20", "stop" };
    for (want, s.slice()) |w, g| try testing.expectEqualStrings(w, g);
    const ap = makeDevice(.airplay, "ATV", "10.0.0.2", "AA:BB");
    try testing.expect(stopArgv(&ap) == null);
}

test "castRefusal: loopback URLs refused, LAN/internet URLs and local paths allowed" {
    try testing.expectEqualStrings(msg_no_media, castRefusal("").?);
    try testing.expectEqualStrings(msg_loopback, castRefusal("http://127.0.0.1:8080/stream").?);
    try testing.expect(castRefusal("http://localhost/x") != null);
    try testing.expect(castRefusal("http://LOCALHOST:9/x") != null);
    try testing.expect(castRefusal("http://[::1]:41595/stream") != null);
    try testing.expect(castRefusal("http://user:pw@127.0.0.2/x") != null);
    try testing.expect(castRefusal("http://0.0.0.0:1/x") != null);
    try testing.expect(castRefusal("http://192.168.1.4:41595/x") == null);
    try testing.expect(castRefusal("https://example.com/127.0.0.1.mp4") == null);
    try testing.expect(castRefusal("/Users/me/Movies/a.mkv") == null);
}

test "sameTarget compares protocol and identifier" {
    const a = makeDevice(.chromecast, "A", "1.2.3.4", "1.2.3.4");
    const b = makeDevice(.chromecast, "renamed", "1.2.3.4", "1.2.3.4");
    const c = makeDevice(.airplay, "A", "1.2.3.4", "1.2.3.4");
    try testing.expect(a.sameTarget(&b));
    try testing.expect(!a.sameTarget(&c));
}
