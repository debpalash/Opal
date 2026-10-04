//! Pure logic for the direct browser link (docs/browser-integration.md): the
//! pairing code state machine, paired-browser token rules, the loopback and
//! Origin checks that guard the unauthenticated pairing route, and parsing plus
//! validation of the media candidates a paired browser sends.
//!
//! No `io_global`, `db`, `state` or clock reach: callers pass `now` and random
//! bytes, so every rule here unit-tests standalone (CLAUDE.md cross-boundary
//! note). `browser_link.zig` and `remote_browser_api.zig` call straight into
//! these functions, so the tested logic is the shipped logic.
//!
//! Everything a page can influence is untrusted data. Candidate URLs, Referer,
//! Origin and User-Agent come from a web page by way of the extension; they are
//! length capped, scheme restricted and checked for control characters, and
//! none of them ever becomes an argv element, a file path or a mpv string
//! command (they reach mpv only as per-file option values through the array
//! form of `loadfile`, in player.zig).

const std = @import("std");

// ── Limits ─────────────────────────────────────────────────────────────────

/// Largest request body `/api/browser/media` reads. The shared 4096-byte request
/// buffer would truncate a tokenized HLS URL, so this one route is allowed to
/// grow (see remote_body_pure.zig); nothing else is.
pub const MAX_BODY: usize = 64 * 1024;
pub const MAX_CANDIDATES: usize = 8;
/// A signed CDN playlist URL can carry a few KB of query. 4096 is the cap of
/// the handoff slot; validation rejects longer URLs instead of truncating them.
pub const MAX_URL: usize = 4096;
pub const MAX_PAGE_URL: usize = 2048;
pub const MAX_REFERER: usize = 2048;
pub const MAX_ORIGIN: usize = 256;
pub const MAX_UA: usize = 512;
pub const MAX_TITLE: usize = 256;
pub const MAX_ART: usize = 1024;
pub const MAX_LABEL: usize = 64;
/// Queue rows (queue.zig) hold URLs under 2048 bytes and carry no headers.
pub const MAX_QUEUE_URL: usize = 2047;

// ── URL and header validation ──────────────────────────────────────────────

pub const UrlError = error{ Empty, TooLong, BadScheme, BadChar, NoHost, Credentials };

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

/// Accept only absolute http(s) URLs with a host and no embedded credentials.
///
/// Deliberately NOT the operator's `publicHost` rule: that one rejects loopback
/// and private addresses because the operator fetches on a model's behalf. A
/// browser-sniffed stream is regularly on the user's own LAN (Jellyfin, a NAS,
/// a camera), so refusing private hosts would break the main use. The risks that
/// do apply to a URL handed to a media player are a non-http(s) scheme (`file:`
/// reads local files, `javascript:` and `data:` are page-controlled payloads)
/// and userinfo (`http://user:pass@host/`, which would persist a credential in
/// history and logs). Those are the only things rejected.
pub fn validateHttpUrl(url: []const u8, max_len: usize) UrlError!void {
    if (url.len == 0) return error.Empty;
    if (url.len > max_len) return error.TooLong;
    for (url) |ch| {
        // Space, controls, DEL, and backslash (browsers read `\` as `/` in the
        // authority of special schemes; mpv and ffmpeg do not).
        if (ch <= 0x20 or ch == 0x7f or ch == '\\') return error.BadChar;
    }
    const rest = if (startsWithIgnoreCase(url, "http://"))
        url["http://".len..]
    else if (startsWithIgnoreCase(url, "https://"))
        url["https://".len..]
    else
        return error.BadScheme;
    var authority_end = rest.len;
    for (rest, 0..) |ch, i| {
        if (ch == '/' or ch == '?' or ch == '#') {
            authority_end = i;
            break;
        }
    }
    const authority = rest[0..authority_end];
    if (authority.len == 0 or authority[0] == ':') return error.NoHost;
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return error.Credentials;
}

/// An Origin is scheme://host[:port] with no path, query or fragment.
pub fn validateOrigin(origin: []const u8) UrlError!void {
    try validateHttpUrl(origin, MAX_ORIGIN);
    const scheme_len: usize = if (startsWithIgnoreCase(origin, "https://")) 8 else 7;
    const rest = origin[scheme_len..];
    if (std.mem.indexOfAny(u8, rest, "/?#") != null) return error.BadChar;
}

/// A header value reaches the request line of the upstream server. No control
/// characters at all (so no CR/LF injection), bounded length.
pub fn validHeaderValue(value: []const u8, max_len: usize) bool {
    if (value.len > max_len) return false;
    for (value) |ch| if (ch < 0x20 or ch == 0x7f) return false;
    return true;
}

/// Copy `src` with control characters turned into spaces, trimmed, cut at
/// `out.len` bytes on a UTF-8 boundary. Used for display strings (title, label)
/// where an odd page title must not fail the whole request.
pub fn sanitizeText(src: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    for (src) |ch| {
        if (n >= out.len) break;
        out[n] = if (ch < 0x20 or ch == 0x7f) ' ' else ch;
        n += 1;
    }
    // Do not leave half of a multi-byte sequence at the cut.
    if (n == out.len and n < src.len and (src[n] & 0xC0) == 0x80) {
        // The cut fell inside a character: drop its lead byte and tail so far.
        while (n > 0 and (out[n - 1] & 0xC0) == 0x80) n -= 1;
        if (n > 0) n -= 1;
    }
    return std.mem.trim(u8, out[0..n], " ");
}

