const std = @import("std");
const logs = @import("../core/logs.zig");
const state = @import("../core/state.zig");

// ══════════════════════════════════════════════════════════
//  AI Tools — Agentic Tool Registry & Executor
// ══════════════════════════════════════════════════════════
//
// Hermes 2 Pro tool-calling format:
//   System prompt includes <tools>[...]</tools>
//   Model responds with <tool_call>{"name":"...", "arguments":{...}}</tool_call>
//   We execute and return <tool_response>{"name":"...", "content":"..."}</tool_response>

/// Maximum tool result size
const MAX_TOOL_RESULT = 2048;

/// Tool call parsed from LLM output
pub const ToolCall = struct {
    name: [64]u8 = std.mem.zeroes([64]u8),
    name_len: usize = 0,
    args_json: [512]u8 = std.mem.zeroes([512]u8),
    args_len: usize = 0,
};

// Note: Tool definitions are built dynamically in ai_context.zig generateResponse()
// so they can conditionally include player tools only when a player is active.

/// Compressed system prompt — every token counts for latency
pub const TOOL_SYSTEM_PROMPT =
    \\You are ZigZag AI, a voice-first media assistant. Be EXTREMELY brief (1 sentence max).
    \\
    \\ROUTING: pause/resume/stop/volume/seek/speed → player_control. "play X" → find_and_play(action="play_best"). "search X" → find_and_play(action="search"). "what's playing" → player_info. "show downloads" → navigate. "youtube X" → youtube_search. "read comic/narrate/what page/read this page" → comic_control or comic_info.
    \\
    \\RESPONSE FORMAT MUST BE JSON: {"message":"Your natural conversational reply here","tool_call":{"name":"tool","arguments":{...}}}
    \\If no tool needed: {"message":"Your natural conversational reply here","tool_call":null}
;

// ══════════════════════════════════════════════════════════
//  Tool Call Detection & Parsing
// ══════════════════════════════════════════════════════════

/// Check if LLM response contains a tool call (JSON format).
/// Accepts the canonical {"tool_call":{...}} wrapper as well as the
/// OpenAI-style bare {"name":..,"arguments":..} object some models emit,
/// including when wrapped in ```json fences or preceded by prose.
pub fn containsToolCall(text: []const u8) bool {
    // Canonical wrapper: mentions tool_call and it's not explicitly null.
    if (std.mem.indexOf(u8, text, "\"tool_call\"") != null) {
        const is_null = std.mem.indexOf(u8, text, "\"tool_call\": null") != null or std.mem.indexOf(u8, text, "\"tool_call\":null") != null;
        if (!is_null) return true;
    }
    // OpenAI-style bare object: has both a "name" and "arguments" key.
    if (std.mem.indexOf(u8, text, "\"name\"") != null and std.mem.indexOf(u8, text, "\"arguments\"") != null) {
        return true;
    }
    return false;
}

/// Find the balanced {...} object starting at the first '{' at or after `from`.
/// Returns the slice including both braces, or null if unbalanced/absent.
fn extractBalancedObject(text: []const u8, from: usize) ?[]const u8 {
    const start = std.mem.indexOfScalarPos(u8, text, from, '{') orelse return null;
    var depth: usize = 0;
    var i: usize = start;
    while (i < text.len) : (i += 1) {
        if (text[i] == '{') depth += 1;
        if (text[i] == '}') {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return text[start .. i + 1];
        }
    }
    return null;
}

/// Parse a {"name":..,"arguments":{..}} object slice into a ToolCall.
/// `json_text` must already be the balanced object containing the keys.
fn parseNameAndArgs(json_text: []const u8) ?ToolCall {
    var tc = ToolCall{};

    // Extract "name": "..."
    const name_key = "\"name\"";
    const name_pos = std.mem.indexOf(u8, json_text, name_key) orelse return null;
    const after_name = json_text[name_pos + name_key.len ..];
    var ni: usize = 0;
    while (ni < after_name.len and after_name[ni] != '"') : (ni += 1) {}
    ni += 1;
    if (ni >= after_name.len) return null;
    const name_start = ni;
    var name_end = name_start;
    while (name_end < after_name.len and after_name[name_end] != '"') : (name_end += 1) {}
    if (name_end <= name_start) return null;
    const name = after_name[name_start..name_end];
    tc.name_len = @min(name.len, 64);
    @memcpy(tc.name[0..tc.name_len], name[0..tc.name_len]);

    // Extract "arguments": {...}
    const args_key = "\"arguments\"";
    if (std.mem.indexOf(u8, json_text, args_key)) |args_pos| {
        if (extractBalancedObject(json_text, args_pos + args_key.len)) |args_json| {
            tc.args_len = @min(args_json.len, 512);
            @memcpy(tc.args_json[0..tc.args_len], args_json[0..tc.args_len]);
        }
    }

    return tc;
}

/// Parse a tool call from LLM response text (JSON).
/// Canonical form: {"message": "...", "tool_call": {"name": "...", "arguments": {...}}}
/// Also tolerates: ```json fences and leading prose (substring search ignores them),
/// and the OpenAI-style bare {"name":.., "arguments":..} object without the
/// outer "tool_call" wrapper that some models emit.
pub fn parseToolCall(text: []const u8) ?ToolCall {
    // Preferred: locate the "tool_call" wrapper and parse the object after it.
    const tc_key = "\"tool_call\"";
    if (std.mem.indexOf(u8, text, tc_key)) |tc_pos| {
        if (extractBalancedObject(text, tc_pos + tc_key.len)) |json_text| {
            if (parseNameAndArgs(json_text)) |tc| return tc;
        }
    }

    // Fallback: OpenAI-style bare object — find the first "name" key and parse
    // the balanced object that encloses it.
    const name_key = "\"name\"";
    if (std.mem.indexOf(u8, text, name_key)) |name_pos| {
        // Walk back to the '{' that opens the object containing this key, then
        // extract the balanced object from there.
        var open: usize = name_pos;
        while (open > 0) : (open -= 1) {
            if (text[open] == '{') break;
        }
        if (text[open] == '{') {
            if (extractBalancedObject(text, open)) |json_text| {
                if (parseNameAndArgs(json_text)) |tc| return tc;
            }
        }
    }

    return null;
}

// ══════════════════════════════════════════════════════════
//  Tool Execution
// ══════════════════════════════════════════════════════════

