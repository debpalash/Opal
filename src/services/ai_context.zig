const std = @import("std");
const chat = @import("ai_chat.zig");
const server = @import("ai_server.zig");
const memory = @import("ai_memory.zig");
const tools = @import("ai_tools.zig");
const resolver = @import("resolver.zig");
const voice = @import("ai_voice.zig");
const intent = @import("ai_intent.zig");
const logs = @import("../core/logs.zig");
const state = @import("../core/state.zig");

pub const FastPathAction = enum { play_best, search };

/// Check if input is a contextual query that references last search.
/// Returns resolved query or null if not contextual.
fn resolveContextual(input: []const u8, buf: *[256]u8) ?[]const u8 {
    if (chat.last_show_len == 0) return null; // no context

    const is_next = std.mem.indexOf(u8, input, "next ep") != null or
        std.mem.indexOf(u8, input, "next one") != null or
        std.mem.eql(u8, input, "next");
    const is_prev = std.mem.indexOf(u8, input, "prev") != null or
        std.mem.indexOf(u8, input, "last ep") != null;
    const is_again = std.mem.indexOf(u8, input, "again") != null or
        std.mem.indexOf(u8, input, "replay") != null or
        std.mem.indexOf(u8, input, "same") != null;

    const season = chat.last_season;
    var episode = chat.last_episode;

    if (is_next) {
        episode += 1;
    } else if (is_prev) {
        if (episode > 1) episode -= 1;
    } else if (is_again) {
        // Same episode — replay
    } else {
        return null;
    }

    // Build: "show name S02E03"
    const show = chat.last_show[0..chat.last_show_len];
    if (season > 0 and episode > 0) {
        const r = std.fmt.bufPrint(buf, "{s} S{d:0>2}E{d:0>2}", .{ show, season, episode }) catch return null;
        return r;
    } else {
        // No season/episode info — just replay the show name
        @memcpy(buf[0..show.len], show);
        return buf[0..show.len];
    }
}

/// Extract and save show name + season/episode from a normalized query.
/// E.g., "the boys S02E03" → show="the boys", season=2, episode=3
pub fn saveSearchContext(query: []const u8) void {
    // Look for SxxExx pattern
    var lower_q: [256]u8 = undefined;
    const ql = @min(query.len, 255);
    for (0..ql) |i| lower_q[i] = std.ascii.toLower(query[i]);
    const lq = lower_q[0..ql];

    // Find 's' followed by digits followed by 'e' followed by digits
    var s_pos: ?usize = null;
    var i: usize = 0;
    while (i < ql) : (i += 1) {
        if (lq[i] == 's' and i + 1 < ql and std.ascii.isDigit(lq[i + 1])) {
            // Check if this is SxxExx
            var j = i + 1;
            while (j < ql and std.ascii.isDigit(lq[j])) j += 1;
            if (j < ql and lq[j] == 'e' and j + 1 < ql and std.ascii.isDigit(lq[j + 1])) {
                s_pos = i;
                break;
            }
        }
    }

    if (s_pos) |sp| {
        // Extract show name (everything before the SxxExx pattern, trimmed)
        const show_raw = std.mem.trim(u8, query[0..sp], " ");
        const slen = @min(show_raw.len, 127);
        @memcpy(chat.last_show[0..slen], show_raw[0..slen]);
        chat.last_show_len = slen;

        // Parse season number
        var si = sp + 1;
        var season_val: u16 = 0;
        while (si < ql and std.ascii.isDigit(lq[si])) : (si += 1) {
            season_val = season_val * 10 + @as(u16, lq[si] - '0');
        }
        chat.last_season = season_val;

        // Skip 'e'
        if (si < ql and lq[si] == 'e') si += 1;

        // Parse episode number
        var ep_val: u16 = 0;
        while (si < ql and std.ascii.isDigit(lq[si])) : (si += 1) {
            ep_val = ep_val * 10 + @as(u16, lq[si] - '0');
        }
        chat.last_episode = ep_val;
    } else {
        // No SxxExx — just save the show name, clear ep info
        const slen = @min(query.len, 127);
        @memcpy(chat.last_show[0..slen], query[0..slen]);
        chat.last_show_len = slen;
        chat.last_season = 0;
        chat.last_episode = 0;
    }
}

// ══════════════════════════════════════════════════════════
//  Instant Commands — Skip LLM, execute immediately
// ══════════════════════════════════════════════════════════

fn addInstantResponse(raw_input: []const u8, response: []const u8) void {
    // Add user message
    if (chat.message_count >= chat.MAX_MESSAGES) return;
    const ulen = @min(raw_input.len, chat.MAX_MSG_LEN);
    chat.messages[chat.message_count] = .{ .role = .user, .text_len = ulen };
    @memcpy(chat.messages[chat.message_count].text[0..ulen], raw_input[0..ulen]);
    chat.message_count += 1;

    // Add assistant response
    if (chat.message_count >= chat.MAX_MESSAGES) return;
    const rlen = @min(response.len, chat.MAX_MSG_LEN);
    chat.messages[chat.message_count] = .{ .role = .assistant, .text_len = rlen };
    @memcpy(chat.messages[chat.message_count].text[0..rlen], response[0..rlen]);
    chat.message_count += 1;

    // TTS if in voice mode
    if (voice.voice_mode and response.len > 0) {
        voice.speakResponse(response);
    }
}

