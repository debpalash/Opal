//! Bounded CBZ (zip) reader: pure, unit-tested (test_cbz_pure).
//!
//! Comic archives are untrusted input. Everything here is bounds-checked and
//! returns an error instead of panicking:
//!   * EOCD search limited to the 64 KiB comment window
//!   * entry count capped (MAX_ENTRIES), zip64 and multi-disk rejected
//!   * every offset / length checked against the buffer before slicing
//!   * stored + deflate only; encrypted entries rejected
//!   * output bounded by the declared size AND a caller cap, CRC verified
//! Entry names go through reader_pure.sanitizeEntryPath before they are used,
//! and pages are ordered with reader_pure.naturalLess.

const std = @import("std");
const reader = @import("reader_pure.zig");

/// Largest archive comics.zig will read into memory.
pub const MAX_ARCHIVE_BYTES: usize = 256 * 1024 * 1024;
/// Most central-directory entries accepted.
pub const MAX_ENTRIES: usize = 4096;
/// Largest single page (encoded bytes) extracted.
pub const MAX_ENTRY_BYTES: u64 = 32 * 1024 * 1024;
/// Total encoded page bytes staged from one archive.
pub const MAX_TOTAL_BYTES: u64 = 384 * 1024 * 1024;

pub const Error = error{
    NotZip,
    Truncated,
    Zip64Unsupported,
    MultiDisk,
    TooManyEntries,
    Corrupt,
    Encrypted,
    UnsupportedMethod,
    TooLarge,
    ChecksumMismatch,
    OutOfMemory,
};

pub const Entry = struct {
    name: []const u8,
    method: u16,
    flags: u16,
    crc32: u32,
    comp_size: u32,
    uncomp_size: u32,
    local_offset: u32,
};

const EOCD_SIG: u32 = 0x06054b50;
const ZIP64_LOCATOR_SIG: u32 = 0x07064b50;
const CD_SIG: u32 = 0x02014b50;
const LOCAL_SIG: u32 = 0x04034b50;
const EOCD_LEN = 22;
const CD_LEN = 46;
const LOCAL_LEN = 30;

fn rd16(d: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, d[at..][0..2], .little);
}
fn rd32(d: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, d[at..][0..4], .little);
}

pub const Archive = struct {
    data: []const u8,
    cd_offset: usize,
    cd_end: usize,
    count: usize,

    pub fn open(data: []const u8) Error!Archive {
        if (data.len < EOCD_LEN) return error.NotZip;
        const lowest = if (data.len > EOCD_LEN + 0xFFFF) data.len - EOCD_LEN - 0xFFFF else 0;
        var pos: usize = data.len - EOCD_LEN;
        const eocd = while (true) : (pos -= 1) {
            if (rd32(data, pos) == EOCD_SIG and pos + EOCD_LEN + rd16(data, pos + 20) <= data.len) break pos;
            if (pos == lowest) return error.NotZip;
        };
        if (eocd >= 20 and rd32(data, eocd - 20) == ZIP64_LOCATOR_SIG) return error.Zip64Unsupported;
        const disk = rd16(data, eocd + 4);
        const cd_disk = rd16(data, eocd + 6);
        const on_disk = rd16(data, eocd + 8);
        const total = rd16(data, eocd + 10);
        const cd_size = rd32(data, eocd + 12);
        const cd_offset = rd32(data, eocd + 16);
        if (total == 0xFFFF or on_disk == 0xFFFF or cd_size == 0xFFFFFFFF or cd_offset == 0xFFFFFFFF) return error.Zip64Unsupported;
        if (disk != 0 or cd_disk != 0 or on_disk != total) return error.MultiDisk;
        if (total > MAX_ENTRIES) return error.TooManyEntries;
        const cd_end = std.math.add(usize, cd_offset, cd_size) catch return error.Corrupt;
        if (cd_end > eocd) return error.Truncated;
        // Each entry needs at least a fixed header: a count the directory cannot
        // hold is a lie, not a reason to loop.
        if (@as(u64, total) * CD_LEN > cd_size) return error.Corrupt;
        return .{ .data = data, .cd_offset = cd_offset, .cd_end = cd_end, .count = total };
    }

    pub fn iterator(self: *const Archive) Iterator {
        return .{ .archive = self, .pos = self.cd_offset };
    }

    /// Decompress `e` into a fresh buffer owned by the caller (free with `gpa`).
    /// Bounded by `max_bytes` and the declared size; CRC-checked.
    pub fn extract(self: *const Archive, gpa: std.mem.Allocator, e: Entry, max_bytes: u64) Error![]u8 {
        if (e.flags & 1 != 0) return error.Encrypted;
        if (e.uncomp_size > max_bytes) return error.TooLarge;
        const d = self.data;
        const lo: usize = e.local_offset;
        if (lo > d.len or d.len - lo < LOCAL_LEN) return error.Truncated;
        if (rd32(d, lo) != LOCAL_SIG) return error.Corrupt;
        const start = lo + LOCAL_LEN + @as(usize, rd16(d, lo + 26)) + rd16(d, lo + 28);
        const end = std.math.add(usize, start, e.comp_size) catch return error.Corrupt;
        // Entry data must sit before the central directory.
        if (end > self.cd_offset) return error.Truncated;
        const src = d[start..end];
        const out = try gpa.alloc(u8, e.uncomp_size);
        errdefer gpa.free(out);
        switch (e.method) {
            0 => {
                if (e.comp_size != e.uncomp_size) return error.Corrupt;
                @memcpy(out, src);
            },
            8 => {
                var in: std.Io.Reader = .fixed(src);
                var w: std.Io.Writer = .fixed(out);
                var flate: std.compress.flate.Decompress = .init(&in, .raw, &.{});
                const n = flate.reader.streamRemaining(&w) catch return error.Corrupt;
                if (n != out.len) return error.Corrupt;
            },
            else => return error.UnsupportedMethod,
        }
        if (std.hash.Crc32.hash(out) != e.crc32) return error.ChecksumMismatch;
        return out;
    }
};

