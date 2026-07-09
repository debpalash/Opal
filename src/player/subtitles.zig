const std = @import("std");
const c = @import("../core/c.zig");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");

/// Pure Zig Subtitle Engine.
/// Queries OpenSubtitles REST API and downloads .srt files using std.http.Client.
/// No external dependencies (no curl, no subprocess).
///
/// Architecture: state machine polled by main loop, work done in background threads.

pub const SubState = enum {
    idle,
    searching,
    found,
    downloading,
    ready,
    failed,
};

/// Which keyless provider produced a result — shown as a chip in the UI.
pub const SubSource = enum {
    opensubtitles, // rest.opensubtitles.org (movies + TV)
    addic7ed, // api.gestdown.info proxy (TV)
};

pub fn sourceName(s: SubSource) []const u8 {
    return switch (s) {
        .opensubtitles => "OpenSubtitles",
        .addic7ed => "Addic7ed",
    };
}

/// Merged result cap: primary provider first, then Gestdown appendings.
pub const MAX_RESULTS = 15;
/// How many of the slots the primary provider may fill.
pub const MAX_PRIMARY = 12;
/// How many Gestdown (Addic7ed) matches get appended after the primary.
pub const MAX_GESTDOWN = 3;

pub const SubResult = struct {
    download_url: [512]u8 = undefined,
    download_url_len: usize = 0,
    movie_name: [256]u8 = undefined,
    movie_name_len: usize = 0,
    lang: [8]u8 = undefined,
    lang_len: usize = 0,
    source: SubSource = .opensubtitles,
};

pub const SubtitleEngine = struct {
    state: SubState = .idle,

    // Merged search results — primary provider first, Gestdown appended.
    results: [MAX_RESULTS]SubResult = undefined,
    result_count: usize = 0,
    selected_idx: usize = 0,

    // Downloaded subtitle path
    srt_path: [384]u8 = undefined,
    srt_path_len: usize = 0,

    // Background thread handle
    thread: ?std.Thread = null,

    // Query used for search
    query_buf: [256]u8 = undefined,
    query_len: usize = 0,

    /// Auto mode (fired on playback start): the search worker chains straight
    /// into downloading the best (first) match. Manual searches from the UI
    /// leave this false and list the results for a per-row Download.
    auto_load: bool = true,

    /// Row index of the sub last handed to mpv, or -1. Lets the UI show a
    /// "Loaded" marker after the .ready → .idle handoff consumes the state.
    loaded_idx: i32 = -1,

    /// Wyhash of the last fired query+lang — dedupes the footer chip so
    /// reopening the picker doesn't re-hit the providers for the same file.
    last_fire_hash: u64 = 0,

    pub fn init() SubtitleEngine {
        return .{};
    }

    pub fn reset(self: *SubtitleEngine) void {
        if (self.thread) |t| {
            t.detach();
        }
        self.state = .idle;
        self.result_count = 0;
        self.selected_idx = 0;
        self.srt_path_len = 0;
        self.thread = null;
        self.query_len = 0;
        self.auto_load = true;
        self.loaded_idx = -1;
    }
};

/// Clean a torrent name into a search query.
/// "Iron.Man.2008.PROPER.1080p.BluRay.x264" → "Iron Man 2008"
fn cleanTorrentName(raw: []const u8, out: *[256]u8) []const u8 {
    var i: usize = 0;
    var out_i: usize = 0;
    
    while (i < raw.len and out_i < 250) : (i += 1) {
        const ch = raw[i];
        
        // Stop at common quality/codec markers
        if (i > 0) {
            const remaining = raw[i..];
            const stop_words = [_][]const u8{
                "1080p", "720p", "2160p", "480p", "4K",
                "BluRay", "WEBRip", "WEB-DL", "HDTV", "DVDRip", "BDRip",
                "x264", "x265", "H.264", "H264", "HEVC", "XviD",
                "PROPER", "REMASTERED", "EXTENDED", "IMAX",
                "AAC", "AC3", "DTS", "FLAC", "MP3",
                "YTS", "RARBG", "FGT", "NTb", "TGx",
                "[", "(", "AMZN",
            };
            var should_stop = false;
            for (stop_words) |sw| {
                if (remaining.len >= sw.len and std.mem.eql(u8, remaining[0..sw.len], sw)) {
                    should_stop = true;
                    break;
                }
            }
            if (should_stop) break;
        }
        
        // Replace dots and underscores with spaces
        if (ch == '.' or ch == '_' or ch == '-') {
            if (out_i > 0 and out[out_i - 1] != ' ') {
                out[out_i] = ' ';
                out_i += 1;
            }
        } else {
            out[out_i] = ch;
            out_i += 1;
        }
    }
    
    // Trim trailing spaces
    while (out_i > 0 and out[out_i - 1] == ' ') out_i -= 1;
    
    return out[0..out_i];
}

