//! What a demuxer must be able to READ before it can open a media file.
//!
//! This is the difference between "33% downloaded" and "actually playable".
//!
//! A partially-downloaded MKV does not start at 33%, or at 90%, because mpv's
//! Matroska demuxer SEEKS TO THE END OF THE FILE during open, to read the Cues
//! (the seek index) and the Tags block. Since mkvtoolnix v7 every scene release
//! carries track-statistics Tags written *after* the Cues — i.e. at the literal
//! last byte of the file. The demuxer blocks there, inside demux_mkv_open(),
//! before it has created a single track. No amount of head progress helps; the
//! bytes it is waiting for are at the other end of the file.
//!
//! And the requirement is NOT the same for every container:
//!
//!   - **MKV / WebM** — Cues + Tags at EOF. Needs the tail. Their exact offset is
//!     recorded in the SeekHead at the FRONT of the file, so it can be computed
//!     rather than guessed.
//!   - **MP4 / MOV** — needs the `moov` atom. If the file was muxed with
//!     +faststart, moov sits before mdat and NO tail is needed at all. Otherwise
//!     moov is after the multi-GB mdat, and without it libavformat fails outright
//!     ("moov atom not found"). Its offset is computable by walking box sizes.
//!   - **AVI** — the `idx1` index sits after the `movi` chunk. The movi chunk's
//!     size is in the header, so the index offset is computable from the front.
//!   - **MPEG-TS / M2TS** — no index, no global header. Streams from byte 0. No
//!     tail whatsoever.
//!   - **FLV** — metadata at the head. No tail.
//!   - **ASF / WMV** — index object at the end; not worth parsing, use a tail guess.
//!
//! So the strategy is two-phase: fetch a small PROBE from the head, parse the
//! container's own index pointer out of it, and only then know the exact tail
//! range to demand. When parsing fails, fall back to a conservative byte-sized
//! tail — never a piece-count, because "last 5 pieces" is 5 MB on a 1 MB-piece
//! torrent and 80 MB on a 16 MB-piece one.
//!
//! Pure: std only. No allocator, no state, no io.

const std = @import("std");

/// Enough to hold an EBML SeekHead / MP4 box chain / AVI header.
pub const PROBE_BYTES: u64 = 256 * 1024;

/// Head buffer we keep pinned for smooth playback. NOT what we wait for before
/// starting — see START_BYTES.
pub const HEAD_BYTES: u64 = 16 * 1024 * 1024;

/// The only thing playback actually WAITS on: enough of the file's start for the
/// demuxer to begin reading. A couple of seconds of 1080p.
///
/// Everything else (the rest of the head, and the container index at EOF) keeps
/// downloading at top priority behind it. Waiting for all of that before pressing
/// play was correct but needlessly slow — a torrent pulling 8 MB/s still sat at
/// "Buffering 87%" for no good reason.
pub const START_BYTES: u64 = 4 * 1024 * 1024;

/// Tail buffer when the index offset can't be parsed. MKV Cues run 50 KB-1 MB and
/// MP4 moov 1-5 MB for a 2h 1080p file, so 8 MB is comfortable headroom.
pub const TAIL_FALLBACK_BYTES: u64 = 8 * 1024 * 1024;

pub const Format = enum {
    mkv, // + webm
    mp4, // + mov, m4v
    avi,
    ts, // + m2ts, mts
    flv,
    asf, // + wmv
    other,

    /// Does this container keep an index at the end that the demuxer reads on open?
    pub fn needsTail(self: Format) bool {
        return switch (self) {
            .mkv, .mp4, .avi, .asf, .other => true,
            .ts, .flv => false, // linear formats — playable from byte 0
        };
    }
};

