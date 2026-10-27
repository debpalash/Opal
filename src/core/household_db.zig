//! Household-wide SQLite access (ROADMAP 7.3 profiles).
//!
//! Each household profile has its own opal.db (paths.zigzagDbFile), but some
//! tables belong to the machine, not a person: web-UI accounts + sessions
//! (auth_store.zig) and paired browsers (browser_link.zig). Switching profile
//! must never make the admin account "disappear" (that would reopen first-run
//! admin setup) or unpair a browser. Those modules import this file instead of
//! db.zig; it exposes the same call surface.
//!
//! Default profile: every call goes to db.zig's shared connection (the same
//! file), so single-profile installs behave exactly as before. Another profile:
//! a dedicated FULLMUTEX connection to the default profile's database.

const std = @import("std");
const db = @import("db.zig");
const paths = @import("paths.zig");
const sync = @import("sync.zig");

pub const c = db.c;
pub const Stmt = db.Stmt;
pub const finalize = db.finalize;
pub const step = db.step;
pub const bindInt = db.bindInt;
pub const bindInt64 = db.bindInt64;
pub const bindText = db.bindText;
pub const columnInt = db.columnInt;
pub const columnInt64 = db.columnInt64;
pub const columnText = db.columnText;

var handle: ?*db.Sqlite3 = null;
var open_mutex: sync.Mutex = .{};

fn connection() ?*db.Sqlite3 {
    if (!paths.profileActive()) return db.get();
    open_mutex.lock();
    defer open_mutex.unlock();
    if (handle) |h| return h;
    var path_buf: [512]u8 = undefined;
    var cpath_buf: [520]u8 = undefined;
    const cpath = std.fmt.bufPrintZ(&cpath_buf, "{s}", .{paths.householdDbFile(&path_buf)}) catch return null;
    var h: ?*db.Sqlite3 = null;
    const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
    if (c.sqlite3_open_v2(cpath.ptr, &h, flags, null) != c.SQLITE_OK) {
        if (h) |bad| _ = c.sqlite3_close_v2(bad);
        return null;
    }
    _ = c.sqlite3_busy_timeout(h, 5000);
    _ = c.sqlite3_exec(h, "PRAGMA journal_mode=WAL", null, null, null);
    handle = h;
    return h;
}

pub fn exec(sql: [*:0]const u8) void {
    const h = connection() orelse return;
    _ = c.sqlite3_exec(h, sql, null, null, null);
}

pub fn prepare(sql: []const u8) ?*Stmt {
    const h = connection() orelse return null;
    var stmt: ?*Stmt = null;
    if (c.sqlite3_prepare_v2(h, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) {
        if (stmt) |s| _ = c.sqlite3_finalize(s);
        return null;
    }
    return stmt;
}

/// Called from db.deinit after every worker is drained.
pub fn deinit() void {
    open_mutex.lock();
    defer open_mutex.unlock();
    if (handle) |h| _ = c.sqlite3_close_v2(h);
    handle = null;
}
