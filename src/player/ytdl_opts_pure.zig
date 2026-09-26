//! mpv `ytdl-raw-options` construction — pure, so the exact option string mpv
//! receives is unit-testable. player.zig routes through `buildRawOptions`.
//!
//! YouTube's current default client can return adaptive URLs that reject the
//! open-ended byte range FFmpeg/libmpv uses (`Range: bytes=0-`) with HTTP 403.
//! The Android compatibility client returns a progressive A/V rendition whose
//! range contract works with libmpv. Opal tries that reliable path first and
//! retains yt-dlp's default extraction as the one error retry.

const std = @import("std");

pub const Options = struct {
    /// Empty = direct.
    proxy: []const u8 = "",
    /// Extra yt-dlp JavaScript runtime to enable (`node`, `deno`, `bun`, or
    /// `name:/path`), or empty for yt-dlp's default set (deno only).
    ///
    /// YouTube extraction needs a JS runtime for its signature/n-challenge
    /// since yt-dlp 2025.10; without one it warns "some formats may be
    /// missing" — the first casualties are the high-bitrate 1440p/4K DASH
    /// streams. `--js-runtimes` is ADDITIVE (deno stays enabled) and a runtime
    /// that is not installed only reproduces today's warning, so naming one
    /// that is merely likely to exist (node ships on far more machines than
    /// deno) is free.
    js_runtime: []const u8 = "",
    /// Prefer the libmpv-compatible progressive YouTube client on first load.
    youtube_compatible: bool = false,
};

const YOUTUBE_COMPAT_ARGS = "youtube:player_client=android";

/// A value may be spliced into mpv's comma-separated key=value list only if it
/// cannot terminate the entry early or smuggle a second key — and if it does
/// not START with `%`: mpv reads a leading `%` as its `%<len>%<bytes>` escape,
/// and a value like `%.*` fails that parse ("Invalid length 0"), which makes
/// mpv reject the ENTIRE option, every other key in it included.
fn safeListValue(v: []const u8) bool {
    return v.len > 0 and
        v[0] != '%' and
        std.mem.indexOfScalar(u8, v, ',') == null and
        std.mem.indexOfScalar(u8, v, '\n') == null and
        std.mem.indexOfScalar(u8, v, '\r') == null and
        std.mem.indexOfScalar(u8, v, 0) == null;
}

/// Build the comma-separated `ytdl-raw-options` value. Returns the slice written
/// into `out`, or null when `out` is too small (caller then sets nothing rather
/// than a truncated option string, which mpv would misparse).
///
/// mpv splits this value on `,`, and each entry is `key=value` (a bare flag is
/// `key=`). A proxy URL containing a comma would corrupt every later entry, so
/// such a proxy is dropped rather than emitted.
pub fn buildRawOptions(opts: Options, out: []u8) ?[]const u8 {
    var w: usize = 0;

    const append = struct {
        fn f(buf: []u8, at: *usize, s: []const u8) bool {
            if (at.* + s.len > buf.len) return false;
            @memcpy(buf[at.*..][0..s.len], s);
            at.* += s.len;
            return true;
        }
    }.f;

    if (!append(out, &w, "ignore-config=,no-playlist=")) return null;

    if (safeListValue(opts.js_runtime)) {
        if (!append(out, &w, ",js-runtimes=")) return null;
        if (!append(out, &w, opts.js_runtime)) return null;
    }

    if (opts.youtube_compatible) {
        if (!append(out, &w, ",extractor-args=%29%")) return null;
        if (!append(out, &w, YOUTUBE_COMPAT_ARGS)) return null;
    }

    // A comma in the proxy would be read by mpv as an option separator.
    if (safeListValue(opts.proxy)) {
        if (!append(out, &w, ",proxy=")) return null;
        if (!append(out, &w, opts.proxy)) return null;
    }

    return out[0..w];
}

// ── script-opts (ytdl_hook configuration) ──

pub const ScriptOpts = struct {
    /// Path of the yt-dlp binary ytdl_hook should spawn. Empty (or unsafe for
    /// the list syntax) = omitted, and ytdl_hook falls back to `yt-dlp` on PATH.
    ytdl_path: []const u8 = "",
    /// Append `sponsorblock-mark=all` for the SponsorBlock user script.
    sponsorblock: bool = false,
};

/// ytdl_hook `exclude`: `|`-separated LUA PATTERNS that ytdl_hook matches
/// (unanchored, lowercased, scheme stripped) against a URL; a hit bypasses
/// yt-dlp entirely. These are the page types that expand into huge playlists
/// (model/channel/playlist pages). They used to be written `%.*/model/.*` —
/// `%.` is Lua's literal-dot escape, so that was "any number of dots, then
/// /model/", and worse, the leading `%` made mpv reject the whole option (see
/// safeListValue). Unanchored substrings need no wildcard at all.
pub const EXCLUDE = "/model/|/channels/|/pornstar/|/playlist";

