//! Anime video extractors — the pure "lib/" layer (Aniyomi-style).
//!
//! A streaming host serves an EMBED page whose real playable stream (m3u8/mp4)
//! is hidden behind a packed script, a token dance, or a signed AJAX call. These
//! are the *pure string/JSON* halves of the per-host extractors: given the
//! already-fetched HTML/JSON they return the direct stream URL (+ referer + subs)
//! with no I/O of their own. `anime_extractors.zig` does the fetching and routes
//! every decision through here so the tested logic IS the shipped logic.
//!
//! Hosts covered: StreamWish / Filemoon / VidHide (packed → m3u8), Mp4Upload
//! (packed → mp4), StreamTape (two-part token), DoodStream (pass_md5 dance),
//! MegaCloud / HiAnime (getSources AJAX with a scraped `_k` nonce, plaintext
//! sources — no AES needed).
//!
//! Hosts we DELEGATE to mpv's ytdl-hook (yt-dlp already nails them, so we do NOT
//! reimplement): youtube, dailymotion, ok.ru, vk, sibnet. See classifyHost().

const std = @import("std");

// ── The P.A.C.K.E.R unpacker (Dean Edwards `eval(function(p,a,c,k,e,d){…})`) ──
//
// Unlocks StreamWish, Filemoon, VidHide and Mp4Upload at once — they all serve a
// packed `<script>` whose unpacked form holds the stream URL. The algorithm:
// split the `|`-delimited symbol table, then substitute every whole-word base-`a`
// token in the payload with its symbol. We tokenize the payload once (single
// pass) and substitute inline — equivalent to the reference `\bTOKEN\b` replace
// loop but O(len) instead of O(len·count).

/// Max symbols we index on the stack (each is a slice = 16B → ≤ 48KB). Real
/// anime-host payloads sit in the low hundreds; a payload with more tokens than
/// this is refused (the driver then falls back) rather than blow the worker
/// stack.
pub const MAX_SYMBOLS = 3000;

fn isWordChar(ch: u8) bool {
    return (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'z') or
        (ch >= 'A' and ch <= 'Z') or ch == '_';
}

/// Base-62 digit value of a symbol char, matching JS `toString(a)` extended by
/// the packer's high-radix encoder: 0-9 → 0-9, a-z → 10-35, A-Z → 36-61.
fn digitVal(ch: u8) ?u16 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'z') return @as(u16, ch - 'a') + 10;
    if (ch >= 'A' and ch <= 'Z') return @as(u16, ch - 'A') + 36;
    return null;
}

/// Canonical base-`a` encoding of `n` (no leading zeros). Mirrors the packer's
/// `e(c)` encoder so we can verify a payload word is the *exact* token the packer
/// would have emitted (rejects "01", "00", … that decode to a small value but
/// were never produced as tokens).
fn encodeToken(n_in: usize, base: u16, buf: []u8) []const u8 {
    if (n_in == 0) {
        if (buf.len == 0) return buf[0..0];
        buf[0] = '0';
        return buf[0..1];
    }
    var tmp: [16]u8 = undefined;
    var i: usize = 0;
    var n = n_in;
    while (n > 0 and i < tmp.len) : (i += 1) {
        const d: usize = @intCast(n % base);
        tmp[i] = if (d < 10) @as(u8, '0') + @as(u8, @intCast(d)) else if (d < 36)
            @as(u8, 'a') + @as(u8, @intCast(d - 10))
        else
            @as(u8, 'A') + @as(u8, @intCast(d - 36));
        n /= base;
    }
    // tmp holds the digits reversed
    var out_len: usize = 0;
    while (i > 0 and out_len < buf.len) {
        i -= 1;
        buf[out_len] = tmp[i];
        out_len += 1;
    }
    return buf[0..out_len];
}

/// Decode a payload word to its numeric token value in `base`, or null if any
/// char is not a base-`base` digit (→ not a token, keep verbatim).
fn decodeToken(word: []const u8, base: u16) ?usize {
    if (word.len == 0) return null;
    var val: usize = 0;
    for (word) |ch| {
        const d = digitVal(ch) orelse return null;
        if (d >= base) return null;
        val = val *% base + d;
    }
    return val;
}

/// Read a JS single/double-quoted string literal starting at `text[i]` (a quote),
/// unescaping into `out`. Returns the unescaped content and the index just past
/// the closing quote, or null on an unterminated literal.
fn readStringLiteral(text: []const u8, i: usize, out: []u8) ?struct { content: []const u8, next: usize } {
    if (i >= text.len) return null;
    const quote = text[i];
    if (quote != '\'' and quote != '"') return null;
    var p = i + 1;
    var w: usize = 0;
    while (p < text.len) {
        const ch = text[p];
        if (ch == '\\' and p + 1 < text.len) {
            const nx = text[p + 1];
            const dec: u8 = switch (nx) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                'b' => 8,
                'f' => 12,
                else => nx, // \/ \\ \' \" and anything else → the char itself
            };
            if (w >= out.len) return null;
            out[w] = dec;
            w += 1;
            p += 2;
            continue;
        }
        if (ch == quote) {
            return .{ .content = out[0..w], .next = p + 1 };
        }
        if (w >= out.len) return null;
        out[w] = ch;
        w += 1;
        p += 1;
    }
    return null;
}

