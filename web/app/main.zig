const std = @import("std");
const zx = @import("zx");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try zx.serve(allocator, .{
        .port = 3000,
        .host = "0.0.0.0",
    });
}
