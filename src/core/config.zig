const std = @import("std");
const state = @import("state.zig");
const paths = @import("paths.zig");
const db = @import("db.zig");
const theme = @import("../ui/theme.zig");
const watch_history_pure = @import("../player/watch_history_pure.zig");
const secret_store = @import("secret_store.zig");

var legacy_secrets_mask: u16 = 0;

fn secretBit(key: []const u8) u16 {
    const names = [_][]const u8{
        "proxy_url",    "tmdb_api_key",  "opensub_api_key",
        "omdb_api_key", "subdl_api_key", "jf_token",
        "abs_token",    "opds_user",     "opds_pass",
    };
    for (names, 0..) |name, index| {
        if (std.mem.eql(u8, key, name)) return @as(u16, 1) << @intCast(index);
    }
    return 0;
}

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
    if (@import("install_identity_pure.zig").valid(&state.app.install_id)) {
        setKey("install_id", &state.app.install_id);
    }

    setKey("ui_scale", fmtFloat(&fb, state.app.ui_scale));
    setKey("ui_scale_auto", if (state.app.ui_scale_auto) "1" else "0");
    setKey("reduce_motion", if (state.app.reduce_motion) "1" else "0");
    setKey("grid_mode", switch (state.app.grid_mode) {
        .auto => "auto",
        .cols_1 => "1",
        .cols_2 => "2",
        .cols_3 => "3",
        .cols_4 => "4",
    });
    setKey("seek_sync", if (state.app.seek_sync) "1" else "0");
    setKey("hwdec2", if (state.app.hwdec_enabled) "1" else "0");
    setKey("auto_advance", if (state.app.auto_advance) "1" else "0");
    setKey("playlist_repeat", @tagName(state.app.playlist_repeat));
    setKey("playlist_shuffle", if (state.app.playlist_shuffle) "1" else "0");
    setKey("playlist_shuffle_seed", fmtInt(&fb, @intCast(state.app.playlist_shuffle_seed)));
    setKey("nsfw_filter", if (state.app.nsfw_filter_enabled) "1" else "0");
    setKey("gallerydl_enabled", if (state.app.gallerydl_enabled) "1" else "0");
    setKey("scrape_use_browser", if (state.app.scrape_use_browser) "1" else "0");
    setKey("prefetch_playlist", if (state.app.prefetch_playlist) "1" else "0");
    setKey("audio_passthrough", if (state.app.audio_passthrough) "1" else "0");
    setKey("audio_exclusive", if (state.app.audio_exclusive) "1" else "0");
    setKey("taste_suggestions", if (state.app.taste_enabled) "1" else "0");
    setKey("content_cache_enabled", if (state.app.content_cache_enabled) "1" else "0");
    setKey("auto_download_subs", if (state.app.auto_download_subs) "1" else "0");
    setKey("save_path", state.app.save_path_buf[0..state.app.save_path_len]);
    setKey("sub_lang", state.app.sub_lang_buf[0..state.app.sub_lang_len]);
    setKey("subtitles_enabled", if (state.app.subtitles_enabled) "1" else "0");
    setKey("audio_lang", state.app.audio_lang_buf[0..state.app.audio_lang_len]);
    setKey("audio_device", state.app.audio_device_buf[0..state.app.audio_device_len]);
    setKey("video_aspect", state.app.video_aspect_buf[0..state.app.video_aspect_len]);
    setKey("playback_volume", fmtFloat(&fb, @floatCast(state.app.playback_volume)));
    setKey("playback_speed", fmtFloat(&fb, @floatCast(state.app.playback_speed)));
    setKey("playback_muted", if (state.app.playback_muted) "1" else "0");
    setKey("video_fill_mode", @tagName(state.app.video_fill_mode));
    setKey("translate_lang", state.app.translate_lang_buf[0..state.app.translate_lang_len]);
    setKey("translate_enabled", if (state.app.translate_enabled) "1" else "0");
    setKey("tts_voice", state.app.tts_voice_buf[0..state.app.tts_voice_len]);
    setKey("tts_speed", fmtFloat(&fb, state.app.tts_speed));
    setKey("kokoro_sid", fmtInt(&fb, @as(usize, @import("../services/voice_backend.zig").kokoro_sid)));
    setKey("music_discovery", if (state.app.music_discovery_enabled) "1" else "0");
    setKey("lang_learn", if (state.app.lang_learn_enabled) "1" else "0");
    setKey("asr_enabled", if (state.app.asr_enabled) "1" else "0");
    setKey("live_asr", if (state.app.live_asr_enabled) "1" else "0");
    setKey("dubbing_enabled", if (state.app.dubbing_enabled) "1" else "0");
    setKey("eq_preset", fmtInt(&fb, state.app.eq_preset));
    setKey("picture_preset", fmtInt(&fb, state.app.picture_preset));
    setKey("download_rate_limit", fmtInt(&fb, @as(usize, @intCast(state.app.download_rate_limit))));
    setKey("http_dl_segments", fmtInt(&fb, @as(usize, state.app.http_dl_segments)));
    setKey("http_dl_max_concurrent", fmtInt(&fb, @as(usize, state.app.http_dl_max_concurrent)));
    setSecretKey("proxy_url", state.app.proxy_url[0..state.app.proxy_url_len]);
    setKey("dpi_bypass_enabled", if (state.app.dpi_bypass_enabled) "1" else "0");
    setKey("dpi_bypass_mode", if (state.app.dpi_bypass_mode_len > 0) state.app.dpi_bypass_mode[0..state.app.dpi_bypass_mode_len] else "sni");
    setKey("ytdl_format_idx", fmtInt(&fb, state.app.ytdl_format_idx));
    setKey("drawer_width_px", fmtFloat(&fb, state.app.drawer_width_px));
    // Persist only USER keys, never the build-time embedded default: writing the
    // default would pin it in the user's DB and defeat key rotation, and would
    // make a fresh install look "already onboarded". Empty string clears the row.
    setSecretKey("tmdb_api_key", if (state.app.tmdb.api_key_is_default) "" else state.app.tmdb.api_key[0..state.app.tmdb.api_key_len]);
    setSecretKey("opensub_api_key", state.app.opensub_api_key[0..state.app.opensub_api_key_len]);
    setSecretKey("omdb_api_key", if (state.app.omdb_api_key_is_default) "" else state.app.omdb_api_key[0..state.app.omdb_api_key_len]);
    setSecretKey("subdl_api_key", state.app.subdl_api_key[0..state.app.subdl_api_key_len]);
    setKey("sponsorblock_enabled", if (state.app.sponsorblock_enabled) "1" else "0");
    setKey("anime_skip_enabled", if (state.app.anime_skip_enabled) "1" else "0");
    setKey("anime_skip_intro", if (state.app.anime_skip_intro) "1" else "0");
    setKey("anime_skip_recap", if (state.app.anime_skip_recap) "1" else "0");
    setKey("anime_skip_credits", if (state.app.anime_skip_credits) "1" else "0");
    setKey("anime_skip_preview", if (state.app.anime_skip_preview) "1" else "0");
    setKey("deband_enabled", if (state.app.deband_enabled) "1" else "0");
    setKey("video_scaler", fmtInt(&fb, @as(usize, state.app.video_scaler)));
    // Video color filters (signed −100..100) — replayed at player init.
    setKey("vf_brightness", fmtI32(&fb, state.app.vf_brightness));
    setKey("vf_contrast", fmtI32(&fb, state.app.vf_contrast));
    setKey("vf_saturation", fmtI32(&fb, state.app.vf_saturation));
    setKey("vf_gamma", fmtI32(&fb, state.app.vf_gamma));
    setKey("cowatch_sensitivity", @tagName(@import("../services/co_watch.zig").sensitivity));
    setKey("jf_server_url", state.app.jf.server_url[0..state.app.jf.server_url_len]);
    setSecretKey("jf_token", state.app.jf.token[0..state.app.jf.token_len]);
    setKey("jf_user_id", state.app.jf.user_id[0..state.app.jf.user_id_len]);
    if (state.app.jf.token_len > 0) {
        setKey("jf_connected", "1");
    } else {
        setKey("jf_connected", "0");
    }

    // Audiobookshelf — persist server + token (the Bearer token is enough to
    // resume the session; the password is never stored).
    setKey("abs_server_url", state.app.abs.server_url[0..state.app.abs.server_url_len]);
    setSecretKey("abs_token", state.app.abs.token[0..state.app.abs.token_len]);
    setKey("abs_connected", if (state.app.abs.token_len > 0) "1" else "0");
    // OPDS reading server (Komga/Kavita/Calibre-Web/LANraragi). Basic-auth
    // credentials use the protected local envelope. The user/pass buffers are
    // null-terminated by the text-entry widget.
    {
        const u_len = std.mem.indexOfScalar(u8, &state.app.opds.user_buf, 0) orelse state.app.opds.user_buf.len;
        const p_len = std.mem.indexOfScalar(u8, &state.app.opds.pass_buf, 0) orelse state.app.opds.pass_buf.len;
        setKey("opds_url", state.app.opds.server_url[0..state.app.opds.server_url_len]);
        setSecretKey("opds_user", state.app.opds.user_buf[0..u_len]);
        setSecretKey("opds_pass", state.app.opds.pass_buf[0..p_len]);
        setKey("opds_connected", if (state.app.opds.connected) "1" else "0");
    }

    // Window state
    setKey("win_x", fmtInt(&fb, @as(usize, @intCast(@max(0, state.app.win_x)))));
    setKey("win_y", fmtInt(&fb, @as(usize, @intCast(@max(0, state.app.win_y)))));
    setKey("win_w", fmtInt(&fb, @as(usize, @intCast(@max(100, state.app.win_w)))));
    setKey("win_h", fmtInt(&fb, @as(usize, @intCast(@max(100, state.app.win_h)))));
    // drawer_open intentionally not persisted — always start with sidebar closed
    setKey("theme_preset", theme.presetName(theme.active_preset));
    setKey("audio_vis", @import("../player/player.zig").vis_style.label());

    // AI backend + selected Hugging Face model (the model picker).
    const ai_server = @import("../services/ai_server.zig");
    setKey("ai_backend", switch (ai_server.backend_kind) {
        .apfel => "apfel",
        .gemma_llama => "llama",
        .cloud => "cloud",
    });
    setKey("ai_model_id", ai_server.activeModelId());
    setKey("ai_cloud_provider", ai_server.cloudProvider().id);
    setKey("web_remote", if (state.app.web_remote_enabled) "1" else "0");
    {
        const remote = @import("../services/remote.zig");
        setKey("web_bind", remote.bind_mode.id());
        var port_buf: [8]u8 = undefined;
        setKey("web_port", std.fmt.bufPrint(&port_buf, "{d}", .{remote.port}) catch "41595");
    }
    setKey("custom_titlebar", if (state.app.custom_titlebar) "1" else "0");
    setKey("onboarded", if (state.app.onboarded) "1" else "0");

    // In-app browser engine (camoufox = Firefox, cloakbrowser = Chromium).
    setKey("browser_engine", @tagName(@import("../services/browser.zig").active_engine));

    // Voice (STT/TTS) backend — the settings page said "Changes saved
    // automatically." while this selection silently reset on restart.
    const voice_backend = @import("../services/voice_backend.zig");
    setKey("voice_backend", @tagName(voice_backend.active_kind));

    // Universal-search source filter (bit per source pill) — exclusions stick
    // across restarts.
    const resolver = @import("../services/resolver.zig");
    setKey("search_sources", fmtInt(&fb, resolver.source_mask.load(.acquire)));

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
    if (!state.app.session_close_captured and state.app.session_saved and
        (!state.app.resume_prompt_checked or state.app.resume_prompt_active)) return;
    if (state.app.session_close_captured) {
        db.exec("DELETE FROM config WHERE key LIKE 'session_url_%'");
        setKey("session_saved", if (state.app.incognito_mode) "0" else "1");
        if (state.app.incognito_mode) return;
        var buf: [64]u8 = undefined;
        setKey("session_route", @tagName(state.app.session_route));
        setKey("session_position", std.fmt.bufPrint(&buf, "{d:.3}", .{state.app.session_position}) catch "0");
        setKey("session_paused", if (state.app.session_paused) "1" else "0");
        setKey("session_speed", std.fmt.bufPrint(&buf, "{d:.3}", .{state.app.session_speed}) catch "1");
        setKey("session_file_idx", std.fmt.bufPrint(&buf, "{d}", .{state.app.session_file_idx}) catch "-1");
        setKey("session_tv_id", std.fmt.bufPrint(&buf, "{d}", .{state.app.session_tv_id}) catch "0");
        setKey("session_tv_season", std.fmt.bufPrint(&buf, "{d}", .{state.app.session_tv_season}) catch "0");
        setKey("session_tv_episode", std.fmt.bufPrint(&buf, "{d}", .{state.app.session_tv_episode}) catch "0");
        const pe = &state.app.playing_episode;
        if (state.app.session_tv_id != 0 and pe.tmdb_id == state.app.session_tv_id and pe.season == state.app.session_tv_season and pe.episode == state.app.session_tv_episode) {
            db.tvSavePosition(pe.tmdb_id, pe.season, pe.episode, state.app.session_position, state.app.session_duration);
            db.tvSavePlayedSeconds(pe.tmdb_id, pe.season, pe.episode, pe.played_seconds);
        }
        if (state.app.session_restore_count > 0) {
            const raw = state.app.session_restore_urls[0][0..state.app.session_restore_lens[0]];
            var safe_buf: [2048]u8 = undefined;
            const safe = watch_history_pure.persistedTarget(raw, &safe_buf).reopen;
            if (safe.len > 0) setKey("session_url_0", safe);
        }
        return;
    }
    {
        const del_sql = "DELETE FROM config WHERE key LIKE 'session_url_%'";
        const del_stmt = db.prepare(del_sql) orelse return;
        defer db.finalize(del_stmt);
        _ = db.step(del_stmt);
    }
    if (!state.app.session_saved) setKey("session_saved", "0");
    if (state.app.incognito_mode) return;
    var slot: usize = 0;
    var i: usize = 0;
    while (i < state.app.players.items.len and slot < 16) : (i += 1) {
        const p = state.app.players.items[i];
        if (p.current_url_len == 0 or p.current_url_len > p.current_url.len) continue;
        const url = if (p.restore_target_len > 0 and p.restore_target_len <= p.restore_target.len)
            p.restore_target[0..p.restore_target_len]
        else
            p.current_url[0..p.current_url_len];
        // Skip ephemeral torrent-streaming loopback URLs; torrent has random port.
        if (std.mem.startsWith(u8, url, "http://127.0.0.1:") or
            std.mem.startsWith(u8, url, "http://localhost:")) continue;
        var safe_buf: [2048]u8 = undefined;
        const safe = watch_history_pure.persistedTarget(url, &safe_buf).reopen;
        if (safe.len == 0) continue;
        var key_buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "session_url_{d}", .{slot}) catch continue;
        setKey(key, safe);
        slot += 1;
    }
}