// ── Candidates ─────────────────────────────────────────────────────────────

pub const Kind = enum {
    hls,
    dash,
    mp4,
    webm,
    mkv,
    audio,
    ts,
    other,

    pub fn parse(s: []const u8) ?Kind {
        inline for (@typeInfo(Kind).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @field(Kind, f.name);
        }
        return null;
    }

    /// Higher plays first when a request carries several candidates. Adaptive
    /// manifests beat a single progressive file, which beats audio-only, which
    /// beats a bare transport-stream segment (usually one piece of an HLS run).
    pub fn rank(self: Kind) u8 {
        return switch (self) {
            .hls, .dash => 4,
            .mp4, .webm, .mkv => 3,
            .audio => 2,
            .other => 1,
            .ts => 0,
        };
    }
};

pub const Action = enum {
    play,
    queue,
    /// Add the (user-edited) title to the Wanted list. No stream is involved.
    add_to_wanted,

    pub fn parse(s: []const u8) ?Action {
        if (std.mem.eql(u8, s, "play")) return .play;
        if (std.mem.eql(u8, s, "queue")) return .queue;
        if (std.mem.eql(u8, s, "add_to_wanted")) return .add_to_wanted;
        return null;
    }
};

pub const Candidate = struct {
    url: []const u8,
    kind: Kind,
    referer: []const u8 = "",
    origin: []const u8 = "",
    ua: []const u8 = "",
    duration: ?f64 = null,
};

pub const Media = struct {
    action: Action,
    page_url: []const u8,
    title: []const u8,
    art: []const u8,
    candidates: []const Candidate,
};

pub const ParseError = error{
    BadJson,
    BadAction,
    NoCandidates,
    TooManyCandidates,
    BadPageUrl,
    BadCandidateUrl,
    BadKind,
    BadReferer,
    BadOrigin,
    BadUserAgent,
    OutOfMemory,
};

/// Human-readable reason for a 400 response.
pub fn parseErrorMessage(err: ParseError) []const u8 {
    return switch (err) {
        error.BadJson => "body must be a JSON object",
        error.BadAction => "action must be play, queue or add_to_wanted",
        error.NoCandidates => "at least one candidate is required",
        error.TooManyCandidates => "too many candidates",
        error.BadPageUrl => "page_url must be an http(s) URL without credentials",
        error.BadCandidateUrl => "candidate url must be an http(s) URL without credentials, at most 4096 bytes",
        error.BadKind => "candidate kind is not recognised",
        error.BadReferer => "candidate referer must be an http(s) URL",
        error.BadOrigin => "candidate origin must be scheme://host[:port]",
        error.BadUserAgent => "candidate ua must be printable and at most 512 bytes",
        error.OutOfMemory => "out of memory",
    };
}

const WireCandidate = struct {
    url: []const u8 = "",
    kind: []const u8 = "other",
    referer: []const u8 = "",
    origin: []const u8 = "",
    ua: []const u8 = "",
    duration: ?f64 = null,
};

const WireMedia = struct {
    page_url: []const u8 = "",
    title: []const u8 = "",
    art: []const u8 = "",
    action: []const u8 = "play",
    candidates: []const WireCandidate = &.{},
};