pub fn formatOf(name: []const u8) Format {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return .other;
    var buf: [8]u8 = undefined;
    const raw = name[dot + 1 ..];
    if (raw.len == 0 or raw.len > buf.len) return .other;
    const ext = std.ascii.lowerString(buf[0..raw.len], raw);

    if (std.mem.eql(u8, ext, "mkv") or std.mem.eql(u8, ext, "webm")) return .mkv;
    if (std.mem.eql(u8, ext, "mp4") or std.mem.eql(u8, ext, "mov") or std.mem.eql(u8, ext, "m4v")) return .mp4;
    if (std.mem.eql(u8, ext, "avi")) return .avi;
    if (std.mem.eql(u8, ext, "ts") or std.mem.eql(u8, ext, "m2ts") or std.mem.eql(u8, ext, "mts")) return .ts;
    if (std.mem.eql(u8, ext, "flv")) return .flv;
    if (std.mem.eql(u8, ext, "wmv") or std.mem.eql(u8, ext, "asf")) return .asf;
    return .other;
}

/// The byte ranges that must be present before handing the file to the player.
pub const Plan = struct {
    format: Format = .other,
    file_size: u64 = 0,

    /// [0, head_end)
    head_end: u64 = 0,
    /// [tail_start, file_size). Empty (tail_start == file_size) means no tail needed.
    tail_start: u64 = 0,

    /// True once tail_start came from the container's OWN index pointer rather
    /// than a guess. A guess is safe; exact is cheaper.
    exact: bool = false,

    pub fn tailLen(self: Plan) u64 {
        if (self.tail_start >= self.file_size) return 0;
        return self.file_size - self.tail_start;
    }
    pub fn needsTail(self: Plan) bool {
        return self.tailLen() > 0;
    }
    /// Total bytes that must land before playback can begin.
    pub fn requiredBytes(self: Plan) u64 {
        return @min(self.head_end, self.file_size) + self.tailLen();
    }
};

/// Phase 1: what to fetch before we know anything. Head probe + a guessed tail.
///
/// Small files are special-cased: if head+tail would cover most of the file
/// anyway, just require the whole thing — a 40 MB episode with an 8 MB tail
/// guess is not worth two windows.
pub fn initialPlan(format: Format, file_size: u64) Plan {
    var p = Plan{ .format = format, .file_size = file_size };
    if (file_size == 0) return p;

    const head = @min(HEAD_BYTES, file_size);

    if (!format.needsTail()) {
        p.head_end = head;
        p.tail_start = file_size; // no tail
        p.exact = true; // linear formats: certainty, not a guess
        return p;
    }

    const tail = @min(TAIL_FALLBACK_BYTES, file_size);
    // Overlapping windows on a small file → just take the file.
    if (head + tail >= file_size) {
        p.head_end = file_size;
        p.tail_start = file_size;
        p.exact = true;
        return p;
    }

    p.head_end = head;
    p.tail_start = file_size - tail;
    p.exact = false;
    return p;
}

/// Phase 2: refine the tail using the container's own index pointer, parsed out
/// of `probe` (the first bytes of the file, PROBE_BYTES is plenty).
///
/// Returns the plan unchanged when the probe is too short or unparseable — a
/// conservative guess is always better than a wrong exact answer.
pub fn refine(plan: Plan, probe: []const u8) Plan {
    if (plan.file_size == 0) return plan;
    if (!plan.format.needsTail()) return plan;

    const idx: ?u64 = switch (plan.format) {
        .mkv => mkvIndexOffset(probe),
        .mp4 => mp4MoovOffset(probe, plan.file_size),
        .avi => aviIndexOffset(probe),
        else => null,
    };

    const at = idx orelse return plan;

    var p = plan;

    // A faststart MP4 reports its moov as already inside the head — nothing to
    // wait for at the end at all.
    if (at >= plan.file_size) {
        p.tail_start = plan.file_size;
        p.exact = true;
        return p;
    }
    if (at <= plan.head_end) {
        p.tail_start = plan.file_size; // index already covered by the head window
        p.exact = true;
        return p;
    }

    // Back off slightly: the SeekHead points at the element START, and a few
    // bytes of slack costs nothing while an off-by-one costs the whole open.
    const slack: u64 = 64 * 1024;
    p.tail_start = if (at > slack) at - slack else 0;
    p.exact = true;
    return p;
}

