const std = @import("std");
const state = @import("../core/state.zig");
const c = @import("../core/c.zig");

// ══════════════════════════════════════════════════════════
// Cast — Send media to Chromecast/DLNA using external tools
// Requires: catt (pip install catt) or castnow (npm i -g castnow)
// ══════════════════════════════════════════════════════════

const alloc = @import("../core/alloc.zig").allocator;

pub const CastDevice = struct {
    name: [64]u8 = std.mem.zeroes([64]u8),
    name_len: usize = 0,
    ip: [46]u8 = std.mem.zeroes([46]u8),
    ip_len: usize = 0,
};

pub var devices: [16]CastDevice = undefined;
pub var device_count: usize = 0;
pub var is_scanning: bool = false;
pub var is_casting: bool = false;
pub var active_device_idx: ?usize = null;

/// Discover cast devices using `catt scan`
pub fn scanDevices() void {
    if (is_scanning) return;
    is_scanning = true;
    device_count = 0;

    if (std.Thread.spawn(.{}, struct {
        fn worker() void {
            defer {
                is_scanning = false;
            }

            const argv = [_][]const u8{ "catt", "scan", "-t", "5" };
            var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Ignore;
            child.spawn() catch {
                state.showToast("Install catt: pip install catt");
                return;
            };

            var buf: [4096]u8 = undefined;
            const n = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, &buf) catch 0 else 0;
            _ = child.wait() catch {};

            if (n == 0) return;

            // Parse output: each line is "DeviceName - IP:port"
            var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
            while (lines.next()) |line| {
                if (line.len < 5 or device_count >= 16) continue;
                if (std.mem.indexOf(u8, line, " - ")) |dash_pos| {
                    const name = line[0..dash_pos];
                    const ip_part = line[dash_pos + 3 ..];
                    // Strip port if present
                    const ip = if (std.mem.indexOf(u8, ip_part, ":")) |col| ip_part[0..col] else ip_part;

                    var dev = &devices[device_count];
                    const nlen = @min(name.len, 63);
                    @memcpy(dev.name[0..nlen], name[0..nlen]);
                    dev.name_len = nlen;
                    const ilen = @min(ip.len, 45);
                    @memcpy(dev.ip[0..ilen], ip[0..ilen]);
                    dev.ip_len = ilen;
                    device_count += 1;
                }
            }

            if (device_count > 0) {
                var msg: [64]u8 = undefined;
                const toast = std.fmt.bufPrint(&msg, "Found {d} cast device(s)", .{device_count}) catch "Devices found";
                state.showToast(toast);
            } else {
                state.showToast("No cast devices found");
            }
        }
    }.worker, .{})) |t| t.detach() else |_| {}
}

/// Cast current video URL to a device
pub fn castTo(device_idx: usize) void {
    if (device_idx >= device_count) return;
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    
    const p = state.app.players.items[state.app.active_player_idx];
    if (p.current_url_len == 0) {
        state.showToast("No video loaded to cast");
        return;
    }

    is_casting = true;
    active_device_idx = device_idx;
    const url = p.current_url[0..p.current_url_len];
    const device_name = devices[device_idx].name[0..devices[device_idx].name_len];

    // Allocate copies for the thread
    const url_copy = alloc.dupe(u8, url) catch return;
    const name_copy = alloc.dupe(u8, device_name) catch return;

    if (std.Thread.spawn(.{}, struct {
        fn worker(u: []const u8, dev: []const u8) void {
            defer {
                is_casting = false;
                alloc.free(u);
                alloc.free(dev);
            }

            const argv = [_][]const u8{ "catt", "-d", dev, "cast", u };
            var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
            child.stdout_behavior = .Inherit;
            child.stderr_behavior = .Inherit;
            child.spawn() catch {
                state.showToast("Cast failed");
                return;
            };

            state.showToast("Casting...");
            _ = child.wait() catch {};
        }
    }.worker, .{ url_copy, name_copy })) |t| t.detach() else |_| {}
}

/// Stop casting
pub fn stopCast() void {
    if (std.Thread.spawn(.{}, struct {
        fn worker() void {
            const argv = [_][]const u8{ "catt", "stop" };
            var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
            child.spawn() catch return;
            _ = child.wait() catch {};
            is_casting = false;
            active_device_idx = null;
            state.showToast("Cast stopped");
        }
    }.worker, .{})) |t| t.detach() else |_| {}
}
