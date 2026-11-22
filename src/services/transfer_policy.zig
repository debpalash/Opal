//! Transfer policy executor: samples every disk-backed torrent on the stall
//! watchdog thread (2 Hz), runs transfer_policy_pure.step, performs the one
//! action it returns, and persists the typed state into
//! active_torrent_intents so it survives restart.
//!
//! RAM-only streams are ephemeral and never managed here. Incognito sessions
//! are enforced but never persisted.

const std = @import("std");
const c = @import("../core/c.zig");
const db = @import("../core/db.zig");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const io_g = @import("../core/io_global.zig");
const sync = @import("../core/sync.zig");
const pure = @import("transfer_policy_pure.zig");
const intent_pure = @import("torrent_intent_pure.zig");

// ── Config snapshot (UI thread → watchdog thread) ────────────────────────────

var cfg_max_active = std.atomic.Value(u32).init(0);
var cfg_reserve_mb = std.atomic.Value(u32).init(256);
var cfg_ratio_x100 = std.atomic.Value(u32).init(0);
var cfg_seed_minutes = std.atomic.Value(u32).init(0);
var cfg_published = std.atomic.Value(bool).init(false);

var root_lock: sync.Mutex = .{};
var root_buf: [257]u8 = std.mem.zeroes([257]u8);
var root_len: usize = 0;

/// Main loop: publish the settings and download root for the watchdog thread.
pub fn publishConfig() void {
    if (!state.app.init_history_loaded) return;
    cfg_max_active.store(state.app.torrent_max_active, .release);
    cfg_reserve_mb.store(state.app.torrent_reserve_mb, .release);
    cfg_ratio_x100.store(state.app.torrent_seed_ratio_x100, .release);
    cfg_seed_minutes.store(state.app.torrent_seed_minutes, .release);
    const n = @min(state.app.save_path_len, root_buf.len - 1);
    root_lock.lock();
    @memcpy(root_buf[0..n], state.app.save_path_buf[0..n]);
    root_buf[n] = 0;
    root_len = n;
    root_lock.unlock();
    cfg_published.store(true, .release);
}

fn policy() pure.Policy {
    return .{
        .max_active = cfg_max_active.load(.acquire),
        .reserve_bytes = @as(u64, cfg_reserve_mb.load(.acquire)) * pure.MiB,
        .seed_ratio_x100 = cfg_ratio_x100.load(.acquire),
        .seed_minutes = cfg_seed_minutes.load(.acquire),
    };
}

// ── Playback marks ───────────────────────────────────────────────────────────

var interactive_lock: sync.Mutex = .{};
var interactive_ids: [64]i32 = @splat(-1);
var interactive_next: usize = 0;

/// A player opened this torrent: it is never queued behind background downloads.
pub fn markInteractive(id: i32) void {
    if (id < 0) return;
    interactive_lock.lock();
    defer interactive_lock.unlock();
    for (interactive_ids) |v| if (v == id) return;
    interactive_ids[interactive_next] = id;
    interactive_next = (interactive_next + 1) % interactive_ids.len;
}

fn isInteractive(id: i32) bool {
    interactive_lock.lock();
    defer interactive_lock.unlock();
    for (interactive_ids) |v| if (v == id) return true;
    return false;
}

// ── Per-torrent records ──────────────────────────────────────────────────────

const MAX_SLOTS = 64;
const PERSIST_EVERY_S: i64 = 60;

const Slot = struct {
    id: i32 = -1,
    rec: pure.Record = .{},
    identity: [intent_pure.MAX_IDENTITY]u8 = undefined,
    identity_len: usize = 0,
    paths_checked: bool = false,
    paths_ok: bool = true,
    last_sample_s: i64 = 0,
    last_persist_s: i64 = 0,
};

var lock: sync.Mutex = .{};
var slots: [MAX_SLOTS]Slot = @splat(.{});

/// Current typed state for the API, or null when the torrent is unmanaged.
pub fn stateOf(id: i32) ?pure.State {
    lock.lock();
    defer lock.unlock();
    for (&slots) |*s| if (s.id == id) return s.rec.state;
    return null;
}

