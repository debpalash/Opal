const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const logs = @import("../core/logs.zig");
const server = @import("ai_server.zig");
const memory = @import("ai_memory.zig");
const voice = @import("ai_voice.zig");
const tools = @import("ai_tools.zig");
const resolver = @import("resolver.zig");
pub const ai_context = @import("ai_context.zig");

// ══════════════════════════════════════════════════════════
// AI Chat — UI + Orchestration (modular)
// ══════════════════════════════════════════════════════════

pub const MAX_MESSAGES = 50;
pub const MAX_MSG_LEN = 2048;
pub const MAX_INPUT_LEN = 512;

pub const Role = enum { user, assistant, system };

pub const Message = struct {
    role: Role = .user,
    text: [MAX_MSG_LEN]u8 = std.mem.zeroes([MAX_MSG_LEN]u8),
    text_len: usize = 0,
    /// Starred / pinned by user. Survives clearHistory (see toggleStar).
    starred: bool = false,
};

pub fn toggleStar(idx: usize) void {
    if (idx >= message_count) return;
    messages[idx].starred = !messages[idx].starred;
    if (messages[idx].starred) {
        saveStarredToDb(messages[idx]);
    } else {
        removeStarredFromDb(messages[idx]);
    }
}

// ── SQLite persistence for starred messages ──

const db = @import("../core/db.zig");

fn roleToInt(r: Role) c_int {
    return switch (r) { .user => 0, .assistant => 1, .system => 2 };
}

fn intToRole(n: c_int) Role {
    return switch (n) { 0 => .user, 1 => .assistant, else => .system };
}

fn saveStarredToDb(m: Message) void {
    const stmt = db.prepare("INSERT INTO ai_chat_starred (role, text) VALUES (?, ?)") orelse return;
    defer db.finalize(stmt);
    db.bindInt(stmt, 1, roleToInt(m.role));
    db.bindText(stmt, 2, m.text[0..m.text_len]);
    _ = db.step(stmt);
}

fn removeStarredFromDb(m: Message) void {
    const stmt = db.prepare("DELETE FROM ai_chat_starred WHERE role = ? AND text = ?") orelse return;
    defer db.finalize(stmt);
    db.bindInt(stmt, 1, roleToInt(m.role));
    db.bindText(stmt, 2, m.text[0..m.text_len]);
    _ = db.step(stmt);
}

/// Load starred messages from SQLite into the message array at startup.
/// Called once from main.appInit after db.init().
pub fn loadStarredFromDb() void {
    const stmt = db.prepare("SELECT role, text FROM ai_chat_starred ORDER BY created_at ASC") orelse return;
    defer db.finalize(stmt);
    while (db.step(stmt) == 100) { // SQLITE_ROW = 100
        if (message_count >= MAX_MESSAGES) break;
        const role_int = db.columnInt(stmt, 0);
        const text = db.columnText(stmt, 1) orelse continue;
        if (text.len == 0) continue;
        const m = &messages[message_count];
        m.role = intToRole(role_int);
        const n = @min(text.len, MAX_MSG_LEN);
        @memset(&m.text, 0);
        @memcpy(m.text[0..n], text[0..n]);
        m.text_len = n;
        m.starred = true;
        message_count += 1;
    }
}

// ── Chat state ──
pub var messages: [MAX_MESSAGES]Message = std.mem.zeroes([MAX_MESSAGES]Message);
pub var message_count: usize = 0;
pub var input_buf: [MAX_INPUT_LEN]u8 = std.mem.zeroes([MAX_INPUT_LEN]u8);
pub var input_len: usize = 0;
pub var is_generating: bool = false;

/// Fine-grained phase reporting so the UI can show what the AI is
/// actually doing, not just "Thinking…". Set at transitions in
/// ai_context.generateResponse + fastPathResolve. Voicebox pattern.
pub const Phase = enum { idle, searching, waiting_server, thinking, tool_calling, streaming };
pub var phase: Phase = .idle;

pub fn phaseLabel(p: Phase) []const u8 {
    return switch (p) {
        .idle => "",
        .searching => "Searching…",
        .waiting_server => "Starting AI…",
        .thinking => "Thinking…",
        .tool_calling => "Running tool…",
        .streaming => "Writing…",
    };
}
pub var llm_thread: ?std.Thread = null;

// ── Error state ──
pub var last_error: [256]u8 = std.mem.zeroes([256]u8);
pub var last_error_len: usize = 0;

// ── Config ──
var show_controls: bool = false;
var callbacks_initialized: bool = false;
pub var incognito_mode: bool = false;
pub var is_bubble_open: bool = false;

pub fn clearHistory() void {
    // Preserve starred messages by compacting them to the front before wipe.
    var kept: usize = 0;
    for (0..message_count) |i| {
        if (messages[i].starred and messages[i].text_len > 0) {
            if (kept != i) messages[kept] = messages[i];
            kept += 1;
        }
    }
    // Zero the tail
    for (kept..MAX_MESSAGES) |i| messages[i] = .{};
    message_count = kept;
    @memset(&input_buf, 0);
    input_len = 0;
    is_generating = false;
    last_error_len = 0;
    chat_result_count = 0;
    chat_results_active = false;
    awaiting_confirmation = false;
    recommended_idx = null;
    last_show_len = 0;
    last_season = 0;
    last_episode = 0;
}

// ── Inline search results (set by ai_tools.zig find_and_play) ──
pub var chat_results: [16]resolver.ResolvedItem = std.mem.zeroes([16]resolver.ResolvedItem);
pub var chat_result_count: usize = 0;
pub var chat_results_active: bool = false;
pub var recommended_idx: ?usize = null;
pub var awaiting_confirmation: bool = false;

// ── Last search context (for "next episode" etc.) ──
pub var last_show: [128]u8 = std.mem.zeroes([128]u8);
pub var last_show_len: usize = 0;
pub var last_season: u16 = 0;
pub var last_episode: u16 = 0;

pub const SYSTEM_PROMPT = tools.TOOL_SYSTEM_PROMPT ++ "\n" ++ tools.TOOL_DEFINITIONS;

fn initCallbacks() void {
    if (callbacks_initialized) return;
    callbacks_initialized = true;
    voice.setCallbacks(&onTranscribed, &setError);
    server.setErrorCallback(&setError);
}