/// Locate the packer invocation payload region `}('…',a,c,'…'.split('|'),…)`.
/// Returns the index of the payload string literal's opening quote.
fn findPackerInvocation(js: []const u8) ?usize {
    // The unique anchor is the function-body close immediately invoking itself:
    // `…return p}(` followed (after optional spaces) by the payload quote.
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, js, search, "}(")) |at| {
        var q = at + 2;
        while (q < js.len and (js[q] == ' ' or js[q] == '\n' or js[q] == '\r' or js[q] == '\t')) : (q += 1) {}
        if (q < js.len and (js[q] == '\'' or js[q] == '"')) return q;
        search = at + 2;
    }
    return null;
}

/// Unpack a Dean-Edwards P.A.C.K.E.R payload found anywhere in `js` into `out`.
/// `sym_buf` is scratch for the unescaped symbol table. Returns the unpacked JS
/// (a slice of `out`) or null if `js` holds no recognizable packed block.
pub fn unpackPacked(js: []const u8, out: []u8, sym_buf: []u8) ?[]const u8 {
    // Must actually look packed — cheap guard so we don't mis-parse arbitrary JS.
    if (std.mem.indexOf(u8, js, "}(") == null) return null;

    const payload_q = findPackerInvocation(js) orelse return null;
    // Find the raw payload bounds; we substitute from the RAW bytes so escapes are
    // handled inline during tokenization.
    const payload_quote = js[payload_q];
    var pp = payload_q + 1;
    while (pp < js.len) {
        if (js[pp] == '\\') {
            pp += 2;
            continue;
        }
        if (js[pp] == payload_quote) break;
        pp += 1;
    }
    if (pp >= js.len) return null;
    const payload_raw = js[payload_q + 1 .. pp]; // still escaped
    var cur = pp + 1; // just past payload closing quote

    // ,BASE,COUNT,
    const base = parseCommaInt(js, &cur) orelse return null;
    const count = parseCommaInt(js, &cur) orelse return null;
    if (base < 2 or base > 62) return null;
    if (count > MAX_SYMBOLS) return null;

    // ,'SYMBOLS'.split('|')
    while (cur < js.len and (js[cur] == ',' or js[cur] == ' ')) : (cur += 1) {}
    if (cur >= js.len or (js[cur] != '\'' and js[cur] != '"')) return null;
    const syms = readStringLiteral(js, cur, sym_buf) orelse return null;

    // Split the (unescaped) symbol table on '|'.
    var k: [MAX_SYMBOLS][]const u8 = undefined;
    var kn: usize = 0;
    var it = std.mem.splitScalar(u8, syms.content, '|');
    while (it.next()) |s| {
        if (kn >= MAX_SYMBOLS) break;
        k[kn] = s;
        kn += 1;
    }

    // Tokenize the raw payload once, substituting whole-word tokens.
    var w: usize = 0; // write cursor into out
    var word_start: usize = 0;
    var in_word = false;
    var i: usize = 0;
    while (i < payload_raw.len) {
        const ch = payload_raw[i];
        if (ch == '\\' and i + 1 < payload_raw.len) {
            // Escape breaks any word run, then emits the unescaped char literally.
            if (in_word) {
                w = flushWord(payload_raw[word_start..i], base, count, k[0..kn], out, w) orelse return null;
                in_word = false;
            }
            const nx = payload_raw[i + 1];
            const dec: u8 = switch (nx) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                'b' => 8,
                'f' => 12,
                else => nx,
            };
            if (w >= out.len) return null;
            out[w] = dec;
            w += 1;
            i += 2;
            continue;
        }
        if (isWordChar(ch)) {
            if (!in_word) {
                in_word = true;
                word_start = i;
            }
            i += 1;
            continue;
        }
        if (in_word) {
            w = flushWord(payload_raw[word_start..i], base, count, k[0..kn], out, w) orelse return null;
            in_word = false;
        }
        if (w >= out.len) return null;
        out[w] = ch;
        w += 1;
        i += 1;
    }
    if (in_word) {
        w = flushWord(payload_raw[word_start..payload_raw.len], base, count, k[0..kn], out, w) orelse return null;
    }
    return out[0..w];
}

