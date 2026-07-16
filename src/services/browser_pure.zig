//! Pure logic for the in-app browser (Browse › Web) — no io, no dvui, no state.
//! browser.zig routes through these functions so the tested logic IS the
//! shipped logic (see CLAUDE.md test discipline).

const std = @import("std");

// ══════════════════════════════════════════════════════════
// Smart address bar
// ══════════════════════════════════════════════════════════

/// Percent-encode a search query for use as a URL query parameter value.
/// Unreserved characters (RFC 3986) pass through; spaces become '+';
/// everything else — including the CLAUDE.md minimum set (& = # ? % +) —
/// is %XX-escaped. Truncates safely if `out` is too small.
pub fn percentEncodeQuery(input: []const u8, out: []u8) []const u8 {
    const hex = "0123456789ABCDEF";
    var w: usize = 0;
    for (input) |ch| {
        const unreserved = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (unreserved) {
            if (w + 1 > out.len) break;
            out[w] = ch;
            w += 1;
        } else if (ch == ' ') {
            if (w + 1 > out.len) break;
            out[w] = '+';
            w += 1;
        } else {
            if (w + 3 > out.len) break;
            out[w] = '%';
            out[w + 1] = hex[ch >> 4];
            out[w + 2] = hex[ch & 0xF];
            w += 3;
        }
    }
    return out[0..w];
}

fn hasScheme(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "http://") or
        std.mem.startsWith(u8, s, "https://") or
        std.mem.startsWith(u8, s, "file://") or
        std.mem.startsWith(u8, s, "about:");
}

/// Heuristic: does the (trimmed, scheme-less) input look like a host the user
/// wants to visit rather than a phrase to search? No interior spaces AND
/// (a dot, "localhost", or an explicit port).
fn looksLikeHost(s: []const u8) bool {
    if (s.len == 0) return false;
    if (std.mem.indexOfScalar(u8, s, ' ') != null) return false;
    if (std.mem.startsWith(u8, s, "localhost")) return true;
    // "host/path" — dotless intranet hosts stay navigable ("nas/admin").
    if (std.mem.indexOfScalar(u8, s, '/')) |si| {
        if (si > 0) return true;
    }
    // "host:port" or "host:port/path"
    if (std.mem.indexOfScalar(u8, s, ':')) |ci| {
        if (ci + 1 < s.len and s[ci + 1] >= '0' and s[ci + 1] <= '9') return true;
    }
    // Needs a dot that isn't leading/trailing ("example.com", not ".", "foo.")
    if (std.mem.indexOfScalar(u8, s, '.')) |di| {
        if (di > 0 and di + 1 < s.len and s[di + 1] != ' ') return true;
    }
    return false;
}

// ══════════════════════════════════════════════════════════
// Engine selection (camoufox = Firefox-based, cloakbrowser = Chromium-based)
// ══════════════════════════════════════════════════════════

pub const Engine = enum { camoufox, cloakbrowser };

/// Parse a persisted engine name; unknown/legacy values fall back to camoufox
/// (the historical default) so a hand-edited config can't break the browser.
pub fn engineFromString(s: []const u8) Engine {
    return std.meta.stringToEnum(Engine, s) orelse .camoufox;
}

/// The pip package name for an engine (also its site-packages dir name).
pub fn enginePipPackage(e: Engine) []const u8 {
    return switch (e) {
        .camoufox => "camoufox",
        .cloakbrowser => "cloakbrowser",
    };
}

// ══════════════════════════════════════════════════════════
// Bridge protocol — JSON line classification
// ══════════════════════════════════════════════════════════

/// The bridge serializes with stable key order (documented contract in
/// scripts/camoufox_bridge.py): nav pushes are `{"event": "nav", ...}`,
/// navigate responses `{"ok": true, "title": ...}`, find results
/// `{"ok": true, "found": ...}`, download events `{"event": "download", ...}`,
/// reader text `{"event": "readtext", ...}`, failures `{"error": ...}`.
/// Prefix matching (not substring search) keeps scrape/eval payloads that
/// merely CONTAIN "title" from being mistaken for navigation updates.
pub const BridgeMsg = enum { ready, nav, err, find, download, readtext, fetchhtml_err, other };

