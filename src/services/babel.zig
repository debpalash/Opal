//! Babel (v10 pillar 7.5) — every language, every file.
//!
//! UI-thread hub for live captions (live_captions.zig), subtitle translation
//! (translate.zig) and "Previously on…" recaps (recap.zig): one per-frame
//! tick, the shared mpv helpers, and the status block served in the player
//! snapshot JSON.
const std = @import("std");
const state = @import("../core/state.zig");
const c = @import("../core/c.zig");
const paths = @import("../core/paths.zig");
const io = @import("../core/io_global.zig");

pub const live_captions = @import("live_captions.zig");
pub const translate = @import("translate.zig");
pub const recap = @import("recap.zig");

/// Media identity last seen by tick(); a change cancels per-media work.
var last_player: usize = 0;
var last_serial: u64 = 0;

/// Per-frame (UI thread, before rendering).
pub fn tick() void {
    var addr: usize = 0;
    var serial: u64 = 0;
    if (state.app.active_player_idx < state.app.players.items.len) {
        const p = state.app.players.items[state.app.active_player_idx];
        addr = @intFromPtr(p);
        serial = p.load_serial;
    }
    if (addr != last_player or serial != last_serial) {
        last_player = addr;
        last_serial = serial;
        translate.cancelForMediaChange();
        recap.onMediaChange();
    }
    live_captions.tick();
    translate.pollAttach();
}

// ── Settings accessors (state.app holds the persisted values) ──

/// Live-caption source language (whisper code, "auto" by default).
pub fn captionLang() []const u8 {
    const l = state.app.babel_caption_lang[0..@min(state.app.babel_caption_lang_len, state.app.babel_caption_lang.len)];
    return @import("live_captions_pure.zig").whisperLang(l);
}

/// "Translate subtitles to" target (ISO 639-1), or "" when off.
pub fn translateLang() []const u8 {
    return state.app.babel_translate_lang[0..@min(state.app.babel_translate_lang_len, state.app.babel_translate_lang.len)];
}

// ── mpv helpers (UI thread) ──

pub fn mpvString(ctx: ?*c.mpv.mpv_handle, name: [*:0]const u8, out: []u8) ?[]const u8 {
    const raw = c.mpv.mpv_get_property_string(ctx, name);
    if (raw == null) return null;
    defer c.mpv.mpv_free(@ptrCast(raw));
    const s = std.mem.span(raw);
    if (s.len == 0 or s.len > out.len) return null;
    @memcpy(out[0..s.len], s);
    return out[0..s.len];
}

pub fn mpvDouble(ctx: ?*c.mpv.mpv_handle, name: [*:0]const u8) ?f64 {
    var v: f64 = 0;
    if (c.mpv.mpv_get_property(ctx, name, c.mpv.MPV_FORMAT_DOUBLE, &v) < 0) return null;
    return v;
}

pub fn mpvInt(ctx: ?*c.mpv.mpv_handle, name: [*:0]const u8) ?i64 {
    var v: i64 = 0;
    if (c.mpv.mpv_get_property(ctx, name, c.mpv.MPV_FORMAT_INT64, &v) < 0) return null;
    return v;
}

/// `sub-add <path> select <title> <lang>`; returns the new track id.
pub fn subAdd(ctx: ?*c.mpv.mpv_handle, path: []const u8, title: []const u8, lang: []const u8) ?i64 {
    var path_z: [1100]u8 = undefined;
    var title_z: [96]u8 = undefined;
    var lang_z: [16]u8 = undefined;
    const p = std.fmt.bufPrintZ(&path_z, "{s}", .{path}) catch return null;
    const t = std.fmt.bufPrintZ(&title_z, "{s}", .{title}) catch return null;
    const l = std.fmt.bufPrintZ(&lang_z, "{s}", .{lang}) catch return null;
    var argv = [_][*c]const u8{ "sub-add", p.ptr, "select", t.ptr, l.ptr, null };
    if (c.mpv.mpv_command(ctx, @ptrCast(&argv)) < 0) return null;
    return mpvInt(ctx, "sid");
}

pub fn subReload(ctx: ?*c.mpv.mpv_handle, sid: i64) bool {
    var id_buf: [24]u8 = undefined;
    const id = std.fmt.bufPrintZ(&id_buf, "{d}", .{sid}) catch return false;
    var argv = [_][*c]const u8{ "sub-reload", id.ptr, null };
    return c.mpv.mpv_command(ctx, @ptrCast(&argv)) >= 0;
}

/// <cache>/babel[/sub] (created). Generated subtitles and transcripts live here.
pub fn cacheDir(buf: []u8, sub: []const u8) []const u8 {
    var base_buf: [600]u8 = undefined;
    const base = paths.cacheFile(&base_buf, "babel");
    const dir = if (sub.len == 0)
        std.fmt.bufPrint(buf, "{s}", .{base}) catch return ""
    else
        std.fmt.bufPrint(buf, "{s}/{s}", .{ base, sub }) catch return "";
    io.cwdMakePath(dir) catch return "";
    return dir;
}

/// Transcript file for one TV episode (written by live captions, read by recaps).
pub fn transcriptPath(buf: []u8, tmdb_id: i32, season: i32, episode: i32) []const u8 {
    var dir_buf: [700]u8 = undefined;
    const dir = cacheDir(&dir_buf, "transcripts");
    if (dir.len == 0) return "";
    return std.fmt.bufPrint(buf, "{s}/{d}-s{d}e{d}.txt", .{ dir, tmdb_id, season, episode }) catch "";
}

// ── Remote JSON ──

fn writeJsonString(w: *std.Io.Writer, s: []const u8) void {
    std.json.Stringify.encodeJsonString(@import("../core/text.zig").safeUtf8(s), .{}, w) catch {};
}

/// `"babel":{...}` member for the player snapshot (subtitle discovery block).
pub fn writeStatusJson(w: *std.Io.Writer) void {
    const live = live_captions.statusSnapshot();
    const tr = translate.statusSnapshot();
    w.print("\"babel\":{{\"live_captions\":{s},\"live_cues\":{d},\"live_status\":", .{
        if (live_captions.enabled.load(.acquire)) "true" else "false",
        live.cues,
    }) catch return;
    writeJsonString(w, live.text[0..live.len]);
    w.writeAll(",\"caption_lang\":") catch return;
    writeJsonString(w, captionLang());
    w.writeAll(",\"translate_lang\":") catch return;
    writeJsonString(w, translateLang());
    w.print(",\"translating\":{s},\"translate_status\":", .{if (translate.in_progress.load(.acquire)) "true" else "false"}) catch return;
    writeJsonString(w, tr.text[0..tr.len]);
    w.writeAll("}") catch return;
}

pub fn subRemove(ctx: ?*c.mpv.mpv_handle, sid: i64) void {
    var buf: [24]u8 = undefined;
    const id = std.fmt.bufPrintZ(&buf, "{d}", .{sid}) catch return;
    var argv = [_][*c]const u8{ "sub-remove", id.ptr, null };
    _ = c.mpv.mpv_command(ctx, @ptrCast(&argv));
}