fn identityFor(ses: c.mpv.TorrentSession, id: i32, out: []u8) ?[]const u8 {
    var raw: [intent_pure.MAX_IDENTITY + 1]u8 = std.mem.zeroes([intent_pure.MAX_IDENTITY + 1]u8);
    if (c.mpv.torrent_get_identity_magnet(ses, id, &raw, raw.len) != 0) return null;
    const raw_len = std.mem.indexOfScalar(u8, &raw, 0) orelse return null;
    return intent_pure.canonicalIdentity(raw[0..raw_len], out);
}

/// Load the persisted record for `identity`; null when nothing usable is stored.
fn loadRecord(identity: []const u8) ?pure.Record {
    if (db.get() == null) return null;
    const stmt = db.prepare("SELECT state, seed_seconds, uploaded, goal_waived FROM active_torrent_intents WHERE identity = ?1") orelse return null;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, identity);
    if (db.step(stmt) != db.c.SQLITE_ROW) return null;
    const tag = db.columnText(stmt, 0) orelse return null;
    const st = pure.parseState(tag) orelse return null;
    return .{
        .state = st,
        .seed_seconds = @intCast(std.math.clamp(db.columnInt64(stmt, 1), 0, std.math.maxInt(u32))),
        .uploaded = @intCast(@max(db.columnInt64(stmt, 2), 0)),
        .goal_waived = db.columnInt(stmt, 3) != 0,
    };
}

/// UPDATE only: the row's lifetime belongs to torrent_intents (insert on
/// accept, delete on removal), so a late write can never resurrect a removed
/// transfer.
fn persist(s: *const Slot) void {
    if (state.app.incognito_mode or db.get() == null or s.identity_len == 0) return;
    const stmt = db.prepare(
        "UPDATE active_torrent_intents SET state = ?1, seed_seconds = ?2, uploaded = ?3, goal_waived = ?4 WHERE identity = ?5",
    ) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, pure.stateTag(s.rec.state));
    db.bindInt64(stmt, 2, s.rec.seed_seconds);
    db.bindInt64(stmt, 3, @intCast(@min(s.rec.uploaded, std.math.maxInt(i64))));
    db.bindInt(stmt, 4, if (s.rec.goal_waived) 1 else 0);
    db.bindText(stmt, 5, s.identity[0..s.identity_len]);
    _ = db.step(stmt);
}

/// Every file path must stay inside the download root. Checked once, after
/// metadata arrives.
fn pathsContained(ses: c.mpv.TorrentSession, id: i32) bool {
    const n = c.mpv.torrent_get_file_count(ses, id);
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        var buf: [1024]u8 = std.mem.zeroes([1024]u8);
        c.mpv.torrent_get_file_path(ses, id, i, &buf, buf.len);
        const len = std.mem.indexOfScalar(u8, &buf, 0) orelse buf.len;
        if (!pure.relativeContained(buf[0..len])) return false;
    }
    return true;
}

fn activeOthers(self_idx: usize) u32 {
    var n: u32 = 0;
    for (&slots, 0..) |*s, i| {
        if (i != self_idx and s.id >= 0 and pure.occupiesSlot(s.rec.state)) n += 1;
    }
    return n;
}

fn describe(ses: c.mpv.TorrentSession, id: i32, from: pure.State, to: pure.State) void {
    var nbuf: [128]u8 = undefined;
    nbuf[0] = 0;
    c.mpv.torrent_get_name(ses, id, &nbuf, nbuf.len);
    const nlen = std.mem.indexOfScalar(u8, &nbuf, 0) orelse nbuf.len;
    const name = @import("../core/text.zig").safeUtf8(nbuf[0..@min(nlen, 60)]);
    var msg: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&msg, "{s} -> {s}: {s}", .{ pure.stateTag(from), pure.stateTag(to), name }) catch return;
    logs.pushLog(if (to == .rejected or to == .blocked_disk) "warn" else "info", "transfer", line, false);
}