pub fn classifyBridgeMsg(line: []const u8) BridgeMsg {
    if (std.mem.startsWith(u8, line, "{\"ready\"")) return .ready;
    if (std.mem.startsWith(u8, line, "{\"event\": \"nav\"")) return .nav;
    if (std.mem.startsWith(u8, line, "{\"event\": \"download\"")) return .download;
    if (std.mem.startsWith(u8, line, "{\"event\": \"readtext\"")) return .readtext;
    // Anti-block scrape fetch FAILURE (the success path returns an 'H' binary
    // frame, not a JSON line — see browser.zig). Keep this before the generic
    // `{"error"...}` check; a fetchhtml error carries the "event" key so the
    // scrape-await path can distinguish it from an interactive-nav failure.
    if (std.mem.startsWith(u8, line, "{\"event\": \"fetchhtml\"")) return .fetchhtml_err;
    if (std.mem.startsWith(u8, line, "{\"ok\": true, \"title\"")) return .nav;
    if (std.mem.startsWith(u8, line, "{\"ok\": true, \"found\"")) return .find;
    if (std.mem.startsWith(u8, line, "{\"error\"")) return .err;
    return .other;
}

/// Extract an unsigned integer field from a flat JSON object: `"field": 123`.
pub fn extractJsonUint(json: []const u8, field: []const u8) ?u64 {
    var search_buf: [64]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{field}) catch return null;
    const field_pos = std.mem.indexOf(u8, json, search) orelse return null;
    var pos = field_pos + search.len;
    while (pos < json.len and (json[pos] == ':' or json[pos] == ' ')) pos += 1;
    var end = pos;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') end += 1;
    if (end == pos) return null;
    return std.fmt.parseInt(u64, json[pos..end], 10) catch null;
}

/// Decode a JSON string body (the bytes BETWEEN the quotes) into `out`:
/// \n \r \t \" \\ \/ \b \f become their characters; \uXXXX escapes decode to
/// UTF-8 (surrogates and truncated escapes degrade to '?'). Truncates safely.
pub fn jsonUnescape(input: []const u8, out: []u8) []const u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < input.len and w < out.len) {
        const ch = input[i];
        if (ch != '\\') {
            out[w] = ch;
            w += 1;
            i += 1;
            continue;
        }
        if (i + 1 >= input.len) break;
        const esc = input[i + 1];
        i += 2;
        switch (esc) {
            'n' => {
                out[w] = '\n';
                w += 1;
            },
            'r' => {
                out[w] = '\r';
                w += 1;
            },
            't' => {
                out[w] = '\t';
                w += 1;
            },
            'b', 'f' => {
                out[w] = ' ';
                w += 1;
            },
            'u' => {
                if (i + 4 <= input.len) {
                    const cp = std.fmt.parseInt(u21, input[i .. i + 4], 16) catch 0xFFFD;
                    i += 4;
                    var utf8: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &utf8) catch blk: {
                        utf8[0] = '?';
                        break :blk 1;
                    };
                    if (w + n > out.len) break;
                    @memcpy(out[w .. w + n], utf8[0..n]);
                    w += n;
                } else {
                    out[w] = '?';
                    w += 1;
                    i = input.len;
                }
            },
            else => {
                out[w] = esc;
                w += 1;
            },
        }
    }
    return out[0..w];
}

