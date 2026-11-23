//! Assistant / voice "jump to the scene where …" (ROADMAP 7.1). A transcript
//! (spoken through ai_voice → ai_chat, or typed) reaches tryHandle from
//! ai_context.tryFastPath. Intent parsing, match choice, the "which one?"
//! follow-up and reply text are scene_jump_pure.handleTranscript; this file
//! supplies Recall's moment search as its Searcher and performs the result:
//! seek the active player, or open another item at that second.

const std = @import("std");
const state = @import("../core/state.zig");
const db = @import("../core/db.zig");
const sync = @import("../core/sync.zig");
const workers = @import("../core/workers.zig");
const logs = @import("../core/logs.zig");
const alloc = @import("../core/alloc.zig").allocator;
const c = @import("../core/c.zig");
const pure = @import("scene_jump_pure.zig");
const recall = @import("recall.zig");
const chat = @import("ai_chat.zig");
const voice = @import("ai_voice.zig");

/// Choices offered by the last turn, waiting for "which one?". Read by the
/// caller's thread in tryHandle and written by the worker → `mutex`.
var mutex: sync.Mutex = .{};
var pending: pure.Pending = .{};
var busy = std.atomic.Value(bool).init(false);

/// Claim `raw_input` when it is a scene request or an answer to pending
/// choices: post the user turn, start the worker, return true. Otherwise
/// false, and the assistant handles the text as before.
pub fn tryHandle(raw_input: []const u8) bool {
    mutex.lock();
    const claimed = pure.claims(raw_input, &pending);
    mutex.unlock();
    if (!claimed) return false;
    if (busy.load(.acquire)) return false; // a jump is still searching
    if (chat.message_count + 2 > chat.MAX_MESSAGES) return false;

    const text = alloc.dupe(u8, raw_input) catch return false;
    const ulen = @min(raw_input.len, chat.MAX_MSG_LEN);
    chat.messages[chat.message_count] = .{ .role = .user, .text_len = ulen };
    @memcpy(chat.messages[chat.message_count].text[0..ulen], raw_input[0..ulen]);
    chat.message_count += 1;
    chat.messages[chat.message_count] = .{ .role = .assistant, .text_len = 0 };
    const assistant_idx = chat.message_count;
    chat.message_count += 1;
    @memset(&chat.input_buf, 0);
    chat.input_len = 0;
    chat.last_error_len = 0;

    busy.store(true, .release);
    chat.is_generating.store(true, .release);
    if (workers.spawnLegacy(worker, .{ text, assistant_idx })) |t| {
        workers.release(t);
    } else |_| {
        alloc.free(text);
        busy.store(false, .release);
        chat.is_generating.store(false, .release);
        reply(assistant_idx, "Could not start the scene search.");
    }
    return true;
}

fn reply(assistant_idx: usize, msg: []const u8) void {
    if (assistant_idx >= chat.MAX_MESSAGES) return;
    const n = @min(msg.len, chat.MAX_MSG_LEN);
    @memcpy(chat.messages[assistant_idx].text[0..n], msg[0..n]);
    chat.messages[assistant_idx].text_len = n;
    if (voice.voice_mode and n > 0) voice.speakResponse(msg[0..n]);
}

/// Recall's moment search as a scene_jump_pure.Searcher.
const RecallSearch = struct {
    fn search(_: *anyopaque, query: []const u8, out: []pure.Candidate) usize {
        const results = alloc.create(recall.Results) catch return 0;
        defer alloc.destroy(results);
        recall.search(query, results, .{});
        var n: usize = 0;
        for (results.moments[0..results.moment_count]) |*m| {
            if (n >= out.len) break;
            out[n] = .{ .moment_id = m.id, .doc_id = m.doc_id, .start_secs = m.start_secs, .score = m.score };
            out[n].setTitle(m.titleText());
            out[n].setSnippet(m.snippetText());
            n += 1;
        }
        return n;
    }
};

/// Recall doc id of the active player's media, when it is indexed.
fn currentDoc() ?i64 {
    var url_buf: [2048]u8 = undefined;
    var url_len: usize = 0;
    state.players_mutex.lock();
    if (state.app.active_player_idx < state.app.players.items.len) {
        const p = state.app.players.items[state.app.active_player_idx];
        url_len = @min(p.current_url_len, url_buf.len, p.current_url.len);
        @memcpy(url_buf[0..url_len], p.current_url[0..url_len]);
    }
    state.players_mutex.unlock();
    if (url_len == 0 or !db.tableExists("recall_docs")) return null;
    const url = url_buf[0..url_len];
    const bare = if (std.mem.startsWith(u8, url, "file://")) url["file://".len..] else url;
    const stmt = db.prepare("SELECT id FROM recall_docs WHERE link=?1 OR link=?2 LIMIT 1") orelse return null;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, url);
    db.bindText(stmt, 2, bare);
    if (db.step(stmt) != db.c.SQLITE_ROW) return null;
    return db.columnInt64(stmt, 0);
}

fn seekActive(secs: f64) bool {
    var cmd_buf: [64]u8 = undefined;
    const cmd = @import("opal-fmt").bufPrintZ(&cmd_buf, "seek {d:.3} absolute+exact", .{secs}) catch return false;
    state.players_mutex.lock();
    defer state.players_mutex.unlock();
    if (state.app.active_player_idx >= state.app.players.items.len) return false;
    const p = state.app.players.items[state.app.active_player_idx];
    _ = c.mpv.mpv_command_string(p.mpv_ctx, cmd.ptr);
    return true;
}

fn worker(text: []const u8, assistant_idx: usize) void {
    defer alloc.free(text);
    defer busy.store(false, .release);
    defer chat.is_generating.store(false, .release);

    mutex.lock();
    var turn = pending;
    mutex.unlock();
    var dummy: u8 = 0;
    const searcher = pure.Searcher{ .ctx = &dummy, .search = RecallSearch.search, .current_doc = currentDoc() };
    var msg_buf: [1024]u8 = undefined;
    const action = pure.handleTranscript(text, &turn, searcher, &msg_buf);
    mutex.lock();
    pending = turn;
    mutex.unlock();

    switch (action) {
        .ignore => reply(assistant_idx, "Say \"jump to the scene where\" and what happens in it."),
        .say => |m| reply(assistant_idx, m),
        .ask => |m| reply(assistant_idx, m),
        .seek => |s| {
            if (seekActive(s.cand.start_secs)) {
                reply(assistant_idx, s.msg);
            } else reply(assistant_idx, "Nothing is playing to jump in.");
        },
        .open => |o| {
            const t = recall.target(0, o.cand.moment_id) orelse return reply(assistant_idx, pure.msg_none);
            if (recall.play(&t)) {
                reply(assistant_idx, o.msg);
            } else reply(assistant_idx, "That scene is in an item Opal has to open from its own page first.");
        },
    }
    var log_buf: [96]u8 = undefined;
    logs.pushLog("info", "assistant", std.fmt.bufPrint(&log_buf, "scene jump: {s}", .{@tagName(action)}) catch "scene jump", false);
}
