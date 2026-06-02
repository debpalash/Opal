const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const c = @import("../core/c.zig");
const state = @import("../core/state.zig");
const player = @import("../player/player.zig");
const logs = @import("../core/logs.zig");
const search = @import("../services/search.zig");
const transfers = @import("../services/transfers.zig");
const theme = @import("theme.zig");
const metadata_dialog = @import("metadata_dialog.zig");
const components = @import("components.zig");


pub const renderHeader = @import("header.zig").renderHeader;
pub const renderTabBar = @import("header.zig").renderTabBar;
pub const handleClipboardPaste = @import("header.zig").handleClipboardPaste;

pub const renderGrid = @import("grid.zig").renderGrid;
pub const computeGridColumns = @import("grid.zig").computeGridColumns;
pub const muteBackgroundPlayers = @import("grid.zig").muteBackgroundPlayers;

pub const aspectDropdownMenu = @import("footer.zig").aspectDropdownMenu;
pub const trackDropdownMenu = @import("footer.zig").trackDropdownMenu;
pub const playlistDropdownMenu = @import("footer.zig").playlistDropdownMenu;
pub const subLanguageDropdown = @import("footer.zig").subLanguageDropdown;
pub const renderLiquidGlassOverlay = @import("footer.zig").renderLiquidGlassOverlay;
pub const renderGlobalBottomTray = @import("footer.zig").renderGlobalBottomTray;
pub const renderToast = @import("footer.zig").renderToast;
pub const renderStatsOverlay = @import("footer.zig").renderStatsOverlay;

const FileOpenState = struct {
    var file_path: [2048]u8 = std.mem.zeroes([2048]u8);
    var file_path_len: usize = 0;
    var pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    var running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    var thread: ?std.Thread = null;

    const builtin = @import("builtin");

    fn dialogWorker() void {
        const io_global = @import("../core/io_global.zig");
        const alloc = @import("../core/alloc.zig").allocator;

        var child = if (comptime builtin.os.tag == .macos) blk: {
            // macOS: native file dialog via osascript + AppleScript
            const script =
                "activate\n" ++
                "set theFile to choose file with prompt \"Open Media File\"\n" ++
                "return POSIX path of theFile";
            break :blk io_global.Child.init(
                &.{ "osascript", "-e", script },
                alloc,
            );
        } else blk: {
            // Linux: zenity file chooser
            break :blk io_global.Child.init(
                &.{ "zenity", "--file-selection", "--title=Open Media File",
                     "--file-filter=Media files|*.mp4 *.mkv *.avi *.webm *.mov *.flv *.m3u *.m3u8 *.ts *.mp3 *.flac *.wav *.ogg *.m4a *.opus" },
                alloc,
            );
        };
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.spawn() catch |err| {
            std.debug.print("[FileOpen] spawn failed: {}\n", .{err});
            running.store(false, .release);
            return;
        };

        // Read stdout using streaming reads (readAll uses positional I/O
        // which silently returns 0 on pipes). Read BEFORE wait to avoid
        // pipe buffer deadlock.
        var n: usize = 0;
        if (child.stdout) |*stdout| {
            while (n < file_path.len) {
                const chunk = io_global.read(stdout, file_path[n..]) catch break;
                if (chunk == 0) break; // EOF
                n += chunk;
            }
        }

        // Also capture stderr for debugging
        var err_buf: [512]u8 = undefined;
        var err_n: usize = 0;
        if (child.stderr) |*stderr_pipe| {
            while (err_n < err_buf.len) {
                const chunk = io_global.read(stderr_pipe, err_buf[err_n..]) catch break;
                if (chunk == 0) break;
                err_n += chunk;
            }
        }

        const term = child.wait() catch |err| {
            std.debug.print("[FileOpen] wait failed: {}\n", .{err});
            running.store(false, .release);
            return;
        };

        if (err_n > 0) {
            std.debug.print("[FileOpen] stderr: {s}\n", .{err_buf[0..err_n]});
        }

        if (n > 0) {
            var plen = n;
            while (plen > 0 and (file_path[plen - 1] == '\n' or file_path[plen - 1] == '\r')) plen -= 1;
            file_path_len = plen;
            std.debug.print("[FileOpen] Got path: {s}\n", .{file_path[0..plen]});
            pending.store(true, .release);
        } else {
            std.debug.print("[FileOpen] No file selected (cancelled) exit={}\n", .{term});
        }
        running.store(false, .release);
    }
};