/// Find a string field in a flat JSON object and return its RAW (still
/// escaped) body — unlike a naive quote scan, this honors backslash escapes,
/// so bodies containing \" don't terminate early. Pair with jsonUnescape.
pub fn extractJsonStringRaw(json: []const u8, field: []const u8) ?[]const u8 {
    var search_buf: [64]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{field}) catch return null;
    const field_pos = std.mem.indexOf(u8, json, search) orelse return null;
    var pos = field_pos + search.len;
    while (pos < json.len and (json[pos] == ':' or json[pos] == ' ')) pos += 1;
    if (pos >= json.len or json[pos] != '"') return null;
    pos += 1;
    var end = pos;
    while (end < json.len) {
        if (json[end] == '\\') {
            end += 2;
            continue;
        }
        if (json[end] == '"') return json[pos..end];
        end += 1;
    }
    return null;
}

// ══════════════════════════════════════════════════════════
// Per-site zoom + downloads — URL/filename helpers
// ══════════════════════════════════════════════════════════

/// Extract the host (with port, without "www.") from a URL — the per-site
/// zoom key. "https://www.example.com:8080/x?y" → "example.com:8080".
pub fn urlHost(url: []const u8) []const u8 {
    var s = url;
    if (std.mem.indexOf(u8, s, "://")) |p| s = s[p + 3 ..];
    var end = s.len;
    for (s, 0..) |ch, i| {
        if (ch == '/' or ch == '?' or ch == '#') {
            end = i;
            break;
        }
    }
    s = s[0..end];
    if (std.mem.lastIndexOfScalar(u8, s, '@')) |a| s = s[a + 1 ..];
    if (std.mem.startsWith(u8, s, "www.")) s = s[4..];
    return s;
}

/// Make a downloaded filename safe to join onto the save dir: path
/// separators and control chars become '_', leading dots are stripped
/// (no dotfiles / traversal), empty input becomes "download".
pub fn sanitizeFilename(name: []const u8, out: []u8) []const u8 {
    var w: usize = 0;
    for (name) |ch| {
        if (w >= out.len) break;
        const bad = ch == '/' or ch == '\\' or ch == ':' or ch < 0x20;
        const c: u8 = if (bad) '_' else ch;
        if (w == 0 and (c == '.' or bad)) continue; // no leading dots / separators
        out[w] = c;
        w += 1;
    }
    if (w == 0) {
        const fallback = "download";
        const n = @min(fallback.len, out.len);
        @memcpy(out[0..n], fallback[0..n]);
        return out[0..n];
    }
    return out[0..w];
}

// ══════════════════════════════════════════════════════════
// History autocomplete ranking
// ══════════════════════════════════════════════════════════

/// Score a history row against what the user typed in the URL bar.
/// 0 = no match. Host-prefix matches rank highest (typing "you" should
/// surface youtube.com first), then URL prefix, URL substring, title
/// substring. All comparisons ASCII case-insensitive.
pub fn historyMatchScore(query: []const u8, url: []const u8, title: []const u8) u32 {
    if (query.len == 0 or url.len == 0) return 0;
    const host = urlHost(url);
    if (std.ascii.startsWithIgnoreCase(host, query)) return 100;
    var np = url;
    if (std.mem.indexOf(u8, np, "://")) |p| np = np[p + 3 ..];
    if (std.ascii.startsWithIgnoreCase(np, query)) return 90;
    if (std.ascii.indexOfIgnoreCase(url, query) != null) return 50;
    if (title.len > 0 and std.ascii.indexOfIgnoreCase(title, query) != null) return 40;
    return 0;
}

/// Turn raw address-bar input into a navigable URL:
///   * already has a scheme → passthrough (trimmed)
///   * looks like a host    → "https://" prefixed
///   * anything else        → DuckDuckGo search URL (query percent-encoded)
/// Returns a slice into `out` (or the trimmed input for passthrough).
pub fn resolveAddress(input: []const u8, out: []u8) []const u8 {
    const s = std.mem.trim(u8, input, " \t\r\n");
    if (s.len == 0) return s;
    if (hasScheme(s)) return s;
    if (looksLikeHost(s)) {
        const n = @min(s.len, out.len -| 8);
        return std.fmt.bufPrint(out, "https://{s}", .{s[0..n]}) catch s;
    }
    const prefix = "https://duckduckgo.com/?q=";
    if (out.len <= prefix.len) return s;
    @memcpy(out[0..prefix.len], prefix);
    const q = percentEncodeQuery(s, out[prefix.len..]);
    return out[0 .. prefix.len + q.len];
}

