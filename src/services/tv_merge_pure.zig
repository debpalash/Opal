//! Merge planner for tracked shows that exist twice in the library.
//!
//! A show tracked while Opal had no TMDB key is stored under the keyless
//! catalog's synthetic id (a hash of its IMDb id). Add a key later, track the
//! same show again, and the library holds it under its real TMDB id too: two
//! rows in Watching. Both rows remember the same IMDb id in `tv_external_ids`,
//! and that is the only thing the planner trusts.
//!
//! Rules (all enforced here, none left to the SQL):
//!   * Only a synthetic row (`keyless_tv_pure.isSynthetic`) is ever a loser, and
//!     only into a NON-synthetic row with exactly the same, valid IMDb id.
//!   * Two rows with different IMDb ids are never merged: a loser is found by
//!     IMDb equality, and its own id must be the hash of that same IMDb id.
//!   * Rows without a remembered IMDb id are never touched.
//!   * Ambiguity (several real rows carry the same IMDb id) merges nothing:
//!     guessing which one owns the history would be destructive.
//!   * The winner is always the TMDB-keyed row.
//!
//! Pure: no io, no state. `tv_merge.zig` executes the plan.

const std = @import("std");
const kl = @import("keyless_tv_pure.zig");
const cm = @import("cinemeta_pure.zig");

pub const Candidate = struct {
    id: i32,
    /// The IMDb id remembered for `id` ("" when unknown).
    imdb: []const u8,
};

pub const Merge = struct {
    /// The TMDB-keyed row that survives.
    winner: i32,
    /// The synthetic row folded into it.
    loser: i32,
};

/// Plan the merges for `rows`. Writes at most `out.len` merges and returns how
/// many. Each loser appears once; a winner may absorb at most one loser (there
/// is exactly one synthetic id per IMDb id).
pub fn planMerges(rows: []const Candidate, out: []Merge) usize {
    var n: usize = 0;
    for (rows) |l| {
        if (n == out.len) break;
        if (!kl.isSynthetic(l.id, l.imdb)) continue;
        if (alreadyPlanned(out[0..n], l.id)) continue;

        var winner: ?i32 = null;
        var ambiguous = false;
        for (rows) |w| {
            if (w.id == l.id or w.id <= 0) continue;
            if (!cm.validImdbId(w.imdb) or !std.mem.eql(u8, w.imdb, l.imdb)) continue;
            if (kl.isSynthetic(w.id, w.imdb)) continue;
            if (winner) |existing| {
                if (existing != w.id) ambiguous = true;
            } else winner = w.id;
        }
        if (ambiguous) continue;
        if (winner) |w| {
            out[n] = .{ .winner = w, .loser = l.id };
            n += 1;
        }
    }
    return n;
}

fn alreadyPlanned(plan: []const Merge, loser: i32) bool {
    for (plan) |m| if (m.loser == loser) return true;
    return false;
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

const t = std.testing;

test "plan: synthetic row merges into the TMDB-keyed row of the same IMDb id" {
    const imdb = "tt0903747";
    const synth = cm.stableId(imdb);
    const rows = [_]Candidate{
        .{ .id = synth, .imdb = imdb },
        .{ .id = 1396, .imdb = imdb },
    };
    var out: [4]Merge = undefined;
    const n = planMerges(&rows, &out);
    try t.expectEqual(@as(usize, 1), n);
    try t.expectEqual(@as(i32, 1396), out[0].winner);
    try t.expectEqual(synth, out[0].loser);
}

test "plan: row order does not change the outcome" {
    const imdb = "tt0903747";
    const synth = cm.stableId(imdb);
    const rows = [_]Candidate{
        .{ .id = 1396, .imdb = imdb },
        .{ .id = 42, .imdb = "tt0000042" },
        .{ .id = synth, .imdb = imdb },
    };
    var out: [4]Merge = undefined;
    try t.expectEqual(@as(usize, 1), planMerges(&rows, &out));
    try t.expectEqual(@as(i32, 1396), out[0].winner);
}

test "plan: different IMDb ids are never merged" {
    const a = "tt0903747";
    const b = "tt0944947";
    const rows = [_]Candidate{
        .{ .id = cm.stableId(a), .imdb = a },
        .{ .id = 1399, .imdb = b },
        .{ .id = cm.stableId(b), .imdb = b },
    };
    var out: [4]Merge = undefined;
    const n = planMerges(&rows, &out);
    // Only b's synthetic folds into b's real row; a's synthetic stays alone.
    try t.expectEqual(@as(usize, 1), n);
    try t.expectEqual(@as(i32, 1399), out[0].winner);
    try t.expectEqual(cm.stableId(b), out[0].loser);
}

test "plan: a row whose id merely equals another show's hash is not a loser" {
    // id collides with hash(a) but remembers IMDb b: isSynthetic(id, b) is false.
    const a = "tt0903747";
    const b = "tt0944947";
    const rows = [_]Candidate{
        .{ .id = cm.stableId(a), .imdb = b },
        .{ .id = 1399, .imdb = b },
    };
    var out: [4]Merge = undefined;
    try t.expectEqual(@as(usize, 0), planMerges(&rows, &out));
}

test "plan: unknown or invalid IMDb ids, lone rows and ambiguity merge nothing" {
    const imdb = "tt0903747";
    const synth = cm.stableId(imdb);
    var out: [4]Merge = undefined;

    const lone = [_]Candidate{.{ .id = synth, .imdb = imdb }};
    try t.expectEqual(@as(usize, 0), planMerges(&lone, &out));

    const no_imdb = [_]Candidate{ .{ .id = synth, .imdb = "" }, .{ .id = 1396, .imdb = "" } };
    try t.expectEqual(@as(usize, 0), planMerges(&no_imdb, &out));

    const bad = [_]Candidate{ .{ .id = synth, .imdb = "junk" }, .{ .id = 1396, .imdb = "junk" } };
    try t.expectEqual(@as(usize, 0), planMerges(&bad, &out));

    const two_real = [_]Candidate{
        .{ .id = synth, .imdb = imdb },
        .{ .id = 1396, .imdb = imdb },
        .{ .id = 1397, .imdb = imdb },
    };
    try t.expectEqual(@as(usize, 0), planMerges(&two_real, &out));

    const only_real = [_]Candidate{ .{ .id = 1396, .imdb = imdb }, .{ .id = 1397, .imdb = imdb } };
    try t.expectEqual(@as(usize, 0), planMerges(&only_real, &out));
}

test "plan: output capacity is respected and duplicate rows plan once" {
    const a = "tt0903747";
    const b = "tt0944947";
    const rows = [_]Candidate{
        .{ .id = cm.stableId(a), .imdb = a },
        .{ .id = cm.stableId(a), .imdb = a },
        .{ .id = 1396, .imdb = a },
        .{ .id = cm.stableId(b), .imdb = b },
        .{ .id = 1399, .imdb = b },
    };
    var out: [4]Merge = undefined;
    try t.expectEqual(@as(usize, 2), planMerges(&rows, &out));
    var one: [1]Merge = undefined;
    try t.expectEqual(@as(usize, 1), planMerges(&rows, &one));
}
