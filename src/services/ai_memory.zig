const std = @import("std");
const db = @import("../core/db.zig");
const logs = @import("../core/logs.zig");

// ══════════════════════════════════════════════════════════
//  AI Memory — RAG Pipeline (Embedding, Ingestion, Retrieval)
// ══════════════════════════════════════════════════════════

pub const EMBED_DIM = 768;
const MAX_MSG_LEN = 2048;

// ── Embedding extraction ──

/// Get a 768-D embedding vector for text via the local embedding server (port 8082).
/// Uses a unique temp file per call to avoid race conditions between threads.
pub fn getEmbedding(text: []const u8, floats_out: *[EMBED_DIM]f32) bool {
    if (text.len == 0) return false;

    // Build JSON request body
    var json_buf: [MAX_MSG_LEN * 2 + 500]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&json_buf);
    const writer = &fbs;

    writer.print("{{\"input\": \"", .{}) catch return false;
    for (text) |ch| {
        switch (ch) {
            '"' => writer.print("\\\"", .{}) catch return false,
            '\n' => writer.print("\\n", .{}) catch return false,
            '\r' => writer.print("\\r", .{}) catch return false,
            '\t' => writer.print("\\t", .{}) catch return false,
            '\\' => writer.print("\\\\", .{}) catch return false,
            else => writer.writeByte(ch) catch return false,
        }
    }
    writer.print("\"}}", .{}) catch return false;

    // Use thread-unique temp files to avoid race conditions
    var req_path_buf: [64]u8 = undefined;
    const tid = std.Thread.getCurrentId();
    const req_path = std.fmt.bufPrintZ(&req_path_buf, "/tmp/opal_embed_req_{d}.json", .{tid}) catch return false;

    var resp_path_buf: [64]u8 = undefined;
    const resp_path = std.fmt.bufPrintZ(&resp_path_buf, "/tmp/opal_embed_resp_{d}.json", .{tid}) catch return false;

    // Write request body to file
    if (@import("../core/io_global.zig").cwdCreateFile(req_path, .{})) |req_file| {
        @import("../core/io_global.zig").writeAll(req_file, fbs.buffered()) catch return false;
        req_file.close(@import("../core/io_global.zig").io());
    } else |_| return false;

    // Call embedding server
    var data_arg_buf: [80]u8 = undefined;
    const data_arg = std.fmt.bufPrintZ(&data_arg_buf, "@{s}", .{req_path}) catch return false;

    var out_arg_buf: [80]u8 = undefined;
    const out_arg = std.fmt.bufPrintZ(&out_arg_buf, "{s}", .{resp_path}) catch return false;

    var curl_child = @import("../core/io_global.zig").Child.init(
        &.{ "curl", "-s", "-X", "POST", "-H", "Content-Type: application/json",
            "--data-binary", data_arg, "-o", out_arg, "--max-time", "10", "http://127.0.0.1:41593/v1/embeddings" },
        @import("../core/alloc.zig").allocator,
    );
    _ = curl_child.spawnAndWait() catch return false;

    // Read response
    const resp_file = @import("../core/io_global.zig").openFileAbsolute(resp_path, .{}) catch return false;
    defer resp_file.close(@import("../core/io_global.zig").io());

    // Clean up temp files
    defer @import("../core/io_global.zig").deleteFileAbsolute(req_path) catch {};
    defer @import("../core/io_global.zig").deleteFileAbsolute(resp_path) catch {};

    var resp_buf: [32768]u8 = undefined;
    const resp_len = @import("../core/io_global.zig").readAll(resp_file, &resp_buf) catch return false;
    if (resp_len == 0) return false;

    // Parse the embedding array from JSON
    const body = resp_buf[0..resp_len];
    const needle = "\"embedding\":[";
    const pos = std.mem.indexOf(u8, body, needle) orelse return false;

    var float_idx: usize = 0;
    var parse_pos = pos + needle.len;
    while (parse_pos < body.len and float_idx < EMBED_DIM) {
        var end_pos = parse_pos;
        while (end_pos < body.len and body[end_pos] != ',' and body[end_pos] != ']') : (end_pos += 1) {}

        const float_str = std.mem.trim(u8, body[parse_pos..end_pos], " \t\r\n");
        if (float_str.len > 0) {
            floats_out[float_idx] = std.fmt.parseFloat(f32, float_str) catch 0.0;
            float_idx += 1;
        }

        if (end_pos >= body.len or body[end_pos] == ']') break;
        parse_pos = end_pos + 1;
    }
    return float_idx == EMBED_DIM;
}

// ── Memory ingestion (async background thread) ──

const IngestArgs = struct {
    role: []u8,
    content: []u8,
    context_type: []u8,
    media_title: []u8,
    allocator: std.mem.Allocator,
};

