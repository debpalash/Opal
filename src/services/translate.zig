//! Subtitle translation via the local LLM (cloud only when the user picked a
//! cloud provider). Translates the active subtitle track into
//! "<name>.<lang>.srt" and loads it as a new track; live captions reuse
//! translatePending() to translate cues as they arrive.
const std = @import("std");
const state = @import("../core/state.zig");
const sync = @import("../core/sync.zig");
const logs = @import("../core/logs.zig");
const io = @import("../core/io_global.zig");
const workers = @import("../core/workers.zig");
const secure_temp = @import("../core/secure_temp.zig");
const bounded = @import("../core/bounded_process.zig");
const alloc = @import("../core/alloc.zig").allocator;
const pure = @import("translate_pure.zig");
const lc = @import("live_captions_pure.zig");
const engine = @import("live_captions_engine.zig");
const llm = @import("llm_oneshot.zig");
const babel = @import("babel.zig");
const target_policy = @import("auto_subs_pure.zig");

pub const Outcome = enum { ok, offline, cancelled };

/// Translate every cue whose `alt` is still null, in batches. A batch the
/// model botches falls back to the original text per line (and is not
/// retried); `.offline` means no model answered at all — alts stay null.
pub fn translatePending(cues: []lc.Cue, lang_code: []const u8, cancel: ?bounded.CancelEpoch) Outcome {
    const lang_name = pure.langName(lang_code) orelse return .offline;
    var pending: std.ArrayList(usize) = .empty;
    defer pending.deinit(alloc);
    for (cues, 0..) |cue, i| if (cue.alt == null) pending.append(alloc, i) catch return .offline;
    if (pending.items.len == 0) return .ok;

    var texts: std.ArrayList([]const u8) = .empty;
    defer texts.deinit(alloc);
    for (pending.items) |i| texts.append(alloc, cues[i].text) catch return .offline;

    var start: usize = 0;
    while (start < texts.items.len) {
        const end = pure.nextBatchEnd(texts.items, start);
        const batch = texts.items[start..end];
        var prompt: std.Io.Writer.Allocating = .init(alloc);
        defer prompt.deinit();
        pure.writeBatchPrompt(&prompt.writer, batch, lang_name) catch return .offline;
        var chars: usize = 0;
        for (batch) |t| chars += t.len;
        const max_tokens: u32 = @intCast(std.math.clamp(chars + 64 * batch.len, 256, 4096));

        const reply: ?[]u8 = llm.complete(pure.system_prompt, prompt.written(), max_tokens, 120, cancel) catch |e| switch (e) {
            error.Cancelled => return .cancelled,
            error.Offline => return .offline,
            else => null, // garbled/HTTP error → this batch keeps its original text
        };
        defer if (reply) |r| alloc.free(r);

        var slots: [pure.max_batch_items]?[]const u8 = undefined;
        const slot_view = slots[0..batch.len];
        for (slot_view) |*s| s.* = null;
        if (reply) |r| {
            _ = pure.parseReply(r, slot_view);
        }
        for (batch, 0..) |orig, k| {
            var line_buf: [1024]u8 = undefined;
            const line = pure.resolveLine(orig, slot_view[k], &line_buf);
            cues[pending.items[start + k]].alt = alloc.dupe(u8, line) catch null;
        }
        start = end;
    }
    return .ok;
}

// ── Translate the active subtitle track ──

pub var in_progress = std.atomic.Value(bool).init(false);
var run_epoch = std.atomic.Value(u64).init(1);
var mutex: sync.Mutex = .{};
var status_buf: [128]u8 = undefined;
var status_len: usize = 0;
var pending_attach: struct {
    ready: bool = false,
    target: target_policy.Target = .{ .player_addr = 0, .load_serial = 0, .epoch = 0 },
    path: [1024]u8 = undefined,
    path_len: usize = 0,
    lang: [8]u8 = undefined,
    lang_len: usize = 0,
} = .{};

pub const StatusSnapshot = struct { text: [128]u8 = undefined, len: usize = 0 };

pub fn statusSnapshot() StatusSnapshot {
    mutex.lock();
    defer mutex.unlock();
    var s: StatusSnapshot = .{ .len = status_len };
    @memcpy(s.text[0..s.len], status_buf[0..s.len]);
    return s;
}

fn setStatus(msg: []const u8) void {
    mutex.lock();
    defer mutex.unlock();
    status_len = @min(msg.len, status_buf.len);
    @memcpy(status_buf[0..status_len], msg[0..status_len]);
}

pub fn cancelForMediaChange() void {
    _ = run_epoch.fetchAdd(1, .acq_rel);
    mutex.lock();
    pending_attach.ready = false;
    mutex.unlock();
}

