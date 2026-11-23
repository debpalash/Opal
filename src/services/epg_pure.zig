//! Live TV programme guide (XMLTV) — PURE, unit-tested (`test_epg_pure`).
//!
//! Everything the guide decides lives here so the shipped logic is the tested
//! logic: XMLTV parsing into fixed-size records, the time maths (XMLTV
//! `YYYYMMDDhhmmss +HHMM` → UTC epoch seconds, DST-safe because every instant
//! carries its own offset), channel matching (user mapping → tvg-id → a
//! normalised name), now/next selection, programme search and the
//! stale-guide verdict.
//!
//!   <tv>
//!     <channel id="BBCOne.uk"><display-name>BBC One HD</display-name></channel>
//!     <programme start="20261025003000 +0100" stop="20261025013000 +0000"
//!                channel="BBCOne.uk"><title>News</title><desc>…</desc></programme>
//!   </tv>
//!
//! Memory is bounded by construction: the parser only writes into caller-owned
//! slices (MAX_CHANNELS / MAX_PROGRAMMES records), truncates every field, and a
//! huge guide is narrowed to a look-ahead horizon that fits (see `parse`). A
//! malformed or truncated document yields whatever parsed cleanly — never a
//! panic (a worker panic aborts the whole app).

const std = @import("std");

/// Raw download cap (a compressed guide is ~5-30 MB for a big provider).
pub const MAX_FETCH_BYTES: usize = 64 * 1024 * 1024;
/// Decompressed XML cap — a gzip bomb stops here instead of eating RAM.
pub const MAX_XML_BYTES: usize = 160 * 1024 * 1024;
pub const MAX_CHANNELS: usize = 4096;
pub const MAX_PROGRAMMES: usize = 24000;
/// The guide keeps programmes from KEEP_PAST_S ago up to KEEP_AHEAD_S ahead.
pub const KEEP_PAST_S: i64 = 3 * 3600;
pub const KEEP_AHEAD_S: i64 = 48 * 3600;
/// A guide whose download is older than this, or that covers less than
/// STALE_COVERAGE_S of future time, is flagged stale.
pub const STALE_AGE_S: i64 = 24 * 3600;
pub const STALE_COVERAGE_S: i64 = 6 * 3600;
/// Re-download a URL guide when its cached copy is older than this.
pub const REFRESH_TTL_S: i64 = 12 * 3600;

pub const GuideChannel = struct {
    id: [64]u8 = std.mem.zeroes([64]u8),
    id_len: u8 = 0,
    name: [96]u8 = std.mem.zeroes([96]u8),
    name_len: u8 = 0,
    /// normalizeName(display-name), precomputed for matching.
    norm: [64]u8 = std.mem.zeroes([64]u8),
    norm_len: u8 = 0,

    pub fn idSlice(self: *const GuideChannel) []const u8 {
        return self.id[0..self.id_len];
    }
    pub fn nameSlice(self: *const GuideChannel) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Programme = struct {
    chan: [64]u8 = std.mem.zeroes([64]u8),
    chan_len: u8 = 0,
    start: i64 = 0,
    stop: i64 = 0,
    title: [128]u8 = std.mem.zeroes([128]u8),
    title_len: u8 = 0,
    desc: [200]u8 = std.mem.zeroes([200]u8),
    desc_len: u8 = 0,
    category: [32]u8 = std.mem.zeroes([32]u8),
    category_len: u8 = 0,

    pub fn chanSlice(self: *const Programme) []const u8 {
        return self.chan[0..self.chan_len];
    }
    pub fn titleSlice(self: *const Programme) []const u8 {
        return self.title[0..self.title_len];
    }
    pub fn descSlice(self: *const Programme) []const u8 {
        return self.desc[0..self.desc_len];
    }
};

// ══════════════════════════════════════════════════════════
// Time maths
// ══════════════════════════════════════════════════════════

/// Days since 1970-01-01 for a proleptic Gregorian date (Hinnant's algorithm).
pub fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + @as(i64, day) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn isLeap(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

fn daysInMonth(y: i64, m: u8) u8 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeap(y)) 29 else 28,
        else => 0,
    };
}

fn digits(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var v: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

/// XMLTV timestamp → UTC epoch seconds. Accepts `YYYYMMDDhhmmss`,
/// `YYYYMMDDhhmm`, an optional `+HHMM` / `-HHMM` / `+HH:MM` offset (absent =
/// UTC, the XMLTV default) and an optional trailing `Z`. The offset is applied
/// per timestamp, so a programme that straddles a DST change (start `+0100`,
/// stop `+0000`) gets its real duration. Null on anything out of range.
pub fn parseXmltvTime(raw: []const u8) ?i64 {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    var i: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    const dt = s[0..i];
    if (dt.len != 12 and dt.len != 14) return null;
    const year: i64 = digits(dt[0..4]) orelse return null;
    const month: u8 = @intCast(digits(dt[4..6]) orelse return null);
    const day: u8 = @intCast(digits(dt[6..8]) orelse return null);
    const hour: i64 = digits(dt[8..10]) orelse return null;
    const minute: i64 = digits(dt[10..12]) orelse return null;
    const second: i64 = if (dt.len == 14) (digits(dt[12..14]) orelse return null) else 0;
    if (year < 1970 or year > 2200) return null;
    if (month < 1 or month > 12) return null;
    if (day < 1 or day > daysInMonth(year, month)) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;

    var offset_s: i64 = 0;
    const rest = std.mem.trim(u8, s[i..], " \t");
    if (rest.len > 0 and !(rest.len == 1 and (rest[0] == 'Z' or rest[0] == 'z'))) {
        const sign: i64 = switch (rest[0]) {
            '+' => 1,
            '-' => -1,
            else => return null,
        };
        var od: [4]u8 = undefined;
        var n: usize = 0;
        for (rest[1..]) |c| {
            if (c == ':') continue;
            if (c < '0' or c > '9' or n >= 4) return null;
            od[n] = c;
            n += 1;
        }
        if (n != 4) return null;
        const oh: i64 = digits(od[0..2]) orelse return null;
        const om: i64 = digits(od[2..4]) orelse return null;
        if (oh > 14 or om > 59) return null;
        offset_s = sign * (oh * 3600 + om * 60);
    }
    const local = daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second;
    return local - offset_s;
}

/// "HH:MM" wall-clock for a UTC instant, given the viewer's UTC offset AT THAT
/// INSTANT (callers look the offset up per instant, so a DST change between
/// now and the programme is honoured).
pub fn formatClock(utc: i64, offset_s: i64, out: []u8) []const u8 {
    const local = utc + offset_s;
    const sod = @mod(local, 86400);
    const h: u32 = @intCast(@divFloor(sod, 3600));
    const m: u32 = @intCast(@divFloor(@mod(sod, 3600), 60));
    return std.fmt.bufPrint(out, "{d:0>2}:{d:0>2}", .{ h, m }) catch out[0..0];
}

const WEEKDAYS = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };

/// "Today 21:00" / "Tomorrow 06:30" / "Mon 21:00" relative to `now` (both
/// instants rendered in their own local offsets).
pub fn formatDayClock(utc: i64, offset_s: i64, now: i64, now_offset_s: i64, out: []u8) []const u8 {
    const day = @divFloor(utc + offset_s, 86400);
    const today = @divFloor(now + now_offset_s, 86400);
    var clock_buf: [8]u8 = undefined;
    const clock = formatClock(utc, offset_s, &clock_buf);
    const prefix: []const u8 = if (day == today) "Today" else if (day == today + 1) "Tomorrow" else WEEKDAYS[@intCast(@mod(day, 7))];
    return std.fmt.bufPrint(out, "{s} {s}", .{ prefix, clock }) catch out[0..0];
}

