const std = @import("std");
const state = @import("../core/state.zig");
const sync = @import("../core/sync.zig");
const workers = @import("../core/workers.zig");
const alloc = @import("../core/alloc.zig").allocator;
const pure = @import("youtube_player_pure.zig");

const Job = struct {
    id: [11]u8,
    target_address: usize,
    load_serial: u64,
};
const Publication = struct {
    target_address: usize = 0,
    load_serial: u64 = 0,
    success: bool = false,
    streams: pure.Streams = .{},
};

var publications: [8]Publication = undefined;
var publication_count: usize = 0;
var publication_mutex = sync.Mutex{};
var visitor_cache: [2048]u8 = undefined;
var visitor_cache_len: usize = 0;
var visitor_mutex = sync.Mutex{};

pub fn resolveAsync(url: []const u8, target: *@import("../player/player.zig").MediaPlayer, load_serial: u64) bool {
    const id = pure.videoId(url) orelse return false;
    var job: Job = .{ .id = undefined, .target_address = @intFromPtr(target), .load_serial = load_serial };
    @memcpy(&job.id, id);
    workers.spawn(resolveWorker, .{job}) catch return false;
    return true;
}

fn publish(job: Job, streams: ?pure.Streams) void {
    publication_mutex.lock();
    defer publication_mutex.unlock();
    if (publication_count == publications.len) {
        // Keep the newest completion under pathological multi-player bursts.
        std.mem.copyForwards(Publication, publications[0 .. publications.len - 1], publications[1..]);
        publication_count -= 1;
    }
    const publication = &publications[publication_count];
    publication_count += 1;
    publication.* = .{ .target_address = job.target_address, .load_serial = job.load_serial, .success = streams != null };
    if (streams) |resolved| publication.streams = resolved;
    state.wakeUi();
}

fn resolveWorker(job: Job) void {
    var visitor: [2048]u8 = undefined;
    var visitor_len: usize = 0;
    visitor_mutex.lock();
    if (visitor_cache_len > 0) {
        visitor_len = visitor_cache_len;
        @memcpy(visitor[0..visitor_len], visitor_cache[0..visitor_len]);
    }
    visitor_mutex.unlock();
    if (visitor_len == 0) {
        var watch_url_buf: [96]u8 = undefined;
        const watch_url = std.fmt.bufPrint(&watch_url_buf, "https://www.youtube.com/watch?v={s}", .{job.id}) catch {
            publish(job, null);
            return;
        };
        const watch_buf = alloc.alloc(u8, 2 * 1024 * 1024) catch {
            publish(job, null);
            return;
        };
        defer alloc.free(watch_buf);
        var attempt: usize = 0;
        while (attempt < 2 and visitor_len == 0) : (attempt += 1) {
            if (@import("reliable_fetch.zig").fetch(watch_url, watch_buf, .{
                .user_agent = @import("../player/playback_load_pure.zig").browser_user_agent,
                .timeout_secs = 6,
                .impersonate = false,
            })) |html| {
                if (pure.visitorData(html, &visitor)) |value| {
                    visitor_len = value.len;
                    visitor_mutex.lock();
                    visitor_cache_len = value.len;
                    @memcpy(visitor_cache[0..value.len], value);
                    visitor_mutex.unlock();
                }
            }
        }
    }

    var body_buf: [1024]u8 = undefined;
    const body = pure.buildVrPlayerBody(&job.id, &body_buf) orelse {
        publish(job, null);
        return;
    };
    const response = alloc.alloc(u8, 512 * 1024) catch {
        publish(job, null);
        return;
    };
    defer alloc.free(response);
    const headers_with_visitor = [_]@import("reliable_fetch.zig").Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "X-YouTube-Client-Name", .value = "28" },
        .{ .name = "X-YouTube-Client-Version", .value = pure.VR_CLIENT_VERSION },
        .{ .name = "X-Goog-Visitor-Id", .value = visitor[0..visitor_len] },
        .{ .name = "Origin", .value = "https://www.youtube.com" },
    };
    if (visitor_len > 0) {
        var attempt: usize = 0;
        while (attempt < 2) : (attempt += 1) {
            const payload = @import("reliable_fetch.zig").fetch(pure.PLAYER_URL, response, .{
                .user_agent = pure.VR_USER_AGENT,
                .headers = &headers_with_visitor,
                .timeout_secs = 6,
                .impersonate = false,
                .post_body = body,
            }) orelse continue;
            var streams: pure.Streams = .{};
            if (pure.parseStreams(alloc, payload, &streams)) {
                publish(job, streams);
                return;
            }
        }
        // A cached visitor token can eventually expire. Make the next click
        // refresh it instead of repeatedly reusing a rejected token.
        visitor_mutex.lock();
        visitor_cache_len = 0;
        visitor_mutex.unlock();
    }

    // Reliable last resort: the Android client exposes a combined 360p MP4
    // whose range contract needs no adapter. This still avoids a slow yt-dlp
    // process when the adaptive endpoint is temporarily unavailable.
    const fallback_body = pure.buildPlayerBody(&job.id, &body_buf) orelse return publish(job, null);
    const fallback_headers = [_]@import("reliable_fetch.zig").Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "X-YouTube-Client-Name", .value = "3" },
        .{ .name = "X-YouTube-Client-Version", .value = pure.CLIENT_VERSION },
        .{ .name = "Origin", .value = "https://www.youtube.com" },
    };
    if (@import("reliable_fetch.zig").fetch(pure.PLAYER_URL, response, .{
        .user_agent = pure.USER_AGENT,
        .headers = &fallback_headers,
        .timeout_secs = 6,
        .impersonate = false,
        .post_body = fallback_body,
    })) |payload| {
        var streams: pure.Streams = .{};
        if (pure.parseStreams(alloc, payload, &streams)) return publish(job, streams);
    }
    publish(job, null);
}

/// Apply worker output on the UI thread. Stale clicks and cancelled loads are
/// discarded by the same address + serial identity used by other resolvers.
pub fn drainResolved() void {
    var result: Publication = undefined;
    publication_mutex.lock();
    if (publication_count == 0) {
        publication_mutex.unlock();
        return;
    }
    result = publications[0];
    publication_count -= 1;
    if (publication_count > 0)
        std.mem.copyForwards(Publication, publications[0..publication_count], publications[1 .. publication_count + 1]);
    publication_mutex.unlock();

    const target: ?*@import("../player/player.zig").MediaPlayer = for (state.app.players.items) |p| {
        if (@intFromPtr(p) == result.target_address and p.load_serial == result.load_serial) break p;
    } else null;
    const p = target orelse return;
    if (result.success)
        p.commitYoutubeStreams(result.streams)
    else
        p.commitYoutubeFallback();
}
