//! Seek-aware piece-deadline planning for torrent streams.
//!
//! A seek moves the player's read cursor to a new BYTE offset inside one file
//! of the torrent. libtorrent schedules by PIECE, and a piece can straddle two
//! files, so this module owns the offset -> piece mapping, the sliding window
//! of graduated deadlines in front of the cursor, the container header/tail
//! pins, and which previously-deadlined pieces have gone stale.
//!
//! The wrapper (`torrent_apply_piece_deadlines`) only executes the plan, so the
//! tested maths here is the shipped maths. No dvui / state / c imports.

const std = @import("std");

/// Largest window the planner will emit. Bounds the plan's fixed arrays and
/// the number of deadline messages sent to libtorrent per seek.
pub const MAX_WINDOW: u32 = 64;
/// Header and tail pins (MKV EBML/Cues, MP4 moov) never exceed this many each.
pub const MAX_PIN: u32 = 8;
pub const MAX_SET: usize = MAX_WINDOW + 2 * MAX_PIN;
pub const MAX_RESET: usize = MAX_WINDOW;

/// Where one file sits inside the torrent's piece space.
pub const Geometry = struct {
    /// Byte offset of the file's first byte inside the torrent.
    file_offset: u64,
    file_size: u64,
    piece_size: u32,
    /// Total pieces in the torrent (the last one may be short).
    num_pieces: u32,
};

pub const Config = struct {
    /// Pieces in the read-ahead window, counting the cursor piece.
    window: u32 = 30,
    /// Pieces pinned at the start of the file (container header).
    head_pin: u32 = 3,
    /// Pieces pinned at the end of the file (index / moov atom).
    tail_pin: u32 = 5,
};

/// Inclusive piece range.
pub const Range = struct {
    first: u32,
    last: u32,

    pub fn contains(self: Range, p: u32) bool {
        return p >= self.first and p <= self.last;
    }
    pub fn len(self: Range) u32 {
        return self.last - self.first + 1;
    }
};

/// The read-ahead window at one cursor. `target` is the cursor piece and the
/// first piece of `span`.
pub const Window = struct {
    target: u32,
    span: Range,
    file: Range,
};

/// Pieces covered by the file, clamped to the torrent. Null when the geometry
/// is unusable (no metadata yet, empty file, file beyond the piece space).
pub fn filePieces(g: Geometry) ?Range {
    if (g.piece_size == 0 or g.num_pieces == 0 or g.file_size == 0) return null;
    const ps: u64 = g.piece_size;
    const first = g.file_offset / ps;
    const last = (g.file_offset + g.file_size - 1) / ps;
    if (first >= g.num_pieces) return null;
    const last_clamped = @min(last, @as(u64, g.num_pieces - 1));
    return .{ .first = @intCast(first), .last = @intCast(last_clamped) };
}

/// Piece holding `byte_offset` of the file. Offsets past the end clamp to the
/// file's last byte: a demuxer probing EOF still needs the tail piece.
pub fn pieceAt(g: Geometry, byte_offset: u64) ?u32 {
    const fr = filePieces(g) orelse return null;
    const clamped = @min(byte_offset, g.file_size - 1);
    const abs = g.file_offset + clamped;
    const p: u64 = abs / g.piece_size;
    return @intCast(std.math.clamp(p, fr.first, fr.last));
}

/// Window of `cfg.window` pieces starting at the cursor piece, clamped to the
/// file's last piece and to MAX_WINDOW. Always at least the cursor piece.
pub fn windowAt(g: Geometry, byte_offset: u64, cfg: Config) ?Window {
    const fr = filePieces(g) orelse return null;
    const target = pieceAt(g, byte_offset) orelse return null;
    const want = std.math.clamp(cfg.window, 1, MAX_WINDOW);
    const last = @min(fr.last, target + (want - 1));
    return .{ .target = target, .span = .{ .first = target, .last = last }, .file = fr };
}

/// Byte offset for a seekbar percentage (0..100). Non-finite input maps to 0.
pub fn percentToOffset(pct: f64, file_size: u64) u64 {
    if (file_size == 0 or !std.math.isFinite(pct)) return 0;
    const f = std.math.clamp(pct, 0.0, 100.0) / 100.0;
    const off: f64 = f * @as(f64, @floatFromInt(file_size));
    const max: u64 = file_size - 1;
    if (off >= @as(f64, @floatFromInt(max))) return max;
    return @intFromFloat(off);
}