/// Parse and validate the `/api/browser/media` body. `arena` owns every
/// allocation; the returned slices stay valid until it is reset. An invalid
/// candidate fails the whole request: the extension only ever sends what it
/// classified itself, so one bad entry means a bug or a hostile caller, and
/// silently dropping it would hide that.
pub fn parseMedia(arena: std.mem.Allocator, body: []const u8) ParseError!Media {
    if (body.len > MAX_BODY) return error.BadJson;
    const wire = std.json.parseFromSliceLeaky(WireMedia, arena, body, .{
        .ignore_unknown_fields = true,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.BadJson;

    const action = Action.parse(wire.action) orelse return error.BadAction;
    // A stream is needed to play or queue one. Adding a title to Wanted involves
    // no stream, so candidates are optional there (and validated if present).
    if (wire.candidates.len == 0 and action != .add_to_wanted) return error.NoCandidates;
    if (wire.candidates.len > MAX_CANDIDATES) return error.TooManyCandidates;

    // The page URL is optional context (it is the Referer fallback), so an
    // absent one is fine; a present one must be sane.
    if (wire.page_url.len > 0) validateHttpUrl(wire.page_url, MAX_PAGE_URL) catch return error.BadPageUrl;

    const out = try arena.alloc(Candidate, wire.candidates.len);
    for (wire.candidates, out) |in, *dst| {
        validateHttpUrl(in.url, MAX_URL) catch return error.BadCandidateUrl;
        const kind = Kind.parse(in.kind) orelse return error.BadKind;
        if (in.referer.len > 0) validateHttpUrl(in.referer, MAX_REFERER) catch return error.BadReferer;
        if (in.origin.len > 0) validateOrigin(in.origin) catch return error.BadOrigin;
        if (!validHeaderValue(in.ua, MAX_UA)) return error.BadUserAgent;
        var duration = in.duration;
        if (duration) |d| {
            if (!std.math.isFinite(d) or d < 0 or d > 10_000_000) duration = null;
        }
        dst.* = .{
            .url = in.url,
            .kind = kind,
            .referer = in.referer,
            .origin = in.origin,
            .ua = in.ua,
            .duration = duration,
        };
    }

    const title_buf = try arena.alloc(u8, MAX_TITLE);
    // Artwork is decoration: an unusable URL drops the picture, not the play.
    var art: []const u8 = wire.art;
    if (art.len > 0) validateHttpUrl(art, MAX_ART) catch {
        art = "";
    };

    return .{
        .action = action,
        .page_url = wire.page_url,
        .title = sanitizeText(wire.title, title_buf),
        .art = art,
        .candidates = out,
    };
}

/// The candidate to act on: highest kind rank, first in the list on a tie.
pub fn best(candidates: []const Candidate) ?*const Candidate {
    if (candidates.len == 0) return null;
    var pick: usize = 0;
    for (candidates[1..], 1..) |c, i| {
        if (c.kind.rank() > candidates[pick].kind.rank()) pick = i;
    }
    return &candidates[pick];
}

// ── Headers handed to the player ───────────────────────────────────────────

pub const Header = struct { name: []const u8, value: []const u8 };

/// Storage for the strings `playHeaders` builds; must outlive the returned slice.
pub const HeaderBuf = struct {
    referer: [MAX_REFERER * 3]u8 = undefined,
    list: [2]Header = undefined,
};

/// mpv's `http-header-fields` is a comma separated list with no escaping, and
/// player.zig drops a whole header that contains a comma. A real Referer can
/// carry commas (`?ids=1,2`), and a dropped Referer is exactly the 403 this
/// feature exists to fix, so commas are written as `%2C` here. That is the same
/// URL to every server that parses the query, and not a character mpv can
/// misread. The fragment is removed the way browsers remove it from Referer.
pub fn encodeReferer(url: []const u8, out: []u8) ?[]const u8 {
    const no_fragment = if (std.mem.indexOfScalar(u8, url, '#')) |i| url[0..i] else url;
    var n: usize = 0;
    for (no_fragment) |ch| {
        if (ch == ',') {
            if (n + 3 > out.len) return null;
            out[n] = '%';
            out[n + 1] = '2';
            out[n + 2] = 'C';
            n += 3;
        } else {
            if (n >= out.len) return null;
            out[n] = ch;
            n += 1;
        }
    }
    return out[0..n];
}

/// Referer (the candidate's own, else the page that hosted it) and Origin (only
/// when the browser sent one: it does not for simple media loads, and inventing
/// one would change what the CDN sees). User-Agent is returned separately by the
/// caller from `candidate.ua`; the player substitutes its browser default.
pub fn playHeaders(c: Candidate, page_url: []const u8, buf: *HeaderBuf) []const Header {
    var count: usize = 0;
    const referer_src = if (c.referer.len > 0) c.referer else page_url;
    if (referer_src.len > 0) {
        if (encodeReferer(referer_src, &buf.referer)) |ref| {
            if (ref.len > 0) {
                buf.list[count] = .{ .name = "Referer", .value = ref };
                count += 1;
            }
        }
    }
    if (c.origin.len > 0) {
        buf.list[count] = .{ .name = "Origin", .value = c.origin };
        count += 1;
    }
    return buf.list[0..count];
}

// ── Pairing code ───────────────────────────────────────────────────────────

pub const CODE_LEN: usize = 6;
pub const CODE_TTL_S: i64 = 120;
pub const MAX_FAILS: u8 = 5;

pub const Pairing = struct {
    code: [CODE_LEN]u8 = @splat('0'),
    issued_at: i64 = 0,
    fails: u8 = 0,
    phase: enum { none, active, burned, used } = .none,
};

pub const Attempt = enum { ok, wrong_code, burned, expired, no_code };

/// Six digits from a uniformly random u32. The top slice of the u32 range that
/// would bias the modulo is rejected; the caller draws again on null.
pub fn codeFromRandom(r: u32) ?[CODE_LEN]u8 {
    const limit: u32 = 4_294_000_000; // largest multiple of 1_000_000 below 2^32
    if (r >= limit) return null;
    var n = r % 1_000_000;
    var out: [CODE_LEN]u8 = undefined;
    var i: usize = CODE_LEN;
    while (i > 0) {
        i -= 1;
        out[i] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
    return out;
}

/// A fresh code replaces any earlier one (and resets the failure count).
pub fn issue(p: *Pairing, now: i64, code: [CODE_LEN]u8) void {
    p.* = .{ .code = code, .issued_at = now, .fails = 0, .phase = .active };
}

pub fn cancel(p: *Pairing) void {
    p.* = .{};
}

/// Seconds the code is still usable; 0 when none, used, burned or expired.
pub fn remaining(p: *const Pairing, now: i64) i64 {
    if (p.phase != .active) return 0;
    const left = CODE_TTL_S - (now - p.issued_at);
    return if (left > 0) left else 0;
}

fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

/// Judge one pairing attempt. A correct code succeeds exactly once. Five wrong
/// guesses burn the code for good: the correct code is refused afterwards, so a
/// guesser gets five tries in 10^6 per code the user reads out, never more.
/// An expired code is cleared. The comparison is constant time.
pub fn attempt(p: *Pairing, now: i64, presented: []const u8) Attempt {
    switch (p.phase) {
        .none, .used => return .no_code,
        .burned => return .burned,
        .active => {},
    }
    if (remaining(p, now) == 0) {
        p.* = .{};
        return .expired;
    }
    // Hash-free but length-independent enough: compare against the code only
    // when the length is right, otherwise compare against a fixed filler so a
    // wrong-length guess takes the same path as a wrong-digit one.
    const same = if (presented.len == CODE_LEN)
        constantTimeEql(presented, &p.code)
    else blk: {
        _ = constantTimeEql(&p.code, &p.code);
        break :blk false;
    };
    if (same) {
        p.* = .{ .phase = .used };
        return .ok;
    }
    p.fails += 1;
    if (p.fails >= MAX_FAILS) {
        p.phase = .burned;
        p.code = @splat('0');
        return .burned;
    }
    return .wrong_code;
}

// ── Paired-browser token ───────────────────────────────────────────────────

pub const TOKEN_PREFIX = "opb_";
pub const TOKEN_RAW_LEN: usize = 32;
pub const TOKEN_LEN: usize = TOKEN_PREFIX.len + TOKEN_RAW_LEN * 2;
pub const HASH_HEX_LEN: usize = 64;

pub fn formatToken(raw: [TOKEN_RAW_LEN]u8) [TOKEN_LEN]u8 {
    var out: [TOKEN_LEN]u8 = undefined;
    @memcpy(out[0..TOKEN_PREFIX.len], TOKEN_PREFIX);
    const hex = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        out[TOKEN_PREFIX.len + i * 2] = hex[b >> 4];
        out[TOKEN_PREFIX.len + i * 2 + 1] = hex[b & 0x0f];
    }
    return out;
}

/// Cheap shape check so a machine token or a session token never costs a
/// database lookup in the browser-token branch of the bearer gate.
pub fn plausibleToken(token: []const u8) bool {
    if (token.len != TOKEN_LEN) return false;
    if (!std.mem.startsWith(u8, token, TOKEN_PREFIX)) return false;
    for (token[TOKEN_PREFIX.len..]) |ch| {
        if (!std.ascii.isHex(ch) or std.ascii.isUpper(ch)) return false;
    }
    return true;
}

/// Tokens are stored as SHA-256 hex. The token is 256 random bits, so a fast
/// hash is the right tool (nothing to brute force); a database leak does not
/// yield a usable credential.
pub fn hashToken(token: []const u8) [HASH_HEX_LEN]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    var out: [HASH_HEX_LEN]u8 = undefined;
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out;
}

/// Paired browsers kept at once. A bound keeps a stuck pairing loop from
/// growing the table, and nobody uses more than a handful.
pub const MAX_LINKS: usize = 8;

// ── Pairing request guards ─────────────────────────────────────────────────

/// `Host` must name this loopback listener. A DNS-rebinding page reaches the
/// socket with its own hostname in `Host`, so this refuses it even though the
/// TCP peer is local.
pub fn hostAllowed(host: ?[]const u8, port: u16) bool {
    const h = host orelse return false;
    var buf: [32]u8 = undefined;
    const ip4 = std.fmt.bufPrint(&buf, "127.0.0.1:{d}", .{port}) catch return false;
    if (std.mem.eql(u8, h, ip4)) return true;
    const ip6 = std.fmt.bufPrint(&buf, "[::1]:{d}", .{port}) catch return false;
    if (std.mem.eql(u8, h, ip6)) return true;
    const local = std.fmt.bufPrint(&buf, "localhost:{d}", .{port}) catch return false;
    return std.ascii.eqlIgnoreCase(h, local);
}

/// A web page's cross-origin POST carries `Origin: https://that.site` (or
/// `null` from a sandbox), and needs no CORS preflight for a simple body. That
/// would let any page guess pairing codes, so any Origin that is not an
/// extension is refused before the attempt is counted. No Origin at all (curl,
/// a native client) is fine: those still need the code.
pub fn pairOriginAllowed(origin: ?[]const u8) bool {
    const o = origin orelse return true;
    return std.mem.startsWith(u8, o, "chrome-extension://") or
        std.mem.startsWith(u8, o, "moz-extension://");
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "validateHttpUrl accepts http(s) including private and loopback hosts" {
    try validateHttpUrl("https://cdn.example.com/a/master.m3u8?token=abc", MAX_URL);
    try validateHttpUrl("HTTP://example.com/x.mp4", MAX_URL);
    // A stream on the LAN is the common case, not an attack: no SSRF filter here.
    try validateHttpUrl("http://192.168.1.20:8096/Videos/1/master.m3u8", MAX_URL);
    try validateHttpUrl("http://127.0.0.1:8000/stream.m3u8", MAX_URL);
    try validateHttpUrl("http://[::1]:8000/stream.m3u8", MAX_URL);
    try validateHttpUrl("http://nas.local/video.mkv", MAX_URL);
}

test "validateHttpUrl rejects other schemes" {
    for ([_][]const u8{
        "javascript:alert(1)",
        "file:///etc/passwd",
        "data:text/html;base64,AAAA",
        "blob:https://example.com/uuid",
        "ftp://example.com/a.mp4",
        "rtsp://example.com/live",
        "//example.com/a.mp4",
        "example.com/a.mp4",
        "https:example.com",
    }) |u| try testing.expectError(error.BadScheme, validateHttpUrl(u, MAX_URL));
    try testing.expectError(error.Empty, validateHttpUrl("", MAX_URL));
}

test "validateHttpUrl rejects embedded credentials in the authority only" {
    try testing.expectError(error.Credentials, validateHttpUrl("http://user:pass@example.com/a.mp4", MAX_URL));
    try testing.expectError(error.Credentials, validateHttpUrl("https://user@example.com/a.mp4", MAX_URL));
    try testing.expectError(error.Credentials, validateHttpUrl("http://example.com:80@evil.example/a.mp4", MAX_URL));
    // An at-sign later in the path or query is ordinary data.
    try validateHttpUrl("https://example.com/a@b.mp4", MAX_URL);
    try validateHttpUrl("https://example.com/watch?email=a@b.c", MAX_URL);
}

test "validateHttpUrl rejects control characters, spaces, backslash and an empty host" {
    try testing.expectError(error.BadChar, validateHttpUrl("https://example.com/a b.mp4", MAX_URL));
    try testing.expectError(error.BadChar, validateHttpUrl("https://example.com/a\r\nHost: x", MAX_URL));
    try testing.expectError(error.BadChar, validateHttpUrl("https://example.com/\x00", MAX_URL));
    try testing.expectError(error.BadChar, validateHttpUrl("https://example.com\\@evil.example/", MAX_URL));
    try testing.expectError(error.NoHost, validateHttpUrl("https:///a.mp4", MAX_URL));
    try testing.expectError(error.NoHost, validateHttpUrl("http://:8000/a.mp4", MAX_URL));
    try testing.expectError(error.NoHost, validateHttpUrl("https://?x=1", MAX_URL));
}

test "validateHttpUrl rejects an over-long URL instead of truncating it" {
    var buf: [MAX_URL + 8]u8 = undefined;
    @memset(&buf, 'a');
    @memcpy(buf[0.."https://example.com/".len], "https://example.com/");
    try validateHttpUrl(buf[0..MAX_URL], MAX_URL);
    try testing.expectError(error.TooLong, validateHttpUrl(buf[0 .. MAX_URL + 1], MAX_URL));
}

test "validateOrigin takes scheme and authority only" {
    try validateOrigin("https://player.example.com");
    try validateOrigin("http://127.0.0.1:8000");
    try testing.expectError(error.BadChar, validateOrigin("https://player.example.com/"));
    try testing.expectError(error.BadChar, validateOrigin("https://player.example.com/embed?x=1"));
    try testing.expectError(error.BadScheme, validateOrigin("null"));
    try testing.expectError(error.Credentials, validateOrigin("https://u:p@x.example"));
}

test "validHeaderValue refuses control characters and long values" {
    try testing.expect(validHeaderValue("Mozilla/5.0 (X11; Linux x86_64) Chrome/152.0.0.0", MAX_UA));
    try testing.expect(validHeaderValue("", MAX_UA));
    try testing.expect(!validHeaderValue("a\r\nX-Evil: 1", MAX_UA));
    try testing.expect(!validHeaderValue("a\nb", MAX_UA));
    try testing.expect(!validHeaderValue("a\x00b", MAX_UA));
    try testing.expect(!validHeaderValue("a\x7fb", MAX_UA));
    var long: [MAX_UA + 1]u8 = undefined;
    @memset(&long, 'x');
    try testing.expect(validHeaderValue(long[0..MAX_UA], MAX_UA));
    try testing.expect(!validHeaderValue(&long, MAX_UA));
}

test "sanitizeText replaces controls, trims and cuts on a UTF-8 boundary" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("a b c", sanitizeText("  a\nb\tc  ", &buf));
    try testing.expectEqualStrings("", sanitizeText("\x00\x01", &buf));
    var small: [5]u8 = undefined;
    // Four bytes of ASCII plus the first byte of a two-byte letter: cut cleanly.
    try testing.expectEqualStrings("abcd", sanitizeText("abcd\xc3\xa9", &small));
    try testing.expectEqualStrings("abc\xc3\xa9", sanitizeText("abc\xc3\xa9z", &small));
}

test "Kind.parse is closed and rank orders manifests above segments" {
    try testing.expectEqual(Kind.hls, Kind.parse("hls").?);
    try testing.expectEqual(Kind.dash, Kind.parse("dash").?);
    try testing.expect(Kind.parse("exe") == null);
    try testing.expect(Kind.parse("") == null);
    try testing.expect(Kind.hls.rank() > Kind.mp4.rank());
    try testing.expect(Kind.mp4.rank() > Kind.audio.rank());
    try testing.expect(Kind.audio.rank() > Kind.ts.rank());
}

test "parseMedia reads a full play request" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const m = try parseMedia(arena.allocator(),
        \\{"page_url":"https://site.example/watch/1","title":"Test pattern","art":"https://site.example/p.jpg",
        \\ "action":"play","candidates":[
        \\ {"url":"https://cdn.example/master.m3u8?t=1","kind":"hls","referer":"https://site.example/embed/1",
        \\  "origin":"https://site.example","ua":"Mozilla/5.0 Test","duration":12.5}]}
    );
    try testing.expectEqual(Action.play, m.action);
    try testing.expectEqualStrings("Test pattern", m.title);
    try testing.expectEqualStrings("https://site.example/p.jpg", m.art);
    try testing.expectEqual(@as(usize, 1), m.candidates.len);
    const c = m.candidates[0];
    try testing.expectEqual(Kind.hls, c.kind);
    try testing.expectEqualStrings("https://site.example/embed/1", c.referer);
    try testing.expectEqualStrings("https://site.example", c.origin);
    try testing.expectEqual(@as(f64, 12.5), c.duration.?);
}

