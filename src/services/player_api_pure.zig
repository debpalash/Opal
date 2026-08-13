//! Pure validation for the web player's action interface.
//!
//! The browser never sends raw mpv commands. It selects one operation from
//! this allowlist and supplies, at most, one bounded value. `remote.zig` maps
//! the resulting Action to direct mpv property calls or fixed command strings.
//! Keeping parsing here makes the security seam unit-testable without mpv,
//! dvui, global state, or IO.

const std = @import("std");

pub const ParseError = error{
    UnknownAction,
    MissingValue,
    InvalidValue,
    OutOfRange,
};

pub const Aspect = enum {
    auto,
    wide,
    classic,
    cinema,

    pub fn mpvValue(self: Aspect) [:0]const u8 {
        return switch (self) {
            .auto => "-1",
            .wide => "16:9",
            .classic => "4:3",
            .cinema => "21:9",
        };
    }
};

pub const Track = union(enum) {
    off,
    id: i64,
};

pub const Repeat = enum { off, all, one };

pub const Action = union(enum) {
    seek_seconds: f64,
    speed: f64,
    chapter: usize,
    audio_track: Track,
    subtitle_track: Track,
    aspect: Aspect,
    subtitle_delay: f64,
    zoom: f64,
    pan_x: f64,
    pan_y: f64,
    brightness: i32,
    contrast: i32,
    saturation: i32,
    gamma: i32,
    picture_preset: u8,
    equalizer_preset: u8,
    audio_device: []const u8,
    shuffle: bool,
    repeat: Repeat,
    playlist_previous,
    playlist_next,
    frame_previous,
    frame_next,
    screenshot,
    loop_a,
    loop_b,
    loop_clear,
    clip_export,
    close_player,
};

fn required(value: ?[]const u8) ParseError![]const u8 {
    const v = value orelse return error.MissingValue;
    if (v.len == 0) return error.MissingValue;
    return v;
}

fn boundedFloat(value: ?[]const u8, min: f64, max: f64) ParseError!f64 {
    const raw = try required(value);
    const parsed = std.fmt.parseFloat(f64, raw) catch return error.InvalidValue;
    if (!std.math.isFinite(parsed)) return error.InvalidValue;
    if (parsed < min or parsed > max) return error.OutOfRange;
    return parsed;
}

fn boundedInt(comptime T: type, value: ?[]const u8, min: T, max: T) ParseError!T {
    const raw = try required(value);
    const parsed = std.fmt.parseInt(T, raw, 10) catch return error.InvalidValue;
    if (parsed < min or parsed > max) return error.OutOfRange;
    return parsed;
}

fn track(value: ?[]const u8) ParseError!Track {
    const raw = try required(value);
    if (std.mem.eql(u8, raw, "off")) return .off;
    return .{ .id = try boundedInt(i64, raw, 0, 99_999) };
}

fn audioDevice(value: ?[]const u8) ParseError![]const u8 {
    const raw = try required(value);
    if (raw.len > 128 or !std.unicode.utf8ValidateSlice(raw)) return error.InvalidValue;
    for (raw) |ch| if (ch < 0x20 or ch == 0x7f) return error.InvalidValue;
    return raw;
}

fn boolean(value: ?[]const u8) ParseError!bool {
    const raw = try required(value);
    if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "1")) return true;
    if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "0")) return false;
    return error.InvalidValue;
}

