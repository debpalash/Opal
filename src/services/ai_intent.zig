const std = @import("std");
const chat = @import("ai_chat.zig");
const resolver = @import("resolver.zig");
const voice = @import("ai_voice.zig");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const pure = @import("ai_intent_pure.zig");

// ══════════════════════════════════════════════════════════
//  AI Intent — Classification, Normalization, Smart Routing
// ══════════════════════════════════════════════════════════
//
// Pure classification/normalization lives in ai_intent_pure.zig
// (testable without crossing src/ module boundaries). This file
// keeps the I/O-heavy recommendation handler.

pub const Intent = pure.Intent;
pub const classifyIntent = pure.classifyIntent;
pub const normalizeQuery = pure.normalizeQuery;
pub const parseNavIndex = pure.parseNavIndex;

/// Handle recommendation intent — use TMDB trending data.
/// Populates chat results with trending movies/shows instead of torrent garbage.
pub fn handleRecommendation(raw_input: []const u8) bool {
    // Add user message to chat
    if (chat.message_count >= chat.MAX_MESSAGES) return false;
    chat.messages[chat.message_count] = .{ .role = .user, .text_len = @min(raw_input.len, chat.MAX_MSG_LEN) };
    @memcpy(chat.messages[chat.message_count].text[0..chat.messages[chat.message_count].text_len], raw_input[0..chat.messages[chat.message_count].text_len]);
    chat.message_count += 1;

    // Add assistant slot
    if (chat.message_count >= chat.MAX_MESSAGES) return false;
    chat.messages[chat.message_count] = .{ .role = .assistant, .text_len = 0 };
    chat.message_count += 1;

    @memset(&chat.input_buf, 0);
    chat.input_len = 0;
    chat.is_generating.store(true, .release);
    chat.last_error_len = 0;

    _ = std.Thread.spawn(.{}, recommendationWorker, .{chat.message_count - 1}) catch {
        chat.is_generating.store(false, .release);
        return false;
    };
    return true;
}

