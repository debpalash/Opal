//! Release-name parsing for Home's library artwork (pure: std + sibling pure
//! modules only, unit tested; `library_art.zig` and `watch_history.zig` route
//! every decision through here).
//!
//!   nameFromSource  — the name inside a path / URL / magnet `dn=` (decoded,
//!                     extension stripped). Never the directory part.
//!   parse           — "Show.Name.S02E04.1080p.WEB-DL.x264-GRP.mkv" →
//!                     { "Show Name", season 2, episode 4, is_tv }
//!   episodeLabel    — "S2 E4" / "S2" / "E12"
//!   lookupAllowed   — privacy gate: only names that look like a release go
//!                     to the network, and only the parsed title (+year).
//!   pickMatch       — which Cinemeta search row really is the parsed title.
//!
//! `markers_pure.parseEpisode` and `recall_pure.yearFromName` cover parts of
//! this but return a lower-cased prefix / bare year; this file keeps the title's
//! original case and also strips tags, so it is the one display + lookup path.

const std = @import("std");
const picks = @import("operator_picks_pure.zig");

pub const Candidate = picks.Candidate;
pub const Media = picks.Media;

pub const MAX_TITLE = 128;
pub const MAX_NAME = 512;
/// Rows that found nothing are retried after this long (a new Cinemeta entry,
/// or a parser improvement, gets a second chance without hammering the API).
pub const RETRY_AFTER_S: i64 = 30 * 24 * 60 * 60;

pub const Parsed = struct {
    title: [MAX_TITLE]u8 = undefined,
    title_len: u8 = 0,
    year: u16 = 0,
    season: u16 = 0,
    episode: u16 = 0,
    is_tv: bool = false,
    /// A release-naming signal was seen: year, episode marker, quality/source
    /// tag or a leading [Group]. Home videos have none.
    signals: bool = false,

    pub fn titleText(self: *const Parsed) []const u8 {
        return self.title[0..self.title_len];
    }

    /// Cinemeta catalog to search first.
    pub fn media(self: *const Parsed) Media {
        return if (self.is_tv) .tv else .movie;
    }
};

// ── Source → bare name ──────────────────────────────────────────────────────

const EXTENSIONS = [_][]const u8{
    "mkv",  "mp4", "m4v",  "avi",  "mov",  "wmv", "flv", "webm", "ts",   "m2ts", "mts", "mpg",
    "mpeg", "vob", "ogv",  "3gp",  "iso",  "rmvb", "divx", "mp3", "flac", "m4a", "aac", "ogg",
    "opus", "wav", "srt", "torrent", "strm", "part",
};

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Decode valid `%XX` escapes (invalid ones stay literal, so a local
/// "100% Wolf" survives). `plus_space` maps `+` to a space (query strings).
pub fn percentDecode(in: []const u8, out: []u8, plus_space: bool) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < in.len and n < out.len) {
        const c = in[i];
        if (c == '%' and i + 2 < in.len) {
            if (hexVal(in[i + 1])) |hi| if (hexVal(in[i + 2])) |lo| {
                out[n] = hi * 16 + lo;
                n += 1;
                i += 3;
                continue;
            };
        }
        out[n] = if (plus_space and c == '+') ' ' else c;
        n += 1;
        i += 1;
    }
    return out[0..n];
}

