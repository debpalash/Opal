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
//! The same probe answers a second question: how many bytes are "enough to
//! start"? A fixed 4 MB is wrong in both directions — a low-bitrate 700 MB film
//! needs a fifth of that, a 4K remux needs more. `refine` reads the container's
//! duration, divides the file size by it to get the real bitrate, and asks for
//! START_SECONDS of it (clamped to 1-8 MB). See Plan.start_bytes.
//!
//! Pure: std only. No allocator, no state, no io.

const std = @import("std");

/// Enough to hold an EBML SeekHead / MP4 box chain / AVI header.
pub const PROBE_BYTES: u64 = 256 * 1024;

/// Head buffer we keep pinned for smooth playback. NOT what we wait for before
/// starting — see START_BYTES / Plan.start_bytes.
pub const HEAD_BYTES: u64 = 16 * 1024 * 1024;

/// Fallback when the container does not expose its duration in the head probe.
/// The real threshold is derived from the file's own bitrate (file size ÷
/// duration) once `refine` has read the header; this is only the conservative
/// guess used before that.
pub const START_BYTES: u64 = 4 * 1024 * 1024;

/// Clamp for the duration-derived start threshold. One megabyte is a floor so a
/// very low-bitrate file still gives the demuxer a usable runway; eight
/// megabytes is a ceiling so a high-bitrate 4K file never makes playback wait
/// for the whole head window.
pub const MIN_START_BYTES: u64 = 1 * 1024 * 1024;
pub const MAX_START_BYTES: u64 = 8 * 1024 * 1024;

/// How many seconds of media the start threshold should cover. Two seconds is
/// enough to satisfy mpv's initial cache gate (0.5s for loopback streams) with
/// headroom for a piece-boundary stall, without making a slow swarm wait for
/// data it does not need yet.
pub const START_SECONDS: f64 = 2.0;

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

    /// Bytes that must be present before the player may open the file. Derived
    /// from the container's duration (`file_size / duration * START_SECONDS`)
    /// when the head probe exposes it; otherwise a size-scaled fallback.
    start_bytes: u64 = START_BYTES,

    pub fn tailLen(self: Plan) u64 {
        if (self.tail_start >= self.file_size) return 0;
        return self.file_size - self.tail_start;
    }
    pub fn needsTail(self: Plan) bool {
        return self.tailLen() > 0;
    }
    /// Size of the full prefetch window (head + tail). NOT the start gate — the
    /// player only waits for `start_bytes`; the rest keeps downloading behind it.
    pub fn requiredBytes(self: Plan) u64 {
        return @min(self.head_end, self.file_size) + self.tailLen();
    }
};

/// Size-only fallback: assume a typical two-hour runtime, so a couple of
/// seconds is `file_size / (7200 / START_SECONDS)`. Clamped. This is what an
/// unparseable container (or a non-faststart MP4, whose moov is at EOF) gets.
/// A plain `file_size / 256` would be far too eager: it implies an eight-minute
/// runtime and asks an 8 GB film for 32 MB of runway.
fn fallbackStartBytes(file_size: u64) u64 {
    // 7200 s runtime / START_SECONDS (2 s) == one byte in 3600.
    const scaled = file_size / 3600;
    return @max(MIN_START_BYTES, @min(MAX_START_BYTES, scaled));
}

/// The actual start threshold: bitrate × START_SECONDS, clamped.
///
/// A 700 MB two-hour film (0.78 Mbps) needs ~0.2 MB for two seconds; a 20 GB
/// 4K film (25 Mbps) needs ~6 MB. Using the file's own duration avoids both
/// the fixed-4 MB over-wait on low-bitrate files and the under-wait on 4K.
fn startBytesFor(file_size: u64, duration_secs: ?f64) u64 {
    const fallback = fallbackStartBytes(file_size);
    const d = duration_secs orelse return fallback;
    if (!(d > 0.0) or !std.math.isFinite(d)) return fallback;

    const bytes_per_sec = @as(f64, @floatFromInt(file_size)) / d;
    const want = bytes_per_sec * START_SECONDS;
    if (!(want > 0.0) or !std.math.isFinite(want)) return fallback;

    const min_f = @as(f64, @floatFromInt(MIN_START_BYTES));
    const max_f = @as(f64, @floatFromInt(MAX_START_BYTES));
    return @as(u64, @intFromFloat(@max(min_f, @min(max_f, want))));
}

