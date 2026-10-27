//! `zig build babel-live -- <media> [lang] [playhead_secs] [model]` — dev probe
//! for the live-caption pipeline. Runs the exact scheduler → ffmpeg chunk →
//! whisper-cli → overlap merge → SRT writer the app's worker uses, with the
//! playhead parked at `playhead_secs`, until captions are a full look-ahead
//! window ahead (or the media ends). Prints the SRT and chunk log.
const std = @import("std");
const engine = @import("services/live_captions_engine.zig");
const pure = @import("services/live_captions_pure.zig");
const secure_temp = @import("core/secure_temp.zig");
const paths = @import("core/paths.zig");

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("babel-live: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const media = args.next() orelse fail("usage: babel-live <media> [lang] [playhead] [model]", .{});
    const lang = pure.whisperLang(args.next() orelse "auto");
    const playhead = std.fmt.parseFloat(f64, args.next() orelse "0") catch 0;
    const model_arg = args.next();

    const whisper = engine.resolveWhisperBin() orelse fail("whisper-cli not found", .{});
    var model_buf: [512]u8 = undefined;
    var cfg_buf: [512]u8 = undefined;
    const model = model_arg orelse (engine.resolveWhisperModel(paths.configDir(&cfg_buf), lang, "tiny", &model_buf) orelse fail("no whisper model", .{}));

    var ws = secure_temp.Workspace.create("babel-live") catch fail("temp dir", .{});
    defer ws.cleanup();

    // Duration via the same ffmpeg (ffprobe may be absent): parse "Duration:".
    const duration = probeDuration(gpa, media);
    var cov: pure.Coverage = .{};
    var cues: std.ArrayList(pure.Cue) = .empty;
    defer {
        for (cues.items) |c| gpa.free(c.text);
        cues.deinit(gpa);
    }
    const cfg: pure.Config = .{};
    var chunks: usize = 0;
    while (pure.nextChunk(playhead, &cov, duration, cfg)) |chunk| {
        const t0 = std.Io.Clock.now(.awake, init.io);
        const got = engine.transcribeChunk(gpa, &ws, .{
            .ffmpeg = engine.ffmpegPath(),
            .whisper_bin = whisper,
            .model = model,
            .lang = lang,
            .source = media,
            .chunk = chunk,
        }) catch |e| fail("chunk {d:.1}+{d:.1}: {s}", .{ chunk.start, chunk.len, @errorName(e) });
        defer pure.freeCues(gpa, got);
        const is_final = duration > 0 and chunk.end() >= duration - 0.25;
        const added = try pure.mergeCues(gpa, &cues, got, chunk, is_final, cfg.overlap_secs);
        cov.add(.{ .start = chunk.start, .end = chunk.end() });
        const ms = t0.durationTo(std.Io.Clock.now(.awake, init.io)).toMilliseconds();
        std.debug.print("chunk {d}: [{d:.1}, {d:.1}) frontier={d:.1} raw={d} added={d} {d} ms\n", .{ chunks, chunk.start, chunk.end(), chunk.frontier, got.len, added, ms });
        chunks += 1;
        if (chunks > 64) break;
    }
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try pure.writeSrt(&aw.writer, cues.items, false);
    std.debug.print("duration={d:.1}s chunks={d} cues={d}\n--- SRT ---\n{s}", .{ duration, chunks, cues.items.len, aw.written() });
}

fn probeDuration(gpa: std.mem.Allocator, media: []const u8) f64 {
    _ = gpa;
    const bounded = @import("core/bounded_process.zig");
    var out: [256]u8 = undefined;
    const argv = [_][]const u8{ "ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", media };
    const r = bounded.run(&argv, &out, .{ .timeout_ms = 20_000 });
    if (!r.ok()) return 0; // unknown → treated like a live stream
    return std.fmt.parseFloat(f64, std.mem.trim(u8, r.output, " \r\n")) catch 0;
}
