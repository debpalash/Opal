//! Household profiles (ROADMAP 7.3): several people share one Opal, each with
//! their own history, library, favorites, recommendations and sync.
//!
//! Design: a profile IS a data directory. The default profile keeps today's
//! paths (<config>/opal.db, <config>/sync_device); every other profile lives in
//! <config>/profiles/<id>/ with its own opal.db and sync_device. Nothing in the
//! schema changes and no query needs scoping, so isolation is total by
//! construction. Household-wide tables (web accounts, paired browsers) stay in
//! the default profile's db via core/household_db.zig.
//!
//! The registry (names, colours, kid flags, PIN hashes, next-launch profile) is
//! a small owner-only file in the config dir, outside every profile db.
//!
//! Switching is a controlled restart: the next profile is written to the
//! registry, the normal quit path runs (session capture, config save, worker
//! drain, db close), and appDeinit re-executes the binary, which opens the new
//! profile's db and restores that profile's own session. This avoids having to
//! invalidate the dozens of in-memory caches derived from the old db.
//!
//! Pure rules (validation, PIN hashing/backoff, maturity): profiles_pure.zig.

const std = @import("std");
const builtin = @import("builtin");
const pure = @import("profiles_pure.zig");
const paths = @import("../core/paths.zig");
const io = @import("../core/io_global.zig");
const logs = @import("../core/logs.zig");
const sync = @import("../core/sync.zig");
const state = @import("../core/state.zig");

pub const Profile = pure.Profile;

var mutex: sync.Mutex = .{};
/// Guarded by `mutex`.
var reg: pure.Registry = .{};
/// The profile THIS process runs. Its id/kid/cap are fixed at boot; only its
/// name/colour/PIN can change (the person editing themselves). Guarded by `mutex`.
var running: pure.Profile = .{};
/// Kid flag of the running profile, readable lock-free every frame.
var running_kid: bool = false;

const BackoffSlot = struct { id: [pure.ID_MAX]u8 = std.mem.zeroes([pure.ID_MAX]u8), id_len: u8 = 0, b: pure.Backoff = .{} };
/// Guarded by `mutex`.
var backoffs: [pure.MAX_PROFILES]BackoffSlot = [_]BackoffSlot{.{}} ** pure.MAX_PROFILES;

var restart_requested = std.atomic.Value(bool).init(false);
var picker_needed = std.atomic.Value(bool).init(false);

var exe_buf: [1024]u8 = undefined;
var exe_len: usize = 0;

// ── Paths ────────────────────────────────────────────────────────────────────

fn registryPath(buf: []u8) []const u8 {
    var dir_buf: [512]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/profiles.tsv", .{paths.configDir(&dir_buf)}) catch "";
}

fn profilesRoot(buf: []u8) []const u8 {
    var dir_buf: [512]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/profiles", .{paths.configDir(&dir_buf)}) catch "";
}

/// Data dir of a non-default profile. Only ever built from a validated id.
fn profileDir(buf: []u8, id: []const u8) []const u8 {
    if (!pure.validId(id) or std.mem.eql(u8, id, pure.DEFAULT_ID)) return "";
    var root_buf: [600]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ profilesRoot(&root_buf), id }) catch "";
}

fn markerPath(buf: []u8) []const u8 {
    var root_buf: [600]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/.switch_ok", .{profilesRoot(&root_buf)}) catch "";
}

// ── Registry I/O ─────────────────────────────────────────────────────────────

fn loadLocked() void {
    var path_buf: [600]u8 = undefined;
    const path = registryPath(&path_buf);
    var text_buf: [pure.SERIALIZED_MAX]u8 = undefined;
    var n: usize = 0;
    if (io.cwdOpenFile(path, .{})) |f| {
        defer io.closeFile(f);
        n = io.readAll(f, &text_buf) catch 0;
    } else |_| {}
    pure.parse(text_buf[0..n], &reg);
}