const Job = struct {
    target: target_policy.Target,
    /// Subtitle file (external track) or the media (embedded track).
    input: []u8,
    /// ffmpeg "-map" for an embedded track ("0:<ff-index>"), else empty.
    map: [24]u8,
    map_len: usize,
    user_agent: []u8,
    headers: []u8,
    name: []u8,
    lang: [8]u8,
    lang_len: usize,

    fn deinit(j: *Job) void {
        alloc.free(j.input);
        alloc.free(j.user_agent);
        alloc.free(j.headers);
        alloc.free(j.name);
        alloc.destroy(j);
    }
};

// Remote callers only queue an owned media identity. Starting work and
// synchronizing Babel/recap state belongs to the playback owner loop.
var requested: ?target_policy.Target = null;
pub fn requestActiveTrack() void {
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const p = state.app.players.items[state.app.active_player_idx];
    mutex.lock();
    defer mutex.unlock();
    requested = .{ .player_addr = @intFromPtr(p), .load_serial = p.load_serial, .epoch = 0 };
}

pub fn pollRequest() void {
    mutex.lock();
    const target = requested;
    requested = null;
    mutex.unlock();
    const wanted = target orelse return;
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const p = state.app.players.items[state.app.active_player_idx];
    if (@intFromPtr(p) != wanted.player_addr or p.load_serial != wanted.load_serial) return;
    translateActiveTrack();
}

