//! Live TV programme guide + channel actions over HTTP (web UI and automation).
//!
//!   GET  /livetv?q=&offset=&view=       catalog page with now/next, health, favorite
//!   GET  /livetv/guide                 guide status, redacted source, mappings
//!   POST /livetv/guide/import          source=<url or path>   (host admin)
//!   POST /livetv/guide/refresh                                (host admin)
//!   POST /livetv/guide/clear           confirm=1              (host admin)
//!   GET  /livetv/guide/channels?q=     guide channels, for mapping
//!   GET  /livetv/programmes?q=         programme search (upcoming + on air)
//!   GET  /livetv/nownext?chan_id=&name=
//!   POST /livetv/map                   channel=<name> [chan_id=] guide_id= | key= (remove)
//!   POST /livetv/favorite              url=<catalog stream url>
//!   POST /livetv/play                  url=<catalog stream url>
//!
//! Import/refresh/clear make the host fetch a URL or read a file, so
//! access_pure lists them as host-administration routes. Play and favourite
//! resolve the channel from the catalog by URL, so per-channel request headers
//! come from the playlist, never from the caller. Times are UTC epoch seconds;
//! clients render them in their own time zone.

const std = @import("std");
const wire = @import("remote_http.zig");
const epg = @import("epg.zig");
const epg_pure = @import("epg_pure.zig");
const ipure = @import("iptv_pure.zig");
const io = @import("../core/io_global.zig");
const state = @import("../core/state.zig");
const alloc = @import("../core/alloc.zig").allocator;

pub fn handle(stream: std.Io.net.Stream, method: []const u8, path: []const u8, query: []const u8, body: []const u8) bool {
    if (std.mem.eql(u8, path, "/livetv")) {
        apiLiveTv(stream, query);
        return true;
    }
    if (std.mem.eql(u8, path, "/livetv/guide")) {
        epg.tick();
        if (wire.requireMethod(stream, method, "GET")) status(stream);
        return true;
    }
    if (std.mem.eql(u8, path, "/livetv/guide/import")) {
        if (wire.requireMethod(stream, method, "POST")) importGuide(stream, query, body);
        return true;
    }
    if (std.mem.eql(u8, path, "/livetv/guide/refresh")) {
        if (wire.requireMethod(stream, method, "POST")) {
            if (epg.refresh()) |_| wire.sendJson(stream, "{\"ok\":true}") else |err| sendImportError(stream, err);
        }
        return true;
    }
    if (std.mem.eql(u8, path, "/livetv/guide/clear")) {
        if (wire.requireMethod(stream, method, "POST")) {
            var cb: [8]u8 = undefined;
            if (!std.mem.eql(u8, wire.formParam(body, query, "confirm", &cb) orelse "", "1")) {
                wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"clear requires confirm=1\"}");
            } else {
                epg.clearGuide();
                wire.sendJson(stream, "{\"ok\":true}");
            }
        }
        return true;
    }
    if (std.mem.eql(u8, path, "/livetv/guide/channels")) {
        if (wire.requireMethod(stream, method, "GET")) guideChannels(stream, query);
        return true;
    }
    if (std.mem.eql(u8, path, "/livetv/programmes")) {
        epg.tick();
        if (wire.requireMethod(stream, method, "GET")) programmes(stream, query);
        return true;
    }
    if (std.mem.eql(u8, path, "/livetv/nownext")) {
        if (wire.requireMethod(stream, method, "GET")) nowNext(stream, query);
        return true;
    }
    if (std.mem.eql(u8, path, "/livetv/map")) {
        if (wire.requireMethod(stream, method, "POST")) map(stream, query, body);
        return true;
    }
    if (std.mem.eql(u8, path, "/livetv/favorite")) {
        if (wire.requireMethod(stream, method, "POST")) favorite(stream, query, body);
        return true;
    }
    if (std.mem.eql(u8, path, "/livetv/play")) {
        if (wire.requireMethod(stream, method, "POST")) play(stream, query, body);
        return true;
    }
    return false;
}