pub const Iterator = struct {
    archive: *const Archive,
    pos: usize,
    index: usize = 0,

    pub fn next(it: *Iterator) Error!?Entry {
        if (it.index >= it.archive.count) return null;
        const d = it.archive.data;
        const p = it.pos;
        if (p > it.archive.cd_end or it.archive.cd_end - p < CD_LEN) return error.Truncated;
        if (rd32(d, p) != CD_SIG) return error.Corrupt;
        const name_len: usize = rd16(d, p + 28);
        const extra_len: usize = rd16(d, p + 30);
        const comment_len: usize = rd16(d, p + 32);
        const total = CD_LEN + name_len + extra_len + comment_len;
        if (it.archive.cd_end - p < total) return error.Truncated;
        const e: Entry = .{
            .name = d[p + CD_LEN ..][0..name_len],
            .flags = rd16(d, p + 8),
            .method = rd16(d, p + 10),
            .crc32 = rd32(d, p + 16),
            .comp_size = rd32(d, p + 20),
            .uncomp_size = rd32(d, p + 24),
            .local_offset = rd32(d, p + 42),
        };
        if (e.comp_size == 0xFFFFFFFF or e.uncomp_size == 0xFFFFFFFF or e.local_offset == 0xFFFFFFFF) return error.Zip64Unsupported;
        it.pos = p + total;
        it.index += 1;
        return e;
    }
};

/// One page the reader may stage: the entry plus its sanitised name.
pub const PageEntry = struct {
    entry: Entry,
    path: [256]u8 = undefined,
    path_len: usize = 0,

    pub fn pathSlice(self: *const PageEntry) []const u8 {
        return self.path[0..self.path_len];
    }
};

pub const Collected = struct { count: usize, skipped_unsafe: usize, truncated: bool };

/// Collect image entries with safe names into `out`, naturally ordered.
/// Unsafe or non-image names are skipped (counted when unsafe). A directory
/// that stops parsing mid-way keeps what was read so far (`truncated`).
pub fn collectPages(archive: *const Archive, out: []PageEntry) Collected {
    var res: Collected = .{ .count = 0, .skipped_unsafe = 0, .truncated = false };
    var it = archive.iterator();
    while (true) {
        const e = (it.next() catch {
            res.truncated = true;
            break;
        }) orelse break;
        if (e.name.len > 0 and e.name[e.name.len - 1] == '/') continue; // directory
        var pe: PageEntry = .{ .entry = e };
        const clean = reader.sanitizeEntryPath(e.name, &pe.path) orelse {
            res.skipped_unsafe += 1;
            continue;
        };
        if (!reader.isPageImage(clean)) continue;
        if (res.count >= out.len) {
            res.truncated = true;
            break;
        }
        pe.path_len = clean.len;
        out[res.count] = pe;
        res.count += 1;
    }
    std.mem.sort(PageEntry, out[0..res.count], {}, struct {
        fn lt(_: void, a: PageEntry, b: PageEntry) bool {
            return reader.naturalLess(a.pathSlice(), b.pathSlice());
        }
    }.lt);
    return res;
}

// ══════════════════════════════════════════════════════════
// Tests: fixtures come from tests/fixtures/gen_cbz_fixtures.py
// ══════════════════════════════════════════════════════════

const testing = std.testing;
const good_cbz = @embedFile("testdata/reader-good.cbz");
const traversal_cbz = @embedFile("testdata/reader-traversal.cbz");
const corrupt_cbz = @embedFile("testdata/reader-corrupt.cbz");
const zip64_cbz = @embedFile("testdata/reader-zip64.cbz");
const many_cbz = @embedFile("testdata/reader-many.cbz");

fn findEntry(a: *const Archive, name: []const u8) !Entry {
    var it = a.iterator();
    while (try it.next()) |e| if (std.mem.eql(u8, e.name, name)) return e;
    return error.TestUnexpectedResult;
}

