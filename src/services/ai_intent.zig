const std = @import("std");
const chat = @import("ai_chat.zig");
const resolver = @import("resolver.zig");
const voice = @import("ai_voice.zig");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");

// ══════════════════════════════════════════════════════════
//  AI Intent — Classification, Normalization, Smart Routing
// ══════════════════════════════════════════════════════════
//
// Instead of blindly forwarding user text to torrent search,
// classify what the user actually wants and route accordingly.

pub const Intent = enum {
    specific_title,   // "play the boys S01E01" — search for a specific thing
    recommendation,   // "play some movies" / "recommend something" — use TMDB trending
    browse_genre,     // "find sci-fi movies" — TMDB genre browse
    search_title,     // "find iron man" — multi-source search
    contextual_nav,   // "next episode" — already handled by resolveContextual
    unknown,          // fallback — let LLM handle it
};

// ── Number word lookup ──
const NumberWord = struct { word: []const u8, val: u8 };
const number_words = [_]NumberWord{
    .{ .word = "one", .val = 1 },     .{ .word = "two", .val = 2 },
    .{ .word = "three", .val = 3 },   .{ .word = "four", .val = 4 },
    .{ .word = "five", .val = 5 },    .{ .word = "six", .val = 6 },
    .{ .word = "seven", .val = 7 },   .{ .word = "eight", .val = 8 },
    .{ .word = "nine", .val = 9 },    .{ .word = "ten", .val = 10 },
    .{ .word = "eleven", .val = 11 }, .{ .word = "twelve", .val = 12 },
    .{ .word = "thirteen", .val = 13 }, .{ .word = "fourteen", .val = 14 },
    .{ .word = "fifteen", .val = 15 }, .{ .word = "sixteen", .val = 16 },
    .{ .word = "seventeen", .val = 17 }, .{ .word = "eighteen", .val = 18 },
    .{ .word = "nineteen", .val = 19 }, .{ .word = "twenty", .val = 20 },
    .{ .word = "first", .val = 1 },   .{ .word = "second", .val = 2 },
    .{ .word = "third", .val = 3 },   .{ .word = "fourth", .val = 4 },
    .{ .word = "fifth", .val = 5 },   .{ .word = "sixth", .val = 6 },
    .{ .word = "seventh", .val = 7 }, .{ .word = "eighth", .val = 8 },
    .{ .word = "ninth", .val = 9 },   .{ .word = "tenth", .val = 10 },
};

fn wordToNumber(word: []const u8) ?u8 {
    var lower: [32]u8 = undefined;
    const wl = @min(word.len, 31);
    for (0..wl) |i| lower[i] = std.ascii.toLower(word[i]);
    const lw = lower[0..wl];
    for (number_words) |nw| {
        if (std.mem.eql(u8, lw, nw.word)) return nw.val;
    }
    return null;
}

// ── Recommendation trigger phrases ──
const rec_phrases = [_][]const u8{
    "some movies", "some shows", "some anime", "some series",
    "recommend", "suggest", "something to watch", "what should i watch",
    "what to watch", "anything good", "random movie", "random show",
    "movies to watch", "shows to watch", "popular movies", "trending",
    "top movies", "best movies", "best shows", "best anime",
    "new movies", "new shows", "latest movies", "whats popular",
    "what's popular", "what is trending", "whats trending",
    "play something", "put something on", "surprise me",
};

// ── Genre keywords ──
const GenreEntry = struct { keyword: []const u8, genre: []const u8 };
const genre_keywords = [_]GenreEntry{
    .{ .keyword = "sci-fi", .genre = "Science Fiction" },
    .{ .keyword = "scifi", .genre = "Science Fiction" },
    .{ .keyword = "science fiction", .genre = "Science Fiction" },
    .{ .keyword = "horror", .genre = "Horror" },
    .{ .keyword = "comedy", .genre = "Comedy" },
    .{ .keyword = "action", .genre = "Action" },
    .{ .keyword = "thriller", .genre = "Thriller" },
    .{ .keyword = "romance", .genre = "Romance" },
    .{ .keyword = "drama", .genre = "Drama" },
    .{ .keyword = "animation", .genre = "Animation" },
    .{ .keyword = "documentary", .genre = "Documentary" },
    .{ .keyword = "fantasy", .genre = "Fantasy" },
    .{ .keyword = "mystery", .genre = "Mystery" },
    .{ .keyword = "western", .genre = "Western" },
    .{ .keyword = "crime", .genre = "Crime" },
    .{ .keyword = "war", .genre = "War" },
};

// ── Filler prefixes to strip from queries ──
const filler_prefixes = [_][]const u8{
    "can you play ", "could you play ", "i want to watch ",
    "i wanna watch ", "put on ", "let me watch ",
    "can you find ", "can you search ", "please play ",
    "please find ", "yo play ", "hey play ",
    "play me ", "show me ",
};

/// Classify intent from user input (lowercase).
pub fn classifyIntent(input_lower: []const u8) Intent {
    // Check recommendation triggers first
    for (rec_phrases) |phrase| {
        if (std.mem.indexOf(u8, input_lower, phrase) != null) return .recommendation;
    }

    // Check genre browse: "find <genre> movies/shows"
    for (genre_keywords) |gk| {
        if (std.mem.indexOf(u8, input_lower, gk.keyword) != null) {
            // Only if also mentions movies/shows/anime (genre browse)
            // vs "play horror movie name" (specific title)
            const has_media_word = std.mem.indexOf(u8, input_lower, "movies") != null or
                std.mem.indexOf(u8, input_lower, "shows") != null or
                std.mem.indexOf(u8, input_lower, "anime") != null or
                std.mem.indexOf(u8, input_lower, "series") != null or
                std.mem.indexOf(u8, input_lower, "films") != null;
            if (has_media_word) return .browse_genre;
        }
    }

    // Default: it's a specific title or search
    return .specific_title;
}

