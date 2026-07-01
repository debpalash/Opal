const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const components = @import("../ui/components.zig");
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
    return switch (r) {
        .user => 0,
        .assistant => 1,
        .system => 2,
    };
}

fn intToRole(n: c_int) Role {
    return switch (n) {
        0 => .user,
        1 => .assistant,
        else => .system,
    };
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
pub var is_generating: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
/// Set true to abort the in-flight LLM stream. generateResponse() resets it to
/// false at the start of each generation and checks it inside the SSE read loop,
/// killing the curl child and bailing. Lets the Stop button and voice barge-in
/// truly stop the model mid-reply (previously is_generating was flipped but the
/// curl child kept streaming and overwrote the chat).
pub var gen_abort: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

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
    is_generating.store(false, .release);
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
    // Abort the in-flight LLM stream for real (curl child gets killed in the
    // SSE loop), and silence any queued sentences of the superseded reply.
    voice.barge_in.store(true, .release);
    gen_abort.store(true, .release);
    is_generating.store(false, .release);
    voice.setPhase(.idle);

    // Pause v2 voice server (thread-safe; voice_socket is now private + mutex-guarded)
    voice.pauseVoiceServer();

    // Kill audio playback + recording in a background thread to avoid blocking
    // render. stopAllAudio targets the real players (say/afplay/aplay), which
    // the old `pkill -f say` missed for Kokoro/Piper backends.
    const t = std.Thread.spawn(.{}, struct {
        fn run() void {
            voice.stopAllAudio();
            var kill_rec = @import("../core/io_global.zig").Child.init(
                &.{ "pkill", "-f", "rec.*opal_ai_mic" },
                @import("../core/alloc.zig").allocator,
            );
            kill_rec.stdout_behavior = .Ignore;
            kill_rec.stderr_behavior = .Ignore;
            _ = kill_rec.spawnAndWait() catch {};
        }
    }.run, .{}) catch {
        return;
    };
    t.detach();
}

// ══════════════════════════════════════════════════════════
//  Main UI
// ══════════════════════════════════════════════════════════