/// Graduated deadline for the i-th piece of the window: the first few are
/// needed now, the rest progressively later so the fastest peers take the
/// cursor and slower ones fill the read-ahead.
pub fn deadlineMs(i: u32) u32 {
    return if (i < 5) i * 10 else 50 + (i - 5) * 40;
}

pub const Mode = enum {
    /// Cursor still on the same piece: nothing to send.
    none,
    /// Cursor moved forward inside the previous window: reset only the pieces
    /// that fell behind it.
    slide,
    /// Backward seek or a jump past the previous window: clear every deadline.
    jump,
};

pub const Entry = struct { piece: u32, deadline_ms: u32 };

pub const Plan = struct {
    mode: Mode = .none,
    window: ?Window = null,
    /// Pieces to (re)arm, cursor window first, then header and tail pins.
    set: [MAX_SET]Entry = undefined,
    set_len: usize = 0,
    /// Previously-deadlined pieces to release (slide mode only).
    reset: [MAX_RESET]u32 = undefined,
    reset_len: usize = 0,

    pub fn sets(self: *const Plan) []const Entry {
        return self.set[0..self.set_len];
    }
    pub fn resets(self: *const Plan) []const u32 {
        return self.reset[0..self.reset_len];
    }
    pub fn clearAll(self: *const Plan) bool {
        return self.mode == .jump;
    }

    fn addSet(self: *Plan, piece: u32, deadline: u32) void {
        for (self.set[0..self.set_len]) |e| if (e.piece == piece) return;
        if (self.set_len >= self.set.len) return;
        self.set[self.set_len] = .{ .piece = piece, .deadline_ms = deadline };
        self.set_len += 1;
    }
};

fn pinned(win: Window, cfg: Config, p: u32) bool {
    const fr = win.file;
    const head = std.math.clamp(cfg.head_pin, 0, MAX_PIN);
    const tail = std.math.clamp(cfg.tail_pin, 0, MAX_PIN);
    if (head > 0 and p >= fr.first and p - fr.first < head) return true;
    if (tail > 0 and p <= fr.last and fr.last - p < tail) return true;
    return false;
}