/// Build the mpv `script-opts` value that configures ytdl_hook. Returns the
/// slice written into `out` (NUL-terminated at out[len] — the caller may hand
/// `out.ptr` to mpv), or null when `out` is too small.
///
/// REGRESSION THIS GUARDS: the string used to be assembled ad hoc in
/// player.zig with an exclude value starting with `%`. mpv parses the value of
/// a key=value list entry as `%<len>%<bytes>` when it starts with `%`, so it
/// logged "Invalid length 0 for 'script-opts'" and DROPPED THE ENTIRE OPTION —
/// including `ytdl_hook-ytdl_path`. ytdl_hook then only searched PATH for
/// yt-dlp / yt-dlp_x86 / youtube-dl, which on Windows (and in a macOS GUI
/// process whose PATH lacks /opt/homebrew/bin) finds nothing, so every YouTube
/// URL failed with "youtube-dl failed: not found or not enough permissions".
pub fn buildScriptOpts(opts: ScriptOpts, out: []u8) ?[:0]const u8 {
    var w: usize = 0;

    const append = struct {
        fn f(buf: []u8, at: *usize, s: []const u8) bool {
            // Keep one byte for the terminator.
            if (at.* + s.len + 1 > buf.len) return false;
            @memcpy(buf[at.*..][0..s.len], s);
            at.* += s.len;
            return true;
        }
    }.f;

    if (safeListValue(opts.ytdl_path)) {
        if (!append(out, &w, "ytdl_hook-ytdl_path=")) return null;
        if (!append(out, &w, opts.ytdl_path)) return null;
        if (!append(out, &w, ",")) return null;
    }
    // try_ytdl_first=no: non-YouTube URLs get one direct open attempt before
    // yt-dlp is spawned (ytdl_hook always tries yt-dlp first for youtube.com).
    if (!append(out, &w, "ytdl_hook-try_ytdl_first=no,ytdl_hook-exclude=")) return null;
    if (!append(out, &w, EXCLUDE)) return null;
    if (opts.sponsorblock) {
        if (!append(out, &w, ",sponsorblock-mark=all")) return null;
    }
    out[w] = 0;
    return out[0..w :0];
}

/// True when every `key=value` entry of an mpv key-value list string has a
/// value mpv can parse literally — i.e. none starts with `%`. Test helper.
fn noEntryStartsWithPercent(list: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return false;
        const val = entry[eq + 1 ..];
        if (val.len > 0 and val[0] == '%') return false;
    }
    return true;
}

test "script-opts: exact string with bundled path and sponsorblock off" {
    var b: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "ytdl_hook-ytdl_path=/Users/x/.config/opal/bin/yt-dlp," ++
            "ytdl_hook-try_ytdl_first=no,ytdl_hook-exclude=/model/|/channels/|/pornstar/|/playlist",
        buildScriptOpts(.{ .ytdl_path = "/Users/x/.config/opal/bin/yt-dlp" }, &b).?,
    );
}

test "script-opts: sponsorblock appends, windows backslash path passes verbatim" {
    var b: [512]u8 = undefined;
    const s = buildScriptOpts(.{
        .ytdl_path = "C:\\Users\\pal\\AppData\\Roaming/opal/bin/yt-dlp.exe",
        .sponsorblock = true,
    }, &b).?;
    try std.testing.expectEqualStrings(
        "ytdl_hook-ytdl_path=C:\\Users\\pal\\AppData\\Roaming/opal/bin/yt-dlp.exe," ++
            "ytdl_hook-try_ytdl_first=no,ytdl_hook-exclude=/model/|/channels/|/pornstar/|/playlist," ++
            "sponsorblock-mark=all",
        s,
    );
    // NUL-terminated in place so out.ptr can go straight to mpv.
    try std.testing.expectEqual(@as(u8, 0), b[s.len]);
}

// Regression: "YouTube: youtube-dl failed: not found or not enough
// permissions" on Windows — the exclude value started with `%` and mpv
// rejected the whole script-opts option, ytdl_path included.
test "script-opts: no entry value may start with '%' (mpv %len% escape)" {
    var b: [512]u8 = undefined;
    const cases = [_]ScriptOpts{
        .{},
        .{ .ytdl_path = "yt-dlp" },
        .{ .ytdl_path = "C:/p/yt-dlp.exe", .sponsorblock = true },
    };
    for (cases) |o| {
        try std.testing.expect(noEntryStartsWithPercent(buildScriptOpts(o, &b).?));
    }
    // And a hostile path cannot smuggle one back in: it is dropped, not emitted.
    const s = buildScriptOpts(.{ .ytdl_path = "%7%abc" }, &b).?;
    try std.testing.expect(std.mem.indexOf(u8, s, "ytdl_path") == null);
    try std.testing.expect(noEntryStartsWithPercent(s));
}

