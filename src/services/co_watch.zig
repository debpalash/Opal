//! Proactive Co-Watcher.
//!
//! When the user pauses or rewinds during VOICE-MODE playback, the AI may
//! speak ONE short, spoiler-safe remark about what is currently on screen.
//! Restraint is the whole point: this is QUIET by default, rate-limited by
//! cooldowns, single-flight, and only active in voice mode. Any remark is
//! instantly killable by barge-in (handled inside ai_voice.speakResponse).
//!
//! Reuses the shipped look_at_screen plumbing:
//!   - frame_ocr.ocrCurrentFrame
//!   - MediaPlayer.getRecentDialogue / cached_sub_text
//!   - the proven local-LLM completion path (curl -> /v1/chat/completions)
//!   - ai_voice.speakResponse (honors barge_in / is_speaking guards)
//!
//! This module owns NO UI and never touches player.zig or settings.zig.

const std = @import("std");
const state = @import("../core/state.zig");
const alloc = @import("../core/alloc.zig").allocator;
const io = @import("../core/io_global.zig");
const logs = @import("../core/logs.zig");

// ── LOCKED PUBLIC API ──────────────────────────────────────────────────────

pub const Sensitivity = enum { off, quiet, balanced, chatty };
pub var sensitivity: Sensitivity = .quiet;

pub const EventKind = enum { paused, rewound };