// ══════════════════════════════════════════════════════════
// Keyboard forwarding decisions
// ══════════════════════════════════════════════════════════

/// Keys that also arrive as dvui text events. Forwarding these as keypresses
/// AND letting the text event through double-types every character — the
/// press must be suppressed unless a chord modifier is held.
pub fn producesText(base: []const u8) bool {
    if (base.len == 1) return true; // letters, digits, punctuation
    return std.mem.eql(u8, base, "Space");
}

/// Should a key-down be forwarded to the page as a Playwright keypress?
/// Navigation/editing keys always go; text-producing keys only as part of a
/// chord (Ctrl/Cmd/Alt) — plain typing is delivered by the text event path.
pub fn shouldForwardKeypress(base: []const u8, ctrl: bool, cmd: bool, alt: bool) bool {
    if (ctrl or cmd or alt) return true;
    return !producesText(base);
}

/// Compose a Playwright key string with modifiers: "Control+Shift+ArrowDown".
/// Order: Control, Alt, Meta, Shift, base. Returns base unchanged when no
/// modifier is held or the buffer is too small.
pub fn composeKeyCombo(base: []const u8, ctrl: bool, cmd: bool, alt: bool, shift: bool, out: []u8) []const u8 {
    if (!ctrl and !cmd and !alt and !shift) return base;
    var w: usize = 0;
    const parts = [_]struct { on: bool, name: []const u8 }{
        .{ .on = ctrl, .name = "Control" },
        .{ .on = alt, .name = "Alt" },
        .{ .on = cmd, .name = "Meta" },
        .{ .on = shift, .name = "Shift" },
    };
    for (parts) |p| {
        if (!p.on) continue;
        if (w + p.name.len + 1 > out.len) return base;
        @memcpy(out[w .. w + p.name.len], p.name);
        w += p.name.len;
        out[w] = '+';
        w += 1;
    }
    if (w + base.len > out.len) return base;
    @memcpy(out[w .. w + base.len], base);
    return out[0 .. w + base.len];
}

// ══════════════════════════════════════════════════════════
// Content routing — URL → mpv / comic viewer / web
// (moved verbatim from browser.zig so it's testable; browser.zig re-exports)
// ══════════════════════════════════════════════════════════

pub const ContentRoute = enum { mpv, comic_viewer, web };

/// Determine the correct pane provider for a given URL
pub fn routeContent(url: []const u8) ContentRoute {
    // Video/audio extensions → mpv
    const mpv_exts = [_][]const u8{
        ".mp4", ".mkv",  ".avi", ".webm", ".flv", ".mov", ".m4v",
        ".mp3", ".flac", ".ogg", ".wav",  ".aac", ".m4a", ".m3u8",
        ".ts",
    };
    for (mpv_exts) |ext| {
        if (std.mem.endsWith(u8, url, ext)) return .mpv;
    }

    // Video hosting sites → mpv (via yt-dlp)
    const mpv_domains = [_][]const u8{
        "youtube.com",     "youtu.be",       "twitch.tv",      "vimeo.com",
        "dailymotion.com", "bilibili.com",   "rumble.com",     "crunchyroll.com",
        "funimation.com",  "allanime.day",   "gogoanime",      "animixplay",
        "pornhub.com",     "pornhub.org",
        // Streamlink-supported live sites
           "chaturbate.com", "stripchat.com",
        "bongacams.com",   "cam4.com",       "camsoda.com",    "myfreecams.com",
        "flirt4free.com",  "livejasmin.com", "kick.com",       "picarto.tv",
        "dlive.tv",        "afreecatv.com",  "pluto.tv",       "odysee.com",
    };
    for (mpv_domains) |domain| {
        if (std.mem.indexOf(u8, url, domain) != null) return .mpv;
    }

    // Comic sites → comic_viewer
    const comic_domains = [_][]const u8{
        "readallcomics.com", "readcomicsonline", "comicextra.net",
        "mangadex.org",      "mangakakalot.com", "manganato.com",
        "webtoons.com",      "tapas.io",
    };
    for (comic_domains) |domain| {
        if (std.mem.indexOf(u8, url, domain) != null) return .comic_viewer;
    }

    // Image galleries → comic_viewer
    const img_exts = [_][]const u8{ ".jpg", ".jpeg", ".png", ".gif", ".webp" };
    for (img_exts) |ext| {
        if (std.mem.endsWith(u8, url, ext)) return .comic_viewer;
    }

    // Everything else → web browser
    return .web;
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "percentEncodeQuery encodes reserved set and spaces" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("cat+videos", percentEncodeQuery("cat videos", &buf));
    try std.testing.expectEqualStrings("a%26b%3Dc%23d%3Fe%25f%2Bg", percentEncodeQuery("a&b=c#d?e%f+g", &buf));
    try std.testing.expectEqualStrings("safe-._~AZaz09", percentEncodeQuery("safe-._~AZaz09", &buf));
}

