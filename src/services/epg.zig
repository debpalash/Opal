//! Live TV programme guide — opt-in XMLTV import, held in bounded memory.
//!
//! The user points the guide at an XMLTV URL (`.xml` or `.xml.gz`) or a local
//! file; nothing is fetched until they do. A worker downloads or reads it,
//! inflates it under a byte cap, and parses it through epg_pure (all parsing,
//! time maths, matching and the stale verdict live there, unit-tested). The
//! parsed guide is two fixed-capacity heap arrays swapped in under `mutex`.
//!
//! Persistence: the source string and per-channel mapping overrides live in
//! SQLite (`iptv_epg_meta`, `iptv_epg_map`); the raw guide body is a disposable
//! cache file, re-parsed on launch and again as the kept window rolls forward
//! (a huge guide only keeps a few hours at a time — see epg_pure.parse).
//!
//! Threads: `tick()` and every reader run on the UI or remote-API thread and
//! only take `mutex` for short copies. The worker never holds it while doing
//! I/O or parsing.

const std = @import("std");
const pure = @import("epg_pure.zig");
const ipure = @import("iptv_pure.zig");
const db = @import("../core/db.zig");
const io = @import("../core/io_global.zig");
const paths = @import("../core/paths.zig");
const logs = @import("../core/logs.zig");
const workers = @import("../core/workers.zig");
const rate_limit = @import("../core/rate_limit.zig");
const reliable_fetch = @import("reliable_fetch.zig");
const alloc = @import("../core/alloc.zig").allocator;

const CACHE_NAME = "epg-guide.xmltv";
const TICK_INTERVAL_S: i64 = 60;

var mutex: @import("../core/sync.zig").Mutex = .{};
var channels: []pure.GuideChannel = &.{};
var programmes: []pure.Programme = &.{};
var chan_count: usize = 0;
var prog_count: usize = 0;
var latest_stop: i64 = 0;
var window_end: i64 = 0;
var horizon_s: i64 = 0;
var fetched_at: i64 = 0;
var malformed: usize = 0;
var dropped: usize = 0;
var err_buf: [160]u8 = undefined;
var err_len: usize = 0;

var importing: std.atomic.Value(bool) = .init(false);
/// Bumped on every publish so UI caches can tell the guide changed.
var generation: std.atomic.Value(u32) = .init(0);
var last_tick: std.atomic.Value(i64) = .init(0);
var attempted_load: std.atomic.Value(bool) = .init(false);

// ── Source + metadata (iptv_epg_meta) ──

fn metaGet(key: []const u8, out: []u8) []const u8 {
    const stmt = db.prepare("SELECT value FROM iptv_epg_meta WHERE key=?1") orelse return out[0..0];
    defer db.finalize(stmt);
    db.bindText(stmt, 1, key);
    if (db.step(stmt) != db.c.SQLITE_ROW) return out[0..0];
    var n: usize = 0;
    db.copyColumn(stmt, 0, out, &n);
    return out[0..n];
}

fn metaSet(key: []const u8, value: []const u8) void {
    const stmt = db.prepare("INSERT OR REPLACE INTO iptv_epg_meta(key,value) VALUES(?1,?2)") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, key);
    db.bindText(stmt, 2, value);
    _ = db.step(stmt);
}

fn metaDelete(key: []const u8) void {
    const stmt = db.prepare("DELETE FROM iptv_epg_meta WHERE key=?1") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, key);
    _ = db.step(stmt);
}

/// The configured guide source ("" = guide off).
pub fn sourceText(out: []u8) []const u8 {
    return metaGet("source", out);
}

pub fn isEnabled() bool {
    var buf: [1024]u8 = undefined;
    return sourceText(&buf).len > 0;
}

fn setError(msg: []const u8) void {
    mutex.lock();
    defer mutex.unlock();
    err_len = @min(msg.len, err_buf.len);
    @memcpy(err_buf[0..err_len], msg[0..err_len]);
}

// ── Import / refresh / clear ──

pub const ImportError = error{ InvalidSource, Busy, SpawnFailed };

const Mode = enum { network, cache };

/// Opt in to (or replace) the guide source and start importing it.
pub fn importSource(text: []const u8) ImportError!void {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (pure.classifySource(trimmed) == .invalid) return error.InvalidSource;
    if (importing.load(.acquire)) return error.Busy;
    metaSet("source", trimmed);
    metaDelete("fetched_at");
    var cache_buf: [512]u8 = undefined;
    io.deleteFileAbsolute(paths.cacheFile(&cache_buf, CACHE_NAME)) catch {};
    try spawnWorker(.network);
}

