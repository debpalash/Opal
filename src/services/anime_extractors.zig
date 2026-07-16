//! Anime video extractors — the fetch+resolve driver.
//!
//! `resolveEmbed(embed_url)` classifies a streaming-host EMBED URL, fetches the
//! embed page (anti-block scrapeFetch, or curl when host-specific headers are
//! required), routes every string/JSON decision through `anime_extractors_pure`,
//! and returns the direct stream URL + the mandatory Referer + any subtitle
//! tracks. For hosts yt-dlp already handles (youtube/dailymotion/ok.ru/vk/sibnet)
//! it returns a `delegate` sentinel: the caller hands the ORIGINAL embed URL to
//! mpv's ytdl-hook and lets it resolve.
//!
//! SYNCHRONOUS + BLOCKING — call only from a worker thread (it does HTTP).

const std = @import("std");
const pure = @import("anime_extractors_pure.zig");
const scrape = @import("scrape_fetch.zig");
const logs = @import("../core/logs.zig");
const io_g = @import("../core/io_global.zig");
const alloc = @import("../core/alloc.zig").allocator;

const UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0";

pub const Sub = struct {
    url: [512]u8 = undefined,
    url_len: usize = 0,
    label: [64]u8 = undefined,
    label_len: usize = 0,
};

pub const Resolved = struct {
    /// Direct playable stream (m3u8/mp4) — OR, when `delegate` is true, the
    /// original embed URL to feed mpv's ytdl-hook.
    stream_url: [1024]u8 = undefined,
    stream_len: usize = 0,
    referer: [256]u8 = undefined,
    referer_len: usize = 0,
    subs: [8]Sub = undefined,
    sub_count: usize = 0,
    /// true → skip extraction, pass `stream_url` (the embed) to mpv/yt-dlp.
    delegate: bool = false,

    pub fn streamUrl(self: *const Resolved) []const u8 {
        return self.stream_url[0..self.stream_len];
    }
    pub fn refererStr(self: *const Resolved) []const u8 {
        return self.referer[0..self.referer_len];
    }

    fn setStream(self: *Resolved, url: []const u8) void {
        const n = @min(url.len, self.stream_url.len);
        @memcpy(self.stream_url[0..n], url[0..n]);
        self.stream_len = n;
    }
    fn setReferer(self: *Resolved, ref: []const u8) void {
        const n = @min(ref.len, self.referer.len);
        @memcpy(self.referer[0..n], ref[0..n]);
        self.referer_len = n;
    }
    fn addSub(self: *Resolved, url: []const u8, label: []const u8) void {
        if (self.sub_count >= self.subs.len or url.len == 0) return;
        var s = Sub{};
        const un = @min(url.len, s.url.len);
        @memcpy(s.url[0..un], url[0..un]);
        s.url_len = un;
        const ln = @min(label.len, s.label.len);
        @memcpy(s.label[0..ln], label[0..ln]);
        s.label_len = ln;
        self.subs[self.sub_count] = s;
        self.sub_count += 1;
    }
};

