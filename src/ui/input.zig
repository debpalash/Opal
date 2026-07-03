const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const ui = @import("ui.zig");
const c = @import("../core/c.zig");
const search = @import("../services/search.zig");
const transfers = @import("../services/transfers.zig");

fn gracefulShutdown() void {
    // Save all player positions before exit
    for (state.app.players.items) |p| {
        p.saveCurrentPosition();
    }
    // Flush config
    const config = @import("../core/config.zig");
    config.save();
    std.process.exit(0);
}

pub fn processGlobalInputs() void {
    for (dvui.events()) |*e| {
        if (e.evt == .key and e.evt.key.action == .down) {
            const key = e.evt.key.code;
            const mod = e.evt.key.mod;

            // ── Always-active shortcuts (work even when text is focused) ──

            // Escape = staged close. Defocus first, then leave fullscreen,
            // then peel panels one at a time (playlist → settings → drawer)
            // so a single Escape doesn't nuke everything at once.
            if (key == .escape) {
                if (dvui.focusedWidgetId() != null) {
                    dvui.focusWidget(null, null, null);
                } else if (state.app.fullscreen_player_idx != null) {
                    state.app.fullscreen_player_idx = null;
                } else if (state.app.playlist_drawer_open) {
                    state.app.playlist_drawer_open = false;
                } else if (state.app.settings_open) {
                    state.app.settings_open = false;
                } else {
                    state.app.drawer_open = false;
                }
                dvui.refresh(null, @src(), null);
                continue;
            }

            // Ctrl+shortcuts always work (Cmd on macOS via the platform-aware
            // "ctrl/cmd" keybind — Ctrl still accepted everywhere).
            const ctrl_or_cmd = mod.control() or mod.matchBind("ctrl/cmd");
            if (ctrl_or_cmd) {
                if (key == .comma) {
                    state.app.settings_open = !state.app.settings_open;
                    dvui.refresh(null, @src(), null);
                    continue;
                }
                if (key == .o) {
                    ui.triggerFileOpen();
                    dvui.refresh(null, @src(), null);
                    continue;
                }
                if (key == .q) {
                    gracefulShutdown();
                }
                if (key == .i) {
                    state.app.media_info_open = !state.app.media_info_open;
                    dvui.refresh(null, @src(), null);
                    continue;
                }
            }

            // ── If a text entry is focused, suppress single-key shortcuts ──
            if (dvui.focusedWidgetId() != null) {
                continue;
            }

            // Shift+I = keyboard-shortcuts cheat sheet. Must live OUTSIDE the
            // no-modifier switch below — the old placement (`if (mod.shift())`
            // inside a `!mod.shift()` guard) was dead code, leaving the cheat
            // sheet unreachable in the default page-shell UI.
            if (key == .i and mod.shift() and !mod.control() and !mod.alt()) {
                state.app.cheatsheet_open = !state.app.cheatsheet_open;
                dvui.refresh(null, @src(), null);
                continue;
            }

            // D = Toggle drawer (legacy layout). In the default page shell the
            // drawer never renders, so the old toggle was a silent no-op —
            // route to the Library page there instead (the drawer's analog).
            if (key == .d and !mod.control() and !mod.shift()) {
                if (state.app.page_shell_enabled) {
                    state.navigateToTab(.Queue);
                } else {
                    state.app.drawer_open = !state.app.drawer_open;
                }
                dvui.refresh(null, @src(), null);
                continue;
            }

            // Ctrl+W = Close active player (like browser tab close)
            if (key == .w and ctrl_or_cmd) {
                if (state.app.players.items.len > 1) {
                    const idx = state.app.active_player_idx;
                    if (idx < state.app.players.items.len) {
                        const p = state.app.players.items[idx];
                        // Save URL for Ctrl+Shift+T restore
                        if (p.source_url_len > 0) {
                            state.pushClosedUrl(p.source_url[0..p.source_url_len]);
                        }
                        p.saveCurrentPosition();
                        state.app.pending_remove_player_idx = @intCast(idx);
                        state.showToast("Player closed (Ctrl+Shift+T to restore)");
                    }
                } else {
                    state.showToast("Can't close last player");
                }
                dvui.refresh(null, @src(), null);
                continue;
            }

            // Ctrl+L = Toggle Language Learning
            if (key == .l and ctrl_or_cmd) {
                state.app.lang_learn_enabled = !state.app.lang_learn_enabled;
                const lang_learn = @import("../services/lang_learn.zig");
                lang_learn.onToggle(state.app.lang_learn_enabled);
                const ll_logs = @import("../core/logs.zig");
                if (state.app.lang_learn_enabled) {
                    ll_logs.pushLog("info", "opal", "Language Learning ON (Ctrl+L)", false);
                } else {
                    ll_logs.pushLog("info", "opal", "Language Learning OFF", false);
                }
                dvui.refresh(null, @src(), null);
                continue;
            }

            // Ctrl+S = Save current subtitle flashcard
            if (key == .s and ctrl_or_cmd) {
                const lang_learn = @import("../services/lang_learn.zig");
                lang_learn.saveSubtitleFlashcard();
                dvui.refresh(null, @src(), null);
                continue;
            }

            // Ctrl+Shift+T = Reopen last closed player (like Chrome tabs)
            if (key == .t and ctrl_or_cmd and mod.shift()) {
                var restore_buf: [2048]u8 = undefined;
                if (state.popClosedUrl(&restore_buf)) |url| {
                    const player = @import("../player/player.zig");
                    if (player.MediaPlayer.init(@import("../core/alloc.zig").allocator)) |p| {
                        state.app.players.append(@import("../core/alloc.zig").allocator, p) catch {};
                        state.app.active_player_idx = state.app.players.items.len - 1;

                        // Load the restored URL into the new player.
                        const browser = @import("../services/browser.zig");
                        browser.loadContent(url);
                        state.showToast("Restored closed player");
                    } else |_| {}
                } else {
                    state.showToast("No closed players to restore");
                }
                dvui.refresh(null, @src(), null);
                continue;
            }

            // Ctrl+T = New player tab — retired. The app plays one media at a
            // time now; opening media replaces the current stream.
            if (key == .t and ctrl_or_cmd and !mod.shift()) {
                state.showToast("Single-player mode — open media to replace the current one");
                dvui.refresh(null, @src(), null);
                continue;
            }

            // Paste shortcut triggers regardless of other state
            if (e.evt.key.matchBind("paste")) {
                ui.handleClipboardPaste();
                continue;
            }

            // Global UI overrides (Toggle Drawers / Fullscreen)
            // No shift/ctrl/alt to avoid clashing with text inputs / OS shortcuts.
            // Every matched key `continue`s — previously a match FELL THROUGH to
            // the player-specific switch below, so e.g. one press of P toggled
            // the playlist drawer AND took a screenshot, and I toggled incognito
            // AND the stats overlay.
            if (!mod.shift() and !mod.control() and !mod.alt() and !mod.command()) {
                switch (key) {
                    .f => {
                        if (state.app.fullscreen_player_idx == null) {
                            state.app.fullscreen_player_idx = state.app.active_player_idx;
                        } else {
                            state.app.fullscreen_player_idx = null;
                        }
                        dvui.refresh(null, @src(), null);
                        continue;
                    },
                    .s => {
                        state.navigateToTab(.Search);
                        dvui.refresh(null, @src(), null);
                        continue;
                    },

                    // P = Playlist (Shift+P = screenshot, player section below)
                    .p => {
                        state.app.playlist_drawer_open = !state.app.playlist_drawer_open;
                        dvui.refresh(null, @src(), null);
                        continue;
                    },
                    .g => {
                        state.app.grid_mode = switch (state.app.grid_mode) {
                            .auto => .cols_1,
                            .cols_1 => .cols_2,
                            .cols_2 => .cols_3,
                            .cols_3 => .cols_4,
                            .cols_4 => .auto,
                        };
                        dvui.refresh(null, @src(), null);
                        continue;
                    },
                    .y => {
                        state.app.seek_sync = !state.app.seek_sync;
                        state.showToast(if (state.app.seek_sync) "Seek sync ON" else "Seek sync OFF");
                        dvui.refresh(null, @src(), null);
                        continue;
                    },
                    // I = Toggle incognito mode (Shift+I = cheat sheet, above)
                    .i => {
                        state.app.incognito_mode = !state.app.incognito_mode;
                        if (state.app.incognito_mode) {
                            state.showToast("Incognito ON — no history saved");
                        } else {
                            state.showToast("Incognito OFF — history recording resumed");
                        }
                        dvui.refresh(null, @src(), null);
                        continue;
                    },
                    .h => {
                        state.navigateToTab(.History);
                        dvui.refresh(null, @src(), null);
                        continue;
                    },
                    .one, .two, .three, .four, .five, .six, .seven, .eight, .nine => {
                        const cell_idx = @intFromEnum(key) - @intFromEnum(dvui.enums.Key.one);
                        if (cell_idx < state.app.players.items.len) {
                            state.app.active_player_idx = @intCast(cell_idx);
                            dvui.refresh(null, @src(), null);
                        }
                        continue;
                    },
                    // Z = Toggle video fill mode (fit / cover)
                    .z => {
                        state.app.video_fill_mode = if (state.app.video_fill_mode == .fit) .cover else .fit;
                        // Apply panscan to all players
                        const panscan_val = if (state.app.video_fill_mode == .cover) "1.0" else "0.0";
                        for (state.app.players.items) |ap| {
                            _ = c.mpv.mpv_set_option_string(ap.mpv_ctx, "panscan", panscan_val);
                        }
                        const mode_str = if (state.app.video_fill_mode == .cover) "Cover (crop fill)" else "Fit (letterbox)";
                        state.showToast(mode_str);
                        dvui.refresh(null, @src(), null);
                        continue;
                    },
                    // B = Open the in-app web browser (Browse › Web tab)
                    .b => {
                        state.navigateToTab(.Web);
                        dvui.refresh(null, @src(), null);
                        continue;
                    },
                    // C = Switch active cell to comic viewer
                    .c => {
                        if (state.app.active_player_idx < state.app.players.items.len) {
                            state.app.players.items[state.app.active_player_idx].provider = .comic_viewer;
                            dvui.refresh(null, @src(), null);
                        }
                        continue;
                    },
                    // U = Cycle audio track
                    .u => {
                        if (state.app.active_player_idx < state.app.players.items.len) {
                            const ap = state.app.players.items[state.app.active_player_idx];
                            _ = c.mpv.mpv_command_string(ap.mpv_ctx, "cycle audio");
                            _ = c.mpv.mpv_command_string(ap.mpv_ctx, "show-text \"${audio}\" 2000");
                            state.showToast("Cycling audio track");
                        }
                        continue;
                    },
                    // V = Cycle subtitle track
                    .v => {
                        if (state.app.active_player_idx < state.app.players.items.len) {
                            const ap = state.app.players.items[state.app.active_player_idx];
                            _ = c.mpv.mpv_command_string(ap.mpv_ctx, "cycle sub");
                            _ = c.mpv.mpv_command_string(ap.mpv_ctx, "show-text \"${sub}\" 2000");
                            state.showToast("Cycling subtitle track");
                        }
                        continue;
                    },
                    // (K = sub delay lives in the player section below, where
                    // Shift+K is actually reachable — it was dead here.)
                    else => {},
                }
            }

            // Ctrl+Arrow = Swap active cell with neighbor
            if (mod.control() and !mod.shift() and !mod.alt()) {
                const pi = state.app.active_player_idx;
                const plen = state.app.players.items.len;
                if (plen > 1) {
                    var swap_target: ?usize = null;
                    switch (key) {
                        .left => {
                            if (pi > 0) swap_target = pi - 1;
                        },
                        .right => {
                            if (pi + 1 < plen) swap_target = pi + 1;
                        },
                        .up => {
                            const cols = ui.computeGridColumns();
                            if (pi >= cols) swap_target = pi - cols;
                        },
                        .down => {
                            const cols = ui.computeGridColumns();
                            if (pi + cols < plen) swap_target = pi + cols;
                        },
                        else => {},
                    }
                    if (swap_target) |target| {
                        const tmp = state.app.players.items[pi];
                        state.app.players.items[pi] = state.app.players.items[target];
                        state.app.players.items[target] = tmp;
                        state.app.active_player_idx = target;
                        dvui.refresh(null, @src(), null);
                    }
                }
            }

            // Player Specific Shortcuts (Only execute if a text entry field / drawer isn't active, to prevent typing from seeking video)
            // To be robust, we check if search_drawer is open, because typically that's where users type.
            if (state.app.active_player_idx < state.app.players.items.len and !state.app.drawer_open) {
                const p = state.app.players.items[state.app.active_player_idx];

                // Active cell modifiers / controls. Modifier guards matter:
                // without them Ctrl+Arrow (cell swap) ALSO seeked ±10s and
                // Shift+Arrow (pan) ALSO changed the volume.
                if ((key == .left or key == .right) and !mod.control() and !mod.shift() and !mod.alt() and !mod.command()) {
                    var seek_cmd: [64]u8 = undefined;
                    if (std.fmt.bufPrintZ(&seek_cmd, "seek {d}", .{if (key == .left) @as(i32, -10) else @as(i32, 10)})) |cmd| {
                        _ = c.mpv.mpv_command_string(p.mpv_ctx, cmd.ptr);
                        // Broadcast to watch party
                        const party = @import("../services/watch_party.zig");
                        var pos: f64 = 0;
                        _ = c.mpv.mpv_get_property(p.mpv_ctx, "time-pos", c.mpv.MPV_FORMAT_DOUBLE, &pos);
                        party.broadcastSeek(pos);
                    } else |_| {}
                }

                if ((key == .up or key == .down) and !mod.control() and !mod.shift() and !mod.alt() and !mod.command()) {
                    var vol_cmd: [64]u8 = undefined;
                    if (std.fmt.bufPrintZ(&vol_cmd, "add volume {d}", .{if (key == .down) @as(i32, -5) else @as(i32, 5)})) |cmd| {
                        _ = c.mpv.mpv_command_string(p.mpv_ctx, cmd.ptr);
                    } else |_| {}
                }

                if (!mod.control() and !mod.alt() and !mod.command()) {
                    switch (key) {
                        .space => {
                            _ = c.mpv.mpv_command_string(p.mpv_ctx, "cycle pause");
                            // Broadcast to watch party
                            const party = @import("../services/watch_party.zig");
                            var paused: c_int = 0;
                            _ = c.mpv.mpv_get_property(p.mpv_ctx, "pause", c.mpv.MPV_FORMAT_FLAG, &paused);
                            if (paused != 0) party.broadcastPause() else party.broadcastPlay();
                        },
                        .m => {
                            _ = c.mpv.mpv_command_string(p.mpv_ctx, "cycle mute");
                            var muted: c_int = 0;
                            _ = c.mpv.mpv_get_property(p.mpv_ctx, "mute", c.mpv.MPV_FORMAT_FLAG, &muted);
                            state.showToast(if (muted != 0) "Muted" else "Unmuted");
                        },
                        .j => {
                            if (mod.shift()) {
                                // Shift+J = Search subtitles online
                                const subs = @import("../services/subtitles.zig");
                                subs.autoSearchFromPlayer();
                                state.showToast("Searching subtitles...");
                            } else {
                                _ = c.mpv.mpv_command_string(p.mpv_ctx, "cycle sub");
                                state.showToast("Subtitle track cycled");
                            }
                        },
                        .left_bracket => {
                            _ = c.mpv.mpv_command_string(p.mpv_ctx, "multiply speed 1/1.1");
                            var spd: f64 = 1.0;
                            _ = c.mpv.mpv_get_property(p.mpv_ctx, "speed", c.mpv.MPV_FORMAT_DOUBLE, &spd);
                            var spd_buf: [32]u8 = undefined;
                            const spd_str = std.fmt.bufPrint(&spd_buf, "Speed: {d:.2}x", .{spd / 1.1}) catch "Speed changed";
                            state.showToast(spd_str);
                        },
                        .right_bracket => {
                            _ = c.mpv.mpv_command_string(p.mpv_ctx, "multiply speed 1.1");
                            var spd: f64 = 1.0;
                            _ = c.mpv.mpv_get_property(p.mpv_ctx, "speed", c.mpv.MPV_FORMAT_DOUBLE, &spd);
                            var spd_buf: [32]u8 = undefined;
                            const spd_str = std.fmt.bufPrint(&spd_buf, "Speed: {d:.2}x", .{spd * 1.1}) catch "Speed changed";
                            state.showToast(spd_str);
                        },
                        .backspace => {
                            _ = c.mpv.mpv_command_string(p.mpv_ctx, "set speed 1.0");
                            state.showToast("Speed: 1.00x");
                        },
                        .comma => {
                            _ = c.mpv.mpv_command_string(p.mpv_ctx, "frame-back-step");
                        },
                        .period => {
                            _ = c.mpv.mpv_command_string(p.mpv_ctx, "frame-step");
                        },
                        .l => {
                            if (p.loop_a < 0) {
                                p.setLoopA();
                            } else if (p.loop_b < 0) {
                                p.setLoopB();
                            } else {
                                p.clearLoop();
                            }
                        },
                        .r => {
                            if (!mod.shift()) p.cycleRotation();
                        },
                        .t => {
                            p.toggleFlip();
                        },
                        // Shift+P = Screenshot (unmodified P toggles the
                        // playlist drawer in the global section above).
                        .p => {
                            if (mod.shift()) {
                                _ = c.mpv.mpv_command_string(p.mpv_ctx, "screenshot");
                                state.showToast("Screenshot saved");
                            }
                        },
                        // Shift+S = Stats for Nerds overlay (unmodified S
                        // navigates to Search; the old unmodified-I binding
                        // collided with the global incognito toggle).
                        .s => {
                            if (mod.shift()) {
                                state.app.stats_overlay_open = !state.app.stats_overlay_open;
                                dvui.refresh(null, @src(), null);
                            }
                        },
                        // K = sub delay +100ms, Shift+K = −100ms. (Moved from
                        // the no-shift global section, where the Shift branch
                        // was unreachable.)
                        .k => {
                            if (mod.shift()) {
                                _ = c.mpv.mpv_command_string(p.mpv_ctx, "add sub-delay -0.1");
                                state.showToast("Sub delay -100ms");
                            } else {
                                _ = c.mpv.mpv_command_string(p.mpv_ctx, "add sub-delay 0.1");
                                state.showToast("Sub delay +100ms");
                            }
                        },
                        // Zoom
                        .equal => {
                            _ = c.mpv.mpv_command_string(p.mpv_ctx, "add video-zoom 0.1");
                        },
                        .minus => {
                            _ = c.mpv.mpv_command_string(p.mpv_ctx, "add video-zoom -0.1");
                        },
                        .zero => {
                            _ = c.mpv.mpv_command_string(p.mpv_ctx, "set video-zoom 0");
                            _ = c.mpv.mpv_command_string(p.mpv_ctx, "set video-pan-x 0");
                            _ = c.mpv.mpv_command_string(p.mpv_ctx, "set video-pan-y 0");
                        },
                        // Audio track cycle lives on U (.a is unassigned; the
                        // AI bubble overlay it used to toggle was removed)
                        // Next/Prev episode (N/Shift+N)
                        .n => {
                            if (mod.shift()) {
                                _ = c.mpv.mpv_command_string(p.mpv_ctx, "playlist-prev");
                            } else {
                                _ = c.mpv.mpv_command_string(p.mpv_ctx, "playlist-next");
                            }
                        },
                        // Chapter navigation
                        .page_up => {
                            _ = c.mpv.mpv_command_string(p.mpv_ctx, "add chapter -1");
                            state.showToast("Previous chapter");
                        },
                        .page_down => {
                            _ = c.mpv.mpv_command_string(p.mpv_ctx, "add chapter 1");
                            state.showToast("Next chapter");
                        },
                        else => {},
                    }
                }

                // Shift+arrows = pan (when zoomed)
                if (mod.shift() and !mod.control() and !mod.command()) {
                    switch (key) {
                        .left => {
                            _ = c.mpv.mpv_command_string(p.mpv_ctx, "add video-pan-x 0.02");
                        },
                        .right => {
                            _ = c.mpv.mpv_command_string(p.mpv_ctx, "add video-pan-x -0.02");
                        },
                        .up => {
                            _ = c.mpv.mpv_command_string(p.mpv_ctx, "add video-pan-y 0.02");
                        },
                        .down => {
                            _ = c.mpv.mpv_command_string(p.mpv_ctx, "add video-pan-y -0.02");
                        },
                        else => {},
                    }
                }

                if (key == .three and mod.shift()) {
                    _ = c.mpv.mpv_command_string(p.mpv_ctx, "cycle audio");
                }
            }
        }
    }
}
