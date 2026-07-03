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

pub const SubResult = struct {
    download_url: [512]u8 = undefined,
    download_url_len: usize = 0,
    movie_name: [256]u8 = undefined,
    movie_name_len: usize = 0,
    lang: [8]u8 = undefined,
    lang_len: usize = 0,
};

pub const SubtitleEngine = struct {
    state: SubState = .idle,
    
    // Search results (up to 5)
    results: [5]SubResult = undefined,
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
        } else if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9')) {
            out[oi] = ch;
            oi += 1;
        }
        // Skip special chars
    }
    return out[0..oi];
}

/// Perform an HTTP GET request using std.http.Client. Pure Zig, no curl.
/// Returns the response body length written into `response_buf`.
fn httpGet(url_str: []const u8, extra_headers: []const std.http.Header, response_buf: []u8) ![]const u8 {
    var client = std.http.Client{ .allocator = @import("../core/alloc.zig").allocator , .io = @import("../core/io_global.zig").io() };
    defer client.deinit();
    
    const uri = std.Uri.parse(url_str) catch return error.HttpFailed;
    
    var req = client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(3),
        .extra_headers = extra_headers,
    }) catch return error.HttpFailed;
    defer req.deinit();
    
    req.sendBodiless() catch return error.HttpFailed;
    
    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return error.HttpFailed;
    
    if (response.head.status != .ok) {
        return error.HttpBadStatus;
    }
    
    // Read body using allocRemaining
    var transfer_buf: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    
    const body = reader.allocRemaining(@import("../core/alloc.zig").allocator, std.Io.Limit.limited(response_buf.len)) catch return error.HttpFailed;
    defer @import("../core/alloc.zig").allocator.free(body);
    
    if (body.len > response_buf.len) return error.HttpFailed;
    @memcpy(response_buf[0..body.len], body);
    
    return response_buf[0..body.len];
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
    
    // Parse JSON manually — find SubDownloadLink and MovieName entries
    var count: usize = 0;
    var pos: usize = 0;
    
    while (count < 5 and pos < json_data.len) {
        // Find next SubDownloadLink
        const dl_key = "\"SubDownloadLink\":\"";
        const dl_start = std.mem.indexOfPos(u8, json_data, pos, dl_key) orelse break;
        const url_start = dl_start + dl_key.len;
        const url_end = std.mem.indexOfPos(u8, json_data, url_start, "\"") orelse break;
        const sub_url = json_data[url_start..url_end];
        
        // Find MovieName near this position
        var movie_name: []const u8 = "Unknown";
        const mn_key = "\"MovieName\":\"";
        const search_start = if (dl_start > 2000) dl_start - 2000 else 0;
        const mn_search = json_data[search_start..dl_start];
        if (std.mem.lastIndexOf(u8, mn_search, mn_key)) |mn_offset| {
            const mn_start = search_start + mn_offset + mn_key.len;
            if (std.mem.indexOfPos(u8, json_data, mn_start, "\"")) |mn_end| {
                movie_name = json_data[mn_start..mn_end];
            }
        }
        
        // Store result
        var r = &engine.results[count];
        const u_len = @min(sub_url.len, r.download_url.len);
        @memcpy(r.download_url[0..u_len], sub_url[0..u_len]);
        r.download_url_len = u_len;
        
        const m_len = @min(movie_name.len, r.movie_name.len);
        @memcpy(r.movie_name[0..m_len], movie_name[0..m_len]);
        r.movie_name_len = m_len;
        
        @memcpy(r.lang[0..lang.len], lang);
        r.lang_len = lang.len;
        
        count += 1;
        pos = url_end + 1;
    }
    
    engine.result_count = count;
    
    if (count > 0) {
        engine.state = .found;
        var log_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&log_buf, "Found {d} subtitles", .{count}) catch "Found subtitles";
        logs.pushLog("info", "subs", msg, false);
        
        // Auto-download the first result
        // NOTE: Download runs synchronously on the search thread (intentional —
        // avoids an extra thread spawn and the search→download transition is seamless).
        downloadThread(engine);
    } else if (gestdownFallback(engine)) {
        // Second keyless provider (Addic7ed via Gestdown) found a TV match.
        engine.state = .found;
        downloadThread(engine);
    } else {
        engine.state = .failed;
        logs.pushLog("warn", "subs", "No subtitles found (keyless providers)", true);
    }
}