/// Emit one payload word into `out`, substituting it with its symbol when it is
/// the canonical base-`base` token for an index < `count` with a non-empty
/// symbol. Returns the new write cursor, or null on overflow.
fn flushWord(word: []const u8, base: u16, count: usize, k: []const []const u8, out: []u8, w_in: usize) ?usize {
    var w = w_in;
    var replacement: ?[]const u8 = null;
    if (decodeToken(word, base)) |val| {
        if (val < count and val < k.len and k[val].len > 0) {
            var enc_buf: [16]u8 = undefined;
            const canon = encodeToken(val, base, &enc_buf);
            if (std.mem.eql(u8, canon, word)) replacement = k[val];
        }
    }
    const emit = replacement orelse word;
    if (w + emit.len > out.len) return null;
    @memcpy(out[w .. w + emit.len], emit);
    w += emit.len;
    return w;
}

/// Parse `,<int>` starting at `js[cur.*]` (skipping spaces around the comma),
/// advancing `cur` past the integer. Returns the value.
fn parseCommaInt(js: []const u8, cur: *usize) ?u16 {
    var p = cur.*;
    while (p < js.len and (js[p] == ' ' or js[p] == ',' or js[p] == '\n' or js[p] == '\r' or js[p] == '\t')) : (p += 1) {}
    if (p >= js.len or js[p] < '0' or js[p] > '9') return null;
    var val: u32 = 0;
    while (p < js.len and js[p] >= '0' and js[p] <= '9') : (p += 1) {
        val = val * 10 + (js[p] - '0');
        if (val > 100_000) return null;
    }
    cur.* = p;
    return @intCast(val);
}

// ── Generic URL scraping ──────────────────────────────────────────────────

fn isUrlDelim(ch: u8) bool {
    return switch (ch) {
        '"', '\'', '\\', ' ', '\n', '\r', '\t', ')', '(', '<', '>', '|', '`', ']', '}', 0 => true,
        else => false,
    };
}

/// Find the first `http(s)://…` URL in `text` that contains `needle` (e.g.
/// ".m3u8" or ".mp4"), copying it into `out`. Returns the copied slice.
pub fn extractUrlContaining(text: []const u8, needle: []const u8, out: []u8) ?[]const u8 {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, text, search, "http")) |h| {
        const rest = text[h..];
        if (!std.mem.startsWith(u8, rest, "http://") and !std.mem.startsWith(u8, rest, "https://")) {
            search = h + 4;
            continue;
        }
        var e = h;
        while (e < text.len and !isUrlDelim(text[e])) : (e += 1) {}
        const url = text[h..e];
        if (std.mem.indexOf(u8, url, needle) != null) {
            if (url.len > out.len) return null;
            @memcpy(out[0..url.len], url);
            return out[0..url.len];
        }
        search = if (e > h) e else h + 4;
    }
    return null;
}

// ── URL host helpers ──────────────────────────────────────────────────────

/// scheme://host (no path, no trailing slash). e.g.
/// "https://streamwish.to/e/abc" → "https://streamwish.to".
pub fn schemeHostOf(url: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, url, "://") orelse return null;
    const host_start = sep + 3;
    var e = host_start;
    while (e < url.len and url[e] != '/' and url[e] != '?' and url[e] != '#') : (e += 1) {}
    return url[0..e];
}

/// Bare host (no scheme). "https://d000d.com/e/x" → "d000d.com".
pub fn hostOf(url: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, url, "://") orelse return null;
    const host_start = sep + 3;
    var e = host_start;
    while (e < url.len and url[e] != '/' and url[e] != '?' and url[e] != '#') : (e += 1) {}
    return url[host_start..e];
}

/// Referer value for a host: scheme://host/  (trailing slash — what the CDNs
/// expect). Writes into `out`.
pub fn refererFor(embed_url: []const u8, out: []u8) ?[]const u8 {
    const sh = schemeHostOf(embed_url) orelse return null;
    if (sh.len + 1 > out.len) return null;
    @memcpy(out[0..sh.len], sh);
    out[sh.len] = '/';
    return out[0 .. sh.len + 1];
}

// ── Host classification + yt-dlp delegation ───────────────────────────────

pub const Host = enum {
    streamwish,
    filemoon,
    vidhide,
    mp4upload,
    streamtape,
    doodstream,
    megacloud,
    /// Handled well by mpv's ytdl-hook (yt-dlp) — pass the embed URL straight to
    /// mpv, do NOT reimplement. youtube / dailymotion / ok.ru / vk / sibnet.
    delegate_ytdlp,
    unknown,
};

fn hostContainsAny(host: []const u8, comptime needles: []const []const u8) bool {
    inline for (needles) |n| {
        if (std.mem.indexOf(u8, host, n) != null) return true;
    }
    return false;
}