/// Elapsed fraction of [start, stop) at `now`, clamped to 0..1.
pub fn progress(start: i64, stop: i64, now: i64) f32 {
    if (stop <= start) return 0;
    if (now <= start) return 0;
    if (now >= stop) return 1;
    return @as(f32, @floatFromInt(now - start)) / @as(f32, @floatFromInt(stop - start));
}

// ══════════════════════════════════════════════════════════
// Text helpers (entity decode, bounded UTF-8 copy)
// ══════════════════════════════════════════════════════════

/// Longest prefix of `s` (≤ max bytes) that does not cut a UTF-8 sequence.
pub fn utf8Prefix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

fn put(dst: []u8, n: *usize, bytes: []const u8) bool {
    if (n.* + bytes.len > dst.len) return false;
    @memcpy(dst[n.*..][0..bytes.len], bytes);
    n.* += bytes.len;
    return true;
}

/// Decode XML text into `dst`: the five named entities, numeric `&#N;` /
/// `&#xH;` references and `<![CDATA[…]]>` sections; whitespace runs collapse to
/// one space and the result is trimmed. An unknown entity is copied verbatim.
/// Stops at the last whole UTF-8 sequence that fits. Returns bytes written.
pub fn decodeText(src: []const u8, dst: []u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    var pending_space = false;
    while (i < src.len) {
        const c = src[i];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            pending_space = n > 0;
            i += 1;
            continue;
        }
        var chunk_buf: [4]u8 = undefined;
        var chunk: []const u8 = src[i .. i + 1];
        var adv: usize = 1;
        if (c == '<' and std.mem.startsWith(u8, src[i..], "<![CDATA[")) {
            const body_start = i + 9;
            const end = std.mem.indexOfPos(u8, src, body_start, "]]>") orelse src.len;
            // CDATA is literal; still collapse its whitespace via recursion-free copy.
            var j = body_start;
            while (j < end) : (j += 1) {
                const b = src[j];
                if (b == ' ' or b == '\t' or b == '\r' or b == '\n') {
                    pending_space = n > 0;
                    continue;
                }
                if (pending_space) {
                    if (!put(dst, &n, " ")) return trimUtf8(dst, n);
                    pending_space = false;
                }
                if (!put(dst, &n, src[j .. j + 1])) return trimUtf8(dst, n);
            }
            i = @min(src.len, end + 3);
            continue;
        }
        if (c == '&') {
            if (std.mem.indexOfScalarPos(u8, src, i + 1, ';')) |semi| {
                if (semi - i <= 10) {
                    const ent = src[i + 1 .. semi];
                    if (decodeEntity(ent, &chunk_buf)) |decoded| {
                        chunk = decoded;
                        adv = semi + 1 - i;
                    }
                }
            }
        }
        if (pending_space) {
            if (!put(dst, &n, " ")) return trimUtf8(dst, n);
            pending_space = false;
        }
        if (!put(dst, &n, chunk)) return trimUtf8(dst, n);
        i += adv;
    }
    return trimUtf8(dst, n);
}

fn trimUtf8(dst: []u8, n: usize) usize {
    // Drop a trailing partial UTF-8 sequence left by a byte-level truncation.
    var end = n;
    var back: usize = 0;
    while (back < 4 and end > back and (dst[end - 1 - back] & 0xC0) == 0x80) back += 1;
    if (end > back) {
        const lead = dst[end - 1 - back];
        const need: usize = if (lead < 0x80) 1 else if (lead >= 0xF0) 4 else if (lead >= 0xE0) 3 else if (lead >= 0xC0) 2 else 1;
        if (need != back + 1) end = end - 1 - back;
    } else if (back > 0) {
        end = 0;
    }
    while (end > 0 and dst[end - 1] == ' ') end -= 1;
    return end;
}

fn decodeEntity(ent: []const u8, out: *[4]u8) ?[]const u8 {
    if (std.mem.eql(u8, ent, "amp")) return "&";
    if (std.mem.eql(u8, ent, "lt")) return "<";
    if (std.mem.eql(u8, ent, "gt")) return ">";
    if (std.mem.eql(u8, ent, "quot")) return "\"";
    if (std.mem.eql(u8, ent, "apos")) return "'";
    if (ent.len >= 2 and ent[0] == '#') {
        const cp: u21 = blk: {
            if (ent[1] == 'x' or ent[1] == 'X') {
                const v = std.fmt.parseInt(u32, ent[2..], 16) catch return null;
                if (v > 0x10FFFF) return null;
                break :blk @intCast(v);
            }
            const v = std.fmt.parseInt(u32, ent[1..], 10) catch return null;
            if (v > 0x10FFFF) return null;
            break :blk @intCast(v);
        };
        if (cp < 0x20 and cp != '\t' and cp != '\n' and cp != '\r') return null;
        const len = std.unicode.utf8Encode(cp, out) catch return null;
        return out[0..len];
    }
    return null;
}

// ══════════════════════════════════════════════════════════
// XML scanning
// ══════════════════════════════════════════════════════════

/// Value of attribute `key` inside an open tag (`<programme start="…" …>`),
/// raw (entity-encoded). Requires whitespace before the key so `start` never
/// matches `pdc-start`. Single or double quotes.
pub fn attrValue(tag: []const u8, key: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, tag, from, key)) |at| {
        from = at + 1;
        if (at == 0) continue;
        const before = tag[at - 1];
        if (before != ' ' and before != '\t' and before != '\n' and before != '\r') continue;
        var j = at + key.len;
        while (j < tag.len and (tag[j] == ' ' or tag[j] == '\t')) j += 1;
        if (j >= tag.len or tag[j] != '=') continue;
        j += 1;
        while (j < tag.len and (tag[j] == ' ' or tag[j] == '\t')) j += 1;
        if (j >= tag.len) return null;
        const q = tag[j];
        if (q != '"' and q != '\'') continue;
        const end = std.mem.indexOfScalarPos(u8, tag, j + 1, q) orelse return null;
        return tag[j + 1 .. end];
    }
    return null;
}

/// End index (exclusive) of the open tag starting at `start` (`<`), honouring
/// quoted attribute values. Null when unterminated.
fn tagEnd(xml: []const u8, start: usize) ?usize {
    var i = start + 1;
    var quote: u8 = 0;
    while (i < xml.len) : (i += 1) {
        const c = xml[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '>') {
            return i + 1;
        }
    }
    return null;
}

fn isNameEnd(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == '>' or c == '/';
}

/// First `<name …>text</name>` child inside `body`, raw. Null when absent.
pub fn childRaw(body: []const u8, name: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfScalarPos(u8, body, from, '<')) |lt| {
        from = lt + 1;
        if (lt + 1 + name.len >= body.len) return null;
        if (!std.mem.eql(u8, body[lt + 1 .. lt + 1 + name.len], name)) continue;
        if (!isNameEnd(body[lt + 1 + name.len])) continue;
        const open_end = tagEnd(body, lt) orelse return null;
        if (body[open_end - 2] == '/') return ""; // <title/>
        var close_buf: [40]u8 = undefined;
        if (name.len + 3 > close_buf.len) return null;
        close_buf[0] = '<';
        close_buf[1] = '/';
        @memcpy(close_buf[2..][0..name.len], name);
        close_buf[2 + name.len] = '>';
        const close = close_buf[0 .. name.len + 3];
        const ce = std.mem.indexOfPos(u8, body, open_end, close) orelse return null;
        return body[open_end..ce];
    }
    return null;
}

