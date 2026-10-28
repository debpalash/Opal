//! /api/recall — semantic search over the user's own library and subtitles
//! (ROADMAP 7.1). Same auth as /api/search (handleApi's route gate). Items are
//! addressed by recall ids only; local paths and deep links never leave the
//! host.
//!
//!   GET  /recall?q=<text>              {"constraints":…,"docs":[…],"moments":[…]}
//!   POST /recall/play  doc=<id> | moment=<id>   play on the host (moment at its second)

const std = @import("std");
const wire = @import("remote_http.zig");
const recall = @import("recall.zig");
const pure = @import("recall_pure.zig");
const alloc = @import("../core/alloc.zig").allocator;

pub fn handle(stream: std.Io.net.Stream, method: []const u8, path: []const u8, query: []const u8, body: []const u8) bool {
    if (std.mem.eql(u8, path, "/recall")) {
        if (wire.requireMethod(stream, method, "GET")) searchRoute(stream, query);
        return true;
    }
    if (std.mem.eql(u8, path, "/recall/play")) {
        if (wire.requireMethod(stream, method, "POST")) playRoute(stream, query, body);
        return true;
    }
    return false;
}

fn searchRoute(stream: std.Io.net.Stream, query: []const u8) void {
    var q_buf: [1024]u8 = undefined;
    const raw = wire.queryParam(query, "q") orelse "";
    const text = if (raw.len == 0) "" else (wire.urlDecode(raw, &q_buf) orelse raw);
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"q required\"}");
        return;
    }
    if (text.len > 500) {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"query too long\"}");
        return;
    }
    const results = alloc.create(recall.Results) catch return sendOom(stream);
    defer alloc.destroy(results);
    recall.search(text, results, .{});
    const json = alloc.alloc(u8, 96 * 1024) catch return sendOom(stream);
    defer alloc.free(json);
    var w = std.Io.Writer.fixed(json);
    writeResults(&w, results) catch {
        wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"response too large\"}");
        return;
    };
    wire.sendJson(stream, w.buffered());
}

fn sendOom(stream: std.Io.net.Stream) void {
    wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
}

fn str(w: *std.Io.Writer, value: []const u8) !void {
    try w.writeByte('"');
    wire.writeJsonString(w, value);
    try w.writeByte('"');
}

pub fn writeResults(w: *std.Io.Writer, r: *const recall.Results) !void {
    const c = &r.parsed.constraints;
    var summary: [192]u8 = undefined;
    try w.writeAll("{\"query\":");
    try str(w, r.parsed.text());
    try w.print(",\"natural\":{},\"moment_intent\":{},\"fts\":{},\"vectors\":{},\"indexed\":{{\"docs\":{d},\"moments\":{d}}}", .{ r.parsed.natural, r.parsed.moment, r.fts, r.vectors, r.indexed_docs, r.indexed_moments });
    try w.writeAll(",\"constraints\":{\"kind\":");
    try str(w, if (c.kind == .any) "" else @tagName(c.kind));
    try w.print(",\"max_runtime_secs\":{d},\"min_runtime_secs\":{d},\"year_min\":{d},\"year_max\":{d},\"watch\":", .{ c.max_runtime_secs, c.min_runtime_secs, c.year_min, c.year_max });
    try str(w, if (c.watch == .any) "" else @tagName(c.watch));
    try w.writeAll(",\"like\":");
    try str(w, c.likeTitle());
    try w.writeAll(",\"lang\":");
    try str(w, c.langCode());
    try w.writeAll(",\"summary\":");
    try str(w, pure.describe(c, &summary));
    try w.writeAll("},\"terms\":[");
    for (r.termList(), 0..) |t, i| {
        if (i > 0) try w.writeByte(',');
        try str(w, t);
    }
    try w.writeAll("],\"docs\":[");
    for (r.docs[0..r.doc_count], 0..) |*d, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"id\":{d},\"kind\":", .{d.id});
        try str(w, @tagName(d.kind));
        try w.writeAll(",\"source\":");
        try str(w, d.source[0..d.source_len]);
        try w.writeAll(",\"title\":");
        try str(w, d.titleText());
        try w.print(",\"year\":{d},\"runtime_secs\":{d},\"percent\":{d:.1},\"favorite\":{},\"playable\":{},\"poster\":", .{ d.year, d.runtime_secs, d.percent, d.favorite, d.playable });
        try str(w, d.posterUrl());
        try w.writeAll(",\"snippet\":");
        try str(w, d.snippetText());
        try w.print(",\"score\":{d:.5}}}", .{d.score});
    }
    try w.writeAll("],\"moments\":[");
    for (r.moments[0..r.moment_count], 0..) |*m, i| {
        if (i > 0) try w.writeByte(',');
        var clock: [24]u8 = undefined;
        try w.print("{{\"id\":{d},\"doc_id\":{d},\"kind\":", .{ m.id, m.doc_id });
        try str(w, @tagName(m.kind));
        try w.writeAll(",\"title\":");
        try str(w, m.titleText());
        try w.print(",\"start_secs\":{d:.1},\"end_secs\":{d:.1},\"clock\":", .{ m.start_secs, m.end_secs });
        try str(w, pure.formatClock(m.start_secs, &clock));
        try w.writeAll(",\"snippet\":");
        try str(w, m.snippetText());
        try w.print(",\"score\":{d:.5}}}", .{m.score});
    }
    try w.writeAll("]}");
}

fn playRoute(stream: std.Io.net.Stream, query: []const u8, body: []const u8) void {
    const doc = std.fmt.parseInt(i64, wire.queryParam(body, "doc") orelse wire.queryParam(query, "doc") orelse "0", 10) catch 0;
    const moment = std.fmt.parseInt(i64, wire.queryParam(body, "moment") orelse wire.queryParam(query, "moment") orelse "0", 10) catch 0;
    if ((doc <= 0) == (moment <= 0)) {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"doc or moment id required\"}");
        return;
    }
    const t = recall.target(doc, moment) orelse {
        wire.sendJsonStatus(stream, "404 Not Found", "{\"error\":\"not in the recall index\"}");
        return;
    };
    if (!recall.play(&t)) {
        wire.sendJsonStatus(stream, "409 Conflict", "{\"error\":\"open this item in Opal\"}");
        return;
    }
    var buf: [96]u8 = undefined;
    const start = t.start_secs orelse -1;
    wire.sendJson(stream, std.fmt.bufPrint(&buf, "{{\"ok\":true,\"start_secs\":{d:.1}}}", .{start}) catch "{\"ok\":true}");
}