/// URL-encode a query string for the API path
fn urlEncode(input: []const u8, out: *[512]u8) []const u8 {
    var oi: usize = 0;
    for (input) |ch| {
        if (oi >= 500) break;
        if (ch == ' ') {
            out[oi] = '-';
            oi += 1;
        } else if ((ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9')) {
            out[oi] = ch;
            oi += 1;
        } else if (ch >= 'A' and ch <= 'Z') {
            // rest.opensubtitles.org 302-redirects any uppercase query to a
            // BROKEN host (https://_/...), so lowercase up front — that path
            // returns 200 directly. (Also fine for Gestdown's show search.)
            out[oi] = ch + 32;
            oi += 1;
        }
        // Skip special chars
    }
    return out[0..oi];
}

/// HTTP GET via curl (already a hard dependency, used across the app). We used
/// std.http.Client here originally, but rest.opensubtitles.org issues a
/// redirect whose Location Zig's client rejects (error.HttpRedirectLocation-
/// Invalid) — curl follows it transparently. curl also handles gzip
/// (--compressed) and HTTP/2, so this is both simpler and more robust.
/// `extra_headers` carries a User-Agent (passed via -A). Returns the body
/// slice inside `response_buf`.
fn httpGet(url_str: []const u8, extra_headers: []const std.http.Header, response_buf: []u8) ![]const u8 {
    const alloc = @import("../core/alloc.zig").allocator;
    const io = @import("../core/io_global.zig");
    var ua: []const u8 = "Opal/1.0";
    for (extra_headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "User-Agent")) ua = h.value;
    }
    var child = io.Child.init(&.{
        "curl", "-s", "-L", "--compressed", "--max-time", "20",
        "-A", ua, url_str,
    }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return error.HttpFailed;
    var n: usize = 0;
    if (child.stdout) |*so| n = io.readAll(so, response_buf) catch 0;
    _ = child.wait() catch {};
    if (n == 0) return error.HttpFailed;
    return response_buf[0..n];
}

/// Background thread: search OpenSubtitles REST API (pure Zig, no curl)
fn searchThread(engine: *SubtitleEngine) void {
    const query = engine.query_buf[0..engine.query_len];
    
    // Build URL
    var url_buf: [768]u8 = undefined;
    var encoded_buf: [512]u8 = undefined;
    const encoded = urlEncode(query, &encoded_buf);
    
    const lang = state.app.sub_lang_buf[0..state.app.sub_lang_len];
    const url = std.fmt.bufPrintZ(&url_buf, "https://rest.opensubtitles.org/search/query-{s}/sublanguageid-{s}", .{encoded, lang}) catch {
        engine.state = .failed;
        return;
    };
    
    logs.pushLog("info", "subs", "Searching subtitles (native)...", false);
    
    // HTTP GET with User-Agent header
    const headers = [_]std.http.Header{
        .{ .name = "User-Agent", .value = "Opal/1.0" },
    };
    
    var response_buf: [128 * 1024]u8 = undefined;
    const json_data = httpGet(url, &headers, &response_buf) catch {
        engine.state = .failed;
        logs.pushLog("error", "subs", "HTTP request failed", true);
        return;
    };
    
    if (json_data.len < 10) {
        engine.state = .failed;
        logs.pushLog("warn", "subs", "Empty subtitle response", true);
        return;
    }
    
    // Parse via the pure (unit-tested) extractor — primary provider first.
    const sp = @import("../services/subtitles_pure.zig");
    var primary: [MAX_PRIMARY]sp.OsRestSub = undefined;
    const primary_n = sp.osRestResults(json_data, &primary);

    var count: usize = 0;
    for (primary[0..primary_n]) |ps| {
        var r = &engine.results[count];
        // OpenSubtitles JSON escapes every slash as \/, so the raw URL is
        // "https:\/\/dl.opensubtitles.org\/..." — std.Uri.parse rejects the
        // backslashes and the download silently fails. Unescape on the way in.
        r.download_url_len = sp.unescapeJsonSlashes(ps.url, &r.download_url);

        // Display-unescape: MovieName arrives with JSON escapes (TV titles are
        // quoted inside the value — the raw copy rendered as a lone "\").
        r.movie_name_len = sp.unescapeJsonString(ps.name, &r.movie_name);

        const l_len = @min(lang.len, r.lang.len);
        @memcpy(r.lang[0..l_len], lang[0..l_len]);
        r.lang_len = l_len;
        r.source = .opensubtitles;
        count += 1;
    }

    // Second keyless provider (Addic7ed via Gestdown) — APPENDS its TV matches
    // to the merged list rather than only rescuing an empty primary.
    count = gestdownAppend(engine, count);

    engine.result_count = count;

    if (count > 0) {
        var log_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&log_buf, "Found {d} subtitles", .{count}) catch "Found subtitles";
        logs.pushLog("info", "subs", msg, false);
        engine.state = .found;

        if (engine.auto_load) {
            // Auto mode (playback start): grab the best match — primary
            // provider first. Runs synchronously on the search thread
            // (intentional — avoids an extra spawn; the transition is seamless).
            downloadThread(engine);
        }
    } else {
        engine.state = .failed;
        logs.pushLog("warn", "subs", "No subtitles found (keyless providers)", true);
    }
}

