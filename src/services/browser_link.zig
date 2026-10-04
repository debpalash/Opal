//! Paired browsers (Opal Connect): the one-time pairing code and the stored
//! per-browser tokens. The rules live in browser_link_pure.zig; this file adds
//! the clock, the entropy source, a mutex and SQLite.
//!
//! The code exists only in this process's memory, shown in Settings > Agent
//! Access and never written to a log, the API or the database, so nothing an
//! agent can read reveals it. A token is shown once, to the browser that paired,
//! and stored only as a SHA-256 hash.

const std = @import("std");
const db = @import("../core/db.zig");
const io = @import("../core/io_global.zig");
const sync = @import("../core/sync.zig");
const pure = @import("browser_link_pure.zig");

var mutex: sync.Mutex = .{};
var pairing: pure.Pairing = .{};

pub const Token = [pure.TOKEN_LEN]u8;

pub fn ensureTables() void {
    db.exec(
        \\CREATE TABLE IF NOT EXISTS browser_links (
        \\  id INTEGER PRIMARY KEY,
        \\  token_hash TEXT UNIQUE NOT NULL,
        \\  label TEXT NOT NULL,
        \\  browser TEXT NOT NULL,
        \\  extension_id TEXT NOT NULL,
        \\  created_at INTEGER NOT NULL,
        \\  last_seen INTEGER NOT NULL
        \\)
    );
}

// ── Pairing code (UI side) ─────────────────────────────────────────────────

pub const PairingView = struct {
    active: bool = false,
    code: [pure.CODE_LEN]u8 = @splat('0'),
    remaining: i64 = 0,
};

/// Start (or restart) pairing. Called from the Settings button, i.e. by the user
/// at the keyboard; there is deliberately no HTTP route that reaches it.
pub fn startPairing() bool {
    var code: [pure.CODE_LEN]u8 = undefined;
    var tries: usize = 0;
    while (tries < 8) : (tries += 1) {
        var raw: [4]u8 = undefined;
        if (!io.randomSecure(&raw)) return false;
        if (pure.codeFromRandom(std.mem.readInt(u32, &raw, .little))) |c| {
            code = c;
            break;
        }
    } else return false;
    mutex.lock();
    defer mutex.unlock();
    pure.issue(&pairing, io.timestamp(), code);
    return true;
}

pub fn cancelPairing() void {
    mutex.lock();
    defer mutex.unlock();
    pure.cancel(&pairing);
}

pub fn pairingView() PairingView {
    mutex.lock();
    defer mutex.unlock();
    const left = pure.remaining(&pairing, io.timestamp());
    if (left == 0) return .{};
    return .{ .active = true, .code = pairing.code, .remaining = left };
}

// ── Pairing (HTTP side) ────────────────────────────────────────────────────

pub const PairResult = union(enum) {
    ok: struct { id: i64, token: Token },
    wrong_code,
    burned,
    expired,
    no_code,
    full,
    unavailable,
};

fn countLinks() ?i64 {
    const stmt = db.prepare("SELECT COUNT(*) FROM browser_links") orelse return null;
    defer db.finalize(stmt);
    if (db.step(stmt) != db.c.SQLITE_ROW) return null;
    return db.columnInt64(stmt, 0);
}

/// Judge a pairing attempt and, on success, mint and store the token. The whole
/// decision runs under one lock so two simultaneous correct guesses cannot both
/// win: the first one consumes the code.
pub fn pair(presented_code: []const u8, label_in: []const u8, browser_in: []const u8, extension_in: []const u8) PairResult {
    var label_buf: [pure.MAX_LABEL]u8 = undefined;
    var browser_buf: [32]u8 = undefined;
    var ext_buf: [64]u8 = undefined;
    const label = pure.sanitizeText(label_in, &label_buf);
    const browser = pure.sanitizeText(browser_in, &browser_buf);
    const ext = pure.sanitizeText(extension_in, &ext_buf);

    mutex.lock();
    defer mutex.unlock();

    // Refuse before the attempt, without counting it, so a full table neither
    // eats a good code nor tells a guesser anything about the code.
    const existing = countLinks() orelse return .unavailable;
    if (existing >= pure.MAX_LINKS) return .full;

    switch (pure.attempt(&pairing, io.timestamp(), presented_code)) {
        .ok => {},
        .wrong_code => return .wrong_code,
        .burned => return .burned,
        .expired => return .expired,
        .no_code => return .no_code,
    }

    var raw: [pure.TOKEN_RAW_LEN]u8 = undefined;
    if (!io.randomSecure(&raw)) return .unavailable;
    const token = pure.formatToken(raw);
    const hash = pure.hashToken(&token);
    const now = io.timestamp();

    const stmt = db.prepare(
        \\INSERT INTO browser_links(token_hash,label,browser,extension_id,created_at,last_seen)
        \\VALUES(?1,?2,?3,?4,?5,?5) RETURNING id
    ) orelse return .unavailable;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, &hash);
    db.bindText(stmt, 2, label);
    db.bindText(stmt, 3, browser);
    db.bindText(stmt, 4, ext);
    db.bindInt64(stmt, 5, now);
    if (db.step(stmt) != db.c.SQLITE_ROW) return .unavailable;
    return .{ .ok = .{ .id = db.columnInt64(stmt, 0), .token = token } };
}