pub const Element = struct {
    kind: enum { channel, programme },
    tag: []const u8, // the open tag incl. attributes
    body: []const u8, // inner XML ("" for self-closing)
};

/// Walks top-level `<channel>` and `<programme>` elements in document order.
/// A truncated element ends the walk (the rest of the document is unusable).
pub const ElementIter = struct {
    xml: []const u8,
    pos: usize = 0,

    pub fn next(self: *ElementIter) ?Element {
        while (std.mem.indexOfScalarPos(u8, self.xml, self.pos, '<')) |lt| {
            const rest = self.xml[lt + 1 ..];
            const kind: @FieldType(Element, "kind") = if (std.mem.startsWith(u8, rest, "programme") and rest.len > 9 and isNameEnd(rest[9]))
                .programme
            else if (std.mem.startsWith(u8, rest, "channel") and rest.len > 7 and isNameEnd(rest[7]))
                .channel
            else {
                self.pos = lt + 1;
                continue;
            };
            const open_end = tagEnd(self.xml, lt) orelse {
                self.pos = self.xml.len;
                return null;
            };
            const tag = self.xml[lt..open_end];
            if (tag.len >= 2 and tag[tag.len - 2] == '/') {
                self.pos = open_end;
                return .{ .kind = kind, .tag = tag, .body = "" };
            }
            const close: []const u8 = if (kind == .programme) "</programme>" else "</channel>";
            const ce = std.mem.indexOfPos(u8, self.xml, open_end, close) orelse {
                self.pos = self.xml.len;
                return null;
            };
            self.pos = ce + close.len;
            return .{ .kind = kind, .tag = tag, .body = self.xml[open_end..ce] };
        }
        self.pos = self.xml.len;
        return null;
    }
};

fn copyDecoded(raw: []const u8, dst: []u8) u8 {
    const n = @min(decodeText(raw, dst), 255);
    scrubUtf8(dst[0..n]);
    return @intCast(n);
}

/// Replace every byte of an invalid UTF-8 sequence with '?', in place, so a
/// mis-encoded guide can never hand invalid UTF-8 to the UI or a JSON writer.
pub fn scrubUtf8(buf: []u8) void {
    var i: usize = 0;
    while (i < buf.len) {
        const len = std.unicode.utf8ByteSequenceLength(buf[i]) catch {
            buf[i] = '?';
            i += 1;
            continue;
        };
        if (i + len > buf.len or !std.unicode.utf8ValidateSlice(buf[i .. i + len])) {
            buf[i] = '?';
            i += 1;
            continue;
        }
        i += len;
    }
}

fn timesOf(tag: []const u8) ?struct { start: i64, stop: i64 } {
    const start = parseXmltvTime(attrValue(tag, "start") orelse return null) orelse return null;
    const stop = if (attrValue(tag, "stop")) |s| (parseXmltvTime(s) orelse start + 1800) else start + 1800;
    if (stop <= start) return null;
    return .{ .start = start, .stop = stop };
}

fn fillChannel(el: Element, c: *GuideChannel) bool {
    c.* = .{};
    const id_raw = attrValue(el.tag, "id") orelse return false;
    c.id_len = copyDecoded(id_raw, &c.id);
    if (c.id_len == 0) return false;
    if (childRaw(el.body, "display-name")) |dn| c.name_len = copyDecoded(dn, &c.name);
    if (c.name_len == 0) {
        @memcpy(c.name[0..c.id_len], c.id[0..c.id_len]);
        c.name_len = c.id_len;
    }
    c.norm_len = @intCast(normalizeName(c.nameSlice(), &c.norm).len);
    return true;
}

fn fillProgramme(el: Element, p: *Programme) bool {
    p.* = .{};
    // XMLTV allows a missing stop; it becomes a 30-minute slot, later clipped
    // to the next programme's start by sortProgrammes.
    const t = timesOf(el.tag) orelse return false;
    p.start = t.start;
    p.stop = t.stop;
    p.chan_len = copyDecoded(attrValue(el.tag, "channel") orelse return false, &p.chan);
    if (p.chan_len == 0) return false;
    if (childRaw(el.body, "title")) |title| p.title_len = copyDecoded(title, &p.title);
    if (p.title_len == 0) return false;
    if (childRaw(el.body, "desc")) |d| p.desc_len = copyDecoded(d, &p.desc);
    if (childRaw(el.body, "category")) |cat| p.category_len = copyDecoded(cat, &p.category);
    return true;
}

pub const ParseResult = struct {
    channels: usize = 0,
    programmes: usize = 0,
    /// Elements dropped because they were malformed (bad time, no title…).
    malformed: usize = 0,
    /// Valid programmes outside the kept window or beyond the record cap.
    dropped: usize = 0,
    /// Look-ahead actually kept (≤ KEEP_AHEAD_S; narrower for a huge guide).
    horizon_s: i64 = 0,
    /// now + horizon_s: re-parse the (cached) guide before this to roll on.
    window_end: i64 = 0,
    /// Last stop time anywhere in the document — the guide's real coverage,
    /// which drives the stale/expired verdict even when the window is narrow.
    latest_stop: i64 = 0,
};

/// Parse `xml` into the caller's fixed slices. Priority when the guide is
/// bigger than `programmes_out`: what is on air now, then upcoming shows hour
/// by hour (pass 1 buckets start times so pass 2 keeps the widest look-ahead
/// that fits), then recently ended ones. A huge guide therefore keeps every
/// channel's now/next instead of the first N channels' whole fortnight.
pub fn parse(xml: []const u8, now: i64, channels_out: []GuideChannel, programmes_out: []Programme) ParseResult {
    var res: ParseResult = .{};
    const past = now - KEEP_PAST_S;
    const HOURS: usize = @intCast(@divFloor(KEEP_AHEAD_S, 3600));
    var on_air: usize = 0;
    var ended: usize = 0;
    // per_hour[h] = programmes starting in [now + (h-1)h, now + h·h).
    var per_hour: [HOURS + 1]usize = @splat(0);
    {
        var it = ElementIter{ .xml = xml };
        while (it.next()) |el| {
            if (el.kind != .programme) continue;
            const t = timesOf(el.tag) orelse continue;
            res.latest_stop = @max(res.latest_stop, t.stop);
            if (t.start <= now and t.stop > now) {
                on_air += 1;
            } else if (t.start > now and t.start < now + KEEP_AHEAD_S) {
                const bucket: usize = @intCast(@divFloor(t.start - now, 3600) + 1);
                per_hour[@min(bucket, HOURS)] += 1;
            } else if (t.stop <= now and t.stop > past) {
                ended += 1;
            }
        }
    }
    const cap = programmes_out.len;
    var used: usize = @min(on_air, cap);
    var horizon_hours: usize = 0;
    {
        var h: usize = 1;
        while (h <= HOURS) : (h += 1) {
            if (used + per_hour[h] > cap) break;
            used += per_hour[h];
            horizon_hours = h;
        }
    }
    const keep_ended = horizon_hours == HOURS and used + ended <= cap;
    res.horizon_s = @as(i64, @intCast(horizon_hours)) * 3600;
    res.window_end = now + res.horizon_s;

    var it = ElementIter{ .xml = xml };
    while (it.next()) |el| switch (el.kind) {
        .channel => {
            if (res.channels >= channels_out.len) continue;
            if (fillChannel(el, &channels_out[res.channels])) res.channels += 1 else res.malformed += 1;
        },
        .programme => {
            if (res.programmes >= cap) {
                res.dropped += 1;
                continue;
            }
            const p = &programmes_out[res.programmes];
            if (!fillProgramme(el, p)) {
                res.malformed += 1;
                continue;
            }
            const airing = p.start <= now and p.stop > now;
            const upcoming = p.start > now and p.start < res.window_end;
            const recent = keep_ended and p.stop <= now and p.stop > past;
            if (!airing and !upcoming and !recent) {
                res.dropped += 1;
                continue;
            }
            res.programmes += 1;
        },
    };
    return res;
}

