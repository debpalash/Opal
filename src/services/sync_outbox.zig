//! Durable, provider-neutral delivery queue for watch-history synchronization.

const std = @import("std");
const db = @import("../core/db.zig");
const pure = @import("sync_outbox_pure.zig");

pub const Job = struct {
    id: i64 = 0,
    operation: [32]u8 = std.mem.zeroes([32]u8),
    operation_len: usize = 0,
    payload: [1024]u8 = std.mem.zeroes([1024]u8),
    payload_len: usize = 0,
    attempts: u32 = 0,
};

pub fn retryDelaySeconds(attempts: u32) i64 {
    return pure.retryDelaySeconds(attempts);
}

pub fn enqueue(provider: []const u8, operation: []const u8, event_key: []const u8, payload: []const u8) bool {
    if (provider.len == 0 or operation.len == 0 or event_key.len == 0 or payload.len == 0 or payload.len > 1024) return false;
    const stmt = db.prepare(
        "INSERT INTO sync_outbox(provider,operation,event_key,payload) VALUES(?1,?2,?3,?4) " ++
            "ON CONFLICT(provider,operation,event_key) DO UPDATE SET payload=excluded.payload,attempts=0,next_attempt_at=0,last_error=''",
    ) orelse return false;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, provider);
    db.bindText(stmt, 2, operation);
    db.bindText(stmt, 3, event_key);
    db.bindText(stmt, 4, payload);
    return db.step(stmt) == db.c.SQLITE_DONE;
}

pub fn nextDue(provider: []const u8, now: i64, out: *Job) bool {
    const stmt = db.prepare("SELECT id,operation,payload,attempts FROM sync_outbox WHERE provider=?1 AND next_attempt_at<=?2 ORDER BY id LIMIT 1") orelse return false;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, provider);
    db.bindInt64(stmt, 2, now);
    if (db.step(stmt) != db.c.SQLITE_ROW) return false;
    out.* = .{ .id = db.columnInt64(stmt, 0), .attempts = @intCast(@max(db.columnInt(stmt, 3), 0)) };
    db.copyColumn(stmt, 1, &out.operation, &out.operation_len);
    db.copyColumn(stmt, 2, &out.payload, &out.payload_len);
    return out.operation_len > 0 and out.payload_len > 0;
}

pub fn complete(id: i64) void {
    const stmt = db.prepare("DELETE FROM sync_outbox WHERE id=?1") orelse return;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, id);
    _ = db.step(stmt);
}

pub fn deferFailure(id: i64, attempts: u32, now: i64, detail: []const u8) void {
    const stmt = db.prepare("UPDATE sync_outbox SET attempts=?1,next_attempt_at=?2,last_error=?3 WHERE id=?4") orelse return;
    defer db.finalize(stmt);
    db.bindInt(stmt, 1, @intCast(@min(attempts + 1, std.math.maxInt(i32))));
    db.bindInt64(stmt, 2, now + retryDelaySeconds(attempts));
    db.bindText(stmt, 3, detail[0..@min(detail.len, 160)]);
    db.bindInt64(stmt, 4, id);
    _ = db.step(stmt);
}

pub fn count(provider: []const u8) usize {
    const stmt = db.prepare("SELECT count(*) FROM sync_outbox WHERE provider=?1") orelse return 0;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, provider);
    if (db.step(stmt) != db.c.SQLITE_ROW) return 0;
    return @intCast(@max(db.columnInt(stmt, 0), 0));
}

pub fn retryNow(provider: []const u8) void {
    const stmt = db.prepare("UPDATE sync_outbox SET next_attempt_at=0 WHERE provider=?1") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, provider);
    _ = db.step(stmt);
}