/// Re-export for player.zig media hooks
pub const ingestMemory = memory.ingestMemory;

/// Emergency stop — kill TTS, abort LLM, stop recording
pub fn stopAll() void {
    // Stop voice pipeline
    voice.is_speaking = false;
    voice.is_recording = false;
    voice.is_transcribing = false;
    is_generating = false;
    voice.setPhase(.idle);

    // Pause v2 voice server
    if (voice.voice_socket) |s| {
        @import("../core/io_global.zig").streamWriteAll(s, "PAUSE\n") catch {};
    }

    // Kill aplay + recording in background thread to avoid blocking render
    _ = std.Thread.spawn(.{}, struct {
        fn run() void {
            var kill_aplay = @import("../core/io_global.zig").Child.init(
                &.{ "pkill", "-f", if (@import("builtin").os.tag == .macos) "say" else "aplay.*zigzag" },
                @import("../core/alloc.zig").allocator,
            );
            kill_aplay.stdout_behavior = .Ignore;
            kill_aplay.stderr_behavior = .Ignore;
            _ = kill_aplay.spawnAndWait() catch {};

            var kill_rec = @import("../core/io_global.zig").Child.init(
                &.{ "pkill", "-f", "rec.*zigzag_ai_mic" },
                @import("../core/alloc.zig").allocator,
            );
            kill_rec.stdout_behavior = .Ignore;
            kill_rec.stderr_behavior = .Ignore;
            _ = kill_rec.spawnAndWait() catch {};
        }
    }.run, .{}) catch {};
}

// ══════════════════════════════════════════════════════════
//  Main UI
// ══════════════════════════════════════════════════════════