// ══════════════════════════════════════════════════════════
// Ordering + lookup
// ══════════════════════════════════════════════════════════

fn progLess(_: void, a: Programme, b: Programme) bool {
    switch (std.ascii.orderIgnoreCase(a.chanSlice(), b.chanSlice())) {
        .lt => return true,
        .gt => return false,
        .eq => return a.start < b.start,
    }
}

/// Sort by (channel id, case-insensitive; start) so a channel's schedule is one
/// contiguous, time-ordered run, then clip overlaps (a programme ends no later
/// than the next one on its channel starts).
pub fn sortProgrammes(progs: []Programme) void {
    std.sort.pdq(Programme, progs, {}, progLess);
    var i: usize = 0;
    while (i + 1 < progs.len) : (i += 1) {
        const a = &progs[i];
        const b = &progs[i + 1];
        if (std.ascii.eqlIgnoreCase(a.chanSlice(), b.chanSlice()) and a.stop > b.start and b.start > a.start) a.stop = b.start;
    }
}

pub const Range = struct { lo: usize, hi: usize };

/// [lo, hi) of `chan_id`'s programmes in a sortProgrammes-ordered slice.
pub fn channelRange(progs: []const Programme, chan_id: []const u8) Range {
    var lo: usize = 0;
    var hi: usize = progs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (std.ascii.orderIgnoreCase(progs[mid].chanSlice(), chan_id) == .lt) lo = mid + 1 else hi = mid;
    }
    var end = lo;
    while (end < progs.len and std.ascii.eqlIgnoreCase(progs[end].chanSlice(), chan_id)) end += 1;
    return .{ .lo = lo, .hi = end };
}

pub const NowNext = struct { now: ?usize = null, next: ?usize = null };

/// The programme on air at `now` and the one after it, within a channel's
/// time-ordered range. Gaps are fine: with nothing on air, `next` is still the
/// first upcoming programme.
pub fn nowNext(progs: []const Programme, r: Range, now: i64) NowNext {
    var out: NowNext = .{};
    var i = r.lo;
    while (i < r.hi) : (i += 1) {
        const p = &progs[i];
        if (p.start <= now and now < p.stop) {
            out.now = i;
        } else if (p.start > now) {
            out.next = i;
            break;
        }
    }
    return out;
}

