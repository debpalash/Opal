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
    // Season detail is an immersive catalogue: use the whole pane instead of
    // centering a reading-width column and wasting the outer thirds.
    const width = viewport_width;
    const stacked = width < 640;
    const columns: usize = if (width >= 1440) 4 else if (width >= 1080) 3 else if (width >= 700) 2 else 1;
    // 12px catalogue insets, 12px gutters, and a 1px card border.
    const count: f32 = @floatFromInt(columns);
    const card_width = @max(1, (width - 24 - 12 * (count - 1)) / count - 2);
    const thumbnail_width = card_width;
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
        try std.testing.expectEqual(@as(usize, if (width >= 1440) 4 else if (width >= 1080) 3 else if (width >= 700) 2 else 1), layout.columns);
        try std.testing.expect(layout.card_width <= layout.width);
    }
    try std.testing.expect(calculate(std.math.nan(f32)).stacked);
    try std.testing.expect(calculate(0).thumbnail_width > 0);
    try std.testing.expectEqual(@as(f32, 3000), calculate(3000).width);
}

test "episode state separates playable upcoming and undated entries" {
    try std.testing.expectEqual(EpisodeState.available, episodeState("2026-09-14", "2026-09-14", false));
    try std.testing.expectEqual(EpisodeState.upcoming, episodeState("2026-09-21", "2026-09-14", false));
    try std.testing.expectEqual(EpisodeState.tba, episodeState("", "2026-09-14", false));
    try std.testing.expectEqual(EpisodeState.available, episodeState("", "2026-09-14", true));
}

test "episode gallery reserves full width artwork across breakpoints" {
    for ([_]f32{ 320, 640, 900, 1280, 1920 }) |width| {
        const layout = calculate(width);
        try std.testing.expectApproxEqAbs(layout.card_width, layout.thumbnail_width, 0.001);
    }
}

test "episode gallery borders gutters and insets fit the viewport" {
    for ([_]f32{ 240, 640, 700, 1080, 1440, 1920, 3000 }) |width| {
        const l = calculate(width);
        const n: f32 = @floatFromInt(l.columns);
        try std.testing.expectApproxEqAbs(width, 24 + n * (l.card_width + 2) + (n - 1) * 12, 0.001);
    }
}