test "script-opts: a comma in the yt-dlp path is dropped rather than splitting the list" {
    var b: [512]u8 = undefined;
    const s = buildScriptOpts(.{ .ytdl_path = "C:/a,b/yt-dlp.exe" }, &b).?;
    try std.testing.expectEqualStrings(
        "ytdl_hook-try_ytdl_first=no,ytdl_hook-exclude=/model/|/channels/|/pornstar/|/playlist",
        s,
    );
}

test "script-opts: exclude patterns are valid unanchored Lua substrings" {
    // No Lua magic characters that would change meaning or fail to compile:
    // the list is `|`-separated by ytdl_hook itself.
    for (EXCLUDE) |ch| {
        try std.testing.expect(ch != '%' and ch != '(' and ch != ')' and ch != '[' and ch != ']');
    }
    try std.testing.expect(std.mem.indexOf(u8, EXCLUDE, "/model/") != null);
    try std.testing.expect(std.mem.indexOf(u8, EXCLUDE, "/playlist") != null);
}

test "script-opts: too-small buffer yields null" {
    var small: [16]u8 = undefined;
    try std.testing.expect(buildScriptOpts(.{ .ytdl_path = "yt-dlp" }, &small) == null);
}

test "default: no cookies, no proxy" {
    var b: [400]u8 = undefined;
    try std.testing.expectEqualStrings(
        "ignore-config=,no-playlist=",
        buildRawOptions(.{}, &b).?,
    );
}

test "normal playback cannot grant cookies or disable TLS" {
    var b: [400]u8 = undefined;
    const options = buildRawOptions(.{}, &b).?;
    try std.testing.expect(std.mem.indexOf(u8, options, "cookies") == null);
    try std.testing.expect(std.mem.indexOf(u8, options, "no-check-certificates") == null);
}

test "proxy appended last" {
    var b: [400]u8 = undefined;
    try std.testing.expectEqualStrings(
        "ignore-config=,no-playlist=,proxy=http://127.0.0.1:8080",
        buildRawOptions(.{ .proxy = "http://127.0.0.1:8080" }, &b).?,
    );
}

test "socks proxy without browser credentials" {
    var b: [400]u8 = undefined;
    try std.testing.expectEqualStrings(
        "ignore-config=,no-playlist=,proxy=socks5://h:1",
        buildRawOptions(.{ .proxy = "socks5://h:1" }, &b).?,
    );
}

test "a comma/newline in the proxy is dropped, not emitted" {
    var b: [400]u8 = undefined;
    try std.testing.expectEqualStrings(
        "ignore-config=,no-playlist=",
        buildRawOptions(.{ .proxy = "http://a,b" }, &b).?,
    );
    try std.testing.expectEqualStrings(
        "ignore-config=,no-playlist=",
        buildRawOptions(.{ .proxy = "http://a\nb" }, &b).?,
    );
}

test "js runtime is emitted before the proxy and only when named" {
    var b: [400]u8 = undefined;
    try std.testing.expectEqualStrings(
        "ignore-config=,no-playlist=,js-runtimes=node",
        buildRawOptions(.{ .js_runtime = "node" }, &b).?,
    );
    try std.testing.expectEqualStrings(
        "ignore-config=,no-playlist=,js-runtimes=node:C:/tools/node.exe,proxy=http://p:1",
        buildRawOptions(.{ .js_runtime = "node:C:/tools/node.exe", .proxy = "http://p:1" }, &b).?,
    );
    // Empty (the default) adds nothing — yt-dlp keeps its own default set.
    try std.testing.expect(std.mem.indexOf(u8, buildRawOptions(.{}, &b).?, "js-runtimes") == null);
}

test "compatible YouTube extraction uses a length-delimited argument" {
    var b: [400]u8 = undefined;
    try std.testing.expectEqualStrings(
        "ignore-config=,no-playlist=,js-runtimes=node,extractor-args=%29%youtube:player_client=android",
        buildRawOptions(.{ .js_runtime = "node", .youtube_compatible = true }, &b).?,
    );
}

test "a comma/newline in the js runtime is dropped, not emitted" {
    var b: [400]u8 = undefined;
    try std.testing.expectEqualStrings(
        "ignore-config=,no-playlist=",
        buildRawOptions(.{ .js_runtime = "node,cookies=x" }, &b).?,
    );
    try std.testing.expectEqualStrings(
        "ignore-config=,no-playlist=",
        buildRawOptions(.{ .js_runtime = "node\n" }, &b).?,
    );
}

test "too-small buffer yields null rather than a truncated option string" {
    var small: [8]u8 = undefined;
    try std.testing.expect(buildRawOptions(.{}, &small) == null);
}

// Regression: the default adaptive audio URL rejected FFmpeg's open-ended byte
// range with 403. Android's progressive A/V URL accepts that request shape.
test "YouTube compatibility mode selects the progressive Android client" {
    var b: [400]u8 = undefined;
    const s = buildRawOptions(.{ .youtube_compatible = true }, &b).?;
    try std.testing.expect(std.mem.indexOf(u8, s, "youtube:player_client=android") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "player_client=tv") == null);
}