/// Classify an embed URL by its host. Substring match on the hostname so mirror
/// domains (streamwish.to / wishfast.top / …) all route to one extractor.
pub fn classifyHost(url: []const u8) Host {
    const host = hostOf(url) orelse return .unknown;

    // yt-dlp handles these — delegate (checked first so a mirror can't be
    // shadowed by a broad host match below).
    if (hostContainsAny(host, &.{
        "youtube.com", "youtu.be",       "youtube-nocookie",
        "dailymotion.com", "dai.ly",      "ok.ru",
        "odnoklassniki",   "vk.com",      "vkvideo",
        "userapi.com",     "sibnet.ru",
    })) return .delegate_ytdlp;

    if (hostContainsAny(host, &.{ "megacloud", "rapid-cloud", "rabbitstream", "megaplay", "vidwish" }))
        return .megacloud;
    if (hostContainsAny(host, &.{ "streamwish", "wishfast", "sfastwish", "swiftplayers", "hlswish", "embedwish", "wishonly", "playerwish", "wishembed", "mwish", "dwish", "awish", "obeywish", "flaswish", "cdnwish", "jwplayerhls" }))
        return .streamwish;
    if (hostContainsAny(host, &.{ "filemoon", "moonplayer", "kerapoxy", "moviesm4u", "1azayf9w", "furher.in" }))
        return .filemoon;
    if (hostContainsAny(host, &.{ "vidhide", "smoothpre", "vidhidepro", "vidhidevip", "nisafevid", "dhcplay", "vid-guard", "vidguard" }))
        return .vidhide;
    if (hostContainsAny(host, &.{"mp4upload"}))
        return .mp4upload;
    if (hostContainsAny(host, &.{ "streamtape", "strtape", "streamta.pe", "shavetape", "stape", "streamadblocker", "tapewithadblock" }))
        return .streamtape;
    if (hostContainsAny(host, &.{ "dood", "d000d", "d-s.io", "dooood", "ds2play", "doods", "vidply", "d0000d" }))
        return .doodstream;

    return .unknown;
}

/// Should this embed be handed straight to mpv/ytdl-hook instead of extracted?
pub fn shouldDelegateToYtdlp(url: []const u8) bool {
    return classifyHost(url) == .delegate_ytdlp;
}

// ── StreamTape ─────────────────────────────────────────────────────────────

/// StreamTape hides the URL as `partA' + ('partB').substring(N)`. Join partA
/// with partB[N..] and prepend the scheme. Writes into `out`.
pub fn extractStreamTape(html: []const u8, out: []u8) ?[]const u8 {
    // Anchor on the robotlink element (there is also an `ideoolink` decoy sibling
    // used by some skins — either works, both feed the same innerHTML pattern).
    const anchor = std.mem.indexOf(u8, html, "robotlink") orelse
        std.mem.indexOf(u8, html, "ideoolink") orelse return null;
    const ih = std.mem.indexOfPos(u8, html, anchor, "innerHTML") orelse return null;

    // partA — first single-quoted string after innerHTML.
    const q1 = std.mem.indexOfScalarPos(u8, html, ih, '\'') orelse return null;
    const q1e = std.mem.indexOfScalarPos(u8, html, q1 + 1, '\'') orelse return null;
    const part_a = html[q1 + 1 .. q1e];

    // partB — next single-quoted string.
    const q2 = std.mem.indexOfScalarPos(u8, html, q1e + 1, '\'') orelse return null;
    const q2e = std.mem.indexOfScalarPos(u8, html, q2 + 1, '\'') orelse return null;
    const part_b = html[q2 + 1 .. q2e];

    // .substring(N)
    var n: usize = 0;
    if (std.mem.indexOfPos(u8, html, q2e, "substring(")) |si| {
        var p = si + "substring(".len;
        while (p < html.len and html[p] >= '0' and html[p] <= '9') : (p += 1) {
            n = n * 10 + (html[p] - '0');
        }
    }
    const tail = if (n <= part_b.len) part_b[n..] else part_b;

    // Join, prefixing scheme when the URL is protocol-relative.
    var w: usize = 0;
    const prefix: []const u8 = if (std.mem.startsWith(u8, part_a, "//")) "https:" else "";
    if (prefix.len + part_a.len + tail.len > out.len) return null;
    @memcpy(out[w .. w + prefix.len], prefix);
    w += prefix.len;
    @memcpy(out[w .. w + part_a.len], part_a);
    w += part_a.len;
    @memcpy(out[w .. w + tail.len], tail);
    w += tail.len;
    if (std.mem.indexOf(u8, out[0..w], "get_video") == null) return null; // sanity
    return out[0..w];
}

// ── DoodStream ─────────────────────────────────────────────────────────────

/// Extract the `/pass_md5/<path>` value (the part AFTER `/pass_md5/`) from a
/// Dood embed page.
pub fn extractDoodPath(html: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, html, "/pass_md5/") orelse return null;
    const start = at + "/pass_md5/".len;
    var e = start;
    while (e < html.len and html[e] != '"' and html[e] != '\'' and html[e] != '\\' and
        html[e] != ' ' and html[e] != '\n' and html[e] != '\r' and html[e] != '<') : (e += 1)
    {}
    if (e == start) return null;
    return html[start..e];
}

