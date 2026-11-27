const std = @import("std");
const dvui = @import("dvui");
const c = @import("../../core/c.zig");
const components = @import("../components.zig");
const state = @import("../../core/state.zig");
const theme = @import("../theme.zig");
const settings = @import("../settings.zig");
const labelText = settings.labelText;
const mutedText = settings.mutedText;
const openExternal = settings.openExternal;
const sectionHeader = settings.sectionHeader;
const settingRow = settings.settingRow;

pub fn renderPlaybackTab() void {
    // One accent, token fills. `btn_*` kept for the few primary actions that
    // remain in this tab (download / install). Inactive segments are handled
    // by components.segment() now.
    const btn_active = theme.colors.accent;
    const btn_inactive = theme.colors.bg_elevated;
    const btn_text_active = theme.colors.text_on_accent;

    // ── Video Processing ──
    sectionHeader("Video Processing", "GPU acceleration and image quality", 20, @src());

    // HW Decode — neutral toggle row; applies mpv option on change. Android
    // always decodes in software (hwdec_feedback_pure.optionValue, #229), so
    // the toggle would do nothing there.
    if (comptime @import("builtin").abi.isAndroid()) {
        components.bodyText(@src(), "Hardware decoding is off on Android: the player decodes in software.", theme.colors.text_secondary);
    } else {
        const before = state.app.hwdec_enabled;
        components.toggleRow(@src(), "Hardware Decoding", "GPU video decode (auto)", &state.app.hwdec_enabled);
        if (state.app.hwdec_enabled != before) {
            for (state.app.players.items) |p| {
                _ = c.mpv.mpv_set_option_string(p.mpv_ctx, "hwdec", @import("../../player/hwdec_feedback_pure.zig").optionValue(state.app.hwdec_enabled, @import("builtin").abi.isAndroid(), false));
            }
            state.markConfigDirty();
        }
    }

    // Deband — neutral toggle row; applies mpv option on change.
    {
        const before = state.app.deband_enabled;
        components.toggleRow(@src(), "Deband Filter", "Smooth color banding", &state.app.deband_enabled);
        if (state.app.deband_enabled != before) {
            for (state.app.players.items) |p| {
                _ = c.mpv.mpv_set_option_string(p.mpv_ctx, "deband", if (state.app.deband_enabled) "yes" else "no");
            }
            state.markConfigDirty();
        }
    }

    // Auto-Advance toggle row — pure bool flip, no side effects.
    {
        const before = state.app.auto_advance;
        components.toggleRow(@src(), "Auto-Advance", "Play next on end", &state.app.auto_advance);
        if (state.app.auto_advance != before) state.markConfigDirty();
    }

    // ── Skip intros & credits ── (any media). Sources, by priority:
    // anime-skip.com crowdsourced markers (anime) > chapter titles > intros /
    // credits matched across a season's local episodes by audio fingerprint.
    // Replaces the old anime-only "Auto-Skip (Anime)" toggle; its config key
    // anime_skip_enabled is kept in sync (= mode != Off) for older builds.
    sectionHeader("Skip Intros & Credits", "anime-skip.com, chapter titles, or matched across a season's episodes", 24, @src());
    settingRow("Skip intros & credits", 251, @src());
    {
        const skip_policy = @import("../../services/skip_policy_pure.zig");
        const opts = [_][]const u8{ skip_policy.modeLabel(.off), skip_policy.modeLabel(.button), skip_policy.modeLabel(.auto) };
        if (components.segment(@src(), &opts, @min(state.app.skip_mode, 2))) |picked| {
            const m = skip_policy.modeFromInt(@intCast(picked));
            if (@backingInt(m) != state.app.skip_mode) {
                state.app.skip_mode = @backingInt(m);
                state.app.skip_mode_loaded = true;
                state.app.anime_skip_enabled = skip_policy.legacyEnabled(m);
                state.markConfigDirty();
            }
        }
    }
    if (state.app.skip_mode == 2) {
        {
            const before = state.app.anime_skip_intro;
            components.toggleRow(@src(), "Skip Intro", "Opening / OP", &state.app.anime_skip_intro);
            if (state.app.anime_skip_intro != before) state.markConfigDirty();
        }
        {
            const before = state.app.anime_skip_recap;
            components.toggleRow(@src(), "Skip Recap", "\"Previously on…\" segments", &state.app.anime_skip_recap);
            if (state.app.anime_skip_recap != before) state.markConfigDirty();
        }
        {
            const before = state.app.anime_skip_credits;
            components.toggleRow(@src(), "Skip Credits", "Ending / ED (otherwise a Next episode button)", &state.app.anime_skip_credits);
            if (state.app.anime_skip_credits != before) state.markConfigDirty();
        }
        {
            const before = state.app.anime_skip_preview;
            components.toggleRow(@src(), "Skip Preview", "Next-episode preview", &state.app.anime_skip_preview);
            if (state.app.anime_skip_preview != before) state.markConfigDirty();
        }
    }

    // Video Scaler — segment.
    settingRow("Video Scaler", 250, @src());
    {
        const sn = [_][]const u8{ "EWA Lanczos (HQ)", "Bilinear (Fast)", "Spline36" };
        const sv = [_][]const u8{ "ewa_lanczossharp", "bilinear", "spline36" };
        const sel: usize = @intCast(@min(state.app.video_scaler, sn.len - 1));
        if (components.segment(@src(), &sn, sel)) |clicked| {
            state.app.video_scaler = @intCast(clicked);
            for (state.app.players.items) |p| {
                _ = c.mpv.mpv_set_option_string(p.mpv_ctx, "scale", @ptrCast(sv[clicked].ptr));
            }
            state.markConfigDirty();
        }
    }

    // ── Audio Equalizer ──
    sectionHeader("Audio Equalizer", "Quick presets for different content types", 22, @src());
    {
        const av_pure = @import("../../player/av_pure.zig");
        const en = [_][]const u8{ "Flat", "Bass+", "Voice", "Cinema", "Loud" };
        const sel: usize = @min(state.app.eq_preset, en.len - 1);
        if (components.segment(@src(), &en, sel)) |clicked| {
            state.app.eq_preset = clicked;
            // Same spec that player.zig replays at init (shared av_pure mapping).
            var eq_buf: [96]u8 = undefined;
            const eq_cmd = @import("opal-fmt").bufPrintZ(&eq_buf, "af set \"{s}\"", .{av_pure.eqFilterSpec(clicked)}) catch "af set \"\"";
            for (state.app.players.items) |p| {
                _ = c.mpv.mpv_command_string(p.mpv_ctx, eq_cmd.ptr);
            }
            state.markConfigDirty();
        }
    }

    // ── Playback extras ──
    // Upstream-mpv options, each off by default because each trades something.
    // They take effect on the NEXT file opened: mpv reads them as options at
    // player init, and re-applying them live would mean tearing down the audio
    // chain mid-playback.
    sectionHeader("Playback Extras", "Applied to the next file you open", 25, @src());
    {
        const before_pf = state.app.prefetch_playlist;
        components.toggleRow(@src(), "Prefetch next in playlist", "Instant next-episode start. Costs a second concurrent download — on a torrent, a whole extra swarm.", &state.app.prefetch_playlist);
        const before_pt = state.app.audio_passthrough;
        components.toggleRow(@src(), "Audio passthrough (AC3/DTS/E-AC3)", "Bitstream to an AV receiver instead of decoding. Silence if your output cannot decode it. TrueHD/Atmos needs a patched mpv and is not offered.", &state.app.audio_passthrough);
        const before_ex = state.app.audio_exclusive;
        components.toggleRow(@src(), "Exclusive audio device", "Bit-perfect output. Nothing else on the machine can make a sound while a player is open.", &state.app.audio_exclusive);
        if (before_pf != state.app.prefetch_playlist or
            before_pt != state.app.audio_passthrough or
            before_ex != state.app.audio_exclusive)
        {
            state.markConfigDirty();
            state.showToast("Applies to the next file you open");
        }
    }
    // ── Audio Output ──
    sectionHeader("Audio Output", "Route sound to a specific output device", 26, @src());
    {
        const av_device = @import("../../player/av_device_pure.zig");
        // Device list + active device, cached: `audio-device-list` is a
        // blocking mpv query and this tab renders every frame while open.
        // JSON parsing is pure and unit-tested (av_device_pure.zig).
        const Cache = struct {
            var last_ms: i64 = 0;
            var ctx_key: usize = 0;
            var devices: [av_device.max_devices]av_device.AudioDevice = undefined;
            var count: usize = 0;
            var cur_buf: [av_device.name_cap]u8 = undefined;
            var cur_len: usize = 0;
        };
        if (state.app.active_player_idx < state.app.players.items.len) {
            const ap = state.app.players.items[state.app.active_player_idx];
            const now = @import("../../core/io_global.zig").milliTimestamp();
            const key = @intFromPtr(ap.mpv_ctx);
            if (!(Cache.ctx_key == key and now - Cache.last_ms < 1000)) {
                Cache.ctx_key = key;
                Cache.last_ms = now;
                Cache.count = 0;
                const list_c = c.mpv.mpv_get_property_string(ap.mpv_ctx, "audio-device-list");
                if (list_c != null) {
                    Cache.count = av_device.parseAudioDevices(std.mem.span(list_c), &Cache.devices);
                    c.mpv.mpv_free(@ptrCast(list_c));
                }
                Cache.cur_len = 0;
                const cur_c = c.mpv.mpv_get_property_string(ap.mpv_ctx, "audio-device");
                if (cur_c != null) {
                    const span = std.mem.span(cur_c);
                    const n = @min(span.len, Cache.cur_buf.len);
                    @memcpy(Cache.cur_buf[0..n], span[0..n]);
                    Cache.cur_len = n;
                    c.mpv.mpv_free(@ptrCast(cur_c));
                }
            }
            const cur: []const u8 = if (Cache.cur_len > 0) Cache.cur_buf[0..Cache.cur_len] else "auto";
            var di: usize = 0;
            while (di < Cache.count) : (di += 1) {
                const d = &Cache.devices[di];
                const is_cur = std.mem.eql(u8, cur, d.nameSlice());
                if (dvui.button(@src(), @import("../../core/text.zig").safeUtf8(d.label()), .{}, .{
                    .id_extra = di + 3300,
                    .expand = .horizontal,
                    .color_fill = @import("../color_compat.zig").wrap(if (is_cur) btn_inactive else theme.transparent),
                    .color_text = @import("../color_compat.zig").wrap(if (is_cur) theme.colors.accent else labelText()),
                    .color_fill_hover = @import("../color_compat.zig").wrap(theme.colors.bg_hover),
                    .color_fill_press = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
                    .border = dvui.Rect.all(0),
                    .corners = theme.dims.rad_sm,
                    .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
                    .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
                })) {
                    var name_z: [av_device.name_cap + 1]u8 = undefined;
                    @memcpy(name_z[0..d.name_len], d.name[0..d.name_len]);
                    name_z[d.name_len] = 0;
                    for (state.app.players.items) |p| {
                        _ = c.mpv.mpv_set_property_string(p.mpv_ctx, "audio-device", @ptrCast(&name_z));
                    }
                    @memset(&state.app.audio_device_buf, 0);
                    @memcpy(state.app.audio_device_buf[0..d.name_len], d.name[0..d.name_len]);
                    state.app.audio_device_len = d.name_len;
                    state.markConfigDirty();
                    @memcpy(Cache.cur_buf[0..d.name_len], d.name[0..d.name_len]);
                    Cache.cur_len = d.name_len;
                    var toast_buf: [192]u8 = undefined;
                    const msg = std.fmt.bufPrint(&toast_buf, "Audio output: {s}", .{d.label()}) catch "Audio output changed";
                    state.showToast(msg);
                }
            }
            if (Cache.count == 0) {
                _ = dvui.label(@src(), "No output devices reported yet.", .{}, .{ .id_extra = 3390, .color_text = @import("../color_compat.zig").wrap(mutedText()) });
            }
        } else {
            _ = dvui.label(@src(), "Open a player to pick an output device.", .{}, .{ .id_extra = 3391, .color_text = @import("../color_compat.zig").wrap(mutedText()) });
        }
    }

    // ── Streaming ──
    sectionHeader("Streaming", "yt-dlp backend for web streams", 23, @src());

    settingRow("Stream Quality", 230, @src());
    {
        const qn = [_][]const u8{ "720p", "1080p", "4K", "Audio" };
        const sel: usize = @min(state.app.ytdl_format_idx, qn.len - 1);
        if (components.segment(@src(), &qn, sel)) |clicked| {
            state.app.ytdl_format_idx = clicked;
            for (state.app.players.items) |p| {
                p.applyYtdlFormat();
            }
            state.markConfigDirty();
        }
    }
    // yt-dlp status + version + actions
    {
        const ytdlp = @import("../../services/ytdlp.zig");
        ytdlp.ensureVersion(); // kick a one-shot background `--version` query
        const btn_opts = dvui.Options{ .color_fill = @import("../color_compat.zig").wrap(btn_inactive), .color_text = @import("../color_compat.zig").wrap(theme.colors.accent), .border = dvui.Rect.all(0), .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs }, .corners = theme.dims.rad_md };

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        _ = dvui.label(@src(), "yt-dlp", .{}, .{ .color_text = @import("../color_compat.zig").wrap(labelText()), .gravity_y = 0.5 });

        // Version (when resolved).
        if (ytdlp.versionReady() and ytdlp.versionString().len > 0) {
            var vb: [40]u8 = undefined;
            const v = std.fmt.bufPrint(&vb, "v{s}", .{ytdlp.versionString()}) catch "";
            _ = dvui.label(@src(), "{s}", .{v}, .{ .id_extra = 2903, .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary), .gravity_y = 0.5, .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 } });
        }

        {
            var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            spacer.deinit();
        }

        if (ytdlp.isDownloading()) {
            components.statusPill("Updating", .info);
            components.pollRefresh(100_000);
        } else if (!ytdlp.versionReady()) {
            components.statusPill("Checking…", .info);
            components.pollRefresh(100_000);
        } else if (ytdlp.versionString().len > 0) {
            // Works (system or bundled).
            components.statusPill("Installed", .success);
            if (dvui.button(@src(), "Open folder", .{}, btn_opts.override(.{ .id_extra = 2904 }))) {
                var db: [512]u8 = undefined;
                openExternal(ytdlp.binaryDir(&db));
            }
            if (dvui.button(@src(), "Update", .{}, btn_opts.override(.{ .id_extra = 2901 }))) {
                ytdlp.update();
            }
        } else {
            components.statusPill("Not installed", .warn);
            if (dvui.button(@src(), "Download", .{}, .{ .id_extra = 2902, .color_fill = @import("../color_compat.zig").wrap(btn_active), .color_text = @import("../color_compat.zig").wrap(btn_text_active), .border = dvui.Rect.all(0), .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs }, .corners = theme.dims.rad_md })) {
                ytdlp.ensureAvailable();
            }
        }
    }
    // yt-dlp path (small, for transparency + so "Open folder" is unambiguous).
    {
        const ytdlp = @import("../../services/ytdlp.zig");
        _ = dvui.label(@src(), "{s}", .{ytdlp.binary()}, .{
            .id_extra = 2910,
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.xs },
        });
    }
    _ = dvui.label(@src(), "Install operation: HTTPS curl to staged file › SHA-256 verification › --version probe › publish.", .{}, .{ .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary) });

    // ── Keyboard Shortcuts ── (quiet text, no card chrome)
    sectionHeader("Keyboard Shortcuts", "", 21, @src());
    {
        _ = dvui.label(@src(), "Space=Pause  Arrows=Seek  Up/Down=Vol  M=Mute", .{}, .{ .id_extra = 2100, .color_text = @import("../color_compat.zig").wrap(mutedText()) });
        _ = dvui.label(@src(), "+/-=Zoom  0=Reset  Shift+Arrows=Pan", .{}, .{ .id_extra = 2101, .color_text = @import("../color_compat.zig").wrap(mutedText()) });
        _ = dvui.label(@src(), "V=Subs  K=SubDelay  Ctrl+=/-=AudioDelay  []=Speed  L=Loop  R=Rotate  T=Flip", .{}, .{ .id_extra = 2102, .color_text = @import("../color_compat.zig").wrap(mutedText()) });
        _ = dvui.label(@src(), "A=AI  D=Drawer/Library  Shift+I=Shortcuts  Ctrl+I=Info  Ctrl+O=Open  Ctrl+Q=Quit", .{}, .{ .id_extra = 2103, .color_text = @import("../color_compat.zig").wrap(mutedText()) });
    }

    // ── Video Filters ── (no card chrome)
    sectionHeader("Video Filters", "Brightness, contrast, saturation, gamma", 24, @src());
    {
        const av_pure = @import("../../player/av_pure.zig");
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.sm },
        });
        defer card.deinit();

        // Each filter: label + step buttons
        const filters = [_]struct { name: []const u8, prop: []const u8, idx: usize }{
            .{ .name = "Brightness", .prop = "brightness", .idx = 0 },
            .{ .name = "Contrast", .prop = "contrast", .idx = 1 },
            .{ .name = "Saturation", .prop = "saturation", .idx = 2 },
            .{ .name = "Gamma", .prop = "gamma", .idx = 3 },
        };

        // The persisted state field backing each filter row, by idx. Written by
        // the ± buttons and replayed at player init (player.zig), so filters now
        // survive restart / apply to newly-opened files.
        const VF = struct {
            fn field(idx: usize) *i32 {
                return switch (idx) {
                    0 => &state.app.vf_brightness,
                    1 => &state.app.vf_contrast,
                    2 => &state.app.vf_saturation,
                    else => &state.app.vf_gamma,
                };
            }
        };

        for (filters) |f| {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = f.idx + 3000,
                .expand = .horizontal,
                .padding = .{ .x = 0, .y = theme.spacing.xxs, .w = 0, .h = theme.spacing.xxs },
            });
            defer row.deinit();

            _ = dvui.label(@src(), "{s}", .{f.name}, .{
                .id_extra = f.idx + 3010,
                .color_text = @import("../color_compat.zig").wrap(labelText()),
                .min_size_content = .{ .w = 90, .h = 0 },
                .gravity_y = 0.5,
            });

            // "−" button
            if (dvui.button(@src(), "−", .{}, .{
                .id_extra = f.idx + 3020,
                .color_fill = @import("../color_compat.zig").wrap(btn_inactive),
                .color_text = @import("../color_compat.zig").wrap(mutedText()),
                .border = dvui.Rect.all(0),
                .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
                .corners = theme.dims.rad_sm,
                .margin = .{ .x = theme.spacing.xs, .y = 0, .w = theme.spacing.xxs, .h = 0 },
            })) {
                const fld = VF.field(f.idx);
                fld.* = av_pure.clampVideoFilter(fld.* - 5);
                for (state.app.players.items) |pl| @import("../../player/player.zig").applyVideoGrade(pl);
                state.markConfigDirty();
            }

            // Current value — throttled: mpv property reads take the core lock
            // synchronously, and 4 per frame while Settings sat open added
            // frame-time jitter to active playback. Refresh at most ~4×/s
            // (clicks read fresh next tick anyway).
            {
                // The manual offset lives in state (mpv's eq props are no-ops
                // under SW render), so read it directly — no mpv IPC.
                const val: i32 = VF.field(f.idx).*;
                var val_buf: [12]u8 = undefined;
                const val_str = @import("opal-fmt").bufPrintZ(&val_buf, "{d}", .{val}) catch "0";
                _ = dvui.label(@src(), "{s}", .{val_str}, .{
                    .id_extra = f.idx + 3030,
                    .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
                    .min_size_content = .{ .w = 30, .h = 0 },
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                });
            }

            // "+" button
            if (dvui.button(@src(), "+", .{}, .{
                .id_extra = f.idx + 3040,
                .color_fill = @import("../color_compat.zig").wrap(btn_inactive),
                .color_text = @import("../color_compat.zig").wrap(mutedText()),
                .border = dvui.Rect.all(0),
                .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
                .corners = theme.dims.rad_sm,
                .margin = .{ .x = theme.spacing.xxs, .y = 0, .w = 0, .h = 0 },
            })) {
                const fld = VF.field(f.idx);
                fld.* = av_pure.clampVideoFilter(fld.* + 5);
                for (state.app.players.items) |pl| @import("../../player/player.zig").applyVideoGrade(pl);
                state.markConfigDirty();
            }
        }

        // Reset all button
        components.divider();
        if (dvui.button(@src(), "Reset All Filters", .{}, .{
            .id_extra = 3099,
            .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
            .color_text = @import("../color_compat.zig").wrap(theme.colors.danger),
            .border = dvui.Rect.all(0),
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
            .corners = theme.dims.rad_md,
        })) {
            state.app.vf_brightness = 0;
            state.app.vf_contrast = 0;
            state.app.vf_saturation = 0;
            state.app.vf_gamma = 0;
            for (state.app.players.items) |pl| @import("../../player/player.zig").applyVideoGrade(pl);
            state.markConfigDirty();
        }
    }

    // ── Capture ── (no card chrome)
    sectionHeader("Capture", "Screenshot and clip export", 25, @src());
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 },
        });
        defer row.deinit();

        // Screenshot button — the single primary action.
        if (dvui.button(@src(), "Screenshot (P)", .{}, .{
            .id_extra = 3200,
            .color_fill = @import("../color_compat.zig").wrap(btn_active),
            .color_text = @import("../color_compat.zig").wrap(btn_text_active),
            .border = dvui.Rect.all(0),
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
            .corners = theme.dims.rad_md,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        })) {
            if (state.app.active_player_idx < state.app.players.items.len) {
                _ = c.mpv.mpv_command_string(state.app.players.items[state.app.active_player_idx].mpv_ctx, "screenshot");
                state.showToast("Screenshot saved");
            }
        }

        // Screenshot without subs
        if (dvui.button(@src(), "Screenshot (no subs)", .{}, .{
            .id_extra = 3201,
            .color_fill = @import("../color_compat.zig").wrap(btn_inactive),
            .color_text = @import("../color_compat.zig").wrap(mutedText()),
            .border = dvui.Rect.all(0),
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
            .corners = theme.dims.rad_md,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        })) {
            if (state.app.active_player_idx < state.app.players.items.len) {
                _ = c.mpv.mpv_command_string(state.app.players.items[state.app.active_player_idx].mpv_ctx, "screenshot video");
                state.showToast("Screenshot (video-only) saved");
            }
        }

        // Clip export
        {
            const has_loop = if (state.app.active_player_idx < state.app.players.items.len) blk: {
                const ap = state.app.players.items[state.app.active_player_idx];
                break :blk ap.loop_a >= 0 and ap.loop_b >= 0;
            } else false;

            const clip_label = if (has_loop) "Export Clip" else "Clip (L › set loop)";
            if (dvui.button(@src(), clip_label, .{}, .{
                .id_extra = 3202,
                .color_fill = @import("../color_compat.zig").wrap(if (has_loop) btn_active else btn_inactive),
                .color_text = @import("../color_compat.zig").wrap(if (has_loop) btn_text_active else mutedText()),
                .border = dvui.Rect.all(0),
                .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
                .corners = theme.dims.rad_md,
            })) {
                if (state.app.active_player_idx < state.app.players.items.len) {
                    state.app.players.items[state.app.active_player_idx].exportClip();
                }
            }
        }
    }
}
