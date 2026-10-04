//! local_names (pure part): which local file names still look messy after the
//! automatic clean-up, the context text handed to the agent (basenames only),
//! validation of the agent's answer, and applying it through an injectable
//! target so the rules are unit tested without a database.
//!
//! The answer only ever changes the DISPLAY title and kind of files in the user's
//! own library, and only where the user has not set a title themselves.

const std = @import("std");
const op = @import("operator_pure.zig");

pub const MAX_ITEMS = 20;
pub const TITLE_MAX = 120;
/// Must equal operator.MAX_CONTEXT (asserted at compile time in operator_local_names.zig).
pub const CONTEXT_MAX = 3000;
/// Longest filename we show the agent; the rest is cut at a character boundary.
pub const BASENAME_MAX = 160;

// ── Is a cleaned title still messy? ─────────────────────────────────────

/// Release-name tokens (lower case, compared to whole alphanumeric tokens).
const junk_tokens = [_][]const u8{
    "480p",   "540p",   "576p",    "720p", "1080p", "1080i", "2160p",  "4320p",  "uhd",      "x264",      "x265",   "h264",
    "h265",   "hevc",   "avc",     "xvid", "divx",  "10bit", "8bit",   "hdr",    "hdr10",    "hdr10plus", "aac",    "aac2",
    "ac3",    "eac3",   "dts",     "ddp",  "ddp5",  "dd5",   "truehd", "atmos",  "bluray",   "bdrip",     "brrip",  "bdremux",
    "dvdrip", "dvdscr", "hdtv",    "pdtv", "hdrip", "hdcam", "camrip", "webrip", "webdl",    "remux",     "repack", "proper",
    "amzn",   "dsnp",   "hmax",    "yify", "yts",   "rarbg", "eztv",   "ettv",   "galaxytv", "fgt",       "sparks", "www",
    "flac",   "flac24", "320kbps",
};

