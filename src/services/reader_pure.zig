//! Comic / manga reader decisions: pure, unit-tested (test_reader_pure).
//!
//! services/comics.zig (native reader) routes its page cache, huge-page
//! downscale, spread / RTL ordering, zoom, resume keys, archive entry
//! sanitisation and embedded-link checks through this module, so the tested
//! logic is the shipped logic. No dvui / app-state imports.

const std = @import("std");

// ══════════════════════════════════════════════════════════
// Reading modes, spreads and page stepping
// ══════════════════════════════════════════════════════════

pub const Mode = enum { scroll, single_page, spread };

/// Toolbar cycle: scroll -> single page -> two-page spread -> scroll.
pub fn nextMode(mode: Mode) Mode {
    return switch (mode) {
        .scroll => .single_page,
        .single_page => .spread,
        .spread => .scroll,
    };
}

pub const Spread = struct { first: usize, second: ?usize = null };

/// The spread containing `page`. The cover (page 0) stands alone, then pages
/// pair (1,2), (3,4), ...; a trailing odd page stands alone. `page` is clamped.
pub fn spreadAt(page: usize, count: usize) Spread {
    if (count == 0) return .{ .first = 0 };
    const p = @min(page, count - 1);
    if (p == 0) return .{ .first = 0 };
    const start = if (p % 2 == 1) p else p - 1;
    return .{ .first = start, .second = if (start + 1 < count) start + 1 else null };
}

/// Left-to-right screen order of a spread. Right-to-left books (manga) put the
/// later page on the left.
pub fn displayOrder(s: Spread, rtl: bool) [2]?usize {
    if (s.second) |second| {
        return if (rtl) .{ second, s.first } else .{ s.first, second };
    }
    return .{ s.first, null };
}

pub const Direction = enum { previous, next };

/// The page index one step away in reading order, or null at either end.
/// Spread mode moves a whole spread and always lands on its first page.
pub fn stepPage(mode: Mode, page: usize, count: usize, dir: Direction) ?usize {
    if (count == 0) return null;
    const p = @min(page, count - 1);
    if (mode != .spread) {
        return switch (dir) {
            .next => if (p + 1 < count) p + 1 else null,
            .previous => if (p > 0) p - 1 else null,
        };
    }
    const s = spreadAt(p, count);
    return switch (dir) {
        .next => blk: {
            const last = s.second orelse s.first;
            break :blk if (last + 1 < count) last + 1 else null;
        },
        .previous => if (s.first == 0) null else spreadAt(s.first - 1, count).first,
    };
}

pub const NavKey = enum { left, right, j, k };

/// Arrow keys follow the page layout: in a right-to-left book the left arrow
/// turns forward. J / K stay previous / next in both directions.
pub fn keyDirection(key: NavKey, rtl: bool) Direction {
    return switch (key) {
        .left => if (rtl) .next else .previous,
        .right => if (rtl) .previous else .next,
        .j => .previous,
        .k => .next,
    };
}

// ══════════════════════════════════════════════════════════
// Decoded-page cache: byte budget + neighbour window
// ══════════════════════════════════════════════════════════

/// Pages kept decoded on either side of what is on screen.
pub const NEIGHBOUR_RADIUS: usize = 2;
/// Total decoded RGBA bytes the reader keeps resident across all pages.
pub const TEXTURE_BUDGET_BYTES: u64 = 256 * 1024 * 1024;

pub fn textureBytes(width: u32, height: u32) u64 {
    return @as(u64, width) * @as(u64, height) * 4;
}

pub fn residentTotal(resident: []const u64) u64 {
    var total: u64 = 0;
    for (resident) |bytes| total +|= bytes;
    return total;
}

fn distance(page: usize, lo: usize, hi: usize) usize {
    if (page < lo) return lo - page;
    if (page > hi) return page - hi;
    return 0;
}

/// The next resident page to free, or null when the cache is within policy.
/// `resident[i]` is page i's decoded bytes (0 = not resident). Pages in
/// [visible_lo, visible_hi] are never chosen. Pages outside the neighbour
/// window go first, farthest first; then, while the total is over `budget`,
/// the farthest remaining off-screen page. The caller frees and calls again.
pub fn pickEviction(resident: []const u64, visible_lo: usize, visible_hi: usize, radius: usize, budget: u64) ?usize {
    const over = residentTotal(resident) > budget;
    var best: ?usize = null;
    var best_dist: usize = 0;
    for (resident, 0..) |bytes, i| {
        if (bytes == 0) continue;
        const d = distance(i, visible_lo, visible_hi);
        if (d == 0) continue;
        if (d <= radius and !over) continue;
        if (best == null or d > best_dist) {
            best = i;
            best_dist = d;
        }
    }
    return best;
}

