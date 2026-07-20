const std = @import("std");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");

// Use the same page allocator as browser.zig
const alloc = @import("../core/alloc.zig").allocator;

// ══════════════════════════════════════════════════════════
// URL Normalization
// ══════════════════════════════════════════════════════════

/// Normalize URLs for yt-dlp compatibility (e.g. .com → .org to bypass geo blocks)
pub fn normalizeUrl(url: []const u8, buf: *[2048]u8) []const u8 {
    const rewrites = [_]struct { from: []const u8, to: []const u8 }{
        .{ .from = "pornhub.com", .to = "pornhub.org" },
    };
    
    for (rewrites) |rw| {
        if (std.mem.indexOf(u8, url, rw.from)) |pos| {
            const before = url[0..pos];
            const after = url[pos + rw.from.len ..];
            const total = before.len + rw.to.len + after.len;
            if (total <= 2048) {
                @memcpy(buf[0..before.len], before);
                @memcpy(buf[before.len .. before.len + rw.to.len], rw.to);
                @memcpy(buf[before.len + rw.to.len .. total], after);
                return buf[0..total];
            }
        }
    }
    return url; // no rewrite needed
}

// ══════════════════════════════════════════════════════════
// Playlist Detection
// ══════════════════════════════════════════════════════════

/// Detect if a URL is a playlist/channel page rather than a single video.
pub fn isPlaylistUrl(url: []const u8) bool {
    // YouTube playlists & channels
    if (std.mem.indexOf(u8, url, "playlist?list=") != null) return true;
    if (std.mem.indexOf(u8, url, "/channel/") != null) return true;
    if (std.mem.indexOf(u8, url, "/@") != null) return true;

    // Adult site channel/model pages
    const playlist_paths = [_][]const u8{
        "/model/", "/pornstar/", "/channels/", "/users/",
    };
    for (playlist_paths) |path| {
        if (std.mem.indexOf(u8, url, path) != null) return true;
    }

    return false;
}

// ══════════════════════════════════════════════════════════
// Playlist Extraction (yt-dlp --flat-playlist)
// ══════════════════════════════════════════════════════════

// NOTE: extract_url_buf/extract_url_len are written by extractPlaylist() on the
// UI thread and read by extractThread().  The extract_thread guard ensures only
// one extraction runs at a time — callers MUST only invoke extractPlaylist()
// from the UI thread.
var extract_url_buf: [2048]u8 = undefined;
var extract_url_len: usize = 0;
var extract_thread: ?std.Thread = null;

pub fn extractPlaylist(url: []const u8) void {
    if (extract_thread != null) {
        state.showToast("Playlist extraction already running...");
        return;
    }
    const len = @min(url.len, 2047);
    @memcpy(extract_url_buf[0..len], url[0..len]);
    extract_url_len = len;

    extract_thread = std.Thread.spawn(.{}, extractThread, .{}) catch {
        state.showToast("Failed to start extraction thread");
        return;
    };
}

