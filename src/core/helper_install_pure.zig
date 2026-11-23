//! Recoverable helper installation: the state machine, sibling names and
//! verification rules. Pure: no io, no state. helper_install.zig executes it.
//!
//! One install is a fixed sequence of steps:
//!   fetch -> verify -> [mark_executable] -> [probe] -> [backup] -> publish
//! A failure before publish discards the staged file and leaves the working
//! copy untouched. Publish is an atomic rename over the live file. The live
//! file is first kept as `<name>.opal-prev` (a hard link, so the live path
//! never goes missing; where links are unsupported it is moved, and a failed
//! publish moves it back). `recovery` repairs the one crash window that
//! a move leaves: live file missing, previous copy present.
//!
//! Trust model: size and SHA-256 come from the caller. For yt-dlp the digest is
//! read from the release's own SHA2-256SUMS, which catches truncation and
//! corruption but not a compromised release; that needs a signature check.

const std = @import("std");

pub const stage_tag = ".opal-stage";
pub const prev_tag = ".opal-prev";
const exe_ext = ".exe";

/// Staged sibling of `name`. A Windows executable keeps its `.exe` last so the
/// staged copy can run its version probe: `yt-dlp.exe` -> `yt-dlp.opal-stage.exe`.
pub fn stageName(buf: []u8, name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;
    if (std.ascii.endsWithIgnoreCase(name, exe_ext) and name.len > exe_ext.len) {
        const stem = name[0 .. name.len - exe_ext.len];
        return std.fmt.bufPrint(buf, "{s}" ++ stage_tag ++ "{s}", .{ stem, name[stem.len..] }) catch null;
    }
    return std.fmt.bufPrint(buf, "{s}" ++ stage_tag, .{name}) catch null;
}

/// The previous published copy kept for rollback.
pub fn prevName(buf: []u8, name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}" ++ prev_tag, .{name}) catch null;
}

/// Every partial-download sibling an install of `name` can leave behind,
/// including the names earlier installers used. Index 0..stale_count.
pub const stale_count = 8;
pub fn staleName(buf: []u8, name: []const u8, index: usize) ?[]const u8 {
    if (name.len == 0) return null;
    var stage_buf: [512]u8 = undefined;
    return switch (index) {
        0 => stageName(buf, name),
        // reliable_fetch writes `<dest>.part` before its own rename.
        1 => std.fmt.bufPrint(buf, "{s}.part", .{stageName(&stage_buf, name) orelse return null}) catch null,
        2 => std.fmt.bufPrint(buf, "{s}.part", .{name}) catch null,
        3 => std.fmt.bufPrint(buf, "{s}.part.part", .{name}) catch null,
        // Legacy yt-dlp updater stage names (POSIX and Windows).
        4 => std.fmt.bufPrint(buf, "{s}.new", .{name}) catch null,
        5 => std.fmt.bufPrint(buf, "{s}.new.part", .{name}) catch null,
        6 => std.fmt.bufPrint(buf, "{s}.new.exe", .{name}) catch null,
        7 => std.fmt.bufPrint(buf, "{s}.new.exe.part", .{name}) catch null,
        else => null,
    };
}

/// Prefix of the isolated extraction tree an archive model install uses.
pub const model_stage_prefix = ".opal-model-stage-";

/// A models-folder entry an interrupted archive install leaves: the hidden
/// `.<archive>.part` download (and reliable_fetch's own `.part.part`), or a
/// half-extracted staging tree. Published model directories never match.
pub fn isStaleModelEntry(name: []const u8) bool {
    if (name.len < 2 or name[0] != '.') return false;
    if (std.mem.startsWith(u8, name, model_stage_prefix)) return name.len > model_stage_prefix.len;
    return std.mem.endsWith(u8, name, ".part");
}

pub const Expect = struct {
    size: ?u64 = null,
    /// Lowercase or uppercase hex, 64 characters.
    sha256_hex: ?[]const u8 = null,

    pub fn needsDigest(self: Expect) bool {
        return self.sha256_hex != null;
    }
};