/// Keyless provider #2: Gestdown (api.gestdown.info, an Addic7ed proxy) for TV
/// episodes. Appends up to MAX_GESTDOWN direct-SRT matches after `base` and
/// returns the new result count. No key, no gzip. Runs on the search thread.
fn gestdownAppend(engine: *SubtitleEngine, base: usize) usize {
    if (base >= engine.results.len) return base;
    const sp = @import("../services/subtitles_pure.zig");
    var q_buf: [256]u8 = undefined;
    var show_buf: [256]u8 = undefined;
    const p = sp.parse(engine.query_buf[0..engine.query_len], &q_buf, &show_buf);
    if (!p.is_tv or p.show.len == 0) return base;

    const headers = [_]std.http.Header{.{ .name = "User-Agent", .value = "Opal/1.0" }};
    var enc: [512]u8 = undefined;

    // 1) show search → first show id (a UUID)
    var url1: [768]u8 = undefined;
    const su = std.fmt.bufPrintZ(&url1, "https://api.gestdown.info/shows/search/{s}", .{urlEncode(p.show, &enc)}) catch return base;
    var buf1: [16 * 1024]u8 = undefined;
    const j1 = httpGet(su, &headers, &buf1) catch return base;
    const show_id = sp.gestdownFirstShowId(j1) orelse return base;

    // 2) episode subtitles → downloadUri + version per match
    const lang_code = state.app.sub_lang_buf[0..state.app.sub_lang_len];
    const lang_name = sp.langFullName(lang_code);
    var url2: [768]u8 = undefined;
    const gu = std.fmt.bufPrintZ(&url2, "https://api.gestdown.info/subtitles/get/{s}/{d}/{d}/{s}", .{ show_id, p.season, p.episode, lang_name }) catch return base;
    var buf2: [32 * 1024]u8 = undefined;
    const j2 = httpGet(gu, &headers, &buf2) catch return base;

    var subs: [MAX_GESTDOWN]sp.GestSub = undefined;
    const room = @min(subs.len, engine.results.len - base);
    const n = sp.gestdownSubs(j2, subs[0..room]);
    if (n == 0) return base;

    var filled: usize = 0;
    for (subs[0..n]) |gs| {
        var r = &engine.results[base + filled];
        const full = std.fmt.bufPrint(&r.download_url, "https://api.gestdown.info{s}", .{gs.uri}) catch continue;
        r.download_url_len = full.len;

        // Row name: "Show SxxEyy · Version" (version omitted when absent).
        const name = if (gs.version.len > 0)
            std.fmt.bufPrint(&r.movie_name, "{s} S{d:0>2}E{d:0>2} \xC2\xB7 {s}", .{ p.show, p.season, p.episode, gs.version }) catch
                std.fmt.bufPrint(&r.movie_name, "{s}", .{p.show}) catch continue
        else
            std.fmt.bufPrint(&r.movie_name, "{s} S{d:0>2}E{d:0>2}", .{ p.show, p.season, p.episode }) catch continue;
        r.movie_name_len = name.len;

        const llen = @min(lang_code.len, r.lang.len);
        @memcpy(r.lang[0..llen], lang_code[0..llen]);
        r.lang_len = llen;
        r.source = .addic7ed;
        filled += 1;
    }
    if (filled > 0) logs.pushLog("info", "subs", "Gestdown (Addic7ed) matches merged", false);
    return base + filled;
}