fn lowerEq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn isJunkToken(tok: []const u8) bool {
    for (junk_tokens) |j| if (lowerEq(tok, j)) return true;
    return false;
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn isYear(tok: []const u8) bool {
    if (tok.len != 4 or !allDigits(tok)) return false;
    const y = std.fmt.parseInt(u16, tok, 10) catch return false;
    return y >= 1900 and y <= 2100;
}

/// S01E02, s1e10, S01 (alone), 1x05.
fn isEpisodeMarker(tok: []const u8) bool {
    if (tok.len >= 2 and (tok[0] == 's' or tok[0] == 'S') and std.ascii.isDigit(tok[1])) {
        var i: usize = 1;
        while (i < tok.len and std.ascii.isDigit(tok[i])) i += 1;
        if (i - 1 > 3) return false;
        if (i == tok.len) return true; // "S01"
        if ((tok[i] == 'e' or tok[i] == 'E') and i + 1 < tok.len) {
            var j = i + 1;
            while (j < tok.len and std.ascii.isDigit(tok[j])) j += 1;
            return j == tok.len and j - i - 1 <= 4;
        }
        return false;
    }
    if (tok.len >= 3 and std.ascii.isDigit(tok[0])) {
        const x = std.mem.indexOfAny(u8, tok, "xX") orelse return false;
        return x >= 1 and x <= 2 and allDigits(tok[0..x]) and tok.len - x - 1 >= 2 and tok.len - x - 1 <= 3 and allDigits(tok[x + 1 ..]);
    }
    return false;
}

fn isUpperAlnum(s: []const u8) bool {
    var upper: usize = 0;
    for (s) |c| {
        if (std.ascii.isLower(c)) return false;
        if (!std.ascii.isAlphanumeric(c)) return false;
        if (std.ascii.isUpper(c)) upper += 1;
    }
    return upper >= 2;
}

/// Does a title that already went through `display_name_pure.clean` still look
/// like a release name rather than a human title? Errs on the side of "messy":
/// the worst outcome of a false positive is one more name in a batch the agent
/// may leave alone.
pub fn looksMessy(cleaned: []const u8) bool {
    const t = std.mem.trim(u8, cleaned, " \t\r\n");
    if (t.len == 0 or t.len > 80) return true;

    var letters: usize = 0;
    var dots_underscores: usize = 0;
    for (t) |c| {
        if (std.ascii.isAlphabetic(c) or c >= 0x80) letters += 1;
        if (c == '.' or c == '_') dots_underscores += 1;
    }
    if (letters == 0) return true; // empty, numeric-only or punctuation-only
    if (dots_underscores >= 3) return true;
    if (t[0] == '[') return true; // "[Group] Title - 05 [ABCD1234]"

    var signal_year_or_episode = false;
    var web_pending = false;
    var it = std.mem.tokenizeAny(u8, t, " \t-.,_()[]{}+");
    while (it.next()) |tok| {
        if (isJunkToken(tok)) return true;
        if (lowerEq(tok, "web")) web_pending = true else if (web_pending and (lowerEq(tok, "dl") or lowerEq(tok, "rip"))) return true else web_pending = false;
        if (isEpisodeMarker(tok)) return true;
        if (isYear(tok)) signal_year_or_episode = true;
        // 8 hex digits in brackets are a CRC; bare they are rare, skip.
    }

    // Trailing "-GROUP" after a year: "Some Movie 2019-GRP". Titles such as
    // "Spider-Man" or "X-MEN" have no year/marker and are left alone.
    if (signal_year_or_episode) {
        const last_space = std.mem.lastIndexOfScalar(u8, t, ' ') orelse 0;
        const last_word = std.mem.trim(u8, t[last_space..], " ");
        if (std.mem.lastIndexOfScalar(u8, last_word, '-')) |dash| {
            if (dash > 0 and isUpperAlnum(last_word[dash + 1 ..]) and last_word.len - dash - 1 <= 12) return true;
        }
    }
    return false;
}

// ── Context for the agent ───────────────────────────────────────────────

pub fn basename(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |c, i| if (c == '/' or c == '\\') {
        start = i + 1;
    };
    return path[start..];
}

pub const Add = enum { added, skipped, full };

/// Up to MAX_ITEMS files, one `index<TAB>filename` line each. Only the final path
/// component is ever written: directories reveal the user's folder layout.
pub const Batch = struct {
    rowids: [MAX_ITEMS]i64 = undefined,
    /// Hash of the cleaned title when the row was picked; the handler skips a row
    /// whose title changed since (the file behind the rowid is not the one asked about).
    hashes: [MAX_ITEMS]u64 = undefined,
    count: usize = 0,
    buf: [CONTEXT_MAX]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const Batch) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn add(self: *Batch, rowid: i64, path: []const u8, cleaned: []const u8) Add {
        if (self.count >= MAX_ITEMS) return .full;
        var name = basename(path);
        if (name.len > BASENAME_MAX) {
            var cut: usize = BASENAME_MAX;
            while (cut > 0 and (name[cut] & 0xC0) == 0x80) cut -= 1;
            name = name[0..cut];
        }
        name = std.mem.trim(u8, name, " ");
        if (name.len == 0) return .skipped;
        var clean: [BASENAME_MAX]u8 = undefined;
        for (name, 0..) |c, i| clean[i] = if (c < 0x20 or c == 0x7f) ' ' else c;
        const line = std.fmt.bufPrint(self.buf[self.len..], "{d}\t{s}\n", .{ self.count, clean[0..name.len] }) catch return .full;
        self.len += line.len;
        self.rowids[self.count] = rowid;
        self.hashes[self.count] = titleHash(cleaned);
        self.count += 1;
        return .added;
    }
};

pub fn titleHash(cleaned: []const u8) u64 {
    return std.hash.Wyhash.hash(0x6e61_6d65_73, cleaned);
}

/// Short stable id of a batch: derived from its first rowid (cooldown is per kind+key).
pub fn batchKey(buf: []u8, first_rowid: i64) []const u8 {
    return std.fmt.bufPrint(buf, "n{d}", .{first_rowid}) catch buf[0..0];
}

// ── Validating the answer ───────────────────────────────────────────────

pub const MediaKind = enum {
    movie,
    tv,
    music,
    audiobook,
    other,

    pub fn id(self: MediaKind) []const u8 {
        return @tagName(self);
    }
};

pub const Item = struct {
    index: u8 = 0,
    title: [TITLE_MAX]u8 = undefined,
    title_len: u8 = 0,
    kind: MediaKind = .other,
    /// 0 when unknown. Kept for later use; the title never carries it.
    year: u16 = 0,

    pub fn titleText(self: *const Item) []const u8 {
        return self.title[0..self.title_len];
    }
};