/// Whether an off-screen neighbour may be decoded ahead of time: it must sit
/// inside the neighbour window and the cache must have room left.
pub fn prefetchAllowed(page: usize, visible_lo: usize, visible_hi: usize, radius: usize, resident_total: u64, budget: u64) bool {
    const d = distance(page, visible_lo, visible_hi);
    return d > 0 and d <= radius and resident_total < budget;
}

// ══════════════════════════════════════════════════════════
// Huge pages: integer box downscale before upload
// ══════════════════════════════════════════════════════════

/// Largest texture edge the reader uploads (common GPU limit).
pub const MAX_TEXTURE_EDGE: u32 = 16384;
/// Largest single decoded page the reader keeps.
pub const MAX_TEXTURE_BYTES: u64 = 64 * 1024 * 1024;

pub const Dims = struct { w: u32, h: u32 };

pub fn scaledDims(w: u32, h: u32, factor: u32) Dims {
    const f = @max(factor, 1);
    return .{ .w = @max(w / f, 1), .h = @max(h / f, 1) };
}

/// Smallest integer factor that brings a page within the edge and byte caps.
/// 1 means "already fits". 0 x 0 pages return 1 (the decoder rejects them).
pub fn downscaleFactor(w: u32, h: u32, max_edge: u32, max_bytes: u64) u32 {
    if (w == 0 or h == 0) return 1;
    var f: u32 = 1;
    while (f < 1024) : (f += 1) {
        const d = scaledDims(w, h, f);
        if (d.w <= max_edge and d.h <= max_edge and textureBytes(d.w, d.h) <= max_bytes) return f;
    }
    return f;
}

/// Average each `factor` x `factor` block of RGBA `pixels` (w x h) into the
/// front of the same buffer. Safe in place: destination pixel j is written only
/// after its block, which starts at or after source pixel j, has been read.
/// Returns the new dimensions; bytes past w'*h'*4 are left as garbage.
pub fn boxDownscaleInPlace(pixels: []u8, w: u32, h: u32, factor: u32) Dims {
    if (factor <= 1 or w == 0 or h == 0) return .{ .w = w, .h = h };
    if (pixels.len < @as(usize, w) * h * 4) return .{ .w = w, .h = h };
    const d = scaledDims(w, h, factor);
    const sw: usize = w;
    var y: usize = 0;
    while (y < d.h) : (y += 1) {
        const y0 = y * factor;
        const y1 = @min(y0 + factor, h);
        var x: usize = 0;
        while (x < d.w) : (x += 1) {
            const x0 = x * factor;
            const x1 = @min(x0 + factor, w);
            var sum = [4]u64{ 0, 0, 0, 0 };
            var yy = y0;
            while (yy < y1) : (yy += 1) {
                var xx = x0;
                while (xx < x1) : (xx += 1) {
                    const s = (yy * sw + xx) * 4;
                    inline for (0..4) |c| sum[c] += pixels[s + c];
                }
            }
            const n: u64 = (y1 - y0) * (x1 - x0);
            const o = (y * d.w + x) * 4;
            inline for (0..4) |c| pixels[o + c] = @intCast((sum[c] + n / 2) / n);
        }
    }
    return d;
}

// ══════════════════════════════════════════════════════════
// Zoom + fit
// ══════════════════════════════════════════════════════════

pub const ZOOM_MIN: f32 = 0.5;
pub const ZOOM_MAX: f32 = 4.0;
pub const ZOOM_STEP: f32 = 1.25;

pub fn clampZoom(z: f32) f32 {
    if (std.math.isNan(z) or std.math.isInf(z)) return 1.0;
    return std.math.clamp(z, ZOOM_MIN, ZOOM_MAX);
}
pub fn zoomIn(z: f32) f32 {
    return clampZoom(clampZoom(z) * ZOOM_STEP);
}
pub fn zoomOut(z: f32) f32 {
    return clampZoom(clampZoom(z) / ZOOM_STEP);
}

pub const Fit = enum { width, page };
pub const Size = struct { w: f32, h: f32 };