/// Case-insensitive substring test (ASCII folding; UTF-8 bytes compare as-is).
pub fn containsFold(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Programmes whose title (or description) contains `query`, that have not
/// ended by `now`. Title hits rank before description-only hits, then
/// earliest first. Writes up to min(out.len, 256) indices; returns the count.
pub fn searchProgrammes(progs: []const Programme, query: []const u8, now: i64, out: []usize) usize {
    const q = std.mem.trim(u8, query, " \t");
    const cap = @min(out.len, 256);
    if (q.len == 0 or cap == 0) return 0;
    var ranks: [256]i128 = undefined;
    var n: usize = 0;
    for (progs, 0..) |*p, idx| {
        if (p.stop <= now) continue;
        const title_hit = containsFold(p.titleSlice(), q);
        if (!title_hit and !containsFold(p.descSlice(), q)) continue;
        const rank = (@as(i128, if (title_hit) 0 else 1) << 64) + p.start;
        var pos = n;
        while (pos > 0 and ranks[pos - 1] > rank) pos -= 1;
        if (pos >= cap) continue;
        var k = @min(n, cap - 1);
        while (k > pos) : (k -= 1) {
            out[k] = out[k - 1];
            ranks[k] = ranks[k - 1];
        }
        out[pos] = idx;
        ranks[pos] = rank;
        if (n < cap) n += 1;
    }
    return n;
}

// ══════════════════════════════════════════════════════════
// Channel matching
// ══════════════════════════════════════════════════════════

const QUALITY_TOKENS = [_][]const u8{ "hd", "fhd", "uhd", "4k", "sd", "hevc", "h265", "1080p", "720p", "576p", "480p", "1080", "720" };

/// Matching key for a channel name: ASCII-lowercased alphanumerics only, with
/// `(…)` / `[…]` asides and trailing quality tokens ("HD", "4K", "720p")
/// removed. "BBC One HD", "bbc one", "BBC One (720p) [Geo-blocked]" → "bbcone".
pub fn normalizeName(name: []const u8, out: []u8) []const u8 {
    // Tokenise on non-alphanumerics, skipping bracketed asides.
    var toks: [24][]const u8 = undefined;
    var nt: usize = 0;
    var depth: u8 = 0;
    var i: usize = 0;
    while (i < name.len) {
        const c = name[i];
        if (c == '(' or c == '[') {
            depth +|= 1;
            i += 1;
            continue;
        }
        if ((c == ')' or c == ']') and depth > 0) {
            depth -= 1;
            i += 1;
            continue;
        }
        if (depth > 0 or !std.ascii.isAlphanumeric(c)) {
            i += 1;
            continue;
        }
        const s = i;
        while (i < name.len and std.ascii.isAlphanumeric(name[i])) i += 1;
        if (nt < toks.len) {
            toks[nt] = name[s..i];
            nt += 1;
        }
    }
    while (nt > 1) {
        var is_quality = false;
        for (QUALITY_TOKENS) |q| {
            if (std.ascii.eqlIgnoreCase(toks[nt - 1], q)) is_quality = true;
        }
        if (!is_quality) break;
        nt -= 1;
    }
    var n: usize = 0;
    for (toks[0..nt]) |t| for (t) |c| {
        if (n >= out.len) return out[0..n];
        out[n] = std.ascii.toLower(c);
        n += 1;
    };
    return out[0..n];
}

/// The guide-id stem used for loose id matching: "BBCOne.uk@HD" → "bbcone".
pub fn idStem(id: []const u8, out: []u8) []const u8 {
    var s = id;
    if (std.mem.indexOfScalar(u8, s, '@')) |at| s = s[0..at];
    if (std.mem.lastIndexOfScalar(u8, s, '.')) |dot| {
        if (s.len - dot - 1 <= 3 and dot > 0) s = s[0..dot];
    }
    return normalizeName(s, out);
}

/// Stable mapping key for a playlist channel: `id:<tvg-id lowercased>` when the
/// playlist names one, else `name:<normalised name>`. "" when neither exists.
pub fn channelKey(chan_id: []const u8, name: []const u8, out: []u8) []const u8 {
    if (chan_id.len > 0) {
        const n = @min(chan_id.len, out.len -| 3);
        if (out.len < 4) return out[0..0];
        @memcpy(out[0..3], "id:");
        for (chan_id[0..n], 0..) |c, k| out[3 + k] = std.ascii.toLower(c);
        return out[0 .. 3 + n];
    }
    if (out.len < 6) return out[0..0];
    const norm = normalizeName(name, out[5..]);
    if (norm.len == 0) return out[0..0];
    @memcpy(out[0..5], "name:");
    return out[0 .. 5 + norm.len];
}

pub const MatchKind = enum { none, mapped, tvg_id, id_stem, name };

pub const Match = struct { kind: MatchKind = .none, guide_id: []const u8 = "" };

/// Resolve which guide channel a playlist channel shows. Order: the user's
/// explicit mapping (an unknown id still wins — the user said so), the
/// playlist's tvg-id (exact, then `@feed`/country-suffix stem), then the
/// normalised display name. `has_programmes(id)` lets a tvg-id match a guide
/// that lists programmes without a matching `<channel>` element.
pub fn matchChannel(
    chan_id: []const u8,
    name: []const u8,
    override: []const u8,
    channels: []const GuideChannel,
    progs: []const Programme,
) Match {
    if (override.len > 0) return .{ .kind = .mapped, .guide_id = override };
    if (chan_id.len > 0) {
        for (channels) |*c| {
            if (std.ascii.eqlIgnoreCase(c.idSlice(), chan_id)) return .{ .kind = .tvg_id, .guide_id = c.idSlice() };
        }
        const r = channelRange(progs, chan_id);
        if (r.hi > r.lo) return .{ .kind = .tvg_id, .guide_id = progs[r.lo].chanSlice() };
        var stem_buf: [64]u8 = undefined;
        const stem = idStem(chan_id, &stem_buf);
        if (stem.len > 0) {
            var other_buf: [64]u8 = undefined;
            for (channels) |*c| {
                if (std.mem.eql(u8, idStem(c.idSlice(), &other_buf), stem)) return .{ .kind = .id_stem, .guide_id = c.idSlice() };
            }
        }
    }
    var norm_buf: [64]u8 = undefined;
    const norm = normalizeName(name, &norm_buf);
    if (norm.len > 0) {
        for (channels) |*c| {
            if (std.mem.eql(u8, c.norm[0..c.norm_len], norm)) return .{ .kind = .name, .guide_id = c.idSlice() };
        }
        var stem_buf: [64]u8 = undefined;
        for (channels) |*c| {
            if (std.mem.eql(u8, idStem(c.idSlice(), &stem_buf), norm)) return .{ .kind = .name, .guide_id = c.idSlice() };
        }
    }
    return .{};
}

// ══════════════════════════════════════════════════════════
// Guide health + source
// ══════════════════════════════════════════════════════════

pub const Freshness = enum {
    empty,
    fresh,
    stale,
    expired,

    pub fn label(self: Freshness) []const u8 {
        return switch (self) {
            .empty => "No guide data",
            .fresh => "Guide up to date",
            .stale => "Guide is getting old",
            .expired => "Guide has run out",
        };
    }
};

/// Verdict for the guide banner: expired once `now` passes the last listed
/// stop; stale when the download is a day old or less than six hours of
/// listings remain; else fresh.
pub fn freshness(programmes: usize, latest_stop: i64, fetched_at: i64, now: i64) Freshness {
    if (programmes == 0) return .empty;
    if (now >= latest_stop) return .expired;
    if (now - fetched_at > STALE_AGE_S or latest_stop - now < STALE_COVERAGE_S) return .stale;
    return .fresh;
}

pub const SourceKind = enum { url, file, invalid };

/// What a user-typed guide source is: an http(s) URL, a local file (absolute
/// path, `~/…`, or `file://`), or unusable. Control characters are refused.
pub fn classifySource(text: []const u8) SourceKind {
    const s = std.mem.trim(u8, text, " \t");
    if (s.len == 0 or s.len > 1024) return .invalid;
    for (s) |c| if (c < 0x20 or c == 0x7f) return .invalid;
    if (std.ascii.startsWithIgnoreCase(s, "https://") or std.ascii.startsWithIgnoreCase(s, "http://")) {
        return if (s.len > 8) .url else .invalid;
    }
    if (std.ascii.startsWithIgnoreCase(s, "file://")) return if (s.len > 7 and s[7] == '/') .file else .invalid;
    if (s[0] == '/' or std.mem.startsWith(u8, s, "~/")) return .file;
    if (s.len > 3 and std.ascii.isAlphabetic(s[0]) and s[1] == ':' and (s[2] == '\\' or s[2] == '/')) return .file;
    return .invalid;
}

/// Local path for a `.file` source (strips `file://`); `~/` is left for the
/// caller to expand against HOME.
pub fn filePath(text: []const u8) []const u8 {
    const s = std.mem.trim(u8, text, " \t");
    if (std.ascii.startsWithIgnoreCase(s, "file://")) return s[7..];
    return s;
}

/// The source as safe to show over the API: a URL loses its userinfo and query
/// string (provider guide URLs routinely carry `username=…&password=…`); a file
/// path is reduced to its file name.
pub fn redactSource(text: []const u8, out: []u8) []const u8 {
    const s = std.mem.trim(u8, text, " \t");
    switch (classifySource(s)) {
        .invalid => return out[0..0],
        .file => {
            const p = filePath(s);
            const cut = std.mem.lastIndexOfAny(u8, p, "/\\");
            const name = if (cut) |c| p[c + 1 ..] else p;
            return std.fmt.bufPrint(out, "file: {s}", .{name}) catch out[0..0];
        },
        .url => {
            const scheme_end = (std.mem.indexOf(u8, s, "://") orelse return out[0..0]) + 3;
            var rest = s[scheme_end..];
            if (std.mem.indexOfAny(u8, rest, "?#")) |q| rest = rest[0..q];
            const host_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
            var host = rest[0..host_end];
            if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
            const had_query = std.mem.indexOfAny(u8, s[scheme_end..], "?#") != null;
            return std.fmt.bufPrint(out, "{s}{s}{s}{s}", .{ s[0..scheme_end], host, rest[host_end..], if (had_query) "?…" else "" }) catch out[0..0];
        },
    }
}

pub fn isGzip(bytes: []const u8) bool {
    return bytes.len >= 2 and bytes[0] == 0x1f and bytes[1] == 0x8b;
}

/// Inflate a `.xml.gz` guide into a fresh buffer, refusing to grow past `cap`
/// bytes (a gzip bomb fails here instead of exhausting memory). Caller frees.
pub fn gunzipBounded(gpa: std.mem.Allocator, bytes: []const u8, cap: usize) ![]u8 {
    const flate = std.compress.flate;
    var reader = std.Io.Reader.fixed(bytes);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var inflate = flate.Decompress.init(&reader, .gzip, window);
    return inflate.reader.allocRemaining(gpa, .limited(cap));
}

/// Does this look like an XMLTV document at all (so a 404 page or a JSON body
/// is reported instead of "0 programmes")?
pub fn looksLikeXmltv(bytes: []const u8) bool {
    const head = bytes[0..@min(bytes.len, 4096)];
    return std.mem.indexOf(u8, head, "<tv") != null;
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

const testing = std.testing;

test "XMLTV time: offsets convert to the same UTC instant" {
    // 2026-07-01 12:00 UTC = 1782907200.
    try testing.expectEqual(@as(?i64, 1782907200), parseXmltvTime("20260701120000 +0000"));
    try testing.expectEqual(@as(?i64, 1782907200), parseXmltvTime("20260701130000 +0100"));
    try testing.expectEqual(@as(?i64, 1782907200), parseXmltvTime("20260701080000 -0400"));
    try testing.expectEqual(@as(?i64, 1782907200), parseXmltvTime("20260701173000 +0530"));
    try testing.expectEqual(@as(?i64, 1782907200), parseXmltvTime("20260701130000 +01:00"));
    // No offset = UTC (XMLTV default); minute precision and a Z suffix are fine.
    try testing.expectEqual(@as(?i64, 1782907200), parseXmltvTime("20260701120000"));
    try testing.expectEqual(@as(?i64, 1782907200), parseXmltvTime("202607011200 Z"));
}

test "XMLTV time: invalid dates and offsets are rejected, never wrapped" {
    for ([_][]const u8{
        "",                     "2026070112",           "20261301120000 +0000", "20260230120000 +0000",
        "20260701250000 +0000", "20260701126000 +0000", "20260701120000 +1500", "20260701120000 0100",
        "20260701120000 +01",   "2026O701120000 +0000", "20250229000000",       "18000101000000",
    }) |bad| try testing.expectEqual(@as(?i64, null), parseXmltvTime(bad));
    // Leap day exists in 2028.
    try testing.expect(parseXmltvTime("20280229000000 +0000") != null);
}

test "DST: Europe/London autumn fallback keeps the real two-hour duration" {
    // Clocks go back 2026-10-25 02:00 BST → 01:00 GMT. A show listed
    // 00:30 BST → 01:30 GMT runs two real hours, though the wall clock moved one.
    const start = parseXmltvTime("20261025003000 +0100").?;
    const stop = parseXmltvTime("20261025013000 +0000").?;
    try testing.expectEqual(@as(i64, 2 * 3600), stop - start);
    // The repeated wall-clock 01:30 is two distinct instants an hour apart.
    const first = parseXmltvTime("20261025013000 +0100").?;
    const second = parseXmltvTime("20261025013000 +0000").?;
    try testing.expectEqual(@as(i64, 3600), second - first);
}

test "DST: US spring-forward gap — an hour-long show across 2am lasts one hour" {
    // America/New_York 2026-03-08: 01:30 EST (-0500) → 03:30 EDT (-0400) is 1h.
    const start = parseXmltvTime("20260308013000 -0500").?;
    const stop = parseXmltvTime("20260308033000 -0400").?;
    try testing.expectEqual(@as(i64, 3600), stop - start);
}

test "DST: now/next is decided in UTC across a transition with mixed offsets" {
    var progs = [_]Programme{ testProg("c", "Before", "20261025000000 +0100", "20261025013000 +0100"), testProg("c", "Straddle", "20261025013000 +0100", "20261025013000 +0000"), testProg("c", "After", "20261025013000 +0000", "20261025030000 +0000") };
    sortProgrammes(&progs);
    const r = channelRange(&progs, "c");
    // Before = 23:00-00:30 UTC, Straddle = 00:30-01:30 UTC, After = 01:30-03:00.
    const now = parseXmltvTime("20261025011500 +0000").?;
    const nn = nowNext(&progs, r, now);
    try testing.expectEqualStrings("Straddle", progs[nn.now.?].titleSlice());
    try testing.expectEqualStrings("After", progs[nn.next.?].titleSlice());
}

test "formatClock renders each instant in its own offset (DST-aware display)" {
    var buf: [16]u8 = undefined;
    const t = parseXmltvTime("20261025003000 +0000").?;
    try testing.expectEqualStrings("01:30", formatClock(t, 3600, &buf)); // BST
    try testing.expectEqualStrings("00:30", formatClock(t, 0, &buf)); // GMT
    try testing.expectEqualStrings("20:30", formatClock(t, -4 * 3600, &buf));
    var dbuf: [24]u8 = undefined;
    const now = parseXmltvTime("20261024220000 +0000").?; // Sat 23:00 BST
    try testing.expectEqualStrings("Tomorrow 01:30", formatDayClock(t, 3600, now, 3600, &dbuf));
    try testing.expectEqualStrings("Today 23:00", formatDayClock(now, 3600, now, 3600, &dbuf));
    const tue = parseXmltvTime("20261027200000 +0000").?;
    try testing.expectEqualStrings("Tue 20:00", formatDayClock(tue, 0, now, 3600, &dbuf));
}

test "decodeText: entities, numeric refs, CDATA, whitespace" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Tom & Jerry <3> \"q\" 'a'", buf[0..decodeText("Tom &amp; Jerry &lt;3&gt; &quot;q&quot; &apos;a&apos;", &buf)]);
    try testing.expectEqualStrings("Caf\u{e9} \u{1F4FA}", buf[0..decodeText("Caf&#233; &#x1F4FA;", &buf)]);
    try testing.expectEqualStrings("a & b", buf[0..decodeText("<![CDATA[a & b]]>", &buf)]);
    try testing.expectEqualStrings("one two", buf[0..decodeText("\n  one \t\n two  ", &buf)]);
    try testing.expectEqualStrings("&bogus; x", buf[0..decodeText("&bogus; x", &buf)]);
    // A control-char reference is not decoded into the text.
    try testing.expectEqualStrings("&#1;", buf[0..decodeText("&#1;", &buf)]);
}