pub const Names = struct {
    items: [MAX_ITEMS]Item = undefined,
    count: usize = 0,
};

/// A title an agent proposed for display: 1..120 bytes of valid UTF-8, no control
/// characters, no path separators or angle brackets, at least one letter.
pub fn validTitle(t: []const u8) bool {
    if (t.len == 0 or t.len > TITLE_MAX) return false;
    if (!std.unicode.utf8ValidateSlice(t)) return false;
    var letters: usize = 0;
    for (t) |c| {
        if (c < 0x20 or c == 0x7f) return false;
        if (c == '/' or c == '\\' or c == '<' or c == '>') return false;
        if (std.ascii.isAlphabetic(c) or c >= 0x80) letters += 1;
    }
    return letters > 0;
}

/// Keep the valid items of `{"items":[{index,title,kind,year?}...]}`. `batch_count`
/// is how many files were asked about. Invalid or repeated items are dropped;
/// null when none survives.
pub fn parseLocalNames(allocator: std.mem.Allocator, json: []const u8, batch_count: usize) ?Names {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const list = parsed.value.object.get("items") orelse return null;
    if (list != .array) return null;
    var out = Names{};
    var seen = [_]bool{false} ** MAX_ITEMS;
    for (list.array.items) |entry| {
        if (entry != .object) continue;
        const obj = entry.object;
        const idx_v = obj.get("index") orelse continue;
        if (idx_v != .integer or idx_v.integer < 0 or idx_v.integer >= @as(i64, @intCast(@min(batch_count, MAX_ITEMS)))) continue;
        const idx: usize = @intCast(idx_v.integer);
        if (seen[idx]) continue;
        const title_v = obj.get("title") orelse continue;
        if (title_v != .string) continue;
        const title = std.mem.trim(u8, title_v.string, " ");
        if (!validTitle(title)) continue;
        const kind_v = obj.get("kind") orelse continue;
        if (kind_v != .string) continue;
        const kind = std.meta.stringToEnum(MediaKind, kind_v.string) orelse continue;
        var year: u16 = 0;
        if (obj.get("year")) |y| if (y == .integer and y.integer > 0 and y.integer <= 2200) {
            year = @intCast(y.integer);
        };
        seen[idx] = true;
        var item = Item{ .index = @intCast(idx), .kind = kind, .year = year };
        @memcpy(item.title[0..title.len], title);
        item.title_len = @intCast(title.len);
        out.items[out.count] = item;
        out.count += 1;
    }
    return if (out.count == 0) null else out;
}

// ── Applying ────────────────────────────────────────────────────────────

pub const Tally = struct { applied: usize = 0, skipped: usize = 0 };

/// What the target reports about a row before it is changed.
pub const Current = struct {
    /// The user (or an earlier run) has not set a display title.
    display_empty: bool,
    /// The automatically cleaned title right now.
    title: []const u8,
    /// Hash of that title as it was when the batch was picked.
    asked_hash: u64,
};

/// Apply each item to its row through `target`, which provides
/// `current(row_id) ?Current` and `apply(row_id, title, kind_id) bool`. A row is
/// left alone when it is unknown, when it already has a display title, when its
/// title changed since it was asked about, or when the answer equals its cleaned title.
pub fn applyNames(names: *const Names, rowids: []const i64, target: anytype) Tally {
    var tally = Tally{};
    for (names.items[0..names.count]) |*item| {
        if (item.index >= rowids.len or rowids[item.index] <= 0) {
            tally.skipped += 1;
            continue;
        }
        const row_id = rowids[item.index];
        const cur = target.current(row_id) orelse {
            tally.skipped += 1;
            continue;
        };
        if (!cur.display_empty or titleHash(cur.title) != cur.asked_hash or std.mem.eql(u8, cur.title, item.titleText())) {
            tally.skipped += 1;
            continue;
        }
        if (target.apply(row_id, item.titleText(), item.kind.id())) tally.applied += 1 else tally.skipped += 1;
    }
    return tally;
}

