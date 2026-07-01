const std = @import("std");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const c = @import("../core/c.zig");

// ══════════════════════════════════════════════════════════
// OpenSubtitles.com REST API v1 — Subtitle Search & Download
// ══════════════════════════════════════════════════════════

const API_BASE = "https://api.opensubtitles.com/api/v1";
const USER_AGENT = "Opal v1.0";

// ── Result storage ──
pub const SubResult = struct {
    file_id: i64 = 0,
    language: [8]u8 = std.mem.zeroes([8]u8),
    lang_len: usize = 0,
    release: [200]u8 = std.mem.zeroes([200]u8),
    release_len: usize = 0,
    download_count: i32 = 0,
    hearing_impaired: bool = false,
    ai_translated: bool = false,
};

pub const MAX_RESULTS = 25;
pub var results: [MAX_RESULTS]SubResult = std.mem.zeroes([MAX_RESULTS]SubResult);
pub var result_count: usize = 0;
pub var is_searching: bool = false;
pub var search_error: [128]u8 = std.mem.zeroes([128]u8);
pub var search_error_len: usize = 0;
pub var is_downloading: bool = false;

// ── Search by query ──
pub fn searchByQuery(query: []const u8, lang: []const u8) void {
    if (is_searching) return;
    if (query.len == 0) return;

    is_searching = true;
    result_count = 0;
    search_error_len = 0;

    const S = struct {
        var q_buf: [256]u8 = undefined;
        var q_len: usize = 0;
        var l_buf: [8]u8 = undefined;
        var l_len: usize = 0;
    };
    S.q_len = @min(query.len, S.q_buf.len);
    @memcpy(S.q_buf[0..S.q_len], query[0..S.q_len]);
    S.l_len = @min(lang.len, S.l_buf.len);
    @memcpy(S.l_buf[0..S.l_len], lang[0..S.l_len]);

    if (std.Thread.spawn(.{}, struct {
        fn work() void {
            defer { is_searching = false; }
            doSearch(S.q_buf[0..S.q_len], S.l_buf[0..S.l_len]);
        }
    }.work, .{})) |t| t.detach() else |_| {
        is_searching = false;
    }
}

fn doSearch(query: []const u8, lang: []const u8) void {
    if (state.app.opensub_api_key_len == 0) {
        setError("Set OpenSubtitles API key in Settings → Subtitles");
        return;
    }

    // Build URL
    var url_buf: [512]u8 = undefined;
    var url_len: usize = 0;

    const prefix = API_BASE ++ "/subtitles?query=";
    @memcpy(url_buf[0..prefix.len], prefix);
    url_len = prefix.len;

    for (query) |ch| {
        if (url_len + 3 >= url_buf.len) break;
        if (ch == ' ') {
            url_buf[url_len] = '+';
            url_len += 1;
        } else if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.') {
            url_buf[url_len] = ch;
            url_len += 1;
        } else {
            url_buf[url_len] = '%';
            url_buf[url_len + 1] = hexDigit(ch >> 4);
            url_buf[url_len + 2] = hexDigit(ch & 0xF);
            url_len += 3;
        }
    }

    if (lang.len > 0) {
        const lang_param = "&languages=";
        if (url_len + lang_param.len + lang.len < url_buf.len) {
            @memcpy(url_buf[url_len..][0..lang_param.len], lang_param);
            url_len += lang_param.len;
            @memcpy(url_buf[url_len..][0..lang.len], lang);
            url_len += lang.len;
        }
    }
    url_buf[url_len] = 0;

    // Build Api-Key header
    var hdr_buf: [160]u8 = undefined;
    const api_key = state.app.opensub_api_key[0..state.app.opensub_api_key_len];
    const hdr_prefix = "Api-Key: ";
    @memcpy(hdr_buf[0..hdr_prefix.len], hdr_prefix);
    @memcpy(hdr_buf[hdr_prefix.len..][0..api_key.len], api_key);
    hdr_buf[hdr_prefix.len + api_key.len] = 0;

    const hdr_len = hdr_prefix.len + api_key.len;
    const hdr_slice: []const u8 = hdr_buf[0..hdr_len];
    const url_slice: []const u8 = url_buf[0..url_len];

    var child = @import("../core/io_global.zig").Child.init(
        &.{ "curl", "-s", "--max-time", "10",
             "-H", "Content-Type: application/json",
             "-H", hdr_slice,
             "-H", "User-Agent: " ++ USER_AGENT,
             url_slice },
        @import("../core/alloc.zig").allocator,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        setError("Failed to spawn curl");
        return;
    };

    var response_buf: [32768]u8 = undefined;
    var n: usize = 0;
    if (child.stdout) |*stdout| {
        n = @import("../core/io_global.zig").readAll(stdout, &response_buf) catch 0;
    }
    _ = child.wait() catch {};

    if (n == 0) {
        setError("No response from OpenSubtitles");
        return;
    }

    parseResults(response_buf[0..n]);

    if (result_count > 0) {
        logs.pushLog("info", "subs", "Found subtitles", false);
    }
}