fn tryInstantCommand(raw_input: []const u8, fl_raw: []const u8) bool {
    const c = @import("../core/c.zig");

    // Extract first sentence (STT often repeats: "Full screen. Full screen.")
    // But skip sentence splitting for URLs (they contain dots that aren't sentence boundaries)
    const first_sentence = blk: {
        if (std.mem.startsWith(u8, fl_raw, "http://") or std.mem.startsWith(u8, fl_raw, "https://") or
            std.mem.startsWith(u8, fl_raw, "play http") or std.mem.startsWith(u8, fl_raw, "open http"))
        {
            break :blk fl_raw; // Don't split URLs on dots
        }
        for (fl_raw, 0..) |ch, i| {
            if ((ch == '.' or ch == '!' or ch == '?') and i > 2) {
                break :blk fl_raw[0..i];
            }
        }
        break :blk fl_raw;
    };
    // Trim trailing punctuation and whitespace (but preserve URL slashes)
    const fl = if (std.mem.startsWith(u8, first_sentence, "http"))
        std.mem.trimEnd(u8, first_sentence, " \t")
    else
        std.mem.trimEnd(u8, first_sentence, ".!?,;: ");

    // Get active player (if any)
    const has_player = state.app.players.items.len > 0;
    const p_idx = if (has_player) @min(state.app.active_player_idx, state.app.players.items.len - 1) else 0;

    // ── Player control ──
    if (std.mem.eql(u8, fl, "pause") or std.mem.eql(u8, fl, "stop")) {
        if (has_player) {
            _ = c.mpv.mpv_command_string(state.app.players.items[p_idx].mpv_ctx, "set pause yes");
            addInstantResponse(raw_input, "Paused.");
        } else addInstantResponse(raw_input, "Nothing playing.");
        return true;
    }
    if (std.mem.eql(u8, fl, "resume") or std.mem.eql(u8, fl, "unpause") or std.mem.eql(u8, fl, "continue")) {
        if (has_player) {
            _ = c.mpv.mpv_command_string(state.app.players.items[p_idx].mpv_ctx, "set pause no");
            addInstantResponse(raw_input, "Resumed.");
        } else addInstantResponse(raw_input, "Nothing playing.");
        return true;
    }

    // ── Direct URL playback: pasted URLs or "play <url>" ──
    {
        const url_input = if (std.mem.startsWith(u8, fl, "play "))
            std.mem.trim(u8, fl["play ".len..], " ")
        else if (std.mem.startsWith(u8, fl, "open "))
            std.mem.trim(u8, fl["open ".len..], " ")
        else
            fl;

        if (std.mem.startsWith(u8, url_input, "http://") or std.mem.startsWith(u8, url_input, "https://")) {
            if (has_player) {
                var url_z: [1024]u8 = std.mem.zeroes([1024]u8);
                const ulen = @min(url_input.len, url_z.len - 1);
                @memcpy(url_z[0..ulen], url_input[0..ulen]);
                state.app.players.items[p_idx].load_file(@ptrCast(&url_z));

                const streamlink = @import("../services/streamlink.zig");
                if (streamlink.isStreamlinkUrl(url_input)) {
                    addInstantResponse(raw_input, "Opening live stream...");
                } else {
                    addInstantResponse(raw_input, "Loading URL...");
                }
            } else {
                addInstantResponse(raw_input, "No player open yet.");
            }
            return true;
        }
    }

    // ── Stream recording ──
    if (std.mem.eql(u8, fl, "record") or std.mem.startsWith(u8, fl, "record stream") or std.mem.startsWith(u8, fl, "start record")) {
        const streamlink = @import("../services/streamlink.zig");
        if (has_player) {
            const p = state.app.players.items[p_idx];
            if (p.current_url_len > 0 and streamlink.isStreamlinkUrl(p.current_url[0..p.current_url_len])) {
                streamlink.startRecording(p.current_url[0..p.current_url_len]);
                addInstantResponse(raw_input, "Recording stream...");
            } else {
                addInstantResponse(raw_input, "No live stream to record.");
            }
        } else {
            addInstantResponse(raw_input, "No player open.");
        }
        return true;
    }

    if (std.mem.eql(u8, fl, "stop recording") or std.mem.eql(u8, fl, "stop record")) {
        const streamlink = @import("../services/streamlink.zig");
        streamlink.stopRecording();
        addInstantResponse(raw_input, "Recording stopped.");
        return true;
    }

    // ── Stream quality: "quality 720p", "quality best" etc ──
    if (std.mem.startsWith(u8, fl, "quality ")) {
        const streamlink = @import("../services/streamlink.zig");
        const quality = std.mem.trim(u8, fl["quality ".len..], " ");
        if (has_player) {
            const p = state.app.players.items[p_idx];
            if (p.current_url_len > 0 and streamlink.isStreamlinkUrl(p.current_url[0..p.current_url_len])) {
                // Re-resolve with new quality and reload
                const S = struct {
                    var q_buf: [16]u8 = undefined;
                    var q_len: usize = 0;
                    var u_buf: [1024]u8 = undefined;
                    var u_len: usize = 0;
                    var pi: usize = 0;
                    var busy: bool = false;

                    fn worker() void {
                        defer @This().busy = false;
                        // Modify the resolver to use requested quality
                        const argv2: []const []const u8 = &.{
                            "python3",
                            streamlink.getResolverPath(),
                            u_buf[0..u_len],
                            q_buf[0..q_len],
                        };
                        var child = @import("../core/io_global.zig").Child.init(argv2, @import("../core/alloc.zig").allocator);
                        child.stdout_behavior = .Pipe;
                        child.stderr_behavior = .Ignore;
                        child.spawn() catch return;
                        var res_buf: [2048]u8 = undefined;
                        const n = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, &res_buf) catch 0 else 0;
                        _ = child.wait() catch {};
                        const trimmed = std.mem.trim(u8, res_buf[0..n], " \t\r\n");
                        if (trimmed.len > 10 and std.mem.startsWith(u8, trimmed, "http")) {
                            if (state.app.players.items.len > pi) {
                                const mpv = @import("../core/c.zig").mpv;
                                var load_z: [2048]u8 = std.mem.zeroes([2048]u8);
                                @memcpy(load_z[0..trimmed.len], trimmed);
                                var args2 = [_][*c]const u8{ "loadfile", @ptrCast(&load_z), null };
                                _ = mpv.mpv_command(state.app.players.items[pi].mpv_ctx, @ptrCast(&args2));
                            }
                        }
                    }
                };
                if (S.busy) return true;
                const ql = @min(quality.len, 15);
                @memcpy(S.q_buf[0..ql], quality[0..ql]);
                S.q_len = ql;
                const ul = @min(p.current_url_len, 1023);
                @memcpy(S.u_buf[0..ul], p.current_url[0..ul]);
                S.u_len = ul;
                S.pi = p_idx;
                S.busy = true;
                const t = std.Thread.spawn(.{}, S.worker, .{}) catch {
                    S.busy = false;
                    return true;
                };
                t.detach();

                var resp_buf2: [64]u8 = undefined;
                const resp = std.fmt.bufPrint(&resp_buf2, "Switching to {s} quality...", .{quality}) catch "Switching quality...";
                addInstantResponse(raw_input, resp);
            } else {
                addInstantResponse(raw_input, "Not a live stream.");
            }
        }
        return true;
    }

    // "volume XX" or "vol XX"
    if (std.mem.startsWith(u8, fl, "volume ") or std.mem.startsWith(u8, fl, "vol ")) {
        if (has_player) {
            const num_start = if (std.mem.startsWith(u8, fl, "volume ")) @as(usize, 7) else @as(usize, 4);
            const vol_str = std.mem.trim(u8, fl[num_start..], " ");
            var cmd_buf: [64]u8 = undefined;
            const cmd = std.fmt.bufPrintZ(&cmd_buf, "set volume {s}", .{vol_str}) catch return false;
            _ = c.mpv.mpv_command_string(state.app.players.items[p_idx].mpv_ctx, cmd.ptr);
            var resp_buf: [64]u8 = undefined;
            const resp = std.fmt.bufPrint(&resp_buf, "Volume set to {s}%", .{vol_str}) catch return false;
            addInstantResponse(raw_input, resp);
        } else addInstantResponse(raw_input, "Nothing playing.");
        return true;
    }

    // "skip XX" or "forward XX" or "skip" (default 10s)
    if (std.mem.startsWith(u8, fl, "skip") or std.mem.startsWith(u8, fl, "forward")) {
        if (has_player) {
            const prefix_len = if (std.mem.startsWith(u8, fl, "forward")) @as(usize, 7) else @as(usize, 4);
            const rest = std.mem.trim(u8, fl[prefix_len..], " s");
            const secs = if (rest.len > 0) rest else "10";
            var cmd_buf: [64]u8 = undefined;
            const cmd = std.fmt.bufPrintZ(&cmd_buf, "seek {s}", .{secs}) catch return false;
            _ = c.mpv.mpv_command_string(state.app.players.items[p_idx].mpv_ctx, cmd.ptr);
            var resp_buf: [64]u8 = undefined;
            const resp = std.fmt.bufPrint(&resp_buf, "Skipped {s}s forward.", .{secs}) catch return false;
            addInstantResponse(raw_input, resp);
        } else addInstantResponse(raw_input, "Nothing playing.");
        return true;
    }

    // "rewind XX" or "back XX"
    if (std.mem.startsWith(u8, fl, "rewind") or std.mem.startsWith(u8, fl, "back ")) {
        if (has_player) {
            const prefix_len = if (std.mem.startsWith(u8, fl, "rewind")) @as(usize, 6) else @as(usize, 5);
            const rest = std.mem.trim(u8, fl[prefix_len..], " s");
            const secs = if (rest.len > 0) rest else "10";
            var cmd_buf: [64]u8 = undefined;
            const cmd = std.fmt.bufPrintZ(&cmd_buf, "seek -{s}", .{secs}) catch return false;
            _ = c.mpv.mpv_command_string(state.app.players.items[p_idx].mpv_ctx, cmd.ptr);
            var resp_buf: [64]u8 = undefined;
            const resp = std.fmt.bufPrint(&resp_buf, "Rewound {s}s.", .{secs}) catch return false;
            addInstantResponse(raw_input, resp);
        } else addInstantResponse(raw_input, "Nothing playing.");
        return true;
    }

    // "speed X.X"
    if (std.mem.startsWith(u8, fl, "speed ")) {
        if (has_player) {
            const spd = std.mem.trim(u8, fl[6..], " x");
            var cmd_buf: [64]u8 = undefined;
            const cmd = std.fmt.bufPrintZ(&cmd_buf, "set speed {s}", .{spd}) catch return false;
            _ = c.mpv.mpv_command_string(state.app.players.items[p_idx].mpv_ctx, cmd.ptr);
            var resp_buf: [64]u8 = undefined;
            const resp = std.fmt.bufPrint(&resp_buf, "Speed {s}x.", .{spd}) catch return false;
            addInstantResponse(raw_input, resp);
        } else addInstantResponse(raw_input, "Nothing playing.");
        return true;
    }

    // "mute" / "unmute"
    if (std.mem.eql(u8, fl, "mute")) {
        if (has_player) {
            _ = c.mpv.mpv_command_string(state.app.players.items[p_idx].mpv_ctx, "set mute yes");
            addInstantResponse(raw_input, "Muted.");
        } else addInstantResponse(raw_input, "Nothing playing.");
        return true;
    }
    if (std.mem.eql(u8, fl, "unmute")) {
        if (has_player) {
            _ = c.mpv.mpv_command_string(state.app.players.items[p_idx].mpv_ctx, "set mute no");
            addInstantResponse(raw_input, "Unmuted.");
        } else addInstantResponse(raw_input, "Nothing playing.");
        return true;
    }

    // "fullscreen"
    if (std.mem.eql(u8, fl, "fullscreen") or std.mem.eql(u8, fl, "full screen")) {
        if (has_player) {
            state.app.fullscreen_player_idx = p_idx;
            addInstantResponse(raw_input, "Fullscreen on.");
        }
        return true;
    }
    if (std.mem.startsWith(u8, fl, "exit fullscreen") or std.mem.startsWith(u8, fl, "exit full")) {
        state.app.fullscreen_player_idx = null;
        addInstantResponse(raw_input, "Exited fullscreen.");
        return true;
    }

    // "suggest" / "recommend" / "what should i watch"
    if (std.mem.eql(u8, fl, "suggest") or std.mem.eql(u8, fl, "recommend") or
        std.mem.eql(u8, fl, "what should i watch") or std.mem.eql(u8, fl, "what to watch"))
    {
        var sug_buf: [256]u8 = undefined;
        var sug_name_buf: [128]u8 = undefined;
        if (memory.getProactiveSuggestion(&sug_buf, &sug_name_buf)) |suggestion| {
            addInstantResponse(raw_input, suggestion);
        } else {
            addInstantResponse(raw_input, "Nothing to suggest yet — watch some content first!");
        }
        return true;
    }

    // "yes" / "continue watching" / "resume watching" — resume last unfinished content
    if (std.mem.eql(u8, fl, "yes") or std.mem.eql(u8, fl, "yeah") or
        std.mem.eql(u8, fl, "continue watching") or std.mem.eql(u8, fl, "resume watching") or
        std.mem.eql(u8, fl, "yes continue") or std.mem.eql(u8, fl, "yes please"))
    {
        var resume_url_buf: [512]u8 = undefined;
        if (memory.getResumeTarget(&resume_url_buf)) |target| {
            // Load the content into the player
            const player_mod = @import("../player/player.zig");
            if (state.app.players.items.len > 0) {
                const p_i = @min(state.app.active_player_idx, state.app.players.items.len - 1);
                var url_z: [513]u8 = std.mem.zeroes([513]u8);
                @memcpy(url_z[0..target.url.len], target.url);
                state.app.players.items[p_i].load_file(@ptrCast(&url_z));
                // Seek to saved position
                if (target.position > 5) {
                    var seek_buf: [64]u8 = undefined;
                    const seek_cmd = std.fmt.bufPrint(&seek_buf, "seek {d:.0} absolute", .{target.position}) catch "seek 0 absolute";
                    _ = c.mpv.mpv_command_string(state.app.players.items[p_i].mpv_ctx, @ptrCast(seek_cmd.ptr));
                }
                // Extract clean name for response
                var clean: []const u8 = target.url;
                if (std.mem.lastIndexOfScalar(u8, clean, '/')) |slash| clean = clean[slash + 1 ..];
                if (std.mem.lastIndexOfScalar(u8, clean, '.')) |dot| {
                    if (dot > 0) clean = clean[0..dot];
                }
                const pos_min: u32 = @intFromFloat(target.position / 60);
                var rbuf: [128]u8 = undefined;
                const resp = std.fmt.bufPrint(&rbuf, "Resuming \"{s}\" at {d}min...", .{ clean[0..@min(clean.len, 60)], pos_min }) catch "Resuming...";
                addInstantResponse(raw_input, resp);
            } else {
                // No player — need to create one. Use player_mod to open.
                _ = player_mod;
                addInstantResponse(raw_input, "Opening player... try again in a moment.");
            }
        } else {
            // No resume target — let the LLM handle "yes" in conversation context
            return false;
        }
        return true;
    }

    // "what's playing" / "whats playing" / "what is playing"
    if (std.mem.startsWith(u8, fl, "what") and
        (std.mem.indexOf(u8, fl, "playing") != null or std.mem.indexOf(u8, fl, "watching") != null))
    {
        if (has_player) {
            const p = state.app.players.items[p_idx];
            if (p.loading_label_len > 0) {
                addInstantResponse(raw_input, p.loading_label[0..p.loading_label_len]);
            } else if (p.current_url_len > 0) {
                addInstantResponse(raw_input, p.current_url[0..@min(p.current_url_len, 120)]);
            } else {
                addInstantResponse(raw_input, "Nothing playing right now.");
            }
        } else {
            addInstantResponse(raw_input, "Nothing playing right now.");
        }
        return true;
    }

    // "close" drawer
    if (std.mem.eql(u8, fl, "close") or std.mem.eql(u8, fl, "close drawer")) {
        state.app.drawer_open = false;
        addInstantResponse(raw_input, "Closed.");
        return true;
    }

    // "clear chat" / "clear history" / "new chat"
    if (std.mem.eql(u8, fl, "clear chat") or std.mem.eql(u8, fl, "clear history") or
        std.mem.eql(u8, fl, "new chat") or std.mem.eql(u8, fl, "clear"))
    {
        chat.clearHistory();
        return true;
    }

    // "save chat" / "export chat" — dump conversation to file
    if (std.mem.eql(u8, fl, "save chat") or std.mem.eql(u8, fl, "export chat") or
        std.mem.eql(u8, fl, "save conversation"))
    {
        if (@import("../core/state.zig").app.incognito_mode) {
            addInstantResponse(raw_input, "Incognito is on — this chat won't be saved anywhere.");
            return true;
        }
        var path_buf: [128]u8 = undefined;
        const ts = @import("../core/io_global.zig").timestamp();
        const path = std.fmt.bufPrint(&path_buf, "/tmp/opal_chat_{d}.txt", .{ts}) catch "/tmp/opal_chat.txt";
        if (@import("../core/io_global.zig").cwdCreateFile(path, .{})) |f| {
            defer f.close(@import("../core/io_global.zig").io());
            var i: usize = 0;
            while (i < chat.message_count) : (i += 1) {
                const m = &chat.messages[i];
                if (m.text_len == 0 or m.role == .system) continue;
                const role_str = switch (m.role) {
                    .user => "User",
                    .assistant => "Opal",
                    .system => "System",
                };
                @import("../core/io_global.zig").writeAll(f, role_str) catch {};
                @import("../core/io_global.zig").writeAll(f, ": ") catch {};
                @import("../core/io_global.zig").writeAll(f, m.text[0..m.text_len]) catch {};
                @import("../core/io_global.zig").writeAll(f, "\n\n") catch {};
            }
            var resp: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&resp, "Chat saved to {s}", .{path}) catch "Chat saved.";
            addInstantResponse(raw_input, msg);
        } else |_| {
            addInstantResponse(raw_input, "Failed to save chat.");
        }
        return true;
    }

    // "incognito" / "incognito mode"
    if (std.mem.startsWith(u8, fl, "incognito")) {
        chat.incognito_mode = !chat.incognito_mode;
        const msg = if (chat.incognito_mode) "Incognito mode on. Messages won't be saved." else "Incognito mode off.";
        addInstantResponse(raw_input, msg);
        return true;
    }

    // "enroll voice" / "enroll" — speaker identification enrollment
    if (std.mem.eql(u8, fl, "enroll") or std.mem.eql(u8, fl, "enroll voice") or
        std.mem.eql(u8, fl, "enroll my voice"))
    {
        voice.enrollSpeaker();
        addInstantResponse(raw_input, "Speak for 5 seconds to enroll your voice...");
        return true;
    }

    // "stop listening" / "be quiet" — deactivate conversation mode
    if (std.mem.eql(u8, fl, "stop listening") or std.mem.eql(u8, fl, "be quiet") or
        std.mem.eql(u8, fl, "shut up") or std.mem.eql(u8, fl, "go away"))
    {
        voice.conversation_active = false;
        voice.is_recording = false;
        voice.voice_mode = false;
        voice.setPhase(.idle);
        addInstantResponse(raw_input, "Conversation mode off. Click to restart.");
        return true;
    }

    // "start listening" / "listen" — activate conversation mode
    if (std.mem.eql(u8, fl, "start listening") or std.mem.eql(u8, fl, "listen") or
        std.mem.eql(u8, fl, "hey opal") or std.mem.eql(u8, fl, "hey zig zag"))
    {
        if (!voice.conversation_active) {
            voice.toggleConversation();
        }
        addInstantResponse(raw_input, "I'm listening.");
        return true;
    }

    // "theme" / "next theme" / "switch theme" — cycle theme preset
    if (std.mem.eql(u8, fl, "theme") or std.mem.eql(u8, fl, "next theme") or
        std.mem.eql(u8, fl, "switch theme") or std.mem.eql(u8, fl, "change theme"))
    {
        const theme = @import("../ui/theme.zig");
        theme.cycleTheme();
        const name = theme.presetName(theme.active_preset);
        var rbuf: [64]u8 = undefined;
        const resp = std.fmt.bufPrint(&rbuf, "Theme: {s}", .{name}) catch "Theme switched.";
        addInstantResponse(raw_input, resp);
        return true;
    }

    // Specific theme names
    const theme_cmds = [_]struct { cmd: []const u8, preset: @import("../ui/theme.zig").ThemePreset }{
        .{ .cmd = "midnight", .preset = .midnight },
        .{ .cmd = "abyss", .preset = .abyss },
        .{ .cmd = "phantom", .preset = .phantom },
        .{ .cmd = "nord", .preset = .nord },
        .{ .cmd = "solarized", .preset = .solarized },
        .{ .cmd = "rose", .preset = .rose },
        .{ .cmd = "ember", .preset = .ember },
    };
    for (theme_cmds) |tc| {
        if (std.mem.eql(u8, fl, tc.cmd) or
            (std.mem.startsWith(u8, fl, "theme ") and std.mem.eql(u8, fl["theme ".len..], tc.cmd)))
        {
            const theme = @import("../ui/theme.zig");
            theme.setPreset(tc.preset);
            const name = theme.presetName(tc.preset);
            var rbuf: [64]u8 = undefined;
            const resp = std.fmt.bufPrint(&rbuf, "Theme: {s}", .{name}) catch "Theme applied.";
            addInstantResponse(raw_input, resp);
            return true;
        }
    }

    // "use voice X" — switch TTS voice
    if (std.mem.startsWith(u8, fl, "use voice ") or std.mem.startsWith(u8, fl, "voice ")) {
        const prefix_len: usize = if (std.mem.startsWith(u8, fl, "use voice ")) 10 else 6;
        const voice_raw = std.mem.trim(u8, fl[prefix_len..], " ");
        if (voice_raw.len > 0 and voice_raw.len <= 16) {
            // Capitalize first letter
            var voice_buf: [16]u8 = std.mem.zeroes([16]u8);
            @memcpy(voice_buf[0..voice_raw.len], voice_raw);
            if (voice_buf[0] >= 'a' and voice_buf[0] <= 'z') {
                voice_buf[0] -= 32;
            }
            @memcpy(state.app.tts_voice_buf[0..voice_raw.len], voice_buf[0..voice_raw.len]);
            state.app.tts_voice_len = voice_raw.len;
            state.markConfigDirty();
            var rbuf: [64]u8 = undefined;
            const resp = std.fmt.bufPrint(&rbuf, "Voice: {s}", .{voice_buf[0..voice_raw.len]}) catch "Voice updated.";
            addInstantResponse(raw_input, resp);
        } else {
            addInstantResponse(raw_input, "Available: Bella, Luna, Grace, Aria, Sarah");
        }
        return true;
    }

    // ── Navigation commands ──
    const NavTarget = struct { prefix: []const u8, tab: state.DrawerTab, name: []const u8 };
    const nav_targets = [_]NavTarget{
        .{ .prefix = "show downloads", .tab = .Downloads, .name = "Downloads" },
        .{ .prefix = "show youtube", .tab = .YouTube, .name = "YouTube" },
        .{ .prefix = "show anime", .tab = .Anime, .name = "Anime" },
        .{ .prefix = "show queue", .tab = .Queue, .name = "Queue" },
        .{ .prefix = "show comics", .tab = .Comics, .name = "Comics" },
        .{ .prefix = "show history", .tab = .History, .name = "History" },
        .{ .prefix = "show rss", .tab = .RSS, .name = "RSS" },
        .{ .prefix = "show jellyfin", .tab = .Jellyfin, .name = "Jellyfin" },
        .{ .prefix = "show tmdb", .tab = .TMDB, .name = "TMDB" },
        .{ .prefix = "open downloads", .tab = .Downloads, .name = "Downloads" },
        .{ .prefix = "open youtube", .tab = .YouTube, .name = "YouTube" },
        .{ .prefix = "open anime", .tab = .Anime, .name = "Anime" },
        .{ .prefix = "open queue", .tab = .Queue, .name = "Queue" },
        .{ .prefix = "open settings", .tab = .Search, .name = "Settings" },
    };

    for (nav_targets) |nt| {
        if (std.mem.startsWith(u8, fl, nt.prefix)) {
            if (std.mem.eql(u8, nt.name, "Settings")) {
                state.app.settings_open = true;
            } else {
                state.navigateToTab(nt.tab);
            }
            var resp_buf: [64]u8 = undefined;
            const resp = std.fmt.bufPrint(&resp_buf, "Opened {s}.", .{nt.name}) catch return false;
            addInstantResponse(raw_input, resp);
            return true;
        }
    }

    return false;
}

