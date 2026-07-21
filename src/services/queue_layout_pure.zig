//! Play-queue row layout math — pure, so the width budget that keeps the action
//! buttons on screen is unit-testable.
//!
//! WHY THIS EXISTS
//! ---------------
//! dvui's horizontal BoxWidget does NOT squeeze children to fit. `rectFor` hands
//! each child `placeIn(available, min_size, ...)` using its FULL min size and
//! then does `child_rect.w = @max(0, child_rect.w - r.w)` — so once the running
//! budget hits zero, every LATER child gets a zero-width rect and is clipped
//! away. A queue row is laid out [thumb][title/meta][actions], and the title box
//! held uncapped labels whose min width is the full rendered text width. Long
//! titles therefore consumed the entire row and the move/play/remove buttons
//! were handed 0px — invisible, which is the bug this module fixes.
//!
//! The cure is to bound the text column instead of trusting it to behave:
//! `Options.max_size_content.w` clamps a widget's REPORTED min size (see
//! WidgetData.zig — `min_size.min(options.max_sizeGet())`), and LabelWidget
//! ellipsizes to that width by default. So a capped title can never widen the
//! row past the point where the actions strip is starved.
//!
//! Everything here is width arithmetic with no dvui types, so the budget that
//! ships is the budget the tests exercise.

const std = @import("std");

/// Below this the title column is unreadable; we would rather let the row
/// overflow slightly than ellipsize a title down to "...".
pub const MIN_TITLE_W: f32 = 60;

/// Fallback row width for the first frame, before dvui has a real content rect
/// to report (contentRect().w is 0 until a widget has been laid out once).
/// Picked to be narrow enough that the first frame under-fills rather than
/// over-fills — an under-filled row corrects itself on frame two, an over-filled
/// one has already clipped the buttons.
pub const FALLBACK_ROW_W: f32 = 320;

/// Width one dvui `buttonIcon` occupies: the icon box (font textHeight, since
/// buttonIcon sizes its icon to the font), plus ButtonWidget's default 4px
/// padding and 4px margin on each side.
///
/// Derived from the LIVE font height rather than a magic constant so the strip
/// still fits at 1.5x/2x UI scale — the same reasoning as youtube.zig's
/// `cardFooterH()`. A hardcoded width silently under-reserves the moment the
/// user raises the font size, which is exactly how the old `min_size_content =
/// .{ .w = 78 }` (too small for its own four buttons even at 1x) went wrong.
pub fn iconButtonW(font_height: f32) f32 {
    return font_height + 2 * 4 + 2 * 4;
}

/// Total width to reserve for a strip of `n` icon buttons.
pub fn actionsW(font_height: f32, n: usize) f32 {
    return iconButtonW(font_height) * @as(f32, @floatFromInt(n));
}

/// Width budget for the title/meta column of a queue row.
///
/// `row_w` is the row's content width, `leading_w` the thumbnail or source glyph
/// ahead of the text (including its trailing gap), `actions_w` the reserved
/// button strip, `chrome_w` the row's own horizontal padding plus inter-column
/// gaps. Clamped to `MIN_TITLE_W` so a pathologically narrow panel degrades to a
/// cramped title rather than a negative (and therefore ignored) cap.
///
/// A `row_w` of 0 means dvui has not laid the row out yet — use the fallback so
/// the first frame still caps the labels instead of letting them run free.
pub fn titleCapW(row_w: f32, leading_w: f32, actions_w: f32, chrome_w: f32) f32 {
    const avail = if (row_w > 0) row_w else FALLBACK_ROW_W;
    return @max(MIN_TITLE_W, avail - leading_w - actions_w - chrome_w);
}

test "title cap leaves room for the actions strip" {
    // 400px row, 86px thumb column, 4 buttons at 11px font, 12px chrome.
    // One button = 11 (icon) + 4+4 (padding) + 4+4 (margin) = 27px.
    const acts = actionsW(11, 4);
    try std.testing.expectEqual(@as(f32, 27 * 4), acts);
    const cap = titleCapW(400, 86, acts, 12);
    try std.testing.expectEqual(@as(f32, 400 - 86 - 108 - 12), cap);
    // The whole row must still fit: title + thumb + actions + chrome <= row.
    try std.testing.expect(cap + 86 + acts + 12 <= 400);
}

test "narrow row clamps to MIN_TITLE_W rather than going negative" {
    const acts = actionsW(11, 4);
    // 120px row cannot fit an 86px thumb, 76px of buttons and a title.
    const cap = titleCapW(120, 86, acts, 12);
    try std.testing.expectEqual(MIN_TITLE_W, cap);
    // Regression guard: a negative cap is worse than no cap at all, because
    // dvui treats it as "no constraint" and the buttons vanish again.
    try std.testing.expect(cap > 0);
}

test "zero row width falls back instead of collapsing the title" {
    const acts = actionsW(11, 4);
    const cap = titleCapW(0, 86, acts, 12);
    try std.testing.expectEqual(titleCapW(FALLBACK_ROW_W, 86, acts, 12), cap);
    try std.testing.expect(cap > MIN_TITLE_W);
}

test "actions strip scales with font size" {
    // The bug: a constant reservation does not grow with the UI scale, so the
    // strip is starved the moment the user raises the font size.
    const at_11 = actionsW(11, 4);
    const at_22 = actionsW(22, 4);
    try std.testing.expect(at_22 > at_11);
    try std.testing.expectEqual(at_11 + 4 * 11, at_22);
}

test "actions strip is wide enough for its own buttons" {
    // The replaced constant was 78px for four buttons; at the theme's 11px body
    // font four buttons genuinely need 76px, and more at any larger size — so
    // 78 was already borderline at 1x and wrong everywhere above it.
    try std.testing.expect(actionsW(11, 4) >= 76);
    try std.testing.expect(actionsW(15, 4) > 78);
}

test "more buttons reserve proportionally more width" {
    try std.testing.expectEqual(actionsW(11, 2) * 2, actionsW(11, 4));
    try std.testing.expectEqual(@as(f32, 0), actionsW(11, 0));
}

test "wider leading column shrinks the title, never the actions" {
    const acts = actionsW(11, 4);
    const with_thumb = titleCapW(500, 86, acts, 12);
    const with_glyph = titleCapW(500, 26, acts, 12);
    try std.testing.expect(with_glyph > with_thumb);
    // Both still reserve the full strip.
    try std.testing.expect(with_thumb + 86 + acts + 12 <= 500);
    try std.testing.expect(with_glyph + 26 + acts + 12 <= 500);
}
