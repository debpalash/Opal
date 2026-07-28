//! Pure logic for the player control bar (`footer.zig` v2).
//!
//! Everything the control bar decides that is NOT a dvui draw call lives here:
//! clock formatting, scrub-band geometry (click/drag/hover → fraction, and
//! fraction → gravity), torrent buffered-range analysis, the seek throttle, the
//! volume glyph ramp, the transport state machine, and the responsive collapse
//! order for a narrow bar.
//!
//! `footer.zig` routes the shipped code through these functions — the tested
//! logic IS the shipped logic. The module is deliberately dvui-free so
//! `zig build test` can run it without a live frame (see build.zig).

const std = @import("std");

// ══════════════════════════════════════════════════════════════════
// Clock formatting
// ══════════════════════════════════════════════════════════════════

/// Shown instead of a misleading "0:00" when the duration is unknown — a live
/// stream, or a file whose duration mpv has not probed yet.
pub const UNKNOWN = "--:--";

/// `M:SS` under an hour, `H:MM:SS` at or above it. Minutes are NOT zero-padded
/// in the short form (`0:42`, `9:05`, `12:34`) which is the convention every
/// mainstream player uses; hours-form pads minutes so the columns line up
/// (`1:02:03`).
pub fn formatTime(buf: []u8, secs: u32) []const u8 {
    const h = secs / 3600;
    const m = (secs % 3600) / 60;
    const s = secs % 60;
    const res = if (h > 0)
        std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ h, m, s })
    else
        std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ m, s });
    return res catch buf[0..0];
}

/// The right-hand readout: total duration, or time remaining as `-M:SS` when
/// the user has toggled it. An unknown duration reads `UNKNOWN` in both modes —
/// "remaining" is meaningless without a total.
pub fn formatTrailing(buf: []u8, elapsed: u32, duration: u32, show_remaining: bool) []const u8 {
    if (duration == 0) return UNKNOWN;
    if (!show_remaining) return formatTime(buf, duration);
    if (buf.len < 2) return UNKNOWN;
    const rem = if (duration > elapsed) duration - elapsed else 0;
    buf[0] = '-';
    const inner = formatTime(buf[1..], rem);
    return buf[0 .. 1 + inner.len];
}

/// Widest character count a clock for `duration_secs` can print. Used to
/// reserve label width so the seek band does not jump sideways when the
/// elapsed time rolls 9:59 → 10:00 (or 59:59 → 1:00:00).
pub fn timeLabelChars(duration_secs: u32, signed: bool) usize {
    const h = duration_secs / 3600;
    const m = (duration_secs % 3600) / 60;
    var n: usize = if (h > 0)
        // H:MM:SS, plus a column per extra hours digit.
        6 + digits(h)
    else if (m >= 10)
        5 // MM:SS
    else
        4; // M:SS
    if (signed) n += 1;
    return n;
}

fn digits(v: u32) usize {
    var n: usize = 1;
    var x = v;
    while (x >= 10) : (x /= 10) n += 1;
    return n;
}

/// Approximate advance width of one digit in the small UI font. The clock is
/// not monospaced, so this is a reservation, not a measurement.
pub const TIME_CHAR_W: f32 = 6.0;

/// Reserved pixel width for a clock label (a little slack on top of the glyph
/// estimate so the text never clips its own box).
pub fn timeLabelWidth(duration_secs: u32, signed: bool) f32 {
    return @as(f32, @floatFromInt(timeLabelChars(duration_secs, signed))) * TIME_CHAR_W + 6.0;
}

/// Width of the hover-preview chip (clock text + its horizontal padding).
pub fn hoverChipWidth(duration_secs: u32) f32 {
    return timeLabelWidth(duration_secs, false) + 8.0;
}

// ══════════════════════════════════════════════════════════════════
// Scrub-band geometry
// ══════════════════════════════════════════════════════════════════

/// Clamp any float (including NaN) into a 0..1 fraction.
pub fn clampFrac(v: f64) f32 {
    if (std.math.isNan(v)) return 0.0;
    return @floatCast(@max(0.0, @min(1.0, v)));
}

/// mpv `percent-pos` (0..100, may be NaN before the first frame) → 0..1.
pub fn percentToFrac(percent: f64) f32 {
    return clampFrac(percent / 100.0);
}