pub fn renderChatBody() void {
    server.checkPaths();
    initCallbacks();
    { // Kill zombie servers from previous runs — once at startup only
        const K = struct { var done: bool = false; };
        if (!K.done) {
            K.done = true;
            voice.killStaleServers();
            voice.preWarmServers();  // Start STT/TTS servers in background early
        }
    }

    // Proactive startup greeting (once per session, fires on first frame with empty chat)
    {
        const S = struct { var shown: bool = false; };
        if (!S.shown and message_count == 0) {
            S.shown = true;
            if (memory.getProactiveSuggestion()) |suggestion| {
                // Inject as assistant greeting
                var msg = &messages[0];
                msg.role = .assistant;
                const slen = @min(suggestion.len, MAX_MSG_LEN);
                @memcpy(msg.text[0..slen], suggestion[0..slen]);
                msg.text_len = slen;
                message_count = 1;
            }
        }
    }

    // Auto-start conversation mode when server is ready
    if (server.model_status == .online and !voice.conversation_active) {
        voice.autoStartConversation();
    }

    // Notify voice server about media playing state (raises VAD threshold)
    const state_mod = @import("../core/state.zig");
    voice.notifyMediaState(state_mod.app.players.items.len > 0);

    // ── Compact header ──
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
            .background = true,
            .color_fill = dvui.Color{ .r = 14, .g = 14, .b = 20, .a = 255 },
            .color_border = dvui.Color{ .r = 30, .g = 30, .b = 45, .a = 180 },
            .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
            .gravity_y = 0.5,
        });
        defer hdr.deinit();

        _ = dvui.icon(@src(), "", icons.tvg.lucide.@"cpu", .{}, .{
            .color_text = theme.colors.accent,
            .min_size_content = .{ .w = 16, .h = 16 },
            .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
        });
        _ = dvui.label(@src(), switch (server.backend_kind) { .apfel => "Apple Intelligence", .gemma_llama => "Gemma 4 E2B" }, .{}, .{
            .color_text = theme.colors.text_main,
            .expand = .horizontal,
        });

        // Status indicator
        if (server.model_status == .online) {
            _ = dvui.label(@src(), "●", .{}, .{ .color_text = theme.colors.success });
        } else if (server.server_running) {
            _ = dvui.label(@src(), "◌", .{}, .{ .color_text = theme.colors.accent });
        } else {
            _ = dvui.label(@src(), "○", .{}, .{ .color_text = dvui.Color{ .r = 80, .g = 50, .b = 50, .a = 200 } });
        }

        // Settings gear
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"settings", .{}, .{}, .{
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = dvui.Color{ .r = 60, .g = 60, .b = 80, .a = 200 },
            .padding = .{ .x = 2, .y = 2, .w = 2, .h = 2 },
            .min_size_content = .{ .w = 14, .h = 14 },
            .margin = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
        })) {
            show_controls = !show_controls;
        }

        // Voice toggle
        if (dvui.button(@src(), if (voice.voice_mode) "VOICE ON" else "VOICE", .{}, .{
            .color_fill = if (voice.voice_mode) dvui.Color{ .r = 20, .g = 40, .b = 25, .a = 255 } else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = if (voice.voice_mode) dvui.Color{ .r = 100, .g = 220, .b = 130, .a = 255 } else dvui.Color{ .r = 60, .g = 60, .b = 80, .a = 200 },
            .corner_radius = dvui.Rect.all(4),
            .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
            .margin = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
        })) {
            voice.voice_mode = !voice.voice_mode;
        }

        // Incognito toggle
        if (dvui.button(@src(), if (incognito_mode) "🕶 INCOG" else "INCOG", .{}, .{
            .color_fill = if (incognito_mode) dvui.Color{ .r = 40, .g = 20, .b = 50, .a = 255 } else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = if (incognito_mode) dvui.Color{ .r = 180, .g = 130, .b = 220, .a = 255 } else dvui.Color{ .r = 60, .g = 60, .b = 80, .a = 200 },
            .corner_radius = dvui.Rect.all(4),
            .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
            .margin = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
        })) {
            incognito_mode = !incognito_mode;
        }

        // Clear chat
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"trash-2", .{}, .{}, .{
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = dvui.Color{ .r = 60, .g = 60, .b = 80, .a = 200 },
            .padding = .{ .x = 2, .y = 2, .w = 2, .h = 2 },
            .min_size_content = .{ .w = 14, .h = 14 },
            .margin = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
        })) {
            clearHistory();
        }
    }

    // ── Control panel (collapsible) ──
    if (show_controls) {
        renderControlPanel();
    }

    // ── Health check ──
    if (server.server_running and server.model_status != .online) {
        const now = @import("../core/io_global.zig").timestamp();
        if (now - server.last_health_check > 3) {
            server.last_health_check = now;
            server.doHealthCheck();
        }
    }

    // ── Live Feedback / Progress Indicator ──
    // Moved out of the input horizontal row to its own dedicated space above input
    var show_status_bar = false;
    if (voice.conversation_active or is_generating or voice.is_speaking) {
        show_status_bar = true;
    }

    if (show_status_bar) {
        var status_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
            .background = true,
            .color_fill = dvui.Color{ .r = 20, .g = 20, .b = 30, .a = 255 },
            .border = .{ .x = 0, .y = 1, .w = 0, .h = 0 },
            .color_border = dvui.Color{ .r = 40, .g = 40, .b = 60, .a = 150 },
        });
        defer status_box.deinit();

        _ = dvui.icon(@src(), "", icons.tvg.lucide.@"activity", .{}, .{
            .color_text = theme.colors.accent,
            .min_size_content = .{ .w = 14, .h = 14 },
            .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
        });

        if (voice.conversation_active) {
            if (voice.conv_phase == .listening) {
                if (voice.partial_text_len > 0) {
                    _ = dvui.label(@src(), "Listening: {s}", .{voice.partial_text[0..voice.partial_text_len]}, .{
                        .color_text = dvui.Color{ .r = 200, .g = 255, .b = 200, .a = 255 },
                        .expand = .horizontal,
                    });
                } else {
                    _ = dvui.label(@src(), "Listening...", .{}, .{
                        .color_text = dvui.Color{ .r = 60, .g = 220, .b = 140, .a = 255 },
                    });
                }
            } else if (voice.conv_phase == .transcribing) {
                _ = dvui.label(@src(), "Transcribing...", .{}, .{
                    .color_text = dvui.Color{ .r = 255, .g = 200, .b = 60, .a = 255 },
                });
            } else if (voice.conv_phase == .thinking) {
                _ = dvui.label(@src(), "Thinking...", .{}, .{
                    .color_text = dvui.Color{ .r = 100, .g = 160, .b = 255, .a = 255 },
                });
            } else if (voice.conv_phase == .speaking) {
                _ = dvui.label(@src(), "Speaking...", .{}, .{
                    .color_text = dvui.Color{ .r = 200, .g = 120, .b = 255, .a = 255 },
                });
            } else {
                _ = dvui.label(@src(), "Voice Active (Ready)", .{}, .{
                    .color_text = dvui.Color{ .r = 120, .g = 120, .b = 140, .a = 255 },
                });
            }
        } else if (is_generating) {
            _ = dvui.label(@src(), "Thinking...", .{}, .{
                .color_text = dvui.Color{ .r = 100, .g = 160, .b = 255, .a = 255 },
            });
        } else if (voice.is_speaking) {
            _ = dvui.label(@src(), "Speaking...", .{}, .{
                .color_text = dvui.Color{ .r = 200, .g = 120, .b = 255, .a = 255 },
            });
        }
    }

    // ── Input bar (sticky at top) ──
    {
        var input_bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = 9005,
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
            .background = true,
            .color_fill = dvui.Color{ .r = 18, .g = 18, .b = 26, .a = 255 },
            .color_border = dvui.Color{ .r = 55, .g = 55, .b = 75, .a = 200 },
            .border = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        });
        defer input_bar.deinit();

        var te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &input_buf },
        }, .{
            .id_extra = 9006,
            .expand = .horizontal,
            .color_fill = dvui.Color{ .r = 26, .g = 26, .b = 36, .a = 255 },
            .color_text = dvui.Color{ .r = 220, .g = 225, .b = 240, .a = 255 },
            .color_border = dvui.Color{ .r = 70, .g = 70, .b = 95, .a = 200 },
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(10),
            .padding = .{ .x = 14, .y = 10, .w = 14, .h = 10 },
            .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
        });
        const enter_pressed = te.enter_pressed;
        input_len = std.mem.indexOfScalar(u8, &input_buf, 0) orelse MAX_INPUT_LEN;
        te.deinit();

        const can_send = input_len > 0 and !is_generating;

        // Send button
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"send", .{}, .{}, .{
            .color_fill = if (can_send) theme.colors.accent else dvui.Color{ .r = 30, .g = 30, .b = 42, .a = 255 },
            .color_text = if (can_send) dvui.Color.white else dvui.Color{ .r = 140, .g = 145, .b = 160, .a = 220 },
            .corner_radius = dvui.Rect.all(8),
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
            .margin = .{ .x = 0, .y = 0, .w = 2, .h = 0 },
            .color_border = dvui.Color{ .r = 60, .g = 60, .b = 80, .a = 150 },
            .border = dvui.Rect.all(1),
        })) {
            if (can_send) trySendMessage();
        }

        // Enter key
        if (enter_pressed and can_send) {
            trySendMessage();
        }

        // Mic button
        {
            const mic_color = if (voice.is_recording)
                dvui.Color{ .r = 220, .g = 40, .b = 40, .a = 255 }
            else if (voice.is_transcribing)
                dvui.Color{ .r = 40, .g = 180, .b = 80, .a = 255 }
            else
                dvui.Color{ .r = 30, .g = 30, .b = 42, .a = 255 };

            const mic_icon_color = if (voice.is_recording)
                dvui.Color.white
            else if (voice.is_transcribing)
                dvui.Color.white
            else
                dvui.Color{ .r = 160, .g = 165, .b = 185, .a = 255 };

            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"mic", .{}, .{}, .{
                .id_extra = 9007,
                .color_fill = mic_color,
                .color_text = mic_icon_color,
                .corner_radius = dvui.Rect.all(8),
                .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
                .margin = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
                .color_border = if (voice.is_recording) dvui.Color{ .r = 255, .g = 80, .b = 80, .a = 200 } else dvui.Color{ .r = 60, .g = 60, .b = 80, .a = 150 },
                .border = dvui.Rect.all(1),
            })) {
                voice.toggleMicRecording();
            }

            // Conversation mode toggle (live hands-free voice loop)
            const conv_color = if (voice.conversation_active)
                dvui.Color{ .r = 30, .g = 200, .b = 120, .a = 255 }
            else
                dvui.Color{ .r = 30, .g = 30, .b = 42, .a = 255 };

            const conv_icon_color = if (voice.conversation_active)
                dvui.Color.white
            else
                dvui.Color{ .r = 120, .g = 125, .b = 145, .a = 255 };

            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"headphones", .{}, .{}, .{
                .id_extra = 9008,
                .color_fill = conv_color,
                .color_text = conv_icon_color,
                .corner_radius = dvui.Rect.all(8),
                .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
                .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
                .color_border = if (voice.conversation_active) dvui.Color{ .r = 40, .g = 220, .b = 140, .a = 200 } else dvui.Color{ .r = 60, .g = 60, .b = 80, .a = 150 },
                .border = dvui.Rect.all(1),
            })) {
                voice.toggleConversation();
            }

            // Stop button
            const is_active = is_generating or voice.is_speaking or voice.is_recording or voice.is_transcribing;
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"square", .{}, .{}, .{
                .id_extra = 9009,
                .color_fill = if (is_active) dvui.Color{ .r = 180, .g = 30, .b = 30, .a = 255 } else dvui.Color{ .r = 30, .g = 30, .b = 42, .a = 255 },
                .color_text = if (is_active) dvui.Color.white else dvui.Color{ .r = 80, .g = 80, .b = 100, .a = 200 },
                .corner_radius = dvui.Rect.all(8),
                .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
                .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
                .color_border = if (is_active) dvui.Color{ .r = 220, .g = 60, .b = 60, .a = 200 } else dvui.Color{ .r = 60, .g = 60, .b = 80, .a = 150 },
                .border = dvui.Rect.all(1),
            })) {
                stopAll();
            }
        }
    }

    // ── Chat area ──
    {
        var scroll = dvui.scrollArea(@src(), .{}, .{
            .expand = .both,
            .color_fill = dvui.Color{ .r = 12, .g = 12, .b = 18, .a = 255 },
            .background = true,
        });
        defer scroll.deinit();

        var content_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
        });
        defer content_box.deinit();

        if (message_count == 0) {
            renderEmptyState();
        } else {
            // Error display (at top — most urgent)
            if (last_error_len > 0) {
                _ = dvui.label(@src(), "{s}", .{last_error[0..last_error_len]}, .{
                    .color_text = dvui.Color{ .r = 255, .g = 100, .b = 100, .a = 255 },
                    .margin = .{ .x = 0, .y = 2, .w = 0, .h = 6 },
                });
            }

            // Generating indicator (at top — latest activity)
            if (is_generating) {
                _ = dvui.label(@src(), "⟳ Thinking...", .{}, .{
                    .color_text = theme.colors.accent,
                    .margin = .{ .x = 0, .y = 2, .w = 0, .h = 6 },
                });
            }

            // Inline search results (at top — latest results)
            renderInlineResults();

            // Messages: newest first
            var mi: usize = message_count;
            while (mi > 0) {
                mi -= 1;
                if (messages[mi].text_len > 0 and messages[mi].role != .system) {
                    renderMessage(mi);
                }
            }
        }
    }
}

