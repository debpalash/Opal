const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const components = @import("../components.zig");
const state = @import("../../core/state.zig");
const theme = @import("../theme.zig");
const settings = @import("../settings.zig");
const labelText = settings.labelText;
const mutedText = settings.mutedText;

/// The AI & Voice control sections themselves — reused by BOTH the legacy
/// .assistant route (via renderAIContent) and the Settings › AI & Voice tab
/// (which supplies its own bigTitle + scroll + centred column, so this must
/// NOT add its own chrome). This is why the "Assistant" nav entry could move
/// into Settings without duplicating the page.
pub fn renderAIContentBody() void {
    // ── Voice Backend ──
    aiSectionWithIcon(icons.tvg.lucide.mic, "Voice Backend", "STT + TTS engine for mic / conversation mode", 24, @src());
    {
        const vb = @import("../../services/voice_backend.zig");
        {
            var choices = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal });
            defer choices.deinit();
            for (vb.allKinds(), 0..) |kind, i| {
                const name = switch (kind) {
                    .whisper_cpp_plus_say => "Whisper",
                    .sherpa_onnx => "Sherpa ONNX",
                    .apple_native => "Apple voice",
                    .speaches => "Speaches",
                    .mlx_whisper => "MLX Whisper",
                    .parakeet_tdt_v2 => "Parakeet v2 · EN",
                    .parakeet_tdt_v3 => "Parakeet v3",
                };
                var wd: dvui.WidgetData = undefined;
                if (dvui.button(@src(), name, .{}, .{
                    .id_extra = 4000 + i,
                    .data_out = &wd,
                    .color_fill = @import("../color_compat.zig").wrap(if (kind == vb.active_kind) theme.colors.bg_elevated else theme.transparent),
                    .color_text = @import("../color_compat.zig").wrap(if (kind == vb.active_kind) theme.colors.accent else theme.colors.text_secondary),
                    .padding = dvui.Rect.all(theme.spacing.sm),
                    .margin = dvui.Rect.all(theme.spacing.xxs),
                    .corners = theme.dims.rad_sm,
                })) {
                    vb.active_kind = kind;
                    vb.voice_backend_explicit = true;
                    state.markConfigDirty();
                    state.showToast("Voice backend changed");
                }
                components.tipId(@src(), wd, vb.backendFor(kind).name, i);
            }
        }

        // MLX Whisper setup
        if (vb.active_kind == .mlx_whisper) {
            const deps = @import("../../core/deps.zig");
            const dep_status = deps.check();

            var mlx_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .margin = .{ .y = 6 },
                .padding = .{ .x = 20 },
            });
            defer mlx_row.deinit();

            if (dep_status.mlx_whisper_model and dep_status.mlx_whisper_cli) {
                components.statusPill("Ready", .success);
            } else if (deps.mlx_whisper_downloading) {
                // Worker-written buffer — snapshot + validate so a torn multi-
                // byte write ("Installing uv…") can't hand dvui invalid UTF-8.
                const status_len = std.mem.indexOfScalar(u8, &deps.mlx_whisper_status, 0) orelse 0;
                var status_snap: [128]u8 = undefined;
                const status_txt = if (status_len > 0) @import("../../core/text.zig").safeUtf8Buf(deps.mlx_whisper_status[0..status_len], &status_snap) else "Setting up…";
                _ = dvui.label(@src(), "{s}", .{status_txt}, .{
                    .color_text = @import("../color_compat.zig").wrap(theme.colors.warning),
                    .gravity_y = 0.5,
                });
                components.pollRefresh(100_000);
            } else {
                if (components.actionButton(@src(), "Set up (~1.6GB)", .primary, 4100)) {
                    deps.fetchMlxWhisperModelAsync();
                    state.showToast("Setting up MLX Whisper (venv + model)…");
                }
            }
        }
    }

    // ── Kokoro Voice Picker ──
    {
        const deps = @import("../../core/deps.zig");
        const vb = @import("../../services/voice_backend.zig");
        if (deps.check().sherpa_kokoro_model) {
            aiSectionWithIcon(icons.tvg.lucide.@"audio-lines", "Kokoro Voice", "Pick a speaker ID from the Kokoro pack (0–53)", 18, @src());
            // Calm: spacing-only row, no card chrome. −/+ steppers are neutral
            // bg_elevated fills; Preview is the single accent affordance.
            var kcard = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .padding = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = theme.spacing.sm },
            });
            defer kcard.deinit();

            var label_buf: [32]u8 = undefined;
            const lbl = std.fmt.bufPrint(&label_buf, "sid = {d}", .{vb.kokoro_sid}) catch "sid = ?";
            _ = dvui.label(@src(), "{s}", .{lbl}, .{
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
                .min_size_content = .{ .w = 80, .h = 0 },
                .gravity_y = 0.5,
            });

            if (dvui.button(@src(), "−", .{}, .{
                .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
                .border = dvui.Rect.all(0),
                .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                .corners = theme.dims.rad_sm,
                .margin = .{ .w = theme.spacing.xs },
                .gravity_y = 0.5,
            })) {
                if (vb.kokoro_sid > 0) {
                    vb.kokoro_sid -= 1;
                    state.markConfigDirty();
                }
            }
            if (dvui.button(@src(), "+", .{}, .{
                .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
                .border = dvui.Rect.all(0),
                .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                .corners = theme.dims.rad_sm,
                .margin = .{ .w = theme.spacing.xs },
                .gravity_y = 0.5,
            })) {
                if (vb.kokoro_sid < 53) {
                    vb.kokoro_sid += 1;
                    state.markConfigDirty();
                }
            }
            {
                var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
                sp.deinit();
            }
            if (dvui.button(@src(), "Preview", .{}, .{
                .color_fill = @import("../color_compat.zig").wrap(theme.colors.accent),
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_on_accent),
                .border = dvui.Rect.all(0),
                .padding = .{ .x = theme.spacing.lg, .y = theme.spacing.xs, .w = theme.spacing.lg, .h = theme.spacing.xs },
                .corners = theme.dims.rad_md,
                .gravity_y = 0.5,
            })) {
                const b = vb.active();
                b.speak("Opal voice preview.");
            }
        }
    }

    // ── Co-Watcher ── (voice-mode feature, so it lives with the voice engine.
    // The language-learning rows that used to sit here duplicated the whole
    // Settings › Language tab with drifted hint copy — they now live ONLY
    // there, one pointer row below.)

    // Proactive Co-Watcher sensitivity — the AI may speak ONE short, spoiler-
    // safe remark about what is on screen when you pause or rewind in voice
    // mode. Quiet by default; this control just assigns the module var.
    aiSectionWithIcon(icons.tvg.lucide.@"message-square-text", "Co-Watcher", "The AI comments while you watch (voice mode)", 60, @src());

    _ = dvui.label(@src(), "AI comments on what you missed when you pause or rewind (voice mode)", .{}, .{
        .id_extra = 651,
        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.sm },
    });
    {
        const co_watch = @import("../../services/co_watch.zig");
        const cw_labels = [_][]const u8{ "Off", "Quiet", "Balanced", "Chatty" };
        const sel: usize = switch (co_watch.sensitivity) {
            .off => 0,
            .quiet => 1,
            .balanced => 2,
            .chatty => 3,
        };
        if (components.segment(@src(), &cw_labels, sel)) |clicked| {
            co_watch.sensitivity = switch (clicked) {
                0 => .off,
                1 => .quiet,
                2 => .balanced,
                else => .chatty,
            };
            state.markConfigDirty();
        }
    }

    // Pointer to the single home of the language-learning controls.
    _ = dvui.label(@src(), "Subtitle translation, ASR, dubbing, and TTS voice live in Settings › Language.", .{}, .{
        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
        .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 },
    });

    // ── Models Management ──
    aiSectionWithIcon(icons.tvg.lucide.@"hard-drive", "Models & Dependencies", "Install, update, or remove AI models", 80, @src());
    // Opens the "Setup" checklist modal on demand. This used to auto-pop at
    // first run; it now lives here so it never nags at startup.
    {
        var cl_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.sm } });
        defer cl_row.deinit();
        if (components.actionButton(@src(), "Open setup checklist…", .secondary, 4101)) state.app.deps_modal_open = true;
    }
    {
        const deps = @import("../../core/deps.zig");
        const ds = deps.check();
        // Download sizes reflect the pinned upstream release assets.
        if (modelRow("Whisper Tiny (75MB)", icons.tvg.lucide.@"audio-waveform", ds.whisper_model, deps.whisper_model_downloading.load(.acquire), 5000, @src())) {
            deps.fetchWhisperModelAsync();
            state.showToast("Downloading Whisper Tiny (75 MB)");
        }
        if (modelRow("Sherpa STT (113MB)", icons.tvg.lucide.mic, ds.sherpa_model, deps.sherpa_model_downloading.load(.acquire), 5001, @src())) {
            deps.fetchSherpaWhisperAsync();
            state.showToast("Downloading Sherpa STT (113 MB)");
        }
        if (modelRow("Piper TTS (64MB)", icons.tvg.lucide.@"volume-2", ds.sherpa_tts_model, deps.sherpa_tts_downloading.load(.acquire), 5002, @src())) {
            deps.fetchSherpaTtsAsync();
            state.showToast("Downloading Piper TTS (64 MB)");
        }
        if (modelRow("Kokoro TTS (305MB)", icons.tvg.lucide.@"audio-lines", ds.sherpa_kokoro_model, deps.sherpa_kokoro_downloading.load(.acquire), 5003, @src())) {
            deps.fetchSherpaKokoroAsync();
            state.showToast("Downloading Kokoro TTS (305 MB)");
        }
        if (modelRow("Stream ASR (296MB)", icons.tvg.lucide.radio, ds.sherpa_stream_model, deps.sherpa_stream_downloading.load(.acquire), 5004, @src())) {
            deps.fetchSherpaStreamAsync();
            state.showToast("Downloading Stream ASR (296 MB)");
        }
        // MLX Whisper (~1.6GB): same card as every other model, with live status.
        {
            const mlx_installed = ds.mlx_whisper_model and ds.mlx_whisper_cli;
            var ssnap: [128]u8 = undefined;
            const st: ModelState = if (deps.mlx_whisper_downloading) blk: {
                const slen = std.mem.indexOfScalar(u8, &deps.mlx_whisper_status, 0) orelse 0;
                components.pollRefresh(100_000);
                break :blk .{ .busy = if (slen > 0) @import("../../core/text.zig").safeUtf8Buf(deps.mlx_whisper_status[0..slen], &ssnap) else "Setting up…" };
            } else if (mlx_installed) .installed else .{ .available = "Set up" };
            if (modelCard("MLX Whisper (1.6GB)", icons.tvg.lucide.cpu, st, 5005, @src())) {
                deps.fetchMlxWhisperModelAsync();
                state.showToast("Setting up MLX Whisper (venv + model)…");
            }
        }

        // NVIDIA Parakeet TDT — sherpa-onnx int8 exports (URLs verified
        // against the k2-fsa release assets). The largest Parakeet TDT with a
        // sherpa export is 0.6B; there is no 1.1b export.
        parakeetModelRow("Parakeet TDT 0.6B v2 · English (480MB)", ds.parakeet_v2_model, deps.parakeet_v2_downloading.load(.acquire), false, 5006);
        parakeetModelRow("Parakeet TDT 0.6B v3 · 25 languages (490MB)", ds.parakeet_v3_model, deps.parakeet_v3_downloading.load(.acquire), true, 5007);
    }
    _ = dvui.label(@src(), "Model operation: HTTPS curl › verify staged download › extract (archive models). MLX Whisper also installs uv, a Python venv, and mlx-whisper.", .{}, .{ .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary) });
}