/// Pointer x → track fraction. Clamps at both edges, so a click one pixel past
/// the end of the band seeks to the end rather than to a stale value, and a
/// drag that runs off the window edge pins instead of jittering.
pub fn fractionAt(x: f32, track_x: f32, track_w: f32) f32 {
    if (!(track_w > 0)) return 0.0;
    const f = (x - track_x) / track_w;
    if (std.math.isNan(f)) return 0.0;
    return @max(0.0, @min(1.0, f));
}

/// dvui gravity_x that centers a `label_w`-wide chip on `cursor_x` inside a
/// track, clamped so the chip never pokes out of either end of the track.
pub fn centeredGravityX(cursor_x: f32, track_x: f32, track_w: f32, label_w: f32) f32 {
    const room = track_w - label_w;
    if (!(room > 0)) return 0.0;
    const left = cursor_x - track_x - label_w * 0.5;
    return @max(0.0, @min(1.0, left / room));
}

// ══════════════════════════════════════════════════════════════════
// Torrent buffered ranges
// ══════════════════════════════════════════════════════════════════

/// Overall completion of a libtorrent piece map ('1' = have). Empty map → 0.
pub fn pieceMapFraction(map: []const u8) f32 {
    if (map.len == 0) return 0.0;
    var have: usize = 0;
    for (map) |ch| {
        if (ch == '1') have += 1;
    }
    return @as(f32, @floatFromInt(have)) / @as(f32, @floatFromInt(map.len));
}

/// End of the CONTIGUOUS run of downloaded pieces that starts at the playhead,
/// as a 0..1 fraction. This is the number a scrub bar actually wants: total
/// completion says nothing about whether the next thirty seconds will play.
/// Returns `play_frac` unchanged when the piece under the playhead is missing
/// (nothing is buffered ahead — playback is about to stall).
pub fn bufferedAheadEnd(map: []const u8, play_frac: f32) f32 {
    if (map.len == 0) return play_frac;
    const start_f = @max(0.0, @min(1.0, play_frac));
    var i: usize = @intFromFloat(@floor(start_f * @as(f32, @floatFromInt(map.len))));
    if (i >= map.len) i = map.len - 1;
    if (map[i] != '1') return start_f;
    var end = i;
    while (end < map.len and map[end] == '1') : (end += 1) {}
    const frac = @as(f32, @floatFromInt(end)) / @as(f32, @floatFromInt(map.len));
    return @max(start_f, @min(1.0, frac));
}

// ══════════════════════════════════════════════════════════════════
// Seek throttle
// ══════════════════════════════════════════════════════════════════

pub const SEEK_MIN_INTERVAL_MS: i64 = 100;
pub const SEEK_JUMP_PCT: f64 = 2.0;
pub const PRIORITIZE_INTERVAL_MS: i64 = 500;

/// While dragging, mpv gets at most one seek per 100ms — except a jump of more
/// than 2% (a click somewhere else on the band) which always goes through
/// immediately, so a click never feels swallowed.
pub fn shouldSeek(now_ms: i64, last_ms: i64, pct: f64, last_pct: f64) bool {
    return now_ms - last_ms > SEEK_MIN_INTERVAL_MS or @abs(pct - last_pct) > SEEK_JUMP_PCT;
}

/// Re-prioritising torrent pieces is far more expensive than a seek, so it runs
/// at most twice a second.
pub fn shouldPrioritize(now_ms: i64, last_ms: i64) bool {
    return now_ms - last_ms > PRIORITIZE_INTERVAL_MS;
}

// ══════════════════════════════════════════════════════════════════
// Volume
// ══════════════════════════════════════════════════════════════════

pub const VolumeLevel = enum { muted, off, low, high };

/// Which speaker glyph the mute button should wear. `muted` (the mpv `mute`
/// flag) always wins — mute is a separate state from level, and toggling it
/// restores whatever level was set, so the level must stay readable underneath.
pub fn volumeLevel(volume: f64, muted: bool) VolumeLevel {
    if (muted) return .muted;
    if (std.math.isNan(volume) or volume < 0.5) return .off;
    if (volume < 50.0) return .low;
    return .high;
}

/// mpv volume (0..100+) → slider fraction.
pub fn volumeFraction(volume: f64) f32 {
    return clampFrac(volume / 100.0);
}