/// True when the answer is a well formed `{"items":[]}`: the agent looked and could
/// not identify any file. That is an honest answer (the prompt tells it to leave out
/// what it cannot decide), not a failure, so the schema allows it.
pub fn declinedAll(allocator: std.mem.Allocator, json: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const list = parsed.value.object.get("items") orelse return false;
    return list == .array and list.array.items.len == 0;
}

/// When a job that asked about a batch failed (agent error, unusable answer,
/// interruption), the files are marked as asked again only after this long instead
/// of the full re-ask window: a missing sign-in must not lock them out for weeks,
/// but a broken agent must not be paid for on every scan either.
pub const RETRY_AFTER_FAILURE_MS: i64 = 24 * 60 * 60 * 1000;

/// The `asked_ms` to store so that a file counts as asked until `now + retry_ms`,
/// given that files are skipped while `asked_ms > now' - reask_ms`.
pub fn retryMarker(now_ms: i64, reask_ms: i64, retry_ms: i64) i64 {
    return now_ms - reask_ms + retry_ms;
}

/// Parse, apply and describe. `rowids[i]` is the row asked about as index i (<= 0
/// when unknown).
pub fn handleAnswer(allocator: std.mem.Allocator, result_json: []const u8, rowids: []const i64, target: anytype) op.Handled {
    if (declinedAll(allocator, result_json)) return op.Handled.make(.applied, "The agent could not identify any of these files", .{});
    const names = parseLocalNames(allocator, result_json, rowids.len) orelse
        return op.Handled.make(.failed, "No usable file names", .{});
    const tally = applyNames(&names, rowids, target);
    if (tally.applied == 0) return op.Handled.make(.applied, "No file names needed changing", .{});
    return op.Handled.make(.applied, "Cleaned {d} file name{s}", .{ tally.applied, if (tally.applied == 1) "" else "s" });
}

// ── Tests ───────────────────────────────────────────────────────────────

test "messy release names are recognised" {
    const messy = [_][]const u8{
        "Dune Part Two 2024 1080p WEB-DL DDP5 1 Atmos x264-FLUX",
        "The Matrix 1999 BluRay 720p x264 YIFY",
        "Breaking Bad S01E02 720p HDTV x264-CTU",
        "Show Name 1x05 Title",
        "Some Show S02",
        "[SubsPlease] Frieren - 12 (1080p) [ABCD1234]",
        "www UIndex org - Movie 2020",
        "Movie Title 2019-RARBG",
        "Movie Title 2019-GRP",
        "Artist - Album 2005 FLAC",
        "Movie WEBRip",
        "Movie WEB DL",
        "a.b.c.d",
        "",
        "   ",
        "20240807175012",
        "1917",
        "(2019) - ...",
        "A Very Long Title That Goes On And On And On And On And On And On And On And On And On And Beyond",
        "Oppenheimer 2023 2160p UHD BluRay REMUX HDR HEVC",
    };
    for (messy) |t| {
        errdefer std.debug.print("expected messy: '{s}'\n", .{t});
        try std.testing.expect(looksMessy(t));
    }
}

test "ordinary human titles are not messy" {
    const clean = [_][]const u8{
        "Dune Part Two",
        "Spirited Away",
        "Spider-Man",
        "X-MEN",
        "WALL-E",
        "Blade Runner 2049",
        "The Matrix 1999",
        "Se7en",
        "Movie 43",
        "Making music symbol with dust",
        "千と千尋の神隠し",
        "Amélie",
        "Mr. Robot",
        "The Web",
        "Evo",
        "Crouching Tiger, Hidden Dragon (2000)",
        "Pink Floyd - The Wall",
        "Spider-Man 2002",
    };
    for (clean) |t| {
        errdefer std.debug.print("expected clean: '{s}'\n", .{t});
        try std.testing.expect(!looksMessy(t));
    }
}

test "basename drops every directory" {
    try std.testing.expectEqualStrings("a.mkv", basename("/home/me/Movies/a.mkv"));
    try std.testing.expectEqualStrings("a.mkv", basename("C:\\Users\\me\\a.mkv"));
    try std.testing.expectEqualStrings("a.mkv", basename("a.mkv"));
    try std.testing.expectEqualStrings("", basename("/dir/"));
}

