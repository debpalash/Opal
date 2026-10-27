//! Live captions (ROADMAP 3.2) — captions for anything playing, on-device.
//!
//! A worker keeps whisper.cpp transcription ~60 s ahead of the playhead in
//! short ffmpeg chunks (local files, torrent streams via the loopback proxy,
//! and http(s) URLs with the player's own User-Agent/header identity), stitches
//! the overlapping chunk output (live_captions_pure), rewrites a growing SRT in
//! the cache dir, and the UI thread `sub-add`s it once then `sub-reload`s it.
//! When "Translate subtitles to" is set, new cues are translated as they
//! arrive and the translated SRT is the loaded track.
//!
//! Lifecycle: tick() (UI thread, every frame) binds the worker to one exact
//! player allocation + load serial. A file change, player close, toggle-off or
//! quit bumps `run_epoch`, which kills any in-flight ffmpeg/whisper and ends
//! the worker.
const std = @import("std");
const state = @import("../core/state.zig");
const sync = @import("../core/sync.zig");
const logs = @import("../core/logs.zig");
const io = @import("../core/io_global.zig");
const paths = @import("../core/paths.zig");
const workers = @import("../core/workers.zig");
const secure_temp = @import("../core/secure_temp.zig");
const bounded = @import("../core/bounded_process.zig");
const alloc = @import("../core/alloc.zig").allocator;
const pure = @import("live_captions_pure.zig");
const engine = @import("live_captions_engine.zig");
const babel = @import("babel.zig");
const translate = @import("translate.zig");

/// User toggle (player "Live captions" button / web API). Session-scoped.
pub var enabled = std.atomic.Value(bool).init(false);
var run_epoch = std.atomic.Value(u64).init(1);

/// UI-thread-only binding to the media being captioned.
var bound: struct {
    active: bool = false,
    player_addr: usize = 0,
    load_serial: u64 = 0,
    epoch: u64 = 0,
    sid: i64 = -1,
} = .{};

/// UI ↔ worker exchange.
var mutex: sync.Mutex = .{};
var shared: struct {
    playhead: f64 = 0,
    duration: f64 = 0,
    publish_ready: bool = false,
    publish_epoch: u64 = 0,
    publish_path: [1024]u8 = undefined,
    publish_len: usize = 0,
    cues: usize = 0,
    status: [128]u8 = undefined,
    status_len: usize = 0,
} = .{};

pub const StatusSnapshot = struct {
    text: [128]u8 = undefined,
    len: usize = 0,
    cues: usize = 0,
};

pub fn statusSnapshot() StatusSnapshot {
    mutex.lock();
    defer mutex.unlock();
    var s: StatusSnapshot = .{ .len = shared.status_len, .cues = shared.cues };
    @memcpy(s.text[0..s.len], shared.status[0..s.len]);
    return s;
}

fn setStatus(msg: []const u8) void {
    mutex.lock();
    defer mutex.unlock();
    const n = @min(msg.len, shared.status.len);
    @memcpy(shared.status[0..n], msg[0..n]);
    shared.status_len = n;
}

/// Toggle from UI / remote. Turning on with no whisper-cli explains why.
pub fn setEnabled(on: bool) void {
    if (on and engine.resolveWhisperBin() == null) {
        state.showToast("Live captions need whisper-cli — install whisper.cpp (brew install whisper-cpp)");
        setStatus("whisper-cli not found");
        enabled.store(false, .release);
        return;
    }
    enabled.store(on, .release);
    if (!on) setStatus("");
}

fn stop() void {
    _ = run_epoch.fetchAdd(1, .acq_rel);
    bound = .{};
    mutex.lock();
    shared.publish_ready = false;
    shared.cues = 0;
    mutex.unlock();
}

