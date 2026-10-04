//! One reusable statement per settings batch; ownership ends with the batch.
const std = @import("std");
pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Writer = struct {
    stmt: ?*c.sqlite3_stmt = null,

    pub fn init(connection: *c.sqlite3) ?Writer {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(connection, "INSERT OR REPLACE INTO config (key, value) VALUES (?1, ?2)", -1, &stmt, null) != c.SQLITE_OK) return null;
        return .{ .stmt = stmt };
    }

    pub fn put(self: *Writer, key: []const u8, value: []const u8) bool {
        const stmt = self.stmt orelse return false;
        _ = c.sqlite3_reset(stmt);
        _ = c.sqlite3_clear_bindings(stmt);
        const transient = transientDestructor();
        if (c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), transient) != c.SQLITE_OK) return false;
        if (c.sqlite3_bind_text(stmt, 2, value.ptr, @intCast(value.len), transient) != c.SQLITE_OK) return false;
        return c.sqlite3_step(stmt) == c.SQLITE_DONE;
    }

    pub fn deinit(self: *Writer) void {
        if (self.stmt) |stmt| _ = c.sqlite3_finalize(stmt);
        self.stmt = null;
    }
};

fn transientDestructor() c.sqlite3_destructor_type {
    @setRuntimeSafety(false);
    var address: usize = std.math.maxInt(usize);
    address += 0;
    return @ptrFromInt(address);
}

test "settings batch finalizes its only statement before database close" {
    var connection: ?*c.sqlite3 = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(":memory:", &connection));
    defer _ = c.sqlite3_close_v2(connection);
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(connection, "CREATE TABLE config (key TEXT PRIMARY KEY, value TEXT NOT NULL)", null, null, null));
    var writer = Writer.init(connection.?) orelse return error.PrepareFailed;
    const stmt = writer.stmt;
    for (0..100) |_| try std.testing.expect(writer.put("setting", "updated"));
    try std.testing.expectEqual(stmt, writer.stmt);
    writer.deinit();
    const remaining = c.sqlite3_next_stmt(connection, null);
    // Clean up the red fixture too, so the feedback loop never leaks.
    defer if (remaining != null) {
        _ = c.sqlite3_finalize(remaining);
    };
    try std.testing.expect(remaining == null);
    writer.deinit();
    try std.testing.expect(!writer.put("closed", "ignored"));
}

test "independent settings batches do not retain connection pointers" {
    for (0..3) |_| {
        var connection: ?*c.sqlite3 = null;
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(":memory:", &connection));
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(connection, "CREATE TABLE config (key TEXT PRIMARY KEY, value TEXT NOT NULL)", null, null, null));
        var writer = Writer.init(connection.?) orelse return error.PrepareFailed;
        try std.testing.expect(writer.put("a", "one"));
        try std.testing.expect(writer.put("b", "two"));
        writer.deinit();
        const result = c.sqlite3_close(connection);
        if (result != c.SQLITE_OK) {
            while (c.sqlite3_next_stmt(connection, null)) |stmt| _ = c.sqlite3_finalize(stmt);
            _ = c.sqlite3_close(connection);
        }
        try std.testing.expectEqual(c.SQLITE_OK, result);
    }
}

test {
    _ = @import("sqlite_transaction.zig");
}