test "decodeText never cuts a UTF-8 sequence when truncating" {
    var buf: [5]u8 = undefined;
    const n = decodeText("abcd\u{e9}f", &buf); // 'é' is 2 bytes and would straddle
    try testing.expectEqualStrings("abcd", buf[0..n]);
    try testing.expect(std.unicode.utf8ValidateSlice(buf[0..n]));
}

const SAMPLE =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE tv SYSTEM "xmltv.dtd">
    \\<tv generator-info-name="fixture">
    \\  <channel id="BBCOne.uk"><display-name lang="en">BBC One HD</display-name><icon src="x.png"/></channel>
    \\  <channel id="news.example"><display-name>Example &amp; News</display-name></channel>
    \\  <channel id='empty.example'/>
    \\  <programme start="20261101180000 +0000" stop="20261101190000 +0000" channel="BBCOne.uk">
    \\    <title lang="en">Six O'Clock News</title><desc>Headlines &amp; weather.</desc><category>News</category>
    \\  </programme>
    \\  <programme start="20261101190000 +0000" stop="20261101200000 +0000" channel="BBCOne.uk"><title>The One Show</title></programme>
    \\  <programme start="20261101183000 +0000" stop="20261101190000 +0000" channel="news.example"><title>World Report</title></programme>
    \\  <programme start="bogus" stop="20261101190000 +0000" channel="news.example"><title>Broken time</title></programme>
    \\  <programme start="20261101190000 +0000" stop="20261101200000 +0000" channel="news.example"></programme>
    \\  <programme start="20261101170000 +0000" pdc-start="20261101000000 +0000" channel="news.example"><title>No stop</title></programme>
    \\</tv>
;

fn testProg(chan: []const u8, title: []const u8, start: []const u8, stop: []const u8) Programme {
    var p: Programme = .{};
    @memcpy(p.chan[0..chan.len], chan);
    p.chan_len = @intCast(chan.len);
    @memcpy(p.title[0..title.len], title);
    p.title_len = @intCast(title.len);
    p.start = parseXmltvTime(start).?;
    p.stop = parseXmltvTime(stop).?;
    return p;
}

test "parse: channels, programmes, entities, malformed elements counted" {
    var chans: [8]GuideChannel = undefined;
    var progs: [16]Programme = undefined;
    const now = parseXmltvTime("20261101183000 +0000").?;
    const r = parse(SAMPLE, now, &chans, &progs);
    try testing.expectEqual(@as(usize, 3), r.channels);
    try testing.expectEqual(@as(usize, 4), r.programmes);
    try testing.expectEqual(@as(usize, 2), r.malformed); // bad start, no title
    try testing.expectEqualStrings("BBCOne.uk", chans[0].idSlice());
    try testing.expectEqualStrings("BBC One HD", chans[0].nameSlice());
    try testing.expectEqualStrings("bbcone", chans[0].norm[0..chans[0].norm_len]);
    try testing.expectEqualStrings("Example & News", chans[1].nameSlice());
    try testing.expectEqualStrings("empty.example", chans[2].nameSlice()); // id fallback
    try testing.expectEqualStrings("Six O'Clock News", progs[0].titleSlice());
    try testing.expectEqualStrings("Headlines & weather.", progs[0].descSlice());
    // A missing stop becomes a 30-minute slot; pdc-start is not mistaken for start.
    try testing.expectEqual(progs[3].start + 1800, progs[3].stop);
    try testing.expectEqual(parseXmltvTime("20261101170000 +0000").?, progs[3].start);

    sortProgrammes(progs[0..r.programmes]);
    const range = channelRange(progs[0..r.programmes], "bbcone.UK");
    try testing.expectEqual(@as(usize, 2), range.hi - range.lo);
    const nn = nowNext(progs[0..r.programmes], range, now);
    try testing.expectEqualStrings("Six O'Clock News", progs[nn.now.?].titleSlice());
    try testing.expectEqualStrings("The One Show", progs[nn.next.?].titleSlice());
}

