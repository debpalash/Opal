const std = @import("std");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const c = @import("../core/c.zig");
const alloc = @import("../core/alloc.zig").allocator;
const io_g = @import("../core/io_global.zig");
const sp = @import("subtitles_pure.zig");

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
pub var is_searching: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var search_error: [128]u8 = std.mem.zeroes([128]u8);
pub var search_error_len: usize = 0;
pub var is_downloading: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// ══════════════════════════════════════════════════════════
// Subdl (api.subdl.com) — a second KEYED provider, parallel to the
// OpenSubtitles.com vars above. Free per-user key (subdl.com → panel → API);
// empty key ⇒ fully inert. Downloads arrive as ZIP archives, extracted
// in-process via std.zip (handles store/deflate/zip64, no external unzip).
// ══════════════════════════════════════════════════════════
pub const SubdlResult = struct {
    /// Download path under dl.subdl.com, e.g. "/subtitle/3098966-3116742.zip".
    url: [512]u8 = std.mem.zeroes([512]u8),
    url_len: usize = 0,
    release: [200]u8 = std.mem.zeroes([200]u8),
    release_len: usize = 0,
    lang: [8]u8 = std.mem.zeroes([8]u8),
    lang_len: usize = 0,
};
pub var subdl_results: [MAX_RESULTS]SubdlResult = std.mem.zeroes([MAX_RESULTS]SubdlResult);
pub var subdl_result_count: usize = 0;
pub var subdl_is_searching: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var subdl_is_downloading: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var subdl_error: [128]u8 = std.mem.zeroes([128]u8);
pub var subdl_error_len: usize = 0;

// ── Search by query ──
pub fn searchByQuery(query: []const u8, lang: []const u8) void {
    if (query.len == 0) return;
    // Atomically claim the search slot — only proceed if we flipped false→true,
    // closing the UI-thread check-then-spawn race.
    if (is_searching.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;

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
            defer { is_searching.store(false, .release); }
            doSearch(S.q_buf[0..S.q_len], S.l_buf[0..S.l_len]);
        }
    }.work, .{})) |t| t.detach() else |_| {
        is_searching.store(false, .release);
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
        // Auto mode (fired on playback start): immediately grab the best match
        // — most-downloaded, non-AI-translated — and sub-add it, inline on this
        // worker thread (doDownload is just two more curl calls).
        if (auto_mode) {
            auto_mode = false;
            var best_idx: usize = 0;
            var best_dl: i32 = -1;
            for (results[0..result_count], 0..) |r, idx| {
                if (r.ai_translated) continue;
                if (r.download_count > best_dl) {
                    best_dl = r.download_count;
                    best_idx = idx;
                }
            }
            doDownload(results[best_idx].file_id);
        }
    }
}

/// Set true by autoFetchForPlayer so the search worker chains straight into
/// downloading the best result. Reset once consumed.
var auto_mode: bool = false;
/// Hash of the media path we last auto-fetched for — dedupes repeat FILE_LOADED
/// events (seeks, track changes) for the same file.
var last_auto_hash: u64 = 0;

