//! Recoverable helper installation: the file half. Runs the step sequence from
//! helper_install_pure.zig against a real directory.
//!
//! Takes an explicit `std.Io` and directory instead of io_global so the same
//! code runs in `zig build test` against a temporary directory and a local
//! fixture. The download and the version probe are hooks: production passes
//! reliable_fetch and bounded_process, tests pass a fixture copy.

const std = @import("std");
const pure = @import("helper_install_pure.zig");

pub const Failure = pure.Failure;
pub const Result = pure.Result;
pub const Expect = pure.Expect;
pub const FetchResult = pure.FetchResult;

pub const Hooks = struct {
    ctx: ?*anyopaque = null,
    /// Download into the absolute `stage_path`. The caller's fetch must not
    /// write anywhere else.
    fetch: *const fn (ctx: ?*anyopaque, stage_path: []const u8) FetchResult,
    /// Run the staged file (e.g. `--version`). Null skips the probe.
    probe: ?*const fn (ctx: ?*anyopaque, stage_path: []const u8) bool = null,
    cancelled: ?*const fn (ctx: ?*anyopaque) bool = null,
};

pub const Target = struct {
    dir: std.Io.Dir,
    /// Absolute path of `dir`, used to give the hooks absolute paths.
    dir_path: []const u8,
    name: []const u8,
};

pub const Spec = struct {
    expect: Expect = .{},
    executable: bool = false,
    keep_previous: bool = true,
};

fn exists(io: std.Io, dir: std.Io.Dir, name: []const u8) bool {
    dir.access(io, name, .{}) catch return false;
    return true;
}

fn deleteQuiet(io: std.Io, dir: std.Io.Dir, name: []const u8) void {
    dir.deleteFile(io, name) catch {};
}

/// Size, plus the SHA-256 when one is expected.
fn measure(io: std.Io, dir: std.Io.Dir, name: []const u8, want_digest: bool, hooks: Hooks) ?struct { size: u64, digest: ?[32]u8 } {
    const file = dir.openFile(io, name, .{}) catch return null;
    defer file.close(io);
    const size = file.length(io) catch return null;
    if (!want_digest) return .{ .size = size, .digest = null };
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        if (isCancelled(hooks)) return null;
        var vec: [1][]u8 = .{&buf};
        const n = file.readStreaming(io, &vec) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return null,
        };
        if (n == 0) break;
        sha.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    return .{ .size = size, .digest = digest };
}

fn isCancelled(hooks: Hooks) bool {
    const f = hooks.cancelled orelse return false;
    return f(hooks.ctx);
}

/// Native permissions: owner rwx, group/other rx on POSIX. Windows has no
/// executable bit; the `.exe` name is what makes it runnable.
fn markExecutable(io: std.Io, dir: std.Io.Dir, name: []const u8) bool {
    if (comptime !std.Io.File.Permissions.has_executable_bit) return true;
    // fchmod on an opened handle: the path-based call lowers to fchmodat2,
    // which Android's seccomp policy kills.
    const file = dir.openFile(io, name, .{}) catch return false;
    defer file.close(io);
    file.setPermissions(io, .fromMode(0o755)) catch return false;
    return true;
}