test "parseMedia defaults: play action, optional fields empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const m = try parseMedia(arena.allocator(), "{\"candidates\":[{\"url\":\"http://h/a.mp4\",\"kind\":\"mp4\"}]}");
    try testing.expectEqual(Action.play, m.action);
    try testing.expectEqualStrings("", m.candidates[0].referer);
    try testing.expect(m.candidates[0].duration == null);
}

test "parseMedia rejects bad shapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.BadJson, parseMedia(a, ""));
    try testing.expectError(error.BadJson, parseMedia(a, "[1,2]"));
    try testing.expectError(error.BadJson, parseMedia(a, "{not json"));
    try testing.expectError(error.NoCandidates, parseMedia(a, "{\"candidates\":[]}"));
    try testing.expectError(error.NoCandidates, parseMedia(a, "{}"));
    try testing.expectError(error.BadAction, parseMedia(a, "{\"action\":\"download\",\"candidates\":[{\"url\":\"http://h/a.mp4\",\"kind\":\"mp4\"}]}"));
    try testing.expectError(error.BadKind, parseMedia(a, "{\"candidates\":[{\"url\":\"http://h/a.mp4\",\"kind\":\"exe\"}]}"));
}

test "parseMedia rejects hostile candidate fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.BadCandidateUrl, parseMedia(a, "{\"candidates\":[{\"url\":\"javascript:alert(1)\",\"kind\":\"mp4\"}]}"));
    try testing.expectError(error.BadCandidateUrl, parseMedia(a, "{\"candidates\":[{\"url\":\"file:///etc/passwd\",\"kind\":\"mp4\"}]}"));
    try testing.expectError(error.BadCandidateUrl, parseMedia(a, "{\"candidates\":[{\"url\":\"http://u:p@h/a.mp4\",\"kind\":\"mp4\"}]}"));
    try testing.expectError(error.BadReferer, parseMedia(a, "{\"candidates\":[{\"url\":\"http://h/a.mp4\",\"kind\":\"mp4\",\"referer\":\"javascript:1\"}]}"));
    try testing.expectError(error.BadOrigin, parseMedia(a, "{\"candidates\":[{\"url\":\"http://h/a.mp4\",\"kind\":\"mp4\",\"origin\":\"https://h/path\"}]}"));
    try testing.expectError(error.BadUserAgent, parseMedia(a, "{\"candidates\":[{\"url\":\"http://h/a.mp4\",\"kind\":\"mp4\",\"ua\":\"a\\r\\nX: y\"}]}"));
    try testing.expectError(error.BadPageUrl, parseMedia(a, "{\"page_url\":\"file:///x\",\"candidates\":[{\"url\":\"http://h/a.mp4\",\"kind\":\"mp4\"}]}"));
}

