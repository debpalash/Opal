//! Pure Android host logic: inset scaling and external-URL policy.
const std = @import("std");
const links = @import("../services/browser_link_pure.zig");
const platform = @import("../core/platform_pure.zig");

pub const Insets = struct { top: f32 = 0, bottom: f32 = 0, left: f32 = 0, right: f32 = 0 };
pub const Logical = struct { insets: Insets, keyboard: f32 };

fn clean(v: f32) f32 {
    return if (std.math.isFinite(v) and v > 0) v else 0;
}

/// Convert physical-pixel insets from Java to dvui logical units. A zero or
/// non-finite width yields scale 1 so a bad window query cannot blow up layout.
pub fn toLogical(px: Insets, keyboard_px: f32, logical_w: f32, pixel_w: f32) Logical {
    const scale: f32 = if (std.math.isFinite(logical_w) and std.math.isFinite(pixel_w) and logical_w > 0 and pixel_w > 0) logical_w / pixel_w else 1;
    return .{
        .insets = .{ .top = clean(px.top) * scale, .bottom = clean(px.bottom) * scale, .left = clean(px.left) * scale, .right = clean(px.right) * scale },
        .keyboard = clean(keyboard_px) * scale,
    };
}

/// Only plain http(s) links may reach ACTION_VIEW.
pub fn externalUrl(raw: []const u8) ?[]const u8 {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    links.validateHttpUrl(value, 2047) catch return null;
    return value;
}

/// Set by the SDL key watch when Android's Back key (SDLK_AC_BACK) goes down;
/// consumed once per frame by the shared shell.
pub var back_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub const BackAction = enum { leave_player, go_back, background };

/// Back leaves the player first, then pops navigation history; at the root
/// the app goes to the background instead of closing.
pub fn backAction(in_player: bool, can_go_back: bool) BackAction {
    if (in_player) return .leave_player;
    if (can_go_back) return .go_back;
    return .background;
}

/// The transfer foreground service is wanted while anything is moving or queued.
/// Whether one torrent should keep the background service (notification +
/// wake lock) alive: unpaused and still fetching metadata or downloading.
/// Seeding-only torrents do not — they would hold a wake lock indefinitely.
pub fn torrentKeepsAwake(paused: bool, has_metadata: bool, progress: f32) bool {
    if (paused) return false;
    if (!has_metadata) return true;
    return !(progress >= 1.0);
}

test "torrentKeepsAwake: downloading yes, seeding and paused no" {
    try std.testing.expect(torrentKeepsAwake(false, false, 0));
    try std.testing.expect(torrentKeepsAwake(false, true, 0.42));
    try std.testing.expect(!torrentKeepsAwake(false, true, 1.0));
    try std.testing.expect(!torrentKeepsAwake(true, true, 0.42));
    try std.testing.expect(!torrentKeepsAwake(true, false, 0));
    // NaN progress from a bad poll counts as still downloading, not seeding.
    try std.testing.expect(torrentKeepsAwake(false, true, std.math.nan(f32)));
}

pub fn hasActiveTransfers(live_unpaused_torrents: usize, http_active: usize, http_queued: usize) bool {
    return live_unpaused_torrents + http_active + http_queued > 0;
}

test "backAction: player, history, then background" {
    try std.testing.expectEqual(BackAction.leave_player, backAction(true, true));
    try std.testing.expectEqual(BackAction.leave_player, backAction(true, false));
    try std.testing.expectEqual(BackAction.go_back, backAction(false, true));
    try std.testing.expectEqual(BackAction.background, backAction(false, false));
}

test "hasActiveTransfers counts torrents, active and queued http" {
    try std.testing.expect(!hasActiveTransfers(0, 0, 0));
    try std.testing.expect(hasActiveTransfers(1, 0, 0));
    try std.testing.expect(hasActiveTransfers(0, 1, 0));
    try std.testing.expect(hasActiveTransfers(0, 0, 2));
}

test "toLogical scales physical pixels and clamps bad input" {
    const r = toLogical(.{ .top = 100, .bottom = 50, .left = 0, .right = 20 }, 400, 540, 1080);
    try std.testing.expectEqual(@as(f32, 50), r.insets.top);
    try std.testing.expectEqual(@as(f32, 25), r.insets.bottom);
    try std.testing.expectEqual(@as(f32, 10), r.insets.right);
    try std.testing.expectEqual(@as(f32, 200), r.keyboard);
    const bad = toLogical(.{ .top = std.math.nan(f32), .bottom = -5, .left = std.math.inf(f32), .right = 3 }, -1, 0, 0);
    try std.testing.expectEqual(@as(f32, 0), bad.insets.top);
    try std.testing.expectEqual(@as(f32, 0), bad.insets.bottom);
    try std.testing.expectEqual(@as(f32, 0), bad.insets.left);
    try std.testing.expectEqual(@as(f32, 3), bad.insets.right);
    try std.testing.expectEqual(@as(f32, 0), bad.keyboard);
}

test "externalUrl allows only http(s) without credentials" {
    try std.testing.expectEqualStrings("https://opal.example/a?b=1", externalUrl(" https://opal.example/a?b=1\n").?);
    for ([_][]const u8{ "", "javascript:alert(1)", "file:///etc/passwd", "intent://x#Intent;end", "https://u:p@opal.example/" }) |bad|
        try std.testing.expect(externalUrl(bad) == null);
}

test "regression: Android save path under HOME passes storedPathUsable" {
    const home = "/storage/emulated/0/Android/data/com.debpalash.opal/files";
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ home, platform.mobileSaveSubdir(.linux, .android).? });
    try std.testing.expect(platform.storedPathUsable(path, home, true));
    try std.testing.expect(!platform.storedPathUsable("/sdcard/Download", home, true));
}
