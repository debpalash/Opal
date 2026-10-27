const std = @import("std");
const builtin = @import("builtin");
const state = @import("../core/state.zig");
const db = @import("../core/db.zig");
const logs = @import("../core/logs.zig");
const sync = @import("../core/sync.zig");
const alloc = @import("../core/alloc.zig").allocator;
const io = @import("../core/io_global.zig");
const bounded_process = @import("../core/bounded_process.zig");
const workers = @import("../core/workers.zig");
const c = @import("../core/c.zig");
const fp = @import("fingerprint_pure.zig");
const mm = @import("marker_match_pure.zig");
const mp = @import("markers_pure.zig");
const policy = @import("skip_policy_pure.zig");
const skip_segments = @import("skip_segments.zig");
const anime_pure = @import("anime_skip_pure.zig");

// ══════════════════════════════════════════════════════════════════════════
// Media markers — "Skip intro" / "Skip credits" for ANY series, computed
// locally.
//
// On every FILE_LOADED (owner thread):
//   • chapter titles ("Opening", "ED", "Credits", "Preview", …) become skip
//     segments instantly — local files and streams alike;
//   • a local file is handed to ONE background worker, which looks up stored
//     markers (media_markers, keyed by path+size+mtime) and otherwise — when
//     the folder holds sibling episodes of the same show/season — extracts
//     the audio head (~10 min) and tail (~6 min) of up to 4 episodes with a
//     low-priority, bounded ffmpeg, fingerprints them (cached in
//     media_fingerprints), aligns them (marker_match_pure.detect) and stores
//     intro/credits markers for EVERY episode it processed, so the siblings
//     are instant later.
//
// Results are published into skip_segments.zig tagged with the load's
// generation; a result for a file that is no longer playing is still stored
// but never shown.
// ══════════════════════════════════════════════════════════════════════════

const METHOD_FP = "fingerprint";
const MAX_CHAPTERS = 64;
const MAX_NAMES = 512;
const NAME_CAP = 256;
const PATH_CAP = 1024;
const MAX_EPS = 4; // target + 3 siblings
const EXTRACT_TIMEOUT_MS: i64 = 180_000;

// ── Owner-thread entry ─────────────────────────────────────────────────────

/// Called from the mpv event pump on MPV_EVENT_FILE_LOADED.
pub fn onFileLoaded(p: anytype) void {
    const gen = skip_segments.reset(@intFromPtr(p));
    if (policy.modeFromInt(state.app.skip_mode) == .off) return;

    var duration: f64 = 0;
    _ = c.mpv.mpv_get_property(p.mpv_ctx, "duration", c.mpv.MPV_FORMAT_DOUBLE, &duration);
    publishChapters(p, gen, duration);

    const path_c = c.mpv.mpv_get_property_string(p.mpv_ctx, "path");
    if (path_c == null) return;
    defer c.mpv.mpv_free(@ptrCast(path_c));
    var path: []const u8 = std.mem.span(path_c);
    if (std.mem.startsWith(u8, path, "file://")) path = path["file://".len..];
    if (!isLocalAbsolute(path) or path.len > PATH_CAP) return;
    Worker.submit(path, gen);
}

fn isLocalAbsolute(path: []const u8) bool {
    if (std.mem.indexOf(u8, path, "://") != null) return false;
    if (path.len > 0 and path[0] == '/') return true;
    return builtin.os.tag == .windows and path.len >= 3 and path[1] == ':' and (path[2] == '\\' or path[2] == '/');
}

