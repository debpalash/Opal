//! local_names: files in the local library whose cleaned title still looks like a
//! release name get a human title and kind from the agent. After a library scan
//! `afterScan` picks up to 20 such files and asks once; the answer is applied
//! (without asking) only to files whose display title is still empty, through
//! `local_library.correct`. Rules and validation live in `operator_names_pure.zig`.
//!
//! The batch's index -> rowid mapping is kept in `operator_names_batch`, which also
//! records which rows were already asked about so a file is not sent twice.

const std = @import("std");
const db = @import("../core/db.zig");
const state = @import("../core/state.zig");
const io_g = @import("../core/io_global.zig");
const alloc = @import("../core/alloc.zig").allocator;
const op = @import("operator_pure.zig");
const pure = @import("operator_names_pure.zig");
const operator = @import("operator.zig");
const local_library = @import("local_library.zig");

comptime {
    std.debug.assert(pure.CONTEXT_MAX == operator.MAX_CONTEXT);
}

/// A file that was asked about and left undecided is asked again after this long.
const REASK_MS: i64 = 14 * 24 * 60 * 60 * 1000;

var table_ready = std.atomic.Value(bool).init(false);

fn ensureTable() bool {
    if (table_ready.load(.acquire)) return true;
    if (db.get() == null) return false;
    db.exec(
        "CREATE TABLE IF NOT EXISTS operator_names_batch(" ++
            "row_id INTEGER PRIMARY KEY," ++
            "batch TEXT NOT NULL," ++
            "idx INTEGER NOT NULL," ++
            "title_hash INTEGER NOT NULL DEFAULT 0," ++
            "asked_ms INTEGER NOT NULL DEFAULT 0)",
    );
    db.exec("CREATE INDEX IF NOT EXISTS operator_names_batch_batch ON operator_names_batch(batch)");
    table_ready.store(true, .release);
    return true;
}

// ── Trigger ─────────────────────────────────────────────────────────────

/// Called once at the end of a successful library scan. Free when the operator is
/// off or the session is incognito: nothing below the first two lines runs.
pub fn afterScan() void {
    if (!state.app.operator_enabled) return;
    if (state.app.incognito_mode) return;
    if (!ensureTable()) return;

    const now = io_g.milliTimestamp();
    // Forget markers of files that left the library.
    db.exec("DELETE FROM operator_names_batch WHERE row_id NOT IN (SELECT rowid FROM local_media)");

    var batch = pure.Batch{};
    {
        const stmt = db.prepare(
            "SELECT l.rowid, l.path, l.title FROM local_media l WHERE COALESCE(l.display_title,'')='' " ++
                "AND NOT EXISTS (SELECT 1 FROM operator_names_batch b WHERE b.row_id=l.rowid AND b.asked_ms>?1) ORDER BY l.rowid",
        ) orelse return;
        defer db.finalize(stmt);
        db.bindInt64(stmt, 1, now - REASK_MS);
        while (db.step(stmt) == db.c.SQLITE_ROW) {
            const title = db.columnText(stmt, 2) orelse "";
            if (!pure.looksMessy(title)) continue;
            const path = db.columnText(stmt, 1) orelse continue;
            if (batch.add(db.columnInt64(stmt, 0), path, title) == .full) break;
        }
    }
    if (batch.count == 0) return;

    var key_buf: [24]u8 = undefined;
    const key = pure.batchKey(&key_buf, batch.rowids[0]);
    // Store the mapping first: the job may start the moment it is queued.
    if (!storeBatch(key, &batch, now)) return;
    if (operator.request(.local_names, key, batch.text()) != .queued) forgetBatch(key);
}

/// A job for this batch failed: ask about its files again after a day instead of
/// leaving them marked as asked for the full re-ask window.
pub fn retryLater(key: []const u8) void {
    if (!ensureTable()) return;
    const stmt = db.prepare("UPDATE operator_names_batch SET asked_ms=?1 WHERE batch=?2") orelse return;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, pure.retryMarker(io_g.milliTimestamp(), REASK_MS, pure.RETRY_AFTER_FAILURE_MS));
    db.bindText(stmt, 2, key);
    _ = db.step(stmt);
}

