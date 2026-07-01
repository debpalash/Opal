const std = @import("std");
const state = @import("state.zig");
const paths = @import("paths.zig");
const db = @import("db.zig");
const theme = @import("../ui/theme.zig");

/// Persistent config — saves/loads from opal.db config table.
/// Migrates from old config.tsv on first run.
pub fn ensureDir() void {
    var buf: [512]u8 = undefined;
    const dir = paths.configDir(&buf);
    std.Io.Dir.cwd().createDirPath(@import("io_global.zig").io(), dir) catch {};
}

pub fn save() void {
    const d = db.get() orelse return;
    _ = d;

    db.exec("BEGIN");
    var fb: [64]u8 = undefined;

    // Accrue in-app usage time since the last save into the lifetime counter.
    accrueUsage();
    setKey("usage_seconds", fmtInt(&fb, @as(usize, @intCast(@max(0, state.app.usage_seconds_total)))));

    setKey("ui_scale", fmtFloat(&fb, state.app.ui_scale));
    setKey("grid_mode", switch (state.app.grid_mode) {
        .auto => "auto",
        .cols_1 => "1",
        .cols_2 => "2",
        .cols_3 => "3",
        .cols_4 => "4",
    });
    setKey("seek_sync", if (state.app.seek_sync) "1" else "0");
    setKey("hwdec", if (state.app.hwdec_enabled) "1" else "0");
    setKey("auto_advance", if (state.app.auto_advance) "1" else "0");
    setKey("nsfw_filter", if (state.app.nsfw_filter_enabled) "1" else "0");
    setKey("save_path", state.app.save_path_buf[0..state.app.save_path_len]);
    setKey("sub_lang", state.app.sub_lang_buf[0..state.app.sub_lang_len]);
    setKey("translate_lang", state.app.translate_lang_buf[0..state.app.translate_lang_len]);
    setKey("translate_enabled", if (state.app.translate_enabled) "1" else "0");
    setKey("tts_voice", state.app.tts_voice_buf[0..state.app.tts_voice_len]);
    setKey("tts_speed", fmtFloat(&fb, state.app.tts_speed));
    setKey("kokoro_sid", fmtInt(&fb, @as(usize, @import("../services/voice_backend.zig").kokoro_sid)));
    setKey("lang_learn", if (state.app.lang_learn_enabled) "1" else "0");
    setKey("asr_enabled", if (state.app.asr_enabled) "1" else "0");
    setKey("live_asr", if (state.app.live_asr_enabled) "1" else "0");
    setKey("dubbing_enabled", if (state.app.dubbing_enabled) "1" else "0");
    setKey("eq_preset", fmtInt(&fb, state.app.eq_preset));
    setKey("download_rate_limit", fmtInt(&fb, @as(usize, @intCast(state.app.download_rate_limit))));
    setKey("proxy_url", state.app.proxy_url[0..state.app.proxy_url_len]);
    setKey("ytdl_format_idx", fmtInt(&fb, state.app.ytdl_format_idx));
    setKey("drawer_width_px", fmtFloat(&fb, state.app.drawer_width_px));
    setKey("tmdb_api_key", state.app.tmdb.api_key[0..state.app.tmdb.api_key_len]);
    setKey("opensub_api_key", state.app.opensub_api_key[0..state.app.opensub_api_key_len]);
    setKey("sponsorblock_enabled", if (state.app.sponsorblock_enabled) "1" else "0");
    setKey("deband_enabled", if (state.app.deband_enabled) "1" else "0");
    setKey("video_scaler", fmtInt(&fb, @as(usize, state.app.video_scaler)));
    setKey("jf_server_url", state.app.jf.server_url[0..state.app.jf.server_url_len]);
    setKey("jf_token", state.app.jf.token[0..state.app.jf.token_len]);
    setKey("jf_user_id", state.app.jf.user_id[0..state.app.jf.user_id_len]);
    if (state.app.jf.token_len > 0) {
        setKey("jf_connected", "1");
    } else {
        setKey("jf_connected", "0");
    }

    // Window state
    setKey("win_x", fmtInt(&fb, @as(usize, @intCast(@max(0, state.app.win_x)))));
    setKey("win_y", fmtInt(&fb, @as(usize, @intCast(@max(0, state.app.win_y)))));
    setKey("win_w", fmtInt(&fb, @as(usize, @intCast(@max(100, state.app.win_w)))));
    setKey("win_h", fmtInt(&fb, @as(usize, @intCast(@max(100, state.app.win_h)))));
    // drawer_open intentionally not persisted — always start with sidebar closed
    setKey("theme_preset", theme.presetName(theme.active_preset));

    // AI backend + selected Hugging Face model (the model picker).
    const ai_server = @import("../services/ai_server.zig");
    setKey("ai_backend", switch (ai_server.backend_kind) {
        .apfel => "apfel",
        .gemma_llama => "llama",
    });
    setKey("ai_model_id", ai_server.activeModelId());

    saveSessionUrls();

    db.exec("COMMIT");
}