/// Capture event-cached playback before stop clears it; SQLite is saved later.
pub fn captureCloseSession() void {
    const has_media = state.app.active_player_idx < state.app.players.items.len and blk: {
        const p = state.app.players.items[state.app.active_player_idx];
        break :blk p.current_url_len > 0 or (p.is_torrent and p.source_url_len > 0);
    };
    if (!state.app.incognito_mode and state.app.session_saved and !has_media and
        (!state.app.resume_prompt_checked or (state.app.resume_prompt_session and state.app.resume_prompt_active))) return;
    state.app.session_close_captured = true;
    state.app.session_route = state.app.router.current;
    state.app.session_restore_count = 0;
    state.app.session_position = 0;
    state.app.session_file_idx = -1;
    state.app.session_tv_id = 0;
    state.app.session_tv_season = 0;
    state.app.session_tv_episode = 0;
    if (state.app.incognito_mode or state.app.active_player_idx >= state.app.players.items.len) return;
    const p = state.app.players.items[state.app.active_player_idx];
    const url = if (p.is_torrent and p.source_url_len > 0)
        p.source_url[0..p.source_url_len]
    else if (p.restore_target_len > 0 and p.restore_target_len <= p.restore_target.len)
        p.restore_target[0..p.restore_target_len]
    else
        p.current_url[0..p.current_url_len];
    if (url.len == 0 or url.len >= 2048) return;
    if (std.mem.startsWith(u8, url, "http://127.0.0.1:") or std.mem.startsWith(u8, url, "http://localhost:")) return;
    var safe_buf: [2048]u8 = undefined;
    const safe = watch_history_pure.persistedTarget(url, &safe_buf).reopen;
    if (safe.len > 0 and safe.len <= state.app.session_restore_urls[0].len) {
        @memcpy(state.app.session_restore_urls[0][0..safe.len], safe);
        state.app.session_restore_lens[0] = safe.len;
        state.app.session_restore_count = 1;
    }
    const snap = p.playbackSnapshot();
    state.app.playback_volume = snap.volume;
    state.app.playback_speed = snap.speed;
    state.app.playback_muted = snap.muted;
    state.app.session_position = snap.time_pos;
    state.app.session_duration = snap.duration;
    state.app.session_paused = snap.paused;
    state.app.session_speed = snap.speed;
    state.app.session_file_idx = if (p.is_torrent) p.selected_file_idx else -1;
    const pe = &state.app.playing_episode;
    if (pe.matches(p.current_url[0..p.current_url_len])) {
        state.app.session_tv_id = pe.tmdb_id;
        state.app.session_tv_season = pe.season;
        state.app.session_tv_episode = pe.episode;
    }
}