fn stripExtension(name: []const u8) []const u8 {
    var s = name;
    var rounds: u8 = 0;
    while (rounds < 2) : (rounds += 1) {
        const dot = std.mem.lastIndexOfScalar(u8, s, '.') orelse break;
        const ext = s[dot + 1 ..];
        var known = false;
        for (EXTENSIONS) |e| {
            if (std.ascii.eqlIgnoreCase(ext, e)) known = true;
        }
        if (!known or dot == 0) break;
        s = s[0..dot];
    }
    return s;
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

/// The display-relevant name inside `raw`: a magnet's `dn=`, a URL's last path
/// segment, or a path's basename — percent-decoded, extension stripped. A
/// magnet without `dn=` yields "" (an info-hash names nothing).
pub fn nameFromSource(raw_in: []const u8, buf: []u8) []const u8 {
    const raw = std.mem.trim(u8, raw_in, " \t\r\n");
    if (raw.len == 0) return "";
    if (startsWithIgnoreCase(raw, "magnet:")) {
        var it = std.mem.tokenizeAny(u8, raw[7..], "?&");
        while (it.next()) |param| {
            if (startsWithIgnoreCase(param, "dn=")) {
                return stripExtension(std.mem.trim(u8, percentDecode(param[3..], buf, true), " "));
            }
        }
        return "";
    }
    var name = raw;
    var is_url = false;
    if (std.mem.indexOf(u8, raw, "://")) |scheme_end| {
        is_url = true;
        const after = raw[scheme_end + 3 ..];
        const path_start = std.mem.indexOfScalar(u8, after, '/') orelse return "";
        var path = after[path_start..];
        if (std.mem.indexOfAny(u8, path, "?#")) |q| path = path[0..q];
        name = std.mem.trimEnd(u8, path, "/");
    }
    var base_start: usize = 0;
    for (name, 0..) |ch, i| {
        if (ch == '/' or (!is_url and ch == '\\')) base_start = i + 1;
    }
    const decoded = percentDecode(name[base_start..], buf, false);
    return stripExtension(std.mem.trim(u8, decoded, " "));
}

// ── Tokens ──────────────────────────────────────────────────────────────────

const TokKind = enum { word, dash, group };
const Tok = struct { kind: TokKind, text: []const u8 };
const MAX_TOKS = 64;

fn isSep(c: u8) bool {
    return c == ' ' or c == '.' or c == '_' or c == '+' or c == '\t' or c == ',';
}

fn closer(c: u8) ?u8 {
    return switch (c) {
        '[' => ']',
        '(' => ')',
        '{' => '}',
        else => null,
    };
}

fn tokenize(name: []const u8, out: []Tok) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < name.len and n < out.len) {
        const c = name[i];
        if (isSep(c)) {
            i += 1;
            continue;
        }
        if (closer(c)) |close| {
            const end = std.mem.indexOfScalarPos(u8, name, i + 1, close) orelse name.len;
            out[n] = .{ .kind = .group, .text = name[i + 1 .. end] };
            n += 1;
            i = @min(name.len, end + 1);
            continue;
        }
        var j = i;
        while (j < name.len and !isSep(name[j]) and closer(name[j]) == null) j += 1;
        const text = name[i..j];
        // A token of only dashes (or an en/em dash) separates, it never titles.
        const only_dash = std.mem.trim(u8, text, "-") .len == 0 or
            std.mem.eql(u8, text, "\xe2\x80\x93") or std.mem.eql(u8, text, "\xe2\x80\x94");
        out[n] = .{ .kind = if (only_dash) .dash else .word, .text = text };
        n += 1;
        i = j;
    }
    return n;
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn parseNum(s: []const u8) ?u16 {
    if (s.len == 0 or s.len > 4 or !allDigits(s)) return null;
    return std.fmt.parseInt(u16, s, 10) catch null;
}

fn yearOf(s: []const u8) ?u16 {
    if (s.len != 4) return null;
    const y = parseNum(s) orelse return null;
    return if (y >= 1900 and y <= 2099) y else null;
}

const Episode = struct { season: u16 = 0, episode: u16 = 0 };

/// Leading digits of `s` (up to `max` of them) and the rest.
fn digitsPrefix(s: []const u8, max: usize) ?struct { v: u16, rest: []const u8 } {
    var k: usize = 0;
    while (k < s.len and k < max and std.ascii.isDigit(s[k])) k += 1;
    if (k == 0) return null;
    if (k < s.len and std.ascii.isDigit(s[k])) return null; // too many digits
    return .{ .v = std.fmt.parseInt(u16, s[0..k], 10) catch return null, .rest = s[k..] };
}

/// `S01E02`, `s1e2`, `S01E02E03`, `S01E02-E03`, `S01.E02` (via `next`), `1x02`.
fn episodeMarker(tok: []const u8, next: ?[]const u8) ?Episode {
    // Trailing release-group suffix ("S01E02-GRP") does not matter.
    if (tok.len >= 2 and (tok[0] == 's' or tok[0] == 'S')) {
        if (digitsPrefix(tok[1..], 2)) |s| {
            const rest = s.rest;
            if (rest.len >= 2 and (rest[0] == 'e' or rest[0] == 'E')) {
                if (digitsPrefix(rest[1..], 4)) |e| {
                    if (e.rest.len == 0 or !std.ascii.isAlphabetic(e.rest[0]) or e.rest[0] == 'e' or e.rest[0] == 'E')
                        return .{ .season = s.v, .episode = e.v };
                }
            }
            if (rest.len == 0) {
                // "S01" alone, maybe followed by "E02".
                if (next) |nx| if (nx.len >= 2 and (nx[0] == 'e' or nx[0] == 'E')) {
                    if (digitsPrefix(nx[1..], 4)) |e| if (e.rest.len == 0) return .{ .season = s.v, .episode = e.v };
                };
                return .{ .season = s.v };
            }
        }
    }
    // 1x02 (season ≤ 2 digits, episode 2-3 digits: never 1920x1080).
    if (digitsPrefix(tok, 2)) |s| {
        if (s.rest.len >= 3 and (s.rest[0] == 'x' or s.rest[0] == 'X')) {
            if (digitsPrefix(s.rest[1..], 3)) |e| {
                const ep_digits = s.rest.len - 1 - e.rest.len;
                if (ep_digits >= 2 and e.rest.len == 0) return .{ .season = s.v, .episode = e.v };
            }
        }
    }
    return null;
}

