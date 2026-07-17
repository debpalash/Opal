//! Pure decision logic for the compacted Logs view — no io, no globals, so it's
//! unit-tested and `ui/drawer.zig` routes through it.
//!
//! The Logs view used to render one row per ring entry showing only `text`,
//! ignoring the `level`/`prefix` each entry already carries. With many sources
//! active that's a wall of anonymous lines, and a chatty source (retry loops,
//! per-poster fetches) floods it with identical rows. The compacted view shows a
//! short level tag + source prefix, and collapses consecutive identical lines
//! into a single row with an `×N` count.

const std = @import("std");

/// Normalize a free-form level string to a fixed 3-char tag for a compact,
/// aligned gutter. Unknown levels render as "LOG".
pub fn levelTag(level: []const u8) []const u8 {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(level, "error") or eq(level, "err")) return "ERR";
    if (eq(level, "warn") or eq(level, "warning")) return "WRN";
    if (eq(level, "info")) return "INF";
    if (eq(level, "debug")) return "DBG";
    if (eq(level, "trace")) return "TRC";
    return "LOG";
}

/// Two adjacent entries collapse into one `×N` row when they're the same line:
/// same level, same source prefix, same text. (is_error is derived from level,
/// so it need not be compared separately.) This is deliberately CONSECUTIVE-only
/// — interleaved duplicates from different sources stay distinct, preserving the
/// real timeline.
pub fn sameLine(
    a_level: []const u8,
    a_prefix: []const u8,
    a_text: []const u8,
    b_level: []const u8,
    b_prefix: []const u8,
    b_text: []const u8,
) bool {
    return std.mem.eql(u8, a_level, b_level) and
        std.mem.eql(u8, a_prefix, b_prefix) and
        std.mem.eql(u8, a_text, b_text);
}

// ── tests ────────────────────────────────────────────────────────────────────

test "levelTag normalizes known levels and defaults unknowns" {
    try std.testing.expectEqualStrings("ERR", levelTag("error"));
    try std.testing.expectEqualStrings("ERR", levelTag("ERR"));
    try std.testing.expectEqualStrings("WRN", levelTag("warn"));
    try std.testing.expectEqualStrings("WRN", levelTag("Warning"));
    try std.testing.expectEqualStrings("INF", levelTag("info"));
    try std.testing.expectEqualStrings("DBG", levelTag("debug"));
    try std.testing.expectEqualStrings("TRC", levelTag("trace"));
    try std.testing.expectEqualStrings("LOG", levelTag("weird"));
    try std.testing.expectEqualStrings("LOG", levelTag(""));
}

test "sameLine collapses identical lines only" {
    try std.testing.expect(sameLine("info", "anime", "loading", "info", "anime", "loading"));
    // any field differing breaks the run
    try std.testing.expect(!sameLine("info", "anime", "loading", "warn", "anime", "loading"));
    try std.testing.expect(!sameLine("info", "anime", "loading", "info", "plex", "loading"));
    try std.testing.expect(!sameLine("info", "anime", "loading", "info", "anime", "loaded"));
}

test "sameLine: the flood case — repeated retries collapse, timeline stays after a break" {
    // Three identical retry lines in a row collapse.
    try std.testing.expect(sameLine("warn", "torrent", "retry", "warn", "torrent", "retry"));
    // A different source interleaving does NOT collapse across it.
    try std.testing.expect(!sameLine("warn", "torrent", "retry", "info", "plex", "ok"));
}