/// Startup recovery: jobs still `running` were cut short, so their batches get the
/// same treatment as a failed job. Called before those jobs are marked failed.
pub fn retryInterruptedLater() void {
    if (!ensureTable()) return;
    const stmt = db.prepare(
        "UPDATE operator_names_batch SET asked_ms=?1 WHERE batch IN (SELECT key FROM operator_jobs WHERE kind='local_names' AND state='running')",
    ) orelse return;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, pure.retryMarker(io_g.milliTimestamp(), REASK_MS, pure.RETRY_AFTER_FAILURE_MS));
    _ = db.step(stmt);
}

fn storeBatch(key: []const u8, batch: *const pure.Batch, now: i64) bool {
    forgetBatch(key);
    const stmt = db.prepare("INSERT OR REPLACE INTO operator_names_batch(row_id,batch,idx,title_hash,asked_ms) VALUES(?1,?2,?3,?4,?5)") orelse return false;
    defer db.finalize(stmt);
    for (0..batch.count) |i| {
        db.reset(stmt);
        db.bindInt64(stmt, 1, batch.rowids[i]);
        db.bindText(stmt, 2, key);
        db.bindInt64(stmt, 3, @intCast(i));
        db.bindInt64(stmt, 4, @bitCast(batch.hashes[i]));
        db.bindInt64(stmt, 5, now);
        if (db.step(stmt) != db.c.SQLITE_DONE) return false;
    }
    return true;
}

fn forgetBatch(key: []const u8) void {
    const stmt = db.prepare("DELETE FROM operator_names_batch WHERE batch=?1") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, key);
    _ = db.step(stmt);
}

// ── Handler ─────────────────────────────────────────────────────────────

/// Reads and writes the real library for `pure.applyNames`.
const LibraryTarget = struct {
    hashes: [pure.MAX_ITEMS]u64 = undefined,
    ids: [pure.MAX_ITEMS]i64 = undefined,
    n: usize = 0,
    title_buf: [512]u8 = undefined,

    pub fn current(self: *LibraryTarget, row_id: i64) ?pure.Current {
        var asked: ?u64 = null;
        for (0..self.n) |i| if (self.ids[i] == row_id) {
            asked = self.hashes[i];
        };
        const stmt = db.prepare("SELECT title, COALESCE(display_title,'') FROM local_media WHERE rowid=?1") orelse return null;
        defer db.finalize(stmt);
        db.bindInt64(stmt, 1, row_id);
        if (db.step(stmt) != db.c.SQLITE_ROW) return null;
        const title = db.columnText(stmt, 0) orelse "";
        if (title.len > self.title_buf.len) return null;
        @memcpy(self.title_buf[0..title.len], title);
        const display = db.columnText(stmt, 1) orelse "";
        return .{
            .display_empty = display.len == 0,
            .title = self.title_buf[0..title.len],
            .asked_hash = asked orelse return null,
        };
    }

    pub fn apply(self: *LibraryTarget, row_id: i64, title: []const u8, kind: []const u8) bool {
        _ = self;
        return local_library.correct(row_id, title, kind);
    }
};

/// `key` is the batch id; the rows come from `operator_names_batch`.
pub fn handle(key: []const u8, result_json: []const u8) op.Handled {
    if (!ensureTable()) return op.Handled.make(.failed, "The library is not available", .{});
    var target = LibraryTarget{};
    var rowids = [_]i64{0} ** pure.MAX_ITEMS;
    var count: usize = 0;
    {
        const stmt = db.prepare("SELECT idx, row_id, title_hash FROM operator_names_batch WHERE batch=?1") orelse
            return op.Handled.make(.failed, "The batch was not found", .{});
        defer db.finalize(stmt);
        db.bindText(stmt, 1, key);
        while (db.step(stmt) == db.c.SQLITE_ROW and target.n < pure.MAX_ITEMS) {
            const idx = db.columnInt64(stmt, 0);
            if (idx < 0 or idx >= pure.MAX_ITEMS) continue;
            const row_id = db.columnInt64(stmt, 1);
            rowids[@intCast(idx)] = row_id;
            count = @max(count, @as(usize, @intCast(idx)) + 1);
            target.ids[target.n] = row_id;
            target.hashes[target.n] = @bitCast(db.columnInt64(stmt, 2));
            target.n += 1;
        }
    }
    if (count == 0) return op.Handled.make(.failed, "The batch was not found", .{});
    return pure.handleAnswer(alloc, result_json, rowids[0..count], &target);
}