fn ingestWorker(args: IngestArgs) void {
    defer {
        args.allocator.free(args.role);
        args.allocator.free(args.content);
        args.allocator.free(args.context_type);
        args.allocator.free(args.media_title);
    }

    if (args.content.len == 0) return;

    var floats: [EMBED_DIM]f32 = undefined;
    if (getEmbedding(args.content, &floats)) {
        db.insertMemory(args.role, args.content, args.context_type, args.media_title, &floats);
        logs.pushLog("debug", "ai-memory", "Ingested memory", false);
    }
}

/// Asynchronously ingest a message into the vector DB (non-blocking).
pub fn ingestMemory(role: []const u8, content: []const u8, context_type: []const u8, media_title: []const u8) void {
    if (content.len == 0) return;
    if (isJunkTurn(content)) return; // same poison filter as saveConversation
    const allocator = @import("../core/alloc.zig").allocator;
    // Free earlier successful dupes if a later one fails (else they leak).
    const r = allocator.dupe(u8, role) catch return;
    const cnt = allocator.dupe(u8, content) catch {
        allocator.free(r);
        return;
    };
    const ct = allocator.dupe(u8, context_type) catch {
        allocator.free(r);
        allocator.free(cnt);
        return;
    };
    const mt = allocator.dupe(u8, media_title) catch {
        allocator.free(r);
        allocator.free(cnt);
        allocator.free(ct);
        return;
    };
    const args = IngestArgs{
        .role = r,
        .content = cnt,
        .context_type = ct,
        .media_title = mt,
        .allocator = allocator,
    };

    const t = std.Thread.spawn(.{}, ingestWorker, .{args}) catch {
        allocator.free(args.role);
        allocator.free(args.content);
        allocator.free(args.context_type);
        allocator.free(args.media_title);
        return;
    };
    t.detach();
}

// ── Context retrieval for RAG ──

/// Build RAG context string for a user prompt.
/// Returns allocated memory (caller must free) or null if no context available.
pub fn buildContext(allocator: std.mem.Allocator, user_prompt: []const u8) ?[]u8 {
    var buf: [8192]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    const writer = &fbs;
    var has_content = false;

    // 1. Vector similarity search (semantic memory)
    var floats: [EMBED_DIM]f32 = undefined;
    if (getEmbedding(user_prompt, &floats)) {
        if (db.retrieveMemory(allocator, &floats, 5)) |mem| {
            defer allocator.free(mem);
            writer.print("Past conversations:\\n{s}\\n", .{mem}) catch {};
            has_content = true;
        }
    }

    // 2. Direct watch history from DB (always available, no embedding needed)
    const watch_sql = "SELECT name, percent, position_secs, duration_secs FROM watch_history ORDER BY updated_at DESC LIMIT 10";
    const stmt = db.prepare(watch_sql);
    if (stmt != null) {
        defer db.finalize(stmt);
        var watch_count: usize = 0;
        while (db.step(stmt) == db.c.SQLITE_ROW) {
            if (watch_count == 0) {
                writer.print("Recent watch history:\\n", .{}) catch {};
            }
            const name = db.columnText(stmt, 0) orelse continue;
            const pct = db.columnDouble(stmt, 1);
            const pos_secs = db.columnDouble(stmt, 2);
            const dur_secs = db.columnDouble(stmt, 3);

            // Extract clean title from path
            var clean_name = name;
            if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| {
                clean_name = name[slash + 1 ..];
            }

            const pos_min: u32 = @intFromFloat(pos_secs / 60);
            const dur_min: u32 = @intFromFloat(dur_secs / 60);

            writer.print("- {s} ({d:.0}% watched, {d}m/{d}m)\\n", .{ clean_name, pct, pos_min, dur_min }) catch {};
            watch_count += 1;
            has_content = true;
        }
    }

    // 3. TMDB user lists (favorites, watchlist, currently watching)
    const list_queries = [_]struct { name: []const u8, sql: []const u8 }{
        .{ .name = "Favorite movies/shows", .sql = "SELECT i.title, i.year, i.media_type, i.genre_text, i.rating FROM tmdb_items i JOIN tmdb_lists l ON i.id = l.item_id WHERE l.list_name = 'fav' LIMIT 15" },
        .{ .name = "Watchlist", .sql = "SELECT i.title, i.year, i.media_type, i.genre_text, i.rating FROM tmdb_items i JOIN tmdb_lists l ON i.id = l.item_id WHERE l.list_name = 'wl' LIMIT 15" },
        .{ .name = "Currently watching", .sql = "SELECT i.title, i.year, i.media_type, i.genre_text, i.rating FROM tmdb_items i JOIN tmdb_lists l ON i.id = l.item_id WHERE l.list_name = 'wat' LIMIT 15" },
    };

    for (list_queries) |lq| {
        const list_stmt = db.prepare(lq.sql);
        if (list_stmt != null) {
            defer db.finalize(list_stmt);
            var list_count: usize = 0;
            while (db.step(list_stmt) == db.c.SQLITE_ROW) {
                if (list_count == 0) {
                    writer.print("{s}:\\n", .{lq.name}) catch {};
                }
                const title = db.columnText(list_stmt, 0) orelse continue;
                const year = db.columnText(list_stmt, 1) orelse "";
                const mtype = db.columnText(list_stmt, 2) orelse "";
                const genre = db.columnText(list_stmt, 3) orelse "";
                const rating = db.columnDouble(list_stmt, 4);
                const pct: u8 = @intFromFloat(std.math.clamp(rating * 10.0, 0.0, 100.0));

                writer.print("- {s}", .{title}) catch {};
                if (year.len > 0) writer.print(" ({s})", .{year}) catch {};
                if (mtype.len > 0) writer.print(" [{s}]", .{mtype}) catch {};
                if (genre.len > 0) writer.print(" {s}", .{genre}) catch {};
                writer.print(" {d}%\\n", .{pct}) catch {};
                list_count += 1;
                has_content = true;
            }
        }
    }

    if (!has_content) return null;
    return allocator.dupe(u8, fbs.buffered()) catch null;
}