/// Re-download (URL) or re-read (file) the configured guide.
pub fn refresh() ImportError!void {
    if (!isEnabled()) return error.InvalidSource;
    if (importing.load(.acquire)) return error.Busy;
    try spawnWorker(.network);
}

/// Opt out: forget the source, the cached body and the parsed guide. Channel
/// mappings are kept (they are the user's work and apply to the next guide).
pub fn clearGuide() void {
    metaDelete("source");
    metaDelete("fetched_at");
    var cache_buf: [512]u8 = undefined;
    io.deleteFileAbsolute(paths.cacheFile(&cache_buf, CACHE_NAME)) catch {};
    mutex.lock();
    const old_c = channels;
    const old_p = programmes;
    channels = &.{};
    programmes = &.{};
    chan_count = 0;
    prog_count = 0;
    latest_stop = 0;
    window_end = 0;
    fetched_at = 0;
    err_len = 0;
    mutex.unlock();
    if (old_c.len > 0) alloc.free(old_c);
    if (old_p.len > 0) alloc.free(old_p);
    _ = generation.fetchAdd(1, .release);
    logs.pushLog("info", "epg", "Programme guide removed", false);
}

fn spawnWorker(mode: Mode) ImportError!void {
    if (importing.swap(true, .acq_rel)) return error.Busy;
    workers.spawn(importWorker, .{mode}) catch {
        importing.store(false, .release);
        return error.SpawnFailed;
    };
}

/// Lazy upkeep, cheap enough to call every frame (one atomic load between
/// minutes): first load from the cache, roll the kept window forward, and
/// re-download a URL guide once its copy passes REFRESH_TTL_S.
pub fn tick() void {
    const now = io.timestamp();
    if (now - last_tick.load(.acquire) < TICK_INTERVAL_S and attempted_load.load(.acquire)) return;
    last_tick.store(now, .release);
    if (importing.load(.acquire) or !isEnabled()) return;
    if (!attempted_load.swap(true, .acq_rel)) {
        spawnWorker(.cache) catch {};
        return;
    }
    mutex.lock();
    const roll = prog_count > 0 and horizon_s < pure.KEEP_AHEAD_S and now > window_end - 1800;
    const fa = fetched_at;
    mutex.unlock();
    var src_buf: [1024]u8 = undefined;
    const is_url = pure.classifySource(sourceText(&src_buf)) == .url;
    if (is_url and fa > 0 and now - fa > pure.REFRESH_TTL_S) {
        spawnWorker(.network) catch {};
    } else if (roll) {
        spawnWorker(.cache) catch {};
    }
}

