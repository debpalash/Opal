//! search_help: a search the user typed found nothing, so the operator is asked
//! (once per normalised query, within its cooldown and budget) for other wording.
//! The answer is stored and shown as "Did you mean" chips on the empty search
//! state; one click re-runs the search with that wording. Nothing here ever runs a
//! search by itself.
//!
//! Cost when the operator is off: `onEmptyResults` returns at its first line.
//! Rules and validation are in `operator_search_help_pure.zig`.

const std = @import("std");
const db = @import("../core/db.zig");
const state = @import("../core/state.zig");
const io_g = @import("../core/io_global.zig");
const alloc = @import("../core/alloc.zig").allocator;
const op = @import("operator_pure.zig");
const pure = @import("operator_search_help_pure.zig");
const operator = @import("operator.zig");

pub const Suggestions = pure.Suggestions;

const KEEP_ROWS = 200;

var table_ready = std.atomic.Value(bool).init(false);

fn ensureTable() bool {
    if (table_ready.load(.acquire)) return true;
    if (db.get() == null) return false;
    db.exec(
        "CREATE TABLE IF NOT EXISTS operator_search_help(" ++
            "key TEXT PRIMARY KEY," ++
            "query TEXT NOT NULL," ++
            "suggestions TEXT NOT NULL DEFAULT ''," ++
            "created_ms INTEGER NOT NULL DEFAULT 0)",
    );
    table_ready.store(true, .release);
    return true;
}

// ── Trigger ─────────────────────────────────────────────────────────────

/// The query the empty state last asked about, so a screen that repaints every
/// frame asks the operator (and the database) once per search, not once per frame.
var asked_key: [17]u8 = undefined;
var asked_len: usize = 0;
/// A query reached by clicking a chip is never asked about in turn: a chain of
/// guesses is how a free feature turns into a spending one.
var from_chip_key: [17]u8 = undefined;
var from_chip_len: usize = 0;

/// Called from the search page while it shows "no results" for `query`. Free when
/// the operator is off or incognito; otherwise at most one request per distinct
/// query (the operator's own cooldown and budget still apply).
pub fn onEmptyResults(query: []const u8) void {
    if (!state.app.operator_enabled or state.app.incognito_mode) return;
    var kb: [17]u8 = undefined;
    const key = pure.queryKey(&kb, query);
    if (key.len == 0) return;
    if (std.mem.eql(u8, key, asked_key[0..asked_len])) return;
    @memcpy(asked_key[0..key.len], key);
    asked_len = key.len;
    if (std.mem.eql(u8, key, from_chip_key[0..from_chip_len])) return;
    if (!pure.worthAsking(query)) return;
    if (!ensureTable()) return;

    var ctx: [256]u8 = undefined;
    const text = pure.buildContext(&ctx, query) orelse return;
    // Remember what was typed before the job can start: the handler needs it to
    // drop suggestions that merely repeat it.
    if (!storeQuery(key, std.mem.trim(u8, query, " \t"))) return;
    switch (operator.request(.search_help, key, text)) {
        .queued => {},
        else => forgetPending(key),
    }
}

/// The user clicked a suggestion: its own empty result must not trigger a new question.
pub fn noteChipClick(suggestion: []const u8) void {
    var kb: [17]u8 = undefined;
    const key = pure.queryKey(&kb, suggestion);
    @memcpy(from_chip_key[0..key.len], key);
    from_chip_len = key.len;
}

fn storeQuery(key: []const u8, query: []const u8) bool {
    const stmt = db.prepare("INSERT INTO operator_search_help(key,query,suggestions,created_ms) VALUES(?1,?2,'',?3) ON CONFLICT(key) DO UPDATE SET query=excluded.query WHERE suggestions=''") orelse return false;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, key);
    db.bindText(stmt, 2, query);
    db.bindInt64(stmt, 3, io_g.milliTimestamp());
    return db.step(stmt) == db.c.SQLITE_DONE;
}

/// The request was refused (cooling down, over budget, ...): drop the placeholder
/// unless an earlier answer is stored for this query.
fn forgetPending(key: []const u8) void {
    const stmt = db.prepare("DELETE FROM operator_search_help WHERE key=?1 AND suggestions=''") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, key);
    _ = db.step(stmt);
}

// ── Handler ─────────────────────────────────────────────────────────────