pub const Failure = enum {
    fetch_http,
    fetch_transport,
    cancelled,
    empty,
    size_mismatch,
    checksum_mismatch,
    bad_checksum_spec,
    permissions,
    probe_failed,
    backup_failed,
    publish_failed,
    /// Publish failed after the live file was moved aside and moving it back
    /// also failed. `recovery` restores it on the next start.
    restore_failed,
};

pub const FetchResult = enum { ok, http_error, transport, cancelled };

pub fn fetchFailure(r: FetchResult) ?Failure {
    return switch (r) {
        .ok => null,
        .http_error => .fetch_http,
        .transport => .fetch_transport,
        .cancelled => .cancelled,
    };
}

/// Verify a staged file. `digest` is null when the caller skipped hashing
/// because no checksum was expected.
pub fn verify(expect: Expect, size: u64, digest: ?[32]u8) ?Failure {
    if (size == 0) return .empty;
    if (expect.size) |want| if (want != size) return .size_mismatch;
    const hex = expect.sha256_hex orelse return null;
    const got = digest orelse return .checksum_mismatch;
    var want: [32]u8 = undefined;
    if (hex.len != 64) return .bad_checksum_spec;
    _ = std.fmt.hexToBytes(&want, hex) catch return .bad_checksum_spec;
    if (!std.crypto.timing_safe.eql([32]u8, want, got)) return .checksum_mismatch;
    return null;
}

pub const Step = enum { fetch, verify, mark_executable, probe, backup, publish, restore, discard, done };

pub const Options = struct {
    executable: bool = false,
    probe: bool = false,
    keep_previous: bool = true,
};

pub const Result = struct {
    published: bool = false,
    failure: ?Failure = null,
    /// A previous copy is kept as `<name>.opal-prev`.
    kept_previous: bool = false,

    pub fn ok(self: Result) bool {
        return self.published and self.failure == null;
    }
};

pub const Machine = struct {
    opts: Options,
    target_existed: bool,
    step: Step = .fetch,
    failure: ?Failure = null,
    /// The backup step moved the live file aside instead of linking it.
    target_moved: bool = false,
    backed_up: bool = false,
    published: bool = false,

    pub fn init(opts: Options, target_existed: bool) Machine {
        return .{ .opts = opts, .target_existed = target_existed };
    }

    /// Cancellation is honoured only before the swap begins.
    pub fn cancellable(self: *const Machine) bool {
        return switch (self.step) {
            .fetch, .verify, .mark_executable, .probe, .backup => true,
            else => false,
        };
    }

    fn afterVerified(self: *Machine, from: Step) Step {
        if (from == .verify and self.opts.executable) return .mark_executable;
        if ((from == .verify or from == .mark_executable) and self.opts.probe) return .probe;
        if (self.target_existed and self.opts.keep_previous) return .backup;
        return .publish;
    }

    pub fn succeed(self: *Machine) void {
        self.step = switch (self.step) {
            .fetch => .verify,
            .verify, .mark_executable, .probe => self.afterVerified(self.step),
            .backup => blk: {
                self.backed_up = true;
                break :blk .publish;
            },
            .publish => blk: {
                self.published = true;
                break :blk .done;
            },
            .restore, .discard, .done => .done,
        };
    }

    /// The backup step could not link and moved the live file instead.
    pub fn backupMoved(self: *Machine) void {
        std.debug.assert(self.step == .backup);
        self.target_moved = true;
        self.succeed();
    }

    pub fn fail(self: *Machine, why: Failure) void {
        switch (self.step) {
            .fetch, .verify, .mark_executable, .probe, .backup => {
                self.failure = why;
                self.step = .discard;
            },
            .publish => {
                self.failure = .publish_failed;
                self.step = if (self.target_moved) .restore else .discard;
            },
            .restore => {
                self.failure = .restore_failed;
                self.step = .discard;
            },
            .discard, .done => self.step = .done,
        }
    }

    pub fn result(self: *const Machine) Result {
        return .{
            .published = self.published,
            .failure = self.failure,
            .kept_previous = self.backed_up and self.published,
        };
    }
};