/// Called every frame — flushes config to SQLite if dirty (2s debounce).
pub fn saveIfDirty() void {
    if (state.app.incognito_mode) return; // incognito: never persist
    if (!state.app.config_dirty) return;
    // The window can be interactive before the background database/config load
    // finishes. Keep the dirty bit armed until a real connection is available;
    // clearing it before save() would silently discard an early user change.
    if (!state.app.config_loaded.load(.acquire) or db.get() == null) return;
    const now = @import("io_global.zig").timestamp();
    if (now - state.app.last_config_save < 2) return; // debounce
    save();
    state.app.config_dirty = false;
    state.app.last_config_save = now;
}

pub fn load() void {
    ensureDir();
    legacy_secrets_mask = 0;

    // Publish readiness even if the config table cannot be queried. Defaults
    // are a valid fallback; leaving this false forever would strand Settings
    // in its cold-load guard and prevent dirty preferences from ever saving.
    defer {
        state.app.config_loaded.store(true, .release);
        state.wakeUi();
    }

    {
        const sql = "SELECT key, value FROM config";
        const stmt = db.prepare(sql) orelse return;
        defer db.finalize(stmt);

        while (db.step(stmt) == db.c.SQLITE_ROW) {
            const key = db.columnText(stmt, 0) orelse continue;
            const val = db.columnText(stmt, 1) orelse continue;
            applyConfig(key, val);
        }
    }

    // Existing installs stored these rows as plaintext. Once all values have
    // been restored, replace only the credential rows with protected values.
    // A protection failure leaves the original row untouched.
    if (@import("builtin").os.tag == .windows and legacy_secrets_mask != 0) {
        migrateLoadedSecrets();
    }

    const identity = @import("install_identity_pure.zig");
    if (!identity.valid(&state.app.install_id)) {
        var random: [16]u8 = undefined;
        if (@import("io_global.zig").randomSecure(&random)) {
            state.app.install_id = identity.encode(random);
            setKey("install_id", &state.app.install_id);
        }
    }

    // Normalize the pair only after reading every row: SQLite does not promise
    // SELECT order, so ui_scale may be applied before or after ui_scale_auto.
    // This also migrates Auto installs that persisted the old 0.68-0.8x policy.
    // Explicit manual sub-1x choices remain valid.
    state.app.ui_scale = @import("scale_pure.zig").restoredScale(
        state.app.ui_scale_auto,
        state.app.ui_scale,
    );

    // Start this session's usage clock now that the lifetime total is loaded.
    const now = @import("io_global.zig").timestamp();
    state.app.session_start_s = now;
    state.app.usage_last_tick = now;

    // Grandfather pre-wizard installs: a config that already carries a TMDB
    // key or has source plugins installed predates onboarding — don't nag.
    // The build-time embedded default key does NOT count (every fresh install
    // has it) — only a real user-supplied key marks a pre-wizard install.
    if (!state.app.onboarded and
        ((state.app.tmdb.api_key_len > 0 and !state.app.tmdb.api_key_is_default) or
            @import("source_config.zig").anyInstalled()))
    {
        state.app.onboarded = true;
    }

    // Signal the render loop that saved prefs (incl. ui_scale / ui_scale_auto)
    // are now in place, so the first frame can apply the device-aware scale
    // without racing this async load. See main.zig appFrame.
    // .release so every write above (esp. the tmdb_api_key bytes+len) is
    // published to any thread that later loads config_loaded with .acquire.
}

