//! DB-backed user + session store for the headless account system (A2).
//!
//! Passwords are bcrypt-hashed via `auth_pure` (the tested logic). Sessions are
//! opaque random tokens stored in SQLite; the remote Bearer gate accepts a live
//! session token OR the static `api.token` file (so the extension/automation
//! keep working while humans log in). Same auth for headless AND desktop-remote
//! — there is no pairing code any more.

const std = @import("std");
const db = @import("../core/db.zig");
const auth = @import("auth_pure.zig");
const io = @import("../core/io_global.zig");

/// 24 random bytes → 48 hex chars.
pub const TOKEN_HEX = 48;
const SESSION_TTL_S: i64 = 30 * 24 * 3600; // 30 days

// ── CSPRNG bytes from /dev/urandom (same source as remote.zig's token) ──
fn fillRandom(buf: []u8) bool {
    if (io.openFileAbsolute("/dev/urandom", .{})) |f| {
        var fh = f;
        defer fh.close(io.io());
        const n = io.readAll(fh, buf) catch return false;
        return n == buf.len;
    } else |_| return false;
}

fn hexEncode(bytes: []const u8, out: []u8) void {
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
}

/// Create the users + sessions tables. Called from db.init().
pub fn ensureTables() void {
    db.exec(
        \\CREATE TABLE IF NOT EXISTS users (
        \\  id INTEGER PRIMARY KEY,
        \\  username TEXT UNIQUE NOT NULL COLLATE NOCASE,
        \\  pw_hash TEXT NOT NULL,
        \\  is_admin INTEGER NOT NULL DEFAULT 0,
        \\  created_at INTEGER NOT NULL
        \\)
    );
    db.exec(
        \\CREATE TABLE IF NOT EXISTS sessions (
        \\  token TEXT PRIMARY KEY,
        \\  user_id INTEGER NOT NULL,
        \\  created_at INTEGER NOT NULL,
        \\  expires_at INTEGER NOT NULL
        \\)
    );
}

/// How many accounts exist. Zero → first-run (the web UI shows "create admin").
pub fn userCount() i64 {
    const stmt = db.prepare("SELECT COUNT(*) FROM users") orelse return 0;
    defer db.finalize(stmt);
    if (db.step(stmt) != db.c.SQLITE_ROW) return 0;
    return db.columnInt64(stmt, 0);
}

pub const CreateError = error{ Invalid, Taken, Db };

/// Create a user (bcrypt-hashed). `error.Taken` if the username exists,
/// `error.Invalid` if username/password fail validation.
pub fn createUser(username: []const u8, password: []const u8, is_admin: bool) CreateError!void {
    if (!auth.validUsername(username) or !auth.validPassword(password)) return error.Invalid;
    var salt: [auth.SALT_LEN]u8 = undefined;
    if (!fillRandom(&salt)) return error.Db;
    var hbuf: [auth.HASH_BUF]u8 = undefined;
    const hash = auth.hashWithSalt(password, salt, &hbuf) catch return error.Db;

    const stmt = db.prepare("INSERT INTO users(username,pw_hash,is_admin,created_at) VALUES(?1,?2,?3,?4)") orelse return error.Db;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, username);
    db.bindText(stmt, 2, hash);
    db.bindInt(stmt, 3, if (is_admin) 1 else 0);
    db.bindInt64(stmt, 4, io.timestamp());
    const rc = db.step(stmt);
    if (rc == db.c.SQLITE_CONSTRAINT) return error.Taken;
    if (rc != db.c.SQLITE_DONE) return error.Db;
}

/// Verify credentials → user id, or null. Constant-time within bcrypt.
pub fn authenticate(username: []const u8, password: []const u8) ?i64 {
    const stmt = db.prepare("SELECT id, pw_hash FROM users WHERE username=?1 COLLATE NOCASE") orelse return null;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, username);
    if (db.step(stmt) != db.c.SQLITE_ROW) return null;
    const id = db.columnInt64(stmt, 0);
    const hash = db.columnText(stmt, 1) orelse return null;
    if (!auth.verify(hash, password)) return null;
    return id;
}

/// Issue a session for `user_id`; writes the hex token into `out`.
pub fn issueSession(user_id: i64, out: *[TOKEN_HEX]u8) bool {
    var raw: [TOKEN_HEX / 2]u8 = undefined;
    if (!fillRandom(&raw)) return false;
    hexEncode(&raw, out);
    const now = io.timestamp();
    const stmt = db.prepare("INSERT INTO sessions(token,user_id,created_at,expires_at) VALUES(?1,?2,?3,?4)") orelse return false;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, out);
    db.bindInt64(stmt, 2, user_id);
    db.bindInt64(stmt, 3, now);
    db.bindInt64(stmt, 4, now + SESSION_TTL_S);
    return db.step(stmt) == db.c.SQLITE_DONE;
}

/// Bearer gate: is this a live (unexpired) session token?
pub fn validSession(token: []const u8) bool {
    if (token.len == 0 or token.len > TOKEN_HEX) return false;
    const stmt = db.prepare("SELECT expires_at FROM sessions WHERE token=?1") orelse return false;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, token);
    if (db.step(stmt) != db.c.SQLITE_ROW) return false;
    return db.columnInt64(stmt, 0) > io.timestamp();
}

pub fn revokeSession(token: []const u8) void {
    const stmt = db.prepare("DELETE FROM sessions WHERE token=?1") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, token);
    _ = db.step(stmt);
}

/// Drop expired sessions. Cheap; call on startup.
pub fn pruneExpired() void {
    const stmt = db.prepare("DELETE FROM sessions WHERE expires_at <= ?1") orelse return;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, io.timestamp());
    _ = db.step(stmt);
}