/// `E02`, `Ep02`, `EP.02` handled by the caller via `next`.
fn bareEpisode(tok: []const u8) ?u16 {
    if (tok.len >= 2 and (tok[0] == 'e' or tok[0] == 'E')) {
        var body = tok[1..];
        if (body.len > 0 and (body[0] == 'p' or body[0] == 'P')) body = body[1..];
        if (digitsPrefix(body, 4)) |e| if (e.rest.len == 0) return e.v;
    }
    return null;
}

/// "02", "02v2", "1080"-ish numbers after a " - " (anime absolute numbering).
fn animeEpisode(tok: []const u8) ?u16 {
    const d = digitsPrefix(tok, 4) orelse return null;
    if (tok.len - d.rest.len < 2) return null; // "Show - 2" is too ambiguous
    if (d.rest.len == 0) return if (yearOf(tok) == null) d.v else null;
    if (d.rest.len == 2 and (d.rest[0] == 'v' or d.rest[0] == 'V') and std.ascii.isDigit(d.rest[1])) return d.v;
    return null;
}

const TAGS = [_][]const u8{
    // resolution / video
    "4k",       "8k",        "uhd",      "fhd",       "x264",     "x265",     "h264",    "h265",
    "hevc",     "avc",       "xvid",     "divx",      "av1",      "vp9",      "10bit",   "8bit",
    "hdr",      "hdr10",     "dovi",     "sdr",       "3d",       "60fps",
    // source
    "webrip",   "web-dl",    "webdl",    "web-rip",   "bluray",   "blu-ray",  "bdrip",   "brrip",
    "bdremux",  "remux",     "dvdrip",   "dvdscr",    "dvd",      "dvd5",     "dvd9",    "hdtv",
    "hdrip",    "hdcam",     "camrip",   "telesync",  "tvrip",    "pdtv",     "sdtv",    "ppv",
    "amzn",     "dsnp",      "hmax",     "atvp",      "hulu",     "pcok",     "pmtp",    "itunes",
    // audio
    "aac",      "aac2",      "ac3",      "eac3",      "ddp",      "ddp5",     "ddp2",    "dd5",
    "dd2",      "dts",       "dts-hd",   "truehd",    "atmos",    "dts-x",
    // edition / release
    "proper",   "repack",    "rerip",    "internal",  "limited",  "unrated",  "extended", "remastered",
    "uncut",    "imax",      "hybrid",   "multi",     "dual",     "dubbed",   "subbed",   "hardsub",
    "multisub", "esub",      "esubs",    "complete",  "readnfo",  "nfofix",
    // well-known groups / sites that appear without a dash
    "yts",      "yify",      "rarbg",    "eztv",      "ettv",     "tgx",      "psa",      "qxr",
};

/// Case-sensitive tags: common words in lower case, tags in upper case.
const UPPER_TAGS = [_][]const u8{ "WEB", "DV", "NF", "HC", "CAM", "TS", "HD", "SD", "MAX" };