/// Parse the public action name and its already-percent-decoded value.
///
/// The limits are intentionally tighter than mpv's theoretical extremes: they
/// cover useful media controls while preventing infinities, huge seeks, and
/// command-shaped strings from crossing the HTTP seam.
pub fn parse(name: []const u8, value: ?[]const u8) ParseError!Action {
    if (std.mem.eql(u8, name, "seek")) return .{ .seek_seconds = try boundedFloat(value, 0, 2_592_000) }; // 30 days
    if (std.mem.eql(u8, name, "speed")) return .{ .speed = try boundedFloat(value, 0.25, 4) };
    if (std.mem.eql(u8, name, "chapter")) return .{ .chapter = try boundedInt(usize, value, 0, 9_999) };
    if (std.mem.eql(u8, name, "audio-track")) return .{ .audio_track = try track(value) };
    if (std.mem.eql(u8, name, "subtitle-track")) return .{ .subtitle_track = try track(value) };
    if (std.mem.eql(u8, name, "aspect")) {
        const raw = try required(value);
        const a: Aspect = if (std.mem.eql(u8, raw, "auto")) .auto else if (std.mem.eql(u8, raw, "16:9")) .wide else if (std.mem.eql(u8, raw, "4:3")) .classic else if (std.mem.eql(u8, raw, "21:9")) .cinema else return error.InvalidValue;
        return .{ .aspect = a };
    }
    if (std.mem.eql(u8, name, "subtitle-delay")) return .{ .subtitle_delay = try boundedFloat(value, -30, 30) };
    if (std.mem.eql(u8, name, "zoom")) return .{ .zoom = try boundedFloat(value, -2, 2) };
    if (std.mem.eql(u8, name, "pan-x")) return .{ .pan_x = try boundedFloat(value, -1, 1) };
    if (std.mem.eql(u8, name, "pan-y")) return .{ .pan_y = try boundedFloat(value, -1, 1) };
    if (std.mem.eql(u8, name, "brightness")) return .{ .brightness = try boundedInt(i32, value, -100, 100) };
    if (std.mem.eql(u8, name, "contrast")) return .{ .contrast = try boundedInt(i32, value, -100, 100) };
    if (std.mem.eql(u8, name, "saturation")) return .{ .saturation = try boundedInt(i32, value, -100, 100) };
    if (std.mem.eql(u8, name, "gamma")) return .{ .gamma = try boundedInt(i32, value, -100, 100) };
    if (std.mem.eql(u8, name, "picture-preset")) return .{ .picture_preset = try boundedInt(u8, value, 0, 5) };
    if (std.mem.eql(u8, name, "equalizer-preset")) return .{ .equalizer_preset = try boundedInt(u8, value, 0, 4) };
    if (std.mem.eql(u8, name, "audio-device")) return .{ .audio_device = try audioDevice(value) };
    if (std.mem.eql(u8, name, "shuffle")) return .{ .shuffle = try boolean(value) };
    if (std.mem.eql(u8, name, "repeat")) {
        const raw = try required(value);
        return .{ .repeat = std.meta.stringToEnum(Repeat, raw) orelse return error.InvalidValue };
    }
    if (std.mem.eql(u8, name, "playlist-previous")) return .playlist_previous;
    if (std.mem.eql(u8, name, "playlist-next")) return .playlist_next;
    if (std.mem.eql(u8, name, "frame-previous")) return .frame_previous;
    if (std.mem.eql(u8, name, "frame-next")) return .frame_next;
    if (std.mem.eql(u8, name, "screenshot")) return .screenshot;
    if (std.mem.eql(u8, name, "loop-a")) return .loop_a;
    if (std.mem.eql(u8, name, "loop-b")) return .loop_b;
    if (std.mem.eql(u8, name, "loop-clear")) return .loop_clear;
    if (std.mem.eql(u8, name, "clip-export")) return .clip_export;
    if (std.mem.eql(u8, name, "close")) return .close_player;
    return error.UnknownAction;
}

test "numeric player actions are bounded and finite" {
    try std.testing.expectEqual(@as(f64, 1.5), (try parse("speed", "1.5")).speed);
    try std.testing.expectEqual(@as(f64, 90), (try parse("seek", "90")).seek_seconds);
    try std.testing.expectEqual(@as(usize, 12), (try parse("chapter", "12")).chapter);
    try std.testing.expectError(error.OutOfRange, parse("speed", "4.1"));
    try std.testing.expectError(error.OutOfRange, parse("seek", "-1"));
    try std.testing.expectError(error.InvalidValue, parse("speed", "nan"));
    try std.testing.expectError(error.InvalidValue, parse("speed", "1;quit"));
}

test "only explicit tracks, aspects, presets and devices cross the seam" {
    try std.testing.expectEqual(Track.off, (try parse("subtitle-track", "off")).subtitle_track);
    try std.testing.expectEqual(Track{ .id = 7 }, (try parse("audio-track", "7")).audio_track);
    try std.testing.expectEqual(Aspect.wide, (try parse("aspect", "16:9")).aspect);
    try std.testing.expectEqual(@as(u8, 5), (try parse("picture-preset", "5")).picture_preset);
    try std.testing.expectEqualStrings("coreaudio/default", (try parse("audio-device", "coreaudio/default")).audio_device);
    try std.testing.expect((try parse("shuffle", "true")).shuffle);
    try std.testing.expectEqual(Repeat.one, (try parse("repeat", "one")).repeat);
    try std.testing.expectError(error.InvalidValue, parse("aspect", "16:9;quit"));
    try std.testing.expectError(error.InvalidValue, parse("audio-device", "device\nquit"));
    try std.testing.expectError(error.OutOfRange, parse("equalizer-preset", "5"));
    try std.testing.expectError(error.InvalidValue, parse("shuffle", "toggle"));
    try std.testing.expectError(error.InvalidValue, parse("repeat", "forever"));
}

test "fixed actions need no caller-controlled command text" {
    try std.testing.expectEqual(Action.playlist_next, try parse("playlist-next", null));
    try std.testing.expectEqual(Action.screenshot, try parse("screenshot", null));
    try std.testing.expectEqual(Action.loop_clear, try parse("loop-clear", null));
    try std.testing.expectError(error.UnknownAction, parse("quit", null));
    try std.testing.expectError(error.MissingValue, parse("speed", null));
}