/// One NVIDIA Parakeet model row (needs the sherpa-onnx CLI, like the sherpa rows).
fn parakeetModelRow(comptime name: []const u8, installed: bool, downloading: bool, v3: bool, id_extra: usize) void {
    const deps = @import("../../core/deps.zig");
    const st: ModelState = if (downloading) .{ .busy = "Downloading…" } else if (installed) .installed else .{ .available = "Download" };
    if (modelCard(name, icons.tvg.lucide.@"audio-waveform", st, id_extra, @src())) {
        deps.fetchParakeetAsync(v3);
        state.showToast("Downloading Parakeet TDT — watch the row for progress");
    }
}
fn aiSectionWithIcon(icon_data: anytype, comptime title: []const u8, comptime subtitle: []const u8, id_extra: usize, src: std.builtin.SourceLocation) void {
    var wrap = dvui.box(src, .{ .dir = .vertical }, .{ .id_extra = id_extra + 900, .expand = .horizontal });
    defer wrap.deinit();
    @import("../service_surfaces.zig").section(@src(), title, subtitle, icon_data);
}

const ModelState = union(enum) {
    installed,
    /// Live work (download / setup) with a short status line.
    busy: []const u8,
    /// Not installed; the label of the button that installs it.
    available: []const u8,
};

fn modelRow(comptime name: []const u8, icon_data: anytype, installed: bool, downloading: bool, id_extra: usize, src: std.builtin.SourceLocation) bool {
    const st: ModelState = if (downloading) .{ .busy = "Downloading…" } else if (installed) .installed else .{ .available = "Download" };
    return modelCard(name, icon_data, st, id_extra, src);
}