/// Live TV / IPTV: page the SQLite channel catalog.
/// GET /api/livetv?q=&country=&category=&offset=&view= → {total,offset,channels:[…]}
/// Adult channels follow the app's NSFW filter, exactly like the desktop tab.
/// view=favorites|recent reads the saved lists (one bounded page) instead of
/// the catalog. Each row carries chan_id, favorite, health and now/next.
/// The page is heap-allocated: IptvChannel is ~1.6 KB, so a stack array would
/// blow the 64 KB spawned-thread budget (see CLAUDE.md thread rules).
fn apiLiveTv(stream: std.Io.net.Stream, query: []const u8) void {
    const cat = @import("iptv_catalog.zig");
    const store = @import("iptv_store.zig");
    const iptv = @import("iptv.zig");

    var qbuf: [128]u8 = undefined;
    var cbuf: [64]u8 = undefined;
    var gbuf: [64]u8 = undefined;
    const text = if (wire.queryParam(query, "q")) |v| (wire.urlDecode(v, &qbuf) orelse v) else "";
    const country = if (wire.queryParam(query, "country")) |v| (wire.urlDecode(v, &cbuf) orelse v) else "";
    const category = if (wire.queryParam(query, "category")) |v| (wire.urlDecode(v, &gbuf) orelse v) else "";
    const offset: usize = if (wire.queryParam(query, "offset")) |v| (std.fmt.parseInt(usize, v, 10) catch 0) else 0;
    const q: cat.Query = .{
        .text = text,
        .country = country,
        .category = category,
        .nsfw_allowed = !state.app.nsfw_filter_enabled,
    };

    const PAGE = 50;
    const rows = alloc.alloc(ipure.IptvChannel, PAGE) catch {
        wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(rows);
    const view = wire.queryParam(query, "view") orelse "";
    const saved: ?store.Kind = if (std.mem.eql(u8, view, "favorites")) .fav else if (std.mem.eql(u8, view, "recent")) .recent else null;
    const n = if (saved) |kind| (if (offset == 0) store.loadInto(kind, rows) else 0) else cat.queryPage(rows, offset, q);
    const total = if (saved != null) n else cat.count(q);
    epg.tick();
    const now = io.timestamp();

    const json_buf = alloc.alloc(u8, 192 * 1024) catch {
        wire.sendJsonStatus(stream, "503 Service Unavailable", "{\"error\":\"channel catalog unavailable\"}");
        return;
    };
    defer alloc.free(json_buf);
    var w = std.Io.Writer.fixed(json_buf);
    w.print("{{\"total\":{d},\"offset\":{d},\"channels\":[", .{ total, offset }) catch return;
    for (rows[0..n], 0..) |ch, i| {
        if (i > 0) w.writeAll(",") catch return;
        const fields = [_]struct { []const u8, []const u8 }{
            .{ "name", ch.name[0..ch.name_len] },         .{ "url", ch.url[0..ch.url_len] },
            .{ "quality", ch.quality[0..ch.quality_len] }, .{ "logo", ch.logo[0..ch.logo_len] },
            .{ "country", ch.country[0..ch.country_len] }, .{ "category", ch.category[0..ch.category_len] },
            .{ "chan_id", ch.chan_id[0..ch.chan_id_len] },
        };
        w.writeAll("{") catch return;
        for (fields) |f| {
            w.print("\"{s}\":\"", .{f[0]}) catch return;
            wire.writeJsonString(&w, f[1]);
            w.writeAll("\",") catch return;
        }
        const url = ch.url[0..ch.url_len];
        w.print("\"favorite\":{s},\"health\":\"{s}\",", .{
            if (store.isFavorite(url)) "true" else "false",
            @tagName(iptv.channelHealth(url)),
        }) catch return;
        writeNowNext(&w, epg.nowNextFor(&ch, now));
        w.writeAll("}") catch return;
    }
    w.writeAll("]}") catch return;
    wire.sendJson(stream, json_buf[0..w.end]);
}

fn sendImportError(stream: std.Io.net.Stream, err: epg.ImportError) void {
    switch (err) {
        error.InvalidSource => wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"source must be an http(s) URL or an absolute file path\"}"),
        error.Busy => wire.sendJsonStatus(stream, "409 Conflict", "{\"error\":\"an import is already running\"}"),
        error.SpawnFailed => wire.sendJsonStatus(stream, "503 Service Unavailable", "{\"error\":\"could not start the import\"}"),
    }
}

fn importGuide(stream: std.Io.net.Stream, query: []const u8, body: []const u8) void {
    var sb: [1024]u8 = undefined;
    const src = wire.formParam(body, query, "source", &sb) orelse "";
    if (epg.importSource(src)) |_| {
        wire.sendJsonStatus(stream, "202 Accepted", "{\"ok\":true,\"importing\":true}");
    } else |err| sendImportError(stream, err);
}

/// Shared JSON shape for one now/next slot.
pub fn writeSlot(w: *std.Io.Writer, slot: epg.Slot) void {
    w.writeAll("{\"title\":\"") catch return;
    wire.writeJsonString(w, slot.titleSlice());
    w.print("\",\"start\":{d},\"stop\":{d}}}", .{ slot.start, slot.stop }) catch return;
}