/// curl GET into `out` with an optional Referer and an optional
/// X-Requested-With: XMLHttpRequest header (needed by MegaCloud). Returns the
/// body slice, or null. Worker-thread only.
fn curlGet(url: []const u8, referer: ?[]const u8, xrw: bool, out: []u8) ?[]const u8 {
    var refbuf: [640]u8 = undefined;
    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(alloc);
    argv.appendSlice(alloc, &.{ "curl", "-sL", "--compressed", "--max-time", "20", "-A", UA }) catch return null;
    if (referer) |r| {
        const h = std.fmt.bufPrint(&refbuf, "Referer: {s}", .{r}) catch return null;
        argv.appendSlice(alloc, &.{ "-H", h }) catch return null;
    }
    if (xrw) argv.appendSlice(alloc, &.{ "-H", "X-Requested-With: XMLHttpRequest" }) catch return null;
    argv.append(alloc, url) catch return null;

    var child = io_g.Child.init(argv.items, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;

    var body_len: usize = 0;
    if (child.stdout) |*stdout| {
        while (body_len < out.len) {
            const r = io_g.read(stdout, out[body_len..]) catch break;
            if (r == 0) break;
            body_len += r;
        }
        var junk: [4096]u8 = undefined;
        while (true) {
            const r = io_g.read(stdout, &junk) catch break;
            if (r == 0) break;
        }
    }
    _ = child.wait() catch {};
    if (body_len == 0) return null;
    return out[0..body_len];
}

/// Resolve a streaming-host EMBED URL to a direct stream. Returns null when the
/// host is unknown or extraction fails (caller should fall back). Worker-thread
/// only — allocates ~1MB of HTML scratch on the heap.
pub fn resolveEmbed(embed_url: []const u8) ?Resolved {
    const host = pure.classifyHost(embed_url);

    // yt-dlp handles these — hand the ORIGINAL embed to mpv's ytdl-hook.
    if (host == .delegate_ytdlp) {
        var r = Resolved{ .delegate = true };
        r.setStream(embed_url);
        logs.pushLog("info", "anime", "Embed delegated to yt-dlp/ytdl-hook", false);
        return r;
    }
    if (host == .unknown) return null;

    // Referer = scheme://host/ of the embed — mandatory for every host's CDN.
    var ref_buf: [256]u8 = undefined;
    const referer = pure.refererFor(embed_url, &ref_buf) orelse return null;

    // Heap scratch — HTML/JS payloads can be several hundred KB and must not sit
    // on the worker stack (macOS 512KB default).
    const html_buf = alloc.alloc(u8, 1024 * 1024) catch return null;
    defer alloc.free(html_buf);

    switch (host) {
        .streamwish, .filemoon, .vidhide => return resolvePacked(embed_url, referer, html_buf, ".m3u8"),
        .mp4upload => return resolvePacked(embed_url, referer, html_buf, ".mp4"),
        .streamtape => return resolveStreamTape(embed_url, referer, html_buf),
        .doodstream => return resolveDood(embed_url, referer, html_buf),
        .megacloud => return resolveMegaCloud(embed_url, referer, html_buf),
        else => return null,
    }
}

/// StreamWish / Filemoon / VidHide / Mp4Upload — all packed. Fetch, unpack, then
/// pull the `ext` URL out of the unpacked JS.
fn resolvePacked(embed_url: []const u8, referer: []const u8, html_buf: []u8, ext: []const u8) ?Resolved {
    const html = scrape.scrapeFetch(embed_url, html_buf) orelse return null;

    // Unpack in a heap buffer (the unpacked JS can exceed the packed source).
    const un_buf = alloc.alloc(u8, 1024 * 1024) catch return null;
    defer alloc.free(un_buf);
    const sym_buf = alloc.alloc(u8, 256 * 1024) catch return null;
    defer alloc.free(sym_buf);

    var url_buf: [1024]u8 = undefined;
    // First try the unpacked payload, then fall back to the raw HTML (some skins
    // ship the URL in plain sight or in a non-packed <script>).
    const stream: ?[]const u8 = blk: {
        if (pure.unpackPacked(html, un_buf, sym_buf)) |un| {
            if (pure.extractUrlContaining(un, ext, &url_buf)) |u| break :blk u;
        }
        break :blk pure.extractUrlContaining(html, ext, &url_buf);
    };
    const su = stream orelse {
        logs.pushLog("warn", "anime", "Packed host: no stream URL after unpack", false);
        return null;
    };

    var r = Resolved{};
    r.setStream(su);
    r.setReferer(referer);
    return r;
}

fn resolveStreamTape(embed_url: []const u8, referer: []const u8, html_buf: []u8) ?Resolved {
    const html = scrape.scrapeFetch(embed_url, html_buf) orelse return null;
    var url_buf: [512]u8 = undefined;
    const su = pure.extractStreamTape(html, &url_buf) orelse {
        logs.pushLog("warn", "anime", "StreamTape: token extraction failed", false);
        return null;
    };
    var r = Resolved{};
    r.setStream(su);
    r.setReferer(referer);
    return r;
}

fn resolveDood(embed_url: []const u8, referer: []const u8, html_buf: []u8) ?Resolved {
    // Referer for Dood's pass_md5 call must be the embed URL itself.
    const html = scrape.scrapeFetch(embed_url, html_buf) orelse return null;
    const path = pure.extractDoodPath(html) orelse {
        logs.pushLog("warn", "anime", "DoodStream: no pass_md5 path", false);
        return null;
    };
    const token = pure.doodToken(path);
    const rnd = pure.doodRandomToken(path);

    const sh = pure.schemeHostOf(embed_url) orelse return null;
    var md5_url_buf: [640]u8 = undefined;
    const md5_url = std.fmt.bufPrint(&md5_url_buf, "{s}/pass_md5/{s}", .{ sh, path }) catch return null;

    // GET the pass_md5 endpoint (Referer = embed URL) → the base URL prefix.
    var base_buf: [4096]u8 = undefined;
    const base = curlGet(md5_url, embed_url, false, &base_buf) orelse {
        logs.pushLog("warn", "anime", "DoodStream: pass_md5 fetch failed", false);
        return null;
    };

    var url_buf: [1024]u8 = undefined;
    const su = pure.assembleDoodUrl(base, &rnd, token, io_g.milliTimestamp(), &url_buf) orelse return null;

    var r = Resolved{};
    r.setStream(su);
    r.setReferer(referer);
    return r;
}

fn resolveMegaCloud(embed_url: []const u8, referer: []const u8, html_buf: []u8) ?Resolved {
    const source_id = pure.megacloudSourceId(embed_url) orelse return null;

    // Embed HTML needs Referer + X-Requested-With to expose the nonce.
    const html = curlGet(embed_url, referer, true, html_buf) orelse return null;
    var key_buf: [64]u8 = undefined;
    const key = pure.megacloudNonce(html, &key_buf) orelse {
        logs.pushLog("warn", "anime", "MegaCloud: _k nonce not found", false);
        return null;
    };

    var gs_url_buf: [640]u8 = undefined;
    const gs_url = pure.megacloudGetSourcesUrl(embed_url, source_id, key, &gs_url_buf) orelse return null;

    var json_buf: [128 * 1024]u8 = undefined;
    const json = curlGet(gs_url, embed_url, true, &json_buf) orelse {
        logs.pushLog("warn", "anime", "MegaCloud: getSources fetch failed", false);
        return null;
    };

    const gs = pure.parseGetSources(json) orelse {
        logs.pushLog("warn", "anime", "MegaCloud: getSources parse failed", false);
        return null;
    };
    if (gs.encrypted) {
        // Current API returns plaintext when _k is right; an encrypted response
        // means our key aged out. AES path intentionally NOT implemented — skip.
        logs.pushLog("warn", "anime", "MegaCloud: response encrypted (stale _k) — skipping", false);
        return null;
    }

    var r = Resolved{};
    r.setStream(gs.streamUrl());
    r.setReferer(referer);
    for (gs.tracks[0..gs.track_count]) |t| {
        r.addSub(t.url[0..t.url_len], t.label[0..t.label_len]);
    }
    return r;
}