fn importWorker(mode: Mode) void {
    defer importing.store(false, .release);
    var src_buf: [1024]u8 = undefined;
    const src = sourceText(&src_buf);
    const kind = pure.classifySource(src);
    if (kind == .invalid) return;

    var body: ?[]u8 = null;
    defer if (body) |b| alloc.free(b);
    var stamp: i64 = io.timestamp();
    var fa_buf: [24]u8 = undefined;
    const stored_fa = std.fmt.parseInt(i64, metaGet("fetched_at", &fa_buf), 10) catch 0;

    var cache_buf: [512]u8 = undefined;
    const cache_path = paths.cacheFile(&cache_buf, CACHE_NAME);
    if (kind == .url and mode == .cache) {
        if (io.cwdReadFileAlloc(cache_path, alloc, pure.MAX_FETCH_BYTES)) |b| {
            body = b;
            stamp = stored_fa;
        } else |_| {}
    }
    if (body == null and kind == .url) {
        body = download(src) orelse {
            setError("Could not download the guide");
            logs.pushLog("warn", "epg", "Programme guide download failed", true);
            return;
        };
        paths.ensureCacheDir();
        var tmp_buf: [520]u8 = undefined;
        if (std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{cache_path})) |tmp| {
            if (io.cwdWriteFile(.{ .sub_path = tmp, .data = body.? })) |_| {
                io.renameAbsolute(tmp, cache_path) catch io.deleteFileAbsolute(tmp) catch {};
            } else |_| {}
        } else |_| {}
    }
    if (kind == .file) {
        var path_buf: [1100]u8 = undefined;
        const path = expandHome(pure.filePath(src), &path_buf) orelse {
            setError("Guide file path is too long");
            return;
        };
        body = io.cwdReadFileAlloc(path, alloc, pure.MAX_FETCH_BYTES) catch {
            setError("Could not read the guide file");
            logs.pushLog("warn", "epg", "Programme guide file unreadable", true);
            return;
        };
        if (mode == .cache and stored_fa > 0) stamp = stored_fa;
    }

    var xml: []const u8 = body.?;
    var inflated: ?[]u8 = null;
    defer if (inflated) |b| alloc.free(b);
    if (pure.isGzip(xml)) {
        inflated = pure.gunzipBounded(alloc, xml, pure.MAX_XML_BYTES) catch {
            setError("Guide archive is corrupt or too large");
            return;
        };
        xml = inflated.?;
    }
    if (!pure.looksLikeXmltv(xml)) {
        setError("That is not an XMLTV guide");
        return;
    }

    const new_c = alloc.alloc(pure.GuideChannel, pure.MAX_CHANNELS) catch {
        setError("Out of memory for the guide");
        return;
    };
    const new_p = alloc.alloc(pure.Programme, pure.MAX_PROGRAMMES) catch {
        alloc.free(new_c);
        setError("Out of memory for the guide");
        return;
    };
    const now = io.timestamp();
    const res = pure.parse(xml, now, new_c, new_p);
    pure.sortProgrammes(new_p[0..res.programmes]);
    if (res.programmes == 0 and res.channels == 0) {
        alloc.free(new_c);
        alloc.free(new_p);
        setError("The guide has no channels or programmes");
        return;
    }
    if (mode == .network) {
        var num_buf: [24]u8 = undefined;
        metaSet("fetched_at", std.fmt.bufPrint(&num_buf, "{d}", .{stamp}) catch "0");
    }

    mutex.lock();
    const old_c = channels;
    const old_p = programmes;
    channels = new_c;
    programmes = new_p;
    chan_count = res.channels;
    prog_count = res.programmes;
    latest_stop = res.latest_stop;
    window_end = res.window_end;
    horizon_s = res.horizon_s;
    fetched_at = if (stamp > 0) stamp else now;
    malformed = res.malformed;
    dropped = res.dropped;
    err_len = 0;
    mutex.unlock();
    if (old_c.len > 0) alloc.free(old_c);
    if (old_p.len > 0) alloc.free(old_p);
    _ = generation.fetchAdd(1, .release);

    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Programme guide loaded: {d} channels, {d} programmes", .{ res.channels, res.programmes }) catch "Programme guide loaded";
    logs.pushLog("info", "epg", msg, false);
    @import("../core/state.zig").wakeUi();
}

fn download(url: []const u8) ?[]u8 {
    rate_limit.acquire("epg", 0.2);
    const buf = alloc.alloc(u8, pure.MAX_FETCH_BYTES) catch return null;
    const got = reliable_fetch.fetch(url, buf, .{
        .user_agent = @import("../core/app_meta.zig").user_agent,
        .timeout_secs = 90,
        .impersonate = false,
    }) orelse {
        alloc.free(buf);
        return null;
    };
    if (got.len == 0) {
        alloc.free(buf);
        return null;
    }
    return alloc.realloc(buf, got.len) catch {
        alloc.free(buf);
        return null;
    };
}

fn expandHome(path: []const u8, out: []u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, "~/")) {
        if (path.len > out.len) return null;
        @memcpy(out[0..path.len], path);
        return out[0..path.len];
    }
    const home = paths.homeDir();
    return std.fmt.bufPrint(out, "{s}{s}", .{ home, path[1..] }) catch null;
}

// ── Status ──

pub const Status = struct {
    enabled: bool = false,
    importing: bool = false,
    channels: usize = 0,
    programmes: usize = 0,
    malformed: usize = 0,
    dropped: usize = 0,
    fetched_at: i64 = 0,
    latest_stop: i64 = 0,
    window_end: i64 = 0,
    freshness: pure.Freshness = .empty,
    err: [160]u8 = undefined,
    err_len: usize = 0,

    pub fn errSlice(self: *const Status) []const u8 {
        return self.err[0..self.err_len];
    }
};