test "context lists basenames only, with indexes, and never directories" {
    var b = Batch{};
    try std.testing.expectEqual(Add.added, b.add(11, "/home/secret_user/Private Folder/Dune.2021.1080p.mkv", "Dune 2021 1080p"));
    try std.testing.expectEqual(Add.added, b.add(12, "C:\\Users\\me\\Videos\\Show.S01E02.mkv", "Show S01E02"));
    try std.testing.expectEqual(Add.skipped, b.add(13, "/dir/", "x"));
    try std.testing.expectEqualStrings("0\tDune.2021.1080p.mkv\n1\tShow.S01E02.mkv\n", b.text());
    try std.testing.expect(std.mem.indexOf(u8, b.text(), "secret_user") == null);
    try std.testing.expect(std.mem.indexOf(u8, b.text(), "Videos") == null);
    try std.testing.expectEqual(@as(usize, 2), b.count);
    try std.testing.expectEqual(@as(i64, 12), b.rowids[1]);
}

test "context neutralises tabs and newlines inside file names" {
    var b = Batch{};
    try std.testing.expectEqual(Add.added, b.add(1, "/x/evil\nname\twith\x01ctl.mkv", "evil"));
    try std.testing.expectEqualStrings("0\tevil name with ctl.mkv\n", b.text());
}

test "context holds at most 20 files and 3000 bytes" {
    var b = Batch{};
    var i: usize = 0;
    var path: [200]u8 = undefined;
    while (i < 40) : (i += 1) {
        const p = std.fmt.bufPrint(&path, "/d/File.Number.{d}.1080p.WEB-DL.x264-GROUP.mkv", .{i}) catch unreachable;
        if (b.add(@intCast(i + 1), p, "x") == .full) break;
    }
    try std.testing.expectEqual(@as(usize, MAX_ITEMS), b.count);
    try std.testing.expect(b.len <= CONTEXT_MAX);

    // Long names: the byte cap stops the batch before 20 files.
    var big = Batch{};
    const long = "/d/" ++ "L" ** 300 ++ ".mkv";
    var n: usize = 0;
    while (big.add(@intCast(n + 1), long, "x") == .added) n += 1;
    try std.testing.expect(n < MAX_ITEMS);
    try std.testing.expect(big.len <= CONTEXT_MAX);
    // Each name was cut to BASENAME_MAX.
    try std.testing.expect(std.mem.indexOf(u8, big.text(), "L" ** (BASENAME_MAX + 1)) == null);
}

test "long multibyte names are cut on a character boundary" {
    var b = Batch{};
    const name = "/d/" ++ "é" ** 100 ++ ".mkv"; // 200 bytes
    try std.testing.expectEqual(Add.added, b.add(1, name, "x"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(b.text()));
}

test "batch key is short and stable" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("n4711", batchKey(&buf, 4711));
    try std.testing.expectEqualStrings("n4711", batchKey(&buf, 4711));
}

test "validator keeps only sound items" {
    const a = std.testing.allocator;
    const n = parseLocalNames(a,
        \\{"items":[
        \\ {"index":0,"title":"Dune: Part Two","kind":"movie","year":2024},
        \\ {"index":0,"title":"Duplicate index","kind":"movie"},
        \\ {"index":1,"title":"Breaking Bad","kind":"tv"},
        \\ {"index":2,"title":"Bad/Path","kind":"movie"},
        \\ {"index":3,"title":"<script>","kind":"movie"},
        \\ {"index":4,"title":"Not a kind","kind":"video"},
        \\ {"index":5,"title":"Out of range","kind":"movie"},
        \\ {"index":-1,"title":"Negative","kind":"movie"},
        \\ {"index":"1","title":"String index","kind":"movie"},
        \\ {"index":2,"title":"12345","kind":"movie"},
        \\ {"index":2,"title":"Line\nbreak","kind":"movie"},
        \\ {"index":2,"title":"Win\\Path","kind":"movie"},
        \\ {"index":2,"title":"","kind":"movie"},
        \\ {"index":2,"title":"Fine Album","kind":"music","year":99999}
        \\],"reason":"r"}
    , 5).?;
    try std.testing.expectEqual(@as(usize, 3), n.count);
    try std.testing.expectEqualStrings("Dune: Part Two", n.items[0].titleText());
    try std.testing.expectEqual(MediaKind.movie, n.items[0].kind);
    try std.testing.expectEqual(@as(u16, 2024), n.items[0].year);
    try std.testing.expectEqual(@as(u8, 1), n.items[1].index);
    try std.testing.expectEqual(MediaKind.tv, n.items[1].kind);
    try std.testing.expectEqualStrings("Fine Album", n.items[2].titleText());
    try std.testing.expectEqual(@as(u16, 0), n.items[2].year); // out-of-range year is ignored, not trusted
}