// ══════════════════════════════════════════════════════════
// MKV / WebM — EBML SeekHead
// ══════════════════════════════════════════════════════════

const ID_EBML: u64 = 0x1A45DFA3;
const ID_SEGMENT: u64 = 0x18538067;
const ID_SEEKHEAD: u64 = 0x114D9B74;
const ID_SEEK: u64 = 0x4DBB;
const ID_SEEKID: u64 = 0x53AB;
const ID_SEEKPOS: u64 = 0x53AC;
const ID_CUES: u64 = 0x1C53BB6B;
const ID_TAGS: u64 = 0x1254C367;
const ID_CLUSTER: u64 = 0x1F43B675;

const Vint = struct { val: u64, len: usize };

/// EBML element ID: the leading-zero count of the first byte gives the width, and
/// the marker bit is KEPT (IDs are compared as stored).
fn readId(buf: []const u8, at: usize) ?Vint {
    if (at >= buf.len) return null;
    const b0 = buf[at];
    if (b0 == 0) return null;
    const width: usize = @clz(b0) + 1;
    if (width > 4 or at + width > buf.len) return null;
    var v: u64 = 0;
    for (buf[at .. at + width]) |b| v = (v << 8) | b;
    return .{ .val = v, .len = width };
}

/// EBML data size: same width encoding, but the marker bit is STRIPPED.
fn readSize(buf: []const u8, at: usize) ?Vint {
    if (at >= buf.len) return null;
    const b0 = buf[at];
    if (b0 == 0) return null;
    const width: usize = @clz(b0) + 1;
    if (width > 8 or at + width > buf.len) return null;
    var v: u64 = b0 & (@as(u64, 0xFF) >> @intCast(width));
    var i: usize = 1;
    while (i < width) : (i += 1) v = (v << 8) | buf[at + i];
    return .{ .val = v, .len = width };
}

fn readUint(buf: []const u8) u64 {
    var v: u64 = 0;
    for (buf) |b| v = (v << 8) | b;
    return v;
}

/// Byte offset of the EARLIEST trailing element (Cues or Tags) that the demuxer
/// will seek to on open, or null if the SeekHead can't be read.
///
/// SeekPositions are relative to the start of the Segment's DATA, not to the file
/// — getting that wrong points the tail window at the wrong place entirely.
fn mkvIndexOffset(probe: []const u8) ?u64 {
    // EBML header
    const eid = readId(probe, 0) orelse return null;
    if (eid.val != ID_EBML) return null;
    const esz = readSize(probe, eid.len) orelse return null;
    var at: usize = eid.len + esz.len + @as(usize, @intCast(@min(esz.val, probe.len)));

    // Segment
    const sid = readId(probe, at) orelse return null;
    if (sid.val != ID_SEGMENT) return null;
    const ssz = readSize(probe, at + sid.len) orelse return null;
    const seg_data: u64 = @intCast(at + sid.len + ssz.len);

    at = @intCast(seg_data);

    // Walk the Segment's top-level children looking for a SeekHead. Stop at the
    // first Cluster — anything past that is payload, not header.
    var best: ?u64 = null;
    var guard: usize = 0;
    while (at < probe.len and guard < 64) : (guard += 1) {
        const id = readId(probe, at) orelse break;
        const sz = readSize(probe, at + id.len) orelse break;
        const body = at + id.len + sz.len;

        if (id.val == ID_CLUSTER) break;

        if (id.val == ID_SEEKHEAD) {
            const end = @min(body + @as(usize, @intCast(sz.val)), probe.len);
            if (scanSeekHead(probe[body..end], seg_data)) |off| {
                best = if (best) |b| @min(b, off) else off;
            }
        }

        // Unknown-size element (all ones) — can't skip it safely.
        if (sz.val == 0x00FF_FFFF_FFFF_FFFF) break;
        const next = body + @as(usize, @intCast(sz.val));
        if (next <= at) break; // malformed; refuse to spin
        at = next;
    }

    return best;
}