/// Rounded percent for the hover readout, clamped to the slider's range.
pub fn volumePercent(volume: f64) i32 {
    if (std.math.isNan(volume)) return 0;
    return @intFromFloat(@round(@max(0.0, @min(100.0, volume))));
}

// ══════════════════════════════════════════════════════════════════
// Transport state
// ══════════════════════════════════════════════════════════════════

pub const Transport = enum { loading, paused, buffering, playing };

/// What the bar should SAY it is doing. Order matters: a file still opening is
/// "loading" whatever else is true; an explicit user pause outranks a stalled
/// cache (the cache isn't why it stopped); only then does an empty cache read
/// as "buffering".
pub fn transportState(is_loading: bool, paused: bool, paused_for_cache: bool) Transport {
    if (is_loading) return .loading;
    if (paused) return .paused;
    if (paused_for_cache) return .buffering;
    return .playing;
}

/// Status text for the non-obvious states; empty when playing/paused normally
/// (the play/pause glyph already says it, no need for a redundant label).
pub fn transportLabel(t: Transport) []const u8 {
    return switch (t) {
        .loading => "Loading\u{2026}",
        .buffering => "Buffering\u{2026}",
        else => "",
    };
}

/// True while the bar should show a spinner beside the transport.
pub fn transportBusy(t: Transport) bool {
    return t == .loading or t == .buffering;
}

// ══════════════════════════════════════════════════════════════════
// Responsive collapse
// ══════════════════════════════════════════════════════════════════

/// Which non-essential control-bar groups survive at a given bar width. The
/// bar lives inside a grid CELL, so at 3×3 it can be ~400px wide — the old
/// fixed layout simply overflowed and clipped the close button off the end.
/// Groups are shed widest-first so the essentials (play/pause, clock, mute,
/// subtitles, close) always fit.
pub const BarLayout = struct {
    /// The 120px volume track (the mute button always stays).
    volume_slider: bool,
    /// Aspect, audio-output-device, subtitle-language and universal-language
    /// chips — all reachable from Settings / keyboard as well.
    secondary_chips: bool,
    /// Playlist position / speed / A-B loop text badges.
    status_badges: bool,
    /// The ±10s / rewind button.
    skip_buttons: bool,
};

// Thresholds are MEASURED against the real bar, not guessed: at 1200pt the
// full set fits with slack and the close button sits at the right edge; at
// 700pt with every group enabled the row overflowed and clipped the close
// button off the end — the exact failure this collapse exists to prevent. Each
// constant is the width below which the next group must go, with margin.
pub const BREAK_VOLUME: f32 = 900; // 120pt track + its gap + hover readout
pub const BREAK_CHIPS: f32 = 800; // aspect, audio-device, sub-lang, uni-lang
pub const BREAK_BADGES: f32 = 520; // chapters, find-subtitles, torrent files
pub const BREAK_SKIP: f32 = 320; // playlist/episode skip, rewind, fullscreen

pub fn barLayout(width: f32) BarLayout {
    return .{
        .volume_slider = width >= BREAK_VOLUME,
        .secondary_chips = width >= BREAK_CHIPS,
        .status_badges = width >= BREAK_BADGES,
        .skip_buttons = width >= BREAK_SKIP,
    };
}

// ══════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

test "formatTime: M:SS under an hour, H:MM:SS at or above" {
    var b: [16]u8 = undefined;
    try expectEqualStrings("0:00", formatTime(&b, 0));
    try expectEqualStrings("0:42", formatTime(&b, 42));
    try expectEqualStrings("9:05", formatTime(&b, 9 * 60 + 5));
    try expectEqualStrings("59:59", formatTime(&b, 3599));
    try expectEqualStrings("1:00:00", formatTime(&b, 3600));
    try expectEqualStrings("1:02:03", formatTime(&b, 3723));
    try expectEqualStrings("10:00:00", formatTime(&b, 36000));
}

test "formatTime: never overruns a short buffer" {
    var tiny: [3]u8 = undefined;
    try expectEqualStrings("", formatTime(&tiny, 3723));
}