test "validator rejects control characters, long titles and unusable shapes" {
    const a = std.testing.allocator;
    try std.testing.expect(parseLocalNames(a, "{\"items\":[{\"index\":0,\"title\":\"a\\u0000b\",\"kind\":\"tv\"}]}", 3) == null);
    try std.testing.expect(parseLocalNames(a, "{\"items\":[{\"index\":0,\"title\":\"a\\u007fb\",\"kind\":\"tv\"}]}", 3) == null);
    const long = "{\"items\":[{\"index\":0,\"title\":\"" ++ "x" ** 121 ++ "\",\"kind\":\"tv\"}]}";
    try std.testing.expect(parseLocalNames(a, long, 3) == null);
    const edge = "{\"items\":[{\"index\":0,\"title\":\"" ++ "x" ** 120 ++ "\",\"kind\":\"tv\"}]}";
    try std.testing.expect(parseLocalNames(a, edge, 3) != null);
    try std.testing.expect(parseLocalNames(a, "{\"items\":[]}", 3) == null);
    try std.testing.expect(parseLocalNames(a, "{\"items\":\"x\"}", 3) == null);
    try std.testing.expect(parseLocalNames(a, "{\"nope\":1}", 3) == null);
    try std.testing.expect(parseLocalNames(a, "[1]", 3) == null);
    try std.testing.expect(parseLocalNames(a, "not json", 3) == null);
    // index must be inside the batch that was asked about
    try std.testing.expect(parseLocalNames(a, "{\"items\":[{\"index\":3,\"title\":\"Ok\",\"kind\":\"tv\"}]}", 3) == null);
    try std.testing.expect(parseLocalNames(a, "{\"items\":[{\"index\":2,\"title\":\"Ok\",\"kind\":\"tv\"}]}", 3) != null);
    // invalid UTF-8 never reaches the display
    try std.testing.expect(!validTitle("bad\xff\xfe"));
    try std.testing.expect(validTitle("千と千尋の神隠し"));
    try std.testing.expect(!validTitle("...---"));
}

const FakeRow = struct { id: i64, display_empty: bool, title: []const u8, asked: []const u8 };

const FakeTarget = struct {
    rows: []const FakeRow,
    applied_ids: [8]i64 = undefined,
    applied_titles: [8][]const u8 = undefined,
    applied_kinds: [8][]const u8 = undefined,
    applied: usize = 0,
    refuse: bool = false,

    fn current(self: *FakeTarget, id: i64) ?Current {
        for (self.rows) |r| if (r.id == id) return .{ .display_empty = r.display_empty, .title = r.title, .asked_hash = titleHash(r.asked) };
        return null;
    }

    fn apply(self: *FakeTarget, id: i64, title: []const u8, kind: []const u8) bool {
        if (self.refuse) return false;
        self.applied_ids[self.applied] = id;
        self.applied_titles[self.applied] = title;
        self.applied_kinds[self.applied] = kind;
        self.applied += 1;
        return true;
    }
};