fn publishChapters(p: anytype, gen: u64, duration: f64) void {
    var count: i64 = 0;
    _ = c.mpv.mpv_get_property(p.mpv_ctx, "chapter-list/count", c.mpv.MPV_FORMAT_INT64, &count);
    if (count <= 0) return;
    const n: usize = @intCast(@min(count, MAX_CHAPTERS));
    var titles: [MAX_CHAPTERS][96]u8 = undefined;
    var chapters: [MAX_CHAPTERS]mm.Chapter = undefined;
    for (0..n) |i| {
        var q: [48]u8 = undefined;
        var t: f64 = 0;
        const tq = std.fmt.bufPrintZ(&q, "chapter-list/{d}/time", .{i}) catch return;
        _ = c.mpv.mpv_get_property(p.mpv_ctx, tq.ptr, c.mpv.MPV_FORMAT_DOUBLE, &t);
        var tl: usize = 0;
        const nq = std.fmt.bufPrintZ(&q, "chapter-list/{d}/title", .{i}) catch return;
        const title_c = c.mpv.mpv_get_property_string(p.mpv_ctx, nq.ptr);
        if (title_c != null) {
            const s = std.mem.span(title_c);
            tl = @min(s.len, titles[i].len);
            @memcpy(titles[i][0..tl], s[0..tl]);
            c.mpv.mpv_free(@ptrCast(title_c));
        }
        chapters[i] = .{ .start = t, .title = titles[i][0..tl] };
    }
    var raw: [policy.MAX_SEGS]anime_pure.Segment = undefined;
    const ns = mm.chapterSegments(chapters[0..n], duration, &raw);
    if (ns == 0) return;
    var segs: [policy.MAX_SEGS]policy.Seg = undefined;
    for (raw[0..ns], 0..) |s, i| segs[i] = .{ .start = s.start, .end = s.end, .category = s.category, .source = .chapters };
    if (skip_segments.publish(.chapters, gen, segs[0..ns])) {
        var b: [64]u8 = undefined;
        logs.pushLog("info", "markers", std.fmt.bufPrint(&b, "{d} skip segment(s) from chapters", .{ns}) catch "chapter markers", false);
    }
}

// ── Worker (single flight; the latest pending request wins) ────────────────

const Job = struct {
    path: [PATH_CAP]u8 = undefined,
    len: usize = 0,
    gen: u64 = 0,
};

const Worker = struct {
    var mutex: sync.Mutex = .{};
    var busy: bool = false; // under mutex
    var pending: Job = .{}; // under mutex
    var has_pending: bool = false; // under mutex

    fn submit(path: []const u8, gen: u64) void {
        @This().mutex.lock();
        @This().pending.len = @min(path.len, PATH_CAP);
        @memcpy(@This().pending.path[0..@This().pending.len], path[0..@This().pending.len]);
        @This().pending.gen = gen;
        @This().has_pending = true;
        if (@This().busy) {
            @This().mutex.unlock();
            return; // the running worker picks it up next
        }
        @This().busy = true;
        @This().mutex.unlock();
        if (workers.spawnLegacy(@This().run, .{})) |t| workers.release(t) else |_| {
            @This().mutex.lock();
            @This().busy = false;
            @This().has_pending = false;
            @This().mutex.unlock();
        }
    }

    fn run() void {
        const job = alloc.create(Job) catch {
            @This().mutex.lock();
            @This().busy = false;
            @This().mutex.unlock();
            return;
        };
        defer alloc.destroy(job);
        while (!workers.isQuitting()) {
            @This().mutex.lock();
            if (!@This().has_pending) break; // unlocked below
            job.* = @This().pending;
            @This().has_pending = false;
            @This().mutex.unlock();
            process(job.path[0..job.len], job.gen);
        } else @This().mutex.lock();
        @This().busy = false;
        @This().mutex.unlock();
    }
};

// ── Per-episode data (heap) ────────────────────────────────────────────────

const Ep = struct {
    path: [PATH_CAP]u8 = undefined,
    path_len: usize = 0,
    size: u64 = 0,
    mtime: i64 = 0,
    duration: f64 = 0,
    tail_offset: f64 = 0,
    head: []u32 = &.{},
    tail: []u32 = &.{},

    fn pathSlice(self: *const Ep) []const u8 {
        return self.path[0..self.path_len];
    }

    fn deinit(self: *Ep) void {
        if (self.head.len > 0) alloc.free(self.head);
        if (self.tail.len > 0) alloc.free(self.tail);
        self.head = &.{};
        self.tail = &.{};
    }
};