fn recommendationWorker(assistant_idx: usize) void {
    defer { chat.is_generating.store(false, .release); }

    // Strategy 1: Use TMDB trending if API key is configured
    if (state.app.tmdb.api_key_len > 0) {
        // Open the TMDB drawer to trending view
        state.app.drawer_open = true;
        state.app.drawer_tab = .TMDB;
        state.app.tmdb.view = .Trending;
        state.app.tmdb.category = .trending;
        state.app.tmdb.media_filter = .movie;
        state.app.tmdb.page = 1;

        const tmdb_api = @import("tmdb_api.zig");
        tmdb_api.fetchCurrentView(false);

        // Wait briefly for TMDB results
        var waited: usize = 0;
        while (state.app.tmdb.is_loading and waited < 30) : (waited += 1) {
            @import("../core/io_global.zig").sleep(100 * std.time.ns_per_ms);
        }

        // Build response from TMDB trending
        const items = state.app.tmdb.results.items;
        const count = @min(items.len, 8);

        if (count > 0) {
            var resp_buf: [1024]u8 = undefined;
            const resp = std.fmt.bufPrint(&resp_buf,
                "Here are trending movies right now! I've opened the TMDB tab so you can browse them with posters and ratings. Pick any title and say \"play <title>\" to start watching.",
                .{},
            ) catch "Check the TMDB tab for trending movies!";

            if (assistant_idx < chat.MAX_MESSAGES) {
                chat.messages[assistant_idx].text_len = @min(resp.len, chat.MAX_MSG_LEN);
                @memcpy(chat.messages[assistant_idx].text[0..chat.messages[assistant_idx].text_len], resp[0..chat.messages[assistant_idx].text_len]);
            }

            // Also populate chat results with top TMDB items so user can see them inline
            chat.chat_result_count = 0;
            for (0..count) |i| {
                const tmdb_item = &items[i];
                var ri = &chat.chat_results[i];
                ri.* = std.mem.zeroes(resolver.ResolvedItem);

                // Copy title
                const tlen = @min(tmdb_item.title_len, 255);
                @memcpy(ri.name[0..tlen], tmdb_item.title[0..tlen]);
                ri.name_len = tlen;

                // Build detail: "2024 · Action, Thriller · ★ 7.8"
                var detail_buf: [128]u8 = undefined;
                const year = tmdb_item.year[0..tmdb_item.year_len];
                const genre = tmdb_item.genre_text[0..tmdb_item.genre_text_len];
                const detail_str = std.fmt.bufPrint(&detail_buf, "{s} · {s} · ★ {d:.1}", .{
                    year, genre, tmdb_item.rating,
                }) catch "";
                const dlen = @min(detail_str.len, 127);
                @memcpy(ri.detail[0..dlen], detail_str[0..dlen]);
                ri.detail_len = dlen;

                ri.match_pct = 95; // These are curated results, high relevance
                ri.source = .stremio; // Use stremio label since these aren't torrents
            }
            chat.chat_result_count = count;
            chat.chat_results_active = true;
            chat.recommended_idx = null;
            chat.awaiting_confirmation = false;

            if (voice.voice_mode and assistant_idx < chat.MAX_MESSAGES) {
                voice.speakResponse(chat.messages[assistant_idx].text[0..chat.messages[assistant_idx].text_len]);
            }
            return;
        }
    }

    // Strategy 2: No TMDB key — use recommendations engine
    const recs = @import("recommendations.zig");
    recs.generateRecommendations();

    // Wait for recs
    var waited2: usize = 0;
    while (recs.is_loading and waited2 < 30) : (waited2 += 1) {
        @import("../core/io_global.zig").sleep(100 * std.time.ns_per_ms);
    }

    if (recs.rec_count > 0) {
        const msg = "Here are some recommendations based on your watch history:";
        if (assistant_idx < chat.MAX_MESSAGES) {
            chat.messages[assistant_idx].text_len = msg.len;
            @memcpy(chat.messages[assistant_idx].text[0..msg.len], msg);
        }
    } else {
        const msg = "I don't have enough watch history to make recommendations yet. Try browsing TMDB trending, or tell me a specific title to search for!";
        if (assistant_idx < chat.MAX_MESSAGES) {
            chat.messages[assistant_idx].text_len = @min(msg.len, chat.MAX_MSG_LEN);
            @memcpy(chat.messages[assistant_idx].text[0..chat.messages[assistant_idx].text_len], msg[0..chat.messages[assistant_idx].text_len]);
        }
    }
}

pub const isErrorResult = pure.isErrorResult;
pub const findGenre = pure.findGenre;

