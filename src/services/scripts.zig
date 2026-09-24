const std = @import("std");
const state = @import("../core/state.zig");
const paths = @import("../core/paths.zig");
const db = @import("../core/db.zig");
const logs = @import("../core/logs.zig");
const sync = @import("../core/sync.zig");

// ══════════════════════════════════════════════════════════
// MPV Script Manager
// Scans ~/.config/mpv/scripts/ and ~/.config/opal/scripts/
// Persists enable/disable state in SQLite
// ══════════════════════════════════════════════════════════

/// Scan directories for .lua / .js mpv scripts and script dirs (containing main.lua).
pub fn scanScripts() void {
    if (state.app.scripts_scanned) return;
    state.app.script_count = 0;

    // Scan Opal scripts dir first
    var opal_dir_buf: [512]u8 = undefined;
    var __cfg_buf_0: [512]u8 = undefined;
    const home = @import("../core/paths.zig").configDir(&__cfg_buf_0);
    const opal_scripts = std.fmt.bufPrint(&opal_dir_buf, "{s}/scripts", .{home}) catch "";
    if (opal_scripts.len > 0) scanDir(opal_scripts);

    // Scan mpv scripts dir
    var mpv_dir_buf: [512]u8 = undefined;
    const mpv_scripts = std.fmt.bufPrint(&mpv_dir_buf, "{s}/.config/mpv/scripts", .{home}) catch "";
    if (mpv_scripts.len > 0) scanDir(mpv_scripts);

    // Load enabled/disabled state from DB
    loadScriptStates();
    state.app.scripts_scanned = true;
}

fn scanDir(dir_path: []const u8) void {
    var dir = @import("../core/io_global.zig").openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close(@import("../core/io_global.zig").io());

    var iter = dir.iterate();
    while (iter.next(@import("../core/io_global.zig").io()) catch null) |entry| {
        if (state.app.script_count >= 32) break;
        const idx = state.app.script_count;

        const name = entry.name;
        const name_len = name.len;

        // Accept .lua files, .js files, or directories (containing main.lua)
        const is_script = switch (entry.kind) {
            .file => std.mem.endsWith(u8, name, ".lua") or std.mem.endsWith(u8, name, ".js"),
            .directory => blk: {
                // Check if directory contains main.lua
                var check_buf: [768]u8 = undefined;
                const check_path = std.fmt.bufPrint(&check_buf, "{s}/{s}/main.lua", .{ dir_path, name }) catch break :blk false;
                if (@import("../core/io_global.zig").openFileAbsolute(check_path, .{})) |f| {
                    f.close(@import("../core/io_global.zig").io());
                    break :blk true;
                } else |_| break :blk false;
            },
            else => false,
        };

        if (!is_script) continue;
        if (name_len >= 128) continue;

        // Store name
        @memcpy(state.app.script_names[idx][0..name_len], name[0..name_len]);
        state.app.script_name_lens[idx] = name_len;

        // Store full path
        var full_path_buf: [512]u8 = undefined;
        const full_path = std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ dir_path, name }) catch continue;
        if (full_path.len >= 512) continue;
        @memcpy(state.app.script_paths[idx][0..full_path.len], full_path);
        state.app.script_path_lens[idx] = full_path.len;

        state.app.script_enabled[idx] = true; // default enabled
        state.app.script_count += 1;
    }
}

/// Load persisted enable/disable states from SQLite.
fn loadScriptStates() void {
    const sql = "SELECT key, value FROM config WHERE key LIKE 'script_%'";
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);

    while (db.step(stmt) == db.c.SQLITE_ROW) {
        if (db.columnText(stmt, 0)) |key| {
            if (db.columnText(stmt, 1)) |val| {
                // key format: "script_<name>"
                if (key.len > 7) {
                    const script_name = key[7..];
                    const enabled = !std.mem.eql(u8, val, "0");

                    // Find matching script by name
                    for (0..state.app.script_count) |i| {
                        const name = state.app.script_names[i][0..state.app.script_name_lens[i]];
                        if (std.mem.eql(u8, name, script_name)) {
                            state.app.script_enabled[i] = enabled;
                            break;
                        }
                    }
                }
            }
        }
    }
}

/// Save a script's enabled state to SQLite.
pub fn saveScriptState(idx: usize) void {
    if (idx >= state.app.script_count) return;
    const name = state.app.script_names[idx][0..state.app.script_name_lens[idx]];

    var key_buf: [160]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "script_{s}", .{name}) catch return;

    const val = if (state.app.script_enabled[idx]) "1" else "0";

    const sql = "INSERT OR REPLACE INTO config (key, value) VALUES (?1, ?2)";
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, key);
    db.bindText(stmt, 2, val);
    _ = db.step(stmt);
}