test "percentEncodeQuery truncates instead of overflowing" {
    var tiny: [4]u8 = undefined;
    // "%26" fits (3 bytes), second escape would need 6 — stops cleanly.
    try std.testing.expectEqualStrings("%26a", percentEncodeQuery("&a&", &tiny));
}

test "resolveAddress passes through full URLs" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("https://example.com/x", resolveAddress("https://example.com/x", &buf));
    try std.testing.expectEqualStrings("http://a.b", resolveAddress("  http://a.b  ", &buf));
    try std.testing.expectEqualStrings("about:blank", resolveAddress("about:blank", &buf));
}

test "resolveAddress prefixes bare hosts with https" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("https://example.com", resolveAddress("example.com", &buf));
    try std.testing.expectEqualStrings("https://sub.domain.io/path?q=1", resolveAddress("sub.domain.io/path?q=1", &buf));
    try std.testing.expectEqualStrings("https://localhost:3000", resolveAddress("localhost:3000", &buf));
    // Dotless intranet host with a path stays navigable (not a search).
    try std.testing.expectEqualStrings("https://nas/admin", resolveAddress("nas/admin", &buf));
}

test "resolveAddress falls back to search for phrases" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://duckduckgo.com/?q=cat+videos",
        resolveAddress("cat videos", &buf),
    );
    // Single word without a dot searches too.
    try std.testing.expectEqualStrings(
        "https://duckduckgo.com/?q=weather",
        resolveAddress("weather", &buf),
    );
    // Phrase containing a dot still searches (interior space wins).
    try std.testing.expectEqualStrings(
        "https://duckduckgo.com/?q=node.js+tutorial",
        resolveAddress("node.js tutorial", &buf),
    );
}

test "keypress forwarding suppresses plain text keys" {
    // Plain letter: text event delivers it — do NOT forward (double-type bug).
    try std.testing.expect(!shouldForwardKeypress("a", false, false, false));
    try std.testing.expect(!shouldForwardKeypress("Space", false, false, false));
    // Chords always forward.
    try std.testing.expect(shouldForwardKeypress("a", true, false, false));
    try std.testing.expect(shouldForwardKeypress("c", false, true, false));
    // Navigation/editing keys always forward.
    try std.testing.expect(shouldForwardKeypress("Enter", false, false, false));
    try std.testing.expect(shouldForwardKeypress("ArrowDown", false, false, false));
    try std.testing.expect(shouldForwardKeypress("Backspace", false, false, false));
}