/// Download the selected subtitle (pure Zig HTTP + gzip decompress)
fn downloadThread(engine: *SubtitleEngine) void {
    if (engine.result_count == 0) {
        engine.state = .failed;
        return;
    }
    
    engine.state = .downloading;
    const r = &engine.results[engine.selected_idx];
    const url = r.download_url[0..r.download_url_len];
    
    @import("../core/io_global.zig").cwdMakePath("/tmp/opal_subs") catch {};
    const srt_path = std.fmt.bufPrintZ(&engine.srt_path, "/tmp/opal_subs/current.srt", .{}) catch {
        engine.state = .failed;
        return;
    };
    engine.srt_path_len = srt_path.len;
    
    // Download the subtitle file via HTTP
    const headers = [_]std.http.Header{
        .{ .name = "User-Agent", .value = "Opal/1.0" },
    };
    
    const alloc = @import("../core/alloc.zig").allocator;
    const response_buf = alloc.alloc(u8, 512 * 1024) catch {
        engine.state = .failed;
        logs.pushLog("error", "subs", "Failed to allocate buffer", true);
        return;
    };
    defer alloc.free(response_buf);
    const data = httpGet(url, &headers, response_buf) catch {
        engine.state = .failed;
        logs.pushLog("error", "subs", "Failed to download subtitle", true);
        return;
    };
    
    if (data.len < 20) {
        engine.state = .failed;
        logs.pushLog("warn", "subs", "Downloaded subtitle is empty", true);
        return;
    }
    
    // Check if it's gzip-compressed (magic bytes 0x1F 0x8B)
    if (data.len >= 2 and data[0] == 0x1F and data[1] == 0x8B) {
        // Save as .gz, then decompress with gunzip
        const gz_path = "/tmp/opal_subs/current.srt.gz";
        const gz_file = @import("../core/io_global.zig").cwdCreateFile(gz_path, .{ .truncate = true }) catch {
            engine.state = .failed;
            return;
        };
        @import("../core/io_global.zig").writeAll(gz_file, data) catch { gz_file.close(@import("../core/io_global.zig").io()); engine.state = .failed; return; };
        gz_file.close(@import("../core/io_global.zig").io());
        
        // Decompress: gunzip -f overwrites
        var gunzip = @import("../core/io_global.zig").Child.init(&.{ "gunzip", "-f", gz_path }, @import("../core/alloc.zig").allocator);
        _ = gunzip.spawnAndWait() catch {
            engine.state = .failed;
            logs.pushLog("error", "subs", "gunzip failed", true);
            return;
        };
        // gunzip produces /tmp/opal_subs/current.srt
    } else {
        // Already uncompressed, write directly
        const file = @import("../core/io_global.zig").cwdCreateFile(srt_path, .{ .truncate = true }) catch {
            engine.state = .failed;
            return;
        };
        defer file.close(@import("../core/io_global.zig").io());
        @import("../core/io_global.zig").writeAll(file, data) catch {
            engine.state = .failed;
            return;
        };
    }
    
    // Verify the .srt file exists and has content
    const stat = @import("../core/io_global.zig").cwdStatFile(srt_path) catch {
        engine.state = .failed;
        logs.pushLog("warn", "subs", "Subtitle file not found after extract", true);
        return;
    };
    if (stat.size > 50) {
        engine.state = .ready;
        logs.pushLog("info", "subs", "Subtitle downloaded!", false);
    } else {
        engine.state = .failed;
        logs.pushLog("warn", "subs", "Downloaded subtitle is empty", true);
    }
}

// ── Public API ──

/// Common search-spawn body. `auto_load` = chain straight into downloading the
/// best match (playback-start auto path) vs. list results for a manual pick.
fn fire(engine: *SubtitleEngine, raw_name: []const u8, auto_load: bool) void {
    if (engine.state == .searching or engine.state == .downloading) return;

    engine.reset();

    var clean_buf: [256]u8 = undefined;
    const clean = cleanTorrentName(raw_name, &clean_buf);
    if (clean.len == 0) return;

    const copy_len = @min(clean.len, engine.query_buf.len);
    @memcpy(engine.query_buf[0..copy_len], clean[0..copy_len]);
    engine.query_len = copy_len;
    engine.auto_load = auto_load;
    engine.last_fire_hash = fireHash(clean);

    engine.state = .searching;

    engine.thread = std.Thread.spawn(.{}, searchThread, .{engine}) catch {
        engine.state = .failed;
        logs.pushLog("error", "subs", "Failed to spawn search thread", true);
        return;
    };
}