// ── Tokens ─────────────────────────────────────────────────────────────────

/// Link id for a live browser token, or null. Refreshes `last_seen` at most
/// every 30 seconds so a busy panel does not write on every request.
pub fn validToken(token: []const u8) ?i64 {
    if (!pure.plausibleToken(token)) return null;
    const hash = pure.hashToken(token);
    const stmt = db.prepare("SELECT id,last_seen FROM browser_links WHERE token_hash=?1") orelse return null;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, &hash);
    if (db.step(stmt) != db.c.SQLITE_ROW) return null;
    const id = db.columnInt64(stmt, 0);
    const last_seen = db.columnInt64(stmt, 1);
    const now = io.timestamp();
    if (now - last_seen >= 30) touch(id, now);
    return id;
}

fn touch(id: i64, now: i64) void {
    const stmt = db.prepare("UPDATE browser_links SET last_seen=?1 WHERE id=?2") orelse return;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, now);
    db.bindInt64(stmt, 2, id);
    _ = db.step(stmt);
}

pub fn revoke(id: i64) bool {
    const stmt = db.prepare("DELETE FROM browser_links WHERE id=?1 RETURNING id") orelse return false;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, id);
    return db.step(stmt) == db.c.SQLITE_ROW;
}

/// Unpair the browser that presented `token`. True when a link was removed.
pub fn revokeToken(token: []const u8) bool {
    if (!pure.plausibleToken(token)) return false;
    const hash = pure.hashToken(token);
    const stmt = db.prepare("DELETE FROM browser_links WHERE token_hash=?1 RETURNING id") orelse return false;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, &hash);
    return db.step(stmt) == db.c.SQLITE_ROW;
}

// ── Listing ────────────────────────────────────────────────────────────────

pub const Link = struct {
    id: i64 = 0,
    label: [pure.MAX_LABEL]u8 = undefined,
    label_len: usize = 0,
    browser: [32]u8 = undefined,
    browser_len: usize = 0,
    created_at: i64 = 0,
    last_seen: i64 = 0,

    pub fn labelSlice(self: *const Link) []const u8 {
        return self.label[0..self.label_len];
    }
    pub fn browserSlice(self: *const Link) []const u8 {
        return self.browser[0..self.browser_len];
    }
};

fn copyInto(dst: []u8, src: ?[]const u8) usize {
    const s = src orelse return 0;
    const n = @min(s.len, dst.len);
    @memcpy(dst[0..n], s[0..n]);
    return n;
}

pub fn list(out: []Link) usize {
    const stmt = db.prepare("SELECT id,label,browser,created_at,last_seen FROM browser_links ORDER BY id") orelse return 0;
    defer db.finalize(stmt);
    var n: usize = 0;
    while (n < out.len and db.step(stmt) == db.c.SQLITE_ROW) : (n += 1) {
        out[n].id = db.columnInt64(stmt, 0);
        out[n].label_len = copyInto(&out[n].label, db.columnText(stmt, 1));
        out[n].browser_len = copyInto(&out[n].browser, db.columnText(stmt, 2));
        out[n].created_at = db.columnInt64(stmt, 3);
        out[n].last_seen = db.columnInt64(stmt, 4);
    }
    return n;
}

pub fn linkById(id: i64, out: *Link) bool {
    var rows: [pure.MAX_LINKS + 1]Link = undefined;
    const n = list(&rows);
    for (rows[0..n]) |row| {
        if (row.id == id) {
            out.* = row;
            return true;
        }
    }
    return false;
}