// ══════════════════════════════════════════════════════════
//  Control Panel — Model + Server Management
// ══════════════════════════════════════════════════════════

fn renderControlPanel() void {
    // Row 1: Model
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
            .background = true,
            .color_fill = dvui.Color{ .r = 18, .g = 18, .b = 26, .a = 255 },
            .gravity_y = 0.5,
        });
        defer row.deinit();

        _ = dvui.icon(@src(), "", icons.tvg.lucide.@"hard-drive", .{}, .{
            .color_text = theme.colors.accent,
            .min_size_content = .{ .w = 14, .h = 14 },
            .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
        });

        if (server.backend_kind == .apfel) {
            // macOS: Apple Intelligence — model is built-in
            _ = dvui.label(@src(), "Apple Intelligence (on-device)", .{}, .{
                .color_text = theme.colors.text_main,
                .expand = .horizontal,
            });
            _ = dvui.label(@src(), "Ready", .{}, .{
                .color_text = theme.colors.success,
            });
        } else if (server.model_exists) {
            _ = dvui.label(@src(), "TinyLlama 1.1B  669 MB", .{}, .{
                .color_text = theme.colors.text_main,
                .expand = .horizontal,
            });
            _ = dvui.label(@src(), "Ready", .{}, .{
                .color_text = theme.colors.success,
            });
        } else if (server.model_downloading) {
            _ = dvui.label(@src(), "{s}", .{server.download_progress_buf[0..server.download_progress_len]}, .{
                .color_text = theme.colors.accent,
                .expand = .horizontal,
            });
        } else {
            _ = dvui.label(@src(), "Model not downloaded", .{}, .{
                .color_text = theme.colors.text_muted,
                .expand = .horizontal,
            });
            if (dvui.button(@src(), "Download", .{}, .{
                .color_fill = theme.colors.accent,
                .color_text = dvui.Color.white,
                .corner_radius = dvui.Rect.all(4),
                .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
            })) {
                server.startModelDownload();
            }
        }
    }

    // Row 2: Server binary
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
            .background = true,
            .color_fill = dvui.Color{ .r = 16, .g = 16, .b = 22, .a = 255 },
            .gravity_y = 0.5,
        });
        defer row.deinit();

        _ = dvui.icon(@src(), "", icons.tvg.lucide.@"server", .{}, .{
            .color_text = theme.colors.accent,
            .min_size_content = .{ .w = 14, .h = 14 },
            .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
        });

        if (server.backend_kind == .apfel) {
            // macOS: show apfel binary status
            if (server.llama_server_exists) {
                _ = dvui.label(@src(), "apfel", .{}, .{
                    .color_text = theme.colors.text_main,
                    .expand = .horizontal,
                });
                _ = dvui.label(@src(), "Found", .{}, .{
                    .color_text = theme.colors.success,
                });
            } else {
                _ = dvui.label(@src(), "apfel not found", .{}, .{
                    .color_text = theme.colors.text_muted,
                    .expand = .horizontal,
                });
                _ = dvui.label(@src(), "brew install apfel", .{}, .{
                    .color_text = theme.colors.accent,
                });
            }
        } else if (server.llama_server_exists) {
            _ = dvui.label(@src(), "Shimmy", .{}, .{
                .color_text = theme.colors.text_main,
                .expand = .horizontal,
            });
            _ = dvui.label(@src(), "Found", .{}, .{
                .color_text = theme.colors.success,
            });
        } else {
            _ = dvui.label(@src(), "Shimmy missing", .{}, .{
                .color_text = theme.colors.text_muted,
                .expand = .horizontal,
            });
            if (dvui.button(@src(), "Install", .{}, .{
                .color_fill = dvui.Color{ .r = 40, .g = 40, .b = 55, .a = 255 },
                .color_text = theme.colors.accent,
                .corner_radius = dvui.Rect.all(4),
                .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
            })) {
                server.installLlamaServer();
            }
        }
    }

    // Row 3: Config
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 4, .w = 12, .h = 4 },
            .background = true,
            .color_fill = dvui.Color{ .r = 14, .g = 14, .b = 20, .a = 255 },
            .gravity_y = 0.5,
        });
        defer row.deinit();

        var port_buf: [8]u8 = undefined;
        const port_str = std.fmt.bufPrintZ(&port_buf, "{d}", .{server.server_port}) catch "41592";
        var gpu_buf: [8]u8 = undefined;
        const gpu_str = std.fmt.bufPrintZ(&gpu_buf, "{d}", .{server.gpu_layers}) catch "99";

        _ = dvui.label(@src(), "Port", .{}, .{
            .color_text = dvui.Color{ .r = 70, .g = 70, .b = 90, .a = 255 },
            .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
        });
        _ = dvui.label(@src(), "{s}", .{port_str}, .{
            .color_text = theme.colors.text_main,
            .margin = .{ .x = 0, .y = 0, .w = 16, .h = 0 },
        });
        _ = dvui.label(@src(), "GPU", .{}, .{
            .color_text = dvui.Color{ .r = 70, .g = 70, .b = 90, .a = 255 },
            .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
        });
        _ = dvui.label(@src(), "{s}", .{gpu_str}, .{
            .color_text = theme.colors.text_main,
            .expand = .horizontal,
        });
    }

    // Row 4: Start / Stop
    {
        const can_start = server.model_exists and server.llama_server_exists and !server.server_running;
        const can_stop = server.server_running;

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
            .background = true,
            .color_fill = dvui.Color{ .r = 14, .g = 14, .b = 20, .a = 255 },
            .color_border = dvui.Color{ .r = 30, .g = 30, .b = 45, .a = 180 },
            .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
            .gravity_y = 0.5,
        });
        defer row.deinit();

        if (dvui.button(@src(), "Start", .{}, .{
            .expand = .horizontal,
            .color_fill = if (can_start) theme.colors.success else dvui.Color{ .r = 25, .g = 30, .b = 25, .a = 200 },
            .color_text = if (can_start) dvui.Color.white else dvui.Color{ .r = 60, .g = 80, .b = 60, .a = 150 },
            .corner_radius = dvui.Rect.all(6),
            .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
            .margin = .{ .x = 0, .y = 0, .w = 3, .h = 0 },
        })) {
            if (can_start) server.startServer();
        }

        if (dvui.button(@src(), "Stop", .{}, .{
            .expand = .horizontal,
            .color_fill = if (can_stop) dvui.Color{ .r = 180, .g = 50, .b = 50, .a = 255 } else dvui.Color{ .r = 30, .g = 20, .b = 20, .a = 200 },
            .color_text = if (can_stop) dvui.Color.white else dvui.Color{ .r = 80, .g = 50, .b = 50, .a = 150 },
            .corner_radius = dvui.Rect.all(6),
            .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
            .margin = .{ .x = 3, .y = 0, .w = 0, .h = 0 },
        })) {
            if (can_stop) server.stopServer();
        }
    }
}

