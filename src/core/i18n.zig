//! Runtime UI locale. `t(.key)` is one atomic load plus one array index into
//! the compile-time resolved table: no allocation, safe to call every frame
//! from any thread. Tables, fallback and negotiation live in `i18n_pure.zig`.
const std = @import("std");
const builtin = @import("builtin");
const pure = @import("i18n_pure.zig");
const io = @import("io_global.zig");

pub const Key = pure.Key;
pub const locales = pure.locales;

const tags = pure.shippingTags();

/// Index into `pure.locales`. Written by the UI thread, read anywhere.
var current = std.atomic.Value(u8).init(0);
/// Explicit choice from config ("" = follow the system). UI thread only.
var pref_buf: [16]u8 = @splat(0);
var pref_len: usize = 0;

pub fn t(key: Key) []const u8 {
    return pure.resolved[current.load(.acquire)][@intFromEnum(key)];
}

/// Format a translated template (`{0}`, `{1}`, ...) into `buf`.
pub fn tf(buf: []u8, key: Key, args: []const []const u8) []const u8 {
    return pure.format(buf, t(key), args);
}

/// Pick `one` or `other` by the active locale's plural rule.
pub fn tn(one: Key, other: Key, n: u64) []const u8 {
    return t(if (pure.pluralCategory(currentTag(), n) == .one) one else other);
}

pub fn currentIndex() usize {
    return current.load(.acquire);
}

pub fn currentTag() []const u8 {
    return tags[current.load(.acquire)];
}

/// Persisted preference: "" for system, else a shipping tag.
pub fn preference() []const u8 {
    return pref_buf[0..pref_len];
}

/// Set the preference (from config load or the settings picker) and apply it.
/// Unknown/oversized values fall back to following the system.
pub fn setPreference(raw: []const u8) void {
    var norm_buf: [32]u8 = undefined;
    const tag = pure.normalize(raw, &norm_buf);
    pref_len = 0;
    if (tag.len > 0 and tag.len <= pref_buf.len) {
        @memcpy(pref_buf[0..tag.len], tag);
        pref_len = tag.len;
    }
    apply();
}

/// Re-negotiate from the preference, else LC_ALL / LC_MESSAGES / LANG, else
/// the platform language (macOS/iOS AppleLanguages).
pub fn apply() void {
    const raw = if (pref_len > 0) pref_buf[0..pref_len] else systemLocale();
    current.store(@intCast(pure.negotiate(&tags, raw)), .release);
}

var platform_buf: [32]u8 = undefined;

fn systemLocale() []const u8 {
    var env: [3]?[]const u8 = undefined;
    for ([_][*:0]const u8{ "LC_ALL", "LC_MESSAGES", "LANG" }, 0..) |name, i| env[i] = io.getenv(name);
    return pure.pickSystemLocale(&env, platformLocale());
}

/// First entry of the user's preferred languages ("es-ES"), or "".
fn platformLocale() []const u8 {
    if (comptime !builtin.os.tag.isDarwin()) return "";
    const langs = Cf.CFLocaleCopyPreferredLanguages() orelse return "";
    defer Cf.CFRelease(langs);
    if (Cf.CFArrayGetCount(langs) < 1) return "";
    const first = Cf.CFArrayGetValueAtIndex(langs, 0) orelse return "";
    const utf8: u32 = 0x08000100; // kCFStringEncodingUTF8
    if (Cf.CFStringGetCString(first, &platform_buf, platform_buf.len, utf8) == 0) return "";
    return std.mem.sliceTo(&platform_buf, 0);
}

const Cf = struct {
    const Ref = *const anyopaque;
    extern "CoreFoundation" fn CFLocaleCopyPreferredLanguages() ?Ref;
    extern "CoreFoundation" fn CFArrayGetCount(Ref) isize;
    extern "CoreFoundation" fn CFArrayGetValueAtIndex(Ref, isize) ?Ref;
    extern "CoreFoundation" fn CFStringGetCString(Ref, [*]u8, isize, u32) u8;
    extern "CoreFoundation" fn CFRelease(Ref) void;
};

/// `{"locale":"es","available":[...],"strings":{key:value,...}}` with every
/// key resolved through the fallback chain. `want` is a tag or an
/// Accept-Language value; empty means the host's active locale.
pub fn writeJson(w: *std.Io.Writer, want: []const u8) !void {
    const idx = if (want.len > 0) pure.negotiate(&tags, want) else currentIndex();
    try w.writeAll("{\"locale\":");
    try std.json.Stringify.value(tags[idx], .{}, w);
    try w.writeAll(",\"available\":[");
    for (pure.locales, 0..) |l, i| {
        if (i > 0) try w.writeByte(',');
        try std.json.Stringify.value(.{ .tag = l.tag, .name = l.name }, .{}, w);
    }
    try w.writeAll("],\"strings\":{");
    inline for (@typeInfo(Key).@"enum".field_names, 0..) |name, i| {
        if (i > 0) try w.writeByte(',');
        try std.json.Stringify.value(name, .{}, w);
        try w.writeByte(':');
        try std.json.Stringify.value(pure.resolved[idx][i], .{}, w);
    }
    try w.writeAll("}}");
}