fn hexDigit(val: u8) u8 {
    const hex = "0123456789ABCDEF";
    return hex[val & 0xF];
}

fn setError(msg: []const u8) void {
    const len = @min(msg.len, search_error.len);
    @memcpy(search_error[0..len], msg[0..len]);
    search_error_len = len;
}

fn parseResults(json: []const u8) void {
    result_count = 0;
    var pos: usize = 0;

    while (pos < json.len and result_count < MAX_RESULTS) {
        const file_id_key = "\"file_id\":";
        const fid_pos = std.mem.indexOfPos(u8, json, pos, file_id_key) orelse break;
        pos = fid_pos + file_id_key.len;
        while (pos < json.len and json[pos] == ' ') pos += 1;

        var file_id: i64 = 0;
        while (pos < json.len and json[pos] >= '0' and json[pos] <= '9') {
            file_id = file_id * 10 + @as(i64, json[pos] - '0');
            pos += 1;
        }
        if (file_id == 0) continue;

        var r = &results[result_count];
        r.* = std.mem.zeroes(SubResult);
        r.file_id = file_id;

        const search_start = if (fid_pos > 500) fid_pos - 500 else 0;
        const context = json[search_start..@min(pos + 500, json.len)];

        if (findJsonString(context, "\"release\":\"")) |rel| {
            const copy_len = @min(rel.len, r.release.len);
            @memcpy(r.release[0..copy_len], rel[0..copy_len]);
            r.release_len = copy_len;
        } else if (findJsonString(context, "\"file_name\":\"")) |fname| {
            const copy_len = @min(fname.len, r.release.len);
            @memcpy(r.release[0..copy_len], fname[0..copy_len]);
            r.release_len = copy_len;
        }

        if (findJsonString(context, "\"language\":\"")) |lang_str| {
            const copy_len = @min(lang_str.len, r.language.len);
            @memcpy(r.language[0..copy_len], lang_str[0..copy_len]);
            r.lang_len = copy_len;
        }

        if (findJsonInt(context, "\"download_count\":")) |dc| {
            r.download_count = @intCast(@min(dc, std.math.maxInt(i32)));
        }
        if (std.mem.indexOf(u8, context, "\"hearing_impaired\":true") != null) r.hearing_impaired = true;
        if (std.mem.indexOf(u8, context, "\"ai_translated\":true") != null) r.ai_translated = true;

        result_count += 1;
    }

    if (result_count == 0) {
        if (findJsonString(json, "\"message\":\"")) |msg| {
            setError(msg);
        } else {
            setError("No subtitles found");
        }
    }
}

fn findJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, json, key) orelse return null;
    const start = idx + key.len;
    if (start >= json.len) return null;
    var end = start;
    while (end < json.len) {
        if (json[end] == '"' and (end == start or json[end - 1] != '\\')) break;
        end += 1;
    }
    if (end <= start) return null;
    return json[start..end];
}

fn findJsonInt(json: []const u8, key: []const u8) ?i64 {
    const idx = std.mem.indexOf(u8, json, key) orelse return null;
    var pos = idx + key.len;
    while (pos < json.len and json[pos] == ' ') pos += 1;
    var val: i64 = 0;
    var found = false;
    while (pos < json.len and json[pos] >= '0' and json[pos] <= '9') {
        val = val * 10 + @as(i64, json[pos] - '0');
        pos += 1;
        found = true;
    }
    return if (found) val else null;
}

// ── Download subtitle by file_id ──
pub fn downloadSubtitle(file_id: i64) void {
    if (is_downloading) return;
    is_downloading = true;

    const S = struct { var fid: i64 = 0; };
    S.fid = file_id;

    if (std.Thread.spawn(.{}, struct {
        fn work() void {
            defer { is_downloading = false; }
            doDownload(S.fid);
        }
    }.work, .{})) |t| t.detach() else |_| {
        is_downloading = false;
    }
}

