//! Drives the shipped helper installer (src/core/helper_install.zig) against a
//! real directory with a local fixture file standing in for the download, so
//! tests/features/test_extraction_privacy.py can check staging, verification,
//! atomic publish, rollback and startup cleanup without the network.
//!
//!   install  <dir> <name> <fixture|-fail> <sha256|-> [probe-ok|probe-fail]
//!   cleanup  <dir> <name>
//!   rollback <dir> <name>
//!
//! Prints one `key=value` line.
const std = @import("std");
const hi = @import("helper_install");

const Ctx = struct {
    io: std.Io,
    fixture: []const u8,
    probe_ok: bool,

    fn fetch(ctx: ?*anyopaque, stage_path: []const u8) hi.FetchResult {
        const self: *Ctx = @ptrCast(@alignCast(ctx.?));
        if (std.mem.eql(u8, self.fixture, "-fail")) return .http_error;
        std.Io.Dir.copyFileAbsolute(self.fixture, stage_path, self.io, .{}) catch return .transport;
        return .ok;
    }
    fn probe(ctx: ?*anyopaque, _: []const u8) bool {
        const self: *Ctx = @ptrCast(@alignCast(ctx.?));
        return self.probe_ok;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const mode = args.next() orelse return error.Usage;
    const dir_path = args.next() orelse return error.Usage;
    const name = args.next() orelse return error.Usage;
    const dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer dir.close(io);

    var out_buf: [256]u8 = undefined;
    const line = if (std.mem.eql(u8, mode, "install")) blk: {
        const fixture = args.next() orelse return error.Usage;
        const sha = args.next() orelse "-";
        const probe_mode = args.next() orelse "probe-ok";
        var ctx: Ctx = .{ .io = io, .fixture = fixture, .probe_ok = std.mem.eql(u8, probe_mode, "probe-ok") };
        const r = hi.install(io, .{ .dir = dir, .dir_path = dir_path, .name = name }, .{
            .expect = .{ .sha256_hex = if (std.mem.eql(u8, sha, "-")) null else sha },
            .executable = true,
        }, .{ .ctx = &ctx, .fetch = Ctx.fetch, .probe = Ctx.probe });
        break :blk try std.fmt.bufPrint(&out_buf, "ok={d} failure={s} kept_previous={d}\n", .{
            @intFromBool(r.ok()),
            if (r.failure) |f| @tagName(f) else "none",
            @intFromBool(r.kept_previous),
        });
    } else if (std.mem.eql(u8, mode, "cleanup")) blk: {
        const r = hi.cleanupStale(io, dir, name);
        break :blk try std.fmt.bufPrint(&out_buf, "removed={d} restored={d}\n", .{ r.removed, @intFromBool(r.restored) });
    } else if (std.mem.eql(u8, mode, "rollback")) blk: {
        break :blk try std.fmt.bufPrint(&out_buf, "ok={d}\n", .{@intFromBool(hi.rollback(io, dir, name))});
    } else return error.Usage;
    try std.Io.File.stdout().writeStreamingAll(io, line);
}