test "composeKeyCombo builds modifier chords" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Enter", composeKeyCombo("Enter", false, false, false, false, &buf));
    try std.testing.expectEqualStrings("Control+a", composeKeyCombo("a", true, false, false, false, &buf));
    try std.testing.expectEqualStrings("Meta+c", composeKeyCombo("c", false, true, false, false, &buf));
    try std.testing.expectEqualStrings(
        "Control+Alt+Meta+Shift+ArrowUp",
        composeKeyCombo("ArrowUp", true, true, true, true, &buf),
    );
}

test "engineFromString parses names and falls back to camoufox" {
    try std.testing.expectEqual(Engine.camoufox, engineFromString("camoufox"));
    try std.testing.expectEqual(Engine.cloakbrowser, engineFromString("cloakbrowser"));
    try std.testing.expectEqual(Engine.camoufox, engineFromString("lightpanda"));
    try std.testing.expectEqual(Engine.camoufox, engineFromString(""));
    try std.testing.expectEqualStrings("cloakbrowser", enginePipPackage(.cloakbrowser));
    try std.testing.expectEqualStrings("camoufox", enginePipPackage(.camoufox));
}

test "classifyBridgeMsg recognizes find, download and readtext messages" {
    try std.testing.expectEqual(BridgeMsg.find, classifyBridgeMsg("{\"ok\": true, \"found\": true, \"count\": 12}"));
    try std.testing.expectEqual(BridgeMsg.download, classifyBridgeMsg("{\"event\": \"download\", \"url\": \"https://x/f.zip\", \"filename\": \"f.zip\"}"));
    try std.testing.expectEqual(BridgeMsg.readtext, classifyBridgeMsg("{\"event\": \"readtext\", \"text\": \"body\"}"));
    try std.testing.expectEqual(BridgeMsg.fetchhtml_err, classifyBridgeMsg("{\"event\": \"fetchhtml\", \"error\": \"net::ERR\"}"));
    // Still classified as before:
    try std.testing.expectEqual(BridgeMsg.nav, classifyBridgeMsg("{\"ok\": true, \"title\": \"T\", \"url\": \"https://x\"}"));
}

test "extractJsonUint parses numeric fields" {
    try std.testing.expectEqual(@as(?u64, 12), extractJsonUint("{\"ok\": true, \"found\": true, \"count\": 12}", "count"));
    try std.testing.expectEqual(@as(?u64, 0), extractJsonUint("{\"count\": 0}", "count"));
    try std.testing.expectEqual(@as(?u64, null), extractJsonUint("{\"count\": \"x\"}", "count"));
    try std.testing.expectEqual(@as(?u64, null), extractJsonUint("{\"ok\": true}", "count"));
}

test "extractJsonStringRaw honors escapes; jsonUnescape decodes" {
    const json = "{\"event\": \"readtext\", \"text\": \"line1\\nsaid \\\"hi\\\"\\ttab\"}";
    const raw = extractJsonStringRaw(json, "text").?;
    try std.testing.expectEqualStrings("line1\\nsaid \\\"hi\\\"\\ttab", raw);
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("line1\nsaid \"hi\"\ttab", jsonUnescape(raw, &buf));
    // \uXXXX decodes to UTF-8.
    try std.testing.expectEqualStrings("a\u{00e9}b", jsonUnescape("a\\u00e9b", &buf));
    // Missing field / unterminated string → null, never a slice overrun.
    try std.testing.expectEqual(@as(?[]const u8, null), extractJsonStringRaw(json, "nope"));
    try std.testing.expectEqual(@as(?[]const u8, null), extractJsonStringRaw("{\"text\": \"unterminated", "text"));
}

test "urlHost extracts host for per-site zoom keys" {
    try std.testing.expectEqualStrings("example.com", urlHost("https://www.example.com/a/b?c=d"));
    try std.testing.expectEqualStrings("example.com:8080", urlHost("http://example.com:8080/x"));
    try std.testing.expectEqualStrings("localhost:3000", urlHost("http://localhost:3000"));
    try std.testing.expectEqualStrings("host.io", urlHost("https://user:pw@host.io/p"));
    try std.testing.expectEqualStrings("bare.host", urlHost("bare.host/path"));
    try std.testing.expectEqualStrings("", urlHost("https://"));
}