const Names = struct {
    buf: [MAX_NAMES][NAME_CAP]u8 = undefined,
    lens: [MAX_NAMES]usize = undefined,
    slices: [MAX_NAMES][]const u8 = undefined,
    n: usize = 0,
};

fn statEp(path: []const u8, ep: *Ep) bool {
    const st = io.cwdStatFile(path) catch return false;
    ep.path_len = @min(path.len, PATH_CAP);
    @memcpy(ep.path[0..ep.path_len], path[0..ep.path_len]);
    ep.size = st.size;
    ep.mtime = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_s));
    return true;
}

fn dirName(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return "";
    return if (i == 0) path[0..1] else path[0..i];
}

fn listDir(dir_path: []const u8, names: *Names) void {
    names.n = 0;
    var dir = io.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io.io());
    var iter = dir.iterate();
    while (iter.next(io.io()) catch null) |entry| {
        if (names.n >= MAX_NAMES) break;
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (entry.name.len > NAME_CAP or !mp.isVideoName(entry.name)) continue;
        const i = names.n;
        @memcpy(names.buf[i][0..entry.name.len], entry.name);
        names.lens[i] = entry.name.len;
        names.slices[i] = names.buf[i][0..entry.name.len];
        names.n += 1;
    }
}

fn joinPath(dir: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    const sep: []const u8 = if (dir.len > 0 and (dir[dir.len - 1] == '/' or dir[dir.len - 1] == '\\')) "" else "/";
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ dir, sep, name }) catch null;
}

fn process(path: []const u8, gen: u64) void {
    const eps = alloc.alloc(Ep, MAX_EPS) catch return;
    defer {
        for (eps) |*e| e.deinit();
        alloc.free(eps);
    }
    for (eps) |*e| e.* = .{};
    if (!statEp(path, &eps[0])) return;

    var key_buf: [PATH_CAP + 64]u8 = undefined;
    const key = mp.mediaKey(eps[0].pathSlice(), eps[0].size, eps[0].mtime, &key_buf);
    if (key.len == 0) return;

    var stored: [8]policy.Seg = undefined;
    const n_stored = loadMarkers(key, &stored);
    if (n_stored > 0) _ = skip_segments.publish(.fingerprint, gen, stored[0..n_stored]);

    const names = alloc.create(Names) catch return;
    defer alloc.destroy(names);
    const dir = dirName(path);
    listDir(dir, names);
    const listed = names.slices[0..names.n];

    if (mp.nextEpisode(path, listed)) |ni| {
        var nb: [PATH_CAP]u8 = undefined;
        if (joinPath(dir, listed[ni], &nb)) |np| skip_segments.publishNextPath(gen, np);
    }
    if (n_stored > 0) return;

    var sib: [MAX_EPS - 1]usize = undefined;
    const n_sib = mp.selectSiblings(path, listed, &sib);
    if (n_sib == 0) return;

    var detected: [MAX_EPS]mm.Result = undefined;
    const n_eps = fingerprintAndDetect(eps, path, dir, listed, sib[0..n_sib], &detected) orelse return;
    if (workers.isQuitting()) return;

    // Store markers for every processed episode; publish the target's.
    for (0..n_eps) |i| {
        var kb: [PATH_CAP + 64]u8 = undefined;
        const k = mp.mediaKey(eps[i].pathSlice(), eps[i].size, eps[i].mtime, &kb);
        if (k.len > 0) storeMarkers(k, detected[i]);
    }
    var segs: [2]policy.Seg = undefined;
    const ns = resultSegs(detected[0], &segs);
    var lb: [160]u8 = undefined;
    logs.pushLog("info", "markers", std.fmt.bufPrint(&lb, "fingerprint: {d} episodes, intro={s} credits={s}", .{
        n_eps,
        if (detected[0].intro != null) "yes" else "no",
        if (detected[0].credits != null) "yes" else "no",
    }) catch "fingerprint done", false);
    if (ns > 0) _ = skip_segments.publish(.fingerprint, gen, segs[0..ns]);
}