// ══════════════════════════════════════════════════════════
// Cross-Session Conversation Persistence
// ══════════════════════════════════════════════════════════

/// Reject content that's LLM plumbing, not human-readable dialogue.
/// Tool-call placeholders, tool-response JSON blobs, and similar framing
/// leak into the prompt as past-session context and poison future turns —
/// the model echoes the pattern it sees ("[tool_call] [tool_response]" loop).
pub fn isJunkTurn(content: []const u8) bool {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return true;
    if (std.mem.startsWith(u8, trimmed, "[tool_call")) return true;
    if (std.mem.startsWith(u8, trimmed, "[tool_response")) return true;
    if (std.mem.startsWith(u8, trimmed, "{\"tool_call\"")) return true;
    if (std.mem.startsWith(u8, trimmed, "{\"tool_response\"")) return true;
    // Fallback: high density of tool-call markers anywhere in text
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, trimmed, i, "[tool_")) |p| : (i = p + 6) count += 1;
    if (count >= 2) return true;
    return false;
}

/// Save a conversation exchange to the persistent log.
/// Only saves substantial messages (>10 chars) to avoid noise.
pub fn saveConversation(role: []const u8, content: []const u8) void {
    if (content.len < 10) return; // skip trivial messages
    if (isJunkTurn(content)) return; // reject tool-plumbing poison
    const q = "INSERT INTO conversation_log(role, content) VALUES(?1, ?2)";
    const stmt = db.prepare(q) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, role);
    db.bindText(stmt, 2, content);
    _ = db.step(stmt);
}

/// One-time purge of already-poisoned rows. Idempotent — WHERE clause is
/// a no-op once the store is clean.
pub fn purgeJunkConversations() void {
    const q =
        \\DELETE FROM conversation_log
        \\WHERE content LIKE '[tool_call%'
        \\   OR content LIKE '[tool_response%'
        \\   OR content LIKE '{"tool_call"%'
        \\   OR content LIKE '{"tool_response"%'
        \\   OR content LIKE '%[tool_call]%[tool_response]%'
    ;
    db.exec(q);
}

/// Get recent conversation history from past sessions for context injection.
pub fn getRecentConversations(allocator: std.mem.Allocator) ?[]u8 {
    const sql = "SELECT role, content, created_at FROM conversation_log ORDER BY created_at DESC LIMIT 20";
    const stmt = db.prepare(sql) orelse return null;
    defer db.finalize(stmt);

    var buf: [4096]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    const writer = &fbs;
    var count: usize = 0;

    while (db.step(stmt) == db.c.SQLITE_ROW) {
        const role = db.columnText(stmt, 0) orelse continue;
        const content = db.columnText(stmt, 1) orelse continue;
        if (isJunkTurn(content)) continue; // belt-and-suspenders: skip legacy poison
        const ts = db.columnInt(stmt, 2);
        
        // Time ago
        const now = @as(i32, @intCast(@min(@import("../core/io_global.zig").timestamp(), std.math.maxInt(i32))));
        const ago_mins = @divTrunc(now - ts, 60);

        if (count == 0) {
            writer.writeAll("Past conversations:\n") catch {};
        }

        if (ago_mins < 60) {
            writer.print("[{d}m ago] {s}: {s}\n", .{ ago_mins, role, content[0..@min(content.len, 120)] }) catch {};
        } else if (ago_mins < 1440) {
            writer.print("[{d}h ago] {s}: {s}\n", .{ @divTrunc(ago_mins, 60), role, content[0..@min(content.len, 120)] }) catch {};
        } else {
            writer.print("[{d}d ago] {s}: {s}\n", .{ @divTrunc(ago_mins, 1440), role, content[0..@min(content.len, 120)] }) catch {};
        }
        count += 1;
    }

    if (count == 0) return null;
    return allocator.dupe(u8, fbs.buffered()) catch null;
}