fn saveLocked() bool {
    var out: [pure.SERIALIZED_MAX]u8 = undefined;
    const text = pure.serialize(&reg, &out) orelse return false;
    var path_buf: [600]u8 = undefined;
    const path = registryPath(&path_buf);
    var tmp_buf: [610]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return false;
    var dir_buf: [512]u8 = undefined;
    io.cwdMakePath(paths.configDir(&dir_buf)) catch {};
    // PIN hashes inside: owner-only, written atomically.
    @import("../core/secret_file.zig").write(tmp, text) catch return false;
    io.renameAbsolute(tmp, path) catch return false;
    return true;
}

fn idOf(p: *const Profile) [pure.ID_MAX]u8 {
    var out = std.mem.zeroes([pure.ID_MAX]u8);
    @memcpy(out[0..p.id_len], p.idText());
    return out;
}

// ── Boot ─────────────────────────────────────────────────────────────────────

/// Resolve the profile this process runs and point paths at its data dir.
/// MUST run in coreInit before db.init and before any worker exists.
pub fn initActive() void {
    mutex.lock();
    defer mutex.unlock();
    loadLocked();
    const want = reg.activeId();
    const idx = reg.find(want) orelse 0;
    running = reg.profiles[idx];
    running_kid = running.kid;
    if (!running.isDefault()) {
        var dir_buf: [600]u8 = undefined;
        const dir = profileDir(&dir_buf, running.idText());
        if (dir.len > 0) {
            io.cwdMakePath(dir) catch {};
            paths.setProfileDataDir(dir);
        }
    }

    // A switch that was already PIN-verified before the restart leaves a
    // one-shot marker naming the profile it unlocked; consume it.
    var marker_buf: [700]u8 = undefined;
    const marker = markerPath(&marker_buf);
    var unlocked = false;
    if (io.cwdOpenFile(marker, .{})) |f| {
        var b: [pure.ID_MAX + 2]u8 = undefined;
        const n = io.readAll(f, &b) catch 0;
        io.closeFile(f);
        unlocked = std.mem.eql(u8, std.mem.trim(u8, b[0..n], " \r\n"), running.idText());
        io.deleteFileAbsolute(marker) catch {};
    } else |_| {}
    picker_needed.store(!unlocked and reg.needsPicker(), .release);

    // Resolved now: the re-exec runs after the allocator and Io are torn down.
    if (io.selfExePath(&exe_buf)) |p| exe_len = p.len else |_| exe_len = 0;

    if (!running.isDefault()) {
        var msg_buf: [96]u8 = undefined;
        logs.pushLog("info", "profiles", std.fmt.bufPrint(&msg_buf, "Profile: {s}", .{running.nameText()}) catch "Profile active", false);
    }
}

// ── Queries (any thread) ─────────────────────────────────────────────────────

pub fn runningIsKid() bool {
    return running_kid;
}

pub fn runningProfile() Profile {
    mutex.lock();
    defer mutex.unlock();
    return running;
}

pub fn runningIsDefault() bool {
    mutex.lock();
    defer mutex.unlock();
    return running.isDefault();
}

/// Copy every profile into `out`; returns the count.
pub fn snapshot(out: []Profile) usize {
    mutex.lock();
    defer mutex.unlock();
    const n = @min(out.len, reg.count);
    @memcpy(out[0..n], reg.profiles[0..n]);
    return n;
}

pub fn count() usize {
    mutex.lock();
    defer mutex.unlock();
    return reg.count;
}

pub fn pickerNeeded() bool {
    return picker_needed.load(.acquire);
}

pub fn dismissPicker() void {
    picker_needed.store(false, .release);
}

pub fn restartRequested() bool {
    return restart_requested.load(.acquire);
}

/// Kid mode: the NSFW filter cannot be turned off. Cheap; called every frame
/// (desktop) / tick (headless) so no other path can leave it off.
pub fn enforce() void {
    if (running_kid and !state.app.nsfw_filter_enabled) state.app.nsfw_filter_enabled = true;
}