/// Install `target.name` through a staged sibling. Never leaves a partial file
/// at the live path; on any failure the working copy stays in place.
pub fn install(io: std.Io, target: Target, spec: Spec, hooks: Hooks) Result {
    var stage_buf: [512]u8 = undefined;
    var prev_buf: [512]u8 = undefined;
    var abs_buf: [1024]u8 = undefined;
    const stage = pure.stageName(&stage_buf, target.name) orelse return .{ .failure = .publish_failed };
    const prev = pure.prevName(&prev_buf, target.name) orelse return .{ .failure = .publish_failed };
    const stage_abs = std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ target.dir_path, stage }) catch return .{ .failure = .publish_failed };

    var m = pure.Machine.init(.{
        .executable = spec.executable,
        .probe = hooks.probe != null,
        .keep_previous = spec.keep_previous,
    }, exists(io, target.dir, target.name));

    deleteQuiet(io, target.dir, stage);
    while (m.step != .done) {
        if (m.cancellable() and isCancelled(hooks)) {
            m.fail(.cancelled);
            continue;
        }
        switch (m.step) {
            .fetch => if (pure.fetchFailure(hooks.fetch(hooks.ctx, stage_abs))) |f| m.fail(f) else m.succeed(),
            .verify => {
                const got = measure(io, target.dir, stage, spec.expect.needsDigest(), hooks) orelse {
                    m.fail(if (isCancelled(hooks)) .cancelled else .empty);
                    continue;
                };
                if (pure.verify(spec.expect, got.size, got.digest)) |f| m.fail(f) else m.succeed();
            },
            .mark_executable => if (markExecutable(io, target.dir, stage)) m.succeed() else m.fail(.permissions),
            .probe => if (hooks.probe.?(hooks.ctx, stage_abs)) m.succeed() else m.fail(.probe_failed),
            .backup => {
                deleteQuiet(io, target.dir, prev);
                // A hard link keeps the live path in place through the swap.
                if (target.dir.hardLink(target.name, target.dir, prev, io, .{})) |_| {
                    m.succeed();
                } else |_| if (target.dir.rename(target.name, target.dir, prev, io)) |_| {
                    m.backupMoved();
                } else |_| m.fail(.backup_failed);
            },
            // rename replaces the live file atomically.
            .publish => if (target.dir.rename(stage, target.dir, target.name, io)) |_| m.succeed() else |_| m.fail(.publish_failed),
            .restore => if (target.dir.rename(prev, target.dir, target.name, io)) |_| m.succeed() else |_| m.fail(.restore_failed),
            .discard => {
                deleteQuiet(io, target.dir, stage);
                var part_buf: [520]u8 = undefined;
                if (pure.staleName(&part_buf, target.name, 1)) |part| deleteQuiet(io, target.dir, part);
                m.succeed();
            },
            .done => {},
        }
    }
    return m.result();
}

pub const CleanupReport = struct { removed: u8 = 0, restored: bool = false };

/// Run once at startup, before any install of `name` can be in flight: drop
/// partial downloads and restore a previous copy a crash left without a live
/// file.
pub fn cleanupStale(io: std.Io, dir: std.Io.Dir, name: []const u8) CleanupReport {
    var report: CleanupReport = .{};
    var i: usize = 0;
    while (i < pure.stale_count) : (i += 1) {
        var buf: [600]u8 = undefined;
        const stale = pure.staleName(&buf, name, i) orelse continue;
        if (dir.deleteFile(io, stale)) |_| {
            report.removed += 1;
        } else |_| {}
    }
    var prev_buf: [512]u8 = undefined;
    const prev = pure.prevName(&prev_buf, name) orelse return report;
    if (pure.recovery(exists(io, dir, name), exists(io, dir, prev)).restore_prev) {
        if (dir.rename(prev, dir, name, io)) |_| {
            report.restored = true;
        } else |_| {}
    }
    return report;
}

pub fn hasPrevious(io: std.Io, dir: std.Io.Dir, name: []const u8) bool {
    var prev_buf: [512]u8 = undefined;
    const prev = pure.prevName(&prev_buf, name) orelse return false;
    return exists(io, dir, prev);
}

/// Put the kept previous copy back over the live file (atomic replace).
pub fn rollback(io: std.Io, dir: std.Io.Dir, name: []const u8) bool {
    var prev_buf: [512]u8 = undefined;
    const prev = pure.prevName(&prev_buf, name) orelse return false;
    if (!pure.canRollback(exists(io, dir, prev))) return false;
    dir.rename(prev, dir, name, io) catch return false;
    return true;
}

// ── Tests: a temporary directory and a local fixture, no network ──

const testing = std.testing;

