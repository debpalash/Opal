//! `chapters_probe <ffmpeg> <ffprobe> <file> [intro_start intro_end]` — runs
//! the shipped scene pass (auto_chapters_pure.sceneArgv + parseScenes) and
//! chapter builder on a real file and prints one "<start> <title>" line per
//! chapter, so the feature test checks production logic on ffmpeg output.
const std = @import("std");
const ac = @import("chapters");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const ffmpeg = args.next() orelse return error.Usage;
    const ffprobe = args.next() orelse return error.Usage;
    const path = args.next() orelse return error.Usage;
    var intro: ?ac.Span = null;
    if (args.next()) |s| intro = .{ .start = try std.fmt.parseFloat(f64, s), .end = try std.fmt.parseFloat(f64, args.next() orelse return error.Usage) };

    const probe = try std.process.run(init.gpa, init.io, .{ .argv = &.{ ffprobe, "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", path } });
    defer init.gpa.free(probe.stdout);
    defer init.gpa.free(probe.stderr);
    const duration = try std.fmt.parseFloat(f64, std.mem.trim(u8, probe.stdout, " \r\n\t"));

    var argv_buf: [ac.SCENE_ARGC][]const u8 = undefined;
    const r = try std.process.run(init.gpa, init.io, .{ .argv = ac.sceneArgv(ffmpeg, path, &argv_buf) });
    defer init.gpa.free(r.stdout);
    defer init.gpa.free(r.stderr);
    var cuts: [4096]ac.Cut = undefined;
    const nc = ac.parseScenes(r.stdout, &cuts);
    var chapters: [ac.MAX_CHAPTERS]ac.Chapter = undefined;
    const n = ac.build(cuts[0..nc], duration, intro, null, &chapters);

    var out: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    try w.print("cuts={d} duration={d:.2}\n", .{ nc, duration });
    for (0..n) |i| {
        var tb: [32]u8 = undefined;
        try w.print("{d:.3} {s}\n", .{ chapters[i].start, ac.title(chapters[0..n], i, &tb) });
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, w.buffered());
}