/// Startup repair for one installed file. Partial siblings are always removed;
/// a missing live file with a kept previous copy is restored from it.
pub const Recovery = struct { remove_partials: bool = true, restore_prev: bool = false };

pub fn recovery(target_exists: bool, prev_exists: bool) Recovery {
    return .{ .restore_prev = !target_exists and prev_exists };
}

/// Rollback is possible only with a kept previous copy.
pub fn canRollback(prev_exists: bool) bool {
    return prev_exists;
}

// ── Tests ──

fn run(m: *Machine, outcomes: []const ?Failure) void {
    for (outcomes) |o| {
        if (m.step == .done) return;
        if (o) |f| m.fail(f) else m.succeed();
    }
}

test "fresh install: fetch, verify, publish; nothing to keep" {
    var m = Machine.init(.{}, false);
    try std.testing.expectEqual(Step.fetch, m.step);
    m.succeed();
    try std.testing.expectEqual(Step.verify, m.step);
    m.succeed();
    try std.testing.expectEqual(Step.publish, m.step);
    m.succeed();
    try std.testing.expectEqual(Step.done, m.step);
    try std.testing.expect(m.result().ok());
    try std.testing.expect(!m.result().kept_previous);
}

test "update of an executable: every step in order, previous kept" {
    var m = Machine.init(.{ .executable = true, .probe = true }, true);
    const order = [_]Step{ .fetch, .verify, .mark_executable, .probe, .backup, .publish };
    for (order) |want| {
        try std.testing.expectEqual(want, m.step);
        m.succeed();
    }
    try std.testing.expectEqual(Step.done, m.step);
    try std.testing.expect(m.result().ok());
    try std.testing.expect(m.result().kept_previous);
}

test "any failure before publish discards the stage and keeps the working copy" {
    const failing = [_]struct { at: usize, why: Failure }{
        .{ .at = 0, .why = .fetch_http },
        .{ .at = 1, .why = .checksum_mismatch },
        .{ .at = 2, .why = .permissions },
        .{ .at = 3, .why = .probe_failed },
        .{ .at = 4, .why = .backup_failed },
    };
    for (failing) |case| {
        var m = Machine.init(.{ .executable = true, .probe = true }, true);
        var i: usize = 0;
        while (i < case.at) : (i += 1) m.succeed();
        m.fail(case.why);
        try std.testing.expectEqual(Step.discard, m.step);
        m.succeed();
        try std.testing.expectEqual(Step.done, m.step);
        const r = m.result();
        try std.testing.expect(!r.published);
        try std.testing.expectEqual(@as(?Failure, case.why), r.failure);
        try std.testing.expect(!m.target_moved);
    }
}

test "publish failure after a move restores the previous copy" {
    var m = Machine.init(.{}, true);
    run(&m, &.{ null, null });
    try std.testing.expectEqual(Step.backup, m.step);
    m.backupMoved();
    try std.testing.expectEqual(Step.publish, m.step);
    m.fail(.publish_failed);
    try std.testing.expectEqual(Step.restore, m.step);
    m.succeed();
    try std.testing.expectEqual(Step.done, m.step);
    try std.testing.expectEqual(@as(?Failure, .publish_failed), m.result().failure);
}

test "publish failure after a link only discards (live file never moved)" {
    var m = Machine.init(.{}, true);
    run(&m, &.{ null, null, null });
    try std.testing.expectEqual(Step.publish, m.step);
    m.fail(.publish_failed);
    try std.testing.expectEqual(Step.discard, m.step);
}

test "a failed restore is reported for startup recovery" {
    var m = Machine.init(.{}, true);
    run(&m, &.{ null, null });
    m.backupMoved();
    m.fail(.publish_failed);
    m.fail(.publish_failed);
    try std.testing.expectEqual(@as(?Failure, .restore_failed), m.result().failure);
    try std.testing.expect(recovery(false, true).restore_prev);
}

test "cancellation stops before the swap, never during it" {
    var m = Machine.init(.{}, true);
    try std.testing.expect(m.cancellable());
    run(&m, &.{ null, null, null });
    try std.testing.expectEqual(Step.publish, m.step);
    try std.testing.expect(!m.cancellable());
}