/// Common fast-path dispatch: add messages, spawn resolver thread.
fn dispatchFastPath(raw_input: []const u8, query: []const u8, action: FastPathAction) bool {
    // Add user message to chat
    if (chat.message_count >= chat.MAX_MESSAGES) return false;
    chat.messages[chat.message_count] = .{ .role = .user, .text_len = @min(raw_input.len, chat.MAX_MSG_LEN) };
    @memcpy(chat.messages[chat.message_count].text[0..chat.messages[chat.message_count].text_len], raw_input[0..chat.messages[chat.message_count].text_len]);
    chat.message_count += 1;

    // Add assistant "Searching..." message
    if (chat.message_count >= chat.MAX_MESSAGES) return false;
    const searching_msg = "Searching...";
    chat.messages[chat.message_count] = .{ .role = .assistant, .text_len = searching_msg.len };
    @memcpy(chat.messages[chat.message_count].text[0..searching_msg.len], searching_msg);
    chat.message_count += 1;

    @memset(&chat.input_buf, 0);
    chat.input_len = 0;
    chat.is_generating.store(true, .release);
    chat.last_error_len = 0;

    // By-value copy of the query string so the thread doesn't read a dead stack frame
    var t_buf: [256]u8 = std.mem.zeroes([256]u8);
    const qlen = @min(query.len, 255);
    @memcpy(t_buf[0..qlen], query[0..qlen]);

    // Spawn fast-path thread
    const t = std.Thread.spawn(.{}, fastPathResolve, .{ t_buf, qlen, chat.message_count - 1, action }) catch {
        chat.is_generating.store(false, .release);
        return false;
    };
    t.detach();

    return true;
}