/// Phase 1: what to fetch before we know anything. Head probe + a guessed tail.
///
/// Small files are special-cased: if head+tail would cover most of the file
/// anyway, just require the whole thing — a 40 MB episode with an 8 MB tail
/// guess is not worth two windows.
pub fn initialPlan(format: Format, file_size: u64) Plan {
    var p = Plan{ .format = format, .file_size = file_size };
    if (file_size == 0) return p;

    p.start_bytes = @min(fallbackStartBytes(file_size), file_size);
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

/// Phase 2: refine the start threshold and the tail using the container's own
/// header, parsed out of `probe` (the first bytes of the file, PROBE_BYTES is
/// plenty).
///
/// The start threshold is duration-derived for indexed containers. The tail is
/// left as the conservative guess when the index pointer can't be read — a
/// guess is always better than a wrong exact answer.
pub fn refine(plan: Plan, probe: []const u8) Plan {
    if (plan.file_size == 0) return plan;

    var p = plan;

    // The head probe carries the container's duration for MKV, faststart MP4
    // and AVI, so "enough to start" can be derived from the file's actual
    // bitrate instead of a fixed guess. Non-faststart MP4 keeps its moov at
    // EOF, where the probe can't see it, so it keeps the size heuristic.
    const duration: ?f64 = switch (plan.format) {
        .mkv => mkvDurationSecs(probe),
        .mp4 => mp4DurationSecs(probe),
        .avi => aviDurationSecs(probe),
        else => null,
    };
    p.start_bytes = @min(startBytesFor(plan.file_size, duration), plan.file_size);

    if (!plan.format.needsTail()) return p;

    const idx: ?u64 = switch (plan.format) {
        .mkv => mkvIndexOffset(probe),
        .mp4 => mp4MoovOffset(probe, plan.file_size),
        .avi => aviIndexOffset(probe),
        else => null,
    };

    const at = idx orelse return p;

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
const ID_INFO: u64 = 0x1549A966;
const ID_TIMECODE_SCALE: u64 = 0x2AD7B1;
const ID_DURATION: u64 = 0x4489;

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
// Duration — how many bytes is "a couple of seconds"?
// ══════════════════════════════════════════════════════════

/// Duration in seconds from the Matroska `Info` element, or null when the
/// element is not inside `probe` / is malformed. TimecodeScale defaults to
/// 1,000,000 ns (1 ms), per the Matroska spec.
fn mkvDurationSecs(probe: []const u8) ?f64 {
    const eid = readId(probe, 0) orelse return null;
    if (eid.val != ID_EBML) return null;
    const esz = readSize(probe, eid.len) orelse return null;
    var at: usize = eid.len + esz.len + @as(usize, @intCast(@min(esz.val, probe.len)));

    const sid = readId(probe, at) orelse return null;
    if (sid.val != ID_SEGMENT) return null;
    const ssz = readSize(probe, at + sid.len) orelse return null;
    at = at + sid.len + ssz.len;

    var guard: usize = 0;
    while (at < probe.len and guard < 64) : (guard += 1) {
        const id = readId(probe, at) orelse break;
        const sz = readSize(probe, at + id.len) orelse break;
        const body = at + id.len + sz.len;
        const size: usize = @intCast(@min(sz.val, probe.len));

        if (id.val == ID_CLUSTER) break;
        if (id.val == ID_INFO) {
            const end = @min(body + size, probe.len);
            if (parseMkvInfo(probe[body..end])) |d| return d;
        }

        if (sz.val == 0x00FF_FFFF_FFFF_FFFF) break;
        const next = body + size;
        if (next <= at or next > probe.len) break;
        at = next;
    }
    return null;
}

fn parseMkvInfo(info: []const u8) ?f64 {
    var timecode_scale: u64 = 1_000_000; // ns
    var duration: ?f64 = null;
    var at: usize = 0;
    var guard: usize = 0;
    while (at < info.len and guard < 32) : (guard += 1) {
        const id = readId(info, at) orelse break;
        const sz = readSize(info, at + id.len) orelse break;
        const body = at + id.len + sz.len;
        const size: usize = @intCast(@min(sz.val, info.len));
        if (body + size > info.len) break;
        const end = body + size;

        if (id.val == ID_TIMECODE_SCALE) timecode_scale = readUint(info[body..end]);
        if (id.val == ID_DURATION) {
            const raw = info[body..end];
            if (raw.len == 4) {
                const bits = std.mem.readInt(u32, raw[0..4], .big);
                duration = @as(f64, @as(f32, @bitCast(bits)));
            } else if (raw.len == 8) {
                const bits = std.mem.readInt(u64, raw[0..8], .big);
                duration = @as(f64, @bitCast(bits));
            }
        }
        at = end;
    }
    const d = duration orelse return null;
    if (timecode_scale == 0) return null;
    return d * @as(f64, @floatFromInt(timecode_scale)) / 1e9;
}

/// Duration in seconds from a faststart MP4's `moov/mvhd`, or null when the
/// moov box is not in the head probe (non-faststart files keep it at EOF).
fn mp4DurationSecs(probe: []const u8) ?f64 {
    var at: u64 = 0;
    var guard: usize = 0;
    while (guard < 64) : (guard += 1) {
        if (at + 8 > probe.len) return null;
        const i: usize = @intCast(at);
        var size: u64 = std.mem.readInt(u32, probe[i..][0..4], .big);
        const typ = probe[i + 4 .. i + 8];
        var hdr: u64 = 8;
        if (size == 1) {
            if (at + 16 > probe.len) return null;
            size = std.mem.readInt(u64, probe[i + 8 ..][0..8], .big);
            hdr = 16;
        } else if (size == 0) {
            size = probe.len - at; // extends to the end of the probe
        }
        if (size < hdr) return null;

        if (std.mem.eql(u8, typ, "moov")) {
            const end = @min(at + size, probe.len);
            return mp4MvhdDuration(probe[i + hdr .. @intCast(end)]);
        }
        at += size;
        if (at >= probe.len) return null;
    }
    return null;
}

fn mp4MvhdDuration(moov: []const u8) ?f64 {
    var at: usize = 0;
    var guard: usize = 0;
    while (at + 8 <= moov.len and guard < 64) : (guard += 1) {
        var size: u64 = std.mem.readInt(u32, moov[at..][0..4], .big);
        const typ = moov[at + 4 .. at + 8];
        var hdr: usize = 8;
        if (size == 1) {
            if (at + 16 > moov.len) return null;
            size = std.mem.readInt(u64, moov[at + 8 ..][0..8], .big);
            hdr = 16;
        } else if (size == 0) {
            size = moov.len - at;
        }
        if (size < hdr or at + size > moov.len) return null;
        if (std.mem.eql(u8, typ, "mvhd")) {
            const body = moov[at + hdr .. at + @as(usize, @intCast(size))];
            if (body.len < 4) return null;
            if (body[0] == 0) {
                if (body.len < 20) return null;
                const timescale = std.mem.readInt(u32, body[12..][0..4], .big);
                const duration = std.mem.readInt(u32, body[16..][0..4], .big);
                if (timescale == 0) return null;
                return @as(f64, @floatFromInt(duration)) / @as(f64, @floatFromInt(timescale));
            }
            if (body[0] == 1) {
                if (body.len < 32) return null;
                const timescale = std.mem.readInt(u32, body[20..][0..4], .big);
                const duration = std.mem.readInt(u64, body[24..][0..8], .big);
                if (timescale == 0) return null;
                return @as(f64, @floatFromInt(duration)) / @as(f64, @floatFromInt(timescale));
            }
            return null;
        }
        at += @intCast(size);
    }
    return null;
}

/// Duration in seconds from the AVI `avih` header (`dwMicroSecPerFrame` ×
/// `dwTotalFrames`), or null when the header is not in the probe.
fn aviDurationSecs(probe: []const u8) ?f64 {
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
            if (std.mem.eql(u8, list_type, "hdrl")) {
                const end = @min(at + 8 + size, probe.len);
                if (aviHeaderDuration(probe[i + 12 .. @intCast(end)])) |d| return d;
            }
            at += 8 + size + (size & 1);
            continue;
        }
        at += 8 + size + (size & 1);
    }
    return null;
}