/// Fingerprint target (eps[0], already stat'ed) + siblings, then detect.
/// Returns the number of episodes used (target first), or null.
fn fingerprintAndDetect(
    eps: []Ep,
    path: []const u8,
    dir: []const u8,
    listed: []const []const u8,
    sib: []const usize,
    out: *[MAX_EPS]mm.Result,
) ?usize {
    _ = path;
    const ffmpeg = @import("remote_stream.zig").ffmpegPath();
    if (ffmpeg.len == 0) {
        logs.pushLog("warn", "markers", "ffmpeg not found — intro detection disabled", false);
        return null;
    }
    const max_samples: usize = @intFromFloat(mm.HEAD_SECONDS * @as(f64, @floatFromInt(fp.SAMPLE_RATE)));
    const pcm = alloc.alloc(i16, max_samples + 32 * 1024) catch return null;
    defer alloc.free(pcm);
    const scratch = alloc.create(fp.Scratch) catch return null;
    defer alloc.destroy(scratch);
    scratch.* = .{};

    if (!loadOrComputePrints(&eps[0], ffmpeg, pcm, scratch)) return null;
    var n: usize = 1;
    for (sib) |si| {
        if (workers.isQuitting()) return null;
        var pb: [PATH_CAP]u8 = undefined;
        const sp = joinPath(dir, listed[si], &pb) orelse continue;
        if (!statEp(sp, &eps[n])) continue;
        if (!loadOrComputePrints(&eps[n], ffmpeg, pcm, scratch)) {
            eps[n].deinit();
            continue;
        }
        n += 1;
    }
    if (n < 2) return null;
    var inputs: [MAX_EPS]mm.Episode = undefined;
    for (0..n) |i| inputs[i] = .{
        .head = eps[i].head,
        .tail = eps[i].tail,
        .tail_offset_s = eps[i].tail_offset,
        .duration_s = eps[i].duration,
    };
    mm.detect(inputs[0..n], out[0..n]);
    return n;
}

fn resultSegs(r: mm.Result, out: *[2]policy.Seg) usize {
    var n: usize = 0;
    if (r.intro) |m| {
        out[n] = .{ .start = m.start, .end = m.end, .category = .intro, .confidence = m.confidence, .source = .fingerprint };
        n += 1;
    }
    if (r.credits) |m| {
        out[n] = .{ .start = m.start, .end = m.end, .category = .credits, .confidence = m.confidence, .source = .fingerprint };
        n += 1;
    }
    return n;
}

// ── Audio extraction + fingerprints ────────────────────────────────────────

fn ffprobePath(ffmpeg: []const u8, buf: []u8) []const u8 {
    if (std.mem.endsWith(u8, ffmpeg, "ffmpeg")) {
        return std.fmt.bufPrint(buf, "{s}ffprobe", .{ffmpeg[0 .. ffmpeg.len - "ffmpeg".len]}) catch "ffprobe";
    }
    return "ffprobe";
}

fn probeDuration(ffmpeg: []const u8, path: []const u8) f64 {
    var pb: [256]u8 = undefined;
    const argv = [_][]const u8{ ffprobePath(ffmpeg, &pb), "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", path };
    var out: [128]u8 = undefined;
    const r = bounded_process.run(&argv, &out, .{ .timeout_ms = 20_000 });
    if (!r.ok()) return 0;
    const txt = std.mem.trim(u8, r.output, " \r\n\t");
    const d = std.fmt.parseFloat(f64, txt) catch return 0;
    return if (std.math.isFinite(d) and d > 0) d else 0;
}

