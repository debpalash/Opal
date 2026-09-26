const std = @import("std");
const state = @import("../core/state.zig");
const sync = @import("../core/sync.zig");
const workers = @import("../core/workers.zig");
const alloc = @import("../core/alloc.zig").allocator;
const pure = @import("youtube_player_pure.zig");

const MAX_URL = 8192;
const Job = struct {
    id: [11]u8,
    target_address: usize,
    load_serial: u64,
};
const Publication = struct {
    target_address: usize = 0,
    load_serial: u64 = 0,
    success: bool = false,
    url: [MAX_URL]u8 = undefined,
    url_len: usize = 0,
};

var publications: [8]Publication = undefined;
var publication_count: usize = 0;
var publication_mutex = sync.Mutex{};

pub fn resolveAsync(url: []const u8, target: *@import("../player/player.zig").MediaPlayer, load_serial: u64) bool {
    const id = pure.videoId(url) orelse return false;
    var job: Job = .{ .id = undefined, .target_address = @intFromPtr(target), .load_serial = load_serial };
    @memcpy(&job.id, id);
    workers.spawn(resolveWorker, .{job}) catch return false;
    return true;
}

fn publish(job: Job, url: ?[]const u8) void {
    publication_mutex.lock();
    defer publication_mutex.unlock();
    if (publication_count == publications.len) {
        // Keep the newest completion under pathological multi-player bursts.
        std.mem.copyForwards(Publication, publications[0 .. publications.len - 1], publications[1..]);
        publication_count -= 1;
    }
    const publication = &publications[publication_count];
    publication_count += 1;
    publication.* = .{ .target_address = job.target_address, .load_serial = job.load_serial, .success = url != null };
    if (url) |u| {
        publication.url_len = @min(u.len, publication.url.len);
        @memcpy(publication.url[0..publication.url_len], u[0..publication.url_len]);
    }
    state.wakeUi();
}

fn resolveWorker(job: Job) void {
    var body_buf: [1024]u8 = undefined;
    const body = pure.buildPlayerBody(&job.id, &body_buf) orelse {
        publish(job, null);
        return;
    };
    const response = alloc.alloc(u8, 512 * 1024) catch {
        publish(job, null);
        return;
    };
    defer alloc.free(response);
    const payload = @import("reliable_fetch.zig").fetch(pure.PLAYER_URL, response, .{
        .user_agent = pure.USER_AGENT,
        .headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "X-YouTube-Client-Name", .value = "3" },
            .{ .name = "X-YouTube-Client-Version", .value = pure.CLIENT_VERSION },
            .{ .name = "Origin", .value = "https://www.youtube.com" },
        },
        .timeout_secs = 6,
        .impersonate = false,
        .post_body = body,
    }) orelse {
        publish(job, null);
        return;
    };
    var url_buf: [MAX_URL]u8 = undefined;
    publish(job, pure.progressiveUrl(payload, &url_buf));
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
    if (result.success and result.url_len > 0)
        p.commitYoutubeFast(result.url[0..result.url_len])
    else
        p.commitYoutubeFallback();
}