// ══════════════════════════════════════════════════════════
// Recommended Scripts (download links)
// ══════════════════════════════════════════════════════════

pub const RecommendedScript = struct {
    name: []const u8,
    description: []const u8,
    url: []const u8,
    filename: []const u8,
};

pub const recommended_scripts = [_]RecommendedScript{
    .{
        .name = "sponsorblock_minimal",
        .description = "Skip YouTube sponsors/intros",
        .url = "https://codeberg.org/jouni/mpv_sponsorblock_minimal/raw/branch/master/sponsorblock_minimal.lua",
        .filename = "sponsorblock_minimal.lua",
    },
    .{
        .name = "autoload",
        .description = "Auto-load playlist from folder",
        .url = "https://raw.githubusercontent.com/mpv-player/mpv/master/TOOLS/lua/autoload.lua",
        .filename = "autoload.lua",
    },
    .{
        .name = "quality-menu",
        .description = "Stream quality selector (ytdl)",
        .url = "https://raw.githubusercontent.com/christoph-heinrich/mpv-quality-menu/master/quality-menu.lua",
        .filename = "quality-menu.lua",
    },
    .{
        .name = "thumbfast",
        .description = "High-performance seek thumbnails",
        .url = "https://raw.githubusercontent.com/po5/thumbfast/master/thumbfast.lua",
        .filename = "thumbfast.lua",
    },
};

pub const ScriptInstallStatus = enum { idle, downloading, installed, failed };
var install_status: [recommended_scripts.len]ScriptInstallStatus = [_]ScriptInstallStatus{.idle} ** recommended_scripts.len;
var install_mutex: sync.Mutex = .{};

pub fn installStatus(idx: usize) ScriptInstallStatus {
    if (idx >= recommended_scripts.len) return .idle;
    install_mutex.lock();
    defer install_mutex.unlock();
    return install_status[idx];
}

fn finishInstall(idx: usize, success: bool) void {
    install_mutex.lock();
    install_status[idx] = if (success) .installed else .failed;
    install_mutex.unlock();
    state.app.scripts_scanned = false;
    state.wakeUi();
}

/// Fetch a curated mpv script into Opal's scripts folder.
pub fn installScript(rec_idx: usize) void {
    if (rec_idx >= recommended_scripts.len) return;
    install_mutex.lock();
    if (install_status[rec_idx] == .downloading) {
        install_mutex.unlock();
        return;
    }
    install_status[rec_idx] = .downloading;
    install_mutex.unlock();
    const thread = @import("../core/workers.zig").spawnLegacy(installScriptWorker, .{rec_idx}) catch {
        finishInstall(rec_idx, false);
        logs.pushLog("error", "scripts", "Could not start script download worker", true);
        return;
    };
    @import("../core/workers.zig").release(thread);
}

fn installScriptWorker(idx: usize) void {
    const rec = recommended_scripts[idx];
    var cfg_buf: [512]u8 = undefined;
    var dir_buf: [600]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buf, "{s}/scripts", .{paths.configDir(&cfg_buf)}) catch {
        finishInstall(idx, false);
        logs.pushLog("error", "scripts", "Scripts folder path is too long", true);
        return;
    };
    const io = @import("../core/io_global.zig");
    io.cwdMakePath(dir) catch {
        finishInstall(idx, false);
        logs.pushLog("error", "scripts", "Could not create scripts folder", true);
        return;
    };
    var file_buf: [768]u8 = undefined;
    const dest = std.fmt.bufPrint(&file_buf, "{s}/{s}", .{ dir, rec.filename }) catch {
        finishInstall(idx, false);
        logs.pushLog("error", "scripts", "Script output path is too long", true);
        return;
    };
    var msg: [384]u8 = undefined;
    logs.pushLog("info", "scripts", std.fmt.bufPrint(&msg, "curl -fLsS --max-time 15 -o <Opal scripts>/{s} {s}", .{ rec.filename, rec.url }) catch "Downloading curated script", false);
    var child = io.Child.init(&.{ "curl", "-fLsS", "--max-time", "15", "-o", dest, rec.url }, @import("../core/alloc.zig").allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = child.spawnAndWait() catch {
        finishInstall(idx, false);
        logs.pushLog("error", "scripts", "Script download failed to start", true);
        return;
    };
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) io.cwdDeleteFile(dest) catch {};
    finishInstall(idx, ok);
    logs.pushLog(if (ok) "info" else "error", "scripts", std.fmt.bufPrint(&msg, "{s}: {s}", .{ rec.name, if (ok) "installed" else "download failed" }) catch "Script download finished", !ok);
}