fn isTag(tok: []const u8, next: ?[]const u8) bool {
    for (UPPER_TAGS) |t| if (std.mem.eql(u8, tok, t)) return true;
    // Release group glued with a dash: judge the part before it.
    const head = if (std.mem.indexOfScalar(u8, tok, '-')) |d| (if (d > 0) tok[0..d] else tok) else tok;
    for (UPPER_TAGS) |t| if (std.mem.eql(u8, head, t)) return true;
    for (TAGS) |t| {
        if (std.ascii.eqlIgnoreCase(tok, t) or std.ascii.eqlIgnoreCase(head, t)) return true;
    }
    // 480p / 1080p / 1080i / 2160p
    if (digitsPrefix(head, 4)) |d| {
        if (d.rest.len == 1 and (d.rest[0] == 'p' or d.rest[0] == 'P' or d.rest[0] == 'i' or d.rest[0] == 'I')) {
            switch (d.v) {
                240, 360, 480, 540, 576, 720, 1080, 1440, 2160, 4320 => return true,
                else => {},
            }
        }
    }
    // "H.264" splits on the dot into "H" + "264".
    if ((std.mem.eql(u8, tok, "H") or std.mem.eql(u8, tok, "h")) and next != null) {
        if (std.mem.startsWith(u8, next.?, "264") or std.mem.startsWith(u8, next.?, "265")) return true;
    }
    // "DDP5.1", "AAC2.0", "DTS-HD" prefixes
    const prefixes = [_][]const u8{ "ddp", "eac3", "truehd", "aac2", "aac5", "ac3", "dts", "atmos" };
    for (prefixes) |p| if (startsWithIgnoreCase(head, p)) return true;
    return false;
}

fn isWord(tok: []const u8, w: []const u8) bool {
    return std.ascii.eqlIgnoreCase(tok, w);
}

/// What a bracketed group contributes: a year, an episode marker, tags.
const GroupInfo = struct { year: u16 = 0, ep: ?Episode = null, tag: bool = false };

fn groupInfo(text: []const u8) GroupInfo {
    var toks: [16]Tok = undefined;
    const n = tokenize(text, &toks);
    var info = GroupInfo{};
    for (toks[0..n], 0..) |t, i| {
        if (t.kind != .word) continue;
        const next: ?[]const u8 = if (i + 1 < n) toks[i + 1].text else null;
        if (yearOf(t.text)) |y| {
            if (info.year == 0) info.year = y;
        } else if (episodeMarker(t.text, next)) |e| {
            if (info.ep == null) info.ep = e;
        } else if (isTag(t.text, next)) info.tag = true;
    }
    return info;
}

fn appendTitle(p: *Parsed, word: []const u8) void {
    const need = word.len + @as(usize, if (p.title_len > 0) 1 else 0);
    if (@as(usize, p.title_len) + need > MAX_TITLE) return;
    if (p.title_len > 0) {
        p.title[p.title_len] = ' ';
        p.title_len += 1;
    }
    @memcpy(p.title[p.title_len..][0..word.len], word);
    p.title_len += @intCast(word.len);
}

fn setEpisode(p: *Parsed, e: Episode) void {
    if (p.season == 0 and p.episode == 0) {
        p.season = e.season;
        p.episode = e.episode;
    }
    p.is_tv = true;
    p.signals = true;
}