pub fn renderChatBody() void {
    server.checkPaths();
    initCallbacks();
    { // Kill zombie servers from previous runs — once at startup only
        const K = struct {
            var done: bool = false;
        };
        if (!K.done) {
            K.done = true;
            voice.killStaleServers();
            voice.preWarmServers(); // Start STT/TTS servers in background early
        }
    }

    // Proactive startup greeting (once per session, fires on first frame with empty chat)
    {
        const S = struct {
            var shown: bool = false;
        };
        if (!S.shown and message_count == 0) {
            S.shown = true;
            var sug_buf: [256]u8 = undefined;
            var sug_name_buf: [128]u8 = undefined;
            if (memory.getProactiveSuggestion(&sug_buf, &sug_name_buf)) |suggestion| {
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

    // ── Compact header ── (no filled bar; one hairline divider below)
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
            .gravity_y = 0.5,
        });
        defer hdr.deinit();

        _ = dvui.icon(@src(), "", icons.tvg.lucide.cpu, .{}, .{
            .color_text = theme.colors.accent,
            .min_size_content = .{ .w = 16, .h = 16 },
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        });
        _ = dvui.label(@src(), switch (server.backend_kind) {
            .apfel => "Apple Intelligence",
            .gemma_llama => "Gemma 4 E2B",
        }, .{}, .{
            .color_text = theme.colors.text_primary,
            .expand = .horizontal,
        });

        // Status indicator — two-state quiet text dot.
        if (server.model_status == .online) {
            _ = dvui.label(@src(), "Online", .{}, .{ .color_text = theme.colors.semantic_success });
        } else {
            _ = dvui.label(@src(), if (server.server_running) "Starting" else "Offline", .{}, .{ .color_text = theme.colors.text_tertiary });
        }

        // Settings gear
        if (components.iconButton(@src(), icons.tvg.lucide.settings, "Settings", show_controls)) {
            show_controls = !show_controls;
        }

        // Voice toggle — plain accent toggle.
        if (dvui.button(@src(), "Voice", .{}, .{
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = if (voice.voice_mode) theme.colors.accent else theme.colors.text_secondary,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            .margin = .{ .x = theme.spacing.xs, .y = 0, .w = 0, .h = 0 },
        })) {
            voice.voice_mode = !voice.voice_mode;
        }

        // Incognito toggle — plain accent toggle.
        if (dvui.button(@src(), "Incognito", .{}, .{
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = if (incognito_mode) theme.colors.accent else theme.colors.text_secondary,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            .margin = .{ .x = theme.spacing.xs, .y = 0, .w = 0, .h = 0 },
        })) {
            incognito_mode = !incognito_mode;
        }

        // Clear chat
        if (components.iconButton(@src(), icons.tvg.lucide.@"trash-2", "Clear chat", false)) {
            clearHistory();
        }
    }
    components.divider();

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
    if (voice.conversation_active or is_generating.load(.acquire) or voice.is_speaking) {
        show_status_bar = true;
    }

    if (show_status_bar) {
        // Spacing-only row (no fill, no border). Status text is quiet and transient.
        var status_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
        });
        defer status_box.deinit();

        _ = dvui.icon(@src(), "", icons.tvg.lucide.activity, .{}, .{
            .color_text = theme.colors.accent,
            .min_size_content = .{ .w = 14, .h = 14 },
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        });

        if (voice.conversation_active) {
            if (voice.conv_phase == .listening) {
                if (voice.partial_text_len > 0) {
                    _ = dvui.label(@src(), "Listening: {s}", .{voice.partial_text[0..voice.partial_text_len]}, .{
                        .color_text = theme.colors.text_secondary,
                        .expand = .horizontal,
                    });
                } else {
                    _ = dvui.label(@src(), "Listening...", .{}, .{
                        .color_text = theme.colors.text_secondary,
                    });
                }
            } else if (voice.conv_phase == .transcribing) {
                _ = dvui.label(@src(), "Transcribing...", .{}, .{
                    .color_text = theme.colors.text_secondary,
                });
            } else if (voice.conv_phase == .thinking) {
                _ = dvui.label(@src(), "Thinking...", .{}, .{
                    .color_text = theme.colors.text_secondary,
                });
            } else if (voice.conv_phase == .speaking) {
                _ = dvui.label(@src(), "Speaking...", .{}, .{
                    .color_text = theme.colors.text_secondary,
                });
            } else {
                _ = dvui.label(@src(), "Voice Active (Ready)", .{}, .{
                    .color_text = theme.colors.text_tertiary,
                });
            }
        } else if (is_generating.load(.acquire)) {
            _ = dvui.label(@src(), "Thinking...", .{}, .{
                .color_text = theme.colors.text_secondary,
            });
        } else if (voice.is_speaking) {
            _ = dvui.label(@src(), "Speaking...", .{}, .{
                .color_text = theme.colors.text_secondary,
            });
        }
    }

    // ── Input bar (sticky at top) — spacing only, no fill/border ──
    {
        var input_bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = 9005,
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.sm, .w = theme.spacing.sm, .h = theme.spacing.sm },
        });
        defer input_bar.deinit();

        // Calm text entry — hairline resting border, accent focus ring,
        // bg_elevated fill (matches searchInput). Keeps enter_pressed/id.
        var has_focus = false;
        var te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &input_buf },
        }, .{
            .id_extra = 9006,
            .expand = .horizontal,
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_primary,
            .color_border = if (has_focus) theme.colors.accent else theme.colors.border_subtle,
            .border = dvui.Rect.all(1),
            .corner_radius = theme.dims.rad_md,
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        });
        const enter_pressed = te.enter_pressed;
        if (dvui.focusedWidgetIdInCurrentSubwindow()) |fid| {
            has_focus = te.data().id == fid;
        }
        input_len = std.mem.indexOfScalar(u8, &input_buf, 0) orelse MAX_INPUT_LEN;
        te.deinit();

        const can_send = input_len > 0 and !is_generating.load(.acquire);

        // Send button — the single accent affordance in this row.
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.send, .{}, .{}, .{
            .color_fill = if (can_send) theme.colors.accent else theme.colors.bg_elevated,
            .color_text = if (can_send) theme.colors.text_on_accent else theme.colors.text_tertiary,
            .corner_radius = theme.dims.rad_md,
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.sm, .w = theme.spacing.sm, .h = theme.spacing.sm },
            .margin = .{ .x = 0, .y = 0, .w = 2, .h = 0 },
            .border = dvui.Rect.all(0),
        })) {
            if (can_send) trySendMessage();
        }

        // Enter key
        if (enter_pressed and can_send) {
            trySendMessage();
        }

        // Mic / conversation / stop — borderless icon buttons.
        // Recording/stopping use the danger token only while active.
        {
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.mic, .{}, .{}, .{
                .id_extra = 9007,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_text = if (voice.is_recording) theme.colors.danger else if (voice.is_transcribing) theme.colors.accent else theme.colors.text_secondary,
                .corner_radius = theme.dims.rad_md,
                .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.sm, .w = theme.spacing.sm, .h = theme.spacing.sm },
                .margin = .{ .x = theme.spacing.xs, .y = 0, .w = 0, .h = 0 },
                .border = dvui.Rect.all(0),
            })) {
                voice.toggleMicRecording();
            }

            // Conversation mode toggle (live hands-free voice loop)
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.headphones, .{}, .{}, .{
                .id_extra = 9008,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_text = if (voice.conversation_active) theme.colors.accent else theme.colors.text_secondary,
                .corner_radius = theme.dims.rad_md,
                .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.sm, .w = theme.spacing.sm, .h = theme.spacing.sm },
                .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
                .border = dvui.Rect.all(0),
            })) {
                voice.toggleConversation();
            }

            // Stop button — danger token only when something is active.
            const is_active = is_generating.load(.acquire) or voice.is_speaking or voice.is_recording or voice.is_transcribing;
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.square, .{}, .{}, .{
                .id_extra = 9009,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_text = if (is_active) theme.colors.danger else theme.colors.text_tertiary,
                .corner_radius = theme.dims.rad_md,
                .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.sm, .w = theme.spacing.sm, .h = theme.spacing.sm },
                .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
                .border = dvui.Rect.all(0),
            })) {
                stopAll();
            }
        }
    }

    // ── Chat area ──
    {
        var scroll = dvui.scrollArea(@src(), .{}, .{
            .expand = .both,
            .color_fill = theme.colors.bg_app,
            .background = true,
        });
        defer scroll.deinit();

        var content_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
        });
        defer content_box.deinit();

        if (message_count == 0) {
            renderEmptyState();
        } else {
            // Error display (at top — most urgent). Transient semantic text only.
            if (last_error_len > 0) {
                _ = dvui.label(@src(), "{s}", .{last_error[0..last_error_len]}, .{
                    .color_text = theme.colors.semantic_error,
                    .margin = .{ .x = 0, .y = 2, .w = 0, .h = 6 },
                });
            }

            // Generating indicator handled in-bubble (renderMessage) — no
            // duplicate top-of-list spinner.

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
    // Row 1: Model — spacing only, separated by whitespace.
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
            .gravity_y = 0.5,
        });
        defer row.deinit();

        _ = dvui.icon(@src(), "", icons.tvg.lucide.@"hard-drive", .{}, .{
            .color_text = theme.colors.text_tertiary,
            .min_size_content = .{ .w = 14, .h = 14 },
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        });

        if (server.backend_kind == .apfel) {
            // macOS: Apple Intelligence — model is built-in
            _ = dvui.label(@src(), "Apple Intelligence (on-device)", .{}, .{
                .color_text = theme.colors.text_primary,
                .expand = .horizontal,
            });
            _ = dvui.label(@src(), "Ready", .{}, .{
                .color_text = theme.colors.semantic_success,
            });
        } else if (server.model_exists) {
            _ = dvui.label(@src(), "TinyLlama 1.1B  669 MB", .{}, .{
                .color_text = theme.colors.text_primary,
                .expand = .horizontal,
            });
            _ = dvui.label(@src(), "Ready", .{}, .{
                .color_text = theme.colors.semantic_success,
            });
        } else if (server.model_downloading) {
            _ = dvui.label(@src(), "{s}", .{server.download_progress_buf[0..server.download_progress_len]}, .{
                .color_text = theme.colors.text_secondary,
                .expand = .horizontal,
            });
        } else {
            _ = dvui.label(@src(), "Model not downloaded", .{}, .{
                .color_text = theme.colors.text_muted,
                .expand = .horizontal,
            });
            if (dvui.button(@src(), "Download", .{}, .{
                .color_fill = theme.colors.accent,
                .color_text = theme.colors.text_on_accent,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            })) {
                server.startModelDownload();
            }
        }
    }

    // Row 2: Server binary
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
            .gravity_y = 0.5,
        });
        defer row.deinit();

        _ = dvui.icon(@src(), "", icons.tvg.lucide.server, .{}, .{
            .color_text = theme.colors.text_tertiary,
            .min_size_content = .{ .w = 14, .h = 14 },
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        });

        if (server.backend_kind == .apfel) {
            // macOS: show apfel binary status
            if (server.llama_server_exists) {
                _ = dvui.label(@src(), "apfel", .{}, .{
                    .color_text = theme.colors.text_primary,
                    .expand = .horizontal,
                });
                _ = dvui.label(@src(), "Found", .{}, .{
                    .color_text = theme.colors.semantic_success,
                });
            } else {
                _ = dvui.label(@src(), "apfel not found", .{}, .{
                    .color_text = theme.colors.text_muted,
                    .expand = .horizontal,
                });
                _ = dvui.label(@src(), "brew install apfel", .{}, .{
                    .color_text = theme.colors.text_secondary,
                });
            }
        } else if (server.llama_server_exists) {
            _ = dvui.label(@src(), "Shimmy", .{}, .{
                .color_text = theme.colors.text_primary,
                .expand = .horizontal,
            });
            _ = dvui.label(@src(), "Found", .{}, .{
                .color_text = theme.colors.semantic_success,
            });
        } else {
            _ = dvui.label(@src(), "Shimmy missing", .{}, .{
                .color_text = theme.colors.text_muted,
                .expand = .horizontal,
            });
            if (dvui.button(@src(), "Install", .{}, .{
                .color_fill = theme.colors.bg_elevated,
                .color_text = theme.colors.accent,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            })) {
                server.installLlamaServer();
            }
        }
    }

    // Row 3: Config
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
            .gravity_y = 0.5,
        });
        defer row.deinit();

        var port_buf: [8]u8 = undefined;
        const port_str = std.fmt.bufPrintZ(&port_buf, "{d}", .{server.server_port}) catch "41592";
        var gpu_buf: [8]u8 = undefined;
        const gpu_str = std.fmt.bufPrintZ(&gpu_buf, "{d}", .{server.gpu_layers}) catch "99";

        _ = dvui.label(@src(), "Port", .{}, .{
            .color_text = theme.colors.text_tertiary,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.xs, .h = 0 },
        });
        _ = dvui.label(@src(), "{s}", .{port_str}, .{
            .color_text = theme.colors.text_primary,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.lg, .h = 0 },
        });
        _ = dvui.label(@src(), "GPU", .{}, .{
            .color_text = theme.colors.text_tertiary,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.xs, .h = 0 },
        });
        _ = dvui.label(@src(), "{s}", .{gpu_str}, .{
            .color_text = theme.colors.text_primary,
            .expand = .horizontal,
        });
    }

    // Row 4: Start / Stop
    {
        const can_start = server.model_exists and server.llama_server_exists and !server.server_running;
        const can_stop = server.server_running;

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
            .gravity_y = 0.5,
        });
        defer row.deinit();

        if (dvui.button(@src(), "Start", .{}, .{
            .expand = .horizontal,
            .color_fill = if (can_start) theme.colors.accent else theme.colors.bg_elevated,
            .color_text = if (can_start) theme.colors.text_on_accent else theme.colors.text_tertiary,
            .corner_radius = theme.dims.rad_md,
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.xs, .h = 0 },
        })) {
            if (can_start) server.startServer();
        }

        if (dvui.button(@src(), "Stop", .{}, .{
            .expand = .horizontal,
            .color_fill = theme.colors.bg_elevated,
            .color_text = if (can_stop) theme.colors.danger else theme.colors.text_tertiary,
            .corner_radius = theme.dims.rad_md,
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
            .margin = .{ .x = theme.spacing.xs, .y = 0, .w = 0, .h = 0 },
        })) {
            if (can_stop) server.stopServer();
        }
    }
    components.divider();
}