/// Fast-path: intercept media commands, classify intent, and route smartly.
/// - Recommendations → TMDB trending (never torrents)
/// - Specific titles → normalize query, then multi-source search
/// - Genre browse → TMDB genre search
/// Returns true if handled.
pub fn tryFastPath(raw_input: []const u8) bool {
    if (raw_input.len < 2) return false;

    // Full lowercase copy
    var full_lower: [chat.MAX_INPUT_LEN]u8 = undefined;
    const flen = @min(raw_input.len, chat.MAX_INPUT_LEN - 1);
    for (0..flen) |i| full_lower[i] = std.ascii.toLower(raw_input[i]);
    const fl = full_lower[0..flen];

    // ── Instant player/nav commands (skip LLM entirely) ──
    if (tryInstantCommand(raw_input, fl)) return true;

    // ── Contextual queries ("next episode", "replay") ──
    var ctx_buf: [256]u8 = undefined;
    const ctx_query = resolveContextual(fl, &ctx_buf);
    if (ctx_query) |resolved| {
        return dispatchFastPath(raw_input, resolved, .play_best);
    }

    // ── Intent classification ──
    const user_intent = intent.classifyIntent(fl);

    // Handle recommendations — route to TMDB, NOT torrents
    if (user_intent == .recommendation) {
        return intent.handleRecommendation(raw_input);
    }

    // Handle genre browse — open TMDB drawer with genre keyword
    if (user_intent == .browse_genre) {
        return intent.handleGenreBrowse(raw_input);
    }

    // Handle contextual nav — pick from existing chat_results, skip search
    if (user_intent == .contextual_nav) {
        if (!chat.chat_results_active or chat.chat_result_count == 0) {
            addInstantResponse(raw_input, "No results to pick from — search first.");
            return true;
        }
        const current = chat.recommended_idx orelse 0;
        const picked = intent.parseNavIndex(fl, current) orelse {
            addInstantResponse(raw_input, "Didn't catch which one — try 'play the first' or 'next'.");
            return true;
        };
        if (picked >= chat.chat_result_count) {
            var msg_buf: [96]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Only {d} result(s) on screen.", .{chat.chat_result_count}) catch "Out of range.";
            addInstantResponse(raw_input, msg);
            return true;
        }
        const ai_chat = @import("ai_chat.zig");
        ai_chat.playChatResult(picked);
        var ok_buf: [128]u8 = undefined;
        const name_slice = chat.chat_results[picked].name[0..@min(chat.chat_results[picked].name_len, 80)];
        const ok = std.fmt.bufPrint(&ok_buf, "Playing #{d}: {s}", .{ picked + 1, name_slice }) catch "Playing.";
        addInstantResponse(raw_input, ok);
        return true;
    }

    // ── Normalize query first (strips "can you play ", etc.) ──
    var norm_buf: [256]u8 = undefined;
    const normalized = intent.normalizeQuery(fl, &norm_buf);

    // Now check if it originally had play intents (either raw or after normalization)
    const is_explicit_play = std.mem.indexOf(u8, fl, "play ") != null or
        std.mem.indexOf(u8, fl, "watch ") != null or
        std.mem.indexOf(u8, fl, "put on ") != null or
        std.mem.indexOf(u8, fl, "start ") != null;

    const is_search = std.mem.indexOf(u8, fl, "find ") != null or
        std.mem.indexOf(u8, fl, "search ") != null;

    if (!is_explicit_play and !is_search) {
        // No explicit play/search command.
        // But if it has season/episode, we assume it's a media request.
        const has_episode = std.mem.indexOf(u8, fl, "season ") != null or
            std.mem.indexOf(u8, fl, "episode ") != null or
            std.mem.indexOf(u8, fl, " ep ") != null or
            std.mem.indexOf(u8, fl, " s0") != null or
            std.mem.indexOf(u8, fl, " s1") != null or
            std.mem.indexOf(u8, fl, " s2") != null;

        if (has_episode and normalized.len >= 2) {
            return dispatchFastPath(raw_input, normalized, .play_best);
        }
        return false;
    }

    if (normalized.len < 2) return false;

    // Use normalized term, but check if we need to manually remove 'play ' if it's still at the start
    var final_query = normalized;
    if (std.mem.startsWith(u8, final_query, "play ")) {
        final_query = final_query[5..];
    } else if (std.mem.startsWith(u8, final_query, "find ")) {
        final_query = final_query[5..];
    } else if (std.mem.startsWith(u8, final_query, "watch ")) {
        final_query = final_query[6..];
    } else if (std.mem.startsWith(u8, final_query, "search ")) {
        final_query = final_query[7..];
    }

    final_query = std.mem.trim(u8, final_query, " ");
    if (final_query.len < 2) return false;

    const action: FastPathAction = if (is_explicit_play) .play_best else .search;
    return dispatchFastPath(raw_input, final_query, action);
}