test "nowNext: gap between shows still reports the next one" {
    var progs = [_]Programme{ testProg("c", "A", "20261101100000", "20261101110000"), testProg("c", "B", "20261101120000", "20261101130000") };
    const nn = nowNext(&progs, .{ .lo = 0, .hi = 2 }, parseXmltvTime("20261101113000").?);
    try testing.expectEqual(@as(?usize, null), nn.now);
    try testing.expectEqual(@as(?usize, 1), nn.next);
}

test "sortProgrammes clips overlapping listings on the same channel" {
    var progs = [_]Programme{ testProg("c", "Long", "20261101100000", "20261101123000"), testProg("c", "Next", "20261101120000", "20261101130000") };
    sortProgrammes(&progs);
    try testing.expectEqual(progs[1].start, progs[0].stop);
}

test "malformed guide: truncated, garbage and binary input never panic" {
    var chans: [4]GuideChannel = undefined;
    var progs: [4]Programme = undefined;
    const cases = [_][]const u8{
        "",
        "<tv>",
        "<tv><programme start=\"20261101100000\" channel=\"c\"><title>cut",
        "<tv><programme start=\"20261101100000",
        "<programme<programme<channel<channel id=",
        "\x00\xff\xfe<channel id=\"\xff\"><display-name>\xc3</display-name></channel>",
        "<tv><channel id=\"a\"><display-name>A</display-name></channel><programme start=\"x\" stop=\"y\" channel=\"\"><title></title></programme></tv>",
    };
    for (cases) |c| {
        const r = parse(c, 1_800_000_000, &chans, &progs);
        try testing.expect(r.channels <= chans.len and r.programmes <= progs.len);
        for (chans[0..r.channels]) |*ch| try testing.expect(ch.id_len <= ch.id.len);
    }
}

test "huge guide: bounded records, horizon narrows, every channel keeps now/next" {
    // 200 channels × 96 half-hour slots (48h) = 19,200 programmes into 1,000 slots.
    const alloc = testing.allocator;
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(alloc);
    const base = parseXmltvTime("20261101000000 +0000").?;
    try doc.appendSlice(alloc, "<tv>");
    var c: usize = 0;
    while (c < 200) : (c += 1) {
        var line: [256]u8 = undefined;
        try doc.appendSlice(alloc, try std.fmt.bufPrint(&line, "<channel id=\"ch{d}\"><display-name>Channel {d}</display-name></channel>", .{ c, c }));
    }
    c = 0;
    while (c < 200) : (c += 1) {
        var slot: i64 = 0;
        while (slot < 96) : (slot += 1) {
            const st = base + slot * 1800;
            var line: [256]u8 = undefined;
            try doc.appendSlice(alloc, try std.fmt.bufPrint(&line, "<programme start=\"{d}\" stop=\"{d}\" channel=\"ch{d}\"><title>Show {d}</title></programme>", .{ xmltvStamp(st), xmltvStamp(st + 1800), c, slot }));
        }
    }
    try doc.appendSlice(alloc, "</tv>");

    const chans = try alloc.alloc(GuideChannel, 300);
    defer alloc.free(chans);
    const progs = try alloc.alloc(Programme, 1000);
    defer alloc.free(progs);
    const now = base + 6 * 3600 + 600; // 06:10
    const r = parse(doc.items, now, chans, progs);
    try testing.expectEqual(@as(usize, 200), r.channels);
    try testing.expect(r.programmes <= 1000);
    try testing.expect(r.horizon_s < KEEP_AHEAD_S);
    try testing.expectEqual(now + r.horizon_s, r.window_end);
    try testing.expect(r.dropped > 0);
    // Coverage is the whole document's, so a narrow window is not "stale".
    try testing.expectEqual(base + 48 * 3600, r.latest_stop);
    try testing.expectEqual(Freshness.fresh, freshness(r.programmes, r.latest_stop, now, now));
    sortProgrammes(progs[0..r.programmes]);
    for ([_][]const u8{ "ch0", "ch99", "ch199" }) |id| {
        const nn = nowNext(progs[0..r.programmes], channelRange(progs[0..r.programmes], id), now);
        try testing.expect(nn.now != null);
        try testing.expect(nn.next != null);
    }
}

fn xmltvStamp(t: i64) u64 {
    // YYYYMMDDhhmmss as a decimal number (UTC) — test helper only.
    const days = @divFloor(t, 86400);
    const sod: u64 = @intCast(@mod(t, 86400));
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u64 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u64 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const y: u64 = @intCast(yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0));
    return ((((y * 100 + m) * 100 + d) * 100 + sod / 3600) * 100 + (sod % 3600) / 60) * 100 + sod % 60;
}

test "daysFromCivil agrees with the test inverse across centuries" {
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(u64, 20000301000000), xmltvStamp(daysFromCivil(2000, 3, 1) * 86400));
    try testing.expectEqual(@as(u64, 21000228235959), xmltvStamp(daysFromCivil(2100, 3, 1) * 86400 - 1));
}

test "normalizeName strips quality tags, asides and punctuation" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("bbcone", normalizeName("BBC One HD", &buf));
    try testing.expectEqualStrings("bbcone", normalizeName("bbc one", &buf));
    try testing.expectEqualStrings("bbcone", normalizeName("BBC One (720p) [Geo-blocked]", &buf));
    try testing.expectEqualStrings("cnninternational", normalizeName("CNN International 1080p", &buf));
    try testing.expectEqualStrings("hd", normalizeName("HD", &buf)); // never empties a real name
    try testing.expectEqualStrings("e4", normalizeName("E4", &buf));
}

test "idStem drops feed and country suffixes" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("bbcone", idStem("BBCOne.uk@HD", &buf));
    try testing.expectEqualStrings("cnn", idStem("CNN.us", &buf));
    try testing.expectEqualStrings("examplenews", idStem("example.news", &buf)); // >3-char suffix kept
}

test "channelKey prefers tvg-id, falls back to normalised name" {
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("id:bbcone.uk", channelKey("BBCOne.uk", "BBC One", &buf));
    try testing.expectEqualStrings("name:bbcone", channelKey("", "BBC One HD", &buf));
    try testing.expectEqualStrings("", channelKey("", "!!", &buf));
}

