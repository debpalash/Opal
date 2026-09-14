const std = @import("std");

pub const Layout = struct {
    viewport_width: f32,
    width: f32,
    stacked: bool,
    columns: usize,
    card_width: f32,
    thumbnail_width: f32,
    thumbnail_height: f32,
};

/// Work in layout units after display/UI scaling, including drawer mode.
pub fn calculate(available: f32) Layout {
    const viewport_width = if (std.math.isFinite(available)) @max(1, available) else 320;
    // Reading-width cap: ultrawide windows get a dense two-column catalogue
    // instead of one 1800px row with its controls stranded in the middle.
    const width = @min(viewport_width, 1480);
    const stacked = width < 640;
    const columns: usize = if (width >= 1080) 2 else 1;
    const gap: f32 = 8;
    // Card width is CONTENT width; each rendered card adds 8px horizontal
    // padding on both sides. Account for it here so two cards never overflow
    // their row and silently collapse back into a strange partial column.
    const card_width = @max(1, (if (columns == 2) (width - gap) / 2 else width) - 16);
    const thumbnail_width = if (stacked) @max(1, card_width - 16) else @min(176, card_width * 0.27);
    return .{
        .viewport_width = viewport_width,
        .width = width,
        .stacked = stacked,
        .columns = columns,
        .card_width = card_width,
        .thumbnail_width = thumbnail_width,
        .thumbnail_height = thumbnail_width * 9 / 16,
    };
}

pub const EpisodeState = enum { available, upcoming, tba };

fn validDate(value: []const u8) bool {
    if (value.len != 10 or value[4] != '-' or value[7] != '-') return false;
    for (value, 0..) |c, i| {
        if (i == 4 or i == 7) continue;
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// Classify an episode without guessing that an undated future entry is
/// playable. `known_aired` comes from the synced show frontier and wins over
/// incomplete provider metadata.
pub fn episodeState(air_date: []const u8, today: []const u8, known_aired: bool) EpisodeState {
    if (known_aired) return .available;
    if (!validDate(air_date)) return .tba;
    if (!validDate(today)) return .available;
    return if (std.mem.order(u8, air_date, today) == .gt) .upcoming else .available;
}

test "TV cards fit phone tablet desktop and scaled drawer widths" {
    for ([_]f32{ 240, 320, 375, 480, 639, 640, 768, 1024, 1920 }) |width| {
        const layout = calculate(width);
        try std.testing.expect(layout.thumbnail_width <= width);
        try std.testing.expectApproxEqAbs(@as(f32, 16.0 / 9.0), layout.thumbnail_width / layout.thumbnail_height, 0.001);
        try std.testing.expectEqual(width < 640, layout.stacked);
        try std.testing.expectEqual(@as(usize, if (@min(width, 1480) >= 1080) 2 else 1), layout.columns);
        try std.testing.expect(layout.card_width <= layout.width);
    }
    try std.testing.expect(calculate(std.math.nan(f32)).stacked);
    try std.testing.expect(calculate(0).thumbnail_width > 0);
    try std.testing.expectEqual(@as(f32, 1480), calculate(3000).width);
}

test "episode state separates playable upcoming and undated entries" {
    try std.testing.expectEqual(EpisodeState.available, episodeState("2026-09-14", "2026-09-14", false));
    try std.testing.expectEqual(EpisodeState.upcoming, episodeState("2026-09-21", "2026-09-14", false));
    try std.testing.expectEqual(EpisodeState.tba, episodeState("", "2026-09-14", false));
    try std.testing.expectEqual(EpisodeState.available, episodeState("", "2026-09-14", true));
}