/// `key` is the query key. Validate the answer against the stored original and
/// keep the surviving suggestions. Always `applied` for a well formed answer, even
/// an empty one (the agent had nothing better).
pub fn handle(key: []const u8, result_json: []const u8) op.Handled {
    if (!ensureTable()) return op.Handled.make(.failed, "Search help is not available", .{});
    var original_buf: [pure.NORM_MAX + 8]u8 = undefined;
    const original = blk: {
        const stmt = db.prepare("SELECT query FROM operator_search_help WHERE key=?1") orelse
            return op.Handled.make(.failed, "The search was not found", .{});
        defer db.finalize(stmt);
        db.bindText(stmt, 1, key);
        if (db.step(stmt) != db.c.SQLITE_ROW) return op.Handled.make(.failed, "The search was not found", .{});
        const q = db.columnText(stmt, 0) orelse "";
        if (q.len > original_buf.len) return op.Handled.make(.failed, "The search was not found", .{});
        @memcpy(original_buf[0..q.len], q);
        break :blk original_buf[0..q.len];
    };
    const answer = pure.parseSearchHelp(alloc, result_json, original) orelse
        return op.Handled.make(.failed, "No usable wording in the answer", .{});
    var enc: [pure.MAX_SUGGESTIONS * (op.QUERY_MAX + 1)]u8 = undefined;
    const text = answer.encode(&enc);
    {
        const stmt = db.prepare("UPDATE operator_search_help SET suggestions=?1, created_ms=?2 WHERE key=?3") orelse
            return op.Handled.make(.failed, "Search help is not available", .{});
        defer db.finalize(stmt);
        db.bindText(stmt, 1, text);
        db.bindInt64(stmt, 2, io_g.milliTimestamp());
        db.bindText(stmt, 3, key);
        if (db.step(stmt) != db.c.SQLITE_DONE) return op.Handled.make(.failed, "Search help is not available", .{});
    }
    prune();
    _ = generation.fetchAdd(1, .acq_rel);
    state.wakeUi();
    if (answer.count == 0) return op.Handled.make(.applied, "No better wording found for a search", .{});
    return op.Handled.make(.applied, "Found {d} other way{s} to word a search", .{ answer.count, if (answer.count == 1) "" else "s" });
}

fn prune() void {
    const stmt = db.prepare("DELETE FROM operator_search_help WHERE key NOT IN (SELECT key FROM operator_search_help ORDER BY created_ms DESC LIMIT ?1)") orelse return;
    defer db.finalize(stmt);
    db.bindInt(stmt, 1, KEEP_ROWS);
    _ = db.step(stmt);
}

// ── Chips for the empty search state ────────────────────────────────────

/// Bumped when an answer is stored, so the empty state re-reads it on the frame the
/// answer wakes up (the screen is otherwise idle and would never poll again).
var generation = std.atomic.Value(u32).init(1);
var cache_gen: u32 = 0;
var cache_key: [17]u8 = undefined;
var cache_len: usize = 0;
var cache: Suggestions = .{};
var cache_checked_ms: i64 = 0;
const POLL_MS: i64 = 1500;

/// Stored suggestions for `query`, for the empty state. Reads the database at most
/// every 1.5 seconds while the answer has not arrived and not at all when the
/// operator is off. UI thread only.
pub fn suggestionsFor(query: []const u8) *const Suggestions {
    if (!state.app.operator_enabled) {
        cache = .{};
        cache_len = 0;
        return &cache;
    }
    var kb: [17]u8 = undefined;
    const key = pure.queryKey(&kb, query);
    const now = io_g.milliTimestamp();
    const same = std.mem.eql(u8, key, cache_key[0..cache_len]);
    const gen = generation.load(.acquire);
    if (same and gen == cache_gen and (cache.count > 0 or now - cache_checked_ms < POLL_MS)) return &cache;
    cache_gen = gen;
    @memcpy(cache_key[0..key.len], key);
    cache_len = key.len;
    cache_checked_ms = now;
    cache = .{};
    if (key.len == 0 or !ensureTable()) return &cache;
    const stmt = db.prepare("SELECT suggestions FROM operator_search_help WHERE key=?1") orelse return &cache;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, key);
    if (db.step(stmt) == db.c.SQLITE_ROW) cache = Suggestions.decode(db.columnText(stmt, 0) orelse "");
    return &cache;
}