test "parseMedia bounds the candidate count and never reads past MAX_BODY" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    try body.appendSlice(testing.allocator, "{\"candidates\":[");
    for (0..MAX_CANDIDATES + 1) |i| {
        if (i > 0) try body.append(testing.allocator, ',');
        try body.appendSlice(testing.allocator, "{\"url\":\"http://h/a.mp4\",\"kind\":\"mp4\"}");
    }
    try body.appendSlice(testing.allocator, "]}");
    try testing.expectError(error.TooManyCandidates, parseMedia(a, body.items));

    const huge = try testing.allocator.alloc(u8, MAX_BODY + 1);
    defer testing.allocator.free(huge);
    @memset(huge, ' ');
    try testing.expectError(error.BadJson, parseMedia(a, huge));
}

test "parseMedia carries a 4000 byte tokenized URL without truncation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var url: [4000]u8 = undefined;
    @memset(&url, 'q');
    @memcpy(url[0.."https://cdn.example/master.m3u8?sig=".len], "https://cdn.example/master.m3u8?sig=");
    const body = try std.fmt.allocPrint(testing.allocator, "{{\"candidates\":[{{\"url\":\"{s}\",\"kind\":\"hls\"}}]}}", .{url});
    defer testing.allocator.free(body);
    const m = try parseMedia(arena.allocator(), body);
    try testing.expectEqualSlices(u8, &url, m.candidates[0].url);
}