/// Decide what to send for a cursor at `byte_offset`, given the window applied
/// by the previous call for the SAME file (null after a file switch or on the
/// first seek). Null when the geometry is unusable.
pub fn plan(g: Geometry, byte_offset: u64, prev: ?Window, cfg: Config) ?Plan {
    const win = windowAt(g, byte_offset, cfg) orelse return null;
    var out: Plan = .{ .window = win };

    // A previous window from a different file (or torrent geometry) is unrelated.
    const usable_prev: ?Window = if (prev) |p|
        (if (p.file.first == win.file.first and p.file.last == win.file.last) p else null)
    else
        null;

    if (usable_prev) |p| {
        if (p.target == win.target) {
            out.mode = .none;
            return out;
        }
        out.mode = if (win.target > p.target and p.span.contains(win.target)) .slide else .jump;
    } else {
        out.mode = .jump;
    }

    var i: u32 = 0;
    var piece = win.span.first;
    while (piece <= win.span.last) : ({
        piece += 1;
        i += 1;
    }) out.addSet(piece, deadlineMs(i));

    const fr = win.file;
    const head = @min(std.math.clamp(cfg.head_pin, 0, MAX_PIN), fr.len());
    var h: u32 = 0;
    while (h < head) : (h += 1) out.addSet(fr.first + h, 0);
    const tail = @min(std.math.clamp(cfg.tail_pin, 0, MAX_PIN), fr.len());
    var t: u32 = 0;
    while (t < tail) : (t += 1) out.addSet(fr.last - t, 0);

    if (out.mode == .slide) {
        const p = usable_prev.?;
        var s = p.span.first;
        while (s <= p.span.last) : (s += 1) {
            if (win.span.contains(s) or pinned(win, cfg, s)) continue;
            if (out.reset_len >= out.reset.len) break;
            out.reset[out.reset_len] = s;
            out.reset_len += 1;
        }
    }
    return out;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const MiB: u64 = 1024 * 1024;

fn single(size: u64, piece: u32) Geometry {
    const n: u32 = @intCast((size + piece - 1) / piece);
    return .{ .file_offset = 0, .file_size = size, .piece_size = piece, .num_pieces = n };
}

test "piece-size boundaries map to the right piece" {
    const g = single(10 * MiB, @intCast(MiB));
    try std.testing.expectEqual(@as(?u32, 0), pieceAt(g, 0));
    try std.testing.expectEqual(@as(?u32, 0), pieceAt(g, MiB - 1));
    try std.testing.expectEqual(@as(?u32, 1), pieceAt(g, MiB));
    try std.testing.expectEqual(@as(?u32, 1), pieceAt(g, MiB + 1));
    try std.testing.expectEqual(@as(?u32, 9), pieceAt(g, 10 * MiB - 1));
}

test "last piece: short tail piece and offsets past EOF clamp to it" {
    // 10 MiB + 317 bytes: an 11th, 317-byte piece.
    const g = single(10 * MiB + 317, @intCast(MiB));
    try std.testing.expectEqual(@as(u32, 11), g.num_pieces);
    try std.testing.expectEqual(@as(?u32, 10), pieceAt(g, 10 * MiB));
    try std.testing.expectEqual(@as(?u32, 10), pieceAt(g, 10 * MiB + 316));
    try std.testing.expectEqual(@as(?u32, 10), pieceAt(g, 99 * MiB));
    const w = windowAt(g, 10 * MiB + 5, .{}).?;
    try std.testing.expectEqual(@as(u32, 10), w.target);
    try std.testing.expectEqual(@as(u32, 10), w.span.last);
    try std.testing.expectEqual(@as(u32, 1), w.span.len());
}

test "multi-file: unaligned file offset maps into the shared boundary piece" {
    // Second file starts 300 bytes before a piece boundary.
    const ps: u32 = 64 * 1024;
    const g = Geometry{ .file_offset = 3 * @as(u64, ps) - 300, .file_size = 5 * @as(u64, ps), .piece_size = ps, .num_pieces = 9 };
    const fr = filePieces(g).?;
    try std.testing.expectEqual(@as(u32, 2), fr.first);
    try std.testing.expectEqual(@as(u32, 7), fr.last);
    try std.testing.expectEqual(@as(?u32, 2), pieceAt(g, 0));
    try std.testing.expectEqual(@as(?u32, 2), pieceAt(g, 299));
    try std.testing.expectEqual(@as(?u32, 3), pieceAt(g, 300));
}

test "window clamps at the file end, at MAX_WINDOW, and to at least one piece" {
    const g = single(100 * MiB, @intCast(MiB));
    const near_end = windowAt(g, 95 * MiB, .{ .window = 30 }).?;
    try std.testing.expectEqual(@as(u32, 95), near_end.span.first);
    try std.testing.expectEqual(@as(u32, 99), near_end.span.last);

    const huge = windowAt(g, 0, .{ .window = 10_000 }).?;
    try std.testing.expectEqual(MAX_WINDOW, huge.span.len());

    const zero = windowAt(g, 7 * MiB, .{ .window = 0 }).?;
    try std.testing.expectEqual(@as(u32, 1), zero.span.len());
    try std.testing.expectEqual(@as(u32, 7), zero.target);
}

test "window never crosses into the next file's pieces" {
    const ps: u32 = @intCast(MiB);
    // File occupies pieces 4..9 of a 20-piece torrent.
    const g = Geometry{ .file_offset = 4 * MiB, .file_size = 6 * MiB, .piece_size = ps, .num_pieces = 20 };
    const w = windowAt(g, 5 * MiB, .{ .window = 30 }).?;
    try std.testing.expectEqual(@as(u32, 9), w.span.last);
}

test "unusable geometry yields no plan" {
    try std.testing.expect(filePieces(.{ .file_offset = 0, .file_size = 0, .piece_size = 1024, .num_pieces = 4 }) == null);
    try std.testing.expect(filePieces(.{ .file_offset = 0, .file_size = 10, .piece_size = 0, .num_pieces = 4 }) == null);
    try std.testing.expect(filePieces(.{ .file_offset = 4096 * 8, .file_size = 10, .piece_size = 4096, .num_pieces = 4 }) == null);
    try std.testing.expect(plan(single(0, 1024), 0, null, .{}) == null);
}

test "percent maps to bytes and clamps" {
    try std.testing.expectEqual(@as(u64, 0), percentToOffset(-5, 1000));
    try std.testing.expectEqual(@as(u64, 500), percentToOffset(50, 1000));
    try std.testing.expectEqual(@as(u64, 999), percentToOffset(100, 1000));
    try std.testing.expectEqual(@as(u64, 999), percentToOffset(250, 1000));
    try std.testing.expectEqual(@as(u64, 0), percentToOffset(std.math.nan(f64), 1000));
    try std.testing.expectEqual(@as(u64, 0), percentToOffset(50, 0));
}

test "first seek is a jump with graduated window and header/tail pins" {
    const g = single(100 * MiB, @intCast(MiB));
    const p = plan(g, 40 * MiB, null, .{ .window = 10, .head_pin = 3, .tail_pin = 5 }).?;
    try std.testing.expectEqual(Mode.jump, p.mode);
    try std.testing.expect(p.clearAll());
    try std.testing.expectEqual(@as(usize, 0), p.resets().len);
    try std.testing.expectEqual(@as(usize, 10 + 3 + 5), p.sets().len);
    try std.testing.expectEqual(Entry{ .piece = 40, .deadline_ms = 0 }, p.sets()[0]);
    try std.testing.expectEqual(Entry{ .piece = 41, .deadline_ms = 10 }, p.sets()[1]);
    try std.testing.expectEqual(Entry{ .piece = 46, .deadline_ms = 90 }, p.sets()[6]);
    try std.testing.expectEqual(Entry{ .piece = 0, .deadline_ms = 0 }, p.sets()[10]);
    try std.testing.expectEqual(Entry{ .piece = 99, .deadline_ms = 0 }, p.sets()[13]);
}

test "same cursor piece sends nothing" {
    const g = single(100 * MiB, @intCast(MiB));
    const first = plan(g, 40 * MiB, null, .{}).?;
    const again = plan(g, 40 * MiB + 1234, first.window, .{}).?;
    try std.testing.expectEqual(Mode.none, again.mode);
    try std.testing.expectEqual(@as(usize, 0), again.sets().len);
}

test "forward move inside the window slides and resets only stale pieces" {
    const g = single(100 * MiB, @intCast(MiB));
    const cfg = Config{ .window = 10, .head_pin = 3, .tail_pin = 5 };
    const first = plan(g, 40 * MiB, null, cfg).?;
    const next = plan(g, 44 * MiB, first.window, cfg).?;
    try std.testing.expectEqual(Mode.slide, next.mode);
    try std.testing.expect(!next.clearAll());
    try std.testing.expectEqualSlices(u32, &.{ 40, 41, 42, 43 }, next.resets());
    try std.testing.expectEqual(@as(u32, 44), next.sets()[0].piece);
}

test "stale reset never releases a header or tail pin" {
    const g = single(20 * MiB, @intCast(MiB));
    const cfg = Config{ .window = 6, .head_pin = 3, .tail_pin = 2 };
    const first = plan(g, 0, null, cfg).?;
    const next = plan(g, 4 * MiB, first.window, cfg).?;
    try std.testing.expectEqual(Mode.slide, next.mode);
    // Pieces 0..2 are header pins: only piece 3 is stale.
    try std.testing.expectEqualSlices(u32, &.{3}, next.resets());
}

test "backward seek and far jump clear every deadline" {
    const g = single(100 * MiB, @intCast(MiB));
    const first = plan(g, 40 * MiB, null, .{ .window = 10 }).?;
    const back = plan(g, 39 * MiB, first.window, .{ .window = 10 }).?;
    try std.testing.expectEqual(Mode.jump, back.mode);
    const far = plan(g, 60 * MiB, first.window, .{ .window = 10 }).?;
    try std.testing.expectEqual(Mode.jump, far.mode);
    try std.testing.expectEqual(@as(usize, 0), far.resets().len);
}

test "previous window from another file is ignored" {
    const ps: u32 = @intCast(MiB);
    const a = Geometry{ .file_offset = 0, .file_size = 10 * MiB, .piece_size = ps, .num_pieces = 30 };
    const b = Geometry{ .file_offset = 10 * MiB, .file_size = 20 * MiB, .piece_size = ps, .num_pieces = 30 };
    const pa = plan(a, 2 * MiB, null, .{}).?;
    const pb = plan(b, 0, pa.window, .{}).?;
    try std.testing.expectEqual(Mode.jump, pb.mode);
}

test "single-piece file: window, head and tail collapse without duplicates" {
    const g = single(1000, 16 * 1024);
    const p = plan(g, 500, null, .{}).?;
    try std.testing.expectEqual(@as(usize, 1), p.sets().len);
    try std.testing.expectEqual(@as(u32, 0), p.sets()[0].piece);
}
