//! Responsive local-library forms; no UI or database dependencies.
const std = @import("std");

pub fn stackFormControls(available_width: f32) bool {
    // Folder paths and metadata titles need usable fields beside their actions.
    return !std.math.isFinite(available_width) or available_width < 620;
}

pub fn emptyHint(query_length: usize, duplicates_only: bool, roots: usize) []const u8 {
    if (query_length > 0) return "No files match this search.";
    if (duplicates_only) return "No likely duplicates found.";
    if (roots == 0) return "Add a media folder, then scan to see your files here.";
    return "No files indexed yet. Scan your media folders to refresh.";
}

test "Local library folder and editor controls stack in compact windows" {
    try std.testing.expect(stackFormControls(584)); // 640px shell minus panel padding.
    try std.testing.expect(stackFormControls(619));
    try std.testing.expect(!stackFormControls(620));
    try std.testing.expect(!stackFormControls(1200));
    try std.testing.expect(stackFormControls(std.math.nan(f32)));
}

test "Local library empty states give the next useful action" {
    try std.testing.expectEqualStrings("No files match this search.", emptyHint(3, false, 0));
    try std.testing.expectEqualStrings("No likely duplicates found.", emptyHint(0, true, 2));
    try std.testing.expectEqualStrings("Add a media folder, then scan to see your files here.", emptyHint(0, false, 0));
    try std.testing.expectEqualStrings("No files indexed yet. Scan your media folders to refresh.", emptyHint(0, false, 1));
}