/// Execute a tool call and return the result as a string
/// Caller must free the returned slice
pub fn executeTool(alloc: std.mem.Allocator, tc: *const ToolCall) ?[]u8 {
    const name = tc.name[0..tc.name_len];

    if (std.mem.eql(u8, name, "find_and_play")) {
        return normResult(alloc, executeFindAndPlay(alloc, tc));
    } else if (std.mem.eql(u8, name, "search_media") or std.mem.eql(u8, name, "play_media")) {
        return normResult(alloc, executeFindAndPlay(alloc, tc));
    } else if (std.mem.eql(u8, name, "player_control")) {
        return normResult(alloc, executePlayerControl(alloc, tc));
    } else if (std.mem.eql(u8, name, "player_info")) {
        return normResult(alloc, executePlayerInfo(alloc));
    } else if (std.mem.eql(u8, name, "navigate")) {
        return normResult(alloc, executeNavigate(alloc, tc));
    } else if (std.mem.eql(u8, name, "queue_manage")) {
        return normResult(alloc, executeQueueManage(alloc, tc));
    } else if (std.mem.eql(u8, name, "youtube_search")) {
        return normResult(alloc, executeYoutubeSearch(alloc, tc));
    } else if (std.mem.eql(u8, name, "anime_search")) {
        return normResult(alloc, executeAnimeSearch(alloc, tc));
    } else if (std.mem.eql(u8, name, "jellyfin_browse")) {
        return normResult(alloc, executeJellyfinBrowse(alloc, tc));
    } else if (std.mem.eql(u8, name, "get_watch_history")) {
        return normResult(alloc, executeGetWatchHistory(alloc, tc));
    } else if (std.mem.eql(u8, name, "tmdb_lookup")) {
        return normResult(alloc, executeTmdbLookup(alloc, tc));
    } else if (std.mem.eql(u8, name, "browse_tmdb")) {
        return normResult(alloc, executeBrowseTmdb(alloc, tc));
    } else if (std.mem.eql(u8, name, "read_webpage")) {
        return normResult(alloc, executeReadWebpage(alloc, tc));
    } else if (std.mem.eql(u8, name, "comic_control")) {
        return normResult(alloc, executeComicControl(alloc, tc));
    } else if (std.mem.eql(u8, name, "comic_info")) {
        return normResult(alloc, executeComicInfo(alloc));
    }

    // Unknown tool
    return std.fmt.allocPrint(alloc, "Unknown tool: {s}", .{name}) catch null;
}

/// Normalize a tool result so callers can free it with alloc.free(result).
/// Sub-functions return result[0..off] from alloc(u8, MAX_TOOL_RESULT) —
/// the GPA requires free-length == alloc-length. We copy into an exact-
/// sized buffer and free the original MAX_TOOL_RESULT-sized allocation.
/// Note: allocPrint results from error paths within sub-functions also pass
/// through here; for those the original alloc size != MAX_TOOL_RESULT, so we
/// just return them as-is (they're already exact-sized and freeable).
fn normResult(alloc: std.mem.Allocator, raw: ?[]u8) ?[]u8 {
    const result = raw orelse return null;
    // If the result fills the entire buffer, it's already exact-sized
    if (result.len == MAX_TOOL_RESULT) return result;
    // Copy into an exact-sized allocation
    const exact = alloc.alloc(u8, result.len) catch return null;
    @memcpy(exact, result);
    // Free the original buffer. Sub-functions that allocate MAX_TOOL_RESULT
    // bytes return result[0..off] where result.ptr is the start of the
    // MAX_TOOL_RESULT-sized allocation.
    const original: []u8 = result.ptr[0..MAX_TOOL_RESULT];
    alloc.free(original);
    return exact;
}

/// Format tool result as a message for the LLM (sanitized for JSON safety)
pub fn formatToolResponse(buf: []u8, tool_name: []const u8, result: []const u8) usize {
    const prefix = "{\"tool_response\": {\"name\": \"";
    const mid = "\", \"content\": \"";
    const suffix = "\"}}";

    var off: usize = 0;

    // Write prefix
    if (off + prefix.len > buf.len) return 0;
    @memcpy(buf[off..off + prefix.len], prefix);
    off += prefix.len;

    // Write tool name
    if (off + tool_name.len > buf.len) return 0;
    @memcpy(buf[off..off + tool_name.len], tool_name);
    off += tool_name.len;

    // Write mid
    if (off + mid.len > buf.len) return 0;
    @memcpy(buf[off..off + mid.len], mid);
    off += mid.len;

    // Write sanitized result (escape quotes, strip non-ASCII/control chars)
    // Reserve space for suffix to guarantee valid JSON closure
    const max_content = if (buf.len > off + suffix.len) buf.len - off - suffix.len else 0;
    var content_written: usize = 0;
    for (result) |ch| {
        if (content_written + 2 >= max_content) break;
        if (ch == '"') {
            buf[off] = '\\'; off += 1; content_written += 1;
            buf[off] = '"'; off += 1; content_written += 1;
        } else if (ch == '\\') {
            buf[off] = '\\'; off += 1; content_written += 1;
            buf[off] = '\\'; off += 1; content_written += 1;
        } else if (ch == '\n') {
            buf[off] = ' '; off += 1; content_written += 1;
        } else if (ch < 32 or ch > 126) {
            // Skip non-ASCII and control chars — prevents UTF-8 parse errors
            continue;
        } else {
            buf[off] = ch; off += 1; content_written += 1;
        }
    }

    // Write suffix — space is guaranteed reserved above
    @memcpy(buf[off..off + suffix.len], suffix);
    off += suffix.len;

    return off;
}

// ══════════════════════════════════════════════════════════
//  Tool Implementations
// ══════════════════════════════════════════════════════════

