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
// Bridge protocol — JSON line classification
// ══════════════════════════════════════════════════════════

/// The Camoufox bridge serializes with stable key order (documented contract
/// in scripts/camoufox_bridge.py): nav pushes are `{"event": "nav", ...}`,
/// navigate responses `{"ok": true, "title": ...}`, failures `{"error": ...}`.
/// Prefix matching (not substring search) keeps scrape/eval payloads that
/// merely CONTAIN "title" from being mistaken for navigation updates.
pub const BridgeMsg = enum { ready, nav, err, other };

pub fn classifyBridgeMsg(line: []const u8) BridgeMsg {
    if (std.mem.startsWith(u8, line, "{\"ready\"")) return .ready;
    if (std.mem.startsWith(u8, line, "{\"event\": \"nav\"")) return .nav;
    if (std.mem.startsWith(u8, line, "{\"ok\": true, \"title\"")) return .nav;
    if (std.mem.startsWith(u8, line, "{\"error\"")) return .err;
    return .other;
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