/// On-screen size of a `tw` x `th` page in an `avail_w` x `avail_h` box.
/// `.width` fills the width (long strips scroll); `.page` fits the whole page.
pub fn displaySize(tw: u32, th: u32, avail_w: f32, avail_h: f32, fit: Fit, zoom: f32) Size {
    if (tw == 0 or th == 0 or !(avail_w > 0)) return .{ .w = 0, .h = 0 };
    const fw: f32 = @floatFromInt(tw);
    const fh: f32 = @floatFromInt(th);
    const by_width = avail_w / fw;
    const fitted: f32 = switch (fit) {
        .width => by_width,
        .page => if (avail_h > 0) @min(by_width, avail_h / fh) else by_width,
    };
    const scale = fitted * clampZoom(zoom);
    return .{ .w = fw * scale, .h = fh * scale };
}

// ══════════════════════════════════════════════════════════
// Resume keys: server identity + book / chapter id, never the title
// ══════════════════════════════════════════════════════════

const Authority = struct { scheme: []const u8, host: []const u8, port: ?[]const u8, rest: []const u8 };

fn splitAuthority(url: []const u8) ?Authority {
    const sep = std.mem.indexOf(u8, url, "://") orelse return null;
    const scheme = url[0..sep];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) return null;
    const after = url[sep + 3 ..];
    const auth_end = std.mem.indexOfAny(u8, after, "/?#") orelse after.len;
    var authority = after[0..auth_end];
    // Credentials never become part of an identity.
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    var host = authority;
    var port: ?[]const u8 = null;
    if (authority.len > 0 and authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
        host = authority[0 .. close + 1];
        if (close + 1 < authority.len) {
            if (authority[close + 1] != ':') return null;
            port = authority[close + 2 ..];
        }
    } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port = authority[colon + 1 ..];
    }
    if (host.len == 0) return null;
    if (port) |p| {
        if (p.len == 0 or p.len > 5) return null;
        for (p) |ch| if (!std.ascii.isDigit(ch)) return null;
    }
    return .{ .scheme = scheme, .host = host, .port = port, .rest = after[auth_end..] };
}

fn writeLower(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| try w.writeByte(std.ascii.toLower(ch));
}

fn writeIdentity(w: *std.Io.Writer, a: Authority) !void {
    try writeLower(w, a.scheme);
    try w.writeAll("://");
    try writeLower(w, a.host);
    try w.writeByte(':');
    if (a.port) |p| {
        const n = std.fmt.parseInt(u32, p, 10) catch 0;
        try w.print("{d}", .{n});
    } else {
        try w.writeAll(if (std.ascii.eqlIgnoreCase(a.scheme, "https")) "443" else "80");
    }
}

/// `scheme://host:port`, lowercased, credentials dropped, default port explicit.
pub fn serverIdentity(url: []const u8, out: []u8) ?[]const u8 {
    const a = splitAuthority(url) orelse return null;
    var w = std.Io.Writer.fixed(out);
    writeIdentity(&w, a) catch return null;
    return w.buffered();
}

/// Resume key for a URL-addressed issue: server identity + path + query, with
/// credentials and fragment dropped. Pseudo routes (`mangadex:<id>`, `cbz:`)
/// are already server-independent ids and pass through. "" when it won't fit.
pub fn urlResumeKey(url: []const u8, out: []u8) []const u8 {
    const a = splitAuthority(url) orelse {
        if (url.len > out.len) return out[0..0];
        @memcpy(out[0..url.len], url);
        return out[0..url.len];
    };
    var rest = a.rest;
    if (std.mem.indexOfScalar(u8, rest, '#')) |h| rest = rest[0..h];
    var w = std.Io.Writer.fixed(out);
    writeIdentity(&w, a) catch return out[0..0];
    w.writeAll(if (rest.len == 0) "/" else rest) catch return out[0..0];
    return w.buffered();
}

pub const PAGE_MARKER = "{pageNumber}";

/// The book id inside an OPDS-PSE page template: its path up to the segment
/// holding `{pageNumber}`, query dropped. `/api/v1/books/7/pages/{pageNumber}`
/// -> `/api/v1/books/7/pages`. Null when there is no marker or no path.
pub fn pseBookId(template: []const u8) ?[]const u8 {
    const a = splitAuthority(template) orelse return null;
    const path_end = std.mem.indexOfAny(u8, a.rest, "?#") orelse a.rest.len;
    const path = a.rest[0..path_end];
    const marker = std.mem.indexOf(u8, path, PAGE_MARKER) orelse return null;
    const seg_start = if (std.mem.lastIndexOfScalar(u8, path[0..marker], '/')) |s| s else return null;
    const id = std.mem.trimEnd(u8, path[0..seg_start], "/");
    if (id.len == 0) return null;
    return id;
}