/// Add the seconds elapsed since the last accrual to the lifetime usage
/// counter. Idempotent-safe: advances `usage_last_tick` so the same wall-clock
/// span is never counted twice. Called from save() and at exit.
pub fn accrueUsage() void {
    const now = @import("io_global.zig").timestamp();
    if (state.app.usage_last_tick == 0) {
        state.app.usage_last_tick = now;
        if (state.app.session_start_s == 0) state.app.session_start_s = now;
        return;
    }
    const delta = now - state.app.usage_last_tick;
    // Guard against clock skew / suspend producing absurd jumps (> 12h).
    if (delta > 0 and delta < 12 * 3600) state.app.usage_seconds_total += delta;
    state.app.usage_last_tick = now;
}

fn saveSessionUrls() void {
    {
        const del_sql = "DELETE FROM config WHERE key LIKE 'session_url_%'";
        const del_stmt = db.prepare(del_sql) orelse return;
        defer db.finalize(del_stmt);
        _ = db.step(del_stmt);
    }
    if (state.app.incognito_mode) return;
    var slot: usize = 0;
    var i: usize = 0;
    while (i < state.app.players.items.len and slot < 16) : (i += 1) {
        const p = state.app.players.items[i];
        if (p.current_url_len == 0 or p.current_url_len > p.current_url.len) continue;
        const url = p.current_url[0..p.current_url_len];
        // Skip ephemeral torrent-streaming loopback URLs; torrent has random port.
        if (std.mem.startsWith(u8, url, "http://127.0.0.1:") or
            std.mem.startsWith(u8, url, "http://localhost:")) continue;
        var key_buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "session_url_{d}", .{slot}) catch continue;
        setKey(key, url);
        slot += 1;
    }
}

/// Called every frame — flushes config to SQLite if dirty (2s debounce).
pub fn saveIfDirty() void {
    if (state.app.incognito_mode) return; // incognito: never persist
    if (!state.app.config_dirty) return;
    const now = @import("io_global.zig").timestamp();
    if (now - state.app.last_config_save < 2) return; // debounce
    state.app.config_dirty = false;
    state.app.last_config_save = now;
    save();
}

pub fn load() void {
    ensureDir();

    const sql = "SELECT key, value FROM config";
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);

    while (db.step(stmt) == db.c.SQLITE_ROW) {
        const key = db.columnText(stmt, 0) orelse continue;
        const val = db.columnText(stmt, 1) orelse continue;
        applyConfig(key, val);
    }

    // Start this session's usage clock now that the lifetime total is loaded.
    const now = @import("io_global.zig").timestamp();
    state.app.session_start_s = now;
    state.app.usage_last_tick = now;
}

fn setKey(key: []const u8, val: []const u8) void {
    const sql = "INSERT OR REPLACE INTO config (key, value) VALUES (?1, ?2)";
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, key);
    db.bindText(stmt, 2, val);
    _ = db.step(stmt);
}