/// Called from the playback-event path (T3). Cheap + non-blocking: it does all
/// gating on the calling thread and, only if a remark is warranted, spawns a
/// detached worker to do the OCR + LLM + TTS work.
pub fn onPlaybackEvent(kind: EventKind) void {
    // Hard off switch.
    if (sensitivity == .off) return;

    // Voice-mode only.
    if (!@import("ai_voice.zig").voice_mode) return;

    // Need a live player.
    if (!(state.app.active_player_idx < state.app.players.items.len)) return;

    // Don't talk over ourselves, the user, or an in-flight generation.
    if (@import("ai_voice.zig").is_speaking.load(.acquire)) return;
    if (@import("ai_chat.zig").is_generating.load(.acquire)) return;

    // Single-flight: if a worker is already running, drop the event.
    if (S.busy.load(.acquire)) return;

    // Cooldown.
    const now = io.milliTimestamp();
    var cd_ms: i64 = switch (sensitivity) {
        .off => return, // unreachable (guarded above) but keep exhaustive.
        .quiet => 90_000,
        .balanced => 45_000,
        .chatty => 20_000,
    };
    // A rewind is a stronger "I might be confused" signal -> react sooner.
    if (kind == .rewound) cd_ms = @divTrunc(cd_ms, 2);

    if (S.last_spoke_ms != 0 and (now - S.last_spoke_ms) < cd_ms) return;

    // Claim the single-flight slot. If someone beat us to it, bail.
    if (S.busy.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;

    // Copy the trigger into a module static for the detached worker.
    S.trigger_kind = kind;

    const t = std.Thread.spawn(.{}, S.worker, .{}) catch {
        // Couldn't spawn — release the slot so future events can try.
        S.busy.store(false, .release);
        return;
    };
    t.detach();
}

// ── Internals ──────────────────────────────────────────────────────────────

const S = struct {
    var busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    var last_spoke_ms: i64 = 0;
    var trigger_kind: EventKind = .paused;

    fn worker() void {
        // ALWAYS release the single-flight slot, no matter how we exit.
        defer @This().busy.store(false, .release);

        const c = @import("../core/c.zig");
        const voice = @import("ai_voice.zig");
        const chat = @import("ai_chat.zig");

        // Re-guard the active player on the worker thread (state may have
        // changed between the event and now).
        if (!(state.app.active_player_idx < state.app.players.items.len)) return;
        const p = state.app.players.items[state.app.active_player_idx];

        const kind = @This().trigger_kind;

        // (a) OCR the current frame.
        var ocr_buf: [4096]u8 = undefined;
        const on = @import("frame_ocr.zig").ocrCurrentFrame(&ocr_buf);
        const ocr_text = ocr_buf[0..on];

        // (b) Current subtitle.
        const sub_text = if (p.cached_sub_text_len <= p.cached_sub_text.len)
            p.cached_sub_text[0..p.cached_sub_text_len]
        else
            p.cached_sub_text[0..0];

        // (c) Recent dialogue.
        var dlg_buf: [4096]u8 = undefined;
        const dn = p.getRecentDialogue(&dlg_buf);
        const dlg_text = dlg_buf[0..dn];

        // Nothing to work with — stay silent.
        if (on == 0 and sub_text.len == 0 and dn == 0) return;

        // (d) Progress percent (spoiler boundary).
        var pos: f64 = 0;
        var dur: f64 = 0;
        _ = c.mpv.mpv_get_property(p.mpv_ctx, "time-pos", c.mpv.MPV_FORMAT_DOUBLE, &pos);
        _ = c.mpv.mpv_get_property(p.mpv_ctx, "duration", c.mpv.MPV_FORMAT_DOUBLE, &dur);
        const percent: f64 = if (dur > 0) (pos / dur) * 100.0 else 0;

        // ── Total Recall: persist this moment as a SCENE memory (T1) ─────────
        // Independent of the salience/firewall/curl remark path below. We join
        // the subtitle + recent-dialogue + OCR text into one stack buffer and
        // hand it to scene_memory, which dedups, junk-filters, embeds, and
        // persists. Degrades silently; never blocks the remark path.
        {
            // Title MUST match what recall_scene queries with (ai_tools uses
            // loading_label) so the per-title spoiler clamp lines up — prefer
            // loading_label, fall back to mpv media-title only if it's empty.
            var title_buf: [256]u8 = undefined;
            const title = if (p.loading_label_len > 0 and p.loading_label_len <= 128)
                p.loading_label[0..p.loading_label_len]
            else
                title_buf[0..p.getMediaTitle(&title_buf)];

            var scene_buf: [9216]u8 = undefined;
            var sfbs = std.Io.Writer.fixed(&scene_buf);
            if (sub_text.len > 0) sfbs.print("{s}\n", .{sub_text}) catch {};
            if (dn > 0) sfbs.print("{s}\n", .{dlg_text}) catch {};
            if (on > 0) sfbs.print("{s}", .{ocr_text}) catch {};
            const joined = sfbs.buffered();

            @import("scene_memory.zig").ingestScene(title, pos, dur, joined);
        }

        const reason: []const u8 = switch (kind) {
            .paused => "The viewer just PAUSED — they may have noticed or be reacting to something on screen.",
            .rewound => "The viewer just REWOUND more than 5 seconds — they may have missed or be confused by something.",
        };

        // ── Build the prompt bodies (heap-buffered; freed on exit) ──────────
        // Large buffers must not live on a thread stack.
        const sys_buf = alloc.alloc(u8, 2048) catch return;
        defer alloc.free(sys_buf);
        const user_buf = alloc.alloc(u8, 8192) catch return;
        defer alloc.free(user_buf);

        // Strict, consistent spoiler-clamp instruction (enforced firewall, S1).
        var clamp_buf: [256]u8 = undefined;
        const pct_u8: u8 = if (percent <= 0) 0 else if (percent >= 100) 100 else @intFromFloat(percent);
        const clamp_text = @import("spoiler.zig").clampLine(pct_u8, &clamp_buf);

        const sys_text = std.fmt.bufPrint(sys_buf,
            "You are a quiet co-watching companion. {s} " ++
            "Reply with ONE short, spoiler-safe sentence of at most 14 words. " ++
            "If there is no genuinely worthwhile remark to make, reply with exactly SILENT.",
            .{clamp_text},
        ) catch return;

        const user_text = std.fmt.bufPrint(user_buf,
            "{s}\n\nOn-screen text (OCR): {s}\nRecent dialogue:\n{s}\n\n" ++
            "Make at most one brief, spoiler-safe observation, or reply SILENT.",
            .{
                reason,
                if (on > 0) ocr_text else "(none)",
                if (dn > 0) dlg_text else "(none)",
            },
        ) catch return;

        // ── JSON-escape both into the request body ──────────────────────────
        var esc_sys: [4096]u8 = undefined;
        var esc_user: [8192]u8 = undefined;
        const sys_esc = escapeJson(sys_text, &esc_sys);
        const user_esc = escapeJson(user_text, &esc_user);

        // Model name (mirror ai_context's selection).
        const server = @import("ai_server.zig");
        var model: []const u8 = "gemma-4-e2b";
        if (server.cached_model_name_len > 0 and server.cached_model_name_len <= server.cached_model_name.len) {
            model = server.cached_model_name[0..server.cached_model_name_len];
        }

        const body_buf = alloc.alloc(u8, 16384) catch return;
        defer alloc.free(body_buf);
        const body = std.fmt.bufPrint(body_buf,
            "{{\"model\":\"{s}\",\"messages\":[" ++
            "{{\"role\":\"system\",\"content\":\"{s}\"}}," ++
            "{{\"role\":\"user\",\"content\":\"{s}\"}}]," ++
            "\"max_tokens\":40,\"temperature\":0.3,\"top_p\":0.9,\"stream\":false}}",
            .{ model, sys_esc, user_esc },
        ) catch return;

        // Write to a SEPARATE temp file (must not collide with ai_req.json).
        const req_path = "/tmp/opal_cowatch_req.json";
        if (io.cwdCreateFile(req_path, .{})) |f| {
            io.writeAll(f, body) catch {};
            f.close(io.io());
        } else |_| return;

        // ── Build URL ───────────────────────────────────────────────────────
        var srv_buf: [128]u8 = undefined;
        const srv_url = server.getServerUrl(&srv_buf);
        var url_buf: [192]u8 = undefined;
        const url = std.fmt.bufPrintZ(&url_buf, "{s}/v1/chat/completions", .{srv_url}) catch return;

        // ── ONE completion via curl ──────────────────────────────────────────
        var child = io.Child.init(
            &.{ "curl", "-s", "--max-time", "6", "-X", "POST", "-H", "Content-Type: application/json", "--data-binary", "@" ++ req_path, url },
            alloc,
        );
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.spawn() catch return;

        // Drain stdout into a heap buffer.
        const resp = alloc.alloc(u8, 4096) catch {
            _ = child.wait() catch {};
            return;
        };
        defer alloc.free(resp);
        var rlen: usize = 0;
        if (child.stdout) |sout| {
            while (rlen < resp.len) {
                const n = io.read(sout, resp[rlen..]) catch break;
                if (n == 0) break;
                rlen += n;
            }
        }
        _ = child.wait() catch {};

        const raw = extractContent(resp[0..rlen]) orelse return;

        // ── Parse + gate ─────────────────────────────────────────────────────
        // Unescape minimal JSON sequences, then trim.
        var rem_buf: [256]u8 = undefined;
        const unesc = unescapeJson(raw, &rem_buf);
        const remark = std.mem.trim(u8, unesc, " \t\r\n\"");

        if (remark.len == 0) return;
        if (remark.len > 120) return;
        if (std.ascii.eqlIgnoreCase(remark, "SILENT")) return;
        // Some models wrap it: "SILENT." etc. — treat a leading SILENT token as silence.
        if (remark.len >= 6 and std.ascii.eqlIgnoreCase(remark[0..6], "SILENT")) return;

        // Enforced spoiler firewall (S1): suppress any remark whose wording
        // strongly signals a beyond-now leak, even if the model ignored the
        // prompt-level clamp. Conservative — only strong, unambiguous signals.
        if (@import("spoiler.zig").flagsSpoiler(remark)) {
            logs.pushLog("info", "co-watch", "remark suppressed as possible spoiler", false);
            return;
        }

        // Re-check the talk guards right before speaking (state may have moved).
        if (voice.is_speaking.load(.acquire)) return;
        if (chat.is_generating.load(.acquire)) return;
        if (voice.barge_in.load(.acquire)) return;

        @This().last_spoke_ms = io.milliTimestamp();
        logs.pushLog("info", "co-watch", remark, false);
        voice.speakResponse(remark);
    }
};

/// Minimal JSON string escaping for embedding into the request body.
fn escapeJson(input: []const u8, buf: []u8) []const u8 {
    var out: usize = 0;
    for (input) |ch| {
        if (out + 2 > buf.len) break;
        switch (ch) {
            '\\' => {
                buf[out] = '\\';
                buf[out + 1] = '\\';
                out += 2;
            },
            '"' => {
                buf[out] = '\\';
                buf[out + 1] = '"';
                out += 2;
            },
            '\n' => {
                buf[out] = '\\';
                buf[out + 1] = 'n';
                out += 2;
            },
            '\r' => {
                buf[out] = '\\';
                buf[out + 1] = 'r';
                out += 2;
            },
            '\t' => {
                buf[out] = '\\';
                buf[out + 1] = 't';
                out += 2;
            },
            0...8, 11, 12, 14...31 => {
                // Drop other control chars rather than emit invalid JSON.
            },
            else => {
                buf[out] = ch;
                out += 1;
            },
        }
    }
    return buf[0..out];
}

/// Inverse of the minimal escaping above, for the model's reply content.
fn unescapeJson(input: []const u8, buf: []u8) []const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < input.len and out < buf.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const n = input[i + 1];
            const repl: u8 = switch (n) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                else => {
                    // Unknown escape — copy the backslash through.
                    buf[out] = input[i];
                    out += 1;
                    i += 1;
                    continue;
                },
            };
            buf[out] = repl;
            out += 1;
            i += 2;
        } else {
            buf[out] = input[i];
            out += 1;
            i += 1;
        }
    }
    return buf[0..out];
}

/// Pull the first assistant `"content":"..."` value out of a completions
/// response, respecting backslash-escaped quotes. (Mirrors ai_context.)
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