test "parseMedia sanitizes the title and drops an unusable poster instead of failing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const m = try parseMedia(arena.allocator(),
        \\{"title":"Line one\nLine two\u0000","art":"javascript:alert(1)","candidates":[{"url":"http://h/a.mp4","kind":"mp4"}]}
    );
    try testing.expectEqualStrings("Line one Line two", m.title);
    try testing.expectEqualStrings("", m.art);
}

test "parseMedia ignores a non-finite or absurd duration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const m = try parseMedia(arena.allocator(), "{\"candidates\":[{\"url\":\"http://h/a.mp4\",\"kind\":\"mp4\",\"duration\":-5}]}");
    try testing.expect(m.candidates[0].duration == null);
}

test "best prefers a manifest, then the earliest on a tie" {
    const cands = [_]Candidate{
        .{ .url = "http://h/seg.ts", .kind = .ts },
        .{ .url = "http://h/a.mp4", .kind = .mp4 },
        .{ .url = "http://h/master.m3u8", .kind = .hls },
        .{ .url = "http://h/other.mpd", .kind = .dash },
    };
    try testing.expectEqualStrings("http://h/master.m3u8", best(&cands).?.url);
    try testing.expectEqualStrings("http://h/a.mp4", best(cands[0..2]).?.url);
    try testing.expect(best(&.{}) == null);
}