/// Decode mono s16le @ SAMPLE_RATE into `pcm`. `sseof` > 0 reads the last
/// `sseof` seconds; otherwise the first `secs`. Returns samples decoded.
fn extract(ffmpeg: []const u8, path: []const u8, sseof: f64, secs: f64, pcm_samples: []i16) ?usize {
    const pcm = std.mem.sliceAsBytes(pcm_samples);
    var nb: [32]u8 = undefined;
    var tb: [32]u8 = undefined;
    var rate_b: [16]u8 = undefined;
    const rate = std.fmt.bufPrint(&rate_b, "{d}", .{fp.SAMPLE_RATE}) catch return null;
    var argv_buf: [32][]const u8 = undefined;
    var n: usize = 0;
    // Low priority: this is background work competing with playback.
    if (builtin.os.tag != .windows) {
        if (io.cwdStatFile("/usr/bin/nice")) |_| {
            for ([_][]const u8{ "/usr/bin/nice", "-n", "19" }) |a| {
                argv_buf[n] = a;
                n += 1;
            }
        } else |_| {}
    }
    for ([_][]const u8{ ffmpeg, "-nostdin", "-v", "error", "-threads", "1" }) |a| {
        argv_buf[n] = a;
        n += 1;
    }
    if (sseof > 0) {
        argv_buf[n] = "-sseof";
        argv_buf[n + 1] = std.fmt.bufPrint(&nb, "-{d:.1}", .{sseof}) catch return null;
        n += 2;
    }
    for ([_][]const u8{ "-i", path, "-vn", "-sn", "-dn", "-ac", "1", "-ar", rate }) |a| {
        argv_buf[n] = a;
        n += 1;
    }
    if (sseof <= 0) {
        argv_buf[n] = "-t";
        argv_buf[n + 1] = std.fmt.bufPrint(&tb, "{d:.1}", .{secs}) catch return null;
        n += 2;
    }
    for ([_][]const u8{ "-f", "s16le", "-" }) |a| {
        argv_buf[n] = a;
        n += 1;
    }

    var proc = bounded_process.StreamProcess.init(argv_buf[0..n], .{
        .timeout_ms = EXTRACT_TIMEOUT_MS,
        .max_output_bytes = pcm.len,
        .cancel_flag = workers.quittingSignal(),
    });
    proc.start() catch return null;
    var total: usize = 0;
    if (proc.stdout()) |out| {
        while (total < pcm.len) {
            const got = io.read(out, pcm[total..]) catch break;
            if (got == 0) break;
            if (!proc.noteOutput(got)) break;
            total += got;
        }
    }
    const res = proc.finish();
    if (!res.ok() and !(res.output_limited and total >= pcm.len)) return null;
    return total / 2;
}

fn printsFromPcm(pcm: []const i16, samples: usize, scratch: *fp.Scratch) ?[]u32 {
    // ffmpeg emits little-endian s16; every supported target is little-endian.
    comptime std.debug.assert(builtin.cpu.arch.endian() == .little);
    const nf = fp.frameCount(samples);
    if (nf == 0) return null;
    const prints = alloc.alloc(u32, nf) catch return null;
    _ = fp.compute(pcm[0..samples], prints, scratch);
    return prints;
}

fn loadOrComputePrints(ep: *Ep, ffmpeg: []const u8, pcm: []i16, scratch: *fp.Scratch) bool {
    if (cacheGet(ep)) return true;
    const path = ep.pathSlice();
    const dur = probeDuration(ffmpeg, path);
    if (dur <= 0) return false;
    // Short episodes: keep head and tail apart so the credits theme can't
    // masquerade as a shared intro.
    const head_s = @min(mm.HEAD_SECONDS, dur * 0.45);
    const tail_s = @min(mm.TAIL_SECONDS, dur * 0.35);
    const sr: f64 = @floatFromInt(fp.SAMPLE_RATE);

    const hn = extract(ffmpeg, path, 0, head_s, pcm) orelse return false;
    ep.head = printsFromPcm(pcm, hn, scratch) orelse return false;
    if (workers.isQuitting()) return false;
    const tn = extract(ffmpeg, path, tail_s, 0, pcm) orelse return false;
    ep.tail = printsFromPcm(pcm, tn, scratch) orelse return false;
    ep.duration = dur;
    ep.tail_offset = @max(0, dur - @as(f64, @floatFromInt(tn)) / sr);
    cachePut(ep);
    return true;
}

// ── DB: media_markers + media_fingerprints (schema in core/db.zig) ─────────

