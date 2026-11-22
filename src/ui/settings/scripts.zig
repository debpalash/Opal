const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const components = @import("../components.zig");
const state = @import("../../core/state.zig");
const theme = @import("../theme.zig");
const settings = @import("../settings.zig");
const labelText = settings.labelText;
const settingRow = settings.settingRow;

pub fn renderScriptsTab() void {
    const scripts = @import("../../services/scripts.zig");

    // Trigger scan on first open
    if (!state.app.scripts_scanned) {
        scripts.scanScripts();
    }

    // ── SponsorBlock Master Toggle ──
    {
        const before = state.app.sponsorblock_enabled;
        components.toggleRow(@src(), "SponsorBlock (YouTube)", "Auto-skip sponsor segments", &state.app.sponsorblock_enabled);
        if (state.app.sponsorblock_enabled != before) state.markConfigDirty();
    }

    // ── AI Backend picker ── (components.segment — the same single-select
    // grammar every other two-option setting uses; the old accent-text button
    // pair was one of four different pick-one idioms on this page)
    settingRow("AI Backend", 71, @src());
    {
        const ai_server = @import("../../services/ai_server.zig");
        ai_server.checkPaths(); // lazy detection — idempotent; not run at boot
        const set_backend = struct {
            fn apply(kind: @TypeOf(ai_server.backend_kind), toast: []const u8) void {
                const srv = @import("../../services/ai_server.zig");
                if (srv.backend_kind == kind) return;
                srv.stopServer();
                srv.backend_kind = kind;
                srv.resetDetection();
                state.markConfigDirty(); // ai_backend IS persisted — without this the switch reverted on restart
                state.showToast(toast);
            }
        };
        if (ai_server.is_macos) {
            const labels = [_][]const u8{ "Apple Intelligence", "Local LLM (Hugging Face)", "Cloud API" };
            const sel: usize = switch (ai_server.backend_kind) {
                .apfel => 0,
                .gemma_llama => 1,
                .cloud => 2,
            };
            if (components.segment(@src(), &labels, sel)) |clicked| {
                switch (clicked) {
                    0 => set_backend.apply(.apfel, "AI backend: Apple Intelligence"),
                    1 => set_backend.apply(.gemma_llama, "AI backend: Local LLM (Hugging Face)"),
                    else => set_backend.apply(.cloud, "AI backend: Cloud API"),
                }
            }
        } else {
            const labels = [_][]const u8{ "Local LLM (Hugging Face)", "Cloud API" };
            const sel: usize = if (ai_server.backend_kind == .cloud) 1 else 0;
            if (components.segment(@src(), &labels, sel)) |clicked| {
                if (clicked == 0)
                    set_backend.apply(.gemma_llama, "AI backend: Local LLM (Hugging Face)")
                else
                    set_backend.apply(.cloud, "AI backend: Cloud API");
            }
        }
    }

    // ── Cloud provider picker ──
    // Keys come from .env ({PREFIX}_API_KEY in ./.env or ~/.config/opal/.env),
    // never the config DB. Rows show key presence so a missing key is obvious
    // before the first failed request.
    {
        const ai_server = @import("../../services/ai_server.zig");
        if (ai_server.backend_kind == .cloud) {
            _ = dvui.label(@src(), "Provider — key from .env", .{}, .{
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
                .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = theme.spacing.xs },
            });
            for (ai_server.CLOUD_PROVIDERS, 0..) |p, i| {
                const sel = i == ai_server.cloud_provider_idx;
                const have_key = ai_server.cloudProviderHasKey(i);

                var prow = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = i + 400,
                    .expand = .horizontal,
                    .background = true,
                    .color_fill = @import("../color_compat.zig").wrap(if (sel) theme.colors.bg_elevated else theme.transparent),
                    .corners = theme.dims.rad_md,
                    .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                    .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
                });
                defer prow.deinit();

                var hovered = false;
                const clicked_row = dvui.clicked(prow.data(), .{ .hovered = &hovered });
                if (hovered and !sel) prow.data().options.color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_hover);
                prow.drawBackground();

                dvui.icon(@src(), "cloud-sel", if (sel) icons.tvg.lucide.@"circle-check-big" else icons.tvg.lucide.circle, .{}, .{
                    .id_extra = i + 400,
                    .color_text = @import("../color_compat.zig").wrap(if (sel) theme.colors.accent else theme.colors.text_tertiary),
                    .min_size_content = theme.iconSize(.sm),
                    .gravity_y = 0.5,
                    .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
                });
                var pname_buf: [160]u8 = undefined;
                const pname = std.fmt.bufPrint(&pname_buf, "{s}  ·  {s}", .{ p.name, if (sel) ai_server.cloudModel() else p.default_model }) catch p.name;
                _ = dvui.label(@src(), "{s}", .{pname}, .{
                    .id_extra = i + 400,
                    .color_text = @import("../color_compat.zig").wrap(if (sel) theme.colors.text_primary else theme.colors.text_secondary),
                    .gravity_y = 0.5,
                    .expand = .horizontal,
                });
                if (have_key)
                    components.statusPill("Key found", .success)
                else
                    components.statusPill("No key in .env", .info);

                if (clicked_row and !sel) {
                    ai_server.cloud_provider_idx = i;
                    ai_server.resetDetection();
                    state.markConfigDirty();
                    if (have_key)
                        state.showToast("Cloud provider selected")
                    else
                        state.showToast("Selected — add its API key to .env to activate");
                }
            }
        }
    }

    // ── Hugging Face model picker ──
    // Curated GGUF catalog served by llama-server. Pick one to download +
    // serve; the choice persists (config key "ai_model_id").
    {
        const ai_server = @import("../../services/ai_server.zig");
        if (ai_server.backend_kind == .gemma_llama) {
            _ = dvui.label(@src(), "Model — Hugging Face GGUF", .{}, .{
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
                .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = theme.spacing.xs },
            });
            // Rows with a leading check glyph + trailing status pill — the old
            // version baked ●/○ radio glyphs and "downloaded" into one string,
            // which wasn't scannable and used a third selection idiom.
            for (ai_server.MODEL_CATALOG, 0..) |m, i| {
                const sel = i == ai_server.active_model_idx;
                const have = ai_server.modelDownloaded(i);

                var mrow = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = i,
                    .expand = .horizontal,
                    .background = true,
                    .color_fill = @import("../color_compat.zig").wrap(if (sel) theme.colors.bg_elevated else theme.transparent),
                    .corners = theme.dims.rad_md,
                    .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                    .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
                });
                defer mrow.deinit();

                var hovered = false;
                const clicked_row = dvui.clicked(mrow.data(), .{ .hovered = &hovered });
                if (hovered and !sel) mrow.data().options.color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_hover);
                mrow.drawBackground();

                dvui.icon(@src(), "model-sel", if (sel) icons.tvg.lucide.@"circle-check-big" else icons.tvg.lucide.circle, .{}, .{
                    .id_extra = i,
                    .color_text = @import("../color_compat.zig").wrap(if (sel) theme.colors.accent else theme.colors.text_tertiary),
                    .min_size_content = theme.iconSize(.sm),
                    .gravity_y = 0.5,
                    .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
                });
                var name_buf: [128]u8 = undefined;
                const name_line = std.fmt.bufPrint(&name_buf, "{s}  ·  {s}  ·  {s}", .{ m.name, m.size_label, m.note }) catch m.name;
                _ = dvui.label(@src(), "{s}", .{name_line}, .{
                    .id_extra = i,
                    .color_text = @import("../color_compat.zig").wrap(if (sel) theme.colors.text_primary else theme.colors.text_secondary),
                    .gravity_y = 0.5,
                    .expand = .horizontal,
                });
                if (have) {
                    components.statusPill("Downloaded", .success);
                }

                if (clicked_row and !sel) {
                    ai_server.stopServer();
                    ai_server.selectModelByIndex(i);
                    state.markConfigDirty();
                    if (have)
                        state.showToast("Model selected")
                    else
                        state.showToast("Model selected — download below in AI panel");
                }
            }
        }
    }

    // ── Watch Party ──
    settingRow("Watch Party (LAN Sync)", 73, @src());
    {
        const party = @import("../../services/watch_party.zig");
        var status_buf: [64]u8 = undefined;
        const status = party.statusText(&status_buf);
        _ = dvui.label(@src(), "{s}", .{status}, .{
            .color_text = @import("../color_compat.zig").wrap(switch (party.role) {
                .none => theme.colors.text_tertiary,
                .host => theme.colors.accent,
                .client => theme.colors.text_secondary,
            }),
            .margin = .{ .x = 0, .y = theme.spacing.xxs, .w = 0, .h = theme.spacing.xs },
        });

        var row_layout = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = theme.spacing.xxs, .w = 0, .h = 6 },
        });

        if (party.role == .none) {
            // Host button — primary accent action.
            if (dvui.button(@src(), "Host Party", .{}, .{
                .color_fill = @import("../color_compat.zig").wrap(theme.colors.accent),
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_on_accent),
                .border = dvui.Rect.all(0),
                .corners = theme.dims.rad_md,
                .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
            })) {
                party.hostParty();
            }

            // Join input + button
            _ = dvui.label(@src(), "Join:", .{}, .{
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
                .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.xxs, .h = theme.spacing.xs },
            });
            var host_ip_input = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.party_host_ip_buf }, .placeholder = "192.168.x.x" }, .{
                .expand = .horizontal,
                .min_size_content = .{ .w = 120, .h = 20 },
                .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
                .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
                .color_border = @import("../color_compat.zig").wrap(theme.colors.border_subtle),
                .border = dvui.Rect.all(1),
                .corners = theme.dims.rad_md,
            });
            const ip_enter = host_ip_input.enter_pressed;
            host_ip_input.deinit();
            const ip_len = std.mem.indexOfScalar(u8, &state.app.party_host_ip_buf, 0) orelse 0;
            // Always render Join; gate the ACTION on a non-empty IP instead.
            // The button popping in and out of existence reflowed the row on
            // the first keystroke, right where the user was typing.
            const join_ready = ip_len > 0;
            const clicked_join = dvui.button(@src(), "Join", .{}, .{
                .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
                .color_text = @import("../color_compat.zig").wrap(if (join_ready) theme.colors.text_primary else theme.colors.text_tertiary),
                .border = dvui.Rect.all(0),
                .corners = theme.dims.rad_md,
                .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
            });
            if (join_ready and (clicked_join or ip_enter)) {
                party.joinParty(state.app.party_host_ip_buf[0..ip_len]);
            }
        } else {
            // Leave button — danger as TEXT on a quiet fill (not a red box).
            if (dvui.button(@src(), "Leave Party", .{}, .{
                .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
                .color_text = @import("../color_compat.zig").wrap(theme.colors.danger),
                .border = dvui.Rect.all(0),
                .corners = theme.dims.rad_md,
                .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
            })) {
                party.leaveParty();
            }
        }
        row_layout.deinit();

        // ── Chat ──
        if (party.role != .none) {
            components.divider();

            _ = dvui.label(@src(), "Chat", .{}, .{
                .id_extra = 7400,
                .color_text = @import("../color_compat.zig").wrap(labelText()),
                .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.xs },
            });

            // Chat messages (last 8)
            {
                var chat_box = dvui.box(@src(), .{ .dir = .vertical }, .{
                    .id_extra = 7500,
                    .expand = .horizontal,
                    .background = true,
                    .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
                    .corners = theme.dims.rad_sm,
                    .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
                    .min_size_content = .{ .w = 0, .h = 80 },
                    .max_size_content = .{ .w = std.math.floatMax(f32), .h = 100 },
                });
                defer chat_box.deinit();

                const start = if (party.chat_count > 8) party.chat_count - 8 else 0;
                for (start..party.chat_count) |ci| {
                    const msg = party.chat_msgs[ci][0..party.chat_msg_lens[ci]];
                    const is_sys = msg.len > 2 and msg[0] == '>' and msg[1] == '>';
                    // Untrusted network peer text (127-byte truncatable) — validate
                    // a stable copy or an invalid byte panics the whole app.
                    var chat_buf: [128]u8 = undefined;
                    _ = dvui.label(@src(), "{s}", .{@import("../../core/text.zig").safeUtf8Buf(msg, &chat_buf)}, .{
                        .id_extra = ci + 7600,
                        .color_text = @import("../color_compat.zig").wrap(if (is_sys) theme.colors.text_tertiary else theme.colors.text_primary),
                    });
                }
            }

            // Input row
            {
                var chat_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = 7700,
                    .expand = .horizontal,
                    .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = 0 },
                });
                defer chat_row.deinit();

                var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &party.chat_input } }, .{
                    .expand = .horizontal,
                    .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
                    .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
                    .color_border = @import("../color_compat.zig").wrap(theme.colors.border_subtle),
                    .border = dvui.Rect.all(1),
                    .corners = theme.dims.rad_sm,
                });
                const chat_enter = te.enter_pressed;
                te.deinit();

                const clicked_send = dvui.button(@src(), "Send", .{}, .{
                    .id_extra = 7710,
                    .color_fill = @import("../color_compat.zig").wrap(theme.colors.accent),
                    .color_text = @import("../color_compat.zig").wrap(theme.colors.text_on_accent),
                    .border = dvui.Rect.all(0),
                    .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                    .margin = .{ .x = theme.spacing.xs, .y = 0, .w = 0, .h = 0 },
                    .corners = theme.dims.rad_sm,
                });
                if (clicked_send or chat_enter) {
                    party.sendChat();
                }
            }

            // Sync URL button (host only) — secondary action, neutral fill.
            if (party.role == .host) {
                if (dvui.button(@src(), "Sync Current Video to All", .{}, .{
                    .id_extra = 7720,
                    .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
                    .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
                    .border = dvui.Rect.all(0),
                    .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                    .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 },
                    .corners = theme.dims.rad_md,
                })) {
                    if (state.app.active_player_idx < state.app.players.items.len) {
                        const p = state.app.players.items[state.app.active_player_idx];
                        if (p.current_url_len > 0) {
                            party.broadcastLoad(p.current_url[0..p.current_url_len]);
                        }
                    }
                }
            }
        }
    }

    // ── Installed Scripts ──
    settingRow("Installed Scripts", 71, @src());

    if (state.app.script_count == 0) {
        _ = dvui.label(@src(), "No scripts found in the mpv or Opal scripts folder", .{}, .{
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
            .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = theme.spacing.sm },
        });
    } else {
        var scroll = dvui.scrollArea(@src(), .{}, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 120 },
            .max_size_content = .{ .w = 0, .h = 180 },
        });
        defer scroll.deinit();

        for (0..state.app.script_count) |i| {
            const name = state.app.script_names[i][0..state.app.script_name_lens[i]];
            const enabled = state.app.script_enabled[i];

            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = i,
                .expand = .horizontal,
                .padding = .{ .x = theme.spacing.xs, .y = theme.spacing.xs, .w = theme.spacing.xs, .h = theme.spacing.xs },
            });
            defer row.deinit();

            // Compact chip toggle — same active grammar as iconButton (quiet
            // bg_elevated fill + accent text when on) instead of a bare text
            // link, with an explicit hover fill so it reads as clickable.
            const toggle_label = if (enabled) "On" else "Off";
            if (dvui.button(@src(), toggle_label, .{}, .{
                .id_extra = i + 7000,
                .color_fill = @import("../color_compat.zig").wrap(if (enabled) theme.colors.bg_elevated else theme.transparent),
                .color_fill_hover = @import("../color_compat.zig").wrap(theme.colors.bg_hover),
                .color_text = @import("../color_compat.zig").wrap(if (enabled) theme.colors.accent else theme.colors.text_tertiary),
                .border = dvui.Rect.all(0),
                .corners = theme.dims.rad_sm,
                .min_size_content = .{ .w = 32, .h = 0 },
                .padding = .{ .x = theme.spacing.xs, .y = theme.spacing.xxs, .w = theme.spacing.xs, .h = theme.spacing.xxs },
                .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
            })) {
                state.app.script_enabled[i] = !state.app.script_enabled[i];
                scripts.saveScriptState(i);
            }

            // Script name
            _ = dvui.labelNoFmt(@src(), name, .{}, .{
                .id_extra = i + 7100,
                .color_text = @import("../color_compat.zig").wrap(if (enabled) theme.colors.text_primary else theme.colors.text_tertiary),
            });
        }
    }

    // ── Recommended Scripts ──
    settingRow("Recommended Scripts", 72, @src());
    _ = dvui.label(@src(), "One-click install popular mpv scripts", .{}, .{
        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.xs },
    });

    for (scripts.recommended_scripts, 0..) |rec, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i + 8000,
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.xs, .y = theme.spacing.xs, .w = theme.spacing.xs, .h = theme.spacing.xs },
        });
        defer row.deinit();

        // Check if already installed
        var installed = false;
        for (0..state.app.script_count) |si| {
            const sn = state.app.script_names[si][0..state.app.script_name_lens[si]];
            if (std.mem.eql(u8, sn, rec.filename)) {
                installed = true;
                break;
            }
        }

        const install_state = scripts.installStatus(i);
        if (install_state == .downloading) {
            components.statusPill("Downloading…", .info);
            components.pollRefresh(100_000);
        } else if (installed) {
            components.statusPill("Installed", .success);
        } else if (install_state == .failed) {
            components.statusPill("Failed · see Logs", .warn);
        }
        if (!installed and install_state != .downloading) {
            if (dvui.button(@src(), if (install_state == .failed) "Retry" else "Install", .{}, .{
                .id_extra = i + 8100,
                .color_fill = @import("../color_compat.zig").wrap(theme.colors.accent),
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_on_accent),
                .border = dvui.Rect.all(0),
                .corners = theme.dims.rad_sm,
                .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xxs, .w = theme.spacing.sm, .h = theme.spacing.xxs },
                .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
            })) {
                scripts.installScript(i);
            }
        }

        _ = dvui.label(@src(), "{s}", .{rec.name}, .{
            .id_extra = i + 8200,
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        });

        _ = dvui.label(@src(), "{s}", .{rec.description}, .{
            .id_extra = i + 8300,
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
        });
    }
    _ = dvui.label(@src(), "Install procedure: curl -fLsS --max-time 15 -o <Opal scripts>/<filename> <curated HTTPS URL>; failed downloads are removed. No shell or private credentials.", .{}, .{ .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary) });
    if (dvui.button(@src(), "View script installation logs", .{}, .{ .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated), .color_text = @import("../color_compat.zig").wrap(theme.colors.accent) })) {
        state.navigateToTab(.Logs);
    }

    // Info footer
    _ = dvui.label(@src(), "Scripts load on next player creation. Restart app to apply changes.", .{}, .{
        .id_extra = 8999,
        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
        .margin = .{ .x = 0, .y = theme.spacing.md, .w = 0, .h = 0 },
    });
}