/// The running profile's maturity decision for a title of minimum age `age`
/// (null = unrated/unknown).
pub fn maturityAllows(age: ?u8) bool {
    mutex.lock();
    const cap = running.effectiveCap();
    const unrated = running.allow_unrated;
    mutex.unlock();
    return pure.maturityAllows(cap, age, unrated);
}

// ── Mutations ────────────────────────────────────────────────────────────────

/// Who is asking. The admin API acts as the household owner.
pub const Actor = enum { ui, admin_api };

pub const EditError = error{ Forbidden, NotFound, NameEmpty, NameTooLong, NameBadCharacter, NameTaken, BadPin, Full, Default, Running, Storage };

fn allowed(actor: Actor, target_id: []const u8) bool {
    return actor == .admin_api or pure.canEdit(&running, target_id);
}

fn ownerAction(actor: Actor) bool {
    return actor == .admin_api or (running.isDefault() and !running.kid);
}

fn checkName(raw: []const u8, except_id: []const u8) EditError![]const u8 {
    const name = pure.validateName(raw) catch |e| return switch (e) {
        error.Empty => error.NameEmpty,
        error.TooLong => error.NameTooLong,
        error.BadCharacter => error.NameBadCharacter,
    };
    if (reg.nameTaken(name, except_id)) return error.NameTaken;
    return name;
}

fn encodePin(pin: []const u8, out: *[pure.HASH_MAX]u8) ?[]const u8 {
    var salt: [pure.SALT_LEN]u8 = undefined;
    if (!io.randomSecure(&salt)) return null;
    return pure.hashPin(pin, salt, pure.PBKDF2_ROUNDS, out);
}

fn syncRunningLocked() void {
    if (reg.find(running.idText())) |i| {
        const kid = running.kid;
        const cap = running.max_age;
        const unrated = running.allow_unrated;
        running = reg.profiles[i];
        // Id/kid/cap stay as booted; a change applies on the next launch.
        running.kid = kid;
        running.max_age = cap;
        running.allow_unrated = unrated;
    }
}

/// Create a profile and seed its database with the household's shared setup.
/// `pin` may be empty. Returns the new id.
pub fn create(actor: Actor, name_raw: []const u8, color: pure.Color, kid: bool, pin: []const u8) EditError![pure.ID_MAX]u8 {
    mutex.lock();
    defer mutex.unlock();
    if (!ownerAction(actor)) return error.Forbidden;
    if (reg.count >= pure.MAX_PROFILES) return error.Full;
    const name = try checkName(name_raw, "");
    if (pin.len > 0 and !pure.validPin(pin)) return error.BadPin;

    var p: Profile = .{};
    var rnd: [pure.ID_MAX / 2]u8 = undefined;
    if (!io.randomSecure(&rnd)) return error.Storage;
    var id_buf: [pure.ID_MAX]u8 = undefined;
    p.setId(pure.idFromBytes(rnd, &id_buf));
    p.setName(name);
    p.color = color;
    p.kid = kid;
    p.max_age = if (kid) pure.KID_DEFAULT_CAP else pure.NO_CAP;
    p.created = io.timestamp();
    if (pin.len > 0) {
        var hb: [pure.HASH_MAX]u8 = undefined;
        p.setPinHash(encodePin(pin, &hb) orelse return error.Storage);
    }

    var dir_buf: [600]u8 = undefined;
    const dir = profileDir(&dir_buf, p.idText());
    if (dir.len == 0) return error.Storage;
    io.cwdMakePath(dir) catch return error.Storage;
    seedProfileDb(dir, kid);

    reg.add(p) catch return error.Full;
    if (!saveLocked()) return error.Storage;
    var msg_buf: [96]u8 = undefined;
    logs.pushLog("info", "profiles", std.fmt.bufPrint(&msg_buf, "Created profile {s}{s}", .{ name, if (kid) " (kid)" else "" }) catch "Created profile", false);
    return idOf(&p);
}