pub fn status() Status {
    var s: Status = .{ .enabled = isEnabled(), .importing = importing.load(.acquire) };
    const now = io.timestamp();
    mutex.lock();
    defer mutex.unlock();
    s.channels = chan_count;
    s.programmes = prog_count;
    s.malformed = malformed;
    s.dropped = dropped;
    s.fetched_at = fetched_at;
    s.latest_stop = latest_stop;
    s.window_end = window_end;
    s.freshness = pure.freshness(prog_count, latest_stop, fetched_at, now);
    s.err_len = err_len;
    @memcpy(s.err[0..err_len], err_buf[0..err_len]);
    return s;
}

pub fn currentGeneration() u32 {
    return generation.load(.acquire);
}

// ── Channel mapping overrides (iptv_epg_map) ──

pub const MAX_MAPPINGS: usize = 256;

pub const Mapping = struct {
    key: [100]u8 = undefined,
    key_len: usize = 0,
    guide: [64]u8 = undefined,
    guide_len: usize = 0,
    label: [96]u8 = undefined,
    label_len: usize = 0,

    pub fn keySlice(self: *const Mapping) []const u8 {
        return self.key[0..self.key_len];
    }
    pub fn guideSlice(self: *const Mapping) []const u8 {
        return self.guide[0..self.guide_len];
    }
    pub fn labelSlice(self: *const Mapping) []const u8 {
        return self.label[0..self.label_len];
    }
};

var maps: [MAX_MAPPINGS]Mapping = undefined;
var map_count: usize = 0;
var maps_loaded = false;

/// Caller holds `mutex`.
fn ensureMapsLocked() void {
    if (maps_loaded) return;
    maps_loaded = true;
    map_count = 0;
    const stmt = db.prepare("SELECT chan_key, guide_id, label FROM iptv_epg_map ORDER BY ts DESC LIMIT 256") orelse return;
    defer db.finalize(stmt);
    while (map_count < MAX_MAPPINGS and db.step(stmt) == db.c.SQLITE_ROW) {
        const m = &maps[map_count];
        m.* = .{};
        db.copyColumn(stmt, 0, &m.key, &m.key_len);
        db.copyColumn(stmt, 1, &m.guide, &m.guide_len);
        db.copyColumn(stmt, 2, &m.label, &m.label_len);
        map_count += 1;
    }
}

fn overrideLocked(key: []const u8) []const u8 {
    if (key.len == 0) return "";
    for (maps[0..map_count]) |*m| {
        if (std.mem.eql(u8, m.keySlice(), key)) return m.guideSlice();
    }
    return "";
}

/// Map a playlist channel to guide channel `guide_id` ("" removes the
/// override). `chan_id`/`name` identify the channel exactly as the guide
/// matcher sees it; `label` is shown in the mapping list. False when the
/// channel has no usable key or the override table is full.
pub fn setMapping(chan_id: []const u8, name: []const u8, guide_id: []const u8, label: []const u8) bool {
    var key_buf: [100]u8 = undefined;
    const key = pure.channelKey(chan_id, name, &key_buf);
    if (key.len == 0) return false;
    const gid = std.mem.trim(u8, guide_id, " \t");
    if (gid.len > 64) return false;
    for (gid) |c| if (c < 0x20 or c == 0x7f) return false;
    mutex.lock();
    defer mutex.unlock();
    ensureMapsLocked();
    if (gid.len == 0) {
        const stmt = db.prepare("DELETE FROM iptv_epg_map WHERE chan_key=?1") orelse return false;
        defer db.finalize(stmt);
        db.bindText(stmt, 1, key);
        _ = db.step(stmt);
    } else {
        if (map_count >= MAX_MAPPINGS and overrideLocked(key).len == 0) return false;
        const stmt = db.prepare("INSERT OR REPLACE INTO iptv_epg_map(chan_key,guide_id,label,ts) VALUES(?1,?2,?3,strftime('%s','now'))") orelse return false;
        defer db.finalize(stmt);
        db.bindText(stmt, 1, key);
        db.bindText(stmt, 2, gid);
        db.bindText(stmt, 3, pure.utf8Prefix(label, 96));
        if (db.step(stmt) != db.c.SQLITE_DONE) return false;
    }
    maps_loaded = false;
    ensureMapsLocked();
    _ = generation.fetchAdd(1, .release);
    return true;
}