// ══════════════════════════════════════════════════════════
//  Chat UI Components
// ══════════════════════════════════════════════════════════

fn renderEmptyState() void {
    components.emptyState(
        icons.tvg.lucide.cpu,
        "Opal",
        if (server.model_status == .online) "Ask me anything about media" else "Start the server to begin chatting",
    );

    // Suggestion text-links — borderless, no fill, separated by whitespace.
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
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
                .margin = .{ .x = theme.spacing.sm, .y = 0, .w = theme.spacing.sm, .h = theme.spacing.xs },
                .color_text = theme.colors.text_secondary,
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

    // Author tag — one quiet label; hierarchy via muting, not colored tags.
    {
        const author: []const u8 = if (is_user) "You" else switch (server.backend_kind) {
            .apfel => "Apple AI",
            .gemma_llama => "Gemma",
        };
        _ = dvui.label(@src(), "{s}", .{author}, .{
            .id_extra = mi + 7000,
            .expand = .horizontal,
            .color_text = theme.colors.text_tertiary,
            .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 2 },
        });
    }

    // Empty assistant bubble — show status instead of a blank line so a
    // reply-in-progress or failed reply never renders as nothing.
    if (msg.text_len == 0) {
        const ph: []const u8 = if (is_generating.load(.acquire) and mi + 1 == message_count) "Thinking…" else "(no response)";
        _ = dvui.label(@src(), "{s}", .{ph}, .{
            .id_extra = mi + 7100,
            .expand = .horizontal,
            .color_text = theme.colors.text_muted,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
        });
        return;
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
        .color_text = if (is_user) theme.colors.text_secondary else theme.colors.text_primary,
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
                .local => "On disk",
                .tmdb => "Catalog",
                .comics => "Comics",
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
        .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = theme.spacing.sm },
    });
    defer results_box.deinit();

    // Header
    components.sectionHeader("Results");

    for (0..chat_result_count) |ci| {
        const item = &chat_results[ci];
        if (item.name_len == 0) continue;
        const name = item.name[0..item.name_len];
        const is_recommended = if (recommended_idx) |ri| ri == ci else false;

        // Vertical row: name (+ accent edge if recommended) over one
        // muted middot metadata line, with queue/play actions on the right.
        var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = ci + 9600,
            .expand = .horizontal,
            // Recommended row carries the only quiet accent edge (left).
            .background = is_recommended,
            .color_fill = if (is_recommended) theme.colors.bg_elevated else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_border = theme.colors.accent,
            .border = if (is_recommended) .{ .x = 2, .y = 0, .w = 0, .h = 0 } else dvui.Rect.all(0),
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            .margin = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
        });
        defer card.deinit();

        // Name + metadata column.
        {
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = ci + 9650,
                .expand = .horizontal,
                .gravity_y = 0.5,
            });
            defer col.deinit();

            _ = dvui.label(@src(), "{s}", .{name}, .{
                .id_extra = ci + 9800,
                .expand = .horizontal,
                .color_text = theme.colors.text_primary,
            });

            // One muted metadata line: pct · source · quality · seeds.
            {
                var meta_buf: [96]u8 = undefined;
                var w: usize = 0;
                const appendStr = struct {
                    fn f(buf: []u8, pos: *usize, s: []const u8) void {
                        if (pos.* > 0) {
                            const sep = " · ";
                            const n0 = @min(sep.len, buf.len - pos.*);
                            @memcpy(buf[pos.*..][0..n0], sep[0..n0]);
                            pos.* += n0;
                        }
                        const n = @min(s.len, buf.len - pos.*);
                        @memcpy(buf[pos.*..][0..n], s[0..n]);
                        pos.* += n;
                    }
                }.f;

                var pct_buf: [8]u8 = undefined;
                const pct_str = std.fmt.bufPrint(&pct_buf, "{d}%", .{item.match_pct}) catch "";
                if (pct_str.len > 0) appendStr(&meta_buf, &w, pct_str);
                appendStr(&meta_buf, &w, source_label(item.source));
                const qlbl = quality_label(item.quality);
                if (qlbl.len > 0) appendStr(&meta_buf, &w, qlbl);
                if (item.seeds > 0) {
                    var seed_buf: [16]u8 = undefined;
                    const seed_str = std.fmt.bufPrint(&seed_buf, "{d} seeds", .{item.seeds}) catch "";
                    if (seed_str.len > 0) appendStr(&meta_buf, &w, seed_str);
                }

                _ = dvui.label(@src(), "{s}", .{meta_buf[0..w]}, .{
                    .id_extra = ci + 9900,
                    .color_text = theme.colors.text_muted,
                });
            }
        }

        // Queue — borderless quiet action.
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.plus, .{}, .{}, .{
            .id_extra = ci + 10400,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.text_secondary,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = theme.spacing.xs, .y = theme.spacing.xs, .w = theme.spacing.xs, .h = theme.spacing.xs },
            .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
            .min_size_content = .{ .w = 14, .h = 14 },
            .gravity_y = 0.5,
            .border = dvui.Rect.all(0),
        })) {
            queueChatResult(ci);
        }

        // Play — accent action.
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.play, .{}, .{}, .{
            .id_extra = ci + 10100,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.accent,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = theme.spacing.xs, .y = theme.spacing.xs, .w = theme.spacing.xs, .h = theme.spacing.xs },
            .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
            .min_size_content = .{ .w = 14, .h = 14 },
            .gravity_y = 0.5,
            .border = dvui.Rect.all(0),
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
        .local => "local",
        .tmdb => "tmdb",
        .comics => "comics",
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
    if (is_generating.load(.acquire)) return;
    if (messages[assistant_idx].role != .assistant) return;
    // Need a user message before it.
    if (assistant_idx == 0 or messages[assistant_idx - 1].role != .user) return;

    // Clear just the assistant's text — keep the slot, generateResponse
    // writes into the last assistant slot.
    messages[assistant_idx].text_len = 0;
    // Trim everything after (tool-call tails, etc.)
    message_count = assistant_idx + 1;

    is_generating.store(true, .release);
    phase = .waiting_server;
    last_error_len = 0;

    llm_thread = std.Thread.spawn(.{}, ai_context.generateResponse, .{}) catch {
        is_generating.store(false, .release);
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
    if (input_len == 0 or is_generating.load(.acquire)) return;

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
    is_generating.store(true, .release);
    last_error_len = 0;

    llm_thread = std.Thread.spawn(.{}, ai_context.generateResponse, .{}) catch {
        is_generating.store(false, .release);
        if (message_count > 0) message_count -= 1;
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

/// Surface a generation failure *inside* the assistant bubble (not just the
/// log / last_error), so a failed reply shows the user why instead of leaving
/// a silent blank bubble. `assistant_idx` is the pre-created assistant slot.
pub fn setAssistantError(assistant_idx: usize, err: []const u8) void {
    setError(err);
    if (assistant_idx >= MAX_MESSAGES) return;
    const elen = @min(err.len, MAX_MSG_LEN);
    messages[assistant_idx].role = .assistant;
    @memcpy(messages[assistant_idx].text[0..elen], err[0..elen]);
    messages[assistant_idx].text_len = elen;
}

// ── Voice callback: ASR result → chat input ──
fn onTranscribed(transcribed: []const u8) void {
    if (message_count >= MAX_MESSAGES) return;
    if (is_generating.load(.acquire)) return; // prevent overlap
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
        });
        defer chat_win.deinit();

        // Header — also the draggable region
        {
            var ctx_hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
                .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
                .color_border = theme.colors.divider,
            });

            // Make header the drag area so user can reposition the window
            chat_win.dragAreaSet(ctx_hdr.data().borderRectScale().r);

            _ = dvui.icon(@src(), "", icons.tvg.lucide.bot, .{}, .{
                .color_text = theme.colors.accent,
                .min_size_content = .{ .w = 14, .h = 14 },
                .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
                .gravity_y = 0.5,
            });

            // Read what's playing
            const state_mod = @import("../core/state.zig");
            if (state_mod.app.active_player_idx < state_mod.app.players.items.len) {
                const ap = state_mod.app.players.items[state_mod.app.active_player_idx];
                var name_buf: [128]u8 = undefined;
                var curr_title: []const u8 = "Media";

                const path = &ap.current_url;
                const path_len = std.mem.indexOfScalar(u8, path, 0) orelse path.len;
                if (path_len > 0) {
                    const basename = std.fs.path.basename(path[0..path_len]);
                    const safe_len = @min(basename.len, 128);
                    @memcpy(name_buf[0..safe_len], basename[0..safe_len]);
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
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.x, .{}, .{}, .{
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