test "formatTrailing: total, remaining, and unknown duration" {
    var b: [20]u8 = undefined;
    // Unknown duration must not read as a confident 0:00.
    try expectEqualStrings(UNKNOWN, formatTrailing(&b, 10, 0, false));
    try expectEqualStrings(UNKNOWN, formatTrailing(&b, 10, 0, true));
    try expectEqualStrings("1:30", formatTrailing(&b, 42, 90, false));
    try expectEqualStrings("-0:48", formatTrailing(&b, 42, 90, true));
    // Elapsed past the end (mpv can report this at EOF) clamps to -0:00.
    try expectEqualStrings("-0:00", formatTrailing(&b, 200, 90, true));
    try expectEqualStrings("-1:00:00", formatTrailing(&b, 0, 3600, true));
}

test "timeLabelChars: reserves the widest form the clock can reach" {
    try expect(timeLabelChars(42, false) == 4); // 0:42
    try expect(timeLabelChars(600, false) == 5); // 10:00
    try expect(timeLabelChars(3600, false) == 7); // 1:00:00
    try expect(timeLabelChars(36000, false) == 8); // 10:00:00
    try expect(timeLabelChars(600, true) == 6); // -10:00
    try expect(timeLabelWidth(42, false) > 0);
    // A longer file always reserves at least as much room as a shorter one.
    try expect(timeLabelWidth(3600, false) > timeLabelWidth(600, false));
}

test "fractionAt: clamps at both edges and survives a zero-width track" {
    try expectApproxEqAbs(@as(f32, 0.0), fractionAt(100, 100, 200), 0.001);
    try expectApproxEqAbs(@as(f32, 0.5), fractionAt(200, 100, 200), 0.001);
    try expectApproxEqAbs(@as(f32, 1.0), fractionAt(300, 100, 200), 0.001);
    // One pixel past the right edge still means "the end", not 0.
    try expectApproxEqAbs(@as(f32, 1.0), fractionAt(301, 100, 200), 0.001);
    try expectApproxEqAbs(@as(f32, 0.0), fractionAt(-50, 100, 200), 0.001);
    try expectApproxEqAbs(@as(f32, 0.0), fractionAt(150, 100, 0), 0.001);
}

test "clampFrac / percentToFrac: NaN and out-of-range are safe" {
    try expectApproxEqAbs(@as(f32, 0.0), clampFrac(std.math.nan(f64)), 0.001);
    try expectApproxEqAbs(@as(f32, 1.0), clampFrac(4.0), 0.001);
    try expectApproxEqAbs(@as(f32, 0.0), clampFrac(-1.0), 0.001);
    try expectApproxEqAbs(@as(f32, 0.5), percentToFrac(50.0), 0.001);
    try expectApproxEqAbs(@as(f32, 0.0), percentToFrac(std.math.nan(f64)), 0.001);
    try expectApproxEqAbs(@as(f32, 1.0), percentToFrac(150.0), 0.001);
}

test "centeredGravityX: centers on the cursor, clamped inside the track" {
    // Cursor mid-track: chip centered → gravity 0.5.
    try expectApproxEqAbs(@as(f32, 0.5), centeredGravityX(500, 400, 200, 40), 0.001);
    // Cursor at the left edge: chip would hang off, so pin left.
    try expectApproxEqAbs(@as(f32, 0.0), centeredGravityX(400, 400, 200, 40), 0.001);
    // Cursor at the right edge: pin right.
    try expectApproxEqAbs(@as(f32, 1.0), centeredGravityX(600, 400, 200, 40), 0.001);
    // Chip wider than the track: no room, pin left rather than divide by zero.
    try expectApproxEqAbs(@as(f32, 0.0), centeredGravityX(500, 400, 20, 40), 0.001);
}

test "pieceMapFraction: overall completion" {
    try expectApproxEqAbs(@as(f32, 0.0), pieceMapFraction(""), 0.001);
    try expectApproxEqAbs(@as(f32, 1.0), pieceMapFraction("1111"), 0.001);
    try expectApproxEqAbs(@as(f32, 0.5), pieceMapFraction("1010"), 0.001);
    try expectApproxEqAbs(@as(f32, 0.25), pieceMapFraction("1000"), 0.001);
}