/// Keyless provider #2: Gestdown (api.gestdown.info, an Addic7ed proxy) for TV
/// episodes. Returns true and fills engine.results[0] with a direct .srt URL
/// when a match is found. No key, no gzip. Runs on the search thread.
fn gestdownFallback(engine: *SubtitleEngine) bool {
    const sp = @import("../services/subtitles_pure.zig");
    var q_buf: [256]u8 = undefined;
    var show_buf: [256]u8 = undefined;
    const p = sp.parse(engine.query_buf[0..engine.query_len], &q_buf, &show_buf);
    if (!p.is_tv or p.show.len == 0) return false;

    const headers = [_]std.http.Header{.{ .name = "User-Agent", .value = "Opal/1.0" }};
    var enc: [512]u8 = undefined;

    // 1) show search → first show id (a UUID)
    var url1: [768]u8 = undefined;
    const su = std.fmt.bufPrintZ(&url1, "https://api.gestdown.info/shows/search/{s}", .{urlEncode(p.show, &enc)}) catch return false;
    var buf1: [16 * 1024]u8 = undefined;
    const j1 = httpGet(su, &headers, &buf1) catch return false;
    const id_key = "\"id\":\"";
    const id_s = (std.mem.indexOf(u8, j1, id_key) orelse return false) + id_key.len;
    const id_e = std.mem.indexOfScalarPos(u8, j1, id_s, '"') orelse return false;
    const show_id = j1[id_s..id_e];
    if (show_id.len < 8) return false;

    // 2) episode subtitles → first downloadUri
    const lang_name = sp.langFullName(state.app.sub_lang_buf[0..state.app.sub_lang_len]);
    var url2: [768]u8 = undefined;
    const gu = std.fmt.bufPrintZ(&url2, "https://api.gestdown.info/subtitles/get/{s}/{d}/{d}/{s}", .{ show_id, p.season, p.episode, lang_name }) catch return false;
    var buf2: [32 * 1024]u8 = undefined;
    const j2 = httpGet(gu, &headers, &buf2) catch return false;
    const du_key = "\"downloadUri\":\"";
    const du_s = (std.mem.indexOf(u8, j2, du_key) orelse return false) + du_key.len;
    const du_e = std.mem.indexOfScalarPos(u8, j2, du_s, '"') orelse return false;
    const uri = j2[du_s..du_e]; // e.g. "/subtitles/download/<uuid>"
    if (uri.len < 8) return false;

    var r = &engine.results[0];
    const full = std.fmt.bufPrint(&r.download_url, "https://api.gestdown.info{s}", .{uri}) catch return false;
    r.download_url_len = full.len;
    const mlen = @min(p.show.len, r.movie_name.len);
    @memcpy(r.movie_name[0..mlen], p.show[0..mlen]);
    r.movie_name_len = mlen;
    const llen = @min(lang_name.len, r.lang.len);
    @memcpy(r.lang[0..llen], lang_name[0..llen]);
    r.lang_len = llen;
    engine.result_count = 1;
    engine.selected_idx = 0;
    logs.pushLog("info", "subs", "Found subtitle via Gestdown (Addic7ed)", false);
    return true;
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

/// Start a subtitle search in the background.
pub fn startSearch(engine: *SubtitleEngine, torrent_name: []const u8) void {
    if (engine.state == .searching or engine.state == .downloading) return;
    
    engine.reset();
    
    var clean_buf: [256]u8 = undefined;
    const clean = cleanTorrentName(torrent_name, &clean_buf);
    if (clean.len == 0) return;
    
    const copy_len = @min(clean.len, engine.query_buf.len);
    @memcpy(engine.query_buf[0..copy_len], clean[0..copy_len]);
    engine.query_len = copy_len;
    
    engine.state = .searching;
    
    engine.thread = std.Thread.spawn(.{}, searchThread, .{engine}) catch {
        engine.state = .failed;
        logs.pushLog("error", "subs", "Failed to spawn search thread", true);
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
    logs.pushLog("info", "subs", "Subtitle loaded into player", false);
}
