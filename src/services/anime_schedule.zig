//! Anime airing-schedule service — the "Airing this week" view inside the Anime
//! tab. Fetches AniList's `Page.airingSchedules` for the current 7-day window off
//! the UI thread and publishes it into the shared `state.app.anime.sched[]`
//! fixed buffers under a mutex + atomic loading flag. Clicking a scheduled show
//! kicks a universal search for its title so the user can find a stream.
//!
//! All parse / window / weekday / clock logic lives in anime_schedule_pure.zig
//! (tested); this file is just the fetch worker + publish + click routing.

const std = @import("std");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const io = @import("../core/io_global.zig");
const db = @import("../core/db.zig");
const pure = @import("anime_schedule_pure.zig");
const alloc = @import("../core/alloc.zig").allocator;

const ANILIST_API = "https://graphql.anilist.co";

/// Serializes the publish into state.app.anime.sched[] against the UI thread's
/// reads (same convention as anime.zig's parse mutex).
var parse_mutex: @import("../core/sync.zig").Mutex = .{};

/// Prevents a second worker while one is in flight (belt-and-braces with the
/// atomic sched_loading flag: the flag gates the public entry, this guards the
/// detached spawn).
var busy: bool = false;

/// Kick a one-shot schedule fetch. No-op if already loaded or a fetch is in
/// flight. `refresh()` clears `sched_loaded` to force a re-fetch.
pub fn loadSchedule() void {
    if (state.app.anime.sched_loaded) return;
    if (state.app.anime.sched_loading.load(.acquire)) return;
    if (busy) return;
    busy = true;
    state.app.anime.sched_loading.store(true, .release);
    if (std.Thread.spawn(.{}, worker, .{})) |t| {
        t.detach();
    } else |_| {
        state.app.anime.sched_loading.store(false, .release);
        busy = false;
    }
}

/// Drop the cache so the next `loadSchedule()` refetches (the Airing view's
/// refresh button).
pub fn refresh() void {
    state.app.anime.sched_loaded = false;
}

/// Local UTC offset in seconds via SQLite (Zig 0.16 std.time is UTC-only; the
/// linked SQLite gets timezones right — same trick as home.zig's localHour).
fn localTzOffset() i64 {
    const stmt = db.prepare("SELECT strftime('%s','now','localtime') - strftime('%s','now')") orelse return 0;
    defer db.finalize(stmt);
    if (db.step(stmt) == db.c.SQLITE_ROW) return db.columnInt64(stmt, 0);
    return 0;
}

fn worker() void {
    defer {
        state.app.anime.sched_loading.store(false, .release);
        busy = false;
    }

    const now = io.timestamp();
    const tz = localTzOffset();
    const window = pure.weekWindow(now, tz);

    var gql_buf: [640]u8 = undefined;
    const gql = pure.buildQuery(window, &gql_buf);
    if (gql.len == 0) return;

    // Heap fetch buffer — never a >64 KB buffer on the worker stack (CLAUDE.md).
    const buf = alloc.alloc(u8, 512 * 1024) catch return;
    defer alloc.free(buf);

    var child = io.Child.init(&.{
        "curl",   "-s",                             "--max-time", "15",
        "-X",     "POST",                           ANILIST_API,  "-H",
        "Content-Type: application/json",           "-H",         "Accept: application/json",
        "-d",     gql,
    }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        logs.pushLog("error", "anime", "Airing schedule: curl failed", true);
        return;
    };
    const bytes = if (child.stdout) |*s| io.readAll(s, buf) catch 0 else 0;
    _ = child.wait() catch {};
    if (bytes < 16) {
        logs.pushLog("error", "anime", "Airing schedule: empty response", true);
        return;
    }

    // Parse into a heap temp (Slot is ~272 B; 60 of them ≈ 16 KB — heap, not the
    // worker stack), then publish under the mutex.
    const tmp = alloc.alloc(pure.Slot, state.app.anime.sched.len) catch return;
    defer alloc.free(tmp);
    const n = pure.parseInto(buf[0..bytes], tmp);

    parse_mutex.lock();
    defer parse_mutex.unlock();
    var i: usize = 0;
    while (i < n) : (i += 1) state.app.anime.sched[i] = tmp[i];
    state.app.anime.sched_count = n;
    state.app.anime.sched_window_start = window.start;
    state.app.anime.sched_tz_offset_s = tz;
    state.app.anime.sched_loaded = true;

    var lb: [64]u8 = undefined;
    logs.pushLog("info", "anime", std.fmt.bufPrint(&lb, "Airing this week: {d} episodes", .{n}) catch "Airing schedule ready", false);
    state.wakeUi();
}

/// Click a scheduled show → universal search for its title so the user can find a
/// stream (same navigate + submitQuery pattern as tmdb.zig's "search all").
pub fn clickSlot(idx: usize) void {
    parse_mutex.lock();
    var title_buf: [128]u8 = undefined;
    var title_len: usize = 0;
    if (idx < state.app.anime.sched_count) {
        const s = &state.app.anime.sched[idx];
        title_len = @min(s.title_len, title_buf.len);
        @memcpy(title_buf[0..title_len], s.title[0..title_len]);
    }
    parse_mutex.unlock();
    if (title_len == 0) return;
    state.navigateToTab(.Search);
    @import("search.zig").submitQuery(title_buf[0..title_len]);
    state.showToast("Searching all sources...");
}