/// Normalize a query: strip filler, convert word numbers to SxxExx format.
/// Returns the normalized query in buf.
pub fn normalizeQuery(raw: []const u8, buf: *[256]u8) []const u8 {
    if (raw.len == 0) return raw;

    // Step 1: strip filler prefixes
    var input = raw;
    var lower_copy: [512]u8 = undefined;
    const clen = @min(raw.len, 511);
    for (0..clen) |i| lower_copy[i] = std.ascii.toLower(raw[i]);
    const lc = lower_copy[0..clen];

    for (filler_prefixes) |fp| {
        if (std.mem.startsWith(u8, lc, fp)) {
            input = raw[fp.len..];
            break;
        }
    }

    // Step 2: convert word numbers in "season X episode Y" patterns
    // Work on lowered input
    var work: [256]u8 = undefined;
    const wlen = @min(input.len, 255);
    for (0..wlen) |i| work[i] = std.ascii.toLower(input[i]);
    const src = work[0..wlen];

    // Check for "season <word/num>" pattern
    if (std.mem.indexOf(u8, src, "season ")) |season_pos| {
        // Copy everything before "season "
        const prefix = std.mem.trim(u8, input[0..season_pos], " ");
        var out: usize = 0;

        // Copy title prefix
        for (prefix) |ch| {
            if (out < 255) { buf[out] = ch; out += 1; }
        }
        if (out > 0 and buf[out - 1] != ' ') { buf[out] = ' '; out += 1; }

        // Parse season number (word or digit)
        const after_season = src[season_pos + 7..]; // skip "season "
        var season_num: ?u8 = null;
        var consumed: usize = 0;

        // Try digit first
        if (after_season.len > 0 and std.ascii.isDigit(after_season[0])) {
            var end: usize = 0;
            var val: u8 = 0;
            while (end < after_season.len and std.ascii.isDigit(after_season[end])) : (end += 1) {
                val = val * 10 + (after_season[end] - '0');
            }
            season_num = val;
            consumed = end;
        } else {
            // Try word number
            var end: usize = 0;
            while (end < after_season.len and after_season[end] != ' ') end += 1;
            if (end > 0) {
                season_num = wordToNumber(after_season[0..end]);
                if (season_num != null) consumed = end;
            }
        }

        if (season_num) |sn| {
            // Write S##
            buf[out] = 'S'; out += 1;
            if (sn < 10) { buf[out] = '0'; out += 1; }
            const sn_str = std.fmt.bufPrint(buf[out..], "{d}", .{sn}) catch "";
            out += sn_str.len;

            // Now look for episode pattern
            var ep_rest = after_season[consumed..];
            // skip spaces
            while (ep_rest.len > 0 and ep_rest[0] == ' ') ep_rest = ep_rest[1..];

            const ep_prefixes = [_][]const u8{ "episode ", "ep " };
            for (ep_prefixes) |ep_prefix| {
                if (std.mem.startsWith(u8, ep_rest, ep_prefix)) {
                    const after_ep = ep_rest[ep_prefix.len..];
                    var ep_num: ?u8 = null;

                    // Try digit
                    if (after_ep.len > 0 and std.ascii.isDigit(after_ep[0])) {
                        var end2: usize = 0;
                        var val2: u8 = 0;
                        while (end2 < after_ep.len and std.ascii.isDigit(after_ep[end2])) : (end2 += 1) {
                            val2 = val2 * 10 + (after_ep[end2] - '0');
                        }
                        ep_num = val2;
                    } else {
                        var end2: usize = 0;
                        while (end2 < after_ep.len and after_ep[end2] != ' ') end2 += 1;
                        if (end2 > 0) ep_num = wordToNumber(after_ep[0..end2]);
                    }

                    if (ep_num) |en| {
                        buf[out] = 'E'; out += 1;
                        if (en < 10) { buf[out] = '0'; out += 1; }
                        const en_str = std.fmt.bufPrint(buf[out..], "{d}", .{en}) catch "";
                        out += en_str.len;
                    }
                    break;
                }
            }

            return buf[0..out];
        }
    }

    // No season/episode pattern — just return with filler stripped
    const trimmed = std.mem.trim(u8, input, " ");
    const tlen = @min(trimmed.len, 255);
    @memcpy(buf[0..tlen], trimmed[0..tlen]);
    return buf[0..tlen];
}

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
    chat.is_generating = true;
    chat.last_error_len = 0;

    _ = std.Thread.spawn(.{}, recommendationWorker, .{chat.message_count - 1}) catch {
        chat.is_generating = false;
        return false;
    };
    return true;
}

fn recommendationWorker(assistant_idx: usize) void {
    defer { chat.is_generating = false; }

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

/// Check if a result name looks like an error message rather than real content.
pub fn isErrorResult(name: []const u8) bool {
    const error_markers = [_][]const u8{
        "api key error", "Jackett:", "jackett:", "API key",
        "error!", "Error!", "ERROR", "configuration",
        "Right-click this", "right-click this",
        "indexer error", "Indexer Error",
    };
    for (error_markers) |marker| {
        if (std.mem.indexOf(u8, name, marker) != null) return true;
    }
    return false;
}

/// Find genre from input text, returns genre name or null.
pub fn findGenre(input_lower: []const u8) ?[]const u8 {
    for (genre_keywords) |gk| {
        if (std.mem.indexOf(u8, input_lower, gk.keyword) != null) return gk.genre;
    }
    return null;
}
