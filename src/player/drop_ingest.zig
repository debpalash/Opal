const std = @import("std");
const io_global = @import("../core/io_global.zig");
const state = @import("../core/state.zig");
const workers = @import("../core/workers.zig");
const m3u = @import("m3u.zig");

// A dropped network mount can remain blocked past the bounded global shutdown
// drain. Keep this worker's allocations independent of the debug allocator
// that appDeinit tears down after that deadline.
const allocator = std.heap.c_allocator;

const max_path_len = 2048;
const max_folder_entries = 10_000;

pub const Kind = enum { path, playlist, empty_folder, invalid_playlist };

pub const Result = struct {
    path: [max_path_len:0]u8 = std.mem.zeroes([max_path_len:0]u8),
    path_len: usize = 0,
    kind: Kind = .path,
    playlist: ?*m3u.M3UPlaylist = null,

    pub fn pathSlice(self: *const Result) []const u8 {
        return self.path[0..self.path_len];
    }

    pub fn deinit(self: *Result) void {
        if (self.playlist) |playlist| {
            playlist.deinit();
            allocator.destroy(playlist);
            self.playlist = null;
        }
    }
};

const Args = struct {
    path: [max_path_len:0]u8 = std.mem.zeroes([max_path_len:0]u8),
    path_len: usize = 0,
    generation: u64,
};

var generation = std.atomic.Value(u64).init(0);
var result_ready = std.atomic.Value(bool).init(false);
var result_lock: @import("../core/sync.zig").Mutex = .{};
var pending: ?Result = null;

/// Start classifying/loading a dropped path away from the UI thread. Newer
/// drops supersede older work; stale workers free their result instead of
/// publishing it.
pub fn start(path: []const u8) bool {
    if (path.len == 0 or workers.isQuitting()) return false;
    const args = allocator.create(Args) catch return false;
    args.* = .{ .generation = generation.fetchAdd(1, .acq_rel) + 1 };
    args.path_len = @min(path.len, args.path.len);
    @memcpy(args.path[0..args.path_len], path[0..args.path_len]);

    // Register before spawning so shutdown cannot observe zero active workers
    // in the gap between spawn and the new thread entering its body.
    workers.enter();
    const thread = std.Thread.spawn(.{}, run, .{args}) catch {
        workers.leave();
        allocator.destroy(args);
        return false;
    };
    thread.detach();
    return true;
}

/// Non-blocking UI-thread drain. The idle path is one atomic load.
pub fn take() ?Result {
    if (!result_ready.load(.acquire)) return null;
    result_lock.lock();
    defer result_lock.unlock();
    if (!result_ready.swap(false, .acq_rel)) return null;
    const out = pending;
    pending = null;
    return out;
}

/// Call after the global worker barrier during app shutdown.
pub fn deinit() void {
    if (take()) |value_const| {
        var value = value_const;
        value.deinit();
    }
}

fn run(args: *Args) void {
    defer workers.leave();
    defer allocator.destroy(args);

    var result = classify(args.path[0..args.path_len]);
    if (workers.isQuitting() or args.generation != generation.load(.acquire)) {
        result.deinit();
        return;
    }

    result_lock.lock();
    if (workers.isQuitting() or args.generation != generation.load(.acquire)) {
        result_lock.unlock();
        result.deinit();
        return;
    }
    if (pending) |old_const| {
        var old = old_const;
        old.deinit();
    }
    pending = result;
    result_ready.store(true, .release);
    result_lock.unlock();
    state.wakeUi();
}

fn classify(path: []const u8) Result {
    var result = Result{};
    result.path_len = @min(path.len, result.path.len);
    @memcpy(result.path[0..result.path_len], path[0..result.path_len]);

    const playlist = allocator.create(m3u.M3UPlaylist) catch return result;
    playlist.* = m3u.M3UPlaylist.init(allocator);

    if (hasPlaylistExtension(path)) {
        playlist.loadFile(io_global.io(), path) catch {
            playlist.deinit();
            allocator.destroy(playlist);
            result.kind = .invalid_playlist;
            return result;
        };
        result.kind = .playlist;
        result.playlist = playlist;
        return result;
    }

    if (!scanDirectory(playlist, path)) {
        playlist.deinit();
        allocator.destroy(playlist);
        return result;
    }
    if (playlist.entries.items.len == 0) {
        playlist.deinit();
        allocator.destroy(playlist);
        result.kind = .empty_folder;
        return result;
    }
    result.kind = .playlist;
    result.playlist = playlist;
    return result;
}

fn scanDirectory(playlist: *m3u.M3UPlaylist, dir_path: []const u8) bool {
    var dir = if (dir_path.len > 0 and dir_path[0] == '/')
        io_global.openDirAbsolute(dir_path, .{ .iterate = true }) catch return false
    else
        io_global.cwdOpenDir(dir_path, .{ .iterate = true }) catch return false;
    defer dir.close(io_global.io());

    var iterator = dir.iterate();
    while (playlist.entries.items.len < max_folder_entries) {
        if (workers.isQuitting()) return true;
        const entry = (iterator.next(io_global.io()) catch return true) orelse break;
        if (entry.kind != .file or !isMediaFile(entry.name)) continue;
        var full_buf: [4096]u8 = undefined;
        const full_path = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        playlist.appendCopy(entry.name, full_path, null, "Local") catch continue;
    }
    return true;
}

fn hasPlaylistExtension(path: []const u8) bool {
    return endsWithIgnoreCase(path, ".m3u") or endsWithIgnoreCase(path, ".m3u8");
}

fn isMediaFile(name: []const u8) bool {
    const extensions = [_][]const u8{
        ".mp4", ".mkv",  ".avi", ".webm", ".mov", ".flv",  ".ts",
        ".mp3", ".flac", ".wav", ".ogg",  ".m4a", ".opus",
    };
    for (extensions) |extension| {
        if (endsWithIgnoreCase(name, extension)) return true;
    }
    return false;
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    return value.len > suffix.len and std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}