fn executeFindAndPlay(alloc: std.mem.Allocator, tc: *const ToolCall) ?[]u8 {
    const raw_query = extractStringArg(tc.args_json[0..tc.args_len], "query") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'query' argument", .{}) catch null;
    const action = extractStringArg(tc.args_json[0..tc.args_len], "action") orelse "search";
    const content_type = extractStringArg(tc.args_json[0..tc.args_len], "content_type") orelse "auto";

    // Normalize query: "season one episode one" → "S01E01"
    const ai_intent = @import("ai_intent.zig");
    var norm_buf: [256]u8 = undefined;
    const query = ai_intent.normalizeQuery(raw_query, &norm_buf);

    // Clear previous results immediately so UI shows fresh state
    const chat = @import("ai_chat.zig");
    chat.chat_result_count = 0;
    chat.chat_results_active = false;
    chat.awaiting_confirmation = false;
    chat.recommended_idx = null;
    @memset(std.mem.asBytes(&chat.chat_results), 0);

    // Run resolver (searches all sources in parallel)
    const resolver = @import("resolver.zig");
    resolver.resolve(query, content_type);

    // Wait for results — max 5s, early exit when ≥3 results after 1.5s
    var waited: usize = 0;
    while (resolver.isResolving() and waited < 50) : (waited += 1) {
        if (resolver.result_count >= 3 and waited >= 15) break;
        @import("../core/io_global.zig").sleep(100 * std.time.ns_per_ms);
    }

    // Copy new results to chat state for inline rendering
    chat.chat_results_active = true;

    resolver.results_mutex.lock();
    const count = @min(resolver.result_count, 12);
    for (0..count) |i| {
        chat.chat_results[i] = resolver.results[i];
    }
    chat.chat_result_count = count;
    resolver.results_mutex.unlock();

    // Set recommended index if play_best
    if (std.mem.eql(u8, action, "play_best") and count > 0) {
        chat.recommended_idx = 0;
        chat.awaiting_confirmation = true;
    } else {
        chat.recommended_idx = null;
        chat.awaiting_confirmation = false;
    }

    // Build result summary for AI response
    var result = alloc.alloc(u8, MAX_TOOL_RESULT) catch return null;
    var off: usize = 0;

    if (count == 0) {
        alloc.free(result);
        return std.fmt.allocPrint(alloc, "No results found for '{s}'.", .{query}) catch null;
    }

    const header = std.fmt.bufPrint(result[off..], "Found {d} results for '{s}':\n", .{ count, query }) catch "";
    off += header.len;

    for (0..@min(count, 5)) |i| {
        const item = &chat.chat_results[i];
        const name = item.name[0..item.name_len];
        const detail = item.detail[0..item.detail_len];
        const line = std.fmt.bufPrint(result[off..], "{d}. {s} ({s})\n", .{ i + 1, name, detail }) catch break;
        off += line.len;
        if (off > MAX_TOOL_RESULT - 200) break;
    }

    if (std.mem.eql(u8, action, "play_best") and count > 0) {
        const best = chat.chat_results[0].name[0..chat.chat_results[0].name_len];
        const note = std.fmt.bufPrint(result[off..], "\nBest match: {s}. Cards are shown in chat.", .{best}) catch "";
        off += note.len;
    }

    return result[0..off];
}

fn executeGetWatchHistory(alloc: std.mem.Allocator, _: *const ToolCall) ?[]u8 {
    const db = @import("../core/db.zig");

    var result = alloc.alloc(u8, MAX_TOOL_RESULT) catch return null;
    var off: usize = 0;

    // Query watch history from DB
    const watch_sql = "SELECT name, percent, position_secs, duration_secs FROM watch_history ORDER BY updated_at DESC LIMIT 15";
    const stmt = db.prepare(watch_sql);
    if (stmt != null) {
        defer db.finalize(stmt);
        var watch_count: usize = 0;
        while (db.step(stmt) == db.c.SQLITE_ROW) {
            if (watch_count == 0) {
                const hdr = "Recent watch history:\n";
                @memcpy(result[off .. off + hdr.len], hdr);
                off += hdr.len;
            }
            const name = db.columnText(stmt, 0) orelse continue;
            const pct = db.columnDouble(stmt, 1);

            var clean_name = name;
            if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| {
                clean_name = name[slash + 1 ..];
            }

            const line = std.fmt.bufPrint(result[off..], "- {s} ({d:.0}% watched)\n", .{ clean_name, pct }) catch break;
            off += line.len;
            watch_count += 1;
            if (off > MAX_TOOL_RESULT - 200) break;
        }
    }

    // TMDB favorites
    const fav_sql = "SELECT i.title, i.year, i.media_type FROM tmdb_items i JOIN tmdb_lists l ON i.id = l.item_id WHERE l.list_name = 'fav' LIMIT 10";
    const fav_stmt = db.prepare(fav_sql);
    if (fav_stmt != null) {
        defer db.finalize(fav_stmt);
        var fav_count: usize = 0;
        while (db.step(fav_stmt) == db.c.SQLITE_ROW) {
            if (fav_count == 0) {
                const hdr2 = "\nFavorites:\n";
                if (off + hdr2.len < MAX_TOOL_RESULT) {
                    @memcpy(result[off .. off + hdr2.len], hdr2);
                    off += hdr2.len;
                }
            }
            const title = db.columnText(fav_stmt, 0) orelse continue;
            const year = db.columnText(fav_stmt, 1) orelse "";
            const mtype = db.columnText(fav_stmt, 2) orelse "";
            const line = std.fmt.bufPrint(result[off..], "- {s} ({s}) [{s}]\n", .{ title, year, mtype }) catch break;
            off += line.len;
            fav_count += 1;
            if (off > MAX_TOOL_RESULT - 200) break;
        }
    }

    if (off == 0) {
        alloc.free(result);
        return std.fmt.allocPrint(alloc, "No watch history or favorites found yet.", .{}) catch null;
    }

    return result[0..off];
}


fn executeBrowseTmdb(alloc: std.mem.Allocator, tc: *const ToolCall) ?[]u8 {
    const query = extractStringArg(tc.args_json[0..tc.args_len], "query") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'query' argument", .{}) catch null;

    if (state.app.tmdb.api_key_len == 0) {
        return std.fmt.allocPrint(alloc, "TMDB API key not configured. Add it in Settings > General.", .{}) catch null;
    }

    // Open drawer to TMDB tab and trigger search
    state.app.drawer_open = true;
    state.app.drawer_tab = .TMDB;
    state.app.tmdb.view = .Search;

    // Copy query into TMDB search buffer
    const qlen = @min(query.len, state.app.tmdb.search_buf.len - 1);
    @memset(&state.app.tmdb.search_buf, 0);
    @memcpy(state.app.tmdb.search_buf[0..qlen], query[0..qlen]);

    // Trigger TMDB search
    state.app.tmdb.page = 1;
    const tmdb_api = @import("tmdb_api.zig");
    tmdb_api.fetchCurrentView(false);
    state.showToast("Searching TMDB...");

    return std.fmt.allocPrint(alloc,
        "I've opened the TMDB browser with results for '{s}'. You can view them in the tab.",
        .{query},
    ) catch null;
}