test "bufferedAheadEnd: contiguous run from the playhead, not total completion" {
    // Playhead at 0 with the first half downloaded → buffered to 0.5, even
    // though a stray later piece would make total completion higher.
    try expectApproxEqAbs(@as(f32, 0.5), bufferedAheadEnd("11110000", 0.0), 0.001);
    try expectApproxEqAbs(@as(f32, 0.5), bufferedAheadEnd("11110001", 0.0), 0.001);
    // Playhead inside the run: the run's END is what matters, not its length.
    try expectApproxEqAbs(@as(f32, 0.5), bufferedAheadEnd("11110000", 0.25), 0.001);
    // Playhead on a missing piece: nothing is buffered ahead.
    try expectApproxEqAbs(@as(f32, 0.75), bufferedAheadEnd("11110000", 0.75), 0.001);
    // Fully downloaded.
    try expectApproxEqAbs(@as(f32, 1.0), bufferedAheadEnd("1111", 0.0), 0.001);
    // Empty map (non-torrent / not fetched) is a no-op.
    try expectApproxEqAbs(@as(f32, 0.3), bufferedAheadEnd("", 0.3), 0.001);
    // play_frac == 1.0 must not index past the end.
    try expectApproxEqAbs(@as(f32, 1.0), bufferedAheadEnd("1111", 1.0), 0.001);
    try expectApproxEqAbs(@as(f32, 1.0), bufferedAheadEnd("1110", 1.0), 0.001);
}

test "shouldSeek: throttles a drag but never swallows a click jump" {
    // Same spot, 20ms later — throttled.
    try expect(!shouldSeek(1020, 1000, 50.0, 50.0));
    // Same spot, 200ms later — allowed.
    try expect(shouldSeek(1200, 1000, 50.0, 50.0));
    // A 30% jump 1ms later — always allowed.
    try expect(shouldSeek(1001, 1000, 80.0, 50.0));
    // A 1% nudge inside the window — throttled.
    try expect(!shouldSeek(1001, 1000, 51.0, 50.0));
    try expect(shouldPrioritize(1600, 1000));
    try expect(!shouldPrioritize(1400, 1000));
}

test "volumeLevel: mute wins, level ramps" {
    try expect(volumeLevel(100, true) == .muted);
    try expect(volumeLevel(0, true) == .muted);
    try expect(volumeLevel(0, false) == .off);
    try expect(volumeLevel(20, false) == .low);
    try expect(volumeLevel(49.9, false) == .low);
    try expect(volumeLevel(50, false) == .high);
    try expect(volumeLevel(std.math.nan(f64), false) == .off);
    try expectApproxEqAbs(@as(f32, 0.6), volumeFraction(60), 0.001);
    try expectApproxEqAbs(@as(f32, 1.0), volumeFraction(130), 0.001);
    try expect(volumePercent(60.4) == 60);
    try expect(volumePercent(130) == 100);
    try expect(volumePercent(std.math.nan(f64)) == 0);
}

test "transportState: loading > paused > buffering > playing" {
    try expect(transportState(true, true, true) == .loading);
    try expect(transportState(false, true, true) == .paused);
    try expect(transportState(false, false, true) == .buffering);
    try expect(transportState(false, false, false) == .playing);
    try expectEqualStrings("", transportLabel(.playing));
    try expectEqualStrings("", transportLabel(.paused));
    try expect(transportLabel(.buffering).len > 0);
    try expect(transportBusy(.loading) and transportBusy(.buffering));
    try expect(!transportBusy(.playing) and !transportBusy(.paused));
}

