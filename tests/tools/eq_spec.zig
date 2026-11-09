//! Prints the shipped ffmpeg eq spec (av_pure.gradeFilterSpec) for
//! `eq_spec <preset 0-5> [brightness contrast saturation gamma]` so the
//! behavioural probe tests the exact string production would use.
const std = @import("std");
const av = @import("av");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const preset = std.fmt.parseInt(usize, args.next() orelse "1", 10) catch 1;
    var m = av.PictureValues{};
    inline for (.{ "brightness", "contrast", "saturation", "gamma" }) |f| {
        @field(m, f) = std.fmt.parseInt(i32, args.next() orelse "0", 10) catch 0;
    }
    var buf: [160]u8 = undefined;
    const spec = av.gradeFilterSpec(&buf, av.combineGrade(av.pictureValues(av.picturePresetFromInt(preset)), m));
    try std.Io.File.stdout().writeStreamingAll(init.io, spec);
}
