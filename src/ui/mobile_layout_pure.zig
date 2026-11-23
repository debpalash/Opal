//! Bound the mobile page to the screen even when its content has a tall minimum.
const std = @import("std");
pub const Insets = struct { top: f32 = 0, bottom: f32 = 0, left: f32 = 0, right: f32 = 0 };
pub const Viewport = struct { width: f32, height: f32, content_width: f32, content_height: f32, insets: Insets };
pub fn fit(width: f32, height: f32, requested: Insets) Viewport {
    const w = if (std.math.isFinite(width)) @max(1, width) else 1;
    const h = if (std.math.isFinite(height)) @max(1, height) else 1;
    const top = std.math.clamp(requested.top, 0, h - 1);
    const bottom = std.math.clamp(requested.bottom, 0, h - top - 1);
    const left = std.math.clamp(requested.left, 0, w - 1);
    const right = std.math.clamp(requested.right, 0, w - left - 1);
    return .{ .width = w, .height = h, .content_width = w - left - right, .content_height = h - top - bottom, .insets = .{ .top = top, .bottom = bottom, .left = left, .right = right } };
}
/// Edge-to-edge shell: the status bar is hidden and the home indicator
/// auto-hides, so only the hardware cutout (Dynamic Island / notch) and the
/// on-screen keyboard keep content off an edge. iOS reports the cutout edge as
/// its safe inset; the cutout itself ends ~cutout_slack pt before that.
pub const cutout_slack: f32 = 12;
pub fn immersive(safe: Insets, keyboard: f32) Insets {
    return .{
        .top = edge(safe.top),
        .bottom = @max(0, keyboard),
        .left = edge(safe.left),
        .right = edge(safe.right),
    };
}
fn edge(inset: f32) f32 {
    // Small insets are system bars (hidden), not a cutout.
    return if (inset > 24) inset - cutout_slack else 0;
}
/// Top offset that centres a control of `height` on the Dynamic Island /
/// notch, which spans ~11pt down to ~2pt above the band's bottom. No band:
/// a small edge margin.
pub fn bandOffset(band: f32, height: f32) f32 {
    if (band <= 0) return 8;
    const island_center = (11 + band - 2) / 2;
    return @max(0, @min(band - height, island_center - height / 2));
}
/// Player route on mobile: the video layer is edge to edge, ignoring the
/// cutout/status-bar insets that every other route honours. Only chrome
/// controls (back button, transport bar) stay inside `chromeInsets`.
pub fn playerVideoInsets(is_player: bool, requested: Insets) Insets {
    return if (is_player) .{} else requested;
}
pub fn playerChromeInsets(requested: Insets) Insets {
    return requested;
}
/// Compact one-row mobile transport bar: content height == minimum touch target.
/// Apple HIG wants >= 44pt, Material >= 48dp; 44 keeps the bar compact.
pub const MIN_TOUCH: f32 = 44;
pub const BAR_HEIGHT: f32 = MIN_TOUCH;
/// Icon content + padding of a bar button; always reaches MIN_TOUCH.
pub const BAR_ICON: f32 = 20;
pub const BAR_ICON_PAD: f32 = (MIN_TOUCH - BAR_ICON) / 2;
/// Seek thumb: a solid accent dot (not dvui's hollow ring), centred on the track.
pub const THUMB_DIA: f32 = 16;
/// Idle time before player chrome (transport bar AND Back button) starts to
/// fade, and the fade length.
pub const CHROME_HIDE_MS: i64 = 2500;
pub const CHROME_FADE_MS: i64 = 220;
/// Chrome opacity 0..1: held (paused / popover open) or fresh activity = 1,
/// then a linear fade, then 0. Zero exactly when `chromeVisible` is false.
pub fn chromeOpacity(idle_ms: i64, held: bool, threshold_ms: i64, fade_ms: i64) f32 {
    if (held or idle_ms <= threshold_ms) return 1.0;
    if (!chromeVisible(idle_ms, threshold_ms, fade_ms)) return 0.0;
    const t = @as(f32, @floatFromInt(idle_ms - threshold_ms)) / @as(f32, @floatFromInt(@max(1, fade_ms)));
    return std.math.clamp(1.0 - t, 0.0, 1.0);
}
/// Seek position 0..1 for a touch at `x` over a track starting at `track_x`.
pub fn seekFraction(x: f32, track_x: f32, track_w: f32) f32 {
    if (!(track_w > 0) or !std.math.isFinite(x)) return 0;
    return std.math.clamp((x - track_x) / track_w, 0, 1);
}
/// Thumb centre x: the dot stays fully inside the track ends.
pub fn thumbCenterX(track_x: f32, track_w: f32, frac: f32, dia: f32) f32 {
    const f = if (std.math.isFinite(frac)) std.math.clamp(frac, 0, 1) else 0;
    const inner = @max(0, track_w - dia);
    return track_x + dia / 2 + inner * f;
}
pub const FrameRect = struct { x: f32, y: f32, w: f32, h: f32 };
/// Video frame of `dw` x `dh` centred in a `vw` x `vh` pane (symmetric
/// letterbox / pillarbox; never larger than the pane).
pub fn centeredFrame(vw: f32, vh: f32, dw: f32, dh: f32) FrameRect {
    if (!(vw > 0 and vh > 0 and dw > 0 and dh > 0) or !std.math.isFinite(vw + vh + dw + dh)) return .{ .x = 0, .y = 0, .w = @max(0, vw), .h = @max(0, vh) };
    const k = @min(1.0, @min(vw / dw, vh / dh));
    const w = dw * k;
    const h = dh * k;
    return .{ .x = (vw - w) / 2, .y = (vh - h) / 2, .w = w, .h = h };
}
/// Top (y) of a box of `h` centred on `center_y` (icon buttons, time labels,
/// track and thumb all share one centre line).
pub fn centeredTop(center_y: f32, h: f32) f32 {
    return center_y - h / 2;
}
/// Chrome fully hidden once idle passes threshold + fade.
pub fn chromeVisible(idle_ms: i64, threshold_ms: i64, fade_ms: i64) bool {
    return idle_ms < threshold_ms + fade_ms;
}
/// New "last activity" timestamp after a tap on the player. A tap on the video
/// toggles chrome (visible -> hide at once, hidden -> show); a tap on chrome
/// just keeps it alive.
pub fn tapActivity(now_ms: i64, last_ms: i64, in_chrome: bool, threshold_ms: i64, fade_ms: i64) i64 {
    if (!chromeVisible(now_ms - last_ms, threshold_ms, fade_ms)) return now_ms;
    if (in_chrome) return now_ms;
    return now_ms - threshold_ms - fade_ms;
}
test "player video is edge to edge while chrome keeps the safe insets" {
    const safe: Insets = .{ .top = 14, .right = 35 };
    const v = playerVideoInsets(true, safe);
    try std.testing.expectEqual(@as(f32, 0), v.top);
    try std.testing.expectEqual(@as(f32, 0), v.right);
    try std.testing.expectEqual(@as(f32, 35), playerChromeInsets(safe).right);
    try std.testing.expectEqual(@as(f32, 35), playerVideoInsets(false, safe).right);
}
test "mobile bar buttons meet the touch target" {
    try std.testing.expect(BAR_ICON + 2 * BAR_ICON_PAD >= MIN_TOUCH);
    try std.testing.expect(BAR_HEIGHT >= MIN_TOUCH);
}
test "tap on video toggles chrome, tap on chrome keeps it" {
    const t: i64 = 2500;
    const f: i64 = 220;
    // visible, tap video -> hidden
    const hid = tapActivity(10_000, 9_000, false, t, f);
    try std.testing.expect(!chromeVisible(10_000 - hid, t, f));
    // hidden, tap anywhere -> shown
    const shown = tapActivity(20_000, 10_000, false, t, f);
    try std.testing.expect(chromeVisible(20_000 - shown, t, f));
    // visible, tap chrome -> stays visible
    const kept = tapActivity(10_000, 9_000, true, t, f);
    try std.testing.expect(chromeVisible(10_000 - kept, t, f));
}
test "band controls centre on the island and fit inside the band" {
    const off = bandOffset(50, 32);
    try std.testing.expect(off >= 0 and off + 32 <= 50);
    try std.testing.expectApproxEqAbs(@as(f32, 29.5), off + 16, 1.0);
    try std.testing.expectEqual(@as(f32, 8), bandOffset(0, 32));
}
test "immersive shell reaches every edge except the cutout and keyboard" {
    const portrait = immersive(.{ .top = 62, .bottom = 34 }, 0);
    try std.testing.expectEqual(@as(f32, 50), portrait.top);
    try std.testing.expectEqual(@as(f32, 0), portrait.bottom);
    const typing = immersive(.{ .top = 62, .bottom = 34 }, 336);
    try std.testing.expectEqual(@as(f32, 336), typing.bottom);
    const landscape = immersive(.{ .left = 62, .right = 62, .bottom = 21 }, 0);
    try std.testing.expectEqual(@as(f32, 50), landscape.left);
    try std.testing.expectEqual(@as(f32, 0), landscape.bottom);
    const home_button = immersive(.{ .top = 20 }, 0);
    try std.testing.expectEqual(@as(f32, 0), home_button.top);
}
test "portrait landscape and keyboard layouts fit the full mobile display" {
    const portrait = fit(402, 874, .{ .top = 62, .bottom = 34 });
    try std.testing.expectEqual(@as(f32, 778), portrait.content_height);
    const keyboard = fit(402, 874, .{ .top = 62, .bottom = 320 });
    try std.testing.expectEqual(@as(f32, 492), keyboard.content_height);
    const landscape = fit(874, 402, .{ .left = 62, .right = 62, .bottom = 21 });
    try std.testing.expectEqual(@as(f32, 750), landscape.content_width);
    try std.testing.expectEqual(@as(f32, 381), landscape.content_height);
    const invalid = fit(0, 0, .{ .top = 1000, .bottom = 1000 });
    try std.testing.expect(invalid.content_width > 0 and invalid.content_height > 0);
}