fn scanSeekHead(sh: []const u8, seg_data: u64) ?u64 {
    var best: ?u64 = null;
    var at: usize = 0;
    var guard: usize = 0;
    while (at < sh.len and guard < 64) : (guard += 1) {
        const id = readId(sh, at) orelse break;
        const sz = readSize(sh, at + id.len) orelse break;
        const body = at + id.len + sz.len;
        const end = body + @as(usize, @intCast(sz.val));
        if (end > sh.len) break;

        if (id.val == ID_SEEK) {
            var seek_id: u64 = 0;
            var seek_pos: ?u64 = null;
            var j: usize = body;
            var g2: usize = 0;
            while (j < end and g2 < 16) : (g2 += 1) {
                const cid = readId(sh, j) orelse break;
                const csz = readSize(sh, j + cid.len) orelse break;
                const cbody = j + cid.len + csz.len;
                const cend = cbody + @as(usize, @intCast(csz.val));
                if (cend > sh.len) break;

                if (cid.val == ID_SEEKID) seek_id = readUint(sh[cbody..cend]);
                if (cid.val == ID_SEEKPOS) seek_pos = readUint(sh[cbody..cend]);
                j = cend;
            }

            // Only the trailing elements matter. Chapters/Attachments/Tracks sit
            // in the header and are already covered by the head window.
            if ((seek_id == ID_CUES or seek_id == ID_TAGS)) {
                if (seek_pos) |sp| {
                    const abs = seg_data + sp;
                    best = if (best) |b| @min(b, abs) else abs;
                }
            }
        }
        at = end;
    }
    return best;
}

// ══════════════════════════════════════════════════════════
// MP4 / MOV — the moov atom
// ══════════════════════════════════════════════════════════

/// Byte offset of `moov`, walking the top-level box chain.
///
/// Returns `file_size` (i.e. "no tail needed") when moov is found BEFORE mdat —
/// that's a +faststart file and it streams from byte 0 with no tail at all.
fn mp4MoovOffset(probe: []const u8, file_size: u64) ?u64 {
    var at: u64 = 0;
    var guard: usize = 0;
    while (guard < 64) : (guard += 1) {
        if (at + 8 > probe.len) return null;
        const i: usize = @intCast(at);
        var size: u64 = std.mem.readInt(u32, probe[i..][0..4], .big);
        const typ = probe[i + 4 .. i + 8];

        var hdr: u64 = 8;
        if (size == 1) {
            // 64-bit largesize
            if (at + 16 > probe.len) return null;
            size = std.mem.readInt(u64, probe[i + 8 ..][0..8], .big);
            hdr = 16;
        } else if (size == 0) {
            // "extends to EOF" — only legal on the last box.
            return null;
        }
        if (size < hdr) return null;

        if (std.mem.eql(u8, typ, "moov")) {
            // Found before any mdat → faststart. Nothing to wait for at the end.
            return file_size;
        }
        if (std.mem.eql(u8, typ, "mdat")) {
            // moov comes after the payload. Its offset is right past mdat.
            const after = at + size;
            if (after >= file_size) return null;
            return after;
        }

        at += size;
        if (at >= file_size) return null;
    }
    return null;
}

// ══════════════════════════════════════════════════════════
// AVI — idx1, right after the movi chunk
// ══════════════════════════════════════════════════════════