/// Remove an override by its stored key (from `mappings`).
pub fn removeMappingKey(key: []const u8) bool {
    mutex.lock();
    defer mutex.unlock();
    const stmt = db.prepare("DELETE FROM iptv_epg_map WHERE chan_key=?1") orelse return false;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, key);
    const ok = db.step(stmt) == db.c.SQLITE_DONE;
    maps_loaded = false;
    ensureMapsLocked();
    _ = generation.fetchAdd(1, .release);
    return ok;
}

/// Snapshot of the user's overrides, newest first.
pub fn mappings(out: []Mapping) usize {
    mutex.lock();
    defer mutex.unlock();
    ensureMapsLocked();
    const n = @min(out.len, map_count);
    @memcpy(out[0..n], maps[0..n]);
    return n;
}

// ── Queries ──

pub const Slot = struct {
    title: [128]u8 = undefined,
    title_len: usize = 0,
    start: i64 = 0,
    stop: i64 = 0,

    pub fn titleSlice(self: *const Slot) []const u8 {
        return self.title[0..self.title_len];
    }
};

pub const NowNextInfo = struct {
    guide_id: [64]u8 = undefined,
    guide_id_len: usize = 0,
    match: pure.MatchKind = .none,
    now: ?Slot = null,
    next: ?Slot = null,

    pub fn guideIdSlice(self: *const NowNextInfo) []const u8 {
        return self.guide_id[0..self.guide_id_len];
    }
};

fn slotOf(p: *const pure.Programme) Slot {
    var s: Slot = .{ .start = p.start, .stop = p.stop };
    s.title_len = p.title_len;
    @memcpy(s.title[0..s.title_len], p.title[0..s.title_len]);
    return s;
}

/// Caller holds `mutex`. The override lookup tries the tvg-id key, then the
/// name key, so a mapping saved by typing a channel's name also applies to
/// rows that carry a tvg-id.
fn resolveLocked(chan_id: []const u8, name: []const u8) pure.Match {
    ensureMapsLocked();
    var kb1: [100]u8 = undefined;
    var kb2: [100]u8 = undefined;
    var override = overrideLocked(pure.channelKey(chan_id, name, &kb1));
    if (override.len == 0 and chan_id.len > 0) override = overrideLocked(pure.channelKey("", name, &kb2));
    return pure.matchChannel(chan_id, name, override, channels[0..chan_count], programmes[0..prog_count]);
}

/// Now/next for a playlist channel, or null when the guide has nothing for it.
pub fn nowNext(chan_id: []const u8, name: []const u8, now: i64) ?NowNextInfo {
    mutex.lock();
    defer mutex.unlock();
    if (prog_count == 0) return null;
    const m = resolveLocked(chan_id, name);
    if (m.kind == .none) return null;
    const progs = programmes[0..prog_count];
    const nn = pure.nowNext(progs, pure.channelRange(progs, m.guide_id), now);
    var info: NowNextInfo = .{ .match = m.kind };
    info.guide_id_len = @min(m.guide_id.len, info.guide_id.len);
    @memcpy(info.guide_id[0..info.guide_id_len], m.guide_id[0..info.guide_id_len]);
    if (nn.now) |i| info.now = slotOf(&progs[i]);
    if (nn.next) |i| info.next = slotOf(&progs[i]);
    return info;
}

/// nowNext for a catalog row.
pub fn nowNextFor(ch: *const ipure.IptvChannel, now: i64) ?NowNextInfo {
    return nowNext(ch.chan_id[0..@min(ch.chan_id_len, ch.chan_id.len)], ch.name[0..@min(ch.name_len, ch.name.len)], now);
}

pub const Hit = struct {
    chan_id: [64]u8 = undefined,
    chan_id_len: usize = 0,
    chan_name: [96]u8 = undefined,
    chan_name_len: usize = 0,
    slot: Slot = .{},
    desc: [200]u8 = undefined,
    desc_len: usize = 0,

    pub fn chanIdSlice(self: *const Hit) []const u8 {
        return self.chan_id[0..self.chan_id_len];
    }
    pub fn chanNameSlice(self: *const Hit) []const u8 {
        return self.chan_name[0..self.chan_name_len];
    }
    pub fn descSlice(self: *const Hit) []const u8 {
        return self.desc[0..self.desc_len];
    }
};

fn channelNameLocked(id: []const u8) []const u8 {
    for (channels[0..chan_count]) |*c| {
        if (std.ascii.eqlIgnoreCase(c.idSlice(), id)) return c.nameSlice();
    }
    return id;
}

