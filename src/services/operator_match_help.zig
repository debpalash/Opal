//! match_help: a wanted title keeps finding nothing, the agent suggested other
//! titles it is known by. Applied without asking: the only effect is extra
//! wording for the same search, and the engine still applies its normal quality,
//! junk and year rules to every release found with it.

const std = @import("std");
const alloc = @import("../core/alloc.zig").allocator;
const pure = @import("operator_pure.zig");
const wanted = @import("wanted.zig");

/// `key` is the wanted item id as text.
pub fn handle(key: []const u8, result_json: []const u8) pure.Handled {
    const id = std.fmt.parseInt(i64, key, 10) catch return pure.Handled.make(.failed, "Bad item id", .{});
    const answer = pure.parseMatchHelp(alloc, result_json) orelse
        return pure.Handled.make(.failed, "No usable alternative titles", .{});
    var titles: [pure.MAX_QUERIES][]const u8 = undefined;
    for (0..answer.count) |i| titles[i] = answer.get(i);
    if (!wanted.setExtraTitles(id, titles[0..answer.count]))
        return pure.Handled.make(.failed, "The wanted item changed or has no usable titles", .{});
    return pure.Handled.make(.applied, "Added {d} alternate title{s} to a wanted item", .{ answer.count, if (answer.count == 1) "" else "s" });
}
