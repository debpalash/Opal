const dvui = @import("dvui");
const c = @import("../../core/c.zig");
const components = @import("../components.zig");
const state = @import("../../core/state.zig");
const theme = @import("../theme.zig");
const settings = @import("../settings.zig");
const langSegment = settings.langSegment;
const settingRow = settings.settingRow;
const ttsSpeedSegment = settings.ttsSpeedSegment;
const ttsVoiceSegment = settings.ttsVoiceSegment;

pub fn renderLangLearnTab() void {
    // Language Learning Mode toggle — flips a bool then runs onToggle.
    {
        const before = state.app.lang_learn_enabled;
        components.toggleRow(@src(), "Language Learning Mode", "ASR + dubbing + translation while watching", &state.app.lang_learn_enabled);
        if (state.app.lang_learn_enabled != before) {
            const lang_learn = @import("../../services/lang_learn.zig");
            lang_learn.onToggle(state.app.lang_learn_enabled);
            state.markConfigDirty();
        }
    }

    // Translation Target Language — segment.
    settingRow("Translate To", 64, @src());
    langSegment(&state.app.translate_lang_buf, &state.app.translate_lang_len, 200);

    // Translation toggle — pure bool flip.
    {
        const before = state.app.translate_enabled;
        components.toggleRow(@src(), "Translation", "Enable subtitle translation", &state.app.translate_enabled);
        if (state.app.translate_enabled != before) state.markConfigDirty();
    }

    // Subtitle Track Selector — stateless setter (issues mpv commands).
    settingRow("Active Subtitle Track", 65, @src());
    {
        if (state.app.active_player_idx < state.app.players.items.len) {
            const p = state.app.players.items[state.app.active_player_idx];
            const track_labels = [_][]const u8{ "None", "Track 1", "Track 2", "Track 3", "Track 4", "Track 5" };
            // No persisted selection here — leave nothing highlighted.
            if (components.segment(@src(), &track_labels, track_labels.len)) |clicked| {
                var cmd_buf: [64]u8 = undefined;
                if (clicked == 0) {
                    _ = c.mpv.mpv_command_string(p.mpv_ctx, "set sid no");
                    state.app.subtitles_enabled = false;
                } else {
                    if (@import("opal-fmt").bufPrintZ(&cmd_buf, "set sid {d}", .{clicked})) |cmd| {
                        _ = c.mpv.mpv_command_string(p.mpv_ctx, cmd.ptr);
                    } else |_| {}
                    _ = c.mpv.mpv_command_string(p.mpv_ctx, "set sub-visibility yes");
                    state.app.subtitles_enabled = true;
                }
                state.markConfigDirty();
            }
        } else {
            _ = dvui.label(@src(), "No active player", .{}, .{ .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary) });
        }
    }

    // ASR toggle — pure bool flip (hint shown inline).
    {
        const before = state.app.asr_enabled;
        components.toggleRow(@src(), "Speech Recognition (ASR)", "Auto-transcribe audio when no subtitles available (Cohere 2B)", &state.app.asr_enabled);
        if (state.app.asr_enabled != before) state.markConfigDirty();
    }

    // Audio Dubbing toggle — bool flip + reset dub hash on enable.
    {
        const before = state.app.dubbing_enabled;
        components.toggleRow(@src(), "Audio Dubbing", "Translate subtitles and speak via TTS (lowers video volume)", &state.app.dubbing_enabled);
        if (state.app.dubbing_enabled != before) {
            if (state.app.dubbing_enabled) state.app.dub_last_hash = 0;
            state.markConfigDirty();
        }
    }

    // Voice Selector — segment.
    settingRow("TTS Voice", 61, @src());
    ttsVoiceSegment(0);

    // Speed Control — segment.
    settingRow("Speech Speed", 62, @src());
    ttsSpeedSegment(0);

    // Server Status
    settingRow("TTS Server", 63, @src());
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .gravity_y = 0.5,
        });
        defer row.deinit();

        if (state.app.tts_server_ok) {
            components.statusPill("Running", .success);
        } else {
            components.statusPill("Not running", .info);
        }

        {
            var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            spacer.deinit();
        }

        const lang_learn = @import("../../services/lang_learn.zig");
        if (!state.app.tts_server_ok) {
            if (dvui.button(@src(), "Start Server", .{}, .{
                .color_fill = @import("../color_compat.zig").wrap(theme.colors.accent),
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_on_accent),
                .border = dvui.Rect.all(0),
                .corners = theme.dims.rad_md,
                .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
            })) {
                lang_learn.startServer();
            }
        } else {
            if (dvui.button(@src(), "Stop Server", .{}, .{
                .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
                .color_text = @import("../color_compat.zig").wrap(theme.colors.danger),
                .border = dvui.Rect.all(0),
                .corners = theme.dims.rad_md,
                .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
            })) {
                lang_learn.stopServer();
            }
        }
    }
    _ = dvui.label(@src(), "KittenTTS (80MB) | Cohere ASR (2B) | Google Translate", .{}, .{
        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
    });
}