/// Resume key for an OPDS-PSE book: `pse:` + server identity + book id. Two
/// servers that both carry "Vol. 1" no longer share a reading position.
pub fn pseResumeKey(template: []const u8, out: []u8) []const u8 {
    const a = splitAuthority(template) orelse return out[0..0];
    const id = pseBookId(template) orelse return out[0..0];
    var w = std.Io.Writer.fixed(out);
    w.writeAll("pse:") catch return out[0..0];
    writeIdentity(&w, a) catch return out[0..0];
    w.writeAll(id) catch return out[0..0];
    return w.buffered();
}

// ══════════════════════════════════════════════════════════
// Untrusted archive entries + embedded links
// ══════════════════════════════════════════════════════════

/// Normalise a CBZ/zip entry name into `out`, or null when it must not be
/// used: absolute paths, drive letters, backslashes, `..` segments, NUL or
/// control bytes, directories, macOS resource forks (`__MACOSX`, `._*`) and
/// other dot files. `.` and empty segments are dropped.
pub fn sanitizeEntryPath(name: []const u8, out: []u8) ?[]const u8 {
    if (name.len == 0 or name.len > out.len) return null;
    for (name) |ch| {
        if (ch < 0x20 or ch == 0x7f or ch == '\\') return null;
    }
    if (name[0] == '/') return null;
    if (name.len >= 2 and name[1] == ':') return null;
    if (name[name.len - 1] == '/') return null;
    var n: usize = 0;
    var last_start: usize = 0;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) return null;
        if (std.ascii.eqlIgnoreCase(seg, "__MACOSX")) return null;
        if (n > 0) {
            out[n] = '/';
            n += 1;
        }
        last_start = n;
        @memcpy(out[n..][0..seg.len], seg);
        n += seg.len;
    }
    if (n == 0) return null;
    if (out[last_start] == '.') return null; // ._resource forks, .DS_Store, …
    return out[0..n];
}

/// Whether an entry is a page image by extension.
pub fn isPageImage(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const ext = name[dot + 1 ..];
    inline for (.{ "jpg", "jpeg", "png", "webp", "gif", "bmp" }) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

/// Natural, case-insensitive order: "page2" < "page10", "P01" == "p1" by
/// value (ties fall back to byte order so the sort stays total).
pub fn naturalLess(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            var ie = i;
            while (ie < a.len and std.ascii.isDigit(a[ie])) ie += 1;
            var je = j;
            while (je < b.len and std.ascii.isDigit(b[je])) je += 1;
            const da = std.mem.trimStart(u8, a[i..ie], "0");
            const db = std.mem.trimStart(u8, b[j..je], "0");
            if (da.len != db.len) return da.len < db.len;
            const ord = std.mem.order(u8, da, db);
            if (ord != .eq) return ord == .lt;
            i = ie;
            j = je;
            continue;
        }
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[j]);
        if (ca != cb) return ca < cb;
        i += 1;
        j += 1;
    }
    if (a.len - i != b.len - j) return a.len - i < b.len - j;
    return std.mem.order(u8, a, b) == .lt;
}

/// An embedded link (next / previous issue, page image) scraped from untrusted
/// content: http(s) only, a host, no credentials, no whitespace / control /
/// backslash bytes. Rejects javascript:, data:, file: and friends.
pub fn isSafeLink(url: []const u8) bool {
    if (url.len < 8 or url.len > 2048) return false;
    for (url) |ch| {
        if (ch <= 0x20 or ch == 0x7f or ch == '\\') return false;
    }
    const sep = std.mem.indexOf(u8, url, "://") orelse return false;
    const scheme = url[0..sep];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) return false;
    const after = url[sep + 3 ..];
    const auth_end = std.mem.indexOfAny(u8, after, "/?#") orelse after.len;
    const authority = after[0..auth_end];
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return false;
    return splitAuthority(url) != null;
}

/// A local comic archive route opened in the reader: `cbz:<abs path>` ending
/// in `.cbz`. Only this explicit prefix routes to the archive reader, so a
/// scraped `file://` link or a bare path can never open a host file.
/// A local path (CLI arg, drag-drop, file association) that should open in
/// the comic reader rather than mpv: an absolute `.cbz` path the reader's
/// `cbz:` route accepts.
pub fn isLocalComicArchive(path: []const u8) bool {
    var buf: [520]u8 = undefined;
    if (path.len + 4 > buf.len) return false;
    @memcpy(buf[0..4], "cbz:");
    @memcpy(buf[4 .. 4 + path.len], path);
    return localArchivePath(buf[0 .. 4 + path.len]) != null;
}