/// UI thread, every frame.
pub fn tick() void {
    if (!enabled.load(.acquire) or state.app.active_player_idx >= state.app.players.items.len) {
        if (bound.active) stop();
        return;
    }
    const p = state.app.players.items[state.app.active_player_idx];
    const addr = @intFromPtr(p);
    if (!bound.active or bound.player_addr != addr or bound.load_serial != p.load_serial) {
        if (bound.active) stop();
        start(p);
        return;
    }
    const pos = babel.mpvDouble(p.mpv_ctx, "time-pos") orelse return;
    const dur = babel.mpvDouble(p.mpv_ctx, "duration") orelse 0;

    var path_buf: [1024]u8 = undefined;
    var path_len: usize = 0;
    mutex.lock();
    shared.playhead = pos;
    shared.duration = dur;
    if (shared.publish_ready and shared.publish_epoch == bound.epoch) {
        path_len = shared.publish_len;
        @memcpy(path_buf[0..path_len], shared.publish_path[0..path_len]);
    }
    shared.publish_ready = false;
    mutex.unlock();
    if (path_len == 0) return;

    const path = path_buf[0..path_len];
    if (bound.sid < 0) {
        const tl = babel.translateLang();
        bound.sid = babel.subAdd(p.mpv_ctx, path, if (tl.len > 0) "Live captions (translated)" else "Live captions", if (tl.len > 0) tl else "") orelse -1;
        if (bound.sid >= 0) logs.pushLog("info", "babel", "Live captions track added", false);
    } else if (!babel.subReload(p.mpv_ctx, bound.sid)) {
        // The track vanished (user removed it / track list rebuilt): re-add.
        bound.sid = babel.subAdd(p.mpv_ctx, path, "Live captions", "") orelse -1;
    }
}

const Args = struct {
    epoch: u64,
    source: []u8,
    user_agent: []u8,
    headers: []u8,
    model: [512]u8,
    model_len: usize,
    whisper_bin: []const u8,
    lang: [8]u8,
    lang_len: usize,
    translate_lang: [8]u8,
    translate_len: usize,
    episode: ?struct { tmdb_id: i32, season: i32, episode: i32 },

    fn deinit(a: *Args) void {
        alloc.free(a.source);
        alloc.free(a.user_agent);
        alloc.free(a.headers);
        alloc.destroy(a);
    }
};

fn start(p: anytype) void {
    const whisper = engine.resolveWhisperBin() orelse {
        setEnabled(true); // shows the install toast and turns the toggle off
        return;
    };
    // Source: the resolved stream mpv actually opened (ytdl → direct URL),
    // else the playlist path. Not available until mpv has loaded the file.
    var src_buf: [4096]u8 = undefined;
    var source: ?[]const u8 = null;
    if (babel.mpvString(p.mpv_ctx, "stream-open-filename", &src_buf)) |s| {
        if (pure.sourceKind(s) != .unsupported) source = s;
    }
    if (source == null) {
        if (babel.mpvString(p.mpv_ctx, "path", &src_buf)) |s| {
            if (pure.sourceKind(s) == .unsupported) {
                state.showToast("Live captions can't read this stream type");
                enabled.store(false, .release);
                return;
            }
            source = s;
        } else return; // still loading — retry next frame
    }

    const lang = babel.captionLang();
    var cfg_buf: [512]u8 = undefined;
    const auto_subs = @import("auto_subs.zig");
    var model_buf: [512]u8 = undefined;
    const model = engine.resolveWhisperModel(paths.configDir(&cfg_buf), lang, auto_subs.whisper_model_size[0..auto_subs.whisper_model_size_len], &model_buf) orelse {
        state.showToast("Live captions need a Whisper model — download it in Settings › AI & Voice");
        setStatus("Whisper model missing");
        enabled.store(false, .release);
        return;
    };

    var hdr_buf: [2048]u8 = undefined;
    const headers = pure.ffmpegHeaders(p.current_header_fields[0..p.current_header_fields_len], &hdr_buf);

    const args = alloc.create(Args) catch return;
    args.* = .{
        .epoch = run_epoch.load(.acquire),
        .source = alloc.dupe(u8, source.?) catch {
            alloc.destroy(args);
            return;
        },
        .user_agent = &.{},
        .headers = &.{},
        .model = undefined,
        .model_len = model.len,
        .whisper_bin = whisper,
        .lang = undefined,
        .lang_len = @min(lang.len, 8),
        .translate_lang = undefined,
        .translate_len = 0,
        .episode = null,
    };
    args.user_agent = alloc.dupe(u8, p.current_user_agent[0..p.current_user_agent_len]) catch {
        alloc.free(args.source);
        alloc.destroy(args);
        return;
    };
    args.headers = alloc.dupe(u8, headers) catch {
        alloc.free(args.user_agent);
        alloc.free(args.source);
        alloc.destroy(args);
        return;
    };
    @memcpy(args.model[0..model.len], model);
    @memcpy(args.lang[0..args.lang_len], lang[0..args.lang_len]);
    const tl = babel.translateLang();
    args.translate_len = @min(tl.len, 8);
    @memcpy(args.translate_lang[0..args.translate_len], tl[0..args.translate_len]);
    const pe = &state.app.playing_episode;
    if (pe.matches(p.current_url[0..p.current_url_len])) {
        args.episode = .{ .tmdb_id = pe.tmdb_id, .season = pe.season, .episode = pe.episode };
    }
    if (tl.len > 0) @import("llm_oneshot.zig").prepare();

    bound = .{ .active = true, .player_addr = @intFromPtr(p), .load_serial = p.load_serial, .epoch = args.epoch, .sid = -1 };
    mutex.lock();
    shared.playhead = babel.mpvDouble(p.mpv_ctx, "time-pos") orelse 0;
    shared.duration = babel.mpvDouble(p.mpv_ctx, "duration") orelse 0;
    shared.publish_ready = false;
    shared.cues = 0;
    mutex.unlock();
    setStatus("Starting live captions…");

    if (workers.spawnLegacy(worker, .{args})) |t| workers.release(t) else |_| {
        args.deinit();
        bound = .{};
        setStatus("Could not start the caption worker");
        enabled.store(false, .release);
    }
}