/// `"now":{…}|null,"next":{…}|null` for a channel (no leading comma).
pub fn writeNowNext(w: *std.Io.Writer, info: ?epg.NowNextInfo) void {
    const now_slot: ?epg.Slot = if (info) |i| i.now else null;
    const next_slot: ?epg.Slot = if (info) |i| i.next else null;
    w.writeAll("\"now\":") catch return;
    if (now_slot) |s| writeSlot(w, s) else w.writeAll("null") catch return;
    w.writeAll(",\"next\":") catch return;
    if (next_slot) |s| writeSlot(w, s) else w.writeAll("null") catch return;
    w.writeAll(",\"guide_id\":\"") catch return;
    if (info) |i| wire.writeJsonString(w, i.guideIdSlice());
    w.writeAll("\"") catch return;
}

fn status(stream: std.Io.net.Stream) void {
    const st = epg.status();
    const buf = alloc.alloc(u8, 64 * 1024) catch return wire.sendJsonStatus(stream, "503 Service Unavailable", "{\"error\":\"out of memory\"}");
    defer alloc.free(buf);
    var w = std.Io.Writer.fixed(buf);
    var src_buf: [1024]u8 = undefined;
    var red_buf: [1100]u8 = undefined;
    const source = epg_pure.redactSource(epg.sourceText(&src_buf), &red_buf);
    w.print("{{\"enabled\":{s},\"importing\":{s},\"source\":\"", .{ if (st.enabled) "true" else "false", if (st.importing) "true" else "false" }) catch return;
    wire.writeJsonString(&w, source);
    w.print("\",\"channels\":{d},\"programmes\":{d},\"malformed\":{d},\"dropped\":{d},\"fetched_at\":{d},\"latest_stop\":{d},\"freshness\":\"{s}\",\"freshness_label\":\"{s}\",\"error\":\"", .{
        st.channels, st.programmes, st.malformed, st.dropped, st.fetched_at, st.latest_stop, @tagName(st.freshness), st.freshness.label(),
    }) catch return;
    wire.writeJsonString(&w, st.errSlice());
    w.writeAll("\",\"mappings\":[") catch return;
    const rows = alloc.alloc(epg.Mapping, epg.MAX_MAPPINGS) catch return;
    defer alloc.free(rows);
    const n = epg.mappings(rows);
    for (rows[0..n], 0..) |*m, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"key\":\"") catch return;
        wire.writeJsonString(&w, m.keySlice());
        w.writeAll("\",\"label\":\"") catch return;
        wire.writeJsonString(&w, m.labelSlice());
        w.writeAll("\",\"guide_id\":\"") catch return;
        wire.writeJsonString(&w, m.guideSlice());
        w.writeAll("\"}") catch return;
    }
    w.writeAll("]}") catch return;
    wire.sendJson(stream, buf[0..w.end]);
}

fn guideChannels(stream: std.Io.net.Stream, query: []const u8) void {
    var qb: [128]u8 = undefined;
    const q = if (wire.queryParam(query, "q")) |v| (wire.urlDecode(v, &qb) orelse "") else "";
    var hits: [50]epg.ChannelHit = undefined;
    const n = epg.guideChannels(q, &hits);
    var buf: [16 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.writeAll("{\"items\":[") catch return;
    for (hits[0..n], 0..) |*h, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"id\":\"") catch return;
        wire.writeJsonString(&w, h.idSlice());
        w.writeAll("\",\"name\":\"") catch return;
        wire.writeJsonString(&w, h.nameSlice());
        w.writeAll("\"}") catch return;
    }
    w.writeAll("]}") catch return;
    wire.sendJson(stream, buf[0..w.end]);
}

