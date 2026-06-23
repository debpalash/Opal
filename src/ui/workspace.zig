const std = @import("std");
const state = @import("../core/state.zig");
const player = @import("../player/player.zig");
const c = @import("../core/c.zig");
const logs = @import("../core/logs.zig");
const paths = @import("../core/paths.zig");

const WorkspacePlayer = struct {
    source_url: []const u8,
    is_torrent: bool,
    cell_volume: f64,
    playback_percent: f64 = 0.0,
};

const WorkspaceData = struct {
    players: []WorkspacePlayer,
    hwdec_enabled: bool,
    seek_sync: bool,
    drawer_width_px: f32 = 480.0,
};

// ══════════════════════════════════════════════════════════
// Named Workspace Management
// ══════════════════════════════════════════════════════════

/// Get the workspaces directory path (~/.config/zigzag/workspaces/)
fn workspacesDir(buf: []u8) []const u8 {
    var dir_buf: [512]u8 = undefined;
    const cfg = paths.configDir(&dir_buf);
    return std.fmt.bufPrint(buf, "{s}/workspaces", .{cfg}) catch "/tmp/zigzag/workspaces";
}

/// Ensure the workspaces directory exists.
fn ensureWorkspacesDir() void {
    var buf: [512]u8 = undefined;
    const dir = workspacesDir(&buf);
    @import("../core/io_global.zig").cwdMakePath(dir) catch {};
}

/// Scan saved workspaces and populate state lists.
pub fn scanWorkspaces() void {
    var dir_buf: [512]u8 = undefined;
    const ws_dir = workspacesDir(&dir_buf);

    var dir = @import("../core/io_global.zig").cwdOpenDir(ws_dir, .{ .iterate = true }) catch {
        state.app.ws_count = 0;
        return;
    };
    defer dir.close(@import("../core/io_global.zig").io());

    state.app.ws_count = 0;
    var iter = dir.iterate();
    while (iter.next(@import("../core/io_global.zig").io()) catch null) |entry| {
        if (state.app.ws_count >= 16) break;
        if (entry.kind != .file) continue;
        // Only .json files
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        // Strip .json extension for display name
        const name_part = entry.name[0 .. entry.name.len - 5];
        const copy_len = @min(name_part.len, 64);
        const slot = state.app.ws_count;
        @memcpy(state.app.ws_names[slot][0..copy_len], name_part[0..copy_len]);
        state.app.ws_name_lens[slot] = copy_len;
        state.app.ws_count += 1;
    }
}

/// Save workspace under the given name.
pub fn saveWorkspaceNamed(allocator: std.mem.Allocator, name: []const u8) void {
    if (state.app.incognito_mode) {
        state.showToast("Cannot save workspace in incognito mode");
        return;
    }
    if (name.len == 0) {
        state.showToast("Workspace name cannot be empty");
        return;
    }

    ensureWorkspacesDir();

    var ws_players = std.ArrayListUnmanaged(WorkspacePlayer).empty;
    defer ws_players.deinit(allocator);

    for (state.app.players.items, 0..) |p, pi| {
        // Try multiple sources for the URL
        var url: []const u8 = "";

        // 1. source_url (set by magnet/torrent code paths)
        if (url.len == 0 and p.source_url_len > 0 and p.source_url_len <= 2048) {
            url = p.source_url[0..p.source_url_len];
        }
        // 2. current_url (set by load_file)
        if (url.len == 0 and p.current_url_len > 0 and p.current_url_len <= 2048) {
            url = p.current_url[0..p.current_url_len];
        }
        // 3. browser_url_buf (set by browser navigate)
        if (url.len == 0 and p.browser_url_len > 0 and p.browser_url_len <= 2048) {
            url = p.browser_url_buf[0..p.browser_url_len];
        }
        // 4. Ask mpv for its current path
        if (url.len == 0) {
            var mpv_path: ?[*:0]const u8 = null;
            if (c.mpv.mpv_get_property(p.mpv_ctx, "path", c.mpv.MPV_FORMAT_STRING, @ptrCast(&mpv_path)) == 0) {
                if (mpv_path) |pp| {
                    const pp_span = std.mem.span(pp);
                    if (pp_span.len > 0 and pp_span.len <= 2048) {
                        url = pp_span;
                    }
                }
            }
        }

        std.debug.print("[workspace] player {d}: source_url_len={d} current_url_len={d} browser_url_len={d} url='{s}'\n",
            .{ pi, p.source_url_len, p.current_url_len, p.browser_url_len, url });

        if (url.len == 0) continue;

        var percent: f64 = 0.0;
        _ = c.mpv.mpv_get_property(p.mpv_ctx, "percent-pos", c.mpv.MPV_FORMAT_DOUBLE, &percent);

        ws_players.append(allocator, .{
            .source_url = url,
            .is_torrent = p.is_torrent,
            .cell_volume = p.cell_volume,
            .playback_percent = percent,
        }) catch continue;
    }

    const data = WorkspaceData{
        .players = ws_players.items,
        .hwdec_enabled = state.app.hwdec_enabled,
        .seek_sync = state.app.seek_sync,
        .drawer_width_px = state.app.drawer_width_px,
    };

    // Build save path: ~/.config/zigzag/workspaces/<name>.json
    var dir_buf: [512]u8 = undefined;
    const ws_dir = workspacesDir(&dir_buf);
    var path_buf: [640]u8 = undefined;
    const save_path = std.fmt.bufPrint(&path_buf, "{s}/{s}.json", .{ ws_dir, name }) catch {
        state.showToast("Path too long");
        return;
    };

    const out_file = @import("../core/io_global.zig").cwdCreateFile(save_path, .{ .truncate = true }) catch {
        state.showToast("Failed to create workspace file");
        return;
    };
    defer out_file.close(@import("../core/io_global.zig").io());

    const json_bytes = std.json.Stringify.valueAlloc(allocator, data, .{ .whitespace = .indent_2 }) catch {
        state.showToast("Failed to serialize workspace");
        return;
    };
    defer allocator.free(json_bytes);
    @import("../core/io_global.zig").writeAll(out_file, json_bytes) catch {
        state.showToast("Failed to write workspace");
        return;
    };

    logs.pushLog("info", "workspace", "Workspace saved", false);
    state.showToast("Workspace saved");

    // Refresh the workspace list
    scanWorkspaces();
}

