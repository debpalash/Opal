const std = @import("std");
const state = @import("../core/state.zig");
const db = @import("../core/db.zig");
const taste_vector = @import("taste_vector.zig");
const ai_memory = @import("ai_memory.zig");

// ══════════════════════════════════════════════════════════
// AI Recommendations — suggests content based on watch history
//
// Primary: "Taste Receipts" — a no-cold-start For-You rail seeded by a
// taste vector over the embeddings already in vec_aimemory (the scenes the
// user leaned into). Each rec carries a spoiler-clamped "because" receipt.
//
// Fallback (MANDATORY, offline-safe): if no taste vector can be computed
// (empty/absent embeddings) we degrade to the original TMDB genre-frequency
// rail below — never hard-fail, never show a wrong receipt.
// ══════════════════════════════════════════════════════════

const alloc = @import("../core/alloc.zig").allocator;

pub const Recommendation = struct {
    title: [128]u8 = std.mem.zeroes([128]u8),
    title_len: usize = 0,
    reason: [256]u8 = std.mem.zeroes([256]u8),
    reason_len: usize = 0,
    id: i32 = 0,
    score: f64 = 0,
};

pub var recommendations: [20]Recommendation = undefined;
pub var rec_count: usize = 0;
pub var is_loading: bool = false;

// Snapshot of the active player taken on the calling (UI) thread BEFORE the
// worker spawns — the worker must not touch state.app.players itself.
var seed_current_title: [128]u8 = std.mem.zeroes([128]u8);
var seed_current_title_len: usize = 0;
var seed_current_pos: f64 = 0;

/// Generate recommendations. Tries the taste-vector rail first; on failure
/// (no embeddings / empty vec store) keeps the original genre-frequency rail.
pub fn generateRecommendations() void {
    if (is_loading) return;
    is_loading = true;
    rec_count = 0;

    // Snapshot the active player on this (UI) thread, guarded per CLAUDE.md.
    seed_current_title_len = 0;
    seed_current_pos = 0;
    if (state.app.active_player_idx < state.app.players.items.len) {
        const p = state.app.players.items[state.app.active_player_idx];
        seed_current_title_len = p.getMediaTitle(&seed_current_title);
        seed_current_pos = p.last_seen_pos;
    }

    _ = std.Thread.spawn(.{}, struct {
        fn worker() void {
            defer {
                is_loading = false;
            }

            // ── Primary: Taste Receipts (taste vector over vec_aimemory) ──
            var taste: [ai_memory.EMBED_DIM]f32 = undefined;
            if (taste_vector.computeTaste(&taste)) {
                const current_title = seed_current_title[0..seed_current_title_len];
                var seeds: [20]db.SeedHit = undefined;
                const n = db.seedTitlesByTaste(taste[0..], current_title, seed_current_pos, seeds[0..]);
                if (n > 0) {
                    var i: usize = 0;
                    while (i < n and rec_count < 20) : (i += 1) {
                        const s = &seeds[i];
                        addRec(
                            s.title[0..@min(s.title_len, s.title.len)],
                            s.reason[0..@min(s.reason_len, s.reason.len)],
                            0,
                            s.score,
                        );
                    }
                    return;
                }
                // n == 0 → fall through to the genre-frequency fallback below.
            }

            // ── Fallback (MANDATORY): TMDB genre-frequency rail ──
            // Reached when no taste vector could be computed (empty/absent
            // embeddings) OR the KNN returned nothing. Original body, verbatim.

            // 1) Collect genre_ids from favorited/watchlisted TMDB items
            var genre_counts: [32]struct { genre: [32]u8, genre_len: usize, count: u32 } = undefined;
            var genre_total: usize = 0;

            const sql = "SELECT t.genre_text FROM tmdb_items t " ++
                "JOIN tmdb_lists l ON t.id = l.item_id " ++
                "WHERE l.list_name IN ('favorites', 'watchlist') " ++
                "ORDER BY l.added_at DESC LIMIT 50";
            const stmt = db.prepare(sql) orelse return;
            defer db.finalize(stmt);

            while (db.step(stmt) == db.c.SQLITE_ROW) {
                if (db.columnText(stmt, 0)) |genre_text| {
                    // genre_text is like "Action, Thriller, Sci-Fi"
                    var genres = std.mem.splitSequence(u8, genre_text, ", ");
                    while (genres.next()) |g| {
                        if (g.len == 0 or g.len > 31) continue;
                        // Find or add genre
                        var found = false;
                        for (genre_counts[0..genre_total]) |*gc| {
                            if (std.mem.eql(u8, gc.genre[0..gc.genre_len], g)) {
                                gc.count += 1;
                                found = true;
                                break;
                            }
                        }
                        if (!found and genre_total < 32) {
                            @memcpy(genre_counts[genre_total].genre[0..g.len], g);
                            genre_counts[genre_total].genre_len = g.len;
                            genre_counts[genre_total].count = 1;
                            genre_total += 1;
                        }
                    }
                }
            }

            if (genre_total == 0) {
                // No data — suggest popular
                addRec("Browse Trending on TMDB", "No watch history yet", 0, 1.0);
                return;
            }

            // 2) Find top genre
            var top_genre: []const u8 = "";
            var top_count: u32 = 0;
            for (genre_counts[0..genre_total]) |gc| {
                if (gc.count > top_count) {
                    top_count = gc.count;
                    top_genre = gc.genre[0..gc.genre_len];
                }
            }

            // 3) Find TMDB items matching top genre that are NOT in user lists
            const rec_sql = "SELECT id, title, genre_text, rating FROM tmdb_items " ++
                "WHERE genre_text LIKE ?1 AND id NOT IN (SELECT item_id FROM tmdb_lists) " ++
                "ORDER BY rating DESC LIMIT 20";
            const rec_stmt = db.prepare(rec_sql) orelse return;
            defer db.finalize(rec_stmt);

            var pattern_buf: [64]u8 = undefined;
            const pattern = std.fmt.bufPrint(&pattern_buf, "%{s}%", .{top_genre}) catch return;
            db.bindText(rec_stmt, 1, pattern);

            while (db.step(rec_stmt) == db.c.SQLITE_ROW and rec_count < 20) {
                const id = db.columnInt(rec_stmt, 0);
                const title = db.columnText(rec_stmt, 1) orelse continue;
                const rating = db.columnDouble(rec_stmt, 3);

                var reason_buf: [64]u8 = undefined;
                const reason = std.fmt.bufPrint(&reason_buf, "You like {s}", .{top_genre}) catch "Recommended";
                addRec(title, reason, id, rating);
            }
        }

        fn addRec(title: []const u8, reason: []const u8, id: i32, score: f64) void {
            if (rec_count >= 20) return;
            var rec = &recommendations[rec_count];
            const tlen = @min(title.len, 127);
            @memcpy(rec.title[0..tlen], title[0..tlen]);
            rec.title_len = tlen;
            const rlen = @min(reason.len, 255);
            @memcpy(rec.reason[0..rlen], reason[0..rlen]);
            rec.reason_len = rlen;
            rec.id = id;
            rec.score = score;
            rec_count += 1;
        }
    }.worker, .{}) catch {};
}