test "barLayout: sheds groups widest-first as the bar narrows" {
    const wide = barLayout(1400);
    try expect(wide.volume_slider and wide.secondary_chips and wide.status_badges and wide.skip_buttons);

    // 700pt: the measured width at which the full set overflowed and clipped
    // the close button. Both the volume track and the picker chips must be
    // gone by here — with the chips still on, the row still ran off the end.
    const seven = barLayout(700);
    try expect(!seven.volume_slider and !seven.secondary_chips);
    try expect(seven.status_badges and seven.skip_buttons);

    // Only the volume track goes at first — the chips still fit.
    const eight_fifty = barLayout(850);
    try expect(!eight_fifty.volume_slider);
    try expect(eight_fifty.secondary_chips and eight_fifty.status_badges and eight_fifty.skip_buttons);

    const narrow = barLayout(460);
    try expect(!narrow.volume_slider and !narrow.secondary_chips and !narrow.status_badges);
    try expect(narrow.skip_buttons);

    const tiny = barLayout(300);
    try expect(!tiny.volume_slider and !tiny.secondary_chips and !tiny.status_badges and !tiny.skip_buttons);

    // A grid cell in a 3x3 workspace — the case that motivated the whole
    // collapse. Everything optional is gone; the essentials still render.
    const cell = barLayout(400);
    try expect(!cell.volume_slider and !cell.secondary_chips and !cell.status_badges);
    try expect(cell.skip_buttons);

    // Monotonic: nothing ever comes BACK as the bar gets narrower.
    var w: f32 = 1400;
    var prev = barLayout(w);
    while (w > 100) : (w -= 10) {
        const cur = barLayout(w);
        try expect(!(cur.volume_slider and !prev.volume_slider));
        try expect(!(cur.secondary_chips and !prev.secondary_chips));
        try expect(!(cur.status_badges and !prev.status_badges));
        try expect(!(cur.skip_buttons and !prev.skip_buttons));
        prev = cur;
    }
}

// ══════════════════════════════════════════════════════════════════
// Scrub-band paint geometry
// ══════════════════════════════════════════════════════════════════
//
// The scrubber's five visual layers (base track, buffered fill, played fill,
// chapter pips, hover knob) used to be dvui boxes sized with
// `min_size_content = { .w = track_rect.w * frac }`. A child's min size
// propagates up to the parent's DERIVED min (dvui takes max(specified,
// derived)), so the band's minimum width ratcheted toward the whole row and
// squeezed the trailing duration label to 0px — the total time was invisible
// from the third frame on (measured: dur box w=92.8 on frame 2, w=0.0 on
// frame 3, with the string itself still correct).
//
// The layers are decoration — nothing about them is interactive (the seek is a
// separate transparent slider). So they're painted as plain rects instead, and
// contribute no min size at all. These helpers compute those rects.

pub const BarRect = struct { x: f32, y: f32, w: f32, h: f32 };

/// A horizontal fill bar `thickness` tall, vertically centered in the band,
/// spanning `frac` of the band's width from its left edge. `frac` is clamped
/// to [0,1]; a non-finite band or fraction yields a zero-width bar rather than
/// a NaN rect that would paint garbage.
pub fn fillBar(bx: f32, by: f32, bw: f32, bh: f32, thickness: f32, frac: f32) BarRect {
    if (!finite4(bx, by, bw, bh) or !std.math.isFinite(thickness)) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    const f = clampFrac(frac);
    const t = @max(0.0, @min(thickness, bh));
    return .{
        .x = bx,
        .y = by + (bh - t) * 0.5,
        .w = @max(0.0, bw) * f,
        .h = t,
    };
}

/// A horizontal bar covering the span `start_frac`..`end_frac` of the band.
/// Used for the contiguous buffered-ahead range, which starts at the playhead
/// rather than at the left edge. An inverted or empty span yields a zero-width
/// rect (nothing to paint) instead of a negative-width one.
pub fn fillSegment(bx: f32, by: f32, bw: f32, bh: f32, thickness: f32, start_frac: f32, end_frac: f32) BarRect {
    const whole = fillBar(bx, by, bw, bh, thickness, 1.0);
    if (whole.w <= 0) return whole;
    const s = clampFrac(start_frac);
    const e = clampFrac(end_frac);
    if (e <= s) return .{ .x = whole.x + whole.w * s, .y = whole.y, .w = 0, .h = whole.h };
    return .{
        .x = whole.x + whole.w * s,
        .y = whole.y,
        .w = whole.w * (e - s),
        .h = whole.h,
    };
}

/// A `w`×`h` marker (chapter pip, hover knob) vertically centered in the band
/// and placed so it never overhangs either end — `frac` 0 pins it flush left,
/// 1 flush right. This is dvui's `gravity_x` rule, kept identical so swapping
/// the boxes for direct paints moved nothing on screen.
pub fn markerAt(bx: f32, by: f32, bw: f32, bh: f32, w: f32, h: f32, frac: f32) BarRect {
    if (!finite4(bx, by, bw, bh) or !finite4(w, h, 0, 0)) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    const f = clampFrac(frac);
    const mw = @max(0.0, @min(w, bw));
    const mh = @max(0.0, @min(h, bh));
    return .{
        .x = bx + (@max(0.0, bw) - mw) * f,
        .y = by + (bh - mh) * 0.5,
        .w = mw,
        .h = mh,
    };
}

