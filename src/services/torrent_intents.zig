//! Durable active-torrent intent without persisting tracker URLs or passkeys.

const std = @import("std");
const c = @import("../core/c.zig");
const db = @import("../core/db.zig");
const state = @import("../core/state.zig");
const pure = @import("torrent_intent_pure.zig");

var restore_state = std.atomic.Value(u8).init(0); // 0 waiting, 1 restoring, 2 done

fn identityForTorrent(id: c_int, out: []u8) ?[]const u8 {
    const ses = state.torrentSession();
    if (ses == null) return null;
    var raw: [pure.MAX_IDENTITY + 1]u8 = std.mem.zeroes([pure.MAX_IDENTITY + 1]u8);
    if (c.mpv.torrent_get_identity_magnet(ses, id, &raw, raw.len) != 0) return null;
    const raw_len = std.mem.indexOfScalar(u8, &raw, 0) orelse return null;
    return pure.canonicalIdentity(raw[0..raw_len], out);
}

/// Remember an accepted torrent. Safe before metadata arrives and a no-op in
/// incognito mode. If SQLite is still starting, restoreIfReady's live scan
/// captures it once the database is published.
pub fn rememberTorrent(id: c_int) void {
    if (state.app.incognito_mode or db.get() == null) return;
    var identity_buf: [pure.MAX_IDENTITY]u8 = undefined;
    const identity = identityForTorrent(id, &identity_buf) orelse return;
    const paused: i32 = if (c.mpv.torrent_is_paused(state.torrentSession(), id) != 0) 1 else 0;
    const stmt = db.prepare(
        "INSERT INTO active_torrent_intents(identity, paused) VALUES (?1, ?2) " ++
            "ON CONFLICT(identity) DO UPDATE SET paused=excluded.paused",
    ) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, identity);
    db.bindInt(stmt, 2, paused);
    _ = db.step(stmt);
}

pub fn setPaused(id: c_int, paused: bool) void {
    if (state.app.incognito_mode or db.get() == null) return;
    var identity_buf: [pure.MAX_IDENTITY]u8 = undefined;
    const identity = identityForTorrent(id, &identity_buf) orelse return;
    const stmt = db.prepare("UPDATE active_torrent_intents SET paused = ?1 WHERE identity = ?2") orelse return;
    defer db.finalize(stmt);
    db.bindInt(stmt, 1, if (paused) 1 else 0);
    db.bindText(stmt, 2, identity);
    _ = db.step(stmt);
}

/// Forget before invalidating the libtorrent handle so the identity remains
/// queryable even for a pre-metadata torrent.
pub fn forgetTorrent(id: c_int) void {
    if (db.get() == null) return;
    var identity_buf: [pure.MAX_IDENTITY]u8 = undefined;
    const identity = identityForTorrent(id, &identity_buf) orelse return;
    const stmt = db.prepare("DELETE FROM active_torrent_intents WHERE identity = ?1") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, identity);
    _ = db.step(stmt);
}

/// One-shot restart restore. It joins saved swarms without creating a player or
/// navigating away from Home, then records torrents accepted before DB startup.
pub fn restoreIfReady() void {
    if (!state.app.init_history_loaded or state.torrentSession() == null) return;
    if (restore_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return;
    defer restore_state.store(2, .release);
    if (state.app.incognito_mode) return;

    var restored_any = false;
    {
        const stmt = db.prepare("SELECT identity, paused FROM active_torrent_intents ORDER BY added_at ASC LIMIT 128") orelse return;
        defer db.finalize(stmt);
        while (db.step(stmt) == db.c.SQLITE_ROW) {
            const stored = db.columnText(stmt, 0) orelse continue;
            var canonical_buf: [pure.MAX_IDENTITY + 1]u8 = undefined;
            const canonical = pure.canonicalIdentity(stored, canonical_buf[0..pure.MAX_IDENTITY]) orelse continue;
            canonical_buf[canonical.len] = 0;
            const restored_id = c.mpv.torrent_add_magnet(state.torrentSession(), @ptrCast(&canonical_buf[0]), state.getSavePath());
            if (restored_id >= 0) {
                if (db.columnInt(stmt, 1) != 0) c.mpv.torrent_pause(state.torrentSession(), restored_id);
                restored_any = true;
            }
        }
    }

    // Captures user actions accepted while SQLite was still initializing and
    // makes restored canonical rows idempotent. Stable ids may contain holes.
    const count = c.mpv.torrent_count(state.torrentSession());
    var id: c_int = 0;
    while (id < count) : (id += 1) {
        if (c.mpv.torrent_is_alive(state.torrentSession(), id) != 0) rememberTorrent(id);
    }
    if (restored_any) @import("../core/logs.zig").pushLog("info", "torrent", "Restored active torrent transfers", false);
}
