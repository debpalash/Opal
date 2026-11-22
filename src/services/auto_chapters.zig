//! Automatic chapters (ROADMAP 7.2) for local files that have none.
//!
//! markers.zig's worker calls `run` after intro/credits detection for the same
//! load. The result is cached in media_auto_chapters (keyed like
//! media_markers by path+size+mtime), so the keyframe scene pass runs once
//! per file version. The chapters are applied on the owner thread by `tick`
//! (playback_update), which writes mpv's `chapter-list` — the footer pips,
//! chapter chip/picker, prev/next keys and web snapshot all read that — and
//! republishes the chapter-title skip segments. Decisions live in
//! auto_chapters_pure.zig.
const std = @import("std");
const state = @import("../core/state.zig");
const db = @import("../core/db.zig");
const logs = @import("../core/logs.zig");
const sync = @import("../core/sync.zig");
const alloc = @import("../core/alloc.zig").allocator;
const io = @import("../core/io_global.zig");
const bounded_process = @import("../core/bounded_process.zig");
const workers = @import("../core/workers.zig");
const c = @import("../core/c.zig");
const pure = @import("auto_chapters_pure.zig");
const mp = @import("markers_pure.zig");
const mm = @import("marker_match_pure.zig");
const policy = @import("skip_policy_pure.zig");
const skip_segments = @import("skip_segments.zig");
const anime_pure = @import("anime_skip_pure.zig");

const METHOD = "scene";
const SCENE_TIMEOUT_MS: i64 = 900_000;
const MAX_CUTS = 4096;
const SCENE_OUTPUT_BYTES = 512 * 1024;

const Pending = struct {
    gen: u64 = 0,
    owner: usize = 0,
    n: usize = 0,
    chapters: [pure.MAX_CHAPTERS]pure.Chapter = undefined,
};

var mutex: sync.Mutex = .{};
var pending: Pending = .{}; // under mutex
var has_pending = std.atomic.Value(bool).init(false);

/// Worker thread: chapters for `path` (stored or computed), then queued for
/// the owner thread. `markers` are the intro/credits already known for it.
pub fn run(path: []const u8, gen: u64, owner: usize, duration: f64, markers: []const policy.Seg) void {
    const st = io.cwdStatFile(path) catch return;
    const mtime: i64 = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_s));
    var key_buf: [1100]u8 = undefined;
    const key = mp.mediaKey(path, st.size, mtime, &key_buf);
    if (key.len == 0) return;

    var chapters: [pure.MAX_CHAPTERS]pure.Chapter = undefined;
    const n = load(key, &chapters) orelse compute(path, key, duration, markers, &chapters) orelse return;
    if (n < 2 or workers.isQuitting()) return;
    mutex.lock();
    pending = .{ .gen = gen, .owner = owner, .n = n };
    @memcpy(pending.chapters[0..n], chapters[0..n]);
    mutex.unlock();
    has_pending.store(true, .release);
    state.wakeUi();
}

fn spanOf(markers: []const policy.Seg, cat: anime_pure.Category) ?pure.Span {
    for (markers) |s| if (s.category == cat) return .{ .start = s.start, .end = s.end };
    return null;
}

fn compute(path: []const u8, key: []const u8, duration_hint: f64, markers: []const policy.Seg, out: *[pure.MAX_CHAPTERS]pure.Chapter) ?usize {
    const ffmpeg = @import("remote_stream.zig").ffmpegPath();
    if (ffmpeg.len == 0) return null;
    const duration = if (duration_hint > 0) duration_hint else @import("markers.zig").probeDuration(ffmpeg, path);
    if (!(duration > 0)) return null;

    var argv_buf: [pure.SCENE_ARGC + 3][]const u8 = undefined;
    var n_argv: usize = 0;
    // Low priority, like the fingerprint worker: this competes with playback.
    if (@import("builtin").os.tag != .windows) {
        if (io.cwdStatFile("/usr/bin/nice")) |_| {
            for ([_][]const u8{ "/usr/bin/nice", "-n", "19" }) |a| {
                argv_buf[n_argv] = a;
                n_argv += 1;
            }
        } else |_| {}
    }
    var scene_argv: [pure.SCENE_ARGC][]const u8 = undefined;
    for (pure.sceneArgv(ffmpeg, path, &scene_argv)) |a| {
        argv_buf[n_argv] = a;
        n_argv += 1;
    }
    const output = alloc.alloc(u8, SCENE_OUTPUT_BYTES) catch return null;
    defer alloc.free(output);
    const res = bounded_process.run(argv_buf[0..n_argv], output, .{ .timeout_ms = SCENE_TIMEOUT_MS });
    // A truncated report still holds the earliest cuts; anything else failing
    // (timeout, cancel, ffmpeg error) is retried on a later load.
    if (!res.ok() and res.failure != .output_limit) return null;
    const cuts = alloc.alloc(pure.Cut, MAX_CUTS) catch return null;
    defer alloc.free(cuts);
    const nc = pure.parseScenes(res.output, cuts);
    const n = pure.build(cuts[0..nc], duration, spanOf(markers, .intro), spanOf(markers, .credits), out);
    store(key, out[0..n]);
    var lb: [96]u8 = undefined;
    logs.pushLog("info", "chapters", std.fmt.bufPrint(&lb, "auto chapters: {d} from {d} scene cut(s)", .{ n, nc }) catch "auto chapters", false);
    return n;
}