/// Load a workspace by name.
pub fn loadWorkspaceNamed(allocator: std.mem.Allocator, name: []const u8) void {
    var dir_buf: [512]u8 = undefined;
    const ws_dir = workspacesDir(&dir_buf);
    var path_buf: [640]u8 = undefined;
    const load_path = std.fmt.bufPrint(&path_buf, "{s}/{s}.json", .{ ws_dir, name }) catch {
        state.showToast("Path too long");
        return;
    };

    const file = @import("../core/io_global.zig").cwdOpenFile(load_path, .{}) catch {
        state.showToast("Workspace not found");
        return;
    };
    defer file.close(@import("../core/io_global.zig").io());

    const max_bytes = 1024 * 1024 * 5;
    const contents = @import("../core/io_global.zig").readToEndAlloc(file, allocator, max_bytes) catch {
        state.showToast("Failed to read workspace");
        return;
    };
    defer allocator.free(contents);

    var parsed = std.json.parseFromSlice(WorkspaceData, allocator, contents, .{ .ignore_unknown_fields = true }) catch {
        state.showToast("Workspace file corrupted");
        return;
    };
    defer parsed.deinit();

    const data = parsed.value;

    // Apply global state
    state.app.hwdec_enabled = data.hwdec_enabled;
    state.app.seek_sync = data.seek_sync;
    state.app.drawer_width_px = data.drawer_width_px;

    // Purge existing players safely
    for (state.app.players.items) |p| {
        p.deinit(allocator);
    }
    state.app.players.clearRetainingCapacity();

    var any_success = false;

    for (data.players) |wsp| {
        if (player.MediaPlayer.init(allocator)) |p| {
            p.cell_volume = wsp.cell_volume;
            state.app.players.append(allocator, p) catch {
                p.deinit(allocator);
                continue;
            };
            any_success = true;

            if (wsp.source_url.len > 0 and wsp.source_url.len < 2048) {
                var c_str: [2048]u8 = undefined;
                @memcpy(c_str[0..wsp.source_url.len], wsp.source_url);
                c_str[wsp.source_url.len] = 0;

                const c_url = @as([*c]const u8, @ptrCast(&c_str[0]));

                @memcpy(p.source_url[0..wsp.source_url.len], wsp.source_url);
                p.source_url_len = wsp.source_url.len;

                if (wsp.is_torrent) {
                    const tid = c.mpv.torrent_add_magnet(state.app.torrent_ses, c_url, state.getSavePath());
                    if (tid >= 0) {
                        p.current_torrent_id = tid;
                        p.torrent_is_ready = false;
                        p.has_metadata = false;
                        p.last_load_time = 0;
                        p.is_torrent = true;
                        p.resume_percent = wsp.playback_percent;
                    } else {
                        @import("../core/logs.zig").pushLog("error", "workspace", "Failed to restore torrent (invalid/duplicate magnet)", true);
                    }
                } else {
                    p.is_torrent = false;
                    p.resume_percent = wsp.playback_percent;
                    p.load_file(c_url);
                }
            } else {
                p.is_torrent = false;
            }
        } else |_| {}
    }

    if (any_success) {
        state.app.active_player_idx = 0;
        logs.pushLog("info", "workspace", "Workspace loaded", false);
        state.showToast("Workspace restored");
    } else {
        state.showToast("Workspace was empty");
    }
}

/// Legacy wrappers for backward compatibility
pub fn saveWorkspace(allocator: std.mem.Allocator) void {
    saveWorkspaceNamed(allocator, "default");
}

pub fn loadWorkspace(allocator: std.mem.Allocator) void {
    loadWorkspaceNamed(allocator, "default");
}