fn aviHeaderDuration(hdrl: []const u8) ?f64 {
    var at: usize = 0;
    var guard: usize = 0;
    while (at + 8 <= hdrl.len and guard < 32) : (guard += 1) {
        const ck = hdrl[at .. at + 4];
        const size: usize = @intCast(std.mem.readInt(u32, hdrl[at + 4 ..][0..4], .little));
        const body = at + 8;
        if (body + size > hdrl.len) return null;
        if (std.mem.eql(u8, ck, "avih")) {
            if (size < 20) return null;
            const usec_per_frame = std.mem.readInt(u32, hdrl[body..][0..4], .little);
            const total_frames = std.mem.readInt(u32, hdrl[body + 16 ..][0..4], .little);
            if (usec_per_frame == 0) return null;
            return (@as(f64, @floatFromInt(usec_per_frame)) *
                @as(f64, @floatFromInt(total_frames))) / 1e6;
        }
        at = body + size + (size & 1);
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

test "start threshold follows the file's bitrate, not a fixed 4 MB" {
    // 700 MB / 2 h = ~0.78 Mbps → ~0.2 MB for two seconds, floored at 1 MB.
    try t.expectEqual(MIN_START_BYTES, startBytesFor(700 * 1024 * 1024, 7200.0));
    // 20 GB / 2 h = ~23.8 Mbps → ~5.7 MB for two seconds.
    const hd = startBytesFor(20 * 1024 * 1024 * 1024, 7200.0);
    try t.expect(hd > 5 * 1024 * 1024);
    try t.expect(hd < MAX_START_BYTES);
    // 200 GB / 2 h would exceed the ceiling; clamp it.
    try t.expectEqual(MAX_START_BYTES, startBytesFor(200 * 1024 * 1024 * 1024, 7200.0));
    // Unknown duration falls back to the size heuristic, not zero.
    try t.expectEqual(
        fallbackStartBytes(20 * 1024 * 1024 * 1024),
        startBytesFor(20 * 1024 * 1024 * 1024, null),
    );
    // A zero/NaN duration is not a usable bitrate.
    try t.expectEqual(fallbackStartBytes(1024 * 1024 * 1024), startBytesFor(1024 * 1024 * 1024, 0.0));
}

test "size-only fallback assumes a two-hour runtime, not a fixed fraction" {
    // 700 MB → ~0.2 MB for two seconds; the 1 MB floor keeps a runway.
    try t.expectEqual(MIN_START_BYTES, fallbackStartBytes(700 * 1024 * 1024));
    // 8 GB → ~2.3 MB. A 1/256th heuristic would ask for 32 MB.
    const movie = fallbackStartBytes(8 * 1024 * 1024 * 1024);
    try t.expect(movie > 2 * 1024 * 1024);
    try t.expect(movie < 3 * 1024 * 1024);
    // 50 GB → ~14 MB uncapped; the ceiling keeps the wait bounded.
    try t.expectEqual(MAX_START_BYTES, fallbackStartBytes(50 * 1024 * 1024 * 1024));
    // Tiny files never ask for more than they are.
    const small = initialPlan(.other, 64 * 1024);
    try t.expectEqual(@as(u64, 64 * 1024), small.start_bytes);
}

test "MKV: Info duration turns the start threshold into bitrate × seconds" {
    var buf: [256]u8 = undefined;
    @memset(&buf, 0);
    var w: usize = 0;

    const ebml = [_]u8{ 0x1A, 0x45, 0xDF, 0xA3, 0x84, 0, 0, 0, 0 };
    @memcpy(buf[w..][0..ebml.len], &ebml);
    w += ebml.len;

    const seg_id = [_]u8{ 0x18, 0x53, 0x80, 0x67 };
    @memcpy(buf[w..][0..4], &seg_id);
    w += 4;
    buf[w] = 0x01;
    std.mem.writeInt(u56, buf[w + 1 ..][0..7], 0x00FF_FFFF_FFFF_FF, .big);
    w += 8;

    const info_id = [_]u8{ 0x15, 0x49, 0xA9, 0x66 };
    @memcpy(buf[w..][0..4], &info_id);
    w += 4;
    const info_size_at = w;
    buf[w] = 0x80;
    w += 1;
    const info_body = w;

    // TimecodeScale = 1,000,000 ns (1 ms).
    buf[w] = 0x2A;
    buf[w + 1] = 0xD7;
    buf[w + 2] = 0xB1;
    buf[w + 3] = 0x84;
    w += 4;
    std.mem.writeInt(u32, buf[w..][0..4], 1_000_000, .big);
    w += 4;

    // Duration = 7,200,000 ticks (7200 s at 1 ms ticks), 8-byte float.
    buf[w] = 0x44;
    buf[w + 1] = 0x89;
    buf[w + 2] = 0x88;
    w += 3;
    const dur_bits: u64 = @bitCast(@as(f64, 7_200_000.0));
    std.mem.writeInt(u64, buf[w..][0..8], dur_bits, .big);
    w += 8;

    buf[info_size_at] = 0x80 | @as(u8, @intCast(w - info_body));

    const cluster = [_]u8{ 0x1F, 0x43, 0xB6, 0x75, 0x80 };
    @memcpy(buf[w..][0..cluster.len], &cluster);
    w += cluster.len;

    const d = mkvDurationSecs(buf[0..w]).?;
    try t.expectApproxEqAbs(@as(f64, 7200.0), d, 0.001);

    // 20 GB / 7200 s = ~2.98 MB/s; two seconds is ~5.7 MiB, under the cap.
    const size: u64 = 20 * 1024 * 1024 * 1024;
    const refined = refine(initialPlan(.mkv, size), buf[0..w]);
    try t.expect(refined.start_bytes > 5 * 1024 * 1024);
    try t.expect(refined.start_bytes <= MAX_START_BYTES);
}

test "MP4: faststart mvhd duration drives the start threshold" {
    var buf: [160]u8 = undefined;
    @memset(&buf, 0);
    _ = box(&buf, 0, 32, "ftyp");
    _ = box(&buf, 32, 100, "moov");
    const mvhd_at = 40;
    _ = box(&buf, mvhd_at, 92, "mvhd");
    buf[mvhd_at + 8] = 0; // version 0
    std.mem.writeInt(u32, buf[mvhd_at + 8 + 12 ..][0..4], 1000, .big); // timescale
    std.mem.writeInt(u32, buf[mvhd_at + 8 + 16 ..][0..4], 7_200_000, .big); // duration

    const d = mp4DurationSecs(buf[0..132]).?;
    try t.expectApproxEqAbs(@as(f64, 7200.0), d, 0.001);

    const size: u64 = 20 * 1024 * 1024 * 1024;
    const refined = refine(initialPlan(.mp4, size), buf[0..132]);
    try t.expect(refined.start_bytes > 5 * 1024 * 1024);
    try t.expect(refined.start_bytes <= MAX_START_BYTES);
    try t.expect(!refined.needsTail()); // faststart: moov is in the head
}

test "AVI: avih duration drives the start threshold" {
    var buf: [64]u8 = undefined;
    @memset(&buf, 0);
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], 44, .little);
    @memcpy(buf[8..12], "AVI ");

    // LIST hdrl, size = type (4) + avih header (8) + avih body (20) = 32.
    @memcpy(buf[12..16], "LIST");
    std.mem.writeInt(u32, buf[16..20], 32, .little);
    @memcpy(buf[20..24], "hdrl");

    @memcpy(buf[24..28], "avih");
    std.mem.writeInt(u32, buf[28..32], 20, .little);
    std.mem.writeInt(u32, buf[32..36], 40_000, .little); // 25 fps
    std.mem.writeInt(u32, buf[48..52], 180_000, .little); // total frames

    const d = aviDurationSecs(buf[0..52]).?;
    try t.expectApproxEqAbs(@as(f64, 7200.0), d, 0.001);
}

test "requiredBytes: head + tail, and a linear format asks for the head only" {
    const size: u64 = 4 * 1024 * 1024 * 1024;
    const mkv = initialPlan(.mkv, size);
    try t.expectEqual(HEAD_BYTES + TAIL_FALLBACK_BYTES, mkv.requiredBytes());

    const ts = initialPlan(.ts, size);
    try t.expectEqual(HEAD_BYTES, ts.requiredBytes());
}