/// Parse a bare release name (see `nameFromSource` for paths/URLs/magnets).
pub fn parseName(name: []const u8) Parsed {
    var p = Parsed{};
    var toks: [MAX_TOKS]Tok = undefined;
    const n = tokenize(name, &toks);
    var i: usize = 0;

    // Leading noise: "[Group]" tags and "www.site.org -" prefixes.
    while (i < n) {
        if (toks[i].kind == .group) {
            const g = groupInfo(toks[i].text);
            if (g.ep) |e| setEpisode(&p, e);
            p.signals = true;
            i += 1;
        } else if (toks[i].kind == .dash) {
            i += 1;
        } else if (isWord(toks[i].text, "www")) {
            var j = i + 1;
            while (j < n and toks[j].kind != .dash) j += 1;
            if (j >= n) break; // no separator: leave it, it may be the name
            i = j + 1;
        } else break;
    }

    var cut = false;
    var after_dash = false;
    while (i < n) : (i += 1) {
        const t = toks[i];
        const next: ?[]const u8 = if (i + 1 < n and toks[i + 1].kind == .word) toks[i + 1].text else null;
        const titled = p.title_len > 0;
        switch (t.kind) {
            .dash => {
                after_dash = true;
                continue;
            },
            .group => {
                const g = groupInfo(t.text);
                if (g.year != 0 and p.year == 0) p.year = g.year;
                if (g.ep) |e| setEpisode(&p, e);
                if (g.year != 0 or g.ep != null or g.tag) {
                    p.signals = true;
                    if (titled) cut = true;
                }
                // Other groups ("(US)", a CRC) never become title words.
                after_dash = false;
                continue;
            },
            .word => {},
        }
        defer after_dash = false;
        const w = t.text;

        if (episodeMarker(w, next)) |e| {
            setEpisode(&p, e);
            cut = true;
            if (e.episode != 0 and next != null and bareEpisode(next.?) != null) i += 1;
            continue;
        }
        if (isWord(w, "season") and next != null) {
            if (parseNum(next.?)) |s| {
                var e = Episode{ .season = s };
                i += 1;
                if (i + 2 < n and isWord(toks[i + 1].text, "episode")) {
                    if (parseNum(toks[i + 2].text)) |ep| {
                        e.episode = ep;
                        i += 2;
                    }
                }
                setEpisode(&p, e);
                cut = true;
                continue;
            }
        }
        if ((isWord(w, "episode") or isWord(w, "ep")) and next != null) {
            if (parseNum(next.?)) |ep| {
                setEpisode(&p, .{ .episode = ep });
                cut = true;
                i += 1;
                continue;
            }
        }
        if (titled) if (bareEpisode(w)) |ep| {
            setEpisode(&p, .{ .episode = ep });
            cut = true;
            continue;
        };
        if (titled and after_dash) if (animeEpisode(w)) |ep| {
            setEpisode(&p, .{ .episode = ep });
            cut = true;
            continue;
        };
        if (yearOf(w)) |y| {
            // A year is the title when nothing precedes it ("1917", "2012") or
            // another year follows it ("Blade Runner 2049 2017").
            const next_is_year = next != null and yearOf(next.?) != null;
            if (!cut and (!titled or next_is_year)) {
                appendTitle(&p, w);
                continue;
            }
            if (p.year == 0) p.year = y;
            p.signals = true;
            cut = true;
            continue;
        }
        if (titled and isTag(w, next)) {
            p.signals = true;
            cut = true;
            continue;
        }
        if (!cut) appendTitle(&p, w);
    }
    return p;
}

/// Parse a path, URL, magnet or bare name.
pub fn parse(raw: []const u8) Parsed {
    var buf: [MAX_NAME]u8 = undefined;
    return parseName(nameFromSource(raw, &buf));
}

/// The better of a row's display title and its identity (file path): the one
/// carrying an episode marker wins, then the one with release signals, then
/// the display title.
pub fn parseBest(title: []const u8, identity: []const u8) Parsed {
    const a = parse(title);
    if (identity.len == 0) return a;
    const b = parse(identity);
    if (a.title_len == 0) return b;
    if (b.title_len == 0) return a;
    if (!a.is_tv and b.is_tv) return b;
    if (!a.signals and b.signals) return b;
    return a;
}

/// "S2 E4", "S2", "E12" or "" for a movie.
pub fn episodeLabel(p: *const Parsed, buf: []u8) []const u8 {
    if (p.season > 0 and p.episode > 0) return std.fmt.bufPrint(buf, "S{d} E{d}", .{ p.season, p.episode }) catch "";
    if (p.season > 0) return std.fmt.bufPrint(buf, "S{d}", .{p.season}) catch "";
    if (p.episode > 0) return std.fmt.bufPrint(buf, "E{d}", .{p.episode}) catch "";
    return "";
}

/// Display title for a library row: the parsed title, or `fallback` when the
/// parse found nothing usable.
pub fn displayTitle(p: *const Parsed, fallback: []const u8) []const u8 {
    return if (p.title_len > 0) p.titleText() else fallback;
}

// ── Privacy gate ────────────────────────────────────────────────────────────

const CAMERA_PREFIXES = [_][]const u8{ "img", "vid", "dsc", "pxl", "mvi", "gopr", "dji", "screen recording", "screenshot", "whatsapp", "signal", "telegram", "zoom", "rec", "mov" };

/// May this parse be looked up online? Only a release-looking name (`signals`)
/// whose title reads like a title: letters, at most 10 words, no 6+ digit run
/// (timestamps, phone-camera names), not a camera/recorder prefix. A home video
/// called "birthday party.mp4" never leaves the machine.
pub fn lookupAllowed(p: *const Parsed) bool {
    return p.signals and titleLooksPublic(p.titleText());
}

