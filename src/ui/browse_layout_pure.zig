//! The page shell owns the one global title-search input. Provider browsing
//! keeps local filters and configuration; legacy layouts retain local search.
const std = @import("std");
pub fn showLocalSearch(page_shell_enabled: bool) bool {
    return !page_shell_enabled;
}
pub fn toolbarHeight(body_font_size: f32) f32 {
    return @max(40, body_font_size * 1.5 + 16);
}
test "browse toolbar height retains room for large-font controls" {
    try std.testing.expectEqual(@as(f32, 40), toolbarHeight(14));
    try std.testing.expect(toolbarHeight(24) >= 24 * 1.5 + 16);
}
test "page shell has one title search and legacy browse retains local search" {
    try std.testing.expect(!showLocalSearch(true));
    try std.testing.expect(showLocalSearch(false));
}