test "handler applies only to untouched rows whose title still matches what was asked" {
    const a = std.testing.allocator;
    const rows = [_]FakeRow{
        .{ .id = 100, .display_empty = true, .title = "Dune 2021 1080p", .asked = "Dune 2021 1080p" },
        .{ .id = 101, .display_empty = false, .title = "My own name", .asked = "My own name" }, // user set a title
        .{ .id = 102, .display_empty = true, .title = "Same", .asked = "Same" }, // answer equals cleaned title
        .{ .id = 103, .display_empty = true, .title = "Changed now", .asked = "Other when asked" }, // different file now
        .{ .id = 104, .display_empty = true, .title = "Show S01E02", .asked = "Show S01E02" },
    };
    var t = FakeTarget{ .rows = &rows };
    const rowids = [_]i64{ 100, 101, 102, 103, 104, 0 };
    const h = handleAnswer(a,
        \\{"items":[
        \\ {"index":0,"title":"Dune","kind":"movie","year":2021},
        \\ {"index":1,"title":"Overwrite attempt","kind":"movie"},
        \\ {"index":2,"title":"Same","kind":"movie"},
        \\ {"index":3,"title":"Stale","kind":"movie"},
        \\ {"index":4,"title":"Show","kind":"tv"},
        \\ {"index":5,"title":"No row","kind":"tv"}
        \\],"reason":"r"}
    , &rowids, &t);
    try std.testing.expectEqual(op.State.applied, h.state);
    try std.testing.expectEqualStrings("Cleaned 2 file names", h.text());
    try std.testing.expectEqual(@as(usize, 2), t.applied);
    try std.testing.expectEqual(@as(i64, 100), t.applied_ids[0]);
    try std.testing.expectEqualStrings("Dune", t.applied_titles[0]);
    try std.testing.expectEqualStrings("movie", t.applied_kinds[0]);
    try std.testing.expectEqual(@as(i64, 104), t.applied_ids[1]);
    try std.testing.expectEqualStrings("tv", t.applied_kinds[1]);
}

test "handler fails on an unusable answer and says so when nothing changed" {
    const a = std.testing.allocator;
    const rows = [_]FakeRow{.{ .id = 1, .display_empty = true, .title = "A b", .asked = "A b" }};
    var t = FakeTarget{ .rows = &rows };
    const rowids = [_]i64{1};
    const bad = handleAnswer(a, "{\"items\":[{\"index\":0,\"title\":\"a/b\",\"kind\":\"movie\"}]}", &rowids, &t);
    try std.testing.expectEqual(op.State.failed, bad.state);
    try std.testing.expectEqual(@as(usize, 0), t.applied);
    t.refuse = true;
    const none = handleAnswer(a, "{\"items\":[{\"index\":0,\"title\":\"Fine\",\"kind\":\"movie\"}]}", &rowids, &t);
    try std.testing.expectEqual(op.State.applied, none.state);
    try std.testing.expectEqualStrings("No file names needed changing", none.text());
    t.refuse = false;
    const one = handleAnswer(a, "{\"items\":[{\"index\":0,\"title\":\"Fine\",\"kind\":\"movie\"}]}", &rowids, &t);
    try std.testing.expectEqualStrings("Cleaned 1 file name", one.text());
}

test "an empty answer is a decline, not a failure" {
    const a = std.testing.allocator;
    const rows = [_]FakeRow{.{ .id = 1, .display_empty = true, .title = "A b", .asked = "A b" }};
    var t = FakeTarget{ .rows = &rows };
    const rowids = [_]i64{1};
    const none = handleAnswer(a, "{\"items\":[],\"reason\":\"cannot tell\"}", &rowids, &t);
    try std.testing.expectEqual(op.State.applied, none.state);
    try std.testing.expectEqual(@as(usize, 0), t.applied);
    try std.testing.expect(!declinedAll(a, "{\"items\":[{\"index\":0}]}"));
    try std.testing.expect(!declinedAll(a, "{\"items\":5}"));
    try std.testing.expect(!declinedAll(a, "not json"));
    // Every item invalid is still a failure.
    try std.testing.expectEqual(op.State.failed, handleAnswer(a, "{\"items\":[{\"index\":9,\"title\":\"x\",\"kind\":\"movie\"}]}", &rowids, &t).state);
}

test "a failed batch is asked again after a day, not after two weeks" {
    const reask: i64 = 14 * 24 * 60 * 60 * 1000;
    const now: i64 = 50 * 24 * 60 * 60 * 1000;
    const marker = retryMarker(now, reask, RETRY_AFTER_FAILURE_MS);
    // The scan skips a row while asked_ms > t - reask.
    const skipped = struct {
        fn at(m: i64, t: i64) bool {
            return m > t - 14 * 24 * 60 * 60 * 1000;
        }
    }.at;
    try std.testing.expect(skipped(marker, now + RETRY_AFTER_FAILURE_MS - 1000));
    try std.testing.expect(!skipped(marker, now + RETRY_AFTER_FAILURE_MS + 1000));
}