fn setKey(key: []const u8, val: []const u8) void {
    const sql = "INSERT OR REPLACE INTO config (key, value) VALUES (?1, ?2)";
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, key);
    db.bindText(stmt, 2, val);
    _ = db.step(stmt);
}

fn setSecretKey(key: []const u8, val: []const u8) void {
    if (val.len == 0) {
        setKey(key, "");
        return;
    }
    var protected: [1024]u8 = undefined;
    defer @memset(&protected, 0);
    const sealed = secret_store.seal(val, &protected) orelse {
        std.log.warn("could not protect config credential '{s}'; keeping previous value", .{key});
        return;
    };
    setKey(key, sealed);
}

fn loadSecretValue(key: []const u8, stored: []const u8, dst: []u8, len: *usize) bool {
    const plain = secret_store.reveal(stored, dst) orelse {
        std.log.warn("could not unlock a saved credential; sign-in may be required", .{});
        return false;
    };
    len.* = plain.len;
    if (@import("builtin").os.tag == .windows and stored.len > 0 and !secret_store.isSealed(stored)) {
        legacy_secrets_mask |= secretBit(key);
    }
    return true;
}

fn migrateLoadedSecrets() void {
    const mask = legacy_secrets_mask;
    // REPLACE deletes the old SQLite cell; secure_delete zeroes that payload,
    // and truncating the WAL prevents a plaintext copy surviving migration.
    db.exec("PRAGMA secure_delete=ON");
    db.exec("BEGIN");
    if (mask & secretBit("proxy_url") != 0) setSecretKey("proxy_url", state.app.proxy_url[0..state.app.proxy_url_len]);
    if (mask & secretBit("tmdb_api_key") != 0) setSecretKey("tmdb_api_key", if (state.app.tmdb.api_key_is_default) "" else state.app.tmdb.api_key[0..state.app.tmdb.api_key_len]);
    if (mask & secretBit("opensub_api_key") != 0) setSecretKey("opensub_api_key", state.app.opensub_api_key[0..state.app.opensub_api_key_len]);
    if (mask & secretBit("omdb_api_key") != 0) setSecretKey("omdb_api_key", if (state.app.omdb_api_key_is_default) "" else state.app.omdb_api_key[0..state.app.omdb_api_key_len]);
    if (mask & secretBit("subdl_api_key") != 0) setSecretKey("subdl_api_key", state.app.subdl_api_key[0..state.app.subdl_api_key_len]);
    if (mask & secretBit("jf_token") != 0) setSecretKey("jf_token", state.app.jf.token[0..state.app.jf.token_len]);
    if (mask & secretBit("abs_token") != 0) setSecretKey("abs_token", state.app.abs.token[0..state.app.abs.token_len]);
    const user_len = std.mem.indexOfScalar(u8, &state.app.opds.user_buf, 0) orelse state.app.opds.user_buf.len;
    const pass_len = std.mem.indexOfScalar(u8, &state.app.opds.pass_buf, 0) orelse state.app.opds.pass_buf.len;
    if (mask & secretBit("opds_user") != 0) setSecretKey("opds_user", state.app.opds.user_buf[0..user_len]);
    if (mask & secretBit("opds_pass") != 0) setSecretKey("opds_pass", state.app.opds.pass_buf[0..pass_len]);
    db.exec("COMMIT");
    db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    legacy_secrets_mask = 0;
}