/// The Dood token = the last path segment of the pass_md5 path.
pub fn doodToken(pass_path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, pass_path, '/')) |s| return pass_path[s + 1 ..];
    return pass_path;
}

/// Deterministic 10-char [A-Za-z0-9] token derived from `seed` (Dood's client
/// appends a random 10-char string; the server does not validate its content, so
/// a deterministic hash is functionally equivalent and keeps the extractor pure).
pub fn doodRandomToken(seed: []const u8) [10]u8 {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    var h = std.hash.Wyhash.init(0x0D00D5EED);
    h.update(seed);
    var state = h.final();
    var out: [10]u8 = undefined;
    for (&out) |*c| {
        c.* = alphabet[@intCast(state % alphabet.len)];
        state = (state *% 6364136223846793005) +% 1442695040888963407;
    }
    return out;
}

/// Assemble the final Dood mp4 URL:
///   base_response ++ random10 ++ "?token=" ++ token ++ "&expiry=" ++ expiry_ms
pub fn assembleDoodUrl(base_response: []const u8, random10: []const u8, token: []const u8, expiry_ms: i64, out: []u8) ?[]const u8 {
    // Base response may carry trailing whitespace/newline from the HTTP body.
    var base = base_response;
    while (base.len > 0 and (base[base.len - 1] == '\n' or base[base.len - 1] == '\r' or base[base.len - 1] == ' ')) {
        base = base[0 .. base.len - 1];
    }
    return std.fmt.bufPrint(out, "{s}{s}?token={s}&expiry={d}", .{ base, random10, token, expiry_ms }) catch null;
}

// ── MegaCloud / HiAnime ────────────────────────────────────────────────────

/// sourceId = last path segment of the embed URL (query stripped).
/// "https://megacloud.blog/embed-2/e-1/aBcD1234?k=1" → "aBcD1234".
pub fn megacloudSourceId(embed_url: []const u8) ?[]const u8 {
    var u = embed_url;
    if (std.mem.indexOfScalar(u8, u, '?')) |q| u = u[0..q];
    if (std.mem.indexOfScalar(u8, u, '#')) |h| u = u[0..h];
    // trim a trailing slash
    while (u.len > 0 and u[u.len - 1] == '/') u = u[0 .. u.len - 1];
    const s = std.mem.lastIndexOfScalar(u8, u, '/') orelse return null;
    const id = u[s + 1 ..];
    if (id.len == 0) return null;
    return id;
}

fn isAlnum(ch: u8) bool {
    return (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
}

/// Longest run of [A-Za-z0-9] starting at `i`.
fn alnumRunLen(html: []const u8, i: usize) usize {
    var e = i;
    while (e < html.len and isAlnum(html[e])) : (e += 1) {}
    return e - i;
}

/// Scrape the MegaCloud `_k` nonce from the embed HTML. Tries, in order:
///   1. a lone 48-char [A-Za-z0-9] run,
///   2. three 16-char [A-Za-z0-9] runs → concatenated (48 chars),
///   3. `_x = "…"` / `nonce = "…"` string ≥ 32 chars.
/// Writes the (≤48-char) key into `out`.
pub fn megacloudNonce(html: []const u8, out: []u8) ?[]const u8 {
    // (1) a single isolated 48-char run.
    {
        var i: usize = 0;
        while (i < html.len) {
            if (isAlnum(html[i])) {
                const run = alnumRunLen(html, i);
                if (run == 48) {
                    if (out.len < 48) return null;
                    @memcpy(out[0..48], html[i .. i + 48]);
                    return out[0..48];
                }
                i += run;
            } else i += 1;
        }
    }
    // (2) three separate 16-char runs → join.
    {
        var joined: usize = 0;
        var found: usize = 0;
        var i: usize = 0;
        while (i < html.len and found < 3) {
            if (isAlnum(html[i])) {
                const run = alnumRunLen(html, i);
                if (run == 16) {
                    if (joined + 16 > out.len) return null;
                    @memcpy(out[joined .. joined + 16], html[i .. i + 16]);
                    joined += 16;
                    found += 1;
                }
                i += run;
            } else i += 1;
        }
        if (found == 3) return out[0..joined];
    }
    // (3) `_x = "…"` / `nonce="…"` / `_k="…"`.
    inline for (.{ "_x", "nonce", "_k" }) |name| {
        if (std.mem.indexOf(u8, html, name)) |at| {
            if (std.mem.indexOfScalarPos(u8, html, at, '"')) |q| {
                const start = q + 1;
                var e = start;
                while (e < html.len and html[e] != '"') : (e += 1) {}
                const v = html[start..e];
                if (v.len >= 32 and v.len <= out.len) {
                    @memcpy(out[0..v.len], v);
                    return out[0..v.len];
                }
            }
        }
    }
    return null;
}

/// Build the getSources AJAX URL:
///   {scheme://host}/embed-2/ajax/e-1/getSources?id=<sourceId>&_k=<key>
pub fn megacloudGetSourcesUrl(embed_url: []const u8, source_id: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    const sh = schemeHostOf(embed_url) orelse return null;
    return std.fmt.bufPrint(out, "{s}/embed-2/ajax/e-1/getSources?id={s}&_k={s}", .{ sh, source_id, key }) catch null;
}

pub const Track = struct {
    url: [512]u8 = undefined,
    url_len: usize = 0,
    label: [64]u8 = undefined,
    label_len: usize = 0,
};

pub const GetSources = struct {
    stream_url: [1024]u8 = undefined,
    stream_len: usize = 0,
    encrypted: bool = false,
    tracks: [8]Track = undefined,
    track_count: usize = 0,

    pub fn streamUrl(self: *const GetSources) []const u8 {
        return self.stream_url[0..self.stream_len];
    }
};

/// Find `"<key>":"<value>"` inside `obj`, returning the value slice.
fn jsonStrField(obj: []const u8, key_quoted: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, obj, key_quoted) orelse return null;
    var p = at + key_quoted.len;
    while (p < obj.len and (obj[p] == ' ' or obj[p] == ':')) : (p += 1) {}
    if (p >= obj.len or obj[p] != '"') return null;
    p += 1;
    const start = p;
    while (p < obj.len and obj[p] != '"') {
        if (obj[p] == '\\') {
            p += 2;
            continue;
        }
        p += 1;
    }
    return obj[start..p];
}