fn applyConfig(key: []const u8, val: []const u8) void {
    if (std.mem.eql(u8, key, "usage_seconds")) {
        state.app.usage_seconds_total = std.fmt.parseInt(i64, val, 10) catch 0;
    } else if (std.mem.eql(u8, key, "ui_scale")) {
        state.app.ui_scale = std.fmt.parseFloat(f32, val) catch 1.3;
    } else if (std.mem.eql(u8, key, "grid_mode")) {
        state.app.grid_mode = if (std.mem.eql(u8, val, "1")) .cols_1 else if (std.mem.eql(u8, val, "2")) .cols_2 else if (std.mem.eql(u8, val, "3")) .cols_3 else if (std.mem.eql(u8, val, "4")) .cols_4 else .auto;
    } else if (std.mem.eql(u8, key, "seek_sync")) {
        state.app.seek_sync = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "hwdec")) {
        state.app.hwdec_enabled = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "auto_advance")) {
        state.app.auto_advance = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "nsfw_filter")) {
        state.app.nsfw_filter_enabled = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "save_path")) {
        if (val.len > 0 and val.len < state.app.save_path_buf.len) {
            @memcpy(state.app.save_path_buf[0..val.len], val);
            state.app.save_path_len = val.len;
        }
    } else if (std.mem.eql(u8, key, "sub_lang")) {
        if (val.len > 0 and val.len <= 8) {
            @memcpy(state.app.sub_lang_buf[0..val.len], val);
            state.app.sub_lang_len = val.len;
        }
    } else if (std.mem.eql(u8, key, "translate_lang")) {
        if (val.len > 0 and val.len <= 8) {
            @memcpy(state.app.translate_lang_buf[0..val.len], val);
            state.app.translate_lang_len = val.len;
        }
    } else if (std.mem.eql(u8, key, "translate_enabled")) {
        state.app.translate_enabled = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "tts_voice")) {
        if (val.len > 0 and val.len <= 16) {
            @memcpy(state.app.tts_voice_buf[0..val.len], val);
            state.app.tts_voice_len = val.len;
        }
    } else if (std.mem.eql(u8, key, "tts_speed")) {
        state.app.tts_speed = std.fmt.parseFloat(f32, val) catch 1.0;
    } else if (std.mem.eql(u8, key, "kokoro_sid")) {
        const sid = std.fmt.parseInt(u16, val, 10) catch 0;
        @import("../services/voice_backend.zig").kokoro_sid = if (sid <= 53) sid else 53;
    } else if (std.mem.eql(u8, key, "lang_learn")) {
        state.app.lang_learn_enabled = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "asr_enabled")) {
        state.app.asr_enabled = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "live_asr")) {
        // setEnabled reflects the flag into state AND starts/stops the worker;
        // also keeps live_asr.zig in the compile graph (it has no other caller yet).
        @import("../services/live_asr.zig").setEnabled(std.mem.eql(u8, val, "1"));
    } else if (std.mem.eql(u8, key, "dubbing_enabled")) {
        state.app.dubbing_enabled = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "eq_preset")) {
        state.app.eq_preset = std.fmt.parseInt(usize, val, 10) catch 0;
    } else if (std.mem.eql(u8, key, "download_rate_limit")) {
        state.app.download_rate_limit = std.fmt.parseInt(i32, val, 10) catch 0;
    } else if (std.mem.eql(u8, key, "proxy_url")) {
        if (val.len > 0 and val.len < state.app.proxy_url.len) {
            @memcpy(state.app.proxy_url[0..val.len], val);
            state.app.proxy_url_len = val.len;
        }
    } else if (std.mem.eql(u8, key, "ytdl_format_idx")) {
        const idx = std.fmt.parseInt(usize, val, 10) catch 1;
        state.app.ytdl_format_idx = if (idx < 4) idx else 1;
    } else if (std.mem.eql(u8, key, "drawer_width_px")) {
        state.app.drawer_width_px = std.fmt.parseFloat(f32, val) catch 480.0;
    } else if (std.mem.eql(u8, key, "tmdb_api_key")) {
        if (val.len > 0 and val.len <= 256) {
            @memcpy(state.app.tmdb.api_key[0..val.len], val);
            state.app.tmdb.api_key_len = val.len;
        }
    } else if (std.mem.eql(u8, key, "opensub_api_key")) {
        if (val.len > 0 and val.len <= 128) {
            @memcpy(state.app.opensub_api_key[0..val.len], val);
            state.app.opensub_api_key_len = val.len;
        }
    } else if (std.mem.eql(u8, key, "sponsorblock_enabled")) {
        state.app.sponsorblock_enabled = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "deband_enabled")) {
        state.app.deband_enabled = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "video_scaler")) {
        const v = std.fmt.parseInt(u8, val, 10) catch 0;
        state.app.video_scaler = if (v <= 2) v else 0;
    } else if (std.mem.eql(u8, key, "jf_server_url")) {
        if (val.len > 0 and val.len < state.app.jf.server_url.len) {
            @memcpy(state.app.jf.server_url[0..val.len], val);
            state.app.jf.server_url_len = val.len;
        }
    } else if (std.mem.eql(u8, key, "jf_token")) {
        if (val.len > 0 and val.len < state.app.jf.token.len) {
            @memcpy(state.app.jf.token[0..val.len], val);
            state.app.jf.token_len = val.len;
        }
    } else if (std.mem.eql(u8, key, "jf_user_id")) {
        if (val.len > 0 and val.len < state.app.jf.user_id.len) {
            @memcpy(state.app.jf.user_id[0..val.len], val);
            state.app.jf.user_id_len = val.len;
        }
    } else if (std.mem.eql(u8, key, "jf_connected")) {
        // Only mark as connected if we also have a token
        state.app.jf.connected = std.mem.eql(u8, val, "1") and state.app.jf.token_len > 0;
    } else if (std.mem.eql(u8, key, "win_x")) {
        state.app.win_x = std.fmt.parseInt(i32, val, 10) catch 0;
        state.app.win_restore_pending = true;
    } else if (std.mem.eql(u8, key, "win_y")) {
        state.app.win_y = std.fmt.parseInt(i32, val, 10) catch 0;
    } else if (std.mem.eql(u8, key, "win_w")) {
        state.app.win_w = std.fmt.parseInt(i32, val, 10) catch 1440;
    } else if (std.mem.eql(u8, key, "win_h")) {
        state.app.win_h = std.fmt.parseInt(i32, val, 10) catch 800;
    } else if (std.mem.eql(u8, key, "drawer_open")) {
        // Ignored — sidebar always starts closed for a clean first impression
    } else if (std.mem.startsWith(u8, key, "session_url_")) {
        const idx_str = key["session_url_".len..];
        const idx = std.fmt.parseInt(usize, idx_str, 10) catch return;
        if (idx >= 16 or val.len == 0 or val.len >= 2048) return;
        if (std.mem.startsWith(u8, val, "http://127.0.0.1:") or
            std.mem.startsWith(u8, val, "http://localhost:")) return;
        @memcpy(state.app.session_restore_urls[idx][0..val.len], val);
        state.app.session_restore_lens[idx] = val.len;
        if (idx + 1 > state.app.session_restore_count) {
            state.app.session_restore_count = idx + 1;
        }
    } else if (std.mem.eql(u8, key, "theme_preset")) {
        const presets = [_]struct { name: []const u8, preset: theme.ThemePreset }{
            .{ .name = "Midnight", .preset = .midnight },
            .{ .name = "Abyss", .preset = .abyss },
            .{ .name = "Phantom", .preset = .phantom },
            .{ .name = "Nord", .preset = .nord },
            .{ .name = "Solarized", .preset = .solarized },
            .{ .name = "Rosé", .preset = .rose },
            .{ .name = "Ember", .preset = .ember },
        };
        for (presets) |p| {
            if (std.mem.eql(u8, val, p.name)) {
                theme.setPreset(p.preset);
                break;
            }
        }
    } else if (std.mem.eql(u8, key, "ai_backend")) {
        const ai_server = @import("../services/ai_server.zig");
        ai_server.backend_kind = if (std.mem.eql(u8, val, "apfel")) .apfel else .gemma_llama;
    } else if (std.mem.eql(u8, key, "ai_model_id")) {
        @import("../services/ai_server.zig").selectModelById(val);
    }
}