test "matchChannel: mapping beats tvg-id beats name" {
    var chans: [3]GuideChannel = undefined;
    var progs: [4]Programme = undefined;
    const r = parse(SAMPLE, 1_800_000_000, &chans, &progs);
    const cs = chans[0..r.channels];
    // Explicit mapping wins, even over a matching tvg-id.
    const m1 = matchChannel("BBCOne.uk", "BBC One", "news.example", cs, &.{});
    try testing.expectEqual(MatchKind.mapped, m1.kind);
    try testing.expectEqualStrings("news.example", m1.guide_id);
    // tvg-id match is case-insensitive.
    const m2 = matchChannel("bbcone.UK", "Whatever", "", cs, &.{});
    try testing.expectEqual(MatchKind.tvg_id, m2.kind);
    // Feed suffix stem.
    const m3 = matchChannel("BBCOne.uk@SD", "", "", cs, &.{});
    try testing.expectEqual(MatchKind.id_stem, m3.kind);
    try testing.expectEqualStrings("BBCOne.uk", m3.guide_id);
    // Name match ignores "HD" and punctuation.
    const m4 = matchChannel("", "bbc one", "", cs, &.{});
    try testing.expectEqual(MatchKind.name, m4.kind);
    try testing.expectEqualStrings("BBCOne.uk", m4.guide_id);
    const m5 = matchChannel("", "Example & News HD", "", cs, &.{});
    try testing.expectEqualStrings("news.example", m5.guide_id);
    // No match.
    try testing.expectEqual(MatchKind.none, matchChannel("", "Unknown TV", "", cs, &.{}).kind);
    // tvg-id with programmes but no <channel> element.
    var only = [_]Programme{testProg("ghost.id", "Show", "20261101100000", "20261101110000")};
    try testing.expectEqual(MatchKind.tvg_id, matchChannel("GHOST.id", "", "", &.{}, &only).kind);
}

test "searchProgrammes: title hits first, then earliest, ended shows excluded" {
    var progs = [_]Programme{
        testProg("a", "Evening News", "20261101200000", "20261101210000"),
        testProg("b", "Morning News", "20261101080000", "20261101090000"),
        testProg("c", "Old News", "20261101050000", "20261101060000"),
        testProg("d", "Film", "20261101190000", "20261101210000"),
        testProg("e", "news at ten", "20261101220000", "20261101223000"),
    };
    @memcpy(progs[3].desc[0..13], "Then the news");
    progs[3].desc_len = 13;
    var out: [3]usize = undefined;
    const now = parseXmltvTime("20261101070000").?;
    const n = searchProgrammes(&progs, "NEWS", now, &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("Morning News", progs[out[0]].titleSlice());
    try testing.expectEqualStrings("Evening News", progs[out[1]].titleSlice());
    try testing.expectEqualStrings("news at ten", progs[out[2]].titleSlice()); // title hit beats desc-only Film
    try testing.expectEqual(@as(usize, 0), searchProgrammes(&progs, "  ", now, &out));
}

test "freshness: empty, fresh, stale by age, stale by coverage, expired" {
    const now: i64 = 1_800_000_000;
    try testing.expectEqual(Freshness.empty, freshness(0, now + 99999, now, now));
    try testing.expectEqual(Freshness.fresh, freshness(10, now + 24 * 3600, now - 3600, now));
    try testing.expectEqual(Freshness.stale, freshness(10, now + 24 * 3600, now - 25 * 3600, now));
    try testing.expectEqual(Freshness.stale, freshness(10, now + 2 * 3600, now - 60, now));
    try testing.expectEqual(Freshness.expired, freshness(10, now - 1, now - 60, now));
}

test "classifySource: urls, files, and refusals" {
    try testing.expectEqual(SourceKind.url, classifySource("https://epg.example/guide.xml.gz"));
    try testing.expectEqual(SourceKind.url, classifySource(" http://10.0.0.2/xmltv.xml "));
    try testing.expectEqual(SourceKind.file, classifySource("/Users/me/guide.xml"));
    try testing.expectEqual(SourceKind.file, classifySource("~/Downloads/guide.xml"));
    try testing.expectEqual(SourceKind.file, classifySource("file:///tmp/guide.xml"));
    try testing.expectEqual(SourceKind.file, classifySource("C:\\tv\\guide.xml"));
    try testing.expectEqualStrings("/tmp/guide.xml", filePath("file:///tmp/guide.xml"));
    for ([_][]const u8{ "", "guide.xml", "ftp://x/y", "javascript:alert(1)", "https://", "file://relative", "/tmp/a\nb", "data:text/xml,<tv/>" }) |bad| {
        try testing.expectEqual(SourceKind.invalid, classifySource(bad));
    }
}

test "redactSource never exposes credentials or full local paths" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("http://iptv.example:8080/xmltv.php?…", redactSource("http://iptv.example:8080/xmltv.php?username=bob&password=hunter2", &buf));
    try testing.expectEqualStrings("https://epg.example/guide.xml.gz", redactSource("https://user:pw@epg.example/guide.xml.gz", &buf));
    try testing.expectEqualStrings("file: guide.xml", redactSource("/Users/me/Private/guide.xml", &buf));
    try testing.expectEqualStrings("", redactSource("javascript:alert(1)", &buf));
}

test "isGzip / looksLikeXmltv sniff the body" {
    try testing.expect(isGzip("\x1f\x8b\x08\x00"));
    try testing.expect(!isGzip("<tv>"));
    try testing.expect(looksLikeXmltv("<?xml version=\"1.0\"?>\n<tv>"));
    try testing.expect(!looksLikeXmltv("<html><body>404</body></html>"));
}

test "gunzipBounded inflates a .xml.gz guide and refuses a bomb past the cap" {
    const gz = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xb3\x29\x29\xb3\xb3\x49\xce\x48\xcc\xcb\x4b\xcd\x51\xc8\x4c\xb1\x55\x4a\x54\xb2\xb3\x49\xc9\x2c\x2e\xc8\x49\xac\xd4\xcd\x4b\xcc\x4d\xb5\x73\xb4\xd1\x47\xe1\xdb\xe8\x43\x95\x03\x59\x40\xcd\x00\x1e\x2b\x2b\xb2\x41\x00\x00\x00";
    try testing.expect(isGzip(gz));
    const xml = try gunzipBounded(testing.allocator, gz, 1024);
    defer testing.allocator.free(xml);
    try testing.expectEqualStrings("<tv><channel id=\"a\"><display-name>A</display-name></channel></tv>", xml);
    // 200 KB of zeros in a 229-byte stream: a cap of 64 KB must refuse it.
    var bomb: [229]u8 = @splat(0);
    const head = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xed\xc1\x31\x01\x00\x00\x00\xc2\xa0\xf5\x4f\x6d\x06\x7f\xa0";
    @memcpy(bomb[0..head.len], head);
    const tail = "\x80\xd7\x00\x7b\x58\xe0\x5c\x40\x0d\x03\x00";
    @memcpy(bomb[bomb.len - tail.len ..], tail);
    try testing.expectError(error.StreamTooLong, gunzipBounded(testing.allocator, &bomb, 64 * 1024));
    const ok = try gunzipBounded(testing.allocator, &bomb, 256 * 1024);
    defer testing.allocator.free(ok);
    try testing.expectEqual(@as(usize, 200000), ok.len);
    // Truncated stream: an error, not a panic.
    try testing.expect(std.meta.isError(gunzipBounded(testing.allocator, gz[0..30], 1024)));
}

test "scrubUtf8 replaces invalid sequences so guide text is always valid UTF-8" {
    var buf = "ok\xc3 \xff\xe2\x82\xac".*;
    scrubUtf8(&buf);
    try testing.expectEqualStrings("ok? ?\u{20ac}", &buf);
}

test "progress clamps to 0..1" {
    try testing.expectEqual(@as(f32, 0), progress(100, 200, 50));
    try testing.expectEqual(@as(f32, 0.5), progress(100, 200, 150));
    try testing.expectEqual(@as(f32, 1), progress(100, 200, 250));
    try testing.expectEqual(@as(f32, 0), progress(200, 100, 150));
}