/// UI thread: translate the selected subtitle track into the configured
/// "Translate subtitles to" language.
pub fn translateActiveTrack() void {
    // Establish the owner-thread media generation before starting the worker.
    babel.syncMediaIdentity();
    const lang = babel.translateLang();
    if (lang.len == 0) {
        state.showToast("Pick a language in Settings › Subtitles › Translate subtitles to");
        return;
    }
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    llm.prepare();
    if (!llm.available()) {
        state.showToast("Translation needs an AI model — install one in Settings › AI");
        return;
    }
    if (in_progress.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
    const p = state.app.players.items[state.app.active_player_idx];

    var ext_buf: [4096]u8 = undefined;
    var path_buf: [4096]u8 = undefined;
    var title_buf: [256]u8 = undefined;
    const external = babel.mpvString(p.mpv_ctx, "current-tracks/sub/external-filename", &ext_buf);
    const ff_index = babel.mpvInt(p.mpv_ctx, "current-tracks/sub/ff-index");
    const media = babel.mpvString(p.mpv_ctx, "stream-open-filename", &path_buf) orelse babel.mpvString(p.mpv_ctx, "path", &path_buf);
    if (external == null and (ff_index == null or media == null)) {
        in_progress.store(false, .release);
        state.showToast("Select a subtitle track to translate first");
        return;
    }
    const input = external orelse media.?;
    if (lc.sourceKind(input) == .unsupported) {
        in_progress.store(false, .release);
        state.showToast("This subtitle track can't be read for translation");
        return;
    }
    const name_src = external orelse (babel.mpvString(p.mpv_ctx, "media-title", &title_buf) orelse "subtitles");

    var hdr_buf: [2048]u8 = undefined;
    const headers = lc.ffmpegHeaders(p.current_header_fields[0..p.current_header_fields_len], &hdr_buf);
    const job = alloc.create(Job) catch {
        in_progress.store(false, .release);
        return;
    };
    job.* = .{
        .target = .{ .player_addr = @intFromPtr(p), .load_serial = p.load_serial, .epoch = run_epoch.load(.acquire) },
        .input = &.{},
        .map = undefined,
        .map_len = 0,
        .user_agent = &.{},
        .headers = &.{},
        .name = &.{},
        .lang = undefined,
        .lang_len = @min(lang.len, 8),
    };
    @memcpy(job.lang[0..job.lang_len], lang[0..job.lang_len]);
    if (external == null) {
        const m = std.fmt.bufPrint(&job.map, "0:{d}", .{ff_index.?}) catch "";
        job.map_len = m.len;
    }
    const ok = blk: {
        job.input = alloc.dupe(u8, input) catch break :blk false;
        job.user_agent = alloc.dupe(u8, p.current_user_agent[0..p.current_user_agent_len]) catch break :blk false;
        job.headers = alloc.dupe(u8, headers) catch break :blk false;
        job.name = alloc.dupe(u8, name_src) catch break :blk false;
        break :blk true;
    };
    if (!ok) {
        job.deinit();
        in_progress.store(false, .release);
        return;
    }
    setStatus("Translating subtitles…");
    if (workers.spawnLegacy(worker, .{job})) |t| workers.release(t) else |_| {
        job.deinit();
        in_progress.store(false, .release);
        setStatus("Could not start translation");
    }
}

fn worker(job: *Job) void {
    defer {
        job.deinit();
        in_progress.store(false, .release);
    }
    const cancel: bounded.CancelEpoch = .{ .epoch64 = .{ .value = &run_epoch, .expected = job.target.epoch } };
    var ws = secure_temp.Workspace.create("translate") catch {
        setStatus("Translation: temp dir unavailable");
        return;
    };
    defer ws.cleanup();
    var srt_buf: [secure_temp.max_path_len]u8 = undefined;
    const srt = ws.path("source.srt", &srt_buf) catch return;

    // Normalize any subtitle (SRT/VTT/ASS, external or embedded) to SRT.
    var argv: [24][]const u8 = undefined;
    var n: usize = 0;
    for ([_][]const u8{ engine.ffmpegPath(), "-nostdin", "-hide_banner", "-loglevel", "error", "-y" }) |s| {
        argv[n] = s;
        n += 1;
    }
    if (lc.sourceKind(job.input) == .http) {
        for ([_][]const u8{ "-rw_timeout", "20000000" }) |s| {
            argv[n] = s;
            n += 1;
        }
        if (job.user_agent.len > 0) {
            argv[n] = "-user_agent";
            argv[n + 1] = job.user_agent;
            n += 2;
        }
        if (job.headers.len > 0) {
            argv[n] = "-headers";
            argv[n + 1] = job.headers;
            n += 2;
        }
    }
    argv[n] = "-i";
    argv[n + 1] = lc.localPath(job.input);
    n += 2;
    if (job.map_len > 0) {
        argv[n] = "-map";
        argv[n + 1] = job.map[0..job.map_len];
        n += 2;
    }
    for ([_][]const u8{ "-f", "srt", srt }) |s| {
        argv[n] = s;
        n += 1;
    }
    var out: [4096]u8 = undefined;
    const ff = bounded.run(argv[0..n], &out, .{ .timeout_ms = 10 * 60 * 1000, .cancel_epoch = cancel });
    if (ff.failure == .cancelled) return;
    const body = io.cwdReadFileAlloc(srt, alloc, 8 * 1024 * 1024) catch {
        setStatus("Translation: could not read the subtitle track");
        return;
    };
    defer alloc.free(body);
    const cues = lc.parseSrt(alloc, body) catch return;
    defer lc.freeCues(alloc, cues);
    if (cues.len == 0) {
        setStatus("Translation: the subtitle track is empty");
        return;
    }

    const lang = job.lang[0..job.lang_len];
    var msg_buf: [96]u8 = undefined;
    setStatus(std.fmt.bufPrint(&msg_buf, "Translating {d} lines into {s}…", .{ cues.len, pure.langName(lang) orelse lang }) catch "Translating…");
    switch (translatePending(cues, lang, cancel)) {
        .ok => {},
        .cancelled => return,
        .offline => {
            setStatus("Translation failed: the AI model is not responding");
            return;
        },
    }
    var fallback: usize = 0;
    for (cues) |cue| {
        if (cue.alt == null or std.mem.eql(u8, cue.alt.?, cue.text)) fallback += 1;
    }

    var dir_buf: [700]u8 = undefined;
    const dir = babel.cacheDir(&dir_buf, "translated");
    var name_buf: [160]u8 = undefined;
    const name = pure.outputName(job.name, lang, &name_buf);
    var path_buf: [900]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    lc.writeSrt(&aw.writer, cues, true) catch return;
    engine.writeAtomic(path, aw.written()) catch {
        setStatus("Translation: could not write the subtitle file");
        return;
    };

    mutex.lock();
    if (run_epoch.load(.acquire) == job.target.epoch) {
        pending_attach.ready = true;
        pending_attach.target = job.target;
        pending_attach.path_len = @min(path.len, pending_attach.path.len);
        @memcpy(pending_attach.path[0..pending_attach.path_len], path[0..pending_attach.path_len]);
        pending_attach.lang_len = job.lang_len;
        @memcpy(pending_attach.lang[0..job.lang_len], job.lang[0..job.lang_len]);
    }
    mutex.unlock();
    const done = std.fmt.bufPrint(&msg_buf, "Translated {d} lines ({d} kept original)", .{ cues.len, fallback }) catch "Translated";
    setStatus(done);
    logs.pushLog("info", "babel", done, false);
    state.wakeUi();
}

/// UI thread: load a finished translation into the exact player/load that
/// asked for it.
pub fn pollAttach() void {
    var pa: @TypeOf(pending_attach) = .{};
    mutex.lock();
    if (pending_attach.ready) {
        pa = pending_attach;
        pending_attach.ready = false;
    }
    mutex.unlock();
    if (!pa.ready) return;
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const p = state.app.players.items[state.app.active_player_idx];
    if (!target_policy.matches(pa.target, @intFromPtr(p), p.load_serial, run_epoch.load(.acquire))) return;
    const lang = pa.lang[0..pa.lang_len];
    var title_buf: [64]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "{s} (translated)", .{pure.langName(lang) orelse lang}) catch "Translated";
    if (babel.subAdd(p.mpv_ctx, pa.path[0..pa.path_len], title, lang) != null) {
        state.showToast("Translated subtitles loaded");
    } else state.showToast("Could not load the translated subtitles");
}