fn aviIndexOffset(probe: []const u8) ?u64 {
    if (probe.len < 12) return null;
    if (!std.mem.eql(u8, probe[0..4], "RIFF")) return null;
    if (!std.mem.eql(u8, probe[8..12], "AVI ")) return null;

    var at: u64 = 12;
    var guard: usize = 0;
    while (guard < 64) : (guard += 1) {
        const i: usize = @intCast(at);
        if (i + 8 > probe.len) return null;
        const ck = probe[i .. i + 4];
        const size: u64 = std.mem.readInt(u32, probe[i + 4 ..][0..4], .little);

        if (std.mem.eql(u8, ck, "LIST")) {
            if (i + 12 > probe.len) return null;
            const list_type = probe[i + 8 .. i + 12];
            if (std.mem.eql(u8, list_type, "movi")) {
                // idx1 begins immediately after this LIST (chunks are word-aligned).
                const end = at + 8 + size;
                return end + (end & 1);
            }
            // Any other LIST (hdrl, INFO): skip it whole.
            at += 8 + size + (size & 1);
            continue;
        }

        at += 8 + size + (size & 1);
    }
    return null;
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

const t = std.testing;

test "formatOf + which containers keep an index at the end" {
    try t.expectEqual(Format.mkv, formatOf("House.of.the.Dragon.S03E04.1080p.HEVC.x265-MeGusta.mkv"));
    try t.expectEqual(Format.mkv, formatOf("clip.WEBM"));
    try t.expectEqual(Format.mp4, formatOf("a.mp4"));
    try t.expectEqual(Format.mp4, formatOf("a.MOV"));
    try t.expectEqual(Format.avi, formatOf("old.avi"));
    try t.expectEqual(Format.ts, formatOf("stream.ts"));
    try t.expectEqual(Format.flv, formatOf("v.flv"));
    try t.expectEqual(Format.asf, formatOf("v.wmv"));
    try t.expectEqual(Format.other, formatOf("noext"));

    // The whole point: TS and FLV are linear and need NO tail; the rest do.
    try t.expect(Format.mkv.needsTail());
    try t.expect(Format.mp4.needsTail());
    try t.expect(Format.avi.needsTail());
    try t.expect(!Format.ts.needsTail());
    try t.expect(!Format.flv.needsTail());
}

test "initialPlan: linear formats demand no tail at all" {
    const p = initialPlan(.ts, 4 * 1024 * 1024 * 1024);
    try t.expect(!p.needsTail());
    try t.expectEqual(@as(u64, 0), p.tailLen());
    try t.expect(p.exact);
}

test "initialPlan: indexed formats reserve a byte-sized tail (never a piece count)" {
    const size: u64 = 4 * 1024 * 1024 * 1024;
    const p = initialPlan(.mkv, size);
    try t.expectEqual(HEAD_BYTES, p.head_end);
    try t.expectEqual(TAIL_FALLBACK_BYTES, p.tailLen());
    try t.expectEqual(size - TAIL_FALLBACK_BYTES, p.tail_start);
    try t.expect(!p.exact); // it's a guess until we parse the index
}

test "initialPlan: a small file is just fetched whole (windows would overlap)" {
    const size: u64 = 20 * 1024 * 1024; // head(16) + tail(8) > 20
    const p = initialPlan(.mkv, size);
    try t.expectEqual(size, p.head_end);
    try t.expectEqual(@as(u64, 0), p.tailLen());
    try t.expect(p.exact);
}

test "initialPlan: zero-size file doesn't divide by anything" {
    const p = initialPlan(.mkv, 0);
    try t.expectEqual(@as(u64, 0), p.requiredBytes());
}

// ── MKV ──

/// Build a minimal but REAL EBML head: EBML header, Segment, SeekHead with two
/// Seek entries pointing at Cues and Tags (SeekPositions are segment-relative).
fn buildMkvProbe(cues_rel: u64, tags_rel: u64, out: []u8) struct { probe: []const u8, seg_data: u64 } {
    var w: usize = 0;
    // EBML header (id 4B) + size 0x84 (4 bytes of body) + 4 filler bytes
    const ebml = [_]u8{ 0x1A, 0x45, 0xDF, 0xA3, 0x84, 0, 0, 0, 0 };
    @memcpy(out[w..][0..ebml.len], &ebml);
    w += ebml.len;

    // Segment: id (4B) + 8-byte "unknown-ish" size (we use a real size)
    const seg_id = [_]u8{ 0x18, 0x53, 0x80, 0x67 };
    @memcpy(out[w..][0..4], &seg_id);
    w += 4;
    out[w] = 0x01; // 8-byte size marker
    std.mem.writeInt(u56, out[w + 1 ..][0..7], 0x00FF_FFFF_FFFF_FF, .big);
    w += 8;
    const seg_data: u64 = @intCast(w);

    // SeekHead
    const sh_id = [_]u8{ 0x11, 0x4D, 0x9B, 0x74 };
    @memcpy(out[w..][0..4], &sh_id);
    w += 4;
    const sh_size_at = w;
    out[w] = 0x80; // 1-byte size, patched below
    w += 1;
    const sh_body = w;

    for ([_]struct { id: [4]u8, pos: u64 }{
        .{ .id = .{ 0x1C, 0x53, 0xBB, 0x6B }, .pos = cues_rel }, // Cues
        .{ .id = .{ 0x12, 0x54, 0xC3, 0x67 }, .pos = tags_rel }, // Tags
    }) |e| {
        out[w] = 0x4D;
        out[w + 1] = 0xBB; // Seek
        w += 2;
        const seek_size_at = w;
        out[w] = 0x80;
        w += 1;
        const seek_body = w;

        out[w] = 0x53;
        out[w + 1] = 0xAB; // SeekID
        out[w + 2] = 0x84; // 4 bytes
        w += 3;
        @memcpy(out[w..][0..4], &e.id);
        w += 4;

        out[w] = 0x53;
        out[w + 1] = 0xAC; // SeekPosition
        out[w + 2] = 0x88; // 8 bytes
        w += 3;
        std.mem.writeInt(u64, out[w..][0..8], e.pos, .big);
        w += 8;

        out[seek_size_at] = 0x80 | @as(u8, @intCast(w - seek_body));
    }
    out[sh_size_at] = 0x80 | @as(u8, @intCast(w - sh_body));

    return .{ .probe = out[0..w], .seg_data = seg_data };
}

test "MKV: the tail comes from the SeekHead, and it's the EARLIEST trailing element" {
    // A 4 GB file whose Cues start 20 MB from the end, with Tags after them.
    // Cues are earliest, so THAT is what the tail window has to reach.
    const size: u64 = 4 * 1024 * 1024 * 1024;
    var buf: [512]u8 = undefined;
    const probe0 = buildMkvProbe(0, 0, &buf); // just to learn seg_data
    const seg = probe0.seg_data;

    const cues_abs: u64 = size - 20 * 1024 * 1024;
    const tags_abs: u64 = size - 4 * 1024 * 1024;
    var buf2: [512]u8 = undefined;
    const b = buildMkvProbe(cues_abs - seg, tags_abs - seg, &buf2);

    const off = mkvIndexOffset(b.probe).?;
    try t.expectEqual(cues_abs, off); // the EARLIEST of the two, not the Tags

    const refined = refine(initialPlan(.mkv, size), b.probe);
    try t.expect(refined.exact);
    try t.expectEqual(cues_abs - 64 * 1024, refined.tail_start);

    // The load-bearing assertion: the blind "last 8 MB" guess would have declared
    // this file ready WITHOUT the Cues (they start 20 MB from the end), and mpv
    // would have hung on open exactly as it does today. The exact answer demands
    // more than the guess — which is the entire point of parsing the SeekHead.
    try t.expect(refined.tailLen() > TAIL_FALLBACK_BYTES);
}

test "MKV: unparseable probe keeps the safe guess rather than inventing an offset" {
    const junk = [_]u8{0xAA} ** 64;
    const size: u64 = 4 * 1024 * 1024 * 1024;
    const p0 = initialPlan(.mkv, size);
    const p1 = refine(p0, &junk);
    try t.expectEqual(p0.tail_start, p1.tail_start);
    try t.expect(!p1.exact);
}

test "MKV: an index already inside the head window means no tail is needed" {
    var buf: [512]u8 = undefined;
    const b = buildMkvProbe(1024, 2048, &buf); // index at ~1 KB
    const size: u64 = 4 * 1024 * 1024 * 1024;
    const refined = refine(initialPlan(.mkv, size), b.probe);
    try t.expect(refined.exact);
    try t.expect(!refined.needsTail());
}

// ── MP4 ──

fn box(out: []u8, at: usize, size: u32, typ: *const [4]u8) usize {
    std.mem.writeInt(u32, out[at..][0..4], size, .big);
    @memcpy(out[at + 4 ..][0..4], typ);
    return at + 8;
}

test "MP4: +faststart (moov before mdat) needs NO tail" {
    var buf: [64]u8 = undefined;
    @memset(&buf, 0);
    _ = box(&buf, 0, 32, "ftyp");
    _ = box(&buf, 32, 1000, "moov"); // moov first → faststart
    const size: u64 = 4 * 1024 * 1024 * 1024;

    const off = mp4MoovOffset(buf[0..40], size).?;
    try t.expectEqual(size, off); // sentinel: "no tail"

    const refined = refine(initialPlan(.mp4, size), buf[0..40]);
    try t.expect(refined.exact);
    try t.expect(!refined.needsTail());
}

test "MP4: moov AFTER mdat — the tail starts right past mdat, not at 'last 8 MB'" {
    var buf: [64]u8 = undefined;
    @memset(&buf, 0);
    _ = box(&buf, 0, 32, "ftyp");
    _ = box(&buf, 32, 900_000_000, "mdat"); // huge payload, moov behind it
    const size: u64 = 1_000_000_000;

    const off = mp4MoovOffset(buf[0..40], size).?;
    try t.expectEqual(@as(u64, 32 + 900_000_000), off);

    const refined = refine(initialPlan(.mp4, size), buf[0..40]);
    try t.expect(refined.exact);
    try t.expectEqual(off - 64 * 1024, refined.tail_start);
}

// ── AVI ──

test "AVI: idx1 sits just past the movi LIST" {
    var buf: [64]u8 = undefined;
    @memset(&buf, 0);
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], 999, .little);
    @memcpy(buf[8..12], "AVI ");

    // LIST hdrl — size 4 = just the list-type word, so the chunk spans [12, 24).
    @memcpy(buf[12..16], "LIST");
    std.mem.writeInt(u32, buf[16..20], 4, .little);
    @memcpy(buf[20..24], "hdrl");

    // LIST movi (size 5000) → idx1 at 24 + 8 + 5000
    @memcpy(buf[24..28], "LIST");
    std.mem.writeInt(u32, buf[28..32], 5000, .little);
    @memcpy(buf[32..36], "movi");

    const off = aviIndexOffset(buf[0..36]).?;
    try t.expectEqual(@as(u64, 24 + 8 + 5000), off);
}

test "START_BYTES is a small fraction of the head — playback must not wait for it all" {
    // The thing playback waits on has to be far smaller than the head we keep
    // pinned, or a fast torrent still sits on a buffering bar for no reason (an
    // 8 MB/s download was showing "Buffering 87%" because the gate wanted 16 MB).
    // The rest of the head, and the index at EOF, keep racing in the background.
    try t.expect(START_BYTES < HEAD_BYTES);
    try t.expect(START_BYTES <= 4 * 1024 * 1024);
    // ...but still big enough for a demuxer to actually get going.
    try t.expect(START_BYTES >= 1024 * 1024);
}

test "requiredBytes: head + tail, and a linear format asks for the head only" {
    const size: u64 = 4 * 1024 * 1024 * 1024;
    const mkv = initialPlan(.mkv, size);
    try t.expectEqual(HEAD_BYTES + TAIL_FALLBACK_BYTES, mkv.requiredBytes());

    const ts = initialPlan(.ts, size);
    try t.expectEqual(HEAD_BYTES, ts.requiredBytes());
}
