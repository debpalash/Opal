//! Registry + validation for the settings the web UI may read and change
//! (`/api/settings`). Pure: no state, no io_global, so it unit-tests standalone.
//!
//! A registry rather than a chain of `if (eql(key, "…"))` branches: the GET
//! handler, the POST handler and the web page all iterate the SAME list, so a
//! key can never be settable-but-not-shown, or shown-but-not-settable. Adding a
//! setting is one row here.
//!
//! Deliberately does NOT expose everything the desktop has. Anything that only
//! means something on the machine running the app — file associations, GPU
//! decode paths that need a restart, model downloads — stays desktop-only.

const std = @import("std");

pub const Kind = enum { boolean, integer, text };

pub const Key = struct {
    name: []const u8,
    kind: Kind,
    /// Groups the web page renders as sections; mirrors the desktop tabs.
    group: []const u8,
    label: []const u8,
    /// Inclusive bounds for `.integer`. Ignored otherwise.
    min: i32 = 0,
    max: i32 = 0,
    /// Max bytes for `.text`. Ignored otherwise.
    max_len: usize = 0,
};

pub const KEYS = [_]Key{
    // Playback
    .{ .name = "hwdec", .kind = .boolean, .group = "Playback", .label = "Hardware decode" },
    .{ .name = "auto_advance", .kind = .boolean, .group = "Playback", .label = "Auto-advance to next" },
    .{ .name = "seek_sync", .kind = .boolean, .group = "Playback", .label = "Sync playback across screens" },
    .{ .name = "sponsorblock", .kind = .boolean, .group = "Playback", .label = "SponsorBlock" },
    // Subtitles
    .{ .name = "auto_download_subs", .kind = .boolean, .group = "Subtitles", .label = "Auto-download subtitles" },
    .{ .name = "sub_lang", .kind = .text, .group = "Subtitles", .label = "Subtitle language (3-letter)", .max_len = 7 },
    // Network
    .{ .name = "proxy_url", .kind = .text, .group = "Network", .label = "Proxy URL", .max_len = 127 },
    // 0 = unlimited. Upper bound is a sanity rail, not a hardware limit.
    .{ .name = "download_rate_limit", .kind = .integer, .group = "Network", .label = "Download limit (KB/s, 0 = unlimited)", .min = 0, .max = 1_000_000 },
    // Storage
    .{ .name = "save_path", .kind = .text, .group = "Storage", .label = "Download folder", .max_len = 255 },
    // AI & Voice. Speed is an integer PERCENT on the wire (f32 internally):
    // JSON floats round-trip badly through form fields, and a percent is what
    // the label says anyway.
    .{ .name = "tts_voice", .kind = .text, .group = "AI & Voice", .label = "TTS voice", .max_len = 15 },
    .{ .name = "tts_speed", .kind = .integer, .group = "AI & Voice", .label = "TTS speed (%)", .min = 25, .max = 300 },
    // Language learning
    .{ .name = "lang_learn", .kind = .boolean, .group = "Language", .label = "Language learning mode" },
    .{ .name = "translate", .kind = .boolean, .group = "Language", .label = "Live translation" },
    .{ .name = "translate_lang", .kind = .text, .group = "Language", .label = "Translate to (2-letter)", .max_len = 7 },
    .{ .name = "dubbing", .kind = .boolean, .group = "Language", .label = "AI dubbing" },
    // General. The desktop General tab also holds the TMDB and OMDb API keys;
    // those stay out deliberately — values in this registry ride in a query
    // string, and the module header's rule is that nothing secret does.
    .{ .name = "theme", .kind = .text, .group = "General", .label = "Theme preset", .max_len = 15 },
    .{ .name = "ui_scale_auto", .kind = .boolean, .group = "General", .label = "Scale UI to display DPI" },
    // Integer percent on the wire; f32 multiplier internally, same as tts_speed.
    .{ .name = "ui_scale", .kind = .integer, .group = "General", .label = "UI scale (%)", .min = 50, .max = 300 },
    .{ .name = "taste_enabled", .kind = .boolean, .group = "General", .label = "Personalized suggestions" },
    // Privacy
    .{ .name = "nsfw_filter", .kind = .boolean, .group = "Privacy", .label = "NSFW filter" },
    .{ .name = "incognito", .kind = .boolean, .group = "Privacy", .label = "Incognito (no history)" },
};

pub fn find(name: []const u8) ?Key {
    for (KEYS) |k| {
        if (std.mem.eql(u8, k.name, name)) return k;
    }
    return null;
}

/// Accepts the forms a web form and a curl user actually send. Anything else is
/// null rather than a silent `false` — a typo must not quietly disable a
/// setting the user meant to turn on.
pub fn parseBool(s: []const u8) ?bool {
    if (s.len == 0) return null;
    if (std.mem.eql(u8, s, "1") or std.ascii.eqlIgnoreCase(s, "true") or
        std.ascii.eqlIgnoreCase(s, "on") or std.ascii.eqlIgnoreCase(s, "yes")) return true;
    if (std.mem.eql(u8, s, "0") or std.ascii.eqlIgnoreCase(s, "false") or
        std.ascii.eqlIgnoreCase(s, "off") or std.ascii.eqlIgnoreCase(s, "no")) return false;
    return null;
}

