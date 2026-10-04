//! Connection-wide transaction ownership. FULLMUTEX alone serializes calls,
//! not a BEGIN/work/COMMIT sequence. SQLite's recursive connection mutex also
//! excludes callers that use raw SQLite APIs or an existing prepared statement.
//! Acquire feature snapshots before beginning; do not acquire feature locks or
//! perform network/process work while a transaction is alive. Same thread only.
const std = @import("std");
pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Transaction = struct {
    connection: *c.sqlite3,
    mutex: *c.sqlite3_mutex,
    active: bool = true,

    pub fn begin(connection: *c.sqlite3) !Transaction {
        const mutex = c.sqlite3_db_mutex(connection) orelse return error.UnserializedConnection;
        c.sqlite3_mutex_enter(mutex);
        errdefer c.sqlite3_mutex_leave(mutex);
        // A nested caller must not commit or roll back its caller's work.
        if (c.sqlite3_get_autocommit(connection) == 0) return error.NestedTransaction;
        if (c.sqlite3_exec(connection, "BEGIN IMMEDIATE", null, null, null) != c.SQLITE_OK)
            return error.BeginFailed;
        return .{ .connection = connection, .mutex = mutex };
    }

    pub fn commit(self: *Transaction) !void {
        if (!self.active) return error.TransactionClosed;
        if (c.sqlite3_exec(self.connection, "COMMIT", null, null, null) != c.SQLITE_OK)
            return error.CommitFailed;
        self.active = false;
        c.sqlite3_mutex_leave(self.mutex);
    }

    pub fn deinit(self: *Transaction) void {
        if (!self.active) return;
        _ = c.sqlite3_exec(self.connection, "ROLLBACK", null, null, null);
        self.active = false;
        c.sqlite3_mutex_leave(self.mutex);
    }
};

test "transaction excludes unrelated writers until rollback and releases ownership" {
    var db: ?*c.sqlite3 = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(":memory:", &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX, null));
    defer _ = c.sqlite3_close(db);
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, "CREATE TABLE t(v); INSERT INTO t VALUES(1)", null, null, null));
    var tx = try Transaction.begin(db.?);
    defer tx.deinit();
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, "DELETE FROM t", null, null, null));
    const Worker = struct {
        fn run(connection: *c.sqlite3, result: *c_int) void {
            const mutex = c.sqlite3_db_mutex(connection);
            result.* = c.sqlite3_mutex_try(mutex);
            if (result.* == c.SQLITE_OK) c.sqlite3_mutex_leave(mutex);
        }
    };
    var result: c_int = -1;
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ db.?, &result });
    thread.join();
    try std.testing.expectEqual(c.SQLITE_BUSY, result);
    try std.testing.expectError(error.NestedTransaction, Transaction.begin(db.?));
    tx.deinit();
    var next = try Transaction.begin(db.?);
    defer next.deinit();
    var stmt: ?*c.sqlite3_stmt = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db, "SELECT v FROM t", -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_column_int(stmt, 0));
    try next.commit();
}

test "failed commit remains owned and rolls back all work" {
    var db: ?*c.sqlite3 = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(":memory:", &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX, null));
    defer _ = c.sqlite3_close(db);
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, "PRAGMA foreign_keys=ON; CREATE TABLE p(id PRIMARY KEY); CREATE TABLE ch(id REFERENCES p(id) DEFERRABLE INITIALLY DEFERRED)", null, null, null));
    var tx = try Transaction.begin(db.?);
    defer tx.deinit();
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, "INSERT INTO ch VALUES(7)", null, null, null));
    try std.testing.expectError(error.CommitFailed, tx.commit());
    tx.deinit();
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(db));
    var stmt: ?*c.sqlite3_stmt = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db, "SELECT count(*) FROM ch", -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_column_int(stmt, 0));
}