// ══════════════════════════════════════════════════════════
// Proactive Suggestion Engine
// ══════════════════════════════════════════════════════════

/// Generate a proactive suggestion based on user patterns.
/// Returns a natural language suggestion or null if nothing to suggest.
pub fn getProactiveSuggestion(buf: []u8, name_buf: []u8) ?[]const u8 {
    // Strategy 1: Continue watching (unfinished content > 10% < 90%)
    const continue_sql = "SELECT name, percent, position_secs, duration_secs FROM watch_history WHERE percent > 0.1 AND percent < 0.9 ORDER BY updated_at DESC LIMIT 1";
    const stmt1 = db.prepare(continue_sql);
    if (stmt1 != null) {
        defer db.finalize(stmt1);
        if (db.step(stmt1) == db.c.SQLITE_ROW) {
            const name_raw = db.columnText(stmt1, 0) orelse return null;
            const pct = db.columnDouble(stmt1, 1);
            const pos = db.columnDouble(stmt1, 2);
            if (pct > 0.1) {
                // Copy name before finalize invalidates the pointer
                const nlen = @min(name_raw.len, name_buf.len);
                @memcpy(name_buf[0..nlen], name_raw[0..nlen]);
                var clean: []const u8 = name_buf[0..nlen];
                
                // Extract filename from path
                if (std.mem.lastIndexOfScalar(u8, clean, '/')) |slash| {
                    clean = clean[slash + 1..];
                }
                // Remove file extension
                if (std.mem.lastIndexOfScalar(u8, clean, '.')) |dot| {
                    if (dot > 0) clean = clean[0..dot];
                }

                const pos_min: u32 = @intFromFloat(pos / 60);
                const pct_int: u32 = @intFromFloat(pct * 100);

                const msg = std.fmt.bufPrint(buf, "You left off at {d}min ({d}%) of \"{s}\". Want to continue?", .{ pos_min, pct_int, clean[0..@min(clean.len, 80)] }) catch return null;
                return msg;
            }
        }
    }

    return null;
}

/// Get the URL and position of the most recent unfinished content for resuming.
pub fn getResumeTarget(url_buf: []u8) ?struct { url: []const u8, position: f64 } {
    const sql = "SELECT name, position_secs FROM watch_history WHERE percent > 0.1 AND percent < 0.9 ORDER BY updated_at DESC LIMIT 1";
    const stmt = db.prepare(sql);
    if (stmt != null) {
        defer db.finalize(stmt);
        if (db.step(stmt) == db.c.SQLITE_ROW) {
            const url_raw = db.columnText(stmt, 0) orelse return null;
            const pos = db.columnDouble(stmt, 1);
            const ulen = @min(url_raw.len, url_buf.len);
            @memcpy(url_buf[0..ulen], url_raw[0..ulen]);
            return .{ .url = url_buf[0..ulen], .position = pos };
        }
    }
    return null;
}

// ══════════════════════════════════════════════════════════
// Preference Learning
// ══════════════════════════════════════════════════════════

/// Increment preference weight for a key (e.g., genre, time_of_day)
pub fn learnPreference(key: []const u8, value: []const u8) void {
    const sql = "INSERT INTO user_preferences(key, value, weight, updated_at) VALUES(?1, ?2, 1.0, strftime('%s','now')) " ++
        "ON CONFLICT(key) DO UPDATE SET weight = weight + 1.0, value = ?2, updated_at = strftime('%s','now')";
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, key);
    db.bindText(stmt, 2, value);
    _ = db.step(stmt);
}

/// Get top preferences for context injection
pub fn getTopPreferences(allocator: std.mem.Allocator) ?[]u8 {
    const sql = "SELECT key, value, weight FROM user_preferences ORDER BY weight DESC LIMIT 10";
    const stmt = db.prepare(sql) orelse return null;
    defer db.finalize(stmt);

    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    const writer = &fbs;
    var count: usize = 0;

    while (db.step(stmt) == db.c.SQLITE_ROW) {
        const key = db.columnText(stmt, 0) orelse continue;
        const value = db.columnText(stmt, 1) orelse continue;
        const weight = db.columnDouble(stmt, 2);

        if (count == 0) writer.writeAll("User preferences:\n") catch {};
        writer.print("- {s}: {s} (strength: {d:.0})\n", .{ key, value, weight }) catch {};
        count += 1;
    }

    if (count == 0) return null;
    return allocator.dupe(u8, fbs.buffered()) catch null;
}