fn cancelled(epoch: u64) bool {
    return run_epoch.load(.acquire) != epoch or workers.isQuitting();
}

fn publish(epoch: u64, path: []const u8, cue_count: usize) void {
    mutex.lock();
    defer mutex.unlock();
    if (run_epoch.load(.acquire) != epoch) return;
    shared.publish_ready = true;
    shared.publish_epoch = epoch;
    shared.publish_len = @min(path.len, shared.publish_path.len);
    @memcpy(shared.publish_path[0..shared.publish_len], path[0..shared.publish_len]);
    shared.cues = cue_count;
    state.wakeUi();
}

fn writeOutputs(a: *const Args, cues: []const pure.Cue, srt_path: []const u8, tr_path: []const u8, translated: bool) bool {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    pure.writeSrt(&aw.writer, cues, false) catch return false;
    engine.writeAtomic(srt_path, aw.written()) catch return false;
    if (translated and tr_path.len > 0) {
        aw.clearRetainingCapacity();
        pure.writeSrt(&aw.writer, cues, true) catch return false;
        engine.writeAtomic(tr_path, aw.written()) catch return false;
    }
    if (a.episode) |ep| {
        var tp_buf: [800]u8 = undefined;
        const tp = babel.transcriptPath(&tp_buf, ep.tmdb_id, ep.season, ep.episode);
        if (tp.len > 0) {
            aw.clearRetainingCapacity();
            pure.writeTranscript(&aw.writer, cues) catch return true;
            engine.writeAtomic(tp, aw.written()) catch {};
        }
    }
    return true;
}

fn fmtClock(buf: []u8, secs: f64) []const u8 {
    const s: u64 = @intFromFloat(@max(0, secs));
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ s / 3600, (s / 60) % 60, s % 60 }) catch "";
}