fn fastPathResolve(query_buf: [256]u8, query_len: usize, assistant_idx: usize, action: FastPathAction) void {
    chat.phase = .searching;
    defer {
        chat.is_generating.store(false, .release);
        chat.phase = .idle;
    }

    const query = query_buf[0..query_len];
    resolver.resolve(query, "auto");

    // Wait for results. Torrent aggregators routinely take 10-20s — the old
    // 5s cap caused "0 results" fallbacks while the side panel was still
    // filling. New policy:
    //   • Keep going as long as resolver is still working (up to 30s cap).
    //   • Early exit only when we have enough (≥5 results) OR when
    //     resolver has finished AND we've waited ≥1s for slow backends.
    const io = @import("../core/io_global.zig");
    var waited: usize = 0;
    const max_ticks: usize = 300; // 300 × 100ms = 30s hard cap
    while (waited < max_ticks) : (waited += 1) {
        const rc = resolver.result_count;
        const done = !resolver.isResolving();
        // Plenty of results — don't keep users waiting on slow trackers
        if (rc >= 5 and waited >= 10) break;
        // Resolver finished. Give one extra tick for late mutex writers, then stop.
        if (done and waited >= 10) break;
        // Resolver finished with something — exit
        if (done and rc > 0) break;
        io.sleep(100 * std.time.ns_per_ms);
    }

    // Copy results to chat, filtering out error/garbage results
    resolver.results_mutex.lock();
    const raw_count = @min(resolver.result_count, 64);
    var filtered_count: usize = 0;
    var has_indexer_error = false;
    for (0..raw_count) |i| {
        if (filtered_count >= 12) break;
        const item = &resolver.results[i];
        const name = item.name[0..@min(item.name_len, 256)];
        // Filter out Jackett API errors and garbage
        if (intent.isErrorResult(name)) {
            has_indexer_error = true;
            continue;
        }
        chat.chat_results[filtered_count] = resolver.results[i];
        filtered_count += 1;
    }
    chat.chat_result_count = filtered_count;
    resolver.results_mutex.unlock();
    chat.chat_results_active = filtered_count > 0;

    // Set recommendation for play commands
    if (action == .play_best and filtered_count > 0) {
        chat.recommended_idx = 0;
        chat.awaiting_confirmation = true;
    } else {
        chat.recommended_idx = null;
        chat.awaiting_confirmation = false;
    }

    // Save search context for "next episode" etc.
    saveSearchContext(query);

    // Write canned response directly (no second LLM call!)
    if (assistant_idx < chat.MAX_MESSAGES) {
        var resp_buf: [512]u8 = undefined;
        var resp_len: usize = 0;

        if (filtered_count == 0) {
            // Smart Fallback: if fast path fails, simulate a tool failure and run LLM
            chat.is_generating.store(true, .release);

            var fallback_buf: [1024]u8 = undefined;
            const fallback_msg = std.fmt.bufPrint(&fallback_buf, "I automatically searched for streams of '{s}' but found 0 results. Provide a conversational response to the user, perhaps suggesting they search TMDB instead.", .{query}) catch "Search failed.";

            chat.messages[assistant_idx].role = .system;
            chat.messages[assistant_idx].text_len = fallback_msg.len;
            @memcpy(chat.messages[assistant_idx].text[0..fallback_msg.len], fallback_msg);

            if (chat.message_count < chat.MAX_MESSAGES) {
                chat.messages[chat.message_count] = .{ .role = .assistant, .text_len = 0 };
                chat.message_count += 1;

                const gen_thread = std.Thread.spawn(.{}, generateResponse, .{}) catch return;
                gen_thread.detach();
                return;
            }
        } else if (action == .play_best) {
            // Show the pick with reasoning + up to 2 runner-ups so user
            // can see why it was chosen (title/year/quality/seeds). The
            // ranking already scored on relevance + quality + seeds.
            var w = std.Io.Writer.fixed(&resp_buf);
            const best_item = chat.chat_results[0];
            const best = best_item.name[0..best_item.name_len];
            const best_q: []const u8 = switch (best_item.quality) {
                4 => "4K",
                3 => "1080p",
                2 => "720p",
                1 => "480p",
                else => "SD",
            };
            w.print(
                "Picked **{s}** ({d}% title match · {s} · {d} seeds).\n",
                .{ best, best_item.match_pct, best_q, best_item.seeds },
            ) catch {};
            if (filtered_count > 1) {
                w.writeAll("Other candidates:\n") catch {};
                const show_n = @min(filtered_count, 3);
                var ri: usize = 1;
                while (ri < show_n) : (ri += 1) {
                    const it = chat.chat_results[ri];
                    const nm = it.name[0..it.name_len];
                    const q: []const u8 = switch (it.quality) {
                        4 => "4K",
                        3 => "1080p",
                        2 => "720p",
                        1 => "480p",
                        else => "SD",
                    };
                    w.print("· {s} ({d}% · {s} · {d} seeds)\n", .{ nm, it.match_pct, q, it.seeds }) catch {};
                }
            }
            w.writeAll("Say **play** or **yes** to start. Or click another.") catch {};
            resp_len = w.buffered().len;
        } else {
            const r = std.fmt.bufPrint(&resp_buf, "Found {d} results. Pick one from the list or click ▶ to play.", .{filtered_count}) catch "Results ready.";
            resp_len = r.len;
        }

        chat.messages[assistant_idx].text_len = @min(resp_len, chat.MAX_MSG_LEN);
        @memcpy(chat.messages[assistant_idx].text[0..chat.messages[assistant_idx].text_len], resp_buf[0..chat.messages[assistant_idx].text_len]);
    }

    // TTS: always speak play confirmations so the AI feels alive
    if (assistant_idx < chat.MAX_MESSAGES) {
        if (chat.awaiting_confirmation and filtered_count > 0) {
            // Short, natural TTS prompt for play confirmation
            var tts_buf: [256]u8 = undefined;
            const best_name = chat.chat_results[0].name[0..@min(chat.chat_results[0].name_len, 80)];
            const tts_msg = std.fmt.bufPrint(&tts_buf, "I found {s}. Want me to play it?", .{best_name}) catch "Found a match. Want me to play it?";
            voice.speakResponse(tts_msg);
        } else if (voice.voice_mode) {
            voice.speakResponse(chat.messages[assistant_idx].text[0..chat.messages[assistant_idx].text_len]);
        }
    }
}

var tool_depth: u8 = 0;