// ══════════════════════════════════════════════════════════
//  Chat UI Components
// ══════════════════════════════════════════════════════════

fn renderEmptyState() void {
    {
        var welcome_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .x = 20, .y = 30, .w = 20, .h = 20 },
            .gravity_x = 0.5,
        });
        defer welcome_box.deinit();

        _ = dvui.icon(@src(), "", icons.tvg.lucide.@"cpu", .{}, .{
            .color_text = dvui.Color{ .r = 60, .g = 80, .b = 120, .a = 150 },
            .min_size_content = .{ .w = 40, .h = 40 },
            .gravity_x = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 12 },
        });
        _ = dvui.label(@src(), "ZigZag AI", .{}, .{
            .color_text = theme.colors.text_main,
            .gravity_x = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
        });

        if (server.model_status == .online) {
            _ = dvui.label(@src(), "Ask me anything about media", .{}, .{
                .color_text = theme.colors.text_muted,
                .gravity_x = 0.5,
                .margin = .{ .x = 0, .y = 0, .w = 0, .h = 20 },
            });
        } else {
            _ = dvui.label(@src(), "Start the server to begin chatting", .{}, .{
                .color_text = theme.colors.text_muted,
                .gravity_x = 0.5,
                .margin = .{ .x = 0, .y = 0, .w = 0, .h = 20 },
            });
        }
    }

    // Suggestion chips
    if (server.model_status == .online) {
        const suggestions = [_][]const u8{
            "Recommend anime like Invincible",
            "What 4K movies should I watch?",
            "Explain HEVC vs H.264",
            "Best sci-fi series of 2026",
        };

        for (suggestions, 0..) |sug, idx| {
            if (dvui.button(@src(), sug, .{}, .{
                .id_extra = idx + 8000,
                .expand = .horizontal,
                .color_fill = dvui.Color{ .r = 20, .g = 22, .b = 30, .a = 255 },
                .color_border = dvui.Color{ .r = 40, .g = 45, .b = 65, .a = 150 },
                .border = dvui.Rect.all(1),
                .corner_radius = dvui.Rect.all(10),
                .padding = .{ .x = 14, .y = 10, .w = 14, .h = 10 },
                .margin = .{ .x = 8, .y = 0, .w = 8, .h = 6 },
                .color_text = theme.colors.text_main,
            })) {
                const slen = @min(sug.len, MAX_INPUT_LEN);
                @memcpy(input_buf[0..slen], sug[0..slen]);
                @memset(input_buf[slen..], 0);
                input_len = slen;
                sendMessage();
            }
        }
    }
}