/// Handle browse_genre intent — open TMDB drawer with discover-by-genre.
/// Uses TMDB genre IDs for proper categorized results instead of text search.
pub fn handleGenreBrowse(raw_input: []const u8) bool {
    if (chat.message_count + 1 >= chat.MAX_MESSAGES) return false;

    var lower: [256]u8 = undefined;
    const llen = @min(raw_input.len, 255);
    for (0..llen) |i| lower[i] = std.ascii.toLower(raw_input[i]);
    const genre = pure.findGenre(lower[0..llen]) orelse return false;

    // Push user msg + assistant slot
    chat.messages[chat.message_count] = .{ .role = .user, .text_len = @min(raw_input.len, chat.MAX_MSG_LEN) };
    @memcpy(chat.messages[chat.message_count].text[0..chat.messages[chat.message_count].text_len], raw_input[0..chat.messages[chat.message_count].text_len]);
    chat.message_count += 1;

    const assistant_idx = chat.message_count;
    chat.messages[chat.message_count] = .{ .role = .assistant, .text_len = 0 };
    chat.message_count += 1;

    @memset(&chat.input_buf, 0);
    chat.input_len = 0;

    // Require TMDB key — else surface clear error instead of silent torrent search
    if (state.app.tmdb.api_key_len == 0) {
        const msg = "Set a TMDB API key in settings to browse by genre.";
        chat.messages[assistant_idx].text_len = msg.len;
        @memcpy(chat.messages[assistant_idx].text[0..msg.len], msg);
        return true;
    }

    // Map genre name to TMDB genre ID for /discover/movie endpoint
    const genre_id = genreNameToId(genre);

    // Use discover API via direct fetch instead of search piggyback
    state.app.drawer_open = true;
    state.app.drawer_tab = .TMDB;
    state.app.tmdb.view = .Search;
    state.app.tmdb.page = 1;

    if (genre_id > 0) {
        // Set response message before spawning thread (no closure captures)
        var resp_buf2: [256]u8 = undefined;
        const resp2 = std.fmt.bufPrint(&resp_buf2, "Here are popular {s} titles! Browse the TMDB drawer.", .{genre}) catch "Opened genre browse.";
        chat.messages[assistant_idx].text_len = @min(resp2.len, chat.MAX_MSG_LEN);
        @memcpy(chat.messages[assistant_idx].text[0..chat.messages[assistant_idx].text_len], resp2[0..chat.messages[assistant_idx].text_len]);

        // Spawn worker to call /discover/movie?with_genres=ID
        const S = struct { var gid: u32 = 0; };
        S.gid = genre_id;
        _ = std.Thread.spawn(.{}, struct {
            fn worker() void {
                const tmdb_api = @import("tmdb_api.zig");
                tmdb_api.fetchDiscover(S.gid);
            }
        }.worker, .{}) catch {};
    } else {
        // Fallback to search by genre keyword
        @memset(&state.app.tmdb.search_buf, 0);
        const glen = @min(genre.len, state.app.tmdb.search_buf.len - 1);
        @memcpy(state.app.tmdb.search_buf[0..glen], genre[0..glen]);
        const tmdb_api = @import("tmdb_api.zig");
        tmdb_api.fetchCurrentView(false);
    }

    var resp_buf: [256]u8 = undefined;
    const resp = std.fmt.bufPrint(&resp_buf, "Browsing {s} — check the TMDB drawer. Say 'play <title>' to start.", .{genre}) catch "Opened TMDB genre browse.";
    chat.messages[assistant_idx].text_len = @min(resp.len, chat.MAX_MSG_LEN);
    @memcpy(chat.messages[assistant_idx].text[0..chat.messages[assistant_idx].text_len], resp[0..chat.messages[assistant_idx].text_len]);

    if (voice.voice_mode) voice.speakResponse(chat.messages[assistant_idx].text[0..chat.messages[assistant_idx].text_len]);
    return true;
}

/// TMDB movie genre IDs (from https://api.themoviedb.org/3/genre/movie/list)
fn genreNameToId(genre: []const u8) u32 {
    const Map = struct { name: []const u8, id: u32 };
    const table = [_]Map{
        .{ .name = "Action", .id = 28 },
        .{ .name = "Adventure", .id = 12 },
        .{ .name = "Animation", .id = 16 },
        .{ .name = "Comedy", .id = 35 },
        .{ .name = "Crime", .id = 80 },
        .{ .name = "Documentary", .id = 99 },
        .{ .name = "Drama", .id = 18 },
        .{ .name = "Family", .id = 10751 },
        .{ .name = "Fantasy", .id = 14 },
        .{ .name = "History", .id = 36 },
        .{ .name = "Horror", .id = 27 },
        .{ .name = "Music", .id = 10402 },
        .{ .name = "Mystery", .id = 9648 },
        .{ .name = "Romance", .id = 10749 },
        .{ .name = "Science Fiction", .id = 878 },
        .{ .name = "Thriller", .id = 53 },
        .{ .name = "War", .id = 10752 },
        .{ .name = "Western", .id = 37 },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, genre, entry.name)) return entry.id;
    }
    return 0;
}