fn finite4(a: f32, b: f32, c: f32, d: f32) bool {
    return std.math.isFinite(a) and std.math.isFinite(b) and
        std.math.isFinite(c) and std.math.isFinite(d);
}

test "fillBar centers the track and scales with the fraction" {
    const band_x: f32 = 100;
    const band_y: f32 = 50;
    const band_w: f32 = 400;
    const band_h: f32 = 26;

    const full = fillBar(band_x, band_y, band_w, band_h, 4, 1.0);
    try expect(full.x == 100);
    try expect(full.w == 400);
    try expect(full.h == 4);
    try expect(full.y == 50 + (26 - 4) / 2); // vertically centered

    const half = fillBar(band_x, band_y, band_w, band_h, 4, 0.5);
    try expect(half.w == 200);
    try expect(half.x == full.x); // always grows from the left edge
    try expect(half.y == full.y);

    // Hovering thickens the track but keeps it centered.
    const thick = fillBar(band_x, band_y, band_w, band_h, 6, 1.0);
    try expect(thick.h == 6);
    try expect(thick.y == 50 + (26 - 6) / 2);
}

test "fillBar clamps out-of-range fractions and thickness" {
    try expect(fillBar(0, 0, 400, 26, 4, -1).w == 0);
    try expect(fillBar(0, 0, 400, 26, 4, 5).w == 400);
    // Thickness can never exceed the band it sits in.
    try expect(fillBar(0, 0, 400, 26, 999, 1).h == 26);
    try expect(fillBar(0, 0, 400, 26, -3, 1).h == 0);
}

test "fillBar refuses to emit a NaN rect" {
    const nan = std.math.nan(f32);
    const r = fillBar(nan, 0, 400, 26, 4, 0.5);
    try expect(r.w == 0 and r.h == 0);
    const r2 = fillBar(0, 0, 400, 26, 4, nan);
    // clampFrac handles a NaN fraction; the rect must still be finite.
    try expect(std.math.isFinite(r2.w) and std.math.isFinite(r2.x));
}

test "markerAt spans flush-left to flush-right without overhang" {
    const left = markerAt(100, 50, 400, 26, 8, 8, 0.0);
    try expect(left.x == 100);
    const right = markerAt(100, 50, 400, 26, 8, 8, 1.0);
    try expect(right.x == 100 + 400 - 8); // right edge lands exactly on the band edge
    try expect(right.x + right.w == 100 + 400);
    const mid = markerAt(100, 50, 400, 26, 8, 8, 0.5);
    try expect(mid.x == 100 + (400 - 8) / 2);
    // Centered vertically, same as the fills.
    try expect(mid.y == 50 + (26 - 8) / 2);
}

test "markerAt never escapes a band narrower than the marker" {
    const r = markerAt(0, 0, 4, 26, 8, 8, 1.0);
    try expect(r.w == 4);
    try expect(r.x == 0);
    try expect(r.x + r.w <= 4);
}

test "fillSegment spans start..end and never inverts" {
    const seg = fillSegment(100, 50, 400, 26, 4, 0.25, 0.75);
    try expect(seg.x == 100 + 100);
    try expect(seg.w == 200);
    try expect(seg.h == 4);

    // Full span matches a plain full-width bar exactly.
    const full = fillSegment(100, 50, 400, 26, 4, 0.0, 1.0);
    const bar = fillBar(100, 50, 400, 26, 4, 1.0);
    try expect(full.x == bar.x and full.w == bar.w and full.y == bar.y);

    // Nothing buffered ahead: end == start → nothing painted, positioned at the
    // playhead rather than at a negative width.
    const empty = fillSegment(100, 50, 400, 26, 4, 0.6, 0.6);
    try expect(empty.w == 0);
    try expect(empty.x == 100 + 240);

    // Inverted input can never produce a negative-width rect.
    const inverted = fillSegment(100, 50, 400, 26, 4, 0.9, 0.1);
    try expect(inverted.w == 0);
}
