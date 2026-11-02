const std = @import("std");
/// Preserve existing zero-terminated formatting call sites on Zig 0.17.
pub fn bufPrintZ(buf: []u8, comptime fmt: []const u8, args: anytype) std.fmt.BufPrintError![:0]u8 {
    return std.mem.printSentinel(buf, fmt, args, 0);
}