/// Copy a JSON string value, collapsing the escaped-slash `\/` that JSON encoders
/// emit for URLs, into `out`.
fn copyJsonUrl(v: []const u8, out: []u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < v.len and w < out.len) {
        if (v[i] == '\\' and i + 1 < v.len) {
            out[w] = v[i + 1];
            w += 1;
            i += 2;
            continue;
        }
        out[w] = v[i];
        w += 1;
        i += 1;
    }
    return w;
}

/// Parse a MegaCloud getSources JSON response. Extracts sources[0].file, the
/// `encrypted` flag (caller SKIPS on true — no AES here), and caption tracks.
pub fn parseGetSources(json: []const u8) ?GetSources {
    var g = GetSources{};

    // encrypted flag (default false).
    if (std.mem.indexOf(u8, json, "\"encrypted\"")) |ei| {
        const rest = json[ei..];
        if (std.mem.indexOf(u8, rest, "true")) |ti| {
            // only treat as encrypted if `true` is the value right after the key
            if (ti < 20) g.encrypted = true;
        }
    }

    // sources[0].file
    if (std.mem.indexOf(u8, json, "\"sources\"")) |si| {
        const file = jsonStrField(json[si..], "\"file\"") orelse return null;
        g.stream_len = copyJsonUrl(file, &g.stream_url);
        if (g.stream_len == 0) return null;
    } else return null;

    // tracks[] — keep kind=="captions" only.
    if (std.mem.indexOf(u8, json, "\"tracks\"")) |ti| {
        const tracks_region = json[ti..];
        var search: usize = 0;
        while (g.track_count < g.tracks.len) {
            const obj_start = std.mem.indexOfScalarPos(u8, tracks_region, search, '{') orelse break;
            const obj_end = std.mem.indexOfScalarPos(u8, tracks_region, obj_start, '}') orelse break;
            const obj = tracks_region[obj_start .. obj_end + 1];
            search = obj_end + 1;
            if (std.mem.indexOf(u8, obj, "\"captions\"") == null) continue;
            const file = jsonStrField(obj, "\"file\"") orelse continue;
            var t = Track{};
            t.url_len = copyJsonUrl(file, &t.url);
            if (jsonStrField(obj, "\"label\"")) |lbl| {
                const n = @min(lbl.len, t.label.len);
                @memcpy(t.label[0..n], lbl[0..n]);
                t.label_len = n;
            }
            if (t.url_len > 0) {
                g.tracks[g.track_count] = t;
                g.track_count += 1;
            }
        }
    }

    return g;
}

// ══════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════

// A hand-built but structurally-real Dean-Edwards packed blob. Payload
// `var 2="0://5.4/3.1"` with base 36, count 6 and the symbol table below unpacks
// to  var file="https://example.com/master.m3u8".
const SAMPLE_PACKED =
    "eval(function(p,a,c,k,e,d){e=function(c){return c.toString(a)};" ++
    "if(!''.replace(/^/,String)){while(c--){d[c.toString(a)]=k[c]||c.toString(a)}" ++
    "k=[function(e){return d[e]}];e=function(){return'\\w+'};c=1};" ++
    "while(c--){if(k[c]){p=p.replace(new RegExp('\\b'+e(c)+'\\b','g'),k[c])}}return p}" ++
    "('var 2=\"0://5.4/3.1\"',36,6,'https|m3u8|file|master|com|example'.split('|'),0,{}))";

