//! `phash_probe <ffmpeg> <ffprobe> <reference> <candidate>...` — signs every
//! file with the shipped sampler (phash_pure.samplePositions + frameArgv +
//! setSample) and prints one `compare` verdict per candidate against the
//! reference, so the feature test exercises the exact production logic on
//! real ffmpeg output.
const std = @import("std");
const ph = @import("phash");

fn duration(init: std.process.Init, ffprobe: []const u8, path: []const u8) !f64 {
    const r = try std.process.run(init.gpa, init.io, .{ .argv = &.{ ffprobe, "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", path } });
    defer init.gpa.free(r.stdout);
    defer init.gpa.free(r.stderr);
    return std.fmt.parseFloat(f64, std.mem.trim(u8, r.stdout, " \r\n\t"));
}

fn sign(init: std.process.Init, ffmpeg: []const u8, ffprobe: []const u8, path: []const u8) !ph.Signature {
    var sig: ph.Signature = .{ .duration = try duration(init, ffprobe, path) };
    var pos: [ph.SAMPLES]f64 = undefined;
    if (!ph.samplePositions(sig.duration, &pos)) return error.BadDuration;
    for (pos, 0..) |t, i| {
        var ts: [32]u8 = undefined;
        var argv_buf: [ph.FRAME_ARGC][]const u8 = undefined;
        const argv = ph.frameArgv(ffmpeg, path, t, &ts, &argv_buf) orelse return error.Argv;
        const r = try std.process.run(init.gpa, init.io, .{ .argv = argv });
        defer init.gpa.free(r.stdout);
        defer init.gpa.free(r.stderr);
        ph.setSample(&sig, i, if (r.stdout.len == ph.FRAME_BYTES) r.stdout[0..ph.FRAME_BYTES] else null);
    }
    return sig;
}

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const ffmpeg = args.next() orelse return error.Usage;
    const ffprobe = args.next() orelse return error.Usage;
    const ref_path = args.next() orelse return error.Usage;
    const ref = try sign(init, ffmpeg, ffprobe, ref_path);
    var out_buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_buf);
    while (args.next()) |path| {
        const m = ph.compare(ref, try sign(init, ffmpeg, ffprobe, path));
        try w.print("{s} duplicate={d} valid={d} close={d} mean={d:.2}\n", .{ path, @intFromBool(m.duplicate), m.valid, m.close, m.mean_distance });
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, w.buffered());
}