fn extractThread() void {
    defer {
        extract_thread = null;
    }

    const url = extract_url_buf[0..extract_url_len];
    const queue_mod = @import("queue.zig");
    queue_mod.initDb();

    // yt-dlp --flat-playlist -j <url> outputs one JSON object per line
    // Pass --cookies-from-browser=firefox (like phub-cli) for sites requiring auth
    // If proxy is configured, also pass --proxy
    const has_proxy = state.app.proxy_url_len > 0;
    const proxy_str = state.app.proxy_url[0..state.app.proxy_url_len];
    
    const ytdlp_bin = @import("ytdlp.zig").binary();
    // No youtube:player_client pin here — the `tv` client this used to force now
    // returns storyboard-only formats, which broke every YouTube resolve. yt-dlp
    // maintains its own client-fallback chain; let it choose. See
    // src/player/ytdl_opts_pure.zig for the full history.
    const argv_proxy = [_][]const u8{
        ytdlp_bin, "--flat-playlist", "-j",
        "--no-warnings",
        "--cookies-from-browser", "firefox",
        "--proxy", proxy_str,
        "--", url,
    };
    const argv_direct = [_][]const u8{
        ytdlp_bin, "--flat-playlist", "-j",
        "--no-warnings",
        "--cookies-from-browser", "firefox",
        "--", url,
    };
    const argv: []const []const u8 = if (has_proxy) &argv_proxy else &argv_direct;

    var child = @import("../core/io_global.zig").Child.init(argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    _ = child.spawn() catch {
        state.showToast("yt-dlp failed to start");
        logs.pushLog("error", "playlist", "yt-dlp failed to spawn", true);
        return;
    };

    const stdout = child.stdout orelse return;

    var count: usize = 0;
    var first_url_buf: [2048]u8 = undefined;
    var first_url_len: usize = 0;

    // Log what we're extracting
    logs.pushLog("info", "playlist", "Extracting playlist...", false);

    // Read all stdout at once (playlist JSON is typically < 1MB)
    const out_buf = alloc.alloc(u8, 1024 * 1024) catch {
        state.showToast("Out of memory for playlist extraction");
        return;
    };
    defer alloc.free(out_buf);
    const total_read = @import("../core/io_global.zig").readAll(stdout, out_buf) catch 0;
    
    // Also read stderr for error reporting
    var err_buf: [4096]u8 = undefined;
    const err_read = if (child.stderr) |*stderr| @import("../core/io_global.zig").readAll(stderr, &err_buf) catch 0 else 0;
    _ = child.wait() catch {};



    if (total_read == 0) {
        if (err_read > 0) {
            const err_str = err_buf[0..@min(err_read, 120)];
            const first_nl = std.mem.indexOfScalar(u8, err_str, '\n') orelse err_str.len;
            logs.pushLog("error", "playlist", err_str[0..first_nl], true);
        }
        state.showToast("No playlist data — check Logs tab");
        return;
    }

    // Split by newlines and process each JSON line
    var remaining = out_buf[0..total_read];
    while (remaining.len > 0) {
        const nl = std.mem.indexOfScalar(u8, remaining, '\n') orelse remaining.len;
        const line = remaining[0..nl];
        remaining = if (nl < remaining.len) remaining[nl + 1..] else remaining[remaining.len..];
        
        if (line.len < 10) continue;
        
        // Extract "url" and "title" from JSON line
        // Use "webpage_url" first (canonical), fall back to "url" key
        var video_url = extractJsonField(line, "\"webpage_url\"");
        if (video_url.len == 0) video_url = extractJsonField(line, "\"url\"");
        const video_title = extractJsonField(line, "\"title\"");
        const video_thumb = extractJsonField(line, "\"thumbnail\"");

        if (video_url.len > 0) {
            const title = if (video_title.len > 0) video_title else video_url;
            queue_mod.addToQueueWithThumb(video_url, title, "playlist", video_thumb);
            count += 1;

            // Save first URL for immediate playback
            if (first_url_len == 0 and video_url.len < 2048) {
                @memcpy(first_url_buf[0..video_url.len], video_url);
                first_url_len = video_url.len;
            }
        }
    }

    // Play first video immediately. This runs on the detached extraction thread,
    // seconds after it started — the user may have closed the player meanwhile,
    // which frees the *MediaPlayer. Hold players_mutex across the lookup + the
    // load_file call and re-check the bound INSIDE the lock so `p` can't dangle
    // (mirrors ai_tools.zig / watch_party.zig / remote.zig).
    if (first_url_len > 0) {
        state.players_mutex.lock();
        defer state.players_mutex.unlock();
        if (state.app.active_player_idx < state.app.players.items.len) {
            const p = state.app.players.items[state.app.active_player_idx];
            p.provider = .mpv;
            var url_z: [2049]u8 = undefined;
            @memcpy(url_z[0..first_url_len], first_url_buf[0..first_url_len]);
            url_z[first_url_len] = 0;
            p.load_file(@ptrCast(&url_z[0]));
        }
    }

    if (count > 0) {
        // Show toast with count
        var msg_buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Added {d} videos to queue", .{count}) catch "Playlist loaded";
        state.showToast(msg);
        // Open playlist drawer which now shows queue
        state.app.playlist_drawer_open = true;
    } else {
        state.showToast("No videos found in playlist");
    }
}

// ══════════════════════════════════════════════════════════
// JSON Helpers
// ══════════════════════════════════════════════════════════

/// Simple JSON field extractor (avoids needing a full JSON parser).
/// Looks for "field": "value" and returns value.
fn extractJsonField(json: []const u8, field: []const u8) []const u8 {
    const field_pos = std.mem.indexOf(u8, json, field) orelse return "";
    const after_field = field_pos + field.len;
    
    // Skip ": " or ":"
    var pos = after_field;
    while (pos < json.len and (json[pos] == ':' or json[pos] == ' ')) pos += 1;
    if (pos >= json.len or json[pos] != '"') return "";
    pos += 1; // skip opening quote
    
    const val_start = pos;
    while (pos < json.len and json[pos] != '"') {
        if (json[pos] == '\\') pos += 1; // skip escaped chars
        pos += 1;
    }
    
    if (pos > val_start) return json[val_start..pos];
    return "";
}