pub fn localArchivePath(route: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, route, "cbz:")) return null;
    const path = route[4..];
    if (path.len < 6 or path[0] != '/') return null;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return null;
    if (!std.ascii.endsWithIgnoreCase(path, ".cbz")) return null;
    return path;
}

// ══════════════════════════════════════════════════════════
// Missing / corrupt page placeholders
// ══════════════════════════════════════════════════════════

pub const PageStatus = enum { downloading, preparing, missing, corrupt };

pub fn pageStatus(has_bytes: bool, decode_failed: bool, missing: bool) PageStatus {
    if (decode_failed) return .corrupt;
    if (has_bytes) return .preparing;
    if (missing) return .missing;
    return .downloading;
}

pub fn pageStatusLabel(s: PageStatus) []const u8 {
    return switch (s) {
        .downloading => "downloading...",
        .preparing => "preparing...",
        .missing => "is missing",
        .corrupt => "could not be decoded",
    };
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

const testing = std.testing;

test "spread pairing: cover alone, then pairs, odd tail alone" {
    try testing.expectEqual(Spread{ .first = 0 }, spreadAt(0, 10));
    try testing.expectEqual(Spread{ .first = 1, .second = 2 }, spreadAt(1, 10));
    try testing.expectEqual(Spread{ .first = 1, .second = 2 }, spreadAt(2, 10));
    try testing.expectEqual(Spread{ .first = 9 }, spreadAt(9, 10));
    try testing.expectEqual(Spread{ .first = 3, .second = 4 }, spreadAt(4, 5));
    try testing.expectEqual(Spread{ .first = 9 }, spreadAt(99, 10)); // clamped
    try testing.expectEqual(Spread{ .first = 0 }, spreadAt(3, 0));
}

test "RTL spreads put the later page on the left" {
    const s = spreadAt(3, 10);
    try testing.expectEqual([2]?usize{ 3, 4 }, displayOrder(s, false));
    try testing.expectEqual([2]?usize{ 4, 3 }, displayOrder(s, true));
    try testing.expectEqual([2]?usize{ 0, null }, displayOrder(spreadAt(0, 10), true));
}

test "page stepping per mode" {
    try testing.expectEqual(@as(?usize, 4), stepPage(.single_page, 3, 10, .next));
    try testing.expectEqual(@as(?usize, null), stepPage(.single_page, 9, 10, .next));
    try testing.expectEqual(@as(?usize, null), stepPage(.scroll, 0, 10, .previous));
    // Spread: 0 -> 1 -> 3 -> 5 … and back, always landing on a spread start.
    try testing.expectEqual(@as(?usize, 1), stepPage(.spread, 0, 10, .next));
    try testing.expectEqual(@as(?usize, 3), stepPage(.spread, 1, 10, .next));
    try testing.expectEqual(@as(?usize, 3), stepPage(.spread, 2, 10, .next));
    try testing.expectEqual(@as(?usize, 9), stepPage(.spread, 8, 10, .next));
    try testing.expectEqual(@as(?usize, null), stepPage(.spread, 9, 10, .next));
    try testing.expectEqual(@as(?usize, 1), stepPage(.spread, 4, 10, .previous));
    try testing.expectEqual(@as(?usize, 0), stepPage(.spread, 2, 10, .previous));
    try testing.expectEqual(@as(?usize, null), stepPage(.spread, 0, 10, .previous));
    try testing.expectEqual(@as(?usize, null), stepPage(.spread, 0, 0, .next));
}

test "RTL arrow keys turn the other way; J/K do not" {
    try testing.expectEqual(Direction.previous, keyDirection(.left, false));
    try testing.expectEqual(Direction.next, keyDirection(.left, true));
    try testing.expectEqual(Direction.previous, keyDirection(.right, true));
    try testing.expectEqual(Direction.next, keyDirection(.k, true));
    try testing.expectEqual(Direction.previous, keyDirection(.j, true));
}

test "mode cycle visits every mode" {
    try testing.expectEqual(Mode.single_page, nextMode(.scroll));
    try testing.expectEqual(Mode.spread, nextMode(.single_page));
    try testing.expectEqual(Mode.scroll, nextMode(.spread));
}

test "cache: pages outside the neighbour window are evicted farthest first" {
    var r: [12]u64 = @splat(0);
    r[0] = 10;
    r[4] = 10;
    r[5] = 10; // visible
    r[7] = 10;
    r[11] = 10;
    try testing.expectEqual(@as(?usize, 11), pickEviction(&r, 5, 5, 2, 1 << 40));
    r[11] = 0;
    try testing.expectEqual(@as(?usize, 0), pickEviction(&r, 5, 5, 2, 1 << 40));
    r[0] = 0;
    // 4 and 7 are neighbours within the budget: kept.
    try testing.expectEqual(@as(?usize, null), pickEviction(&r, 5, 5, 2, 1 << 40));
}

test "cache: over budget evicts neighbours but never the visible spread" {
    var r: [8]u64 = @splat(0);
    r[2] = 100;
    r[3] = 100; // visible spread 3..4
    r[4] = 100;
    r[6] = 100;
    // Budget 250: 400 resident -> evict farthest neighbour (6), then 2.
    try testing.expectEqual(@as(?usize, 6), pickEviction(&r, 3, 4, 2, 250));
    r[6] = 0;
    try testing.expectEqual(@as(?usize, 2), pickEviction(&r, 3, 4, 2, 250));
    r[2] = 0;
    // Visible pages alone exceed the budget: nothing left to evict.
    try testing.expectEqual(@as(?usize, null), pickEviction(&r, 3, 4, 2, 150));
}

test "cache: the resident total stays under budget after evicting to policy" {
    var r: [128]u64 = @splat(0);
    for (&r, 0..) |*b, i| b.* = 8 * 1024 * 1024 + i; // every page decoded
    while (pickEviction(&r, 60, 61, NEIGHBOUR_RADIUS, TEXTURE_BUDGET_BYTES)) |victim| r[victim] = 0;
    try testing.expect(residentTotal(&r) <= TEXTURE_BUDGET_BYTES);
    for (r, 0..) |b, i| try testing.expectEqual(i >= 58 and i <= 63, b != 0);
}

test "prefetch: neighbours only, and only with room left" {
    try testing.expect(prefetchAllowed(6, 5, 5, 1, 0, 100));
    try testing.expect(!prefetchAllowed(5, 5, 5, 1, 0, 100)); // visible: not a prefetch
    try testing.expect(!prefetchAllowed(8, 5, 5, 1, 0, 100));
    try testing.expect(!prefetchAllowed(6, 5, 5, 1, 100, 100));
}

test "huge pages get the smallest integer downscale that fits" {
    try testing.expectEqual(@as(u32, 1), downscaleFactor(1200, 1800, MAX_TEXTURE_EDGE, MAX_TEXTURE_BYTES));
    // A 1000 x 30000 webtoon strip exceeds the edge -> 2x.
    try testing.expectEqual(@as(u32, 2), downscaleFactor(1000, 30000, MAX_TEXTURE_EDGE, MAX_TEXTURE_BYTES));
    // 8000 x 8000 is 256 MB of RGBA -> 2x is still 64 MB (fits exactly).
    try testing.expectEqual(@as(u32, 2), downscaleFactor(8000, 8000, MAX_TEXTURE_EDGE, MAX_TEXTURE_BYTES));
    try testing.expectEqual(@as(u32, 3), downscaleFactor(9000, 9000, MAX_TEXTURE_EDGE, MAX_TEXTURE_BYTES));
    const d = scaledDims(9000, 9000, 3);
    try testing.expect(textureBytes(d.w, d.h) <= MAX_TEXTURE_BYTES);
    try testing.expectEqual(@as(u32, 1), downscaleFactor(0, 0, 10, 10));
}

test "box downscale averages blocks in place" {
    // 4 x 2 RGBA: left 2x2 block all 10, right block 0/20/40/60 -> mean 30.
    var px = [_]u8{
        10, 10, 10, 255, 10, 10, 10, 255, 0,  0,  0,  255, 20, 20, 20, 255,
        10, 10, 10, 255, 10, 10, 10, 255, 40, 40, 40, 255, 60, 60, 60, 255,
    };
    const d = boxDownscaleInPlace(&px, 4, 2, 2);
    try testing.expectEqual(Dims{ .w = 2, .h = 1 }, d);
    try testing.expectEqualSlices(u8, &.{ 10, 10, 10, 255, 30, 30, 30, 255 }, px[0..8]);
}

test "box downscale clamps odd edges and rejects a short buffer" {
    var px: [60]u8 = @splat(9); // 5 x 3
    try testing.expectEqual(Dims{ .w = 2, .h = 1 }, boxDownscaleInPlace(&px, 5, 3, 2));
    var short: [8]u8 = @splat(0);
    try testing.expectEqual(Dims{ .w = 4, .h = 4 }, boxDownscaleInPlace(&short, 4, 4, 2));
}

test "zoom clamps and steps; fit width vs fit page" {
    try testing.expectEqual(ZOOM_MAX, clampZoom(100));
    try testing.expectEqual(@as(f32, 1.0), clampZoom(std.math.nan(f32)));
    try testing.expectApproxEqAbs(@as(f32, 1.25), zoomIn(1.0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.8), zoomOut(1.0), 0.001);
    try testing.expectEqual(ZOOM_MIN, zoomOut(ZOOM_MIN));
    const fw = displaySize(1000, 1500, 500, 300, .width, 1.0);
    try testing.expectApproxEqAbs(@as(f32, 500), fw.w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 750), fw.h, 0.01);
    const fp = displaySize(1000, 1500, 500, 300, .page, 1.0);
    try testing.expectApproxEqAbs(@as(f32, 300), fp.h, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 200), fp.w, 0.01);
    const z = displaySize(1000, 1500, 500, 300, .width, 2.0);
    try testing.expectApproxEqAbs(@as(f32, 1000), z.w, 0.01);
    try testing.expectEqual(Size{ .w = 0, .h = 0 }, displaySize(0, 10, 500, 300, .page, 1));
}