fn doDownload(file_id: i64) void {
    if (state.app.opensub_api_key_len == 0) {
        state.showToast("Set API key in Settings");
        return;
    }

    const api_key = state.app.opensub_api_key[0..state.app.opensub_api_key_len];

    // POST body: {"file_id": 12345}
    var body_buf: [64]u8 = undefined;
    const body = std.fmt.bufPrintZ(&body_buf, "{{\"file_id\":{d}}}", .{file_id}) catch return;

    // Api-Key header
    var hdr_buf: [160]u8 = undefined;
    const hdr_prefix = "Api-Key: ";
    @memcpy(hdr_buf[0..hdr_prefix.len], hdr_prefix);
    @memcpy(hdr_buf[hdr_prefix.len..][0..api_key.len], api_key);
    hdr_buf[hdr_prefix.len + api_key.len] = 0;

    const hdr_len = hdr_prefix.len + api_key.len;
    const hdr_slice: []const u8 = hdr_buf[0..hdr_len];
    const body_slice: []const u8 = body;

    var child = @import("../core/io_global.zig").Child.init(
        &.{ "curl", "-s", "--max-time", "15", "-X", "POST",
             "-H", "Content-Type: application/json",
             "-H", hdr_slice,
             "-H", "User-Agent: " ++ USER_AGENT,
             "-d", body_slice,
             API_BASE ++ "/download" },
        @import("../core/alloc.zig").allocator,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        state.showToast("Download failed (curl)");
        return;
    };

    var resp_buf: [4096]u8 = undefined;
    var n: usize = 0;
    if (child.stdout) |*stdout| {
        n = @import("../core/io_global.zig").readAll(stdout, &resp_buf) catch 0;
    }
    _ = child.wait() catch {};

    if (n == 0) {
        state.showToast("No download response");
        return;
    }

    const link = findJsonString(resp_buf[0..n], "\"link\":\"") orelse {
        if (findJsonString(resp_buf[0..n], "\"message\":\"")) |msg| {
            const tlen = @min(msg.len, 80);
            state.showToast(msg[0..tlen]);
        } else {
            state.showToast("Failed to get download link");
        }
        return;
    };

    // Download .srt to /tmp
    var path_buf: [128]u8 = undefined;
    const sub_path = std.fmt.bufPrintZ(&path_buf, "/tmp/opal_sub_{d}.srt", .{file_id}) catch return;

    // Need null-terminated link for curl
    var link_z: [512]u8 = undefined;
    const link_len = @min(link.len, link_z.len - 1);
    @memcpy(link_z[0..link_len], link[0..link_len]);
    link_z[link_len] = 0;

    const link_slice: []const u8 = link_z[0..link_len];

    var dl_child = @import("../core/io_global.zig").Child.init(
        &.{ "curl", "-s", "--max-time", "15", "-L", "-o", sub_path,
             link_slice },
        @import("../core/alloc.zig").allocator,
    );
    dl_child.stdout_behavior = .Ignore;
    dl_child.stderr_behavior = .Ignore;
    dl_child.spawn() catch {
        state.showToast("Download failed");
        return;
    };
    _ = dl_child.wait() catch {};

    // Load into mpv
    if (state.app.active_player_idx < state.app.players.items.len) {
        const p = state.app.players.items[state.app.active_player_idx];
        var cmd_buf: [256]u8 = undefined;
        const cmd = std.fmt.bufPrintZ(&cmd_buf, "sub-add \"{s}\"", .{sub_path}) catch return;
        _ = c.mpv.mpv_command_string(p.mpv_ctx, cmd.ptr);
    }

    state.showToast("Subtitle loaded");
    logs.pushLog("info", "subs", "Subtitle downloaded and loaded", false);
}

// ── Auto-search from currently playing file ──
pub fn autoSearchFromPlayer() void {
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const p = state.app.players.items[state.app.active_player_idx];

    const title_c = c.mpv.mpv_get_property_string(p.mpv_ctx, "media-title");
    if (title_c != null) {
        defer c.mpv.mpv_free(@ptrCast(title_c));
        const ts = std.mem.span(title_c);
        if (ts.len > 0 and !std.mem.eql(u8, ts, "No file") and !std.mem.eql(u8, ts, "stream")) {
            const lang = if (state.app.sub_lang_len > 0) state.app.sub_lang_buf[0..state.app.sub_lang_len] else "en";
            searchByQuery(ts, lang);
            return;
        }
    }

    if (p.current_url_len > 0 and p.current_url_len <= p.current_url.len) {
        const url = p.current_url[0..p.current_url_len];
        const base_end = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
        const path = url[0..base_end];
        const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx|
            (if (idx + 1 < path.len) path[idx + 1 ..] else path)
        else
            path;

        if (basename.len > 0 and !std.mem.eql(u8, basename, "stream")) {
            const name_end = std.mem.lastIndexOfScalar(u8, basename, '.') orelse basename.len;
            var clean_buf: [256]u8 = undefined;
            const copy_len = @min(name_end, clean_buf.len);
            for (basename[0..copy_len], 0..) |ch, ci| {
                clean_buf[ci] = if (ch == '.' or ch == '_') ' ' else ch;
            }
            const lang = if (state.app.sub_lang_len > 0) state.app.sub_lang_buf[0..state.app.sub_lang_len] else "en";
            searchByQuery(clean_buf[0..copy_len], lang);
        }
    }
}