/// New profile db: just the config table, filled with the household's shared
/// setup (profiles_pure.seedsConfigKey). Everything else is created by db.init
/// on that profile's first launch — including a FRESH sync device id, so a new
/// profile never shares an identity with the one it was created from.
fn seedProfileDb(dir: []const u8, kid: bool) void {
    const db = @import("../core/db.zig");
    const c = db.c;
    var path_buf: [700]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/opal.db", .{dir}) catch return;
    var h: ?*db.Sqlite3 = null;
    if (c.sqlite3_open_v2(path.ptr, &h, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null) != c.SQLITE_OK) {
        if (h) |bad| _ = c.sqlite3_close_v2(bad);
        return;
    }
    defer _ = c.sqlite3_close_v2(h);
    _ = c.sqlite3_busy_timeout(h, 5000);
    _ = c.sqlite3_exec(h, "CREATE TABLE IF NOT EXISTS config (key TEXT PRIMARY KEY, value TEXT NOT NULL DEFAULT '')", null, null, null);

    var src_buf: [512]u8 = undefined;
    const src = paths.householdDbFile(&src_buf);
    var attach: ?*db.Stmt = null;
    if (c.sqlite3_prepare_v2(h, "ATTACH DATABASE ?1 AS household", -1, &attach, null) == c.SQLITE_OK) {
        db.bindText(attach, 1, src);
        _ = c.sqlite3_step(attach);
    }
    _ = c.sqlite3_finalize(attach);

    var sel: ?*db.Stmt = null;
    var ins: ?*db.Stmt = null;
    _ = c.sqlite3_exec(h, "BEGIN", null, null, null);
    if (c.sqlite3_prepare_v2(h, "SELECT key, value FROM household.config", -1, &sel, null) == c.SQLITE_OK and
        c.sqlite3_prepare_v2(h, "INSERT OR REPLACE INTO main.config(key, value) VALUES(?1, ?2)", -1, &ins, null) == c.SQLITE_OK)
    {
        while (c.sqlite3_step(sel) == c.SQLITE_ROW) {
            const k = db.columnText(sel, 0) orelse continue;
            if (!pure.seedsConfigKey(k)) continue;
            const v = db.columnText(sel, 1) orelse "";
            _ = c.sqlite3_reset(ins);
            db.bindText(ins, 1, k);
            db.bindText(ins, 2, v);
            _ = c.sqlite3_step(ins);
        }
    }
    _ = c.sqlite3_finalize(sel);
    _ = c.sqlite3_finalize(ins);
    if (kid) _ = c.sqlite3_exec(h, "INSERT OR REPLACE INTO main.config(key, value) VALUES('nsfw_filter', '1')", null, null, null);
    _ = c.sqlite3_exec(h, "COMMIT", null, null, null);
    _ = c.sqlite3_exec(h, "DETACH DATABASE household", null, null, null);
    @import("../core/secret_file.zig").restrictExisting(path);
}

pub fn rename(actor: Actor, id: []const u8, name_raw: []const u8) EditError!void {
    mutex.lock();
    defer mutex.unlock();
    if (!allowed(actor, id)) return error.Forbidden;
    const p = reg.get(id) orelse return error.NotFound;
    const name = try checkName(name_raw, id);
    p.setName(name);
    if (!saveLocked()) return error.Storage;
    syncRunningLocked();
}

pub fn setColor(actor: Actor, id: []const u8, color: pure.Color) EditError!void {
    mutex.lock();
    defer mutex.unlock();
    if (!allowed(actor, id)) return error.Forbidden;
    const p = reg.get(id) orelse return error.NotFound;
    p.color = color;
    if (!saveLocked()) return error.Storage;
    syncRunningLocked();
}