test "server identity: lowercase, explicit port, no credentials" {
    var b: [128]u8 = undefined;
    try testing.expectEqualStrings("https://komga.lan:443", serverIdentity("HTTPS://Komga.LAN/opds", &b).?);
    try testing.expectEqualStrings("http://10.0.0.5:25600", serverIdentity("http://user:pw@10.0.0.5:25600/x", &b).?);
    try testing.expectEqualStrings("http://[::1]:8080", serverIdentity("http://[::1]:8080/", &b).?);
    try testing.expect(serverIdentity("ftp://x/y", &b) == null);
    try testing.expect(serverIdentity("mangadex:abc", &b) == null);
    try testing.expect(serverIdentity("http://host:99999999/", &b) == null);
}

test "PSE resume key uses server + book id, never the title" {
    var b: [256]u8 = undefined;
    const t1 = "https://komga.lan/api/v1/books/7/pages/{pageNumber}?zero_based=true";
    try testing.expectEqualStrings("/api/v1/books/7/pages", pseBookId(t1).?);
    try testing.expectEqualStrings("pse:https://komga.lan:443/api/v1/books/7/pages", pseResumeKey(t1, &b));
    // Same book id on another server -> a different key.
    var b2: [256]u8 = undefined;
    const other = pseResumeKey("https://kavita.lan:5000/api/v1/books/7/pages/{pageNumber}", &b2);
    try testing.expect(!std.mem.eql(u8, pseResumeKey(t1, &b), other));
    // Credentials in the template never leak into the key.
    try testing.expect(std.mem.indexOf(u8, pseResumeKey("https://u:secret@komga.lan/b/9/{pageNumber}", &b), "secret") == null);
    // No marker / no path -> no key (no title fallback).
    try testing.expectEqualStrings("", pseResumeKey("https://komga.lan/api/v1/books/7/pages/1", &b));
    try testing.expectEqualStrings("", pseResumeKey("https://komga.lan/{pageNumber}", &b));
}