/// Wyhash of query+language — the double-fire guard key.
fn fireHash(clean_query: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(clean_query);
    h.update(state.app.sub_lang_buf[0..state.app.sub_lang_len]);
    return h.final();
}

/// Start an automatic subtitle search in the background (playback start):
/// downloads the best match as soon as the search lands.
pub fn startSearch(engine: *SubtitleEngine, torrent_name: []const u8) void {
    fire(engine, torrent_name, true);
}

/// Manual search from the UI (footer picker / Settings): lists merged,
/// source-tagged results; nothing downloads until downloadIndex is called.
pub fn searchQuery(engine: *SubtitleEngine, query: []const u8) void {
    fire(engine, query, false);
}

/// Manual search seeded from the active player's media title (or the URL
/// basename). Debounced: if the same query+language already has results
/// listed, the existing list is kept instead of re-hitting the providers —
/// the footer chip calls this every time the picker opens.
pub fn searchFromActivePlayer(engine: *SubtitleEngine) void {
    if (engine.state == .searching or engine.state == .downloading) return;
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const p = state.app.players.items[state.app.active_player_idx];

    var title_buf: [256]u8 = undefined;
    var qname: []const u8 = "";
    const tc = c.mpv.mpv_get_property_string(p.mpv_ctx, "media-title");
    if (tc != null) {
        const ts = std.mem.span(tc);
        if (ts.len > 0 and !std.mem.eql(u8, ts, "No file") and !std.mem.eql(u8, ts, "stream")) {
            const n = @min(ts.len, title_buf.len);
            @memcpy(title_buf[0..n], ts[0..n]);
            qname = title_buf[0..n];
        }
        c.mpv.mpv_free(@ptrCast(tc));
    }
    if (qname.len == 0 and p.current_url_len > 0 and p.current_url_len <= p.current_url.len) {
        const url = p.current_url[0..p.current_url_len];
        const base_end = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
        const path = url[0..base_end];
        qname = if (std.mem.lastIndexOfScalar(u8, path, '/')) |ix|
            (if (ix + 1 < path.len) path[ix + 1 ..] else path)
        else
            path;
    }
    if (qname.len == 0) return;

    // Double-fire guard: same query+lang with a live result list → keep it.
    var clean_buf: [256]u8 = undefined;
    const clean = cleanTorrentName(qname, &clean_buf);
    if (clean.len == 0) return;
    if (fireHash(clean) == engine.last_fire_hash and engine.result_count > 0 and engine.state != .failed) return;

    fire(engine, qname, false);
}

/// Re-run the current query (e.g. after the search language changed). No-ops
/// when nothing was searched yet or a worker is busy.
pub fn refire(engine: *SubtitleEngine) void {
    if (engine.query_len == 0) return;
    if (engine.state == .searching or engine.state == .downloading) return;
    var q_buf: [256]u8 = undefined;
    const n = @min(engine.query_len, q_buf.len);
    @memcpy(q_buf[0..n], engine.query_buf[0..n]);
    fire(engine, q_buf[0..n], false);
}

/// Download result `idx` on a worker thread. On completion the engine state
/// flips to .ready and the player poll sub-adds it via loadIntoMpv (that
/// poll-side contract is unchanged).
pub fn downloadIndex(engine: *SubtitleEngine, idx: usize) void {
    if (engine.state == .searching or engine.state == .downloading) return;
    if (idx >= engine.result_count) return;

    engine.selected_idx = idx;
    engine.state = .downloading;

    if (engine.thread) |t| t.detach();
    engine.thread = std.Thread.spawn(.{}, downloadThread, .{engine}) catch {
        engine.state = .failed;
        logs.pushLog("error", "subs", "Failed to spawn download thread", true);
        return;
    };
}

/// Load the downloaded subtitle into mpv.
pub fn loadIntoMpv(engine: *SubtitleEngine, mpv_ctx: *c.mpv.mpv_handle) void {
    if (engine.state != .ready) return;

    const path = engine.srt_path[0..engine.srt_path_len];
    var cmd_buf: [512]u8 = undefined;
    const cmd = std.fmt.bufPrintZ(&cmd_buf, "sub-add \"{s}\"", .{path}) catch return;
    _ = c.mpv.mpv_command_string(mpv_ctx, cmd.ptr);
    engine.loaded_idx = @intCast(@min(engine.selected_idx, std.math.maxInt(i32)));
    state.showToast("Subtitle loaded");
    logs.pushLog("info", "subs", "Subtitle loaded into player", false);
}