test "good archive: image pages only, junk skipped, natural order" {
    const a = try Archive.open(good_cbz);
    var pages: [16]PageEntry = undefined;
    const got = collectPages(&a, &pages);
    try testing.expect(!got.truncated);
    try testing.expectEqual(@as(usize, 4), got.count);
    try testing.expectEqualStrings("Vol 1/p1.png", pages[0].pathSlice());
    try testing.expectEqualStrings("Vol 1/p2.png", pages[1].pathSlice());
    try testing.expectEqualStrings("Vol 1/p3.png", pages[2].pathSlice());
    try testing.expectEqualStrings("Vol 1/p10.png", pages[3].pathSlice());
    // __MACOSX/._p1.png is an unsafe name; ComicInfo.xml is not an image.
    try testing.expectEqual(@as(usize, 1), got.skipped_unsafe);
}

test "good archive: stored and deflated pages extract with CRC" {
    const a = try Archive.open(good_cbz);
    var pages: [16]PageEntry = undefined;
    const got = collectPages(&a, &pages);
    for (pages[0..got.count]) |pe| {
        const bytes = try a.extract(testing.allocator, pe.entry, MAX_ENTRY_BYTES);
        defer testing.allocator.free(bytes);
        try testing.expect(std.mem.startsWith(u8, bytes, "\x89PNG"));
    }
    // p10 is the deflated one with back-references.
    try testing.expectEqual(@as(u16, 8), pages[3].entry.method);
    try testing.expectEqual(@as(u16, 0), pages[0].entry.method);
}

test "traversal archive: only the safe page survives" {
    const a = try Archive.open(traversal_cbz);
    var pages: [16]PageEntry = undefined;
    const got = collectPages(&a, &pages);
    try testing.expectEqual(@as(usize, 1), got.count);
    try testing.expectEqualStrings("ok/page1.png", pages[0].pathSlice());
    try testing.expectEqual(@as(usize, 5), got.skipped_unsafe);
}

test "corrupt entries error instead of crashing" {
    const a = try Archive.open(corrupt_cbz);
    try testing.expectError(error.Corrupt, a.extract(testing.allocator, try findEntry(&a, "bad-deflate.png"), MAX_ENTRY_BYTES));
    try testing.expectError(error.ChecksumMismatch, a.extract(testing.allocator, try findEntry(&a, "bad-crc.png"), MAX_ENTRY_BYTES));
    // Declares 64 bytes, inflates to 100000: the bounded writer stops it.
    try testing.expectError(error.Corrupt, a.extract(testing.allocator, try findEntry(&a, "liar.png"), MAX_ENTRY_BYTES));
    try testing.expectError(error.TooLarge, a.extract(testing.allocator, try findEntry(&a, "huge.png"), MAX_ENTRY_BYTES));
    try testing.expectError(error.Encrypted, a.extract(testing.allocator, try findEntry(&a, "locked.png"), MAX_ENTRY_BYTES));
    try testing.expectError(error.Truncated, a.extract(testing.allocator, try findEntry(&a, "past-end.png"), MAX_ENTRY_BYTES));
    const ok = try a.extract(testing.allocator, try findEntry(&a, "fine.png"), MAX_ENTRY_BYTES);
    defer testing.allocator.free(ok);
    try testing.expect(std.mem.startsWith(u8, ok, "\x89PNG"));
}

test "zip64 and huge entry counts are rejected up front" {
    try testing.expectError(error.Zip64Unsupported, Archive.open(zip64_cbz));
    try testing.expectError(error.TooManyEntries, Archive.open(many_cbz));
}

test "truncated, empty and garbage input never panic" {
    try testing.expectError(error.NotZip, Archive.open(""));
    try testing.expectError(error.NotZip, Archive.open("PK\x05\x06"));
    try testing.expectError(error.NotZip, Archive.open(good_cbz[0 .. good_cbz.len / 2]));
    // Every prefix and a byte-flipped copy: errors are fine, panics are not.
    var i: usize = 0;
    while (i < good_cbz.len) : (i += 7) {
        const a = Archive.open(good_cbz[0..i]) catch continue;
        var pages: [16]PageEntry = undefined;
        _ = collectPages(&a, &pages);
    }
    var flipped: [good_cbz.len]u8 = good_cbz.*;
    var k: usize = 0;
    while (k < flipped.len) : (k += 13) flipped[k] ^= 0x5a;
    if (Archive.open(&flipped)) |a| {
        var pages: [16]PageEntry = undefined;
        const got = collectPages(&a, &pages);
        for (pages[0..got.count]) |pe| {
            if (a.extract(testing.allocator, pe.entry, MAX_ENTRY_BYTES)) |b| testing.allocator.free(b) else |_| {}
        }
    } else |_| {}
}

test "an EOCD whose count exceeds its directory is corrupt, not a long loop" {
    var buf: [EOCD_LEN]u8 = @splat(0);
    std.mem.writeInt(u32, buf[0..4], EOCD_SIG, .little);
    std.mem.writeInt(u16, buf[8..10], 4000, .little);
    std.mem.writeInt(u16, buf[10..12], 4000, .little);
    try testing.expectError(error.Corrupt, Archive.open(&buf));
}

test "collectPages caps at the page slots and reports truncation" {
    const a = try Archive.open(good_cbz);
    var pages: [2]PageEntry = undefined;
    const got = collectPages(&a, &pages);
    try testing.expectEqual(@as(usize, 2), got.count);
    try testing.expect(got.truncated);
}