/// Same title checks, for rows whose title is already a catalog title.
pub fn titleLooksPublic(t: []const u8) bool {
    if (!picks.validTitle(t)) return false;
    var letters: usize = 0;
    var words: usize = 1;
    var digit_run: usize = 0;
    for (t) |c| {
        if (std.ascii.isAlphabetic(c) or c >= 0x80) letters += 1;
        if (c == ' ') words += 1;
        if (std.ascii.isDigit(c)) {
            digit_run += 1;
            if (digit_run >= 6) return false;
        } else digit_run = 0;
    }
    if (letters < 2 or words > 10) return false;
    for (CAMERA_PREFIXES) |pre| {
        if (startsWithIgnoreCase(t, pre) and (t.len == pre.len or !std.ascii.isAlphabetic(t[pre.len]))) return false;
    }
    return true;
}

/// Shared cache key: every episode of one show resolves with one lookup.
pub fn cacheKey(media: Media, title: []const u8, year: u16, buf: []u8) []const u8 {
    var norm: [picks.NORM_MAX]u8 = undefined;
    const t = picks.normTitle(&norm, title);
    if (t.len == 0) return "";
    return std.fmt.bufPrint(buf, "{s}|{s}|{d}", .{ media.id(), t, year }) catch "";
}

// ── Matching ────────────────────────────────────────────────────────────────

fn yearDiff(a: u16, b: u16) u16 {
    return if (a > b) a - b else b - a;
}

/// Index of the catalog row that is the parsed title: same title once
/// normalised. A movie with a year needs a catalog year within one; a show
/// prefers that but accepts the first exact title (file years on episodes are
/// often air years). No fuzzy matching: a wrong poster is worse than none.
pub fn pickMatch(title: []const u8, year: u16, media: Media, cands: []const Candidate) ?usize {
    var first: ?usize = null;
    for (cands, 0..) |*c, i| {
        if (!picks.sameTitle(title, c.titleText())) continue;
        if (year == 0) return i;
        if (c.year != 0 and yearDiff(c.year, year) <= 1) return i;
        if (first == null) first = i;
    }
    return if (media == .tv) first else null;
}

/// Parse a Cinemeta `meta/{type}/{imdb}.json` document into one candidate.
pub fn parseMetaCandidate(allocator: std.mem.Allocator, body: []const u8, media: Media) ?Candidate {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const meta = parsed.value.object.get("meta") orelse return null;
    if (meta != .object) return null;
    return picks.candidateFromObject(meta.object, media);
}

// ── Tests ───────────────────────────────────────────────────────────────────

const t_eq = std.testing.expectEqualStrings;
const t_ok = std.testing.expect;

fn expectParse(raw: []const u8, title: []const u8, year: u16, season: u16, episode: u16) !void {
    const p = parse(raw);
    t_eq(title, p.titleText()) catch |e| {
        std.debug.print("input: {s}\n", .{raw});
        return e;
    };
    try std.testing.expectEqual(year, p.year);
    try std.testing.expectEqual(season, p.season);
    try std.testing.expectEqual(episode, p.episode);
    try std.testing.expectEqual(season > 0 or episode > 0, p.is_tv);
}

test "scene TV names" {
    try expectParse("The.Last.of.Us.S02E04.1080p.WEB-DL.DDP5.1.H.264-GRP.mkv", "The Last of Us", 0, 2, 4);
    try expectParse("Severance.S01E01.Good.News.About.Hell.2160p.ATVP.WEB-DL.mkv", "Severance", 0, 1, 1);
    try expectParse("show_name_s1e2.mp4", "show name", 0, 1, 2);
    try expectParse("The Bear 3x05 720p HDTV x264", "The Bear", 0, 3, 5);
    try expectParse("Doctor.Who.2005.S13E01.1080p.HDTV.x265", "Doctor Who", 2005, 13, 1);
    try expectParse("Fargo S01E02E03 1080p", "Fargo", 0, 1, 2);
    try expectParse("Fargo.S01.E02.1080p", "Fargo", 0, 1, 2);
    try expectParse("Mr.Robot.S04E13-GRP", "Mr Robot", 0, 4, 13);
}

test "spelled-out and season-only TV names" {
    try expectParse("Breaking Bad Season 2 Episode 4.mkv", "Breaking Bad", 0, 2, 4);
    try expectParse("Breaking.Bad.Season.2.Complete.720p", "Breaking Bad", 0, 2, 0);
    try expectParse("Dark.S02.1080p.NF.WEB-DL", "Dark", 0, 2, 0);
    try expectParse("Planet Earth Episode 3", "Planet Earth", 0, 0, 3);
    try expectParse("Planet.Earth.E03.720p", "Planet Earth", 0, 0, 3);
}