test "bar controls and seek hit area meet 44pt (HIG)" {
    try std.testing.expect(MIN_TOUCH >= 44);
    try std.testing.expect(BAR_HEIGHT >= 44);
    try std.testing.expect(THUMB_DIA < BAR_HEIGHT and THUMB_DIA >= 12);
}
test "regression: Back button hides with the transport bar" {
    const t = CHROME_HIDE_MS;
    const f = CHROME_FADE_MS;
    try std.testing.expectEqual(@as(f32, 1), chromeOpacity(0, false, t, f));
    try std.testing.expectEqual(@as(f32, 1), chromeOpacity(t, false, t, f));
    const mid = chromeOpacity(t + f / 2, false, t, f);
    try std.testing.expect(mid > 0 and mid < 1);
    try std.testing.expectEqual(@as(f32, 0), chromeOpacity(t + f, false, t, f));
    try std.testing.expectEqual(@as(f32, 0), chromeOpacity(60_000, false, t, f));
    // held (paused / popover): never hides
    try std.testing.expectEqual(@as(f32, 1), chromeOpacity(60_000, true, t, f));
    // opacity is 0 exactly when chromeVisible is false
    var i: i64 = 0;
    while (i < 6000) : (i += 37) try std.testing.expectEqual(chromeVisible(i, t, f), chromeOpacity(i, false, t, f) > 0);
}
test "seek thumb stays on the track and maps touches" {
    try std.testing.expectEqual(@as(f32, 0), seekFraction(10, 50, 200));
    try std.testing.expectEqual(@as(f32, 1), seekFraction(999, 50, 200));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), seekFraction(150, 50, 200), 1e-6);
    try std.testing.expectEqual(@as(f32, 0), seekFraction(5, 0, 0));
    try std.testing.expectEqual(@as(f32, 58), thumbCenterX(50, 200, 0, 16));
    try std.testing.expectEqual(@as(f32, 242), thumbCenterX(50, 200, 1, 16));
    try std.testing.expectEqual(@as(f32, 150), thumbCenterX(50, 200, 0.5, 16));
}
test "regression: icons, labels and track share one centre line" {
    // Bar icon button (44 box) and the 44 scrub row centre on the same y.
    const c: f32 = 100;
    try std.testing.expectEqual(centeredTop(c, BAR_HEIGHT) + BAR_HEIGHT / 2, c);
    try std.testing.expectEqual(centeredTop(c, THUMB_DIA) + THUMB_DIA / 2, c);
}

test "regression: ultra-wide video letterboxes symmetrically, never offset or cropped" {
    // 2.55:1 frame in a 874x402 landscape pane: bars equal top and bottom.
    const r = centeredFrame(874, 402, 874, 342.7);
    try std.testing.expectApproxEqAbs(r.y, 402 - (r.y + r.h), 1e-3);
    try std.testing.expect(r.y > 0 and r.y + r.h <= 402);
    // oversized request (balanced/cover) is clamped into the pane
    const o = centeredFrame(874, 402, 993, 457);
    try std.testing.expect(o.x >= 0 and o.y >= 0 and o.x + o.w <= 874.01 and o.y + o.h <= 402.01);
    try std.testing.expectApproxEqAbs(o.y, 402 - (o.y + o.h), 1e-3);
    // degenerate input falls back to the pane
    try std.testing.expectEqual(@as(f32, 874), centeredFrame(874, 402, 0, 0).w);
}
