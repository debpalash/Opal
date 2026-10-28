//! Assistant tools over Recall (ROADMAP 7.1): `recall_search` lists what the
//! user's own library holds for a plain-language request; `find_moment` finds
//! the subtitle moment that matches and starts it at that second. Called from
//! ai_tools.executeTool on the assistant worker thread; results are short
//! plain text for the model (ai_tools caps tool results at 2 KB).

const std = @import("std");
const recall = @import("recall.zig");
const pure = @import("recall_pure.zig");

const RESULT_MAX = 1800;

fn results() ?*recall.Results {
    return @import("../core/alloc.zig").allocator.create(recall.Results) catch null;
}

fn release(r: *recall.Results) void {
    @import("../core/alloc.zig").allocator.destroy(r);
}

pub fn recallSearch(alloc: std.mem.Allocator, query_arg: ?[]const u8) ?[]u8 {
    const query = query_arg orelse return std.fmt.allocPrint(alloc, "Error: missing 'query' argument", .{}) catch null;
    const r = results() orelse return null;
    defer release(r);
    recall.search(query, r, .{ .moments = true });
    if (r.doc_count == 0 and r.moment_count == 0) {
        if (r.indexed_docs == 0) return std.fmt.allocPrint(alloc, "Your library index is still empty or building.", .{}) catch null;
        return std.fmt.allocPrint(alloc, "Nothing in your library matches that.", .{}) catch null;
    }
    const buf = alloc.alloc(u8, RESULT_MAX) catch return null;
    var w = std.Io.Writer.fixed(buf);
    var summary: [160]u8 = undefined;
    const desc = pure.describe(&r.parsed.constraints, &summary);
    if (r.doc_count > 0) {
        w.print("From your library{s}{s}{s}:\n", .{ if (desc.len > 0) " (" else "", desc, if (desc.len > 0) ")" else "" }) catch {};
        for (r.docs[0..@min(r.doc_count, 6)], 0..) |*d, i| {
            w.print("{d}. {s} [{s}", .{ i + 1, d.titleText(), @tagName(d.kind) }) catch {};
            if (d.year > 0) w.print(", {d}", .{d.year}) catch {};
            if (d.runtime_secs >= 60) w.print(", {d} min", .{d.runtime_secs / 60}) catch {};
            if (d.percent >= pure.WATCHED_PCT) w.writeAll(", watched") catch {} else if (d.percent >= pure.STARTED_PCT) w.print(", {d:.0}% watched", .{d.percent}) catch {};
            w.writeAll("]\n") catch {};
        }
    }
    if (r.moment_count > 0) {
        w.writeAll("Moments:\n") catch {};
        for (r.moments[0..@min(r.moment_count, 3)]) |*m| {
            var clock: [24]u8 = undefined;
            w.print("- {s} at {s}: \"{s}\"\n", .{ m.titleText(), pure.formatClock(m.start_secs, &clock), pure.utf8Prefix(m.snippetText(), 160) }) catch {};
        }
    }
    const used = w.end;
    return alloc.realloc(buf, used) catch {
        alloc.free(buf);
        return null;
    };
}

pub fn findMoment(alloc: std.mem.Allocator, query_arg: ?[]const u8) ?[]u8 {
    const query = query_arg orelse return std.fmt.allocPrint(alloc, "Error: missing 'query' argument", .{}) catch null;
    const r = results() orelse return null;
    defer release(r);
    recall.search(query, r, .{ .moments = true });
    if (r.moment_count == 0) {
        if (r.indexed_moments == 0) return std.fmt.allocPrint(alloc, "No subtitles are indexed yet, so I can't search inside your media.", .{}) catch null;
        return std.fmt.allocPrint(alloc, "I couldn't find that moment in your subtitles.", .{}) catch null;
    }
    const m = &r.moments[0];
    var clock: [24]u8 = undefined;
    const at = pure.formatClock(m.start_secs, &clock);
    const t = recall.target(0, m.id) orelse return std.fmt.allocPrint(alloc, "That moment is no longer in your library.", .{}) catch null;
    if (!recall.play(&t)) return std.fmt.allocPrint(alloc, "Found it in {s} at {s}, but it has to be opened from its page.", .{ m.titleText(), at }) catch null;
    return std.fmt.allocPrint(alloc, "Playing {s} at {s}: \"{s}\"", .{ m.titleText(), at, pure.utf8Prefix(m.snippetText(), 200) }) catch null;
}