/// Watchdog thread, 2 Hz (torrent_stall.tick).
pub fn tick(ses: c.mpv.TorrentSession, toast: *const fn ([]const u8) void) void {
    if (!cfg_published.load(.acquire)) return;
    // Wait for SQLite so a restored transfer is classified from its persisted
    // state, not mistaken for a fresh add.
    if (!state.app.incognito_mode and db.get() == null) return;

    const p = policy();
    const now_s = io_g.timestamp();

    var root: [257]u8 = undefined;
    root_lock.lock();
    const rlen = root_len;
    @memcpy(root[0 .. rlen + 1], root_buf[0 .. rlen + 1]);
    root_lock.unlock();
    const free_raw: i64 = if (rlen > 0) c.mpv.torrent_disk_free_bytes(@ptrCast(&root)) else -1;
    const free: ?u64 = if (free_raw >= 0) @intCast(free_raw) else null;

    lock.lock();
    defer lock.unlock();

    for (&slots) |*s| {
        if (s.id >= 0 and c.mpv.torrent_is_alive(ses, s.id) == 0) s.* = .{};
    }

    const total = c.mpv.torrent_count(ses);
    var id: i32 = 0;
    while (id < total) : (id += 1) {
        if (c.mpv.torrent_is_alive(ses, id) == 0) continue;
        var tf: c.mpv.TorrentTransferFacts = undefined;
        if (c.mpv.torrent_get_transfer_facts(ses, id, &tf) != 0 or tf.is_memory != 0) continue;

        var idx: ?usize = null;
        var free_idx: ?usize = null;
        for (&slots, 0..) |*s, i| {
            if (s.id == id) {
                idx = i;
                break;
            }
            if (s.id < 0 and free_idx == null) free_idx = i;
        }

        const facts = pure.Facts{
            .paused = tf.paused != 0,
            .errored = tf.has_error != 0,
            .has_metadata = tf.has_metadata != 0,
            .wanted = @intCast(@max(tf.total_wanted, 0)),
            .wanted_done = @intCast(@max(tf.total_wanted_done, 0)),
            .uploaded = @intCast(@max(tf.all_time_upload, 0)),
            .free_bytes = free,
            .streaming = @import("../player/stream_proxy.zig").isServingTorrent(id),
            .interactive = isInteractive(id),
            .paths_ok = true,
        };

        var ctx = pure.Context{};
        const k = idx orelse blk: {
            const k = free_idx orelse continue; // table full: unmanaged, never a crash
            const s = &slots[k];
            s.* = .{ .id = id, .last_sample_s = now_s, .last_persist_s = now_s };
            if (identityFor(ses, id, &s.identity)) |ident| s.identity_len = ident.len;
            if (s.identity_len > 0) {
                if (loadRecord(s.identity[0..s.identity_len])) |rec| {
                    s.rec = rec;
                    ctx.restored = true;
                }
            }
            if (!ctx.restored) {
                s.rec.state = pure.initialState(facts);
                ctx.first_sight = true;
            }
            break :blk k;
        };
        const s = &slots[k];

        if (facts.has_metadata and !s.paths_checked) {
            s.paths_checked = true;
            s.paths_ok = pathsContained(ses, id);
        }
        var f = facts;
        f.paths_ok = s.paths_ok;

        ctx.active_others = activeOthers(k);
        ctx.dt_s = @intCast(std.math.clamp(now_s - s.last_sample_s, 0, 60));
        s.last_sample_s = now_s;

        const before = s.rec.state;
        const action = pure.step(&s.rec, f, p, ctx);
        switch (action) {
            .none => {},
            .pause => c.mpv.torrent_pause(ses, id),
            .resume_ => c.mpv.torrent_resume(ses, id),
        }

        const changed = before != s.rec.state;
        if (changed) {
            describe(ses, id, before, s.rec.state);
            switch (s.rec.state) {
                .blocked_disk => toast("Download paused: not enough free disk space."),
                .rejected => toast("Torrent stopped: a file path escapes the download folder."),
                else => {},
            }
        }
        if (changed or ctx.first_sight or ctx.restored or now_s - s.last_persist_s >= PERSIST_EVERY_S) {
            s.last_persist_s = now_s;
            persist(s);
        }
    }
}