test "encodeReferer writes commas as %2C and drops the fragment" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("https://s.example/w?ids=1%2C2", encodeReferer("https://s.example/w?ids=1,2#frag", &buf).?);
    var tiny: [4]u8 = undefined;
    try testing.expect(encodeReferer("https://s.example/", &tiny) == null);
}

test "playHeaders: Referer falls back to the page, Origin only when given" {
    var buf: HeaderBuf = .{};
    const own = playHeaders(.{ .url = "http://h/a.m3u8", .kind = .hls, .referer = "https://embed.example/p/1", .origin = "https://embed.example" }, "https://site.example/w", &buf);
    try testing.expectEqual(@as(usize, 2), own.len);
    try testing.expectEqualStrings("Referer", own[0].name);
    try testing.expectEqualStrings("https://embed.example/p/1", own[0].value);
    try testing.expectEqualStrings("Origin", own[1].name);

    const fallback = playHeaders(.{ .url = "http://h/a.m3u8", .kind = .hls }, "https://site.example/w", &buf);
    try testing.expectEqual(@as(usize, 1), fallback.len);
    try testing.expectEqualStrings("https://site.example/w", fallback[0].value);

    const none = playHeaders(.{ .url = "http://h/a.m3u8", .kind = .hls }, "", &buf);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "playHeaders never emits a comma in a value" {
    var buf: HeaderBuf = .{};
    const hs = playHeaders(.{ .url = "http://h/a.m3u8", .kind = .hls, .referer = "https://e.example/a?x=1,2,3" }, "", &buf);
    try testing.expectEqual(@as(usize, 1), hs.len);
    try testing.expect(std.mem.indexOfScalar(u8, hs[0].value, ',') == null);
}

test "codeFromRandom: six digits, zero padded, biased tail rejected" {
    try testing.expectEqualStrings("000000", &codeFromRandom(0).?);
    try testing.expectEqualStrings("000042", &codeFromRandom(42).?);
    try testing.expectEqualStrings("999999", &codeFromRandom(999_999).?);
    try testing.expectEqualStrings("000001", &codeFromRandom(1_000_001).?);
    try testing.expect(codeFromRandom(4_294_000_000) == null);
    try testing.expect(codeFromRandom(std.math.maxInt(u32)) == null);
    try testing.expect(codeFromRandom(4_293_999_999) != null);
}

test "pairing: the right code works once" {
    var p: Pairing = .{};
    issue(&p, 1000, "123456".*);
    try testing.expectEqual(@as(i64, CODE_TTL_S), remaining(&p, 1000));
    try testing.expectEqual(Attempt.ok, attempt(&p, 1010, "123456"));
    // One-time: the same code cannot pair a second browser.
    try testing.expectEqual(Attempt.no_code, attempt(&p, 1011, "123456"));
    try testing.expectEqual(@as(i64, 0), remaining(&p, 1011));
}

test "pairing: no code issued" {
    var p: Pairing = .{};
    try testing.expectEqual(Attempt.no_code, attempt(&p, 5, "000000"));
}

test "pairing: expires after 120 seconds and is cleared" {
    var p: Pairing = .{};
    issue(&p, 1000, "123456".*);
    try testing.expectEqual(@as(i64, 1), remaining(&p, 1000 + CODE_TTL_S - 1));
    try testing.expectEqual(Attempt.expired, attempt(&p, 1000 + CODE_TTL_S, "123456"));
    try testing.expectEqual(Attempt.no_code, attempt(&p, 1000 + CODE_TTL_S + 1, "123456"));
}

test "pairing: still valid one second before expiry" {
    var p: Pairing = .{};
    issue(&p, 1000, "123456".*);
    try testing.expectEqual(Attempt.ok, attempt(&p, 1000 + CODE_TTL_S - 1, "123456"));
}

test "pairing: four wrong guesses then the right code still works" {
    var p: Pairing = .{};
    issue(&p, 0, "123456".*);
    for (0..4) |_| try testing.expectEqual(Attempt.wrong_code, attempt(&p, 1, "000000"));
    try testing.expectEqual(Attempt.ok, attempt(&p, 2, "123456"));
}

test "pairing: five wrong guesses burn the code, even for the right code" {
    var p: Pairing = .{};
    issue(&p, 0, "123456".*);
    for (0..4) |_| try testing.expectEqual(Attempt.wrong_code, attempt(&p, 1, "000000"));
    try testing.expectEqual(Attempt.burned, attempt(&p, 1, "000000"));
    try testing.expectEqual(Attempt.burned, attempt(&p, 2, "123456"));
    try testing.expectEqual(@as(i64, 0), remaining(&p, 2));
    // The burned state does not reveal the code.
    try testing.expectEqualStrings("000000", &p.code);
}

test "pairing: a wrong-length or non-digit guess counts as a failure" {
    var p: Pairing = .{};
    issue(&p, 0, "123456".*);
    try testing.expectEqual(Attempt.wrong_code, attempt(&p, 1, ""));
    try testing.expectEqual(Attempt.wrong_code, attempt(&p, 1, "12345"));
    try testing.expectEqual(Attempt.wrong_code, attempt(&p, 1, "1234567"));
    try testing.expectEqual(Attempt.wrong_code, attempt(&p, 1, "12345a"));
    try testing.expectEqual(@as(u8, 4), p.fails);
}

test "pairing: issuing a new code resets failures and replaces the old code" {
    var p: Pairing = .{};
    issue(&p, 0, "111111".*);
    for (0..5) |_| _ = attempt(&p, 1, "000000");
    try testing.expectEqual(Attempt.burned, attempt(&p, 2, "111111"));
    issue(&p, 10, "222222".*);
    try testing.expectEqual(Attempt.wrong_code, attempt(&p, 11, "111111"));
    try testing.expectEqual(Attempt.ok, attempt(&p, 12, "222222"));
}

test "pairing: cancel clears the code" {
    var p: Pairing = .{};
    issue(&p, 0, "123456".*);
    cancel(&p);
    try testing.expectEqual(Attempt.no_code, attempt(&p, 1, "123456"));
}

test "token format, shape check and hashing" {
    const raw: [TOKEN_RAW_LEN]u8 = @splat(0xab);
    const tok = formatToken(raw);
    try testing.expectEqual(@as(usize, TOKEN_LEN), tok.len);
    try testing.expect(std.mem.startsWith(u8, &tok, "opb_"));
    try testing.expect(plausibleToken(&tok));

    try testing.expect(!plausibleToken(""));
    try testing.expect(!plausibleToken("opb_abc"));
    try testing.expect(!plausibleToken("0123456789abcdef0123456789abcdef0123456789abcdef")); // session token shape
    var upper = tok;
    upper[10] = 'A';
    try testing.expect(!plausibleToken(&upper));
    var bad_prefix = tok;
    bad_prefix[0] = 'x';
    try testing.expect(!plausibleToken(&bad_prefix));

    const h1 = hashToken(&tok);
    const h2 = hashToken(&tok);
    try testing.expectEqualSlices(u8, &h1, &h2);
    try testing.expect(!std.mem.eql(u8, &h1, &tok));
    try testing.expect(std.mem.indexOf(u8, &h1, tok[4..20]) == null);
    var other = tok;
    other[TOKEN_LEN - 1] = if (other[TOKEN_LEN - 1] == 'f') 'e' else 'f';
    try testing.expect(!std.mem.eql(u8, &h1, &hashToken(&other)));
}

test "hashToken matches a known SHA-256 vector" {
    // sha256("abc")
    const h = hashToken("abc");
    try testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &h);
}