fn programmes(stream: std.Io.net.Stream, query: []const u8) void {
    var qb: [128]u8 = undefined;
    const q = if (wire.queryParam(query, "q")) |v| (wire.urlDecode(v, &qb) orelse "") else "";
    const hits = alloc.alloc(epg.Hit, 40) catch return wire.sendJsonStatus(stream, "503 Service Unavailable", "{\"error\":\"out of memory\"}");
    defer alloc.free(hits);
    const now = io.timestamp();
    const n = epg.search(q, now, hits);
    const buf = alloc.alloc(u8, 64 * 1024) catch return;
    defer alloc.free(buf);
    var w = std.Io.Writer.fixed(buf);
    w.print("{{\"now\":{d},\"items\":[", .{now}) catch return;
    for (hits[0..n], 0..) |*h, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"title\":\"") catch return;
        wire.writeJsonString(&w, h.slot.titleSlice());
        w.writeAll("\",\"desc\":\"") catch return;
        wire.writeJsonString(&w, h.descSlice());
        w.writeAll("\",\"channel_id\":\"") catch return;
        wire.writeJsonString(&w, h.chanIdSlice());
        w.writeAll("\",\"channel_name\":\"") catch return;
        wire.writeJsonString(&w, h.chanNameSlice());
        w.print("\",\"start\":{d},\"stop\":{d},\"on_air\":{s}", .{ h.slot.start, h.slot.stop, if (h.slot.start <= now and now < h.slot.stop) "true" else "false" }) catch return;
        // The playable catalog channel for this programme, when one exists.
        const nsfw_allowed = !state.app.nsfw_filter_enabled;
        w.writeAll(",\"url\":\"") catch return;
        if (@import("iptv_catalog.zig").findByChanId(h.chanIdSlice(), nsfw_allowed)) |row| wire.writeJsonString(&w, row.url[0..row.url_len]);
        w.writeAll("\"}") catch return;
    }
    w.writeAll("]}") catch return;
    wire.sendJson(stream, buf[0..w.end]);
}

fn nowNext(stream: std.Io.net.Stream, query: []const u8) void {
    var ib: [64]u8 = undefined;
    var nb: [160]u8 = undefined;
    const chan_id = if (wire.queryParam(query, "chan_id")) |v| (wire.urlDecode(v, &ib) orelse "") else "";
    const name = if (wire.queryParam(query, "name")) |v| (wire.urlDecode(v, &nb) orelse "") else "";
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.writeAll("{") catch return;
    writeNowNext(&w, epg.nowNext(chan_id, name, io.timestamp()));
    w.writeAll("}") catch return;
    wire.sendJson(stream, buf[0..w.end]);
}

fn map(stream: std.Io.net.Stream, query: []const u8, body: []const u8) void {
    var kb: [100]u8 = undefined;
    if (wire.formParam(body, query, "key", &kb)) |key| {
        if (key.len > 0) {
            if (epg.removeMappingKey(key)) wire.sendJson(stream, "{\"ok\":true}") else wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"could not remove mapping\"}");
            return;
        }
    }
    var cb: [160]u8 = undefined;
    var ib: [64]u8 = undefined;
    var gb: [96]u8 = undefined;
    const name = wire.formParam(body, query, "channel", &cb) orelse "";
    const chan_id = wire.formParam(body, query, "chan_id", &ib) orelse "";
    const guide_id = wire.formParam(body, query, "guide_id", &gb) orelse "";
    if (name.len == 0 and chan_id.len == 0) {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"channel or chan_id required\"}");
        return;
    }
    if (!epg.setMapping(chan_id, name, guide_id, if (name.len > 0) name else chan_id)) {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"could not save mapping\"}");
        return;
    }
    wire.sendJson(stream, "{\"ok\":true}");
}

fn catalogRow(stream: std.Io.net.Stream, query: []const u8, body: []const u8) ?ipure.IptvChannel {
    var ub: [1024]u8 = undefined;
    const url = wire.formParam(body, query, "url", &ub) orelse "";
    if (url.len == 0) {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"url required\"}");
        return null;
    }
    const row = @import("iptv_catalog.zig").findByUrl(url) orelse {
        wire.sendJsonStatus(stream, "404 Not Found", "{\"error\":\"channel not in the catalog\"}");
        return null;
    };
    return row;
}

fn favorite(stream: std.Io.net.Stream, query: []const u8, body: []const u8) void {
    const row = catalogRow(stream, query, body) orelse return;
    const now_fav = @import("iptv_store.zig").toggleFavorite(&row);
    @import("iptv.zig").noteFavoritesChanged();
    wire.sendJson(stream, if (now_fav) "{\"ok\":true,\"favorite\":true}" else "{\"ok\":true,\"favorite\":false}");
}

fn play(stream: std.Io.net.Stream, query: []const u8, body: []const u8) void {
    const row = catalogRow(stream, query, body) orelse return;
    const url = row.url[0..row.url_len];
    if (@import("iptv.zig").channelHealth(url) == .dead) {
        wire.sendJsonStatus(stream, "409 Conflict", "{\"error\":\"channel is offline\",\"health\":\"dead\"}");
        return;
    }
    if (!@import("forwarded_open.zig").pushLiveTv(url, row.name[0..row.name_len])) {
        wire.sendJsonStatus(stream, "503 Service Unavailable", "{\"error\":\"player queue is busy\"}");
        return;
    }
    wire.sendJson(stream, "{\"ok\":true}");
}