fn worker(a: *Args) void {
    defer a.deinit();
    const epoch = a.epoch;
    var ws = secure_temp.Workspace.create("livecap") catch {
        setStatus("Live captions: temp dir unavailable");
        return;
    };
    defer ws.cleanup();

    var dir_buf: [700]u8 = undefined;
    const dir = babel.cacheDir(&dir_buf, "live");
    var srt_buf: [800]u8 = undefined;
    var tr_buf: [800]u8 = undefined;
    const srt_path = std.fmt.bufPrint(&srt_buf, "{s}/live-{d}.srt", .{ dir, epoch }) catch return;
    const tl = a.translate_lang[0..a.translate_len];
    const tr_path = if (tl.len > 0) (std.fmt.bufPrint(&tr_buf, "{s}/live-{d}.{s}.srt", .{ dir, epoch, tl }) catch "") else "";
    var translate_on = tl.len > 0 and tr_path.len > 0;

    var cov: pure.Coverage = .{};
    var cues: std.ArrayList(pure.Cue) = .empty;
    defer {
        for (cues.items) |cue| {
            alloc.free(cue.text);
            if (cue.alt) |t| alloc.free(t);
        }
        cues.deinit(alloc);
    }
    const cfg: pure.Config = .{};
    const cancel: bounded.CancelEpoch = .{ .epoch64 = .{ .value = &run_epoch, .expected = epoch } };
    var failures: u32 = 0;
    var announced = false;

    while (!cancelled(epoch)) {
        mutex.lock();
        const playhead = shared.playhead;
        const duration = shared.duration;
        mutex.unlock();
        const chunk = pure.nextChunk(playhead, &cov, duration, cfg) orelse {
            io.sleep(300 * std.time.ns_per_ms);
            continue;
        };
        var clock_buf: [24]u8 = undefined;
        var st_buf: [96]u8 = undefined;
        setStatus(std.fmt.bufPrint(&st_buf, "Captioning from {s}…", .{fmtClock(&clock_buf, chunk.start)}) catch "Captioning…");

        const got = engine.transcribeChunk(alloc, &ws, .{
            .ffmpeg = engine.ffmpegPath(),
            .whisper_bin = a.whisper_bin,
            .model = a.model[0..a.model_len],
            .lang = a.lang[0..a.lang_len],
            .source = a.source,
            .user_agent = a.user_agent,
            .headers = a.headers,
            .chunk = chunk,
            .cancel = cancel,
        }) catch |e| {
            if (e == error.Cancelled or cancelled(epoch)) break;
            failures += 1;
            if (failures >= 3) {
                setStatus(if (e == error.Extract) "Live captions stopped: ffmpeg could not read the stream" else "Live captions stopped: whisper failed");
                logs.pushLog("error", "babel", "Live captions gave up after 3 failed chunks", true);
                break;
            }
            // Skip this window so a bad segment can't wedge the loop.
            cov.add(.{ .start = chunk.start, .end = chunk.end() });
            continue;
        };
        defer pure.freeCues(alloc, got);
        failures = 0;
        const is_final = duration > 0 and chunk.end() >= duration - 0.25;
        _ = pure.mergeCues(alloc, &cues, got, chunk, is_final, cfg.overlap_secs) catch break;
        cov.add(.{ .start = chunk.start, .end = chunk.end() });
        if (cancelled(epoch)) break;

        if (translate_on) {
            switch (translate.translatePending(cues.items, tl, cancel)) {
                .ok => {},
                .cancelled => break,
                .offline => {
                    translate_on = false;
                    setStatus("Translation unavailable (no AI model) — showing original captions");
                },
            }
        }
        if (!writeOutputs(a, cues.items, srt_path, tr_path, translate_on)) {
            setStatus("Live captions: could not write the subtitle file");
            break;
        }
        publish(epoch, if (translate_on) tr_path else srt_path, cues.items.len);
        if (!announced) {
            announced = true;
            logs.pushLog("info", "babel", "Live captions running", false);
        }
        var done_buf: [96]u8 = undefined;
        const ahead = if (cov.containing(playhead, cfg.seek_slack_secs)) |r| r.end else chunk.end();
        setStatus(std.fmt.bufPrint(&done_buf, "Live captions: {d} lines, ready to {s}{s}", .{
            cues.items.len,
            fmtClock(&clock_buf, ahead),
            if (tl.len > 0 and !translate_on) " (untranslated: no AI model)" else "",
        }) catch "Live captions on");
    }
}