fn renderMessage(mi: usize) void {
    const msg = &messages[mi];
    const is_user = msg.role == .user;
    const text = msg.text[0..msg.text_len];

    if (is_user) {
        _ = dvui.label(@src(), "You", .{}, .{
            .id_extra = mi + 7000,
            .expand = .horizontal,
            .color_text = dvui.Color{ .r = 130, .g = 160, .b = 220, .a = 255 },
            .margin = .{ .x = 0, .y = 6, .w = 0, .h = 2 },
        });
    } else {
        _ = dvui.label(@src(), switch (server.backend_kind) { .apfel => "Apple AI", .gemma_llama => "Gemma" }, .{}, .{
            .id_extra = mi + 7000,
            .expand = .horizontal,
            .color_text = dvui.Color{ .r = 100, .g = 200, .b = 130, .a = 255 },
            .margin = .{ .x = 0, .y = 6, .w = 0, .h = 2 },
        });
    }

    // Word-wrap into lines
    var wrapped: [MAX_MSG_LEN * 2]u8 = undefined;
    var wpos: usize = 0;
    var col: usize = 0;
    const wrap_at: usize = 65;
    var last_space: usize = 0;
    var last_space_col: usize = 0;

    for (text) |ch| {
        if (wpos >= wrapped.len - 1) break;
        if (ch == '\n') {
            wrapped[wpos] = '\n';
            wpos += 1;
            col = 0;
            last_space = wpos;
            last_space_col = 0;
            continue;
        }
        if (ch == ' ') {
            last_space = wpos;
            last_space_col = col;
        }
        wrapped[wpos] = ch;
        wpos += 1;
        col += 1;

        if (col >= wrap_at and last_space > 0 and last_space_col > 0) {
            wrapped[last_space] = '\n';
            col = wpos - last_space - 1;
            last_space = 0;
            last_space_col = 0;
        }
    }

    dvui.labelEx(@src(), "{s}", .{wrapped[0..wpos]}, .{ .ellipsize = false }, .{
        .id_extra = mi + 7100,
        .expand = .horizontal,
        .color_text = dvui.Color{ .r = 210, .g = 215, .b = 225, .a = 255 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
    });

    // Inline results are rendered separately after the message loop
}

// ── Inline search results widget (from find_and_play tool) ──
pub fn renderInlineResults() void {
    if (!chat_results_active or chat_result_count == 0) return;

    const source_label = struct {
        fn get(s: resolver.SourceType) []const u8 {
            return switch (s) {
                .jellyfin => "Jellyfin",
                .stremio => "Stremio",
                .torrent => "Torrent",
                .anime => "Anime",
                .youtube => "YouTube",
            };
        }
    }.get;

    const quality_label = struct {
        fn get(q: u8) []const u8 {
            return switch (q) {
                4 => "4K",
                3 => "1080p",
                2 => "720p",
                1 => "480p",
                else => "",
            };
        }
    }.get;

    var results_box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = 9500,
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = 4, .w = 0, .h = 8 },
    });
    defer results_box.deinit();

    // Header
    _ = dvui.label(@src(), "Results", .{}, .{
        .id_extra = 9501,
        .color_text = dvui.Color{ .r = 100, .g = 200, .b = 130, .a = 255 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
    });

    for (0..chat_result_count) |ci| {
        const item = &chat_results[ci];
        if (item.name_len == 0) continue;
        const name = item.name[0..item.name_len];
        const is_recommended = if (recommended_idx) |ri| ri == ci else false;

        // Single-row card: name (flex) · pct · source · quality · seeds · [+] [▶]
        var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = ci + 9600,
            .expand = .horizontal,
            .background = true,
            .color_fill = if (is_recommended)
                dvui.Color{ .r = 25, .g = 35, .b = 55, .a = 255 }
            else
                dvui.Color{ .r = 22, .g = 22, .b = 34, .a = 255 },
            .color_border = if (is_recommended)
                theme.colors.accent
            else
                dvui.Color{ .r = 50, .g = 50, .b = 70, .a = 180 },
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(8),
            .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
            .margin = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
        });
        defer card.deinit();

        if (is_recommended) {
            _ = dvui.label(@src(), "★", .{}, .{
                .id_extra = ci + 9700,
                .color_text = dvui.Color{ .r = 255, .g = 200, .b = 50, .a = 255 },
                .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
                .gravity_y = 0.5,
            });
        }

        // Name — flex-grow via expand. Single line, fades on overflow.
        _ = dvui.label(@src(), "{s}", .{name}, .{
            .id_extra = ci + 9800,
            .expand = .horizontal,
            .color_text = dvui.Color{ .r = 220, .g = 225, .b = 240, .a = 255 },
            .gravity_y = 0.5,
        });

        // Match % badge
        {
            const pct = item.match_pct;
            const pct_color = if (pct >= 80)
                dvui.Color{ .r = 80, .g = 200, .b = 120, .a = 255 }
            else if (pct >= 50)
                dvui.Color{ .r = 220, .g = 180, .b = 50, .a = 255 }
            else
                dvui.Color{ .r = 180, .g = 100, .b = 80, .a = 255 };
            _ = dvui.label(@src(), "{d}%", .{pct}, .{
                .id_extra = ci + 10200,
                .color_text = pct_color,
                .margin = .{ .x = 6, .y = 0, .w = 6, .h = 0 },
                .gravity_y = 0.5,
            });
        }

        _ = dvui.label(@src(), "{s}", .{source_label(item.source)}, .{
            .id_extra = ci + 9900,
            .color_text = dvui.Color{ .r = 140, .g = 145, .b = 165, .a = 200 },
            .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
            .gravity_y = 0.5,
        });

        {
            const qlbl = quality_label(item.quality);
            if (qlbl.len > 0) {
                _ = dvui.label(@src(), "{s}", .{qlbl}, .{
                    .id_extra = ci + 10000,
                    .color_text = dvui.Color{ .r = 100, .g = 180, .b = 255, .a = 220 },
                    .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
                    .gravity_y = 0.5,
                });
            }
        }

        if (item.seeds > 0) {
            _ = dvui.label(@src(), "↑{d}", .{item.seeds}, .{
                .id_extra = ci + 10300,
                .color_text = if (item.seeds > 20)
                    dvui.Color{ .r = 80, .g = 200, .b = 120, .a = 220 }
                else
                    dvui.Color{ .r = 200, .g = 180, .b = 60, .a = 220 },
                .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
                .gravity_y = 0.5,
            });
        }

        // Queue
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"plus", .{}, .{}, .{
            .id_extra = ci + 10400,
            .color_fill = dvui.Color{ .r = 35, .g = 40, .b = 55, .a = 255 },
            .color_text = dvui.Color{ .r = 160, .g = 170, .b = 200, .a = 255 },
            .corner_radius = dvui.Rect.all(6),
            .padding = .{ .x = 5, .y = 5, .w = 5, .h = 5 },
            .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
            .min_size_content = .{ .w = 14, .h = 14 },
            .gravity_y = 0.5,
        })) {
            queueChatResult(ci);
        }

        // Play
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"play", .{}, .{}, .{
            .id_extra = ci + 10100,
            .color_fill = theme.colors.accent,
            .color_text = dvui.Color.white,
            .corner_radius = dvui.Rect.all(6),
            .padding = .{ .x = 5, .y = 5, .w = 5, .h = 5 },
            .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
            .min_size_content = .{ .w = 14, .h = 14 },
            .gravity_y = 0.5,
        })) {
            playChatResult(ci);
        }
    }
}