fn executeTmdbLookup(alloc: std.mem.Allocator, tc: *const ToolCall) ?[]u8 {
    const query = extractStringArg(tc.args_json[0..tc.args_len], "query") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'query' argument", .{}) catch null;

    if (state.app.tmdb.api_key_len == 0) {
        return std.fmt.allocPrint(alloc, "Error: TMDB API key not configured in Settings.", .{}) catch null;
    }

    // Synchronously curl TMDB search to return data to LLM
    var url_buf: [512]u8 = undefined;
    var escaped_query: [256]u8 = undefined;
    var eq_len: usize = 0;
    for (query) |c| {
        if (eq_len >= 253) break;
        switch (c) {
            ' ' => { escaped_query[eq_len] = '+'; eq_len += 1; },
            '&' => { escaped_query[eq_len] = '%'; escaped_query[eq_len + 1] = '2'; escaped_query[eq_len + 2] = '6'; eq_len += 3; },
            '=' => { escaped_query[eq_len] = '%'; escaped_query[eq_len + 1] = '3'; escaped_query[eq_len + 2] = 'D'; eq_len += 3; },
            '#' => { escaped_query[eq_len] = '%'; escaped_query[eq_len + 1] = '2'; escaped_query[eq_len + 2] = '3'; eq_len += 3; },
            '?' => { escaped_query[eq_len] = '%'; escaped_query[eq_len + 1] = '3'; escaped_query[eq_len + 2] = 'F'; eq_len += 3; },
            '%' => { escaped_query[eq_len] = '%'; escaped_query[eq_len + 1] = '2'; escaped_query[eq_len + 2] = '5'; eq_len += 3; },
            else => { escaped_query[eq_len] = c; eq_len += 1; },
        }
    }
    
    const api_key = state.app.tmdb.api_key[0..state.app.tmdb.api_key_len];
    const url = std.fmt.bufPrint(&url_buf, "https://api.themoviedb.org/3/search/multi?api_key={s}&query={s}&page=1", .{api_key, escaped_query[0..eq_len]}) catch return null;
    
    var child = @import("../core/io_global.zig").Child.init(&.{ "curl", "-s", "--max-time", "10", url }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;
    
    const stdout = child.stdout.?;
    var result_buf: [8192]u8 = undefined;
    const n = @import("../core/io_global.zig").readAll(stdout, &result_buf) catch 0;
    _ = child.wait() catch {};
    
    if (n == 0) return std.fmt.allocPrint(alloc, "Error: Failed to fetch TMDB", .{}) catch null;
    
    // We don't have a JSON parser, so we use string matching to extract the first 3 titles and release dates
    var out_buf: [2048]u8 = undefined;
    var out_fbs = std.Io.Writer.fixed(&out_buf);
    const writer = &out_fbs;
    
    writer.print("Top 3 TMDB Results for '{s}':\n", .{query}) catch {};
    
    const json_str = result_buf[0..n];
    var search_start: usize = 0;
    var count: usize = 0;
    
    while (count < 3) : (count += 1) {
        // Find "original_title" or "original_name"
        const name_idx = std.mem.indexOf(u8, json_str[search_start..], "\"title\":\"") orelse 
                         std.mem.indexOf(u8, json_str[search_start..], "\"name\":\"");
        if (name_idx == null) break;
        
        // Key lengths: '"title":"' = 10, '"name":"' = 8
        const key_len: usize = if (std.mem.indexOf(u8, json_str[search_start..], "\"title\":\"") != null) 10 else 8;
        search_start += name_idx.? + key_len;
        const name_end = std.mem.indexOfScalarPos(u8, json_str, search_start, '"') orelse break;
        const title = json_str[search_start..name_end];
        
        // Find release_date or first_air_date
        var date: []const u8 = "Unknown";
        const date_idx = std.mem.indexOf(u8, json_str[search_start..], "\"release_date\":\"") orelse 
                         std.mem.indexOf(u8, json_str[search_start..], "\"first_air_date\":\"");
                         
        if (date_idx != null) {
            const d_start = search_start + date_idx.? + 16;
            if (std.mem.indexOfScalarPos(u8, json_str, d_start, '"')) |d_end| {
                date = json_str[d_start..d_end];
            }
        }
        
        // Find overview summary (just first 100 chars)
        var overview: []const u8 = "";
        if (std.mem.indexOf(u8, json_str[search_start..], "\"overview\":\"")) |o_idx| {
            const o_start = search_start + o_idx + 12;
            if (std.mem.indexOfScalarPos(u8, json_str, o_start, '"')) |o_end| {
                const max_olen = @min(o_end - o_start, 100);
                overview = json_str[o_start .. o_start + max_olen];
            }
        }
        
        writer.print("{d}. {s} ({s}) - {s}...\n", .{count + 1, title, date, overview}) catch {};
        search_start = name_end;
    }
    
    if (count == 0) {
        writer.print("No results found.", .{}) catch {};
    }
    
    return alloc.dupe(u8, out_fbs.buffered()) catch null;
}


fn executeReadWebpage(alloc: std.mem.Allocator, tc: *const ToolCall) ?[]u8 {
    const url = extractStringArg(tc.args_json[0..tc.args_len], "url") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'url' argument", .{}) catch null;

    // Security: only allow http/https URLs to prevent SSRF against local services
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return std.fmt.allocPrint(alloc, "Error: only http:// and https:// URLs are supported", .{}) catch null;
    }
    // Block SSRF: loopback, private networks, cloud metadata, encoded IPs
    const blocked = [_][]const u8{
        "127.0.0.1", "localhost", "0.0.0.0", "[::1]",
        "169.254.169.254",
        "10.", "192.168.", "172.16.", "172.17.", "172.18.", "172.19.",
        "172.20.", "172.21.", "172.22.", "172.23.", "172.24.", "172.25.",
        "172.26.", "172.27.", "172.28.", "172.29.", "172.30.", "172.31.",
        "0x", "0177.",
    };
    for (blocked) |pat| {
        if (std.mem.indexOf(u8, url, pat) != null) {
            return std.fmt.allocPrint(alloc, "Error: cannot access local URLs", .{}) catch null;
        }
    }

    // Use Jina Reader (free, no API key) to extract web content
    var jina_url_buf: [512]u8 = undefined;
    const jina_url = std.fmt.bufPrintZ(&jina_url_buf, "https://r.jina.ai/{s}", .{url}) catch
        return std.fmt.allocPrint(alloc, "URL too long", .{}) catch null;

    // Execute curl in background
    var child = @import("../core/io_global.zig").Child.init(
        &.{ "curl", "-s", "--max-time", "10", "-H", "Accept: text/plain", jina_url },
        alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch
        return std.fmt.allocPrint(alloc, "Failed to fetch URL", .{}) catch null;

    // Read up to MAX_TOOL_RESULT bytes of output
    var result = alloc.alloc(u8, MAX_TOOL_RESULT) catch {
        _ = child.wait() catch {};
        return null;
    };
    const stdout = child.stdout.?;
    var total: usize = 0;
    while (total < MAX_TOOL_RESULT) {
        const n = @import("../core/io_global.zig").read(stdout, result[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    _ = child.wait() catch {};

    if (total == 0) {
        alloc.free(result);
        return std.fmt.allocPrint(alloc, "No content retrieved from URL", .{}) catch null;
    }

    // Sanitize: replace newlines and quotes for JSON safety
    for (result[0..total]) |*ch| {
        if (ch.* == '\n') ch.* = ' ';
        if (ch.* == '\r') ch.* = ' ';
        if (ch.* == '"') ch.* = '\'';
        if (ch.* < 32) ch.* = ' ';
    }

    return result[0..total];
}

// ══════════════════════════════════════════════════════════
//  JSON Argument Extraction (minimal, no allocator needed)
// ══════════════════════════════════════════════════════════

fn extractStringArg(json: []const u8, key: []const u8) ?[]const u8 {
    // Find "key": "value" pattern
    // Build search needle: "key"
    var needle_buf: [72]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, needle) orelse return null;
    const after = json[key_pos + needle.len..];

    // Skip : and whitespace, find opening quote
    var i: usize = 0;
    while (i < after.len and (after[i] == ':' or after[i] == ' ')) : (i += 1) {}
    if (i >= after.len or after[i] != '"') return null;
    i += 1; // skip opening quote

    const val_start = i;
    // Find closing quote (handling escaped quotes)
    while (i < after.len) : (i += 1) {
        if (after[i] == '"' and (i == val_start or after[i - 1] != '\\')) break;
    }

    if (i <= val_start) return null;
    return after[val_start..i];
}

// ══════════════════════════════════════════════════════════
//  New Tool Executors — App Control
// ══════════════════════════════════════════════════════════

/// Validate that a string contains only digits, dots, minus signs.
/// Returns the input if safe, or a fallback if not.
fn sanitizeNumeric(val: []const u8, fallback: []const u8) []const u8 {
    if (val.len == 0 or val.len > 16) return fallback;
    for (val) |ch| {
        if (!((ch >= '0' and ch <= '9') or ch == '.' or ch == '-')) return fallback;
    }
    return val;
}

fn executePlayerControl(alloc: std.mem.Allocator, tc: *const ToolCall) ?[]u8 {
    const c = @import("../core/c.zig");
    const action = extractStringArg(tc.args_json[0..tc.args_len], "action") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'action'", .{}) catch null;
    const value = extractStringArg(tc.args_json[0..tc.args_len], "value");

    // Get active player
    if (state.app.players.items.len == 0)
        return std.fmt.allocPrint(alloc, "No player active", .{}) catch null;
    const idx = @min(state.app.active_player_idx, state.app.players.items.len - 1);
    const p = state.app.players.items[idx];

    if (std.mem.eql(u8, action, "pause")) {
        _ = c.mpv.mpv_command_string(p.mpv_ctx, "set pause yes");
        return std.fmt.allocPrint(alloc, "Paused", .{}) catch null;
    } else if (std.mem.eql(u8, action, "resume")) {
        _ = c.mpv.mpv_command_string(p.mpv_ctx, "set pause no");
        return std.fmt.allocPrint(alloc, "Resumed", .{}) catch null;
    } else if (std.mem.eql(u8, action, "toggle_pause")) {
        _ = c.mpv.mpv_command_string(p.mpv_ctx, "cycle pause");
        return std.fmt.allocPrint(alloc, "Toggled pause", .{}) catch null;
    } else if (std.mem.eql(u8, action, "stop")) {
        _ = c.mpv.mpv_command_string(p.mpv_ctx, "stop");
        return std.fmt.allocPrint(alloc, "Stopped", .{}) catch null;
    } else if (std.mem.eql(u8, action, "seek_forward")) {
        var cmd_buf: [64]u8 = undefined;
        const secs = sanitizeNumeric(value orelse "10", "10");
        const cmd = std.fmt.bufPrintZ(&cmd_buf, "seek {s}", .{secs}) catch return null;
        _ = c.mpv.mpv_command_string(p.mpv_ctx, cmd.ptr);
        return std.fmt.allocPrint(alloc, "Seeked forward {s}s", .{secs}) catch null;
    } else if (std.mem.eql(u8, action, "seek_backward")) {
        var cmd_buf: [64]u8 = undefined;
        const secs = sanitizeNumeric(value orelse "10", "10");
        const cmd = std.fmt.bufPrintZ(&cmd_buf, "seek -{s}", .{secs}) catch return null;
        _ = c.mpv.mpv_command_string(p.mpv_ctx, cmd.ptr);
        return std.fmt.allocPrint(alloc, "Seeked backward {s}s", .{secs}) catch null;
    } else if (std.mem.eql(u8, action, "seek_to")) {
        var cmd_buf: [64]u8 = undefined;
        const pos = sanitizeNumeric(value orelse "0", "0");
        const cmd = std.fmt.bufPrintZ(&cmd_buf, "seek {s} absolute", .{pos}) catch return null;
        _ = c.mpv.mpv_command_string(p.mpv_ctx, cmd.ptr);
        return std.fmt.allocPrint(alloc, "Seeked to {s}", .{pos}) catch null;
    } else if (std.mem.eql(u8, action, "set_volume")) {
        var cmd_buf: [64]u8 = undefined;
        const vol = sanitizeNumeric(value orelse "100", "100");
        const cmd = std.fmt.bufPrintZ(&cmd_buf, "set volume {s}", .{vol}) catch return null;
        _ = c.mpv.mpv_command_string(p.mpv_ctx, cmd.ptr);
        return std.fmt.allocPrint(alloc, "Volume set to {s}%", .{vol}) catch null;
    } else if (std.mem.eql(u8, action, "set_speed")) {
        var cmd_buf: [64]u8 = undefined;
        const spd = sanitizeNumeric(value orelse "1.0", "1.0");
        const cmd = std.fmt.bufPrintZ(&cmd_buf, "set speed {s}", .{spd}) catch return null;
        _ = c.mpv.mpv_command_string(p.mpv_ctx, cmd.ptr);
        return std.fmt.allocPrint(alloc, "Speed set to {s}x", .{spd}) catch null;
    } else if (std.mem.eql(u8, action, "fullscreen")) {
        state.app.fullscreen_player_idx = idx;
        return std.fmt.allocPrint(alloc, "Fullscreen on", .{}) catch null;
    } else if (std.mem.eql(u8, action, "exit_fullscreen")) {
        state.app.fullscreen_player_idx = null;
        return std.fmt.allocPrint(alloc, "Exited fullscreen", .{}) catch null;
    }

    return std.fmt.allocPrint(alloc, "Unknown action: {s}", .{action}) catch null;
}

fn executePlayerInfo(alloc: std.mem.Allocator) ?[]u8 {
    const c = @import("../core/c.zig");

    if (state.app.players.items.len == 0)
        return std.fmt.allocPrint(alloc, "No player active", .{}) catch null;
    const idx = @min(state.app.active_player_idx, state.app.players.items.len - 1);
    const p = state.app.players.items[idx];

    // Get properties from MPV
    var pos: f64 = 0;
    var dur: f64 = 0;
    var vol: f64 = 100;
    var is_paused: c_int = 0;
    _ = c.mpv.mpv_get_property(p.mpv_ctx, "time-pos", c.mpv.MPV_FORMAT_DOUBLE, &pos);
    _ = c.mpv.mpv_get_property(p.mpv_ctx, "duration", c.mpv.MPV_FORMAT_DOUBLE, &dur);
    _ = c.mpv.mpv_get_property(p.mpv_ctx, "volume", c.mpv.MPV_FORMAT_DOUBLE, &vol);
    _ = c.mpv.mpv_get_property(p.mpv_ctx, "pause", c.mpv.MPV_FORMAT_FLAG, &is_paused);

    // Get title — prefer loading_label (human-readable) over raw URL
    const title = if (p.loading_label_len > 0 and p.loading_label_len <= 128)
        p.loading_label[0..p.loading_label_len]
    else
        "Unknown";
    const paused_str = if (is_paused != 0) "paused" else "playing";

    return std.fmt.allocPrint(alloc,
        "Status: {s} | Title: {s} | Position: {d:.0}s / {d:.0}s | Volume: {d:.0}%",
        .{ paused_str, title, pos, dur, vol }
    ) catch null;
}

fn executeNavigate(alloc: std.mem.Allocator, tc: *const ToolCall) ?[]u8 {
    const target = extractStringArg(tc.args_json[0..tc.args_len], "target") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'target'", .{}) catch null;

    if (std.mem.eql(u8, target, "settings")) {
        state.app.settings_open = true;
        return std.fmt.allocPrint(alloc, "Opened settings", .{}) catch null;
    } else if (std.mem.eql(u8, target, "close_drawer")) {
        state.app.drawer_open = false;
        return std.fmt.allocPrint(alloc, "Drawer closed", .{}) catch null;
    } else if (std.mem.eql(u8, target, "fullscreen")) {
        if (state.app.players.items.len > 0) {
            state.app.fullscreen_player_idx = state.app.active_player_idx;
        }
        return std.fmt.allocPrint(alloc, "Fullscreen on", .{}) catch null;
    }

    // Map target string to DrawerTab
    const tab: ?state.DrawerTab = if (std.mem.eql(u8, target, "search")) .Search
        else if (std.mem.eql(u8, target, "downloads")) .Downloads
        else if (std.mem.eql(u8, target, "tmdb")) .TMDB
        else if (std.mem.eql(u8, target, "youtube")) .YouTube
        else if (std.mem.eql(u8, target, "queue")) .Queue
        else if (std.mem.eql(u8, target, "comics")) .Comics
        else if (std.mem.eql(u8, target, "anime")) .Anime
        else if (std.mem.eql(u8, target, "history")) .History
        else if (std.mem.eql(u8, target, "rss")) .RSS
        else if (std.mem.eql(u8, target, "jellyfin")) .Jellyfin
        else if (std.mem.eql(u8, target, "ai")) .AI
        else null;

    if (tab) |t| {
        state.app.drawer_tab = t;
        state.app.drawer_open = true;
        return std.fmt.allocPrint(alloc, "Switched to {s} tab", .{target}) catch null;
    }

    return std.fmt.allocPrint(alloc, "Unknown target: {s}", .{target}) catch null;
}

fn executeQueueManage(alloc: std.mem.Allocator, tc: *const ToolCall) ?[]u8 {
    const queue = @import("queue.zig");
    const action = extractStringArg(tc.args_json[0..tc.args_len], "action") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'action'", .{}) catch null;

    if (std.mem.eql(u8, action, "play_next")) {
        if (state.app.players.items.len > 0) {
            const idx = @min(state.app.active_player_idx, state.app.players.items.len - 1);
            queue.playNextUnplayed(state.app.players.items[idx]);
            return std.fmt.allocPrint(alloc, "Playing next in queue", .{}) catch null;
        }
        return std.fmt.allocPrint(alloc, "No player active", .{}) catch null;
    } else if (std.mem.eql(u8, action, "clear")) {
        queue.clearAll();
        return std.fmt.allocPrint(alloc, "Queue cleared", .{}) catch null;
    } else if (std.mem.eql(u8, action, "clear_played")) {
        queue.clearPlayed();
        return std.fmt.allocPrint(alloc, "Cleared played items", .{}) catch null;
    } else if (std.mem.eql(u8, action, "list")) {
        // Return actual queue contents from DB
        const db = @import("../core/db.zig");
        var result = alloc.alloc(u8, MAX_TOOL_RESULT) catch return null;
        var off: usize = 0;
        const sql = "SELECT title, source FROM queue ORDER BY id DESC LIMIT 10";
        const stmt = db.prepare(sql);
        if (stmt != null) {
            defer db.finalize(stmt);
            var count: usize = 0;
            while (db.step(stmt) == db.c.SQLITE_ROW) {
                if (count == 0) {
                    const hdr = "Queue contents:\n";
                    @memcpy(result[off..off + hdr.len], hdr);
                    off += hdr.len;
                }
                const title = db.columnText(stmt, 0) orelse continue;
                const source = db.columnText(stmt, 1) orelse "";
                const line = std.fmt.bufPrint(result[off..], "{d}. {s} ({s})\n", .{ count + 1, title, source }) catch break;
                off += line.len;
                count += 1;
                if (off > MAX_TOOL_RESULT - 200) break;
            }
            if (count == 0) {
                alloc.free(result);
                return std.fmt.allocPrint(alloc, "Queue is empty.", .{}) catch null;
            }
        } else {
            alloc.free(result);
            return std.fmt.allocPrint(alloc, "Queue is empty.", .{}) catch null;
        }
        return result[0..off];
    }

    return std.fmt.allocPrint(alloc, "Unknown queue action: {s}", .{action}) catch null;
}

fn executeYoutubeSearch(alloc: std.mem.Allocator, tc: *const ToolCall) ?[]u8 {
    const youtube = @import("youtube.zig");
    const query = extractStringArg(tc.args_json[0..tc.args_len], "query") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'query'", .{}) catch null;

    // Switch to YouTube tab and trigger search
    state.app.drawer_tab = .YouTube;
    state.app.drawer_open = true;
    youtube.fetchYoutube(query);

    return std.fmt.allocPrint(alloc, "Searching YouTube for '{s}'. Results shown in YouTube tab.", .{query}) catch null;
}

fn executeAnimeSearch(alloc: std.mem.Allocator, tc: *const ToolCall) ?[]u8 {
    const anime = @import("anime.zig");
    const query = extractStringArg(tc.args_json[0..tc.args_len], "query") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'query'", .{}) catch null;
    const episode = extractStringArg(tc.args_json[0..tc.args_len], "episode");

    // Switch to Anime tab
    state.app.drawer_tab = .Anime;
    state.app.drawer_open = true;

    if (episode) |ep| {
        // Play specific episode — search first, then play
        anime.searchAnime(query);
        // Wait briefly for results
        @import("../core/io_global.zig").sleep(2000 * std.time.ns_per_ms);
        anime.playEpisode(ep);
        return std.fmt.allocPrint(alloc, "Playing {s} episode {s}", .{query, ep}) catch null;
    } else {
        anime.searchAnime(query);
        return std.fmt.allocPrint(alloc, "Searching anime for '{s}'. Results in Anime tab.", .{query}) catch null;
    }
}

fn executeJellyfinBrowse(alloc: std.mem.Allocator, tc: *const ToolCall) ?[]u8 {
    const jellyfin = @import("jellyfin.zig");
    const action = extractStringArg(tc.args_json[0..tc.args_len], "action") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'action'", .{}) catch null;

    // Switch to Jellyfin tab
    state.app.drawer_tab = .Jellyfin;
    state.app.drawer_open = true;

    if (std.mem.eql(u8, action, "libraries")) {
        jellyfin.fetchLibraries();
        return std.fmt.allocPrint(alloc, "Fetching Jellyfin libraries", .{}) catch null;
    } else if (std.mem.eql(u8, action, "search")) {
        const query = extractStringArg(tc.args_json[0..tc.args_len], "query") orelse
            return std.fmt.allocPrint(alloc, "Error: missing 'query' for search", .{}) catch null;
        // Copy query into jellyfin search buffer so searchItems() can read it
        const qlen = @min(query.len, state.app.jf.search_buf.len - 1);
        @memset(&state.app.jf.search_buf, 0);
        @memcpy(state.app.jf.search_buf[0..qlen], query[0..qlen]);
        jellyfin.searchItems();
        return std.fmt.allocPrint(alloc, "Searching Jellyfin for '{s}'", .{query}) catch null;
    } else if (std.mem.eql(u8, action, "play")) {
        const query = extractStringArg(tc.args_json[0..tc.args_len], "query") orelse
            return std.fmt.allocPrint(alloc, "Error: missing item ID for play", .{}) catch null;
        jellyfin.playItem(query);
        return std.fmt.allocPrint(alloc, "Playing from Jellyfin", .{}) catch null;
    }

    return std.fmt.allocPrint(alloc, "Unknown Jellyfin action: {s}", .{action}) catch null;
}

// ══════════════════════════════════════════════════════════
//  Comic Reader — Agentic Control
// ══════════════════════════════════════════════════════════

fn executeComicControl(alloc: std.mem.Allocator, tc: *const ToolCall) ?[]u8 {
    const comics = @import("comics.zig");
    const action = extractStringArg(tc.args_json[0..tc.args_len], "action") orelse
        return std.fmt.allocPrint(alloc, "Error: missing 'action'", .{}) catch null;
    const value = extractStringArg(tc.args_json[0..tc.args_len], "value");

    if (std.mem.eql(u8, action, "start_narration")) {
        // Navigate to comics tab and start narration
        state.app.drawer_tab = .Comics;
        state.app.drawer_open = true;
        if (!state.app.comic.narrating and state.app.comic.page_count > 0) {
            comics.toggleNarration();
        }
        return std.fmt.allocPrint(alloc, "Narration started from page {d}", .{state.app.comic.current_page + 1}) catch null;
    } else if (std.mem.eql(u8, action, "stop_narration")) {
        if (state.app.comic.narrating) {
            comics.toggleNarration();
        }
        return std.fmt.allocPrint(alloc, "Narration stopped", .{}) catch null;
    } else if (std.mem.eql(u8, action, "next_page")) {
        if (state.app.comic.current_page + 1 < state.app.comic.page_count) {
            state.app.comic.current_page += 1;
        }
        return std.fmt.allocPrint(alloc, "Page {d} of {d}", .{state.app.comic.current_page + 1, state.app.comic.page_count}) catch null;
    } else if (std.mem.eql(u8, action, "prev_page")) {
        if (state.app.comic.current_page > 0) {
            state.app.comic.current_page -= 1;
        }
        return std.fmt.allocPrint(alloc, "Page {d} of {d}", .{state.app.comic.current_page + 1, state.app.comic.page_count}) catch null;
    } else if (std.mem.eql(u8, action, "go_to_page")) {
        const page_str = value orelse return std.fmt.allocPrint(alloc, "Error: need page number in 'value'", .{}) catch null;
        // Parse page number
        var page_num: usize = 0;
        for (page_str) |ch| {
            if (ch >= '0' and ch <= '9') {
                page_num = page_num * 10 + (ch - '0');
            }
        }
        if (page_num > 0) page_num -= 1; // Convert from 1-based to 0-based
        if (page_num < state.app.comic.page_count) {
            state.app.comic.current_page = page_num;
        }
        return std.fmt.allocPrint(alloc, "Jumped to page {d} of {d}", .{state.app.comic.current_page + 1, state.app.comic.page_count}) catch null;
    } else if (std.mem.eql(u8, action, "read_page")) {
        // OCR current page and return text (also speak it)
        const pg = state.app.comic.current_page;
        if (pg >= state.app.comic.page_count) {
            return std.fmt.allocPrint(alloc, "No comic loaded", .{}) catch null;
        }
        comics.ocrPage(pg);
        state.app.comic.show_ocr_overlay = true;
        if (pg < 128 and state.app.comic.ocr_done[pg]) {
            const text_len = state.app.comic.ocr_lens[pg];
            if (text_len > 0) {
                // Speak it via TTS
                const ai_voice = @import("ai_voice.zig");
                ai_voice.speakResponse(state.app.comic.ocr_texts[pg][0..text_len]);
                return std.fmt.allocPrint(alloc, "Page {d} text: {s}", .{pg + 1, state.app.comic.ocr_texts[pg][0..text_len]}) catch null;
            }
        }
        return std.fmt.allocPrint(alloc, "No text detected on page {d}", .{pg + 1}) catch null;
    } else if (std.mem.eql(u8, action, "load_comic")) {
        const url = value orelse return std.fmt.allocPrint(alloc, "Error: need comic URL in 'value'", .{}) catch null;
        // Set the URL and trigger load
        const url_len = @min(url.len, state.app.comic.url_buf.len);
        @memcpy(state.app.comic.url_buf[0..url_len], url[0..url_len]);
        state.app.comic.url_len = url_len;
        state.app.drawer_tab = .Comics;
        state.app.drawer_open = true;
        comics.loadComic(url);
        return std.fmt.allocPrint(alloc, "Loading comic from: {s}", .{url[0..@min(url.len, 80)]}) catch null;
    }

    return std.fmt.allocPrint(alloc, "Unknown comic action: {s}", .{action}) catch null;
}

fn executeComicInfo(alloc: std.mem.Allocator) ?[]u8 {
    const pg = state.app.comic.current_page;
    const total = state.app.comic.page_count;

    if (total == 0) {
        return std.fmt.allocPrint(alloc, "No comic loaded. Use comic_control(load_comic) or navigate to Comics tab.", .{}) catch null;
    }

    var result = alloc.alloc(u8, MAX_TOOL_RESULT) catch return null;
    var off: usize = 0;

    // Basic info
    const info = std.fmt.bufPrint(result[off..], "Comic: page {d}/{d} | Narrating: {s}", .{
        pg + 1, total,
        if (state.app.comic.narrating) "yes" else "no",
    }) catch "";
    off += info.len;

    // OCR text if available
    if (pg < 128 and state.app.comic.ocr_done[pg]) {
        const text_len = state.app.comic.ocr_lens[pg];
        if (text_len > 0) {
            const hdr = "\nPage text: ";
            if (off + hdr.len < MAX_TOOL_RESULT) {
                @memcpy(result[off..off + hdr.len], hdr);
                off += hdr.len;
            }
            const copy_len = @min(text_len, MAX_TOOL_RESULT - off - 1);
            @memcpy(result[off..off + copy_len], state.app.comic.ocr_texts[pg][0..copy_len]);
            off += copy_len;
        } else {
            const no_text = "\nPage text: (no text detected)";
            if (off + no_text.len < MAX_TOOL_RESULT) {
                @memcpy(result[off..off + no_text.len], no_text);
                off += no_text.len;
            }
        }
    } else {
        const not_scanned = "\nPage text: (not yet scanned — use comic_control read_page)";
        if (off + not_scanned.len < MAX_TOOL_RESULT) {
            @memcpy(result[off..off + not_scanned.len], not_scanned);
            off += not_scanned.len;
        }
    }

    return result[0..off];
}

// ══════════════════════════════════════════════════════════
//  Tests (pure — parsing only, no io_global)
// ══════════════════════════════════════════════════════════

test "parseToolCall: canonical tool_call wrapper" {
    const text =
        \\{"message":"Sure","tool_call":{"name":"player_control","arguments":{"action":"pause"}}}
    ;
    const tc = parseToolCall(text) orelse return error.NoToolCall;
    try std.testing.expectEqualStrings("player_control", tc.name[0..tc.name_len]);
    try std.testing.expectEqualStrings("{\"action\":\"pause\"}", tc.args_json[0..tc.args_len]);
}

test "parseToolCall: null tool_call is not a call" {
    try std.testing.expect(!containsToolCall("{\"message\":\"hi\",\"tool_call\":null}"));
    try std.testing.expect(parseToolCall("{\"message\":\"hi\",\"tool_call\":null}") == null);
}

test "parseToolCall: wrapped in json fences" {
    const text =
        \\```json
        \\{"message":"ok","tool_call":{"name":"navigate","arguments":{"to":"downloads"}}}
        \\```
    ;
    try std.testing.expect(containsToolCall(text));
    const tc = parseToolCall(text) orelse return error.NoToolCall;
    try std.testing.expectEqualStrings("navigate", tc.name[0..tc.name_len]);
    try std.testing.expectEqualStrings("{\"to\":\"downloads\"}", tc.args_json[0..tc.args_len]);
}

test "parseToolCall: leading prose before json" {
    const text =
        \\Sure, let me do that for you.
        \\{"message":"Playing","tool_call":{"name":"find_and_play","arguments":{"query":"dune"}}}
    ;
    const tc = parseToolCall(text) orelse return error.NoToolCall;
    try std.testing.expectEqualStrings("find_and_play", tc.name[0..tc.name_len]);
    try std.testing.expectEqualStrings("{\"query\":\"dune\"}", tc.args_json[0..tc.args_len]);
}

test "parseToolCall: openai-style bare object without wrapper" {
    const text =
        \\{"name":"youtube_search","arguments":{"query":"cats"}}
    ;
    try std.testing.expect(containsToolCall(text));
    const tc = parseToolCall(text) orelse return error.NoToolCall;
    try std.testing.expectEqualStrings("youtube_search", tc.name[0..tc.name_len]);
    try std.testing.expectEqualStrings("{\"query\":\"cats\"}", tc.args_json[0..tc.args_len]);
}

test "parseToolCall: openai-style bare object in fences with prose" {
    const text =
        \\Here's the call:
        \\```json
        \\{"name":"player_info","arguments":{}}
        \\```
    ;
    const tc = parseToolCall(text) orelse return error.NoToolCall;
    try std.testing.expectEqualStrings("player_info", tc.name[0..tc.name_len]);
    try std.testing.expectEqualStrings("{}", tc.args_json[0..tc.args_len]);
}

test "parseToolCall: no tool call returns null" {
    try std.testing.expect(parseToolCall("{\"message\":\"just chatting\"}") == null);
    try std.testing.expect(!containsToolCall("{\"message\":\"just chatting\"}"));
}

test "parseToolCall: missing arguments still parses name" {
    const text =
        \\{"tool_call":{"name":"player_info"}}
    ;
    const tc = parseToolCall(text) orelse return error.NoToolCall;
    try std.testing.expectEqualStrings("player_info", tc.name[0..tc.name_len]);
    try std.testing.expect(tc.args_len == 0);
}
