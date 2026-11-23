//! `opal-scene-jump-probe` — feeds transcript strings (instead of the
//! microphone) through scene_jump_pure.handleTranscript, the same function the
//! assistant runs for "jump to the scene where …", with a JSON fixture of
//! moments standing in for Recall's moment index. Used by
//! tests/features/test_scene_jump.py.
//!
//!   opal-scene-jump-probe <fixture.json> <current_doc|-> <transcript>...
//!
//! Fixture: [{"moment_id":1,"doc_id":1,"start_secs":754,"title":"Heat",
//!            "snippet":"...","keywords":["rob","bank"],"score":0.9}, ...]
//! A moment matches a query when any keyword appears in it; its score is the
//! fixture score times the fraction of keywords matched. Transcripts run in
//! order with one shared pending state, so a follow-up answer can be tested.
//! One JSON object per transcript on stdout.
const std = @import("std");
const pure = @import("services/scene_jump_pure.zig");

const Entry = struct {
    moment_id: i64,
    doc_id: i64,
    start_secs: f64,
    score: f64 = 1,
    title: []const u8 = "",
    snippet: []const u8 = "",
    keywords: []const []const u8 = &.{},
};

const Fixture = struct {
    entries: []const Entry,
    queries: usize = 0,

    fn search(ctx: *anyopaque, query: []const u8, out: []pure.Candidate) usize {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        self.queries += 1;
        var n: usize = 0;
        for (self.entries) |e| {
            if (n >= out.len) break;
            var hits: usize = 0;
            for (e.keywords) |k| {
                if (std.mem.indexOf(u8, query, k) != null) hits += 1;
            }
            if (hits == 0) continue;
            out[n] = .{ .moment_id = e.moment_id, .doc_id = e.doc_id, .start_secs = e.start_secs, .score = e.score * @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(e.keywords.len)) };
            out[n].setTitle(e.title);
            out[n].setSnippet(e.snippet);
            n += 1;
        }
        return n;
    }
};

fn jsonStr(w: *std.Io.Writer, s: []const u8) !void {
    try std.json.Stringify.value(s, .{}, w);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const fixture_path = args.next() orelse return error.Usage;
    const current_text = args.next() orelse return error.Usage;
    const current_doc: ?i64 = if (std.mem.eql(u8, current_text, "-")) null else try std.fmt.parseInt(i64, current_text, 10);

    const raw = try std.Io.Dir.cwd().readFileAlloc(init.io, fixture_path, gpa, .limited(1 << 20));
    defer gpa.free(raw);
    const parsed = try std.json.parseFromSlice([]Entry, gpa, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var fx = Fixture{ .entries = parsed.value };

    var out_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    var pending = pure.Pending{};
    const searcher = pure.Searcher{ .ctx = &fx, .search = Fixture.search, .current_doc = current_doc };
    while (args.next()) |transcript| {
        var msg: [1024]u8 = undefined;
        const before = fx.queries;
        const claimed = pure.claims(transcript, &pending);
        const action = pure.handleTranscript(transcript, &pending, searcher, &msg);
        try w.print("{{\"transcript\":", .{});
        try jsonStr(w, transcript);
        try w.print(",\"claimed\":{},\"searched\":{},\"action\":\"{s}\"", .{ claimed, fx.queries > before, @tagName(action) });
        switch (action) {
            .ignore => {},
            .say, .ask => |m| {
                try w.writeAll(",\"message\":");
                try jsonStr(w, m);
            },
            .seek, .open => |s| {
                try w.print(",\"moment_id\":{d},\"doc_id\":{d},\"start_secs\":{d:.3},\"message\":", .{ s.cand.moment_id, s.cand.doc_id, s.cand.start_secs });
                try jsonStr(w, s.msg);
            },
        }
        try w.print(",\"pending\":{d}}}\n", .{pending.choices.len});
    }
}