/// Kid flag + maturity cap + unrated policy. Owner only; never on the default
/// profile; takes effect on that profile's next launch.
pub fn setKidOptions(actor: Actor, id: []const u8, kid: bool, max_age: u8, allow_unrated: bool) EditError!void {
    mutex.lock();
    defer mutex.unlock();
    if (!ownerAction(actor)) return error.Forbidden;
    if (std.mem.eql(u8, id, pure.DEFAULT_ID)) return error.Default;
    const p = reg.get(id) orelse return error.NotFound;
    p.kid = kid;
    p.max_age = if (kid) max_age else pure.NO_CAP;
    p.allow_unrated = allow_unrated;
    if (!saveLocked()) return error.Storage;
}

/// Set (or clear, with an empty `pin`) a profile's PIN.
pub fn setPin(actor: Actor, id: []const u8, pin: []const u8) EditError!void {
    mutex.lock();
    defer mutex.unlock();
    if (!allowed(actor, id)) return error.Forbidden;
    const p = reg.get(id) orelse return error.NotFound;
    if (pin.len == 0) {
        p.pin_hash_len = 0;
    } else {
        if (!pure.validPin(pin)) return error.BadPin;
        var hb: [pure.HASH_MAX]u8 = undefined;
        p.setPinHash(encodePin(pin, &hb) orelse return error.Storage);
    }
    if (!saveLocked()) return error.Storage;
    syncRunningLocked();
}

/// Delete a profile and its data. Never the default, never the running one.
pub fn delete(actor: Actor, id: []const u8) EditError!void {
    mutex.lock();
    defer mutex.unlock();
    if (!ownerAction(actor)) return error.Forbidden;
    if (std.mem.eql(u8, id, pure.DEFAULT_ID)) return error.Default;
    if (std.mem.eql(u8, id, running.idText())) return error.Running;
    var name_buf: [pure.NAME_MAX]u8 = undefined;
    const p = reg.get(id) orelse return error.NotFound;
    const name_len = p.name_len;
    @memcpy(name_buf[0..name_len], p.nameText());
    reg.remove(id) catch return error.NotFound;
    if (!saveLocked()) return error.Storage;
    var dir_buf: [600]u8 = undefined;
    const dir = profileDir(&dir_buf, id);
    if (dir.len > 0) io.cwdDeleteTree(dir) catch {};
    var msg_buf: [96]u8 = undefined;
    logs.pushLog("info", "profiles", std.fmt.bufPrint(&msg_buf, "Deleted profile {s}", .{name_buf[0..name_len]}) catch "Deleted profile", false);
}

// ── Switching ────────────────────────────────────────────────────────────────

pub const SwitchResult = union(enum) {
    /// Restarting into the profile.
    switching,
    /// It is the running profile (picker dismissed, nothing to do).
    same,
    not_found,
    /// A PIN is required (whose: target's own or the owner's).
    pin_required: pure.PinSource,
    bad_pin: pure.PinSource,
    locked_ms: i64,
    storage,
};

fn backoffFor(id: []const u8) *pure.Backoff {
    for (&backoffs) |*s| if (s.id_len > 0 and std.mem.eql(u8, s.id[0..s.id_len], id)) return &s.b;
    for (&backoffs) |*s| if (s.id_len == 0) {
        @memcpy(s.id[0..id.len], id);
        s.id_len = @intCast(id.len);
        s.b = .{};
        return &s.b;
    };
    backoffs[0] = .{};
    @memcpy(backoffs[0].id[0..id.len], id);
    backoffs[0].id_len = @intCast(id.len);
    return &backoffs[0].b;
}

/// Which PIN a switch to `id` needs (for the picker's prompt).
pub fn pinSourceFor(id: []const u8) ?pure.PinSource {
    mutex.lock();
    defer mutex.unlock();
    const i = reg.find(id) orelse return null;
    if (std.mem.eql(u8, id, running.idText()) and !picker_needed.load(.acquire)) return .none;
    const owner_pin = if (reg.defaultProfile()) |d| d.hasPin() else false;
    return pure.pinSourceFor(running_kid, &reg.profiles[i], owner_pin);
}