test "sanitizeFilename blocks traversal and separators" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("etc_passwd", sanitizeFilename("../etc/passwd", &buf));
    try std.testing.expectEqualStrings("a_b_c.txt", sanitizeFilename("a/b\\c.txt", &buf));
    try std.testing.expectEqualStrings("download", sanitizeFilename("", &buf));
    try std.testing.expectEqualStrings("download", sanitizeFilename("...", &buf));
    try std.testing.expectEqualStrings("movie (2024).mkv", sanitizeFilename("movie (2024).mkv", &buf));
}

test "historyMatchScore ranks host prefix over substring over title" {
    const yt_score = historyMatchScore("you", "https://www.youtube.com/watch", "Watch");
    const sub_score = historyMatchScore("tube", "https://www.youtube.com/watch", "Watch");
    const title_score = historyMatchScore("zig", "https://example.com/lang", "Zig language");
    try std.testing.expect(yt_score > sub_score);
    try std.testing.expect(sub_score > title_score);
    try std.testing.expect(title_score > 0);
    // Case-insensitive; no match → 0; empty query → 0.
    try std.testing.expect(historyMatchScore("YOU", "https://youtube.com", "") == yt_score);
    try std.testing.expectEqual(@as(u32, 0), historyMatchScore("xyz", "https://example.com", "title"));
    try std.testing.expectEqual(@as(u32, 0), historyMatchScore("", "https://example.com", "t"));
}

test "classifyBridgeMsg keys off stable prefixes, not substrings" {
    // Exact json.dumps output shapes from camoufox_bridge.py.
    try std.testing.expectEqual(BridgeMsg.ready, classifyBridgeMsg("{\"ready\": true}"));
    try std.testing.expectEqual(BridgeMsg.nav, classifyBridgeMsg("{\"event\": \"nav\", \"title\": \"T\", \"url\": \"https://x\"}"));
    try std.testing.expectEqual(BridgeMsg.nav, classifyBridgeMsg("{\"ok\": true, \"title\": \"T\", \"url\": \"https://x\"}"));
    try std.testing.expectEqual(BridgeMsg.err, classifyBridgeMsg("{\"error\": \"net::ERR\", \"url\": \"https://x\"}"));
    // Scrape/eval payloads that merely CONTAIN "title" are NOT nav updates —
    // the old substring check rewrote the address bar with scraped text.
    try std.testing.expectEqual(BridgeMsg.other, classifyBridgeMsg("{\"ok\": true, \"results\": [\"the page title is bogus\", \"\\\"title\\\":\\\"x\\\"\"]}"));
    try std.testing.expectEqual(BridgeMsg.other, classifyBridgeMsg("{\"ok\": true, \"result\": {\"title\": \"from eval\"}}"));
}

test "routeContent classifies media, comics and web" {
    try std.testing.expectEqual(ContentRoute.mpv, routeContent("https://x.cdn/movie.mkv"));
    try std.testing.expectEqual(ContentRoute.mpv, routeContent("https://www.youtube.com/watch?v=abc"));
    try std.testing.expectEqual(ContentRoute.mpv, routeContent("https://stream.site/live.m3u8"));
    try std.testing.expectEqual(ContentRoute.comic_viewer, routeContent("https://mangadex.org/title/x"));
    try std.testing.expectEqual(ContentRoute.comic_viewer, routeContent("https://img.host/page.png"));
    try std.testing.expectEqual(ContentRoute.web, routeContent("https://en.wikipedia.org/wiki/Zig"));
    // Regression guard: extensionless stream-ish URL stays .web — known
    // playback must use resumePlayback/loadContentDirect, not routing.
    try std.testing.expectEqual(ContentRoute.web, routeContent("https://cdn.example.com/stream/98765"));
}