fn applyConfig(key: []const u8, val: []const u8) void {
    if (std.mem.eql(u8, key, "usage_seconds")) {
        state.app.usage_seconds_total = std.fmt.parseInt(i64, val, 10) catch 0;
    } else if (std.mem.eql(u8, key, "install_id")) {
        if (@import("install_identity_pure.zig").valid(val)) {
            @memcpy(&state.app.install_id, val);
        }
    } else if (std.mem.eql(u8, key, "ui_scale")) {
        state.app.ui_scale = @import("scale_pure.zig").clampScale(std.fmt.parseFloat(f32, val) catch 1.0);
    } else if (std.mem.eql(u8, key, "ui_scale_auto")) {
        state.app.ui_scale_auto = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "reduce_motion")) {
        state.app.reduce_motion = std.mem.eql(u8, val, "1");
        theme.setReducedMotion(state.app.reduce_motion);
    } else if (std.mem.eql(u8, key, "grid_mode")) {
        state.app.grid_mode = if (std.mem.eql(u8, val, "1")) .cols_1 else if (std.mem.eql(u8, val, "2")) .cols_2 else if (std.mem.eql(u8, val, "3")) .cols_3 else if (std.mem.eql(u8, val, "4")) .cols_4 else .auto;
    } else if (std.mem.eql(u8, key, "seek_sync")) {
        state.app.seek_sync = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "hwdec2")) {
        state.app.hwdec_enabled = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "hwdec")) {
        // Legacy key: every save auto-persisted the old OFF default, so a
        // stored 0 is NOT an explicit user choice — ignore it and let the new
        // hw-decode-on default (or an explicit hwdec2 row) win.
    } else if (std.mem.eql(u8, key, "auto_advance")) {
        state.app.auto_advance = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "playlist_repeat")) {
        const RepeatMode = @import("../player/playlist_pure.zig").RepeatMode;
        state.app.playlist_repeat = std.meta.stringToEnum(RepeatMode, val) orelse .off;
    } else if (std.mem.eql(u8, key, "playlist_shuffle")) {
        state.app.playlist_shuffle = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "playlist_shuffle_seed")) {
        state.app.playlist_shuffle_seed = std.fmt.parseInt(u64, val, 10) catch 0;
    } else if (std.mem.eql(u8, key, "nsfw_filter")) {
        state.app.nsfw_filter_enabled = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "gallerydl_enabled")) {
        state.app.gallerydl_enabled = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "scrape_use_browser")) {
        state.app.scrape_use_browser = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "prefetch_playlist")) {
        state.app.prefetch_playlist = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "audio_passthrough")) {
        state.app.audio_passthrough = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "audio_exclusive")) {
        state.app.audio_exclusive = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "taste_suggestions")) {
        state.app.taste_enabled = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "content_cache_enabled")) {
        state.app.content_cache_enabled = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "auto_download_subs")) {
        state.app.auto_download_subs = std.mem.eql(u8, val, "1");
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
    } else if (std.mem.eql(u8, key, "subtitles_enabled")) {
        state.app.subtitles_enabled = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "audio_lang")) {
        if (val.len < state.app.audio_lang_buf.len) {
            @memset(state.app.audio_lang_buf[0..], 0);
            @memcpy(state.app.audio_lang_buf[0..val.len], val);
            state.app.audio_lang_len = val.len;
        }
    } else if (std.mem.eql(u8, key, "audio_device")) {
        if (val.len < state.app.audio_device_buf.len) {
            @memset(state.app.audio_device_buf[0..], 0);
            @memcpy(state.app.audio_device_buf[0..val.len], val);
            state.app.audio_device_len = val.len;
        }
    } else if (std.mem.eql(u8, key, "playback_volume")) {
        const volume = std.fmt.parseFloat(f64, val) catch 100;
        state.app.playback_volume = if (std.math.isFinite(volume)) std.math.clamp(volume, 0, 100) else 100;
    } else if (std.mem.eql(u8, key, "playback_speed")) {
        const speed = std.fmt.parseFloat(f64, val) catch 1;
        state.app.playback_speed = if (std.math.isFinite(speed)) std.math.clamp(speed, 0.25, 4) else 1;
    } else if (std.mem.eql(u8, key, "playback_muted")) {
        state.app.playback_muted = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "video_aspect")) {
        if (val.len > 0 and val.len < state.app.video_aspect_buf.len) {
            @memset(state.app.video_aspect_buf[0..], 0);
            @memcpy(state.app.video_aspect_buf[0..val.len], val);
            state.app.video_aspect_len = val.len;
        }
    } else if (std.mem.eql(u8, key, "video_fill_mode")) {
        state.app.video_fill_mode = if (std.mem.eql(u8, val, "fit")) .fit else .cover;
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
    } else if (std.mem.eql(u8, key, "music_discovery")) {
        state.app.music_discovery_enabled = std.mem.eql(u8, val, "1");
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
    } else if (std.mem.eql(u8, key, "picture_preset")) {
        // Routed through the pure mapping so a corrupt value lands on `auto`
        // rather than whatever integer happened to be stored.
        const avp = @import("../player/av_pure.zig");
        state.app.picture_preset = @intFromEnum(avp.picturePresetFromInt(std.fmt.parseInt(usize, val, 10) catch 0));
    } else if (std.mem.eql(u8, key, "download_rate_limit")) {
        state.app.download_rate_limit = @import("../player/av_pure.zig").sanitizeDownloadLimit(std.fmt.parseInt(i32, val, 10) catch 0);
        // Session may already be up (torrent_init worker) — apply now; if not,
        // that worker calls this too once it publishes the session.
        state.applyDownloadLimitIfReady();
    } else if (std.mem.eql(u8, key, "http_dl_segments")) {
        state.app.http_dl_segments = std.math.clamp(std.fmt.parseInt(u32, val, 10) catch 4, 1, 8);
    } else if (std.mem.eql(u8, key, "http_dl_max_concurrent")) {
        state.app.http_dl_max_concurrent = std.math.clamp(std.fmt.parseInt(u32, val, 10) catch 3, 1, 8);
    } else if (std.mem.eql(u8, key, "proxy_url")) {
        var restored_len: usize = 0;
        if (val.len > 0 and loadSecretValue(key, val, state.app.proxy_url[0 .. state.app.proxy_url.len - 1], &restored_len) and restored_len > 0) {
            state.app.proxy_url_len = restored_len;
            // The session may not exist yet; applyTorrentProxyIfReady is
            // idempotent and main.zig calls it again once it does.
            state.applyTorrentProxyIfReady();
        }
    } else if (std.mem.eql(u8, key, "dpi_bypass_enabled")) {
        // The sidecar itself is started/stopped in main.coreInit (after this
        // load completes, so the mode row is already applied) and from the
        // Settings toggle — here we only restore the flag.
        state.app.dpi_bypass_enabled = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "dpi_bypass_mode")) {
        const dpi_pure = @import("../services/dpi_bypass_pure.zig");
        if (dpi_pure.validMode(val) and val.len <= state.app.dpi_bypass_mode.len) {
            @memcpy(state.app.dpi_bypass_mode[0..val.len], val);
            state.app.dpi_bypass_mode_len = val.len;
        }
    } else if (std.mem.eql(u8, key, "ytdl_format_idx")) {
        const idx = std.fmt.parseInt(usize, val, 10) catch 1;
        state.app.ytdl_format_idx = if (idx < 4) idx else 1;
    } else if (std.mem.eql(u8, key, "drawer_width_px")) {
        state.app.drawer_width_px = std.fmt.parseFloat(f32, val) catch 480.0;
    } else if (std.mem.eql(u8, key, "tmdb_api_key")) {
        var restored_len: usize = 0;
        if (val.len > 0 and loadSecretValue(key, val, &state.app.tmdb.api_key, &restored_len) and restored_len > 0) {
            // A saved key is a real user key — override any embedded default.
            state.app.tmdb.api_key_len = restored_len;
            state.app.tmdb.api_key_is_default = false;
        }
    } else if (std.mem.eql(u8, key, "opensub_api_key")) {
        var restored_len: usize = 0;
        if (val.len > 0 and loadSecretValue(key, val, &state.app.opensub_api_key, &restored_len) and restored_len > 0) {
            state.app.opensub_api_key_len = restored_len;
        }
    } else if (std.mem.eql(u8, key, "omdb_api_key")) {
        var restored_len: usize = 0;
        if (val.len > 0 and loadSecretValue(key, val, &state.app.omdb_api_key, &restored_len) and restored_len > 0) {
            state.app.omdb_api_key_len = restored_len;
            state.app.omdb_api_key_is_default = false;
        }
    } else if (std.mem.eql(u8, key, "subdl_api_key")) {
        var restored_len: usize = 0;
        if (val.len > 0 and loadSecretValue(key, val, &state.app.subdl_api_key, &restored_len) and restored_len > 0) {
            state.app.subdl_api_key_len = restored_len;
        }
    } else if (std.mem.eql(u8, key, "sponsorblock_enabled")) {
        state.app.sponsorblock_enabled = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "anime_skip_enabled")) {
        state.app.anime_skip_enabled = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "anime_skip_intro")) {
        state.app.anime_skip_intro = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "anime_skip_recap")) {
        state.app.anime_skip_recap = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "anime_skip_credits")) {
        state.app.anime_skip_credits = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "anime_skip_preview")) {
        state.app.anime_skip_preview = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "deband_enabled")) {
        state.app.deband_enabled = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "video_scaler")) {
        const v = std.fmt.parseInt(u8, val, 10) catch 0;
        state.app.video_scaler = if (v <= 2) v else 0;
    } else if (std.mem.eql(u8, key, "vf_brightness")) {
        state.app.vf_brightness = @import("../player/av_pure.zig").clampVideoFilter(std.fmt.parseInt(i32, val, 10) catch 0);
    } else if (std.mem.eql(u8, key, "vf_contrast")) {
        state.app.vf_contrast = @import("../player/av_pure.zig").clampVideoFilter(std.fmt.parseInt(i32, val, 10) catch 0);
    } else if (std.mem.eql(u8, key, "vf_saturation")) {
        state.app.vf_saturation = @import("../player/av_pure.zig").clampVideoFilter(std.fmt.parseInt(i32, val, 10) catch 0);
    } else if (std.mem.eql(u8, key, "vf_gamma")) {
        state.app.vf_gamma = @import("../player/av_pure.zig").clampVideoFilter(std.fmt.parseInt(i32, val, 10) catch 0);
    } else if (std.mem.eql(u8, key, "cowatch_sensitivity")) {
        const cw = @import("../services/co_watch.zig");
        if (std.meta.stringToEnum(cw.Sensitivity, val)) |s| cw.sensitivity = s;
    } else if (std.mem.eql(u8, key, "jf_server_url")) {
        if (val.len > 0 and val.len < state.app.jf.server_url.len) {
            @memcpy(state.app.jf.server_url[0..val.len], val);
            state.app.jf.server_url_len = val.len;
        }
    } else if (std.mem.eql(u8, key, "jf_token")) {
        var restored_len: usize = 0;
        if (val.len > 0 and loadSecretValue(key, val, state.app.jf.token[0 .. state.app.jf.token.len - 1], &restored_len) and restored_len > 0) {
            state.app.jf.token_len = restored_len;
        }
    } else if (std.mem.eql(u8, key, "jf_user_id")) {
        if (val.len > 0 and val.len < state.app.jf.user_id.len) {
            @memcpy(state.app.jf.user_id[0..val.len], val);
            state.app.jf.user_id_len = val.len;
        }
    } else if (std.mem.eql(u8, key, "jf_connected")) {
        // Only mark as connected if we also have a token
        state.app.jf.connected = std.mem.eql(u8, val, "1") and state.app.jf.token_len > 0;
    } else if (std.mem.eql(u8, key, "abs_server_url")) {
        if (val.len > 0 and val.len < state.app.abs.server_url.len) {
            @memcpy(state.app.abs.server_url[0..val.len], val);
            state.app.abs.server_url_len = val.len;
        }
    } else if (std.mem.eql(u8, key, "abs_token")) {
        var restored_len: usize = 0;
        if (val.len > 0 and loadSecretValue(key, val, state.app.abs.token[0 .. state.app.abs.token.len - 1], &restored_len) and restored_len > 0) {
            state.app.abs.token_len = restored_len;
        }
    } else if (std.mem.eql(u8, key, "abs_connected")) {
        state.app.abs.connected = std.mem.eql(u8, val, "1") and state.app.abs.token_len > 0;
    } else if (std.mem.eql(u8, key, "opds_url")) {
        if (val.len > 0 and val.len < state.app.opds.server_url.len) {
            @memcpy(state.app.opds.server_url[0..val.len], val);
            state.app.opds.server_url_len = val.len;
        }
    } else if (std.mem.eql(u8, key, "opds_user")) {
        var restored_len: usize = 0;
        if (val.len > 0 and loadSecretValue(key, val, state.app.opds.user_buf[0 .. state.app.opds.user_buf.len - 1], &restored_len)) {
            state.app.opds.user_buf[restored_len] = 0;
        }
    } else if (std.mem.eql(u8, key, "opds_pass")) {
        var restored_len: usize = 0;
        if (val.len > 0 and loadSecretValue(key, val, state.app.opds.pass_buf[0 .. state.app.opds.pass_buf.len - 1], &restored_len)) {
            state.app.opds.pass_buf[restored_len] = 0;
        }
    } else if (std.mem.eql(u8, key, "opds_connected")) {
        // Connected only if a catalog URL was also restored.
        state.app.opds.connected = std.mem.eql(u8, val, "1") and state.app.opds.server_url_len > 0;
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
    } else if (std.mem.eql(u8, key, "session_saved")) {
        state.app.session_saved = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "session_route")) {
        state.app.session_route = std.meta.stringToEnum(@import("router.zig").Route, val) orelse .home;
    } else if (std.mem.eql(u8, key, "session_position")) {
        const pos = std.fmt.parseFloat(f64, val) catch 0;
        state.app.session_position = if (std.math.isFinite(pos) and pos >= 0) pos else 0;
    } else if (std.mem.eql(u8, key, "session_paused")) {
        state.app.session_paused = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "session_speed")) {
        const speed = std.fmt.parseFloat(f64, val) catch 1;
        state.app.session_speed = if (std.math.isFinite(speed)) std.math.clamp(speed, 0.25, 4) else 1;
    } else if (std.mem.eql(u8, key, "session_file_idx")) {
        state.app.session_file_idx = std.fmt.parseInt(i32, val, 10) catch -1;
    } else if (std.mem.eql(u8, key, "session_tv_id")) {
        state.app.session_tv_id = std.fmt.parseInt(i32, val, 10) catch 0;
    } else if (std.mem.eql(u8, key, "session_tv_season")) {
        state.app.session_tv_season = std.fmt.parseInt(i32, val, 10) catch 0;
    } else if (std.mem.eql(u8, key, "session_tv_episode")) {
        state.app.session_tv_episode = std.fmt.parseInt(i32, val, 10) catch 0;
    } else if (std.mem.startsWith(u8, key, "session_url_")) {
        const idx_str = key["session_url_".len..];
        const idx = std.fmt.parseInt(usize, idx_str, 10) catch return;
        if (idx >= 16 or val.len == 0 or val.len >= 2048) return;
        if (std.mem.startsWith(u8, val, "http://127.0.0.1:") or
            std.mem.startsWith(u8, val, "http://localhost:")) return;
        var safe_buf: [2048]u8 = undefined;
        const safe = watch_history_pure.persistedTarget(val, &safe_buf).reopen;
        if (safe.len == 0) return;
        @memcpy(state.app.session_restore_urls[idx][0..safe.len], safe);
        state.app.session_restore_lens[idx] = safe.len;
        if (idx + 1 > state.app.session_restore_count) {
            state.app.session_restore_count = idx + 1;
        }
    } else if (std.mem.eql(u8, key, "audio_vis")) {
        // fromLabel falls back to the default on an unknown label, so a hand-edited
        // or older config can't crash the player.
        const vis = @import("../player/visualizer_pure.zig");
        @import("../player/player.zig").vis_style = vis.Style.fromLabel(val);
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
        // "cloud" IS an explicit choice — honor it. Apple Intelligence (apfel)
        // is now an explicit user segment in Settings (macOS only), so a stored
        // "apfel" on macOS is a deliberate choice and must be honored too. Any
        // other/legacy value (or non-macOS "apfel") falls back to the local
        // llama brain.
        const ai_server = @import("../services/ai_server.zig");
        ai_server.backend_kind = if (std.mem.eql(u8, val, "cloud"))
            .cloud
        else if (ai_server.is_macos and std.mem.eql(u8, val, "apfel"))
            .apfel
        else
            .gemma_llama;
    } else if (std.mem.eql(u8, key, "ai_cloud_provider")) {
        @import("../services/ai_server.zig").selectCloudProviderById(val);
    } else if (std.mem.eql(u8, key, "onboarded")) {
        state.app.onboarded = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "web_remote")) {
        state.app.web_remote_enabled = std.mem.eql(u8, val, "1");
        // Config loads AFTER appInit — honor a persisted enable now.
        if (state.app.web_remote_enabled) @import("../services/remote.zig").start();
    } else if (std.mem.eql(u8, key, "web_bind") or std.mem.eql(u8, key, "web_port")) {
        // applyBinding rather than a bare assignment: key order within the
        // config is not guaranteed, so `web_remote` may already have started
        // the server on the defaults by the time these load. applyBinding
        // no-ops when nothing changed and restarts the listener when it did.
        const remote = @import("../services/remote.zig");
        const access_pure = @import("../services/access_pure.zig");
        if (std.mem.eql(u8, key, "web_bind")) {
            remote.applyBinding(access_pure.bindModeFromString(val), remote.port);
        } else if (access_pure.parsePort(val)) |p| {
            remote.applyBinding(remote.bind_mode, p);
        }
    } else if (std.mem.eql(u8, key, "custom_titlebar")) {
        state.app.custom_titlebar = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, key, "ai_model_id")) {
        @import("../services/ai_server.zig").selectModelById(val);
    } else if (std.mem.eql(u8, key, "browser_engine")) {
        // Unknown/legacy names fall back to camoufox (browser_pure logic).
        const browser = @import("../services/browser.zig");
        browser.active_engine = @import("../services/browser_pure.zig").engineFromString(val);
    } else if (std.mem.eql(u8, key, "voice_backend")) {
        const voice_backend = @import("../services/voice_backend.zig");
        if (std.meta.stringToEnum(voice_backend.Kind, val)) |k| {
            voice_backend.active_kind = k;
            // A stored choice is explicit: the startup auto-promotion must
            // not override it (see the deferred promotion in main.zig).
            voice_backend.voice_backend_explicit = true;
        }
    } else if (std.mem.eql(u8, key, "search_sources")) {
        const resolver = @import("../services/resolver.zig");
        const mask = std.fmt.parseInt(u16, val, 10) catch 0xFF;
        resolver.source_mask.store(mask, .release);
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

fn fmtI32(buf: *[64]u8, v: i32) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch "0";
}