/// Verify the PIN policy and, when it passes, restart into `id`. At launch
/// (picker shown) choosing the running profile still requires its PIN, then
/// just dismisses the picker.
pub fn requestSwitch(id: []const u8, pin: []const u8) SwitchResult {
    mutex.lock();
    defer mutex.unlock();
    const i = reg.find(id) orelse return .not_found;
    const target = &reg.profiles[i];
    const is_running = std.mem.eql(u8, id, running.idText());
    const at_picker = picker_needed.load(.acquire);
    if (is_running and !at_picker) return .same;

    const owner = reg.defaultProfile();
    const owner_pin = if (owner) |d| d.hasPin() else false;
    const source = pure.pinSourceFor(running_kid, target, owner_pin);
    if (source != .none) {
        const check_id = if (source == .target) id else pure.DEFAULT_ID;
        const hash = if (source == .target) target.pinHash() else (owner orelse return .not_found).pinHash();
        const bo = backoffFor(check_id);
        const now = io.milliTimestamp();
        const wait = bo.retryAfterMs(now);
        if (wait > 0) return .{ .locked_ms = wait };
        if (pin.len == 0) return .{ .pin_required = source };
        if (!pure.verifyPin(pin, hash)) {
            bo.recordFailure(now);
            const w = bo.retryAfterMs(now);
            if (w > 0) return .{ .locked_ms = w };
            return .{ .bad_pin = source };
        }
        bo.recordSuccess();
    }

    if (is_running) {
        picker_needed.store(false, .release);
        return .same;
    }

    reg.setActive(id);
    if (!saveLocked()) return .storage;
    // One-shot proof for the next boot that this profile was unlocked here.
    var root_buf: [600]u8 = undefined;
    io.cwdMakePath(profilesRoot(&root_buf)) catch {};
    var marker_buf: [700]u8 = undefined;
    @import("../core/secret_file.zig").write(markerPath(&marker_buf), id) catch {};
    var msg_buf: [96]u8 = undefined;
    logs.pushLog("info", "profiles", std.fmt.bufPrint(&msg_buf, "Switching to profile {s}", .{target.nameText()}) catch "Switching profile", false);
    restart_requested.store(true, .release);
    state.wakeUi();
    return .switching;
}

// ── Restart ──────────────────────────────────────────────────────────────────

const posix_c = struct {
    extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
    extern "c" fn _NSGetEnviron() *[*:null]?[*:0]u8;
};

/// Last step of appDeinit: re-execute Opal into the profile chosen by
/// `requestSwitch`. No-op unless a switch was requested. POSIX replaces the
/// process image (same pid, so supervisors and the live tests keep tracking
/// it); Windows starts a fresh process and lets this one exit.
pub fn restartAfterShutdown() void {
    if (!restart_requested.load(.acquire) or exe_len == 0) return;
    if (comptime builtin.os.tag == .windows) {
        var child = io.Child.init(&.{exe_buf[0..exe_len]}, @import("../core/alloc.zig").allocator);
        child.stdin_behavior = .Ignore;
        child.spawn() catch {};
        return;
    } else {
        var path_z: [1025]u8 = undefined;
        @memcpy(path_z[0..exe_len], exe_buf[0..exe_len]);
        path_z[exe_len] = 0;
        const path: [*:0]const u8 = @ptrCast(&path_z);
        const argv = [_:null]?[*:0]const u8{path};
        const envp: [*:null]const ?[*:0]const u8 = if (comptime builtin.os.tag == .macos)
            @ptrCast(posix_c._NSGetEnviron().*)
        else
            @ptrCast(std.c.environ);
        _ = posix_c.execve(path, &argv, envp);
        // exec failed: fall through to a normal exit; the registry already
        // names the new profile, so the next manual launch opens it.
    }
}