test "hostAllowed: only this loopback listener" {
    try testing.expect(hostAllowed("127.0.0.1:41595", 41595));
    try testing.expect(hostAllowed("localhost:41595", 41595));
    try testing.expect(hostAllowed("LOCALHOST:41595", 41595));
    try testing.expect(hostAllowed("[::1]:41595", 41595));
    try testing.expect(!hostAllowed(null, 41595));
    try testing.expect(!hostAllowed("", 41595));
    try testing.expect(!hostAllowed("evil.example:41595", 41595));
    try testing.expect(!hostAllowed("127.0.0.1.evil.example:41595", 41595));
    try testing.expect(!hostAllowed("127.0.0.1:41596", 41595));
    try testing.expect(!hostAllowed("192.168.1.5:41595", 41595));
    try testing.expect(!hostAllowed("127.0.0.1", 41595));
}

test "pairOriginAllowed: extensions and native clients, never web pages" {
    try testing.expect(pairOriginAllowed(null));
    try testing.expect(pairOriginAllowed("chrome-extension://abcdefghijklmnopabcdefghijklmnop"));
    try testing.expect(pairOriginAllowed("moz-extension://0f2d6f2e-0000-4000-8000-000000000000"));
    try testing.expect(!pairOriginAllowed("https://evil.example"));
    try testing.expect(!pairOriginAllowed("http://127.0.0.1:41595"));
    try testing.expect(!pairOriginAllowed("null"));
    try testing.expect(!pairOriginAllowed(""));
    try testing.expect(!pairOriginAllowed("https://chrome-extension://x"));
}

test "add_to_wanted needs no candidate, play and queue still do, a present candidate is still validated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = try parseMedia(a, "{\"action\":\"add_to_wanted\",\"title\":\"  Dune 2021 \"}");
    try std.testing.expectEqual(Action.add_to_wanted, w.action);
    try std.testing.expectEqualStrings("Dune 2021", w.title);
    try std.testing.expectEqual(@as(usize, 0), w.candidates.len);
    try std.testing.expectError(error.NoCandidates, parseMedia(a, "{\"action\":\"play\",\"title\":\"x\"}"));
    try std.testing.expectError(error.NoCandidates, parseMedia(a, "{\"action\":\"queue\",\"title\":\"x\"}"));
    try std.testing.expectError(error.BadCandidateUrl, parseMedia(a, "{\"action\":\"add_to_wanted\",\"title\":\"x\",\"candidates\":[{\"url\":\"file:///etc/passwd\",\"kind\":\"mp4\"}]}"));
    try std.testing.expectError(error.BadAction, parseMedia(a, "{\"action\":\"download\",\"title\":\"x\"}"));
    try std.testing.expectEqual(@as(?Action, .add_to_wanted), Action.parse("add_to_wanted"));
}