/// Parse + range-check an integer setting. Out-of-range is rejected, not
/// clamped: silently storing something other than what was asked for is how a
/// "limit not applied" bug report starts.
pub fn parseInt(k: Key, s: []const u8) ?i32 {
    const n = std.fmt.parseInt(i32, std.mem.trim(u8, s, " \t\r\n"), 10) catch return null;
    if (n < k.min or n > k.max) return null;
    return n;
}

/// Trimmed text value, or null when it exceeds the key's budget. Empty is
/// allowed — it's how you clear a proxy.
pub fn parseText(k: Key, s: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len > k.max_len) return null;
    return t;
}

// ── Tests ──

test "find: known and unknown keys" {
    try std.testing.expect(find("hwdec") != null);
    try std.testing.expectEqual(Kind.boolean, find("hwdec").?.kind);
    try std.testing.expectEqual(Kind.integer, find("download_rate_limit").?.kind);
    try std.testing.expectEqual(Kind.text, find("proxy_url").?.kind);
    try std.testing.expectEqual(@as(?Key, null), find("no_such_setting"));
    try std.testing.expectEqual(@as(?Key, null), find(""));
}

test "registry: names unique, every key labelled and grouped" {
    for (KEYS, 0..) |a, i| {
        try std.testing.expect(a.name.len > 0);
        try std.testing.expect(a.label.len > 0);
        try std.testing.expect(a.group.len > 0);
        for (KEYS[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
        }
    }
}

test "registry: text keys have a budget, integer keys a usable range" {
    for (KEYS) |k| {
        switch (k.kind) {
            .text => try std.testing.expect(k.max_len > 0),
            .integer => try std.testing.expect(k.max > k.min),
            .boolean => {},
        }
    }
}

test "parseBool: the forms clients actually send" {
    for ([_][]const u8{ "1", "true", "TRUE", "on", "yes" }) |s|
        try std.testing.expectEqual(@as(?bool, true), parseBool(s));
    for ([_][]const u8{ "0", "false", "FALSE", "off", "no" }) |s|
        try std.testing.expectEqual(@as(?bool, false), parseBool(s));
}

test "parseBool: junk is null, never a silent false" {
    for ([_][]const u8{ "", "maybe", "2", "tru" }) |s|
        try std.testing.expectEqual(@as(?bool, null), parseBool(s));
}

test "parseInt: in range, out of range, junk" {
    const k = find("download_rate_limit").?;
    try std.testing.expectEqual(@as(?i32, 0), parseInt(k, "0"));
    try std.testing.expectEqual(@as(?i32, 2048), parseInt(k, " 2048 "));
    try std.testing.expectEqual(@as(?i32, null), parseInt(k, "-1"));
    try std.testing.expectEqual(@as(?i32, null), parseInt(k, "2000000"));
    try std.testing.expectEqual(@as(?i32, null), parseInt(k, "fast"));
    try std.testing.expectEqual(@as(?i32, null), parseInt(k, ""));
}

test "parseInt: rejects rather than clamps" {
    // Clamping would store a limit the user never asked for and report success.
    const k = find("download_rate_limit").?;
    try std.testing.expectEqual(@as(?i32, null), parseInt(k, "99999999"));
}

test "parseText: trims, allows empty, rejects over-budget" {
    const k = find("sub_lang").?;
    try std.testing.expectEqualStrings("eng", parseText(k, "  eng \n").?);
    try std.testing.expectEqualStrings("", parseText(k, "   ").?); // clearing is legal
    try std.testing.expectEqual(@as(?[]const u8, null), parseText(k, "waaaaytoolong"));
}

test "parseText: proxy budget matches the state buffer" {
    const k = find("proxy_url").?;
    try std.testing.expect(k.max_len <= 127); // state.app.proxy_url is [128]u8
    try std.testing.expectEqualStrings("socks5://127.0.0.1:1080", parseText(k, "socks5://127.0.0.1:1080").?);
}

test "registry covers every settings group the web page promises" {
    // Guards against a group silently disappearing when keys are edited — the
    // web Settings page renders one section per distinct group.
    const want = [_][]const u8{ "Playback", "Subtitles", "Network", "Storage", "AI & Voice", "Language", "Privacy" };
    for (want) |g| {
        var found = false;
        for (KEYS) |k| {
            if (std.mem.eql(u8, k.group, g)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "tts_speed is a percent, not a raw multiplier" {
    // 1.0x internally; the wire value is 100. A registry that accepted 1 would
    // silently set 1% speed.
    const k = find("tts_speed").?;
    try std.testing.expectEqual(@as(?i32, 100), parseInt(k, "100"));
    try std.testing.expectEqual(@as(?i32, null), parseInt(k, "1"));
    try std.testing.expectEqual(@as(?i32, null), parseInt(k, "500"));
}

test "save_path budget matches the state buffer" {
    // state.app.save_path_buf is [256]u8 and is NUL-terminated on write.
    try std.testing.expect(find("save_path").?.max_len <= 255);
}
