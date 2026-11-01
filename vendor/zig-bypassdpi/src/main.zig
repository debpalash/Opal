//! zig-bypassdpi — a userspace DPI-bypass proxy.
//!
//! Listens locally as a combined SOCKS5 + HTTP CONNECT proxy and fragments the
//! first TLS ClientHello of each :443 connection so a Deep Packet Inspection
//! engine cannot reassemble the SNI hostname. Pure BSD sockets, no root, no
//! kernel module.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const proxy = @import("proxy.zig");
const desync = @import("desync.zig");

const usage =
    \\zig-bypassdpi — userspace DPI-bypass proxy (SOCKS5 + HTTP CONNECT)
    \\
    \\Usage: zig-bypassdpi [options]
    \\
    \\Options:
    \\  --port <N>       Listen port           (default 8881)
    \\  --listen <IP>    Listen address        (default 127.0.0.1)
    \\  --mode <MODE>    Desync split strategy (default sni)
    \\                     sni       split in the middle of the SNI hostname
    \\                     split:N   split after the first N bytes (e.g. split:2)
    \\  -v, --verbose    Log each connection / fragmentation
    \\  -h, --help       Show this help
    \\
    \\Examples:
    \\  zig-bypassdpi --port 8881 --mode sni
    \\  curl --socks5-hostname 127.0.0.1:8881 https://example.com
    \\  curl -x http://127.0.0.1:8881 https://www.google.com
    \\
;

fn parseMode(s: []const u8) ?desync.Mode {
    if (std.mem.eql(u8, s, "sni")) return .sni;
    if (std.mem.eql(u8, s, "split")) return .{ .split = 1 };
    if (std.mem.startsWith(u8, s, "split:")) {
        const n = std.fmt.parseInt(usize, s["split:".len..], 10) catch return null;
        if (n == 0) return null;
        return .{ .split = n };
    }
    return null;
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn onSignal(_: posix.SIG) callconv(.c) void {
    // Async-signal-safe enough for a CLI: just exit. Detached connection
    // threads and the listener are reclaimed by the OS.
    std.process.exit(0);
}

fn installSignalHandler() void {
    if (builtin.os.tag == .windows) return;
    var act: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);
}

pub fn main(init: std.process.Init) !void {
    // The runtime hands us a ready threaded Io backend (blocking sockets we can
    // fan out across per-connection OS threads) plus an allocator.
    const io = init.io;
    const gpa = init.gpa;

    // `--listen` / `--mode` values are borrowed from the argv strings, which
    // must outlive the whole run, so copy them into an arena.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cfg: proxy.Config = .{};

    // initAllocator (not iterate): on Windows/WASI the command line must be
    // decoded with an allocator, and `iterate()` is a hard @compileError there.
    // The allocator form is portable and is what lets this run on Windows.
    var it = try init.minimal.args.iterateAllocator(gpa);
    defer it.deinit();
    _ = it.skip(); // argv0
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        } else if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose")) {
            cfg.verbose = true;
        } else if (std.mem.eql(u8, a, "--port")) {
            const v = it.next() orelse fail("--port needs a value", .{});
            cfg.port = std.fmt.parseInt(u16, v, 10) catch fail("invalid --port \"{s}\"", .{v});
        } else if (std.mem.eql(u8, a, "--listen")) {
            const v = it.next() orelse fail("--listen needs a value", .{});
            cfg.host = arena.dupe(u8, v) catch fail("out of memory", .{});
        } else if (std.mem.eql(u8, a, "--mode")) {
            const v = it.next() orelse fail("--mode needs a value", .{});
            const owned = arena.dupe(u8, v) catch fail("out of memory", .{});
            cfg.mode = parseMode(owned) orelse fail("invalid --mode \"{s}\" (use sni or split:N)", .{v});
        } else {
            fail("unknown argument \"{s}\" (try --help)", .{a});
        }
    }

    installSignalHandler();

    try proxy.run(io, cfg);
}