/// The one model row every entry uses: bordered card, icon, name, and a
/// right-aligned status column (Installed pill / spinner + status / button).
/// Returns true when the install button was clicked.
fn modelCard(name: []const u8, icon_data: anytype, st: ModelState, id_extra: usize, src: std.builtin.SourceLocation) bool {
    const installed = st == .installed;
    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = 30 },
        .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
        .margin = .{ .x = 0, .y = 3, .w = 0, .h = 3 },
        .background = true,
        .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_surface),
        .border = dvui.Rect.all(1),
        .color_border = @import("../color_compat.zig").wrap(theme.colors.border_subtle),
        .corners = theme.dims.rad_md,
    });
    defer row.deinit();

    dvui.icon(src, "", icon_data, .{}, .{
        .id_extra = id_extra + 10,
        .color_text = @import("../color_compat.zig").wrap(if (installed) theme.colors.accent else mutedText()),
        .min_size_content = theme.iconSize(.sm),
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = theme.spacing.md, .h = 0 },
    });
    _ = dvui.label(src, "{s}", .{name}, .{
        .id_extra = id_extra + 20,
        .expand = .horizontal,
        .color_text = @import("../color_compat.zig").wrap(labelText()),
        .gravity_y = 0.5,
    });
    var status = dvui.box(src, .{ .dir = .horizontal }, .{ .id_extra = id_extra + 30, .gravity_y = 0.5 });
    defer status.deinit();
    switch (st) {
        .installed => components.statusPill("Installed", .success),
        .busy => |text| {
            dvui.spinner(src, .{
                .id_extra = id_extra + 40,
                .color_text = @import("../color_compat.zig").wrap(theme.colors.warning),
                .min_size_content = theme.iconSize(.sm),
                .gravity_y = 0.5,
                .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
            });
            _ = dvui.label(src, "{s}", .{text}, .{
                .id_extra = id_extra + 50,
                .color_text = @import("../color_compat.zig").wrap(theme.colors.warning),
                .gravity_y = 0.5,
            });
        },
        .available => |label| return components.actionButton(src, label, .primary, id_extra + 60),
    }
    return false;
}