const Fixture = struct {
    io: std.Io,
    /// Bytes the fake download writes; null simulates an HTTP failure.
    body: ?[]const u8,
    probe_ok: bool = true,
    fetched: usize = 0,
    probed: usize = 0,
    cancel: bool = false,

    fn fetch(ctx: ?*anyopaque, stage_path: []const u8) FetchResult {
        const self: *Fixture = @ptrCast(@alignCast(ctx.?));
        self.fetched += 1;
        const bytes = self.body orelse return .http_error;
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = stage_path, .data = bytes }) catch return .transport;
        return .ok;
    }
    fn probe(ctx: ?*anyopaque, _: []const u8) bool {
        const self: *Fixture = @ptrCast(@alignCast(ctx.?));
        self.probed += 1;
        return self.probe_ok;
    }
    fn cancelled(ctx: ?*anyopaque) bool {
        const self: *Fixture = @ptrCast(@alignCast(ctx.?));
        return self.cancel;
    }
    fn hooks(self: *Fixture, with_probe: bool) Hooks {
        return .{ .ctx = self, .fetch = fetch, .probe = if (with_probe) probe else null, .cancelled = cancelled };
    }
};

fn readAlloc(io: std.Io, dir: std.Io.Dir, name: []const u8) ![]u8 {
    return dir.readFileAlloc(io, name, testing.allocator, .limited(1 << 20));
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

const TestDir = struct {
    tmp: testing.TmpDir,
    path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    path_len: usize = 0,

    fn init() !TestDir {
        var t: TestDir = .{ .tmp = testing.tmpDir(.{}) };
        t.path_len = try t.tmp.dir.realPath(testing.io, &t.path_buf);
        return t;
    }
    fn target(self: *TestDir, name: []const u8) Target {
        return .{ .dir = self.tmp.dir, .dir_path = self.path_buf[0..self.path_len], .name = name };
    }
    fn deinit(self: *TestDir) void {
        self.tmp.cleanup();
    }
};

test "fresh install publishes the verified fixture and leaves no stage" {
    const io = testing.io;
    var t = try TestDir.init();
    defer t.deinit();
    const bytes = "#!/bin/sh\necho 2026.11.01\n";
    const hex = sha256Hex(bytes);
    var fx: Fixture = .{ .io = io, .body = bytes };
    const r = install(io, t.target("tool"), .{ .expect = .{ .size = bytes.len, .sha256_hex = &hex }, .executable = true }, fx.hooks(true));
    try testing.expect(r.ok());
    try testing.expect(!r.kept_previous);
    const got = try readAlloc(io, t.tmp.dir, "tool");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(bytes, got);
    try testing.expect(!exists(io, t.tmp.dir, "tool.opal-stage"));
    try testing.expectEqual(@as(usize, 1), fx.probed);
    if (comptime std.Io.File.Permissions.has_executable_bit) {
        const st = try t.tmp.dir.statFile(io, "tool", .{});
        try testing.expect(st.permissions.toMode() & 0o100 != 0);
        try testing.expect(st.permissions.toMode() & 0o002 == 0);
    }
}

test "update keeps the previous version and rollback restores it" {
    const io = testing.io;
    var t = try TestDir.init();
    defer t.deinit();
    try t.tmp.dir.writeFile(io, .{ .sub_path = "tool", .data = "old" });
    var fx: Fixture = .{ .io = io, .body = "new" };
    const r = install(io, t.target("tool"), .{}, fx.hooks(false));
    try testing.expect(r.ok());
    try testing.expect(r.kept_previous);
    const live = try readAlloc(io, t.tmp.dir, "tool");
    defer testing.allocator.free(live);
    try testing.expectEqualStrings("new", live);
    try testing.expect(hasPrevious(io, t.tmp.dir, "tool"));
    try testing.expect(rollback(io, t.tmp.dir, "tool"));
    const back = try readAlloc(io, t.tmp.dir, "tool");
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("old", back);
    try testing.expect(!rollback(io, t.tmp.dir, "tool"));
}

test "checksum mismatch, HTTP failure, failed probe and cancel keep the working copy" {
    const io = testing.io;
    const wrong = sha256Hex("something else");
    const Case = struct { body: ?[]const u8, probe_ok: bool, cancel: bool, expect: Expect, want: Failure };
    const cases = [_]Case{
        .{ .body = "tampered", .probe_ok = true, .cancel = false, .expect = .{ .sha256_hex = &wrong }, .want = .checksum_mismatch },
        .{ .body = "short", .probe_ok = true, .cancel = false, .expect = .{ .size = 999 }, .want = .size_mismatch },
        .{ .body = null, .probe_ok = true, .cancel = false, .expect = .{}, .want = .fetch_http },
        .{ .body = "", .probe_ok = true, .cancel = false, .expect = .{}, .want = .empty },
        .{ .body = "broken", .probe_ok = false, .cancel = false, .expect = .{}, .want = .probe_failed },
        .{ .body = "new", .probe_ok = true, .cancel = true, .expect = .{}, .want = .cancelled },
    };
    for (cases) |case| {
        var t = try TestDir.init();
        defer t.deinit();
        try t.tmp.dir.writeFile(io, .{ .sub_path = "tool", .data = "working" });
        var fx: Fixture = .{ .io = io, .body = case.body, .probe_ok = case.probe_ok, .cancel = case.cancel };
        const r = install(io, t.target("tool"), .{ .expect = case.expect }, fx.hooks(true));
        try testing.expect(!r.ok());
        try testing.expectEqual(@as(?Failure, case.want), r.failure);
        const live = try readAlloc(io, t.tmp.dir, "tool");
        defer testing.allocator.free(live);
        try testing.expectEqualStrings("working", live);
        try testing.expect(!exists(io, t.tmp.dir, "tool.opal-stage"));
        try testing.expect(!hasPrevious(io, t.tmp.dir, "tool"));
    }
}

test "startup cleanup removes partials and restores a previous copy after a crash" {
    const io = testing.io;
    var t = try TestDir.init();
    defer t.deinit();
    // A crash mid-download, plus legacy names from the old updater.
    for ([_][]const u8{ "tool.opal-stage", "tool.opal-stage.part", "tool.part", "tool.new", "tool.new.part" }) |n|
        try t.tmp.dir.writeFile(io, .{ .sub_path = n, .data = "partial" });
    // A crash between moving the live file aside and publishing.
    try t.tmp.dir.writeFile(io, .{ .sub_path = "tool.opal-prev", .data = "good" });
    const report = cleanupStale(io, t.tmp.dir, "tool");
    try testing.expectEqual(@as(u8, 5), report.removed);
    try testing.expect(report.restored);
    const live = try readAlloc(io, t.tmp.dir, "tool");
    defer testing.allocator.free(live);
    try testing.expectEqualStrings("good", live);
    // Idempotent, and a healthy install keeps its previous copy.
    try t.tmp.dir.writeFile(io, .{ .sub_path = "tool.opal-prev", .data = "older" });
    const again = cleanupStale(io, t.tmp.dir, "tool");
    try testing.expectEqual(@as(u8, 0), again.removed);
    try testing.expect(!again.restored);
    try testing.expect(hasPrevious(io, t.tmp.dir, "tool"));
}

test "a Windows-style executable stages with its extension last" {
    const io = testing.io;
    var t = try TestDir.init();
    defer t.deinit();
    const Seen = struct {
        io: std.Io,
        path_buf: [1024]u8 = undefined,
        path_len: usize = 0,
        fn fetch(ctx: ?*anyopaque, stage_path: []const u8) FetchResult {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            @memcpy(self.path_buf[0..stage_path.len], stage_path);
            self.path_len = stage_path.len;
            std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = stage_path, .data = "MZ" }) catch return .transport;
            return .ok;
        }
    };
    var seen: Seen = .{ .io = io };
    const r = install(io, t.target("yt-dlp.exe"), .{ .executable = true }, .{ .ctx = &seen, .fetch = Seen.fetch });
    try testing.expect(r.ok());
    try testing.expect(std.mem.endsWith(u8, seen.path_buf[0..seen.path_len], "/yt-dlp.opal-stage.exe"));
}