/// Programme search across the whole guide (title, then description).
pub fn search(query: []const u8, now: i64, out: []Hit) usize {
    var idx: [64]usize = undefined;
    mutex.lock();
    defer mutex.unlock();
    const progs = programmes[0..prog_count];
    const n = pure.searchProgrammes(progs, query, now, idx[0..@min(idx.len, out.len)]);
    for (idx[0..n], 0..) |pi, k| {
        const p = &progs[pi];
        const h = &out[k];
        h.* = .{ .slot = slotOf(p) };
        h.chan_id_len = p.chan_len;
        @memcpy(h.chan_id[0..h.chan_id_len], p.chan[0..p.chan_len]);
        const nm = channelNameLocked(p.chanSlice());
        h.chan_name_len = @min(nm.len, h.chan_name.len);
        @memcpy(h.chan_name[0..h.chan_name_len], nm[0..h.chan_name_len]);
        h.desc_len = p.desc_len;
        @memcpy(h.desc[0..h.desc_len], p.desc[0..p.desc_len]);
    }
    return n;
}

pub const ChannelHit = struct {
    id: [64]u8 = undefined,
    id_len: usize = 0,
    name: [96]u8 = undefined,
    name_len: usize = 0,

    pub fn idSlice(self: *const ChannelHit) []const u8 {
        return self.id[0..self.id_len];
    }
    pub fn nameSlice(self: *const ChannelHit) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Guide channels whose id or display name contains `query` — mapping
/// suggestions.
pub fn guideChannels(query: []const u8, out: []ChannelHit) usize {
    const q = std.mem.trim(u8, query, " \t");
    mutex.lock();
    defer mutex.unlock();
    var n: usize = 0;
    for (channels[0..chan_count]) |*c| {
        if (n >= out.len) break;
        if (!pure.containsFold(c.nameSlice(), q) and !pure.containsFold(c.idSlice(), q)) continue;
        out[n] = .{ .id_len = c.id_len, .name_len = c.name_len };
        @memcpy(out[n].id[0..c.id_len], c.id[0..c.id_len]);
        @memcpy(out[n].name[0..c.name_len], c.name[0..c.name_len]);
        n += 1;
    }
    return n;
}

// ── Local time (DST-aware, per instant) ──

const OffsetCache = struct { hour: i64 = std.math.minInt(i64), offset: i64 = 0 };
var offset_cache: [16]OffsetCache = @splat(.{});
var offset_mutex: @import("../core/sync.zig").Mutex = .{};

/// The viewer's UTC offset at `utc` — asked of SQLite's localtime per instant
/// (Zig's std.time is UTC-only), so a programme after tonight's DST change is
/// shown in the post-change offset. Cached per hour.
pub fn localOffsetAt(utc: i64) i64 {
    const hour = @divFloor(utc, 3600);
    const slot = &offset_cache[@intCast(@mod(hour, offset_cache.len))];
    offset_mutex.lock();
    if (slot.hour == hour) {
        const o = slot.offset;
        offset_mutex.unlock();
        return o;
    }
    offset_mutex.unlock();
    var off: i64 = 0;
    if (db.prepare("SELECT CAST(strftime('%s', ?1, 'unixepoch', 'localtime') AS INTEGER) - ?1")) |stmt| {
        defer db.finalize(stmt);
        db.bindInt64(stmt, 1, utc);
        if (db.step(stmt) == db.c.SQLITE_ROW) off = db.columnInt64(stmt, 0);
    }
    offset_mutex.lock();
    slot.* = .{ .hour = hour, .offset = off };
    offset_mutex.unlock();
    return off;
}

/// "21:00" in the viewer's local time.
pub fn clock(utc: i64, out: []u8) []const u8 {
    return pure.formatClock(utc, localOffsetAt(utc), out);
}

/// "Today 21:00" / "Tomorrow 06:30" / "Tue 20:00" in local time.
pub fn dayClock(utc: i64, now: i64, out: []u8) []const u8 {
    return pure.formatDayClock(utc, localOffsetAt(utc), now, localOffsetAt(now), out);
}

/// Free the parsed guide at shutdown (leak check).
pub fn deinit() void {
    mutex.lock();
    const old_c = channels;
    const old_p = programmes;
    channels = &.{};
    programmes = &.{};
    chan_count = 0;
    prog_count = 0;
    mutex.unlock();
    if (old_c.len > 0) alloc.free(old_c);
    if (old_p.len > 0) alloc.free(old_p);
}