fn loadMarkers(key: []const u8, out: []policy.Seg) usize {
    const stmt = db.prepare("SELECT kind, start, \"end\", confidence FROM media_markers WHERE media_key=?1 AND method=?2") orelse return 0;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, key);
    db.bindText(stmt, 2, METHOD_FP);
    var n: usize = 0;
    while (n < out.len and db.step(stmt) == db.c.SQLITE_ROW) {
        const kind = db.columnText(stmt, 0) orelse continue;
        const cat = mp.categoryFromKind(kind) orelse continue;
        out[n] = .{
            .start = db.columnDouble(stmt, 1),
            .end = db.columnDouble(stmt, 2),
            .category = cat,
            .confidence = @floatCast(db.columnDouble(stmt, 3)),
            .source = .fingerprint,
        };
        n += 1;
    }
    return n;
}

fn storeMarkers(key: []const u8, r: mm.Result) void {
    if (db.prepare("DELETE FROM media_markers WHERE media_key=?1 AND method=?2")) |del| {
        db.bindText(del, 1, key);
        db.bindText(del, 2, METHOD_FP);
        _ = db.step(del);
        db.finalize(del);
    }
    const now = io.timestamp();
    const items = [_]struct { mm.Category, ?mm.Marker }{ .{ .intro, r.intro }, .{ .credits, r.credits } };
    for (items) |it| {
        const m = it[1] orelse continue;
        const stmt = db.prepare("INSERT OR REPLACE INTO media_markers(media_key, kind, start, \"end\", confidence, method, updated_at) VALUES(?1,?2,?3,?4,?5,?6,?7)") orelse return;
        db.bindText(stmt, 1, key);
        db.bindText(stmt, 2, mp.kindName(it[0]));
        db.bindDouble(stmt, 3, m.start);
        db.bindDouble(stmt, 4, m.end);
        db.bindDouble(stmt, 5, m.confidence);
        db.bindText(stmt, 6, METHOD_FP);
        db.bindInt64(stmt, 7, now);
        _ = db.step(stmt);
        db.finalize(stmt);
    }
}

fn cacheGet(ep: *Ep) bool {
    const stmt = db.prepare("SELECT size, mtime, duration, tail_offset, head, tail FROM media_fingerprints WHERE path=?1") orelse return false;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, ep.pathSlice());
    if (db.step(stmt) != db.c.SQLITE_ROW) return false;
    if (db.columnInt64(stmt, 0) != @as(i64, @intCast(ep.size)) or db.columnInt64(stmt, 1) != ep.mtime) return false;
    const head_b = db.columnBlob(stmt, 4) orelse return false;
    const tail_b = db.columnBlob(stmt, 5) orelse return false;
    const head = alloc.alloc(u32, head_b.len / 4) catch return false;
    const tail = alloc.alloc(u32, tail_b.len / 4) catch {
        alloc.free(head);
        return false;
    };
    _ = mp.decodePrints(head_b, head);
    _ = mp.decodePrints(tail_b, tail);
    ep.head = head;
    ep.tail = tail;
    ep.duration = db.columnDouble(stmt, 2);
    ep.tail_offset = db.columnDouble(stmt, 3);
    return true;
}

fn cachePut(ep: *const Ep) void {
    const hb = alloc.alloc(u8, ep.head.len * 4) catch return;
    defer alloc.free(hb);
    const tb = alloc.alloc(u8, ep.tail.len * 4) catch return;
    defer alloc.free(tb);
    const stmt = db.prepare("INSERT OR REPLACE INTO media_fingerprints(path, size, mtime, duration, tail_offset, head, tail, updated_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8)") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, ep.pathSlice());
    db.bindInt64(stmt, 2, @intCast(ep.size));
    db.bindInt64(stmt, 3, ep.mtime);
    db.bindDouble(stmt, 4, ep.duration);
    db.bindDouble(stmt, 5, ep.tail_offset);
    db.bindBlob(stmt, 6, mp.encodePrints(ep.head, hb));
    db.bindBlob(stmt, 7, mp.encodePrints(ep.tail, tb));
    db.bindInt64(stmt, 8, io.timestamp());
    _ = db.step(stmt);
}