test "URL resume key normalises host and drops credentials and fragment" {
    var b: [256]u8 = undefined;
    try testing.expectEqualStrings("https://readallcomics.com:443/x-1/?p=2", urlResumeKey("https://u:p@ReadAllComics.com/x-1/?p=2#top", &b));
    try testing.expectEqualStrings("https://a.example:443/", urlResumeKey("https://a.example", &b));
    try testing.expectEqualStrings("mangadex:801513ba-a712-498c-8f57-cae55b38cc92", urlResumeKey("mangadex:801513ba-a712-498c-8f57-cae55b38cc92", &b));
    var tiny: [4]u8 = undefined;
    try testing.expectEqualStrings("", urlResumeKey("mangadex:abcdef", &tiny));
}

test "archive entry sanitisation rejects traversal, absolute and junk paths" {
    var b: [256]u8 = undefined;
    try testing.expectEqualStrings("vol1/p001.jpg", sanitizeEntryPath("vol1/p001.jpg", &b).?);
    try testing.expectEqualStrings("vol1/p001.jpg", sanitizeEntryPath("./vol1//p001.jpg", &b).?);
    for ([_][]const u8{
        "../evil.jpg", "a/../../evil.jpg", "/etc/passwd",    "C:/x.jpg",
        "c:evil.jpg",  "a\\..\\b.jpg",     "\\abs.jpg",      "a/\x00.jpg",
        "a/b\x1f.jpg", "__MACOSX/a.jpg",   "x/__macosx/._a", "x/._p1.jpg",
        ".DS_Store",   "dir/",             "",               "./",
        "a/..",
    }) |bad| {
        if (sanitizeEntryPath(bad, &b)) |got| {
            std.debug.print("accepted unsafe entry {s} -> {s}\n", .{ bad, got });
            return error.TestUnexpectedResult;
        }
    }
    var tiny: [3]u8 = undefined;
    try testing.expect(sanitizeEntryPath("long.jpg", &tiny) == null);
}