fn load(key: []const u8, out: *[pure.MAX_CHAPTERS]pure.Chapter) ?usize {
    const stmt = db.prepare("SELECT chapters FROM media_auto_chapters WHERE media_key=?1 AND method=?2") orelse return null;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, key);
    db.bindText(stmt, 2, METHOD);
    if (db.step(stmt) != db.c.SQLITE_ROW) return null;
    return pure.decode(db.columnText(stmt, 0) orelse "", out);
}

fn store(key: []const u8, chapters: []const pure.Chapter) void {
    var buf: [pure.MAX_CHAPTERS * 24]u8 = undefined;
    const stmt = db.prepare("INSERT OR REPLACE INTO media_auto_chapters(media_key, method, chapters, updated_at) VALUES(?1,?2,?3,?4)") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, key);
    db.bindText(stmt, 2, METHOD);
    db.bindText(stmt, 3, pure.encode(chapters, &buf));
    db.bindInt64(stmt, 4, io.timestamp());
    _ = db.step(stmt);
}

/// Owner thread (playback_update.tick, under players_mutex).
pub fn tick() void {
    if (!has_pending.load(.acquire)) return;
    mutex.lock();
    const job = pending;
    has_pending.store(false, .release);
    mutex.unlock();
    if (job.gen != skip_segments.currentGeneration()) return; // a newer file loaded
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const p = state.app.players.items[state.app.active_player_idx];
    if (@intFromPtr(p) != job.owner) return;
    apply(p, job.chapters[0..job.n], job.gen);
}

fn apply(p: anytype, chapters: []const pure.Chapter, gen: u64) void {
    // Only ever fill an empty list: never replace chapters mpv found itself.
    var count: i64 = 0;
    _ = c.mpv.mpv_get_property(p.mpv_ctx, "chapter-list/count", c.mpv.MPV_FORMAT_INT64, &count);
    if (count > 0) return;

    const n = @min(chapters.len, pure.MAX_CHAPTERS);
    var titles: [pure.MAX_CHAPTERS][24]u8 = undefined;
    var title_lens: [pure.MAX_CHAPTERS]usize = undefined;
    var values: [pure.MAX_CHAPTERS][2]c.mpv.mpv_node = undefined;
    var keys: [pure.MAX_CHAPTERS][2][*c]u8 = undefined;
    var maps: [pure.MAX_CHAPTERS]c.mpv.mpv_node_list = undefined;
    var entries: [pure.MAX_CHAPTERS]c.mpv.mpv_node = undefined;
    for (0..n) |i| {
        var title_buf: [23]u8 = undefined;
        const t = pure.title(chapters[0..n], i, &title_buf);
        @memcpy(titles[i][0..t.len], t);
        title_lens[i] = t.len;
        titles[i][t.len] = 0;
        values[i] = .{
            .{ .u = .{ .string = @ptrCast(&titles[i]) }, .format = c.mpv.MPV_FORMAT_STRING },
            .{ .u = .{ .double_ = chapters[i].start }, .format = c.mpv.MPV_FORMAT_DOUBLE },
        };
        keys[i] = .{ @constCast("title"), @constCast("time") };
        maps[i] = .{ .num = 2, .values = @ptrCast(&values[i]), .keys = @ptrCast(&keys[i]) };
        entries[i] = .{ .u = .{ .list = &maps[i] }, .format = c.mpv.MPV_FORMAT_NODE_MAP };
    }
    var list: c.mpv.mpv_node_list = .{ .num = @intCast(n), .values = @ptrCast(&entries), .keys = null };
    var node: c.mpv.mpv_node = .{ .u = .{ .list = &list }, .format = c.mpv.MPV_FORMAT_NODE_ARRAY };
    if (c.mpv.mpv_set_property(p.mpv_ctx, "chapter-list", c.mpv.MPV_FORMAT_NODE, &node) < 0) {
        logs.pushLog("warn", "chapters", "mpv rejected the generated chapter list", false);
        return;
    }

    // The same chapter-title skip path markers.zig runs on FILE_LOADED.
    var mm_chapters: [pure.MAX_CHAPTERS]mm.Chapter = undefined;
    for (0..n) |i| mm_chapters[i] = .{ .start = chapters[i].start, .title = titles[i][0..title_lens[i]] };
    var raw: [policy.MAX_SEGS]anime_pure.Segment = undefined;
    const ns = mm.chapterSegments(mm_chapters[0..n], p.cached_duration, &raw);
    if (ns > 0) {
        var segs: [policy.MAX_SEGS]policy.Seg = undefined;
        for (raw[0..ns], 0..) |s, i| segs[i] = .{ .start = s.start, .end = s.end, .category = s.category, .source = .chapters };
        _ = skip_segments.publish(.chapters, gen, segs[0..ns]);
    }
    var lb: [64]u8 = undefined;
    logs.pushLog("info", "chapters", std.fmt.bufPrint(&lb, "{d} automatic chapter(s) applied", .{n}) catch "automatic chapters applied", false);
    state.wakeUi();
}
