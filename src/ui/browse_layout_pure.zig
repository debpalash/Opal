//! The page shell owns the one global title-search input. Provider browsing
//! keeps local filters and configuration; legacy layouts retain local search.
const std = @import("std");
pub fn showLocalSearch(page_shell_enabled: bool) bool {
    return !page_shell_enabled;
}
pub fn toolbarHeight(body_font_size: f32) f32 {
    return @max(48, body_font_size * 2 + 20);
}
test "browse toolbar height retains room for large-font controls" {
    try std.testing.expectEqual(@as(f32, 48), toolbarHeight(14));
    try std.testing.expect(toolbarHeight(24) >= 24 * 2 + 20);
}
pub const ReadingGrid = struct { columns: usize, card_width: f32 };
pub fn readingGrid(viewport_width: f32) ReadingGrid {
    const width = @max(1, viewport_width);
    const columns: usize = if (width >= 1060) 4 else if (width >= 760) 3 else if (width >= 500) 2 else 1;
    return .{ .columns = columns, .card_width = @max(1, (width - 16) / @as(f32, @floatFromInt(columns)) - 8) };
}
test "reading grid width reserves row padding and every card margin" {
    for ([_]f32{ 320, 640, 800, 1360 }) |width| {
        const grid = readingGrid(width);
        try std.testing.expect(grid.card_width > 0);
        try std.testing.expect(16 + @as(f32, @floatFromInt(grid.columns)) * (grid.card_width + 8) <= width + 0.01);
    }
    try std.testing.expectEqual(@as(usize, 1), readingGrid(320).columns);
    try std.testing.expectEqual(@as(usize, 4), readingGrid(1360).columns);
}
test "page shell has one title search and legacy browse retains local search" {
    try std.testing.expect(!showLocalSearch(true));
    try std.testing.expect(showLocalSearch(false));
}