test "page images by extension, and natural page order" {
    try testing.expect(isPageImage("a/P01.JPG"));
    try testing.expect(isPageImage("x.webp"));
    try testing.expect(!isPageImage("ComicInfo.xml"));
    try testing.expect(!isPageImage("noext"));
    var names = [_][]const u8{ "p10.jpg", "p2.jpg", "P1.jpg", "p02b.jpg", "cover.jpg", "p001.png" };
    std.mem.sort([]const u8, &names, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return naturalLess(a, b);
        }
    }.lt);
    try testing.expectEqualStrings("cover.jpg", names[0]);
    try testing.expectEqualStrings("P1.jpg", names[1]);
    try testing.expectEqualStrings("p001.png", names[2]);
    try testing.expectEqualStrings("p2.jpg", names[3]);
    try testing.expectEqualStrings("p02b.jpg", names[4]);
    try testing.expectEqualStrings("p10.jpg", names[5]);
    try testing.expect(!naturalLess("a", "a"));
}

test "embedded links: http(s) only, no credentials or control bytes" {
    try testing.expect(isSafeLink("https://readallcomics.com/next-issue/"));
    try testing.expect(isSafeLink("http://cdn.example:8080/p/1.jpg?x=1"));
    for ([_][]const u8{
        "javascript:alert(1)",           "data:image/png;base64,AAAA",
        "file:///etc/passwd",            "//evil.example/x",
        "https://user:pw@evil.example/", "https://ok.example/a b",
        "https://ok.example/\x00",       "https:///nohost",
        "HTTPS://ok.example\\@evil/",    "/relative/next",
        "mangadex:801513ba",
    }) |bad| try testing.expect(!isSafeLink(bad));
}

test "local archive routes" {
    try testing.expectEqualStrings("/Users/a/b.cbz", localArchivePath("cbz:/Users/a/b.cbz").?);
    try testing.expectEqualStrings("/x/B.CBZ", localArchivePath("cbz:/x/B.CBZ").?);
    try testing.expect(localArchivePath("file:///x/y.cbz") == null);
    try testing.expect(localArchivePath("/x/y.cbz") == null);
    try testing.expect(localArchivePath("https://h/x.cbz") == null);
    try testing.expect(localArchivePath("cbz:relative.cbz") == null);
    try testing.expect(localArchivePath("cbz:/x/y.zip") == null);
}

test "missing and corrupt pages map to placeholders" {
    try testing.expectEqual(PageStatus.corrupt, pageStatus(true, true, false));
    try testing.expectEqual(PageStatus.missing, pageStatus(false, false, true));
    try testing.expectEqual(PageStatus.preparing, pageStatus(true, false, false));
    try testing.expectEqual(PageStatus.downloading, pageStatus(false, false, false));
    try testing.expectEqualStrings("is missing", pageStatusLabel(.missing));
}

test "local comic archives route to the reader, not mpv" {
    try std.testing.expect(isLocalComicArchive("/home/u/Comics/Saga 01.cbz"));
    try std.testing.expect(isLocalComicArchive("/Users/u/Downloads/ISSUE.CBZ"));
    try std.testing.expect(!isLocalComicArchive("relative/book.cbz"));
    try std.testing.expect(!isLocalComicArchive("/home/u/clip.mkv"));
    try std.testing.expect(!isLocalComicArchive("https://x/y.cbz"));
    try std.testing.expect(!isLocalComicArchive("/bad\x00.cbz"));
}