pub fn triggerFileOpen() void {
    if (!FileOpenState.running.load(.acquire)) {
        FileOpenState.running.store(true, .release);
        FileOpenState.thread = std.Thread.spawn(.{}, FileOpenState.dialogWorker, .{}) catch blk: {
            FileOpenState.running.store(false, .release);
            break :blk null;
        };
    }
}

pub fn pollFileOpen() void {
    if (FileOpenState.pending.load(.acquire)) {
        if (FileOpenState.file_path_len > 0 and state.app.active_player_idx < state.app.players.items.len) {
            FileOpenState.file_path[FileOpenState.file_path_len] = 0;
            state.app.players.items[state.app.active_player_idx].load_file(@ptrCast(&FileOpenState.file_path[0]));
            logs.pushLog("info", "open", "Loaded local file", false);
        }
        FileOpenState.pending.store(false, .release);
        if (FileOpenState.thread) |t| { t.join(); FileOpenState.thread = null; }
    }
}

pub fn renderWorkspaceModals() void {
    const workspace = @import("workspace.zig");

    // ═══════════════════════════════════════════════════════
    // SAVE WORKSPACE MODAL
    // ═══════════════════════════════════════════════════════
    if (state.app.ws_save_open) {
        var win = dvui.floatingWindow(@src(), .{
            .modal = true,
            .open_flag = &state.app.ws_save_open,
        }, .{
            .min_size_content = .{ .w = 360, .h = 120 },
            .color_fill = theme.colors.bg_drawer,
            .color_border = theme.colors.border_card,
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(12),
        });
        defer win.deinit();

        // Header
        {
            var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .background = true,
                .color_fill = theme.colors.bg_header,
                .padding = .{ .x = 12, .y = 8, .w = 8, .h = 8 },
                .color_border = theme.colors.bg_header_border,
                .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
            });
            defer hdr.deinit();

            dvui.icon(@src(), "", icons.tvg.lucide.@"save", .{}, .{
                .color_text = theme.colors.accent,
                .gravity_y = 0.5,
            });
            _ = dvui.label(@src(), " Save Workspace", .{}, .{
                .color_text = theme.colors.text_main,
                .gravity_y = 0.5,
            });

            { var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal }); spacer.deinit(); }

            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"x", .{}, .{}, .{
                .color_text = theme.colors.text_muted,
                .color_fill = theme.transparent,
                .border = dvui.Rect.all(0),
                .gravity_y = 0.5,
            })) {
                state.app.ws_save_open = false;
            }
        }

        // Body
        {
            var body = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .padding = .{ .x = 16, .y = 12, .w = 16, .h = 12 },
            });
            defer body.deinit();

            _ = dvui.label(@src(), "Workspace name:", .{}, .{
                .color_text = theme.colors.text_muted,
                .margin = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
            });

            var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.ws_name_input } }, .{
                .expand = .horizontal,
                .color_fill = theme.colors.bg_input,
                .color_text = theme.colors.text_main,
                .color_border = theme.colors.divider,
                .border = dvui.Rect.all(1),
                .corner_radius = dvui.Rect.all(6),
                .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
            });
            const enter_pressed = te.enter_pressed;
            te.deinit();

            { var gap = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 0, .h = 10 } }); gap.deinit(); }

            var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer btn_row.deinit();

            if (dvui.button(@src(), "Save", .{}, .{
                .color_fill = theme.colors.accent,
                .color_text = theme.colors.bg_app,
                .corner_radius = dvui.Rect.all(6),
                .border = dvui.Rect.all(0),
                .padding = .{ .x = 16, .y = 6, .w = 16, .h = 6 },
            }) or enter_pressed) {
                const name_len = std.mem.indexOfScalar(u8, &state.app.ws_name_input, 0) orelse state.app.ws_name_input.len;
                if (name_len > 0) {
                    workspace.saveWorkspaceNamed(@import("../core/alloc.zig").allocator, state.app.ws_name_input[0..name_len]);
                    state.app.ws_save_open = false;
                }
            }

            { var s = dvui.box(@src(), .{}, .{ .expand = .horizontal }); s.deinit(); }

            if (dvui.button(@src(), "Cancel", .{}, .{
                .color_fill = theme.transparent,
                .color_text = theme.colors.text_muted,
                .corner_radius = dvui.Rect.all(6),
                .border = dvui.Rect.all(1),
                .color_border = theme.colors.divider,
                .padding = .{ .x = 16, .y = 6, .w = 16, .h = 6 },
            })) {
                state.app.ws_save_open = false;
            }
        }
    }

    // ═══════════════════════════════════════════════════════
    // LOAD WORKSPACE MODAL
    // ═══════════════════════════════════════════════════════
    if (state.app.ws_load_open) {
        var win = dvui.floatingWindow(@src(), .{
            .modal = true,
            .open_flag = &state.app.ws_load_open,
        }, .{
            .min_size_content = .{ .w = 360, .h = 120 },
            .color_fill = theme.colors.bg_drawer,
            .color_border = theme.colors.border_card,
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(12),
        });
        defer win.deinit();

        // Header
        {
            var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .background = true,
                .color_fill = theme.colors.bg_header,
                .padding = .{ .x = 12, .y = 8, .w = 8, .h = 8 },
                .color_border = theme.colors.bg_header_border,
                .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
            });
            defer hdr.deinit();

            dvui.icon(@src(), "", icons.tvg.lucide.@"folder-open", .{}, .{
                .color_text = theme.colors.accent,
                .gravity_y = 0.5,
            });
            _ = dvui.label(@src(), " Load Workspace", .{}, .{
                .color_text = theme.colors.text_main,
                .gravity_y = 0.5,
            });

            { var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal }); spacer.deinit(); }

            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"x", .{}, .{}, .{
                .color_text = theme.colors.text_muted,
                .color_fill = theme.transparent,
                .border = dvui.Rect.all(0),
                .gravity_y = 0.5,
            })) {
                state.app.ws_load_open = false;
            }
        }

        // Body
        {
            var body = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .padding = .{ .x = 16, .y = 12, .w = 16, .h = 12 },
            });
            defer body.deinit();

            if (state.app.ws_count == 0) {
                _ = dvui.label(@src(), "No saved workspaces yet.", .{}, .{
                    .color_text = theme.colors.text_muted,
                    .margin = .{ .x = 0, .y = 12, .w = 0, .h = 4 },
                    .gravity_x = 0.5,
                });
                _ = dvui.label(@src(), "Save one first with the save button.", .{}, .{
                    .color_text = theme.colors.text_dim,
                    .gravity_x = 0.5,
                    .margin = .{ .x = 0, .y = 0, .w = 0, .h = 12 },
                });
            } else {
                for (0..state.app.ws_count) |wi| {
                    const name = state.app.ws_names[wi][0..state.app.ws_name_lens[wi]];
                    if (dvui.button(@src(), name, .{}, .{
                        .id_extra = wi,
                        .expand = .horizontal,
                        .color_fill = theme.colors.bg_card,
                        .color_text = theme.colors.text_main,
                        .color_border = theme.colors.divider,
                        .border = dvui.Rect.all(1),
                        .corner_radius = dvui.Rect.all(6),
                        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
                        .margin = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
                    })) {
                        workspace.loadWorkspaceNamed(@import("../core/alloc.zig").allocator, name);
                        state.app.ws_load_open = false;
                    }
                }
            }
        }
    }
}
