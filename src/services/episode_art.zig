//! Bounded, session-local episode previews. Stable slots outlive all workers;
//! metadata is published atomically and image bytes use the shared disk cache.
const std = @import("std");
const state = @import("../core/state.zig");
const workers = @import("../core/workers.zig");
const pure = @import("episode_art_pure.zig");
const tp = @import("tv_pure.zig");

pub const Slot = struct {
    id: i32 = 0,
    ep: tp.Ep = .{},
    ready: std.atomic.Value(bool) = .init(false),
    metadata: pure.Metadata = .{},
    image: state.TmdbItem = .{},
};
var slots: [64]Slot = [_]Slot{.{}} ** 64;
var busy: std.atomic.Value(bool) = .init(false);

/// UI-thread only. At most one metadata request runs at a time. No slot reuse:
/// an image worker can never publish into a different episode after advancing.
pub fn get(id: i32, ep: tp.Ep, name: []const u8) ?*Slot {
    for (&slots) |*slot| {
        if (slot.id == id and slot.ep.eql(ep)) return slot;
    }
    if (id == 0 or !state.app.config_loaded.load(.acquire)) return null;
    if (busy.swap(true, .acq_rel)) return null;
    for (&slots) |*slot| {
        if (slot.id != 0) continue;
        slot.id = id;
        slot.ep = ep;
        var title: [128]u8 = .{0} ** 128;
        const len = @min(name.len, title.len);
        @memcpy(title[0..len], name[0..len]);
        workers.spawn(fetch, .{ slot, state.app.tmdb.api_key, state.app.tmdb.api_key_len, title, len }) catch {
            slot.id = 0;
            busy.store(false, .release);
            return null;
        };
        return slot;
    }
    busy.store(false, .release);
    return null;
}

fn fetch(slot: *Slot, key: @TypeOf(state.app.tmdb.api_key), key_len: usize, title: [128]u8, title_len: usize) void {
    defer {
        slot.ready.store(true, .release);
        busy.store(false, .release);
        state.wakeUi();
    }
    const allocator = @import("../core/alloc.zig").allocator;
    const body = allocator.alloc(u8, 8 * 1024 * 1024) catch return;
    defer allocator.free(body);
    var path_buf: [640]u8 = undefined;
    const api = @import("tmdb_api.zig");
    if (slot.id > 0 and key_len > 0) {
        const path = std.fmt.bufPrint(&path_buf, "/3/tv/{d}/season/{d}/episode/{d}", .{ slot.id, slot.ep.season, slot.ep.episode }) catch return;
        const n = api.tmdbApiInto(path, key[0..key_len], body);
        if (workers.isQuitting()) return;
        if (n > 0) {
            slot.metadata = pure.parse(allocator, body[0..n], slot.ep.season, slot.ep.episode) catch .{};
            if (slot.metadata.url_len > 0) return;
        }
    }
    const db = @import("../core/db.zig");
    var imdb_buf: [16]u8 = undefined;
    var imdb = db.tvImdbId(slot.id, &imdb_buf);
    if (imdb.len == 0) {
        var encoded: [512]u8 = undefined;
        const q = @import("../core/http.zig").urlEncode(title[0..title_len], &encoded);
        const search = std.fmt.bufPrint(&path_buf, "/catalog/series/top/search={s}.json", .{q}) catch return;
        const n = api.cinemetaApiInto(search, body);
        if (workers.isQuitting() or n == 0) return;
        imdb = pure.findImdb(allocator, body[0..n], slot.id, &imdb_buf) catch return;
        if (imdb.len == 0) return;
        db.tvRememberImdb(slot.id, imdb);
    }
    const path = std.fmt.bufPrint(&path_buf, "/meta/series/{s}.json", .{imdb}) catch return;
    const n = api.cinemetaApiInto(path, body);
    if (workers.isQuitting() or n == 0) return;
    const fallback = pure.parseCinemeta(allocator, body[0..n], slot.ep.season, slot.ep.episode) catch return;
    if (fallback.url_len > 0) {
        const runtime = slot.metadata.runtime_secs;
        slot.metadata = fallback;
        slot.metadata.runtime_secs = runtime;
    }
}

/// Called only after the worker barrier, before the window is destroyed.
pub fn deinit() void {
    for (&slots) |*slot| {
        if (comptime !@import("build_options").headless) {
            if (slot.image.poster_tex) |tex| {
                if (state.app.dvui_win) |win| win.backend.textureDestroy(tex);
            }
        }
        if (slot.image.poster_pixels) |pixels| std.heap.c_allocator.free(pixels);
        slot.image.poster_pixels = null;
        slot.image.poster_tex = null;
    }
}