// ══════════════════════════════════════════════════════════
// Migration from old config.tsv
// ══════════════════════════════════════════════════════════

pub fn migrateFromTsv() void {
    var path_buf: [512]u8 = undefined;
    const tsv_path = paths.configFile(&path_buf);

    const io = @import("io_global.zig").io();
    const file = std.Io.Dir.openFileAbsolute(io, tsv_path, .{}) catch return;
    defer file.close(io);

    var buf: [8192]u8 = undefined;
    const bytes_read = file.readPositionalAll(io, &buf, 0) catch return;
    if (bytes_read == 0) return;

    db.exec("BEGIN");

    var lines = std.mem.splitScalar(u8, buf[0..bytes_read], '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.indexOfScalar(u8, line, '=')) |eq_pos| {
            const key = line[0..eq_pos];
            const val = line[eq_pos + 1 ..];
            setKey(key, val);
        }
    }

    db.exec("COMMIT");

    // Rename old file
    var new_buf: [512]u8 = undefined;
    const new_path = std.fmt.bufPrint(&new_buf, "{s}.migrated", .{tsv_path}) catch return;
    std.Io.Dir.renameAbsolute(tsv_path, new_path, @import("io_global.zig").io()) catch {};
}

// ══════════════════════════════════════════════════════════
// Formatting helpers
// ══════════════════════════════════════════════════════════

fn fmtFloat(buf: *[64]u8, v: f32) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.2}", .{v}) catch "0";
}

fn fmtInt(buf: *[64]u8, v: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch "0";
}
