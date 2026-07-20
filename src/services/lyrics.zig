//! Synced lyrics fetcher (lrclib.net) — the non-pure half of lyrics_pure.zig.
//!
//! Owns the detached fetch worker, the parsed timeline, and its thread safety.
//! One track's lyrics at a time: `requestFor` is a no-op while a fetch is in
//! flight or when the requested track already matches `loaded_key`, so the UI
//! can call it every frame without hammering the API.
//!
//! lrclib is keyless and rate-friendly; a miss (404 / instrumental) is a normal
//! outcome and simply leaves the timeline empty — callers render nothing.

const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const alloc = @import("../core/alloc.zig").allocator;
const sync = @import("../core/sync.zig");
const pure = @import("lyrics_pure.zig");
const rf = @import("reliable_fetch.zig");

pub const LyricLine = pure.LyricLine;

/// A long song is ~120 lines; 400 covers even karaoke-style word dumps.
const MAX_LINES = 400;
/// lrclib bodies are small JSON; 512KB is generous and heap-allocated anyway.
const RESP_CAP = 512 * 1024;

const agent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

// ── Shared timeline (mutex-guarded; UI thread reads, worker writes) ──
var mutex: sync.Mutex = .{};
var lines: [MAX_LINES]pure.LyricLine = undefined;
var line_count: usize = 0;

var fetching: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// "artist\x1ftitle" of the track whose fetch has been issued — guards against
/// refetching the same song (including a miss) every frame.
var loaded_key: [320]u8 = std.mem.zeroes([320]u8);
var loaded_key_len: usize = 0;

fn keyInto(out: []u8, artist: []const u8, title: []const u8) []const u8 {
    return std.fmt.bufPrint(out, "{s}\x1f{s}", .{ artist, title }) catch out[0..0];
}

// ══════════════════════════════════════════════════════════
// Public API
// ══════════════════════════════════════════════════════════

/// Fetch synced lyrics for a track, unless the same track is already loaded or
/// a fetch is in flight. Safe to call every frame. UI thread.
pub fn requestFor(artist: []const u8, title: []const u8, album: []const u8, duration_secs: u32) void {
    if (artist.len == 0 or title.len == 0) return;
    if (fetching.load(.acquire)) return;

    var kbuf: [320]u8 = undefined;
    const key = keyInto(&kbuf, artist, title);
    if (key.len == 0) return;

    mutex.lock();
    const same = std.mem.eql(u8, key, loaded_key[0..loaded_key_len]);
    mutex.unlock();
    if (same) return;

    const S = struct {
        var artist_buf: [160]u8 = undefined;
        var artist_len: usize = 0;
        var title_buf: [200]u8 = undefined;
        var title_len: usize = 0;
        var album_buf: [160]u8 = undefined;
        var album_len: usize = 0;
        var duration: u32 = 0;

        fn worker() void {
            const Self = @This();
            defer fetching.store(false, .release);

            const a = Self.artist_buf[0..Self.artist_len];
            const t = Self.title_buf[0..Self.title_len];
            const al = Self.album_buf[0..Self.album_len];

            var url_buf: [1024]u8 = undefined;
            const url = pure.buildLrclibUrl(a, t, al, Self.duration, &url_buf) orelse return;

            // >64KB must never live on a spawned thread's stack (macOS: 512KB).
            const body_buf = alloc.alloc(u8, RESP_CAP) catch return;
            defer alloc.free(body_buf);

            var body: ?[]const u8 = rf.fetch(url, body_buf, .{
                .user_agent = agent,
                .timeout_secs = 12,
                .impersonate = false, // plain JSON API, not fingerprint-walled
            });

            // Exact match missed (404 / empty) → fuzzy "artist title" search.
            var have_synced = false;
            const lrc_buf = alloc.alloc(u8, 128 * 1024) catch return;
            defer alloc.free(lrc_buf);
            var lrc: []const u8 = "";

            if (body) |b| {
                if (pure.extractSyncedLyrics(b, lrc_buf)) |s| {
                    lrc = s;
                    have_synced = true;
                }
            }

            if (!have_synced) {
                var qbuf: [400]u8 = undefined;
                const q = std.fmt.bufPrint(&qbuf, "{s} {s}", .{ a, t }) catch "";
                if (q.len > 0) {
                    if (pure.buildLrclibSearchUrl(q, &url_buf)) |surl| {
                        body = rf.fetch(surl, body_buf, .{
                            .user_agent = agent,
                            .timeout_secs = 12,
                            .impersonate = false,
                        });
                        // The search returns an array; the first object carrying a
                        // non-null syncedLyrics is the best available match.
                        if (body) |b| {
                            if (pure.extractSyncedLyrics(b, lrc_buf)) |s| {
                                lrc = s;
                                have_synced = true;
                            }
                        }
                    }
                }
            }

            var parsed: usize = 0;
            var scratch: [MAX_LINES]pure.LyricLine = undefined;
            if (have_synced and lrc.len > 0) parsed = pure.parseLrc(lrc, &scratch);

            mutex.lock();
            var i: usize = 0;
            while (i < parsed) : (i += 1) lines[i] = scratch[i];
            line_count = parsed;
            var kb: [320]u8 = undefined;
            const k = keyInto(&kb, a, t);
            const klen = @min(k.len, loaded_key.len);
            @memcpy(loaded_key[0..klen], k[0..klen]);
            loaded_key_len = klen;
            mutex.unlock();

            if (parsed > 0) {
                logs.pushLog("info", "lyrics", "Synced lyrics loaded", false);
            } else {
                logs.pushLog("info", "lyrics", "No synced lyrics found", false);
            }
            if (state.app.dvui_win) |win| dvui.refresh(win, @src(), null);
        }
    };

    // Copy every input into the statics BEFORE spawning.
    S.artist_len = @min(artist.len, S.artist_buf.len);
    @memcpy(S.artist_buf[0..S.artist_len], artist[0..S.artist_len]);
    S.title_len = @min(title.len, S.title_buf.len);
    @memcpy(S.title_buf[0..S.title_len], title[0..S.title_len]);
    S.album_len = @min(album.len, S.album_buf.len);
    @memcpy(S.album_buf[0..S.album_len], album[0..S.album_len]);
    S.duration = duration_secs;

    fetching.store(true, .release);
    if (std.Thread.spawn(.{}, S.worker, .{})) |th| {
        th.detach(); // never joined — detach to avoid leaking the handle
    } else |_| {
        fetching.store(false, .release);
    }
}

/// Index of the line that should be highlighted at `pos_ms`, or null.
pub fn currentIndex(pos_ms: u32) ?usize {
    mutex.lock();
    defer mutex.unlock();
    return pure.activeLineAt(lines[0..line_count], pos_ms);
}

/// Copy the timeline into caller storage; returns the number of lines written.
pub fn snapshot(out: []pure.LyricLine) usize {
    mutex.lock();
    defer mutex.unlock();
    const n = @min(line_count, out.len);
    var i: usize = 0;
    while (i < n) : (i += 1) out[i] = lines[i];
    return n;
}

/// Drop the timeline and the loaded-track key (call when the track changes).
pub fn clear() void {
    mutex.lock();
    defer mutex.unlock();
    line_count = 0;
    loaded_key_len = 0;
}

pub fn hasLyrics() bool {
    mutex.lock();
    defer mutex.unlock();
    return line_count > 0;
}

/// True while a fetch is in flight — lets the UI show a quiet placeholder.
pub fn isFetching() bool {
    return fetching.load(.acquire);
}