test "verify: size, digest, empty, malformed spec" {
    const zero: [32]u8 = @splat(0);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("abc", &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqual(@as(?Failure, null), verify(.{ .size = 3, .sha256_hex = &hex }, 3, digest));
    const upper = std.fmt.bytesToHex(digest, .upper);
    try std.testing.expectEqual(@as(?Failure, null), verify(.{ .sha256_hex = &upper }, 3, digest));
    try std.testing.expectEqual(@as(?Failure, .size_mismatch), verify(.{ .size = 4 }, 3, null));
    try std.testing.expectEqual(@as(?Failure, .checksum_mismatch), verify(.{ .sha256_hex = &hex }, 3, zero));
    try std.testing.expectEqual(@as(?Failure, .checksum_mismatch), verify(.{ .sha256_hex = &hex }, 3, null));
    try std.testing.expectEqual(@as(?Failure, .empty), verify(.{}, 0, null));
    try std.testing.expectEqual(@as(?Failure, .bad_checksum_spec), verify(.{ .sha256_hex = "abc" }, 3, digest));
    try std.testing.expectEqual(@as(?Failure, null), verify(.{}, 10, null));
}

test "names: stage keeps .exe last, prev and stale siblings" {
    var b: [128]u8 = undefined;
    try std.testing.expectEqualStrings("yt-dlp.opal-stage", stageName(&b, "yt-dlp").?);
    try std.testing.expectEqualStrings("yt-dlp.opal-stage.exe", stageName(&b, "yt-dlp.exe").?);
    try std.testing.expectEqualStrings("yt-dlp.opal-prev", prevName(&b, "yt-dlp").?);
    try std.testing.expectEqualStrings("yt-dlp.opal-stage.part", staleName(&b, "yt-dlp", 1).?);
    try std.testing.expectEqualStrings("yt-dlp.exe.new.exe", staleName(&b, "yt-dlp.exe", 6).?);
    try std.testing.expectEqual(@as(?[]const u8, null), staleName(&b, "yt-dlp", stale_count));
    try std.testing.expectEqual(@as(?[]const u8, null), stageName(&b, ""));
    var i: usize = 0;
    while (i < stale_count) : (i += 1) {
        const n = staleName(&b, "m.bin", i).?;
        // A stale name is never the live file or the kept previous copy.
        try std.testing.expect(!std.mem.eql(u8, n, "m.bin"));
        try std.testing.expect(!std.mem.eql(u8, n, "m.bin.opal-prev"));
    }
}

test "model folder: only interrupted archive installs are stale" {
    try std.testing.expect(isStaleModelEntry(".parakeet-v3.tar.bz2.part"));
    try std.testing.expect(isStaleModelEntry(".parakeet-v3.tar.bz2.part.part"));
    try std.testing.expect(isStaleModelEntry(".opal-model-stage-sherpa-kokoro.tar.bz2"));
    try std.testing.expect(!isStaleModelEntry(".opal-model-stage-"));
    try std.testing.expect(!isStaleModelEntry("sherpa-kokoro"));
    try std.testing.expect(!isStaleModelEntry("ggml-tiny.en.bin"));
    try std.testing.expect(!isStaleModelEntry("ggml-tiny.en.bin.part"));
    try std.testing.expect(!isStaleModelEntry(".DS_Store"));
    try std.testing.expect(!isStaleModelEntry("."));
}

test "recovery: restore only when the live file is missing" {
    try std.testing.expect(recovery(false, true).restore_prev);
    try std.testing.expect(!recovery(true, true).restore_prev);
    try std.testing.expect(!recovery(false, false).restore_prev);
    try std.testing.expect(recovery(true, false).remove_partials);
    try std.testing.expect(canRollback(true));
    try std.testing.expect(!canRollback(false));
}

test "fetch failures map to typed install failures" {
    try std.testing.expectEqual(@as(?Failure, null), fetchFailure(.ok));
    try std.testing.expectEqual(@as(?Failure, .fetch_http), fetchFailure(.http_error));
    try std.testing.expectEqual(@as(?Failure, .cancelled), fetchFailure(.cancelled));
}