test "unpackPacked decodes a P.A.C.K.E.R payload to its source" {
    var out: [4096]u8 = undefined;
    var sym: [4096]u8 = undefined;
    const un = unpackPacked(SAMPLE_PACKED, &out, &sym) orelse return error.Unpacked;
    try std.testing.expect(std.mem.indexOf(u8, un, "https://example.com/master.m3u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, un, "var file=") != null);
    // "var" is NOT a valid base-36 token < 6 → must survive verbatim.
    try std.testing.expect(std.mem.indexOf(u8, un, "var") != null);
}

test "unpackPacked → StreamWish-style m3u8 extraction" {
    var out: [4096]u8 = undefined;
    var sym: [4096]u8 = undefined;
    const un = unpackPacked(SAMPLE_PACKED, &out, &sym) orelse return error.Unpacked;
    var url: [1024]u8 = undefined;
    const m3u8 = extractUrlContaining(un, ".m3u8", &url) orelse return error.NoUrl;
    try std.testing.expectEqualStrings("https://example.com/master.m3u8", m3u8);
}

test "unpackPacked rejects non-packed JS" {
    var out: [1024]u8 = undefined;
    var sym: [1024]u8 = undefined;
    try std.testing.expect(unpackPacked("function foo(){return 1;}", &out, &sym) == null);
    try std.testing.expect(unpackPacked("", &out, &sym) == null);
}

test "encodeToken / decodeToken incl. high radix" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0", encodeToken(0, 36, &buf));
    try std.testing.expectEqualStrings("a", encodeToken(10, 36, &buf));
    try std.testing.expectEqualStrings("10", encodeToken(36, 36, &buf));
    try std.testing.expectEqualStrings("A", encodeToken(36, 62, &buf)); // base62 high digit
    try std.testing.expectEqual(@as(?usize, 10), decodeToken("a", 36));
    try std.testing.expectEqual(@as(?usize, null), decodeToken("g", 16)); // 'g' ≥ base 16
}

test "extractUrlContaining stops at delimiters" {
    var out: [256]u8 = undefined;
    const html = "src:\"https://cdn.host/x/master.m3u8?e=1\",type:'hls'";
    const u = extractUrlContaining(html, ".m3u8", &out) orelse return error.NoUrl;
    try std.testing.expectEqualStrings("https://cdn.host/x/master.m3u8?e=1", u);
}

test "Mp4Upload-style mp4 extraction from unpacked src()" {
    var out: [256]u8 = undefined;
    const un = "player.src({type:\"video/mp4\",src:\"https://a.mp4upload.com/d/xyz/video.mp4\"});";
    const u = extractUrlContaining(un, ".mp4", &out) orelse return error.NoUrl;
    try std.testing.expectEqualStrings("https://a.mp4upload.com/d/xyz/video.mp4", u);
}

test "StreamTape two-part token join" {
    var out: [512]u8 = undefined;
    const html =
        "<div id=\"robotlink\">//streamta.pe/get_video?id=abc&expires=123&ip=1&token=</div>" ++
        "<script>document.getElementById('robotlink').innerHTML = " ++
        "'//streamta.pe/get_video?id=abc&expires=123&ip=1&token=' + ('xLohaqi9?stream=1').substring(3);</script>";
    const u = extractStreamTape(html, &out) orelse return error.NoUrl;
    try std.testing.expectEqualStrings(
        "https://streamta.pe/get_video?id=abc&expires=123&ip=1&token=haqi9?stream=1",
        u,
    );
}

test "DoodStream pass_md5 extraction + assembly" {
    const html = "$.get('/pass_md5/183531-1696975089/abcdef1234', function(data){";
    const path = extractDoodPath(html) orelse return error.NoPath;
    try std.testing.expectEqualStrings("183531-1696975089/abcdef1234", path);
    try std.testing.expectEqualStrings("abcdef1234", doodToken(path));

    const rnd = doodRandomToken(path);
    for (rnd) |ch| try std.testing.expect(isAlnum(ch));
    // Deterministic: same seed → same token.
    try std.testing.expectEqualSlices(u8, &rnd, &doodRandomToken(path));

    var out: [512]u8 = undefined;
    const url = assembleDoodUrl("https://dood.wf/cdn/base123\n", "RANDOM7890", doodToken(path), 1700000000000, &out) orelse return error.NoUrl;
    try std.testing.expectEqualStrings(
        "https://dood.wf/cdn/base123RANDOM7890?token=abcdef1234&expiry=1700000000000",
        url,
    );
}

test "MegaCloud sourceId + getSources URL build" {
    const embed = "https://megacloud.blog/embed-2/e-1/aBcD1234?k=1";
    try std.testing.expectEqualStrings("aBcD1234", megacloudSourceId(embed).?);
    var out: [256]u8 = undefined;
    const url = megacloudGetSourcesUrl(embed, "aBcD1234", "KEY", &out).?;
    try std.testing.expectEqualStrings(
        "https://megacloud.blog/embed-2/ajax/e-1/getSources?id=aBcD1234&_k=KEY",
        url,
    );
}

test "MegaCloud nonce scrape — 48-char run" {
    const key48 = "ABCDEFGHIJ0123456789abcdefghijKLMNOPQRSTUV012345"; // 48 chars
    try std.testing.expectEqual(@as(usize, 48), key48.len);
    var html_buf: [128]u8 = undefined;
    const html = std.fmt.bufPrint(&html_buf, "<div data-k=\"{s}\"></div>", .{key48}) catch unreachable;
    var out: [64]u8 = undefined;
    const nonce = megacloudNonce(html, &out) orelse return error.NoNonce;
    try std.testing.expectEqualStrings(key48, nonce);
}

test "MegaCloud getSources JSON parse (plaintext m3u8 + captions)" {
    const json =
        "{\"sources\":[{\"file\":\"https:\\/\\/cdn.megacloud.blog\\/hls\\/master.m3u8\",\"type\":\"hls\"}]," ++
        "\"tracks\":[{\"file\":\"https:\\/\\/cdn\\/sub\\/eng.vtt\",\"label\":\"English\",\"kind\":\"captions\",\"default\":true}," ++
        "{\"file\":\"https:\\/\\/cdn\\/thumb.vtt\",\"kind\":\"thumbnails\"}]," ++
        "\"encrypted\":false,\"server\":1,\"intro\":{\"start\":10,\"end\":20}}";
    const g = parseGetSources(json) orelse return error.NoParse;
    try std.testing.expect(!g.encrypted);
    try std.testing.expectEqualStrings("https://cdn.megacloud.blog/hls/master.m3u8", g.streamUrl());
    try std.testing.expectEqual(@as(usize, 1), g.track_count); // only the captions track
    try std.testing.expectEqualStrings("English", g.tracks[0].label[0..g.tracks[0].label_len]);
    try std.testing.expectEqualStrings("https://cdn/sub/eng.vtt", g.tracks[0].url[0..g.tracks[0].url_len]);
}

test "MegaCloud getSources — encrypted response is flagged (caller skips)" {
    const json = "{\"sources\":[{\"file\":\"deadbeef==\"}],\"encrypted\":true}";
    const g = parseGetSources(json) orelse return error.NoParse;
    try std.testing.expect(g.encrypted);
}

test "classifyHost routes each host + yt-dlp delegate list" {
    try std.testing.expectEqual(Host.streamwish, classifyHost("https://streamwish.to/e/abc"));
    try std.testing.expectEqual(Host.streamwish, classifyHost("https://wishfast.top/e/abc"));
    try std.testing.expectEqual(Host.filemoon, classifyHost("https://filemoon.sx/e/xyz"));
    try std.testing.expectEqual(Host.vidhide, classifyHost("https://vidhide.com/v/xyz"));
    try std.testing.expectEqual(Host.mp4upload, classifyHost("https://www.mp4upload.com/embed-abc.html"));
    try std.testing.expectEqual(Host.streamtape, classifyHost("https://streamtape.com/e/abc"));
    try std.testing.expectEqual(Host.doodstream, classifyHost("https://d000d.com/e/xyz"));
    try std.testing.expectEqual(Host.megacloud, classifyHost("https://megacloud.blog/embed-2/e-1/x?k=1"));
    try std.testing.expectEqual(Host.unknown, classifyHost("https://randomhost.example/e/x"));

    // Delegate to yt-dlp — do NOT reimplement these.
    try std.testing.expect(shouldDelegateToYtdlp("https://www.youtube.com/watch?v=abc"));
    try std.testing.expect(shouldDelegateToYtdlp("https://youtu.be/abc"));
    try std.testing.expect(shouldDelegateToYtdlp("https://www.dailymotion.com/embed/video/x"));
    try std.testing.expect(shouldDelegateToYtdlp("https://ok.ru/videoembed/12345"));
    try std.testing.expect(shouldDelegateToYtdlp("https://vk.com/video_ext.php?oid=1"));
    try std.testing.expect(shouldDelegateToYtdlp("https://video.sibnet.ru/shell.php?videoid=1"));
    try std.testing.expect(!shouldDelegateToYtdlp("https://streamwish.to/e/abc"));
}

test "schemeHostOf / refererFor" {
    try std.testing.expectEqualStrings("https://streamwish.to", schemeHostOf("https://streamwish.to/e/abc?x=1").?);
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("https://d000d.com/", refererFor("https://d000d.com/e/xyz", &out).?);
}