test "anime naming" {
    try expectParse("[SubsPlease] Frieren - 12 (1080p) [ABCD1234].mkv", "Frieren", 0, 0, 12);
    try expectParse("[Erai-raws] One Piece - 1085v2 [720p].mkv", "One Piece", 0, 0, 1085);
    // A lone digit after a dash is too ambiguous to be an episode.
    try expectParse("Ocean's - 8", "Ocean's 8", 0, 0, 0);
}

test "movie names with years and tags" {
    try expectParse("Dune.Part.Two.2024.2160p.UHD.BluRay.x265-GRP.mkv", "Dune Part Two", 2024, 0, 0);
    try expectParse("Inception (2010) [1080p] [BluRay] [YTS.MX].mp4", "Inception", 2010, 0, 0);
    try expectParse("Heat [1995] 1080p", "Heat", 1995, 0, 0);
    try expectParse("Blade.Runner.2049.2017.1080p.BluRay", "Blade Runner 2049", 2017, 0, 0);
    try expectParse("1917.2019.1080p.WEBRip.x264", "1917", 2019, 0, 0);
    try expectParse("2012 (2009).mkv", "2012", 2009, 0, 0);
    try expectParse("Schindler's List 1993 REMASTERED 1080p", "Schindler's List", 1993, 0, 0);
    try expectParse("Spider-Man.No.Way.Home.2021.HDR.2160p", "Spider-Man No Way Home", 2021, 0, 0);
    try expectParse("Arrival.1080p.BluRay.x264", "Arrival", 0, 0, 0);
    try expectParse("The Office (US) S02E01", "The Office", 0, 2, 1);
}

test "paths, URLs and magnets" {
    try expectParse("/Users/me/Movies/Heat.1995.1080p.mkv", "Heat", 1995, 0, 0);
    try expectParse("C:\\Media\\TV\\Fargo.S01E02.mkv", "Fargo", 0, 1, 2);
    try expectParse("https://cdn.example.com/v/The%20Bear%20S01E01.mp4?token=abc#t=10", "The Bear", 0, 1, 1);
    try expectParse("http://host/files/Arrival.2016.720p.mkv/", "Arrival", 2016, 0, 0);
    try expectParse("magnet:?xt=urn:btih:ABCDEF0123&dn=Severance.S02E03.1080p.WEB.h264&tr=udp%3A%2F%2Ftracker", "Severance", 0, 2, 3);
    try expectParse("magnet:?dn=Dune+Part+Two+%282024%29&xt=urn:btih:00", "Dune Part Two", 2024, 0, 0);
    try expectParse("magnet:?xt=urn:btih:ABCDEF0123", "", 0, 0, 0);
    try expectParse("www.UIndex.org    -    Shrinking S02E05 1080p", "Shrinking", 0, 2, 5);
}

test "edge cases never crash and stay bounded" {
    try expectParse("", "", 0, 0, 0);
    try expectParse("1080p.mkv", "1080p", 0, 0, 0);
    try expectParse("....", "", 0, 0, 0);
    try expectParse("[Group]", "", 0, 0, 0);
    try expectParse("100% Wolf (2020).mkv", "100% Wolf", 2020, 0, 0);
    try expectParse("1920x1080 wallpaper", "1920x1080 wallpaper", 0, 0, 0);
    var long: [2000]u8 = undefined;
    @memset(&long, 'a');
    for (0..long.len / 7) |k| long[k * 7] = '.';
    const p = parse(&long);
    try t_ok(p.title_len <= MAX_TITLE);
    // Unclosed bracket swallows the rest instead of reading past the end.
    try expectParse("Movie (2010", "Movie", 2010, 0, 0);
}

test "parseBest prefers the identity when it names the episode" {
    const p = parseBest("Fargo", "/tv/Fargo/Fargo.S01E02.720p.mkv");
    try t_eq("Fargo", p.titleText());
    try std.testing.expectEqual(@as(u16, 2), p.episode);
    const q = parseBest("Heat (1995)", "/m/heat.mkv");
    try std.testing.expectEqual(@as(u16, 1995), q.year);
    const r = parseBest("", "/m/Heat.1995.mkv");
    try t_eq("Heat", r.titleText());
}

test "episode label" {
    var buf: [24]u8 = undefined;
    var p = parse("Show.S02E04.mkv");
    try t_eq("S2 E4", episodeLabel(&p, &buf));
    p = parse("Show.S03.1080p");
    try t_eq("S3", episodeLabel(&p, &buf));
    p = parse("[G] Show - 12");
    try t_eq("E12", episodeLabel(&p, &buf));
    p = parse("Heat.1995.mkv");
    try t_eq("", episodeLabel(&p, &buf));
}