pub fn playChatResult(idx: usize) void {
    if (idx >= chat_result_count) return;
    // Copy item into resolver's global results slot 0 and play
    resolver.results_mutex.lock();
    resolver.results[0] = chat_results[idx];
    if (resolver.result_count == 0) resolver.result_count = 1;
    resolver.results_mutex.unlock();
    resolver.playItem(0);
    chat_results_active = false;
    awaiting_confirmation = false;
}

fn queueChatResult(idx: usize) void {
    if (idx >= chat_result_count) return;
    const item = &chat_results[idx];
    const name = item.name[0..item.name_len];
    const url_str = item.url[0..item.url_len];
    const src_label = switch (item.source) {
        .jellyfin => "jellyfin",
        .stremio => "stremio",
        .torrent => "torrent",
        .anime => "anime",
        .youtube => "youtube",
    };
    @import("queue.zig").addToQueue(url_str, name, src_label);
    state.showToast("Added to queue");
}


// ══════════════════════════════════════════════════════════
//  LLM Backend
// ══════════════════════════════════════════════════════════

/// Take-again: drop the last assistant reply + re-run generation from
/// the user prompt just before it. Message index passed in because
/// dropdown + grid chat both render lists and need to target one msg.
pub fn regenerateFrom(assistant_idx: usize) void {
    if (assistant_idx >= message_count) return;
    if (is_generating) return;
    if (messages[assistant_idx].role != .assistant) return;
    // Need a user message before it.
    if (assistant_idx == 0 or messages[assistant_idx - 1].role != .user) return;

    // Clear just the assistant's text — keep the slot, generateResponse
    // writes into the last assistant slot.
    messages[assistant_idx].text_len = 0;
    // Trim everything after (tool-call tails, etc.)
    message_count = assistant_idx + 1;

    is_generating = true;
    phase = .waiting_server;
    last_error_len = 0;

    llm_thread = std.Thread.spawn(.{}, ai_context.generateResponse, .{}) catch {
        is_generating = false;
        phase = .idle;
        setError("Regenerate: failed to spawn thread");
        return;
    };
    llm_thread.?.detach();
}

pub fn trySendMessage() void {
    // Ensure path detection has run (renderChatBody normally does this,
    // but input submit may fire before the drawer is ever opened).
    server.checkPaths();
    // Auto-start server if not running
    if (!server.server_running and server.model_exists and server.llama_server_exists) {
        server.startServer();
    }
    sendMessage();
}

pub fn sendMessage() void {
    if (input_len == 0 or is_generating) return;

    // Check if this is a confirmation response for play
    if (awaiting_confirmation and recommended_idx != null) {
        const user_text = input_buf[0..input_len];
        var lower: [64]u8 = undefined;
        const clen = @min(input_len, 63);
        for (0..clen) |i| lower[i] = std.ascii.toLower(user_text[i]);
        const l = lower[0..clen];

        const is_yes = std.mem.startsWith(u8, l, "yes") or
            std.mem.startsWith(u8, l, "play") or
            std.mem.startsWith(u8, l, "go") or
            std.mem.startsWith(u8, l, "sure") or
            std.mem.startsWith(u8, l, "ok") or
            std.mem.startsWith(u8, l, "yeah") or
            std.mem.startsWith(u8, l, "yep") or
            std.mem.startsWith(u8, l, "start");

        if (is_yes) {
            playChatResult(recommended_idx.?);
            @memset(&input_buf, 0);
            input_len = 0;
            // Add confirmation message to chat
            if (message_count < MAX_MESSAGES) {
                messages[message_count] = .{ .role = .assistant, .text_len = 0 };
                const conf_msg = "Playing now!";
                messages[message_count].text_len = conf_msg.len;
                @memcpy(messages[message_count].text[0..conf_msg.len], conf_msg);
                message_count += 1;
            }
            return;
        }
    }

    if (message_count >= MAX_MESSAGES) return;

    // ── Fast-path: skip LLM for obvious media commands ──
    // Pattern-match "play X", "find X", "watch X", "search X"
    if (ai_context.tryFastPath(input_buf[0..input_len])) {
        return; // handled — resolver spawned, canned response generated
    }

    messages[message_count] = .{
        .role = .user,
        .text_len = @min(input_len, MAX_MSG_LEN),
    };
    @memcpy(messages[message_count].text[0..messages[message_count].text_len], input_buf[0..messages[message_count].text_len]);
    message_count += 1;

    // Pre-create assistant message slot
    if (message_count < MAX_MESSAGES) {
        messages[message_count] = .{
            .role = .assistant,
            .text_len = 0,
        };
        message_count += 1;
    }

    @memset(&input_buf, 0);
    input_len = 0;
    is_generating = true;
    last_error_len = 0;

    llm_thread = std.Thread.spawn(.{}, ai_context.generateResponse, .{}) catch {
        is_generating = false;
        setError("Failed to start AI thread");
        return;
    };
    llm_thread.?.detach();
}