pub fn generateResponse() void {
    chat.phase = .waiting_server;
    // Serialize every model-touching call across the app. Other callers
    // (TTS speak, STT transcribe, tool-chain recursion) acquire the same
    // mutex so we never have two concurrent inference paths hitting apfel.
    server.inference_mutex.lock();
    defer server.inference_mutex.unlock();
    chat.phase = .thinking;

    // Fresh generation — clear any stale abort request from a previous reply.
    chat.gen_abort.store(false, .release);

    defer {
        chat.is_generating.store(false, .release);
        chat.phase = .idle;
        tool_depth = 0; // Reset depth when the chain completes
    }

    if (chat.message_count < 2) {
        chat.setError("No message to respond to");
        return;
    }
    const assistant_idx = chat.message_count - 1;

    var json_buf: [8192]u8 = undefined;
    var msg_part: [6144]u8 = undefined;
    var msg_off: usize = 0;

    // RAG: Build context from vector DB + watch history
    const user_text = chat.messages[assistant_idx - 1].text[0..chat.messages[assistant_idx - 1].text_len];
    var rag_context: ?[]u8 = null;
    // Incognito: fresh brain — no vector-memory / watch-history retrieval.
    if (!@import("../core/state.zig").app.incognito_mode) {
        rag_context = memory.buildContext(@import("../core/alloc.zig").allocator, user_text);
    }
    defer if (rag_context) |ctx| @import("../core/alloc.zig").allocator.free(ctx);

    // System prompt with RAG context (must be JSON-escaped at runtime
    // because SYSTEM_PROMPT contains real newlines from multiline literals)
    const sys_start = "{\"role\":\"system\",\"content\":\"";
    @memcpy(msg_part[msg_off .. msg_off + sys_start.len], sys_start);
    msg_off += sys_start.len;

    // ── Dynamic System Prompt — conditionally include tools ──
    const has_player = state.app.active_player_idx < state.app.players.items.len;
    var dyn_buf: [3072]u8 = undefined;
    var dyn_fbs = std.Io.Writer.fixed(&dyn_buf);
    const dw = &dyn_fbs;

    // Base prompt
    dw.writeAll(tools.TOOL_SYSTEM_PROMPT) catch {};
    // Routing hint: "find the scene where... / take me back to when..." → recall_scene
    if (has_player) {
        dw.writeAll("\nWhen the user asks to find the scene where something happened, or to take them back to when something was said, use recall_scene.") catch {};
    }
    dw.writeAll("\n<tools>\n[") catch {};

    // Core tools (always)
    dw.writeAll(
        \\
        \\  {"name":"find_and_play","description":"Search/play media.","parameters":{"type":"object","properties":{"query":{"type":"string"},"content_type":{"type":"string","enum":["auto","movie","show","anime","youtube","comic"]},"action":{"type":"string","enum":["search","play_best"]}},"required":["query"]}},
        \\  {"name":"navigate","description":"Switch UI tabs.","parameters":{"type":"object","properties":{"target":{"type":"string","enum":["search","downloads","tmdb","youtube","queue","comics","anime","history","rss","jellyfin","ai","settings","close_drawer","fullscreen"]}},"required":["target"]}},
        \\  {"name":"youtube_search","description":"Search YouTube.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}},
        \\  {"name":"anime_search","description":"Search anime.","parameters":{"type":"object","properties":{"query":{"type":"string"},"episode":{"type":"string"}},"required":["query"]}},
        \\  {"name":"browse_tmdb","description":"TMDB lookup.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}
    ) catch {};

    // Player tools — only when player is active
    if (has_player) {
        dw.writeAll(
            \\,
            \\  {"name":"player_control","description":"Playback: pause/resume/stop/seek/volume/speed/fullscreen.","parameters":{"type":"object","properties":{"action":{"type":"string","enum":["pause","resume","toggle_pause","stop","seek_forward","seek_backward","seek_to","set_volume","set_speed","fullscreen","exit_fullscreen"]},"value":{"type":"string"}},"required":["action"]}},
            \\  {"name":"player_info","description":"Now playing info.","parameters":{"type":"object","properties":{}}},
            \\  {"name":"look_at_screen","description":"Returns on-screen text (OCR), the current subtitle, and recent dialogue. Use when the user asks who someone is, what was just said, what is happening on screen, or for a recap.","parameters":{"type":"object","properties":{}}},
            \\  {"name":"recall_scene","description":"Find a remembered scene from the user's own watch history by describing it in natural language (what was said, what happened, a feeling) and jump the player there. Use when the user asks to find or return to a scene/moment they saw before.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}},
            \\  {"name":"queue_manage","description":"Queue ops.","parameters":{"type":"object","properties":{"action":{"type":"string","enum":["list","play_next","clear","clear_played"]}},"required":["action"]}}
        ) catch {};
    }

    dw.writeAll("\n]\n</tools>") catch {};
    const dyn_str = dyn_fbs.buffered();

    // JSON-escape dynamic prompt
    for (dyn_str) |ch| {
        if (msg_off >= 5600) break;
        switch (ch) {
            '"' => {
                if (msg_off + 2 > msg_part.len) break;
                msg_part[msg_off] = '\\';
                msg_off += 1;
                msg_part[msg_off] = '"';
                msg_off += 1;
            },
            '\n' => {
                if (msg_off + 2 > msg_part.len) break;
                msg_part[msg_off] = '\\';
                msg_off += 1;
                msg_part[msg_off] = 'n';
                msg_off += 1;
            },
            '\r' => {},
            '\\' => {
                if (msg_off + 2 > msg_part.len) break;
                msg_part[msg_off] = '\\';
                msg_off += 1;
                msg_part[msg_off] = '\\';
                msg_off += 1;
            },
            '\t' => {
                if (msg_off + 2 > msg_part.len) break;
                msg_part[msg_off] = '\\';
                msg_off += 1;
                msg_part[msg_off] = 't';
                msg_off += 1;
            },
            else => |c| {
                if (c < 32) continue; // skip other control chars
                msg_part[msg_off] = c;
                msg_off += 1;
            },
        }
    }

    if (rag_context) |ctx| {
        const prefix = "\\n\\n[Memory Context]\\n";
        @memcpy(msg_part[msg_off .. msg_off + prefix.len], prefix);
        msg_off += prefix.len;

        for (ctx) |ch| {
            if (msg_off >= 5500) break;
            switch (ch) {
                '"' => {
                    if (msg_off + 2 > msg_part.len) break;
                    msg_part[msg_off] = '\\';
                    msg_off += 1;
                    msg_part[msg_off] = '"';
                    msg_off += 1;
                },
                '\n' => {
                    if (msg_off + 2 > msg_part.len) break;
                    msg_part[msg_off] = '\\';
                    msg_off += 1;
                    msg_part[msg_off] = 'n';
                    msg_off += 1;
                },
                '\r' => {},
                '\\' => {
                    if (msg_off + 2 > msg_part.len) break;
                    msg_part[msg_off] = '\\';
                    msg_off += 1;
                    msg_part[msg_off] = '\\';
                    msg_off += 1;
                },
                else => |c| {
                    if (c >= 32) {
                        msg_part[msg_off] = c;
                        msg_off += 1;
                    }
                },
            }
        }
    }

    // Cross-session conversation history (persistent across restarts).
    // Skipped in incognito — past sessions must not leak into the prompt.
    if (!@import("../core/state.zig").app.incognito_mode) {
        const convo_ctx = memory.getRecentConversations(@import("../core/alloc.zig").allocator);
        defer if (convo_ctx) |cc| @import("../core/alloc.zig").allocator.free(cc);

        if (convo_ctx) |cc| {
            const prefix2 = "\\n\\n[Past Sessions]\\n";
            if (msg_off + prefix2.len < msg_part.len) {
                @memcpy(msg_part[msg_off .. msg_off + prefix2.len], prefix2);
                msg_off += prefix2.len;
                for (cc) |ch| {
                    if (msg_off >= 5800) break;
                    switch (ch) {
                        '"' => {
                            if (msg_off + 2 > msg_part.len) break;
                            msg_part[msg_off] = '\\';
                            msg_off += 1;
                            msg_part[msg_off] = '"';
                            msg_off += 1;
                        },
                        '\n' => {
                            if (msg_off + 2 > msg_part.len) break;
                            msg_part[msg_off] = '\\';
                            msg_off += 1;
                            msg_part[msg_off] = 'n';
                            msg_off += 1;
                        },
                        '\r' => {},
                        '\\' => {
                            if (msg_off + 2 > msg_part.len) break;
                            msg_part[msg_off] = '\\';
                            msg_off += 1;
                            msg_part[msg_off] = '\\';
                            msg_off += 1;
                        },
                        else => |c| {
                            if (c >= 32) {
                                msg_part[msg_off] = c;
                                msg_off += 1;
                            }
                        },
                    }
                }
            }
        }
    }

    // Learned preferences — also skipped in incognito.
    if (!@import("../core/state.zig").app.incognito_mode) {
        const pref_ctx = memory.getTopPreferences(@import("../core/alloc.zig").allocator);
        defer if (pref_ctx) |pc| @import("../core/alloc.zig").allocator.free(pc);

        if (pref_ctx) |pc| {
            const prefix3 = "\\n[Preferences]\\n";
            if (msg_off + prefix3.len < msg_part.len) {
                @memcpy(msg_part[msg_off .. msg_off + prefix3.len], prefix3);
                msg_off += prefix3.len;
                for (pc) |ch| {
                    if (msg_off >= 5900) break;
                    switch (ch) {
                        '"' => {
                            msg_part[msg_off] = '\\';
                            msg_off += 1;
                            msg_part[msg_off] = '"';
                            msg_off += 1;
                        },
                        '\n' => {
                            msg_part[msg_off] = '\\';
                            msg_off += 1;
                            msg_part[msg_off] = 'n';
                            msg_off += 1;
                        },
                        '\r' => {},
                        '\\' => {
                            msg_part[msg_off] = '\\';
                            msg_off += 1;
                            msg_part[msg_off] = '\\';
                            msg_off += 1;
                        },
                        else => |c| {
                            if (c >= 32) {
                                msg_part[msg_off] = c;
                                msg_off += 1;
                            }
                        },
                    }
                }
            }
        }
    }

    // -- Active State Injection Phase 2 --
    const active_prefix = "\\n\\n[Environment Context]\\n";
    @memcpy(msg_part[msg_off .. msg_off + active_prefix.len], active_prefix);
    msg_off += active_prefix.len;

    var state_buf: [1024]u8 = undefined;
    var state_fbs = std.Io.Writer.fixed(&state_buf);
    const w = &state_fbs;

    // 1. Playback state (enriched for context-aware responses)
    // Fresh bounds check (not the stale `has_player` from above): this runs on
    // the generation worker thread and the UI thread can shrink players in
    // between — indexing on a stale length is an OOB/UAF. CLAUDE.md mandate.
    if (state.app.active_player_idx < state.app.players.items.len) {
        const p = state.app.players.items[state.app.active_player_idx];
        if (p.loading_label_len > 0 and p.loading_label_len <= 128) {
            w.print("Playing: {s}", .{p.loading_label[0..p.loading_label_len]}) catch {};
            // Add pause/volume/speed state
            const paused_str = if (p.is_buffering_paused) " [PAUSED]" else "";
            w.print("{s} vol={d:.0}% speed={d:.1}x\\n", .{ paused_str, p.cell_volume, p.cell_speed }) catch {};
        }
    } else {
        w.print("No media playing.\\n", .{}) catch {};
    }

    // 2. Search Context
    if (chat.last_show_len > 0 and chat.last_show_len <= 128) {
        w.print("Last search context: {s}", .{chat.last_show[0..chat.last_show_len]}) catch {};
        if (chat.last_season > 0) w.print(" (Season {d} Ep {d})", .{ chat.last_season, chat.last_episode }) catch {};
        w.print("\\n", .{}) catch {};
    }

    // 3. Current Search Results on Screen
    if (chat.chat_results_active and chat.chat_result_count > 0) {
        w.print("Current search results on screen:\\n", .{}) catch {};
        for (0..@min(chat.chat_result_count, 5)) |i| {
            const item = &chat.chat_results[i];
            const nlen = @min(item.name_len, 256);
            if (nlen == 0) continue;
            const name = item.name[0..nlen];
            w.print("{d}. {s} ({d} seeds)\\n", .{ i + 1, name, item.seeds }) catch {};
        }
    }

    const state_str = state_fbs.buffered();
    for (state_str) |ch| {
        if (msg_off >= 6000) break;
        switch (ch) {
            '"' => {
                msg_part[msg_off] = '\\';
                msg_off += 1;
                msg_part[msg_off] = '"';
                msg_off += 1;
            },
            '\n' => {
                msg_part[msg_off] = '\\';
                msg_off += 1;
                msg_part[msg_off] = 'n';
                msg_off += 1;
            },
            '\r' => {},
            '\\' => {
                msg_part[msg_off] = '\\';
                msg_off += 1;
                msg_part[msg_off] = '\\';
                msg_off += 1;
            },
            else => |c| {
                if (c >= 32) {
                    msg_part[msg_off] = c;
                    msg_off += 1;
                }
            },
        }
    }

    const sys_end = "\"}";
    @memcpy(msg_part[msg_off .. msg_off + sys_end.len], sys_end);
    msg_off += sys_end.len;

    // Last 8 messages (tight context for speed — RAG handles long-term memory)
    const history_end = chat.message_count - 1;
    const start = if (history_end > 8) history_end - 8 else 0;
    for (start..history_end) |mi| {
        const msg = &chat.messages[mi];
        // .system role = tool responses, sent as "user" to LLM but hidden from UI
        const role_str = if (msg.role == .assistant) "assistant" else "user";
        const text = msg.text[0..msg.text_len];

        // Skip corrupted assistant turns that are just "[tool_call]/[tool_response]"
        // stubs. Feeding them back to the model causes it to echo the pattern.
        // `.system` role messages are legitimate tool JSON and must still pass through.
        if (msg.role == .assistant and memory.isJunkTurn(text)) continue;

        var escaped: [2048]u8 = undefined;
        var elen: usize = 0;
        for (text) |ch| {
            if (elen >= 2040) break;
            switch (ch) {
                '"' => {
                    escaped[elen] = '\\';
                    elen += 1;
                    escaped[elen] = '"';
                    elen += 1;
                },
                '\\' => {
                    escaped[elen] = '\\';
                    elen += 1;
                    escaped[elen] = '\\';
                    elen += 1;
                },
                '\n' => {
                    escaped[elen] = '\\';
                    elen += 1;
                    escaped[elen] = 'n';
                    elen += 1;
                },
                '\r' => {},
                else => {
                    escaped[elen] = ch;
                    elen += 1;
                },
            }
        }

        if (std.fmt.bufPrint(msg_part[msg_off..], ",{{\"role\":\"{s}\",\"content\":\"{s}\"}}", .{ role_str, escaped[0..elen] })) |slice| {
            msg_off += slice.len;
        } else |_| break;
    }

    // Model name
    var active_model: []const u8 = switch (server.backend_kind) {
        .apfel => "apple-foundationmodel",
        .gemma_llama => "gemma-4-e2b",
    };
    if (server.cached_model_name_len > 0) {
        active_model = server.cached_model_name[0..server.cached_model_name_len];
    }

    const json_str = std.fmt.bufPrintZ(&json_buf, "{{\"model\":\"{s}\",\"messages\":[{s}],\"max_tokens\":256,\"temperature\":0.3,\"top_p\":0.9,\"stream\":true,\"response_format\":{{\"type\":\"json_object\"}}}}", .{ active_model, msg_part[0..msg_off] }) catch {
        chat.setAssistantError(assistant_idx, "Couldn't build the AI request.");
        return;
    };

    // Write to temp file
    if (@import("../core/io_global.zig").cwdCreateFile("/tmp/opal_ai_req.json", .{})) |f| {
        @import("../core/io_global.zig").writeAll(f, json_str) catch {};
        f.close(@import("../core/io_global.zig").io());
    } else |_| {}

    var srv_buf: [128]u8 = undefined;
    const srv_url = server.getServerUrl(&srv_buf);
    var url_buf: [192]u8 = undefined;
    const url = std.fmt.bufPrintZ(&url_buf, "{s}/v1/chat/completions", .{srv_url}) catch {
        chat.setAssistantError(assistant_idx, "Invalid AI server URL.");
        return;
    };

    // Wait for server to become healthy if it was just (re)started
    {
        var health_url_buf: [192]u8 = undefined;
        const health_url = std.fmt.bufPrintZ(&health_url_buf, "{s}/health", .{srv_url}) catch null;
        if (health_url) |hurl| {
            var attempts: usize = 0;
            while (attempts < 30) : (attempts += 1) { // up to 15 seconds
                var hc = @import("../core/io_global.zig").Child.init(
                    &.{ "curl", "-s", "--max-time", "2", hurl },
                    @import("../core/alloc.zig").allocator,
                );
                hc.stdout_behavior = .Pipe;
                hc.stderr_behavior = .Ignore;
                hc.spawn() catch break;
                const hstdout = hc.stdout.?;
                var hbuf: [256]u8 = undefined;
                const hn = @import("../core/io_global.zig").read(hstdout, &hbuf) catch 0;
                _ = hc.wait() catch {};
                if (hn > 0 and std.mem.indexOf(u8, hbuf[0..hn], "ok") != null) break;
                @import("../core/io_global.zig").sleep(500 * std.time.ns_per_ms);
            }
        }
    }

    server.model_status = .checking;

    var child = @import("../core/io_global.zig").Child.init(
        &.{ "curl", "-s", "-N", "--max-time", "60", "-X", "POST", "-H", "Content-Type: application/json", "--data-binary", "@/tmp/opal_ai_req.json", url },
        @import("../core/alloc.zig").allocator,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch {
        chat.setAssistantError(assistant_idx, "Can't reach the AI server. Start it (or set an API key) in Settings > AI.");
        return;
    };

    // Buffer to hold the incoming JSON response (for tool_call parsing)
    var resp_buf: [8192]u8 = undefined;
    var resp_len: usize = 0;

    // Sentence-streaming TTS buffer (speak each sentence as it completes)
    var tts_sentence_buf: [512]u8 = undefined;
    var tts_sentence_len: usize = 0;
    var tts_sentences_spoken: usize = 0;

    // State machine for live-streaming the "message" value to the UI
    // 0 = haven't found "message" key yet
    // 1 = found key, looking for opening quote of value
    // 2 = inside message value string (streaming to UI)
    // 3 = message value complete
    var msg_state: u8 = 0;

    // Stream SSE response line-by-line
    var line_buf: [4096]u8 = undefined;
    var line_pos: usize = 0;
    const stdout_file = child.stdout.?;

    while (true) {
        // Barge-in / Stop — abort the stream and kill curl so we don't block on
        // its --max-time and don't overwrite the chat with a superseded reply.
        if (chat.gen_abort.load(.acquire)) {
            _ = child.kill() catch {};
            break;
        }
        var byte: [1]u8 = undefined;
        const n = @import("../core/io_global.zig").read(stdout_file, &byte) catch break;
        if (n == 0) break; // EOF

        if (byte[0] == '\n') {
            const line = line_buf[0..line_pos];
            line_pos = 0;

            if (line.len == 0 or !std.mem.startsWith(u8, line, "data: ")) continue;
            const data = line[6..];
            if (std.mem.eql(u8, data, "[DONE]")) break;

            const token = extractContent(data) orelse continue;
            var ti: usize = 0;
            while (ti < token.len) {
                if (resp_len >= resp_buf.len) break;

                // Decode escape sequences
                var decoded_char: u8 = token[ti];
                var advance: usize = 1;
                if (token[ti] == '\\' and ti + 1 < token.len) {
                    switch (token[ti + 1]) {
                        'n' => {
                            decoded_char = '\n';
                            advance = 2;
                        },
                        't' => {
                            decoded_char = '\t';
                            advance = 2;
                        },
                        '"' => {
                            decoded_char = '"';
                            advance = 2;
                        },
                        '\\' => {
                            decoded_char = '\\';
                            advance = 2;
                        },
                        else => {},
                    }
                }

                // Always buffer the full response
                resp_buf[resp_len] = decoded_char;
                resp_len += 1;

                // State machine: track if we're inside the "message" value
                if (msg_state == 0) {
                    // Check if we've accumulated enough to see "message":
                    if (resp_len >= 10) {
                        // Look for "message" in what we've accumulated so far
                        if (std.mem.indexOf(u8, resp_buf[0..resp_len], "\"message\"")) |_| {
                            msg_state = 1; // found key, looking for value start
                        }
                    }
                } else if (msg_state == 1) {
                    // Looking for the opening quote of the value
                    if (decoded_char == '"') {
                        // Check this isn't the closing quote of "message" key
                        // We need to skip past the colon: "message": "
                        // The quote we want is after a colon+space
                        if (resp_len >= 2 and (resp_buf[resp_len - 2] == ':' or resp_buf[resp_len - 2] == ' ')) {
                            msg_state = 2; // now inside the message value
                        }
                    }
                } else if (msg_state == 2) {
                    // Inside the message value — stream to UI!
                    if (decoded_char == '"' and resp_len >= 2 and resp_buf[resp_len - 2] != '\\') {
                        // Closing quote — message value ends
                        msg_state = 3;
                    } else {
                        // Live-stream this character to the chat UI
                        if (chat.messages[assistant_idx].text_len < chat.MAX_MSG_LEN) {
                            chat.messages[assistant_idx].text[chat.messages[assistant_idx].text_len] = decoded_char;
                            chat.messages[assistant_idx].text_len += 1;
                        }

                        // Sentence-streaming TTS: buffer chars, speak on sentence boundary
                        if (voice.voice_mode and tts_sentence_len < tts_sentence_buf.len - 1) {
                            tts_sentence_buf[tts_sentence_len] = decoded_char;
                            tts_sentence_len += 1;

                            // Sentence boundary detected — speak this chunk immediately
                            if ((decoded_char == '.' or decoded_char == '!' or decoded_char == '?') and tts_sentence_len > 8) {
                                // Wait for previous TTS to finish before speaking next sentence
                                while (voice.is_speaking) {
                                    @import("../core/io_global.zig").sleep(30 * std.time.ns_per_ms);
                                }
                                voice.speakResponse(tts_sentence_buf[0..tts_sentence_len]);
                                tts_sentences_spoken += 1;
                                tts_sentence_len = 0;
                            }
                        }
                    }
                }

                ti += advance;
            }
            // Wake the UI once per streamed token chunk (not per char) so the chat
            // shows live text instead of only updating on incidental repaints — the
            // chat view has no timer/animation of its own. Thread-safe *Window form;
            // cheap at token cadence. Only while we're emitting the visible message.
            if (msg_state == 2 or msg_state == 3) {
                if (state.app.dvui_win) |win| @import("dvui").refresh(win, @src(), null);
            }
        } else {
            if (line_pos < line_buf.len) {
                line_buf[line_pos] = byte[0];
                line_pos += 1;
            }
        }
    }

    _ = child.wait() catch {};
    server.model_status = .online;

    // Incognito: the request body (system prompt + last-8 history) was staged
    // at /tmp/opal_ai_req.json for curl — don't leave a disk residue of a
    // conversation the user asked us not to remember.
    if (@import("../core/state.zig").app.incognito_mode) {
        @import("../core/io_global.zig").deleteFileAbsolute("/tmp/opal_ai_req.json") catch {};
    }

    // Aborted by barge-in / Stop — leave whatever partial text was streamed and
    // bail without surfacing a "no response" error or parsing tool calls on a
    // truncated reply. The defer clears is_generating; the next turn replaces it.
    if (chat.gen_abort.load(.acquire)) return;

    if (resp_len == 0) {
        chat.setAssistantError(assistant_idx, "The AI server returned no response. Is it running?");
        return;
    }

    const response_text = resp_buf[0..resp_len];

    // If the state machine didn't find a proper "message" value (e.g. model didn't output JSON),
    // fall back to showing the raw response
    if (chat.messages[assistant_idx].text_len == 0) {
        // If the raw response is actually an API error envelope, surface its
        // message via setError rather than dumping raw JSON into the chat.
        if (extractError(response_text)) |emsg| {
            chat.setAssistantError(assistant_idx, emsg);
            return;
        }
        // Fallback: show whatever raw text was received
        const fallback_len = @min(resp_len, chat.MAX_MSG_LEN);
        @memcpy(chat.messages[assistant_idx].text[0..fallback_len], response_text[0..fallback_len]);
        chat.messages[assistant_idx].text_len = fallback_len;
    }

    // 2. Check for tool call (with recursion limit to prevent infinite loops)
    if (tools.containsToolCall(response_text)) {
        if (tool_depth >= 3) {
            // Too many tool calls in a row — break the loop
            logs.pushLog("warn", "ai-tool", "Tool depth limit reached", true);
            const err_msg = "I performed the action. Let me know if you need anything else.";
            chat.messages[assistant_idx].text_len = err_msg.len;
            @memcpy(chat.messages[assistant_idx].text[0..err_msg.len], err_msg);
        } else if (tools.parseToolCall(response_text)) |tc| {
            const tool_name = tc.name[0..tc.name_len];
            logs.pushLog("info", "ai-tool", tool_name, false);

            // Execute the tool
            if (tools.executeTool(@import("../core/alloc.zig").allocator, &tc)) |result| {
                // executeTool returns an exact-sized allocation; free after copying.
                defer @import("../core/alloc.zig").allocator.free(result);
                var tool_result_buf: [2048]u8 = undefined;
                const rlen = @min(result.len, tool_result_buf.len);
                @memcpy(tool_result_buf[0..rlen], result[0..rlen]);

                // Replace the assistant tool-call message with a system message (hidden from UI)
                var tool_msg_buf: [chat.MAX_MSG_LEN]u8 = undefined;
                const tool_msg_len = tools.formatToolResponse(&tool_msg_buf, tool_name, tool_result_buf[0..rlen]);

                chat.messages[assistant_idx].role = .system;
                chat.messages[assistant_idx].text_len = @min(tool_msg_len, chat.MAX_MSG_LEN);
                @memcpy(chat.messages[assistant_idx].text[0..chat.messages[assistant_idx].text_len], tool_msg_buf[0..chat.messages[assistant_idx].text_len]);

                if (chat.message_count < chat.MAX_MESSAGES) {
                    chat.messages[chat.message_count] = .{ .role = .assistant, .text_len = 0 };
                    chat.message_count += 1;
                    tool_depth += 1;
                    chat.phase = .tool_calling;
                    generateResponse();
                    return;
                }
            }
        }
    }

    // Normal response (no tool call) — save to memory (unless incognito)
    if (!chat.incognito_mode) {
        if (assistant_idx > 0) {
            const ingested_msg = chat.messages[assistant_idx - 1];
            const usr_msg = ingested_msg.text[0..ingested_msg.text_len];
            memory.ingestMemory("user", usr_msg, "chat", "");
            memory.saveConversation("user", usr_msg);
        }
        const asst_text = chat.messages[assistant_idx].text[0..chat.messages[assistant_idx].text_len];
        memory.ingestMemory("assistant", asst_text, "chat", "");
        memory.saveConversation("assistant", asst_text);
    }

    if (voice.voice_mode) {
        // If we already streamed sentences during generation, only speak the trailing remainder
        if (tts_sentences_spoken > 0) {
            if (tts_sentence_len > 3) {
                // Wait for last sentence to finish
                while (voice.is_speaking) {
                    @import("../core/io_global.zig").sleep(30 * std.time.ns_per_ms);
                }
                voice.speakResponse(tts_sentence_buf[0..tts_sentence_len]);
            }
        } else {
            // No streaming happened (short response or tool call) — speak full response
            voice.speakResponse(chat.messages[assistant_idx].text[0..chat.messages[assistant_idx].text_len]);
        }
    }
}

fn extractContent(json: []const u8) ?[]const u8 {
    const needle = "\"content\":\"";
    const pos = std.mem.indexOf(u8, json, needle) orelse return null;
    const s = pos + needle.len;
    if (s >= json.len) return null;
    var e = s;
    while (e < json.len) {
        if (json[e] == '"' and (e == s or json[e - 1] != '\\')) break;
        e += 1;
    }
    if (e <= s) return null;
    return json[s..e];
}

fn extractError(json: []const u8) ?[]const u8 {
    const needle = "\"error\":";
    const pos = std.mem.indexOf(u8, json, needle) orelse return null;
    const mn = "\"message\":\"";
    const mp = std.mem.indexOf(u8, json[pos..], mn) orelse return null;
    const s = pos + mp + mn.len;
    if (s >= json.len) return null;
    var e = s;
    while (e < json.len and json[e] != '"') : (e += 1) {}
    return json[s..e];
}