test "privacy gate keeps home videos and camera files local" {
    var p = parse("/Users/me/Videos/birthday party.mp4");
    try t_ok(!lookupAllowed(&p));
    p = parse("/Users/me/Downloads/Making_music_symbol_with_dust_202608071750.mp4");
    try t_ok(!lookupAllowed(&p));
    p = parse("IMG_20240101_1200 2024.mov");
    try t_ok(!lookupAllowed(&p));
    p = parse("VID 2023 720p.mp4");
    try t_ok(!lookupAllowed(&p));
    p = parse("Heat.1995.1080p.mkv");
    try t_ok(lookupAllowed(&p));
    p = parse("The.Bear.S01E01.mkv");
    try t_ok(lookupAllowed(&p));
    try t_ok(titleLooksPublic("Recess"));
    try t_ok(!titleLooksPublic("x"));
}

test "cache key is shared across episodes and normalised" {
    var a: [160]u8 = undefined;
    var b: [160]u8 = undefined;
    const p1 = parse("The.Bear.S01E01.mkv");
    const p2 = parse("the bear s02e05 720p");
    try t_eq(cacheKey(p1.media(), p1.titleText(), p1.year, &a), cacheKey(p2.media(), p2.titleText(), p2.year, &b));
    try t_eq("movie|heat|1995", cacheKey(.movie, "Heat", 1995, &a));
    try t_eq("", cacheKey(.movie, "", 0, &a));
}

fn cand(title: []const u8, year: u16) Candidate {
    var c = Candidate{};
    @memcpy(c.title[0..title.len], title);
    c.title_len = @intCast(title.len);
    c.year = year;
    return c;
}

test "pickMatch is exact on title and careful with years" {
    const rows = [_]Candidate{ cand("Heat", 1986), cand("Heat", 1995), cand("Dune: Part Two", 2024) };
    try std.testing.expectEqual(@as(?usize, 1), pickMatch("Heat", 1995, .movie, &rows));
    try std.testing.expectEqual(@as(?usize, 0), pickMatch("Heat", 0, .movie, &rows));
    try std.testing.expectEqual(@as(?usize, null), pickMatch("Heat", 2010, .movie, &rows));
    try std.testing.expectEqual(@as(?usize, 2), pickMatch("Dune Part Two", 2024, .movie, &rows));
    try std.testing.expectEqual(@as(?usize, null), pickMatch("Heat Wave", 0, .movie, &rows));
    // A show's file year may be an air year: fall back to the exact title.
    const shows = [_]Candidate{cand("Doctor Who", 1963)};
    try std.testing.expectEqual(@as(?usize, 0), pickMatch("Doctor Who", 2005, .tv, &shows));
}

test "Cinemeta search + meta bodies feed the matcher" {
    const a = std.testing.allocator;
    const search =
        \\{"metas":[{"id":"tt0113277","imdb_id":"tt0113277","type":"movie","name":"Heat","releaseInfo":"1995","poster":"https://images.metahub.space/poster/small/tt0113277/img"},
        \\{"id":"tt0091204","type":"movie","name":"Heat","releaseInfo":"1986","poster":"https://images.metahub.space/poster/small/tt0091204/img"}]}
    ;
    var rows: [4]Candidate = undefined;
    const n = picks.parseCandidates(a, search, .movie, &rows);
    try std.testing.expectEqual(@as(usize, 2), n);
    const i = pickMatch("Heat", 1986, .movie, rows[0..n]).?;
    try t_eq("tt0091204", rows[i].imdbText());
    try t_eq("https://images.metahub.space/poster/small/tt0091204/img.jpg", rows[i].poster[0..rows[i].poster_len]);

    const meta =
        \\{"meta":{"id":"tt0903747","type":"series","name":"Breaking Bad","releaseInfo":"2008-2013","poster":"https://images.metahub.space/poster/small/tt0903747/img"}}
    ;
    const c = parseMetaCandidate(a, meta, .tv).?;
    try t_eq("Breaking Bad", c.titleText());
    try std.testing.expectEqual(@as(u16, 2008), c.year);
    try std.testing.expect(parseMetaCandidate(a, "{\"meta\":null}", .tv) == null);
    try std.testing.expect(parseMetaCandidate(a, "not json", .tv) == null);
}