pub fn setError(err: []const u8) void {
    const elen = @min(err.len, 256);
    @memcpy(last_error[0..elen], err[0..elen]);
    last_error_len = elen;
    logs.pushLog("error", "ai", err, true);
}

// ── Voice callback: ASR result → chat input ──
fn onTranscribed(transcribed: []const u8) void {
    if (message_count >= MAX_MESSAGES) return;
    if (is_generating) return; // prevent overlap
    const tlen = @min(transcribed.len, MAX_INPUT_LEN - 1);
    @memcpy(input_buf[0..tlen], transcribed[0..tlen]);
    @memset(input_buf[tlen..], 0);
    input_len = tlen;
    trySendMessage();
}

// ══════════════════════════════════════════════════════════
//  Next-Gen Floating AI Bubble Overlay
// ══════════════════════════════════════════════════════════

pub fn renderFloatingBubble() void {

    const min_w: f32 = 300.0;
    const min_h: f32 = 400.0;
    const default_w: f32 = 400.0;
    const default_h: f32 = 550.0;

    // Persistent rect — tracks position across frames for BOTH collapsed and expanded modes.
    // Initialized to bottom-right on first open.
    const S = struct {
        var win_rect: dvui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        var initialized: bool = false;
        var was_expanded: bool = true;
    };

    if (!S.initialized) {
        const wr = dvui.windowRect();
        if (is_bubble_open) {
            S.win_rect = .{
                .x = wr.w - default_w - 30, // Default to right side
                .y = wr.h - default_h - 80, // Default to bottom
                .w = default_w + 4,
                .h = default_h + 4,
            };
        } else {
            S.win_rect = .{
                .x = wr.w - 56 - 30, // Bottom-right corner specifically for the small bubble
                .y = wr.h - 56 - 80,
                .w = 60,
                .h = 90,
            };
        }
        S.initialized = true;
        S.was_expanded = is_bubble_open;
    }

    // Handle seamless resizing by anchoring the bottom-right corner
    if (is_bubble_open and !S.was_expanded) {
        // Just expanded: grow up and left
        S.win_rect.x -= (default_w + 4 - S.win_rect.w);
        S.win_rect.y -= (default_h + 4 - S.win_rect.h);
        S.win_rect.w = default_w + 4;
        S.win_rect.h = default_h + 4;
        S.was_expanded = true;
    } else if (!is_bubble_open and S.was_expanded) {
        // Just collapsed: shrink down and right
        S.win_rect.x += (S.win_rect.w - 60);
        S.win_rect.y += (S.win_rect.h - 90);
        S.win_rect.w = 60;
        S.win_rect.h = 90;
        S.was_expanded = false;
    }

    if (is_bubble_open) {
        // ══════════════════════════════════════════════════
        // EXPANDED: dvui.floatingWindow — a true top-level
        // subwindow that sits above ALL content and captures
        // ALL mouse/keyboard events within its bounds.
        // ══════════════════════════════════════════════════
        var chat_win = dvui.floatingWindow(@src(), .{
            .modal = false,
            .resize = .all,
            .rect = &S.win_rect,
        }, .{
            .min_size_content = .{ .w = min_w, .h = min_h },
            .color_fill = theme.colors.bg_glass,
            .color_border = theme.colors.border_glass,
            .border = dvui.Rect.all(1),
            .corner_radius = theme.dims.rad_lg,
            .box_shadow = .{ .color = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 180 }, .offset = .{ .x = 0, .y = 6 }, .fade = 24.0 },
        });
        defer chat_win.deinit();

        // Header — also the draggable region
        {
            var ctx_hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
                .background = true,
                .color_fill = theme.colors.bg_header,
                .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
                .color_border = theme.colors.divider,
            });

            // Make header the drag area so user can reposition the window
            chat_win.dragAreaSet(ctx_hdr.data().borderRectScale().r);

            _ = dvui.icon(@src(), "", icons.tvg.lucide.@"bot", .{}, .{
                .color_text = theme.colors.accent,
                .min_size_content = .{ .w = 14, .h = 14 },
                .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
                .gravity_y = 0.5,
            });

            // Read what's playing
            const state_mod = @import("../core/state.zig");
            if (state_mod.app.players.items.len > 0) {
                const ap = state_mod.app.players.items[state_mod.app.active_player_idx];
                var name_buf: [128]u8 = undefined;
                var curr_title: []const u8 = "Media";

                const path = &ap.current_url;
                const path_len = std.mem.indexOfScalar(u8, path, 0) orelse path.len;
                if (path_len > 0) {
                    const basename = std.fs.path.basename(path[0..path_len]);
                    const safe_len = @min(basename.len, 128);
                    @memcpy(&name_buf, basename[0..safe_len]);
                    curr_title = name_buf[0..safe_len];
                }

                _ = dvui.label(@src(), "Seeing: ", .{}, .{
                    .color_text = theme.colors.text_muted,
                    .gravity_y = 0.5,
                });
                dvui.labelEx(@src(), "{s}", .{curr_title}, .{ .ellipsize = true }, .{
                    .color_text = theme.colors.text_main,
                    .gravity_y = 0.5,
                    .expand = .horizontal,
                });
            } else {
                _ = dvui.label(@src(), "AI Chat", .{}, .{
                    .color_text = theme.colors.text_muted,
                    .gravity_y = 0.5,
                    .expand = .horizontal,
                });
            }

            // Close button
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"x", .{}, .{}, .{
                .color_text = theme.colors.text_muted,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .border = dvui.Rect.all(0),
                .gravity_y = 0.5,
            })) {
                is_bubble_open = false;
            }

            ctx_hdr.deinit();
        }

        // Render the inner chat UI
        renderChatBody();

    } else {
        // Collapsed mode handled by header bot-toggle. No floating FAB.
        return;
    }
}