/// Fire-and-forget auto subtitle fetch for the active player's media. Called
/// from the mpv FILE_LOADED handler when no subtitle track is present. No-ops
/// on streams without a usable title, when disabled, without an API key, or if
/// we already tried this exact file.
pub fn autoFetchForPlayer() void {
    if (!state.app.auto_download_subs) return;
    if (state.app.opensub_api_key_len == 0) return; // can't — silently skip
    if (is_searching.load(.acquire) or is_downloading.load(.acquire)) return;
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const p = state.app.players.items[state.app.active_player_idx];

    // Dedupe on the current media path.
    if (p.current_url_len > 0 and p.current_url_len <= p.current_url.len) {
        const h = std.hash.Wyhash.hash(0, p.current_url[0..p.current_url_len]);
        if (h == last_auto_hash) return;
        last_auto_hash = h;
    }

    autoSearchFromPlayer(true); // auto=true → doSearch chains into download
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
    // Atomically claim the download slot — only proceed if we flipped false→true,
    // closing the UI-thread check-then-spawn race.
    if (is_downloading.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;

    const S = struct { var fid: i64 = 0; };
    S.fid = file_id;

    if (std.Thread.spawn(.{}, struct {
        fn work() void {
            defer { is_downloading.store(false, .release); }
            doDownload(S.fid);
        }
    }.work, .{})) |t| t.detach() else |_| {
        is_downloading.store(false, .release);
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
pub fn autoSearchFromPlayer(auto: bool) void {
    auto_mode = auto; // consumed by doSearch on success; harmless if no search fires
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

// ══════════════════════════════════════════════════════════
// Subdl provider — search + ZIP download
// ══════════════════════════════════════════════════════════

fn setSubdlError(msg: []const u8) void {
    const len = @min(msg.len, subdl_error.len);
    @memcpy(subdl_error[0..len], msg[0..len]);
    subdl_error_len = len;
}

/// Search Subdl for `query` in `lang` (an app language code, e.g. "eng").
/// No-ops without a key. Runs on a detached worker; results land in
/// `subdl_results`. `lang` is snapshotted, then mapped to Subdl's 2-letter code.
pub fn subdlSearch(query: []const u8, lang: []const u8) void {
    if (query.len == 0) return;
    // Atomically claim the search slot — only proceed if we flipped false→true.
    if (subdl_is_searching.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;

    subdl_result_count = 0;
    subdl_error_len = 0;

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
            defer subdl_is_searching.store(false, .release);
            doSubdlSearch(S.q_buf[0..S.q_len], S.l_buf[0..S.l_len]);
        }
    }.work, .{})) |t| t.detach() else |_| {
        subdl_is_searching.store(false, .release);
    }
}

fn doSubdlSearch(query: []const u8, lang: []const u8) void {
    if (state.app.subdl_api_key_len == 0) {
        setSubdlError("Set Subdl API key in Settings → Subtitles");
        return;
    }

    const http = @import("../core/http.zig");
    const api_key = state.app.subdl_api_key[0..state.app.subdl_api_key_len];
    const subdl_lang = sp.subdlLangCode(lang);

    var enc: [512]u8 = undefined;
    const encoded = http.urlEncode(query, &enc);

    // NB: Subdl takes the key in the query string (its API has no header form).
    // Never log this URL — it carries the key.
    var url_buf: [896]u8 = undefined;
    const url = std.fmt.bufPrintZ(&url_buf, "https://api.subdl.com/api/v1/subtitles?api_key={s}&film_name={s}&languages={s}&subs_per_page=30", .{ api_key, encoded, subdl_lang }) catch {
        setSubdlError("Query too long");
        return;
    };

    var child = io_g.Child.init(
        &.{ "curl", "-s", "--max-time", "15", "-A", USER_AGENT, url },
        alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        setSubdlError("Failed to spawn curl");
        return;
    };

    var response_buf: [64 * 1024]u8 = undefined;
    var n: usize = 0;
    if (child.stdout) |*stdout| {
        n = io_g.readAll(stdout, &response_buf) catch 0;
    }
    _ = child.wait() catch {};

    if (n == 0) {
        setSubdlError("No response from Subdl");
        return;
    }

    parseSubdl(response_buf[0..n], lang);

    if (subdl_result_count > 0) {
        logs.pushLog("info", "subs", "Subdl subtitles found", false);
    }
}

/// Fill `subdl_results` from a Subdl response via the pure parser. `want_lang`
/// is the app language code; when the row carries a short code we double-check
/// it (the server already filtered by `&languages=`, so this only guards
/// against surprises — full-name/empty langs are kept as-is).
fn parseSubdl(json: []const u8, want_lang: []const u8) void {
    subdl_result_count = 0;

    var parsed: [MAX_RESULTS]sp.SubdlSub = undefined;
    const pn = sp.subdlSubs(json, &parsed);

    for (parsed[0..pn]) |ps| {
        if (subdl_result_count >= MAX_RESULTS) break;
        if (ps.url.len == 0) continue;
        if (ps.lang.len >= 2 and ps.lang.len <= 3 and !sp.langMatches(want_lang, ps.lang)) continue;

        var r = &subdl_results[subdl_result_count];
        r.* = std.mem.zeroes(SubdlResult);

        const ul = @min(ps.url.len, r.url.len);
        @memcpy(r.url[0..ul], ps.url[0..ul]);
        r.url_len = ul;

        const rl = @min(ps.release.len, r.release.len);
        @memcpy(r.release[0..rl], ps.release[0..rl]);
        r.release_len = rl;

        const ll = @min(ps.lang.len, r.lang.len);
        @memcpy(r.lang[0..ll], ps.lang[0..ll]);
        r.lang_len = ll;

        subdl_result_count += 1;
    }

    if (subdl_result_count == 0) {
        if (findJsonString(json, "\"error\":\"")) |msg| {
            setSubdlError(msg);
        } else {
            setSubdlError("No Subdl subtitles found");
        }
    }
}

/// Download Subdl result `idx` (a ZIP), extract the first subtitle in-process,
/// and sub-add it to the active player. Runs on a detached worker; the URL is
/// snapshotted before spawn.
pub fn subdlDownload(idx: usize) void {
    // Atomically claim the download slot — only proceed if we flipped false→true.
    if (subdl_is_downloading.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
    if (idx >= subdl_result_count) {
        subdl_is_downloading.store(false, .release);
        return;
    }

    const S = struct {
        var url: [512]u8 = undefined;
        var url_len: usize = 0;
    };
    const r = &subdl_results[idx];
    S.url_len = r.url_len;
    @memcpy(S.url[0..S.url_len], r.url[0..S.url_len]);

    if (std.Thread.spawn(.{}, struct {
        fn work() void {
            defer subdl_is_downloading.store(false, .release);
            doSubdlDownload(S.url[0..S.url_len]);
        }
    }.work, .{})) |t| t.detach() else |_| {
        subdl_is_downloading.store(false, .release);
    }
}

fn doSubdlDownload(url_path: []const u8) void {
    if (url_path.len == 0) {
        state.showToast("Bad subtitle link");
        return;
    }

    io_g.cwdMakePath("/tmp/opal_subs") catch {};

    var url_buf: [640]u8 = undefined;
    const url = std.fmt.bufPrintZ(&url_buf, "https://dl.subdl.com{s}", .{url_path}) catch {
        state.showToast("Bad subtitle link");
        return;
    };

    const zip_path = "/tmp/opal_subs/subdl.zip";
    var dl = io_g.Child.init(
        &.{ "curl", "-s", "-L", "--max-time", "25", "-A", USER_AGENT, "-o", zip_path, url },
        alloc,
    );
    dl.stdout_behavior = .Ignore;
    dl.stderr_behavior = .Ignore;
    dl.spawn() catch {
        state.showToast("Download failed (curl)");
        return;
    };
    _ = dl.wait() catch {};

    const st = io_g.cwdStatFile(zip_path) catch {
        state.showToast("Subtitle download failed");
        return;
    };
    if (st.size < 100) {
        state.showToast("Subtitle archive empty");
        return;
    }

    var path_buf: [1024]u8 = undefined;
    const srt = extractFirstSubtitle(zip_path, "/tmp/opal_subs/subdl", &path_buf) orelse {
        state.showToast("No subtitle in archive");
        logs.pushLog("warn", "subs", "Subdl ZIP contained no subtitle file", true);
        return;
    };

    if (state.app.active_player_idx < state.app.players.items.len) {
        const p = state.app.players.items[state.app.active_player_idx];
        var cmd_buf: [1152]u8 = undefined;
        const cmd = std.fmt.bufPrintZ(&cmd_buf, "sub-add \"{s}\"", .{srt}) catch return;
        _ = c.mpv.mpv_command_string(p.mpv_ctx, cmd.ptr);
    }

    state.showToast("Subtitle loaded");
    logs.pushLog("info", "subs", "Subdl subtitle downloaded and loaded", false);
}

/// Extract `zip_path` into a freshly-cleaned `extract_dir` and return the path
/// of the first subtitle file inside (recursively), preferring `.srt`. Uses
/// std.zip (store/deflate/zip64, backslash-tolerant). Returns null when the
/// archive is unreadable or holds no subtitle. `out_buf` owns the returned slice.
fn extractFirstSubtitle(zip_path: []const u8, extract_dir: []const u8, out_buf: []u8) ?[]const u8 {
    const io = io_g.io();
    const cwd = std.Io.Dir.cwd();

    // Clean the target so std.zip's exclusive-create never collides with stale
    // files from a previous download.
    cwd.deleteTree(io, extract_dir) catch {};
    cwd.createDirPath(io, extract_dir) catch return null;

    // Extract everything. The 64KB reader buffer lives on the heap to keep the
    // worker stack lean (std.zip's own extract already uses a large stack frame).
    {
        var zf = cwd.openFile(io, zip_path, .{}) catch return null;
        defer zf.close(io);
        const rbuf = alloc.alloc(u8, 64 * 1024) catch return null;
        defer alloc.free(rbuf);
        var fr = zf.reader(io, rbuf);
        var dest = cwd.openDir(io, extract_dir, .{}) catch return null;
        defer dest.close(io);
        // A partial extraction can still yield the .srt — swallow errors and let
        // the walk below decide success.
        std.zip.extract(dest, &fr, .{ .allow_backslashes = true }) catch {};
    }

    // Recursive walk for the first subtitle, preferring .srt over other formats.
    var wdir = cwd.openDir(io, extract_dir, .{ .iterate = true }) catch return null;
    defer wdir.close(io);
    var w = wdir.walk(alloc) catch return null;
    defer w.deinit();

    var fallback_buf: [1024]u8 = undefined;
    var fallback: ?[]const u8 = null;
    while (w.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const p = entry.path; // relative, sentinel-terminated
        if (std.ascii.endsWithIgnoreCase(p, ".srt")) {
            return std.fmt.bufPrint(out_buf, "{s}/{s}", .{ extract_dir, p }) catch null;
        }
        if (fallback == null and isSubtitleExt(p)) {
            fallback = std.fmt.bufPrint(&fallback_buf, "{s}/{s}", .{ extract_dir, p }) catch null;
        }
    }
    if (fallback) |fb| {
        const n = @min(fb.len, out_buf.len);
        @memcpy(out_buf[0..n], fb[0..n]);
        return out_buf[0..n];
    }
    return null;
}

/// True for mpv-loadable subtitle extensions other than .srt.
fn isSubtitleExt(name: []const u8) bool {
    const exts = [_][]const u8{ ".ass", ".ssa", ".sub", ".vtt", ".smi" };
    for (exts) |e| if (std.ascii.endsWithIgnoreCase(name, e)) return true;
    return false;
}
