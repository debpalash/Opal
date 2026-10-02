//! Allowlisted static assets for the web companion.
//!
//! Routing an explicit table keeps arbitrary filesystem paths off the network
//! surface. Development reads `web/`; packaged builds resolve the same relative
//! paths below the runtime resource root.

const std = @import("std");
const state = @import("../core/state.zig");
const io_g = @import("../core/io_global.zig");
const alloc = @import("../core/alloc.zig").allocator;
const sync = @import("../core/sync.zig");
const pure = @import("remote_static_pure.zig");

const Cache = enum { no_store, revalidate, immutable };

const Asset = struct {
    route: []const u8,
    bundled: []const u8,
    dev: []const u8,
    content_type: []const u8,
    cache: Cache,
};

const assets = [_]Asset{
    .{ .route = "/", .bundled = "index.html", .dev = "web/index.html", .content_type = "text/html", .cache = .no_store },
    .{ .route = "/index.html", .bundled = "index.html", .dev = "web/index.html", .content_type = "text/html", .cache = .no_store },
    .{ .route = "/manifest.webmanifest", .bundled = "manifest.webmanifest", .dev = "web/manifest.webmanifest", .content_type = "application/manifest+json", .cache = .revalidate },
    .{ .route = "/service-worker.js", .bundled = "service-worker.js", .dev = "web/service-worker.js", .content_type = "application/javascript", .cache = .revalidate },
    .{ .route = "/styles/app.css", .bundled = "styles/app.css", .dev = "web/styles/app.css", .content_type = "text/css; charset=utf-8", .cache = .revalidate },
    .{ .route = "/js/core.js", .bundled = "js/core.js", .dev = "web/js/core.js", .content_type = "application/javascript", .cache = .revalidate },
    .{ .route = "/js/now-playing.js", .bundled = "js/now-playing.js", .dev = "web/js/now-playing.js", .content_type = "application/javascript", .cache = .revalidate },
    .{ .route = "/js/search.js", .bundled = "js/search.js", .dev = "web/js/search.js", .content_type = "application/javascript", .cache = .revalidate },
    .{ .route = "/js/catalog.js", .bundled = "js/catalog.js", .dev = "web/js/catalog.js", .content_type = "application/javascript", .cache = .revalidate },
    .{ .route = "/js/playback.js", .bundled = "js/playback.js", .dev = "web/js/playback.js", .content_type = "application/javascript", .cache = .revalidate },
    .{ .route = "/js/integrations.js", .bundled = "js/integrations.js", .dev = "web/js/integrations.js", .content_type = "application/javascript", .cache = .revalidate },
    .{ .route = "/js/access.js", .bundled = "js/access.js", .dev = "web/js/access.js", .content_type = "application/javascript", .cache = .revalidate },
    .{ .route = "/js/source-management.js", .bundled = "js/source-management.js", .dev = "web/js/source-management.js", .content_type = "application/javascript", .cache = .revalidate },
    .{ .route = "/js/media.js", .bundled = "js/media.js", .dev = "web/js/media.js", .content_type = "application/javascript", .cache = .revalidate },
    .{ .route = "/js/source-details.js", .bundled = "js/source-details.js", .dev = "web/js/source-details.js", .content_type = "application/javascript", .cache = .revalidate },
    .{ .route = "/js/discovery.js", .bundled = "js/discovery.js", .dev = "web/js/discovery.js", .content_type = "application/javascript", .cache = .revalidate },
    .{ .route = "/js/boot.js", .bundled = "js/boot.js", .dev = "web/js/boot.js", .content_type = "application/javascript", .cache = .revalidate },
    .{ .route = "/icon.svg", .bundled = "icon.svg", .dev = "assets/logo.svg", .content_type = "image/svg+xml", .cache = .immutable },
    .{ .route = "/favicon.ico", .bundled = "icon.svg", .dev = "assets/logo.svg", .content_type = "image/svg+xml", .cache = .immutable },
    .{ .route = "/vendor/hls.min.js", .bundled = "vendor/hls.min.js", .dev = "web/vendor/hls.min.js", .content_type = "application/javascript", .cache = .immutable },
};

/// One asset's bytes, read at most once per process in a packaged build.
const Loaded = struct {
    body: []const u8 = &.{},
    etag: [24]u8 = undefined,
    etag_len: usize = 0,
    filled: bool = false,
};

var loaded: [assets.len]Loaded = [_]Loaded{.{}} ** assets.len;
var loaded_mutex: sync.Mutex = .{};

/// Serve an allowlisted asset. Returns false when `route` belongs to another
/// handler, allowing the caller to continue API/media routing.
///
/// `raw_request` is the full request head, read only for `If-None-Match`.
pub fn serve(stream: std.Io.net.Stream, route: []const u8, raw_request: []const u8) bool {
    for (assets, 0..) |asset, index| {
        if (!std.mem.eql(u8, route, asset.route)) continue;
        serveAsset(stream, asset, index, raw_request);
        return true;
    }
    return false;
}

/// A packaged build serves the same immutable bytes for its whole lifetime, so
/// each file is read once and kept. A dev checkout deliberately keeps reading
/// from disk: `just run` has to show an edited `web/js/*.js` on reload, and a
/// cache would hide exactly that.
fn memoizeAssets() bool {
    return state.resourceRoot() != null;
}

fn serveAsset(stream: std.Io.net.Stream, asset: Asset, index: usize, raw_request: []const u8) void {
    var path_buf: [800]u8 = undefined;
    if (state.resourceRoot()) |root| {
        const bundled = std.fmt.bufPrint(&path_buf, "{s}/web/{s}", .{ root, asset.bundled }) catch "";
        if (bundled.len > 0 and exists(bundled)) return serveFile(stream, bundled, asset, index, raw_request);
    }
    serveFile(stream, asset.dev, asset, index, raw_request);
}

fn exists(path: []const u8) bool {
    const file = io_g.cwdOpenFile(path, .{}) catch return false;
    file.close(io_g.io());
    return true;
}

/// Read `path` once and memoize it. The allocation is intentionally retained
/// for the process lifetime; there are 17 allowlisted files totalling well
/// under a megabyte.
fn loadOnce(index: usize, path: []const u8) ?*const Loaded {
    loaded_mutex.lock();
    defer loaded_mutex.unlock();
    const slot = &loaded[index];
    if (slot.filled) return slot;
    const file = io_g.cwdOpenFile(path, .{}) catch return null;
    defer file.close(io_g.io());
    const body = io_g.readToEndAlloc(file, alloc, 4 * 1024 * 1024) catch return null;
    slot.body = body;
    if (std.fmt.bufPrint(&slot.etag, "\"{x:0>16}\"", .{std.hash.Fnv1a_64.hash(body)})) |out| {
        slot.etag_len = out.len;
    } else |_| {
        slot.etag_len = 0;
    }
    slot.filled = true;
    return slot;
}

/// Case-insensitive `name: value` lookup over a raw request head.
fn headerValue(raw: []const u8, name: []const u8) ?[]const u8 {
    return pure.headerValue(raw, name);
}

/// True when the client already holds this exact body (or `*`).
fn clientHasEtag(raw: []const u8, etag: []const u8) bool {
    return pure.clientHasEtag(raw, etag);
}

fn serveFile(stream: std.Io.net.Stream, path: []const u8, asset: Asset, index: usize, raw_request: []const u8) void {
    var body: []const u8 = undefined;
    var owned_body: ?[]u8 = null;
    defer if (owned_body) |bytes| alloc.free(bytes);
    var etag: []const u8 = "";
    if (memoizeAssets()) {
        const slot = loadOnce(index, path) orelse return notFound(stream);
        body = slot.body;
        etag = slot.etag[0..slot.etag_len];
    } else {
        const file = io_g.cwdOpenFile(path, .{}) catch return notFound(stream);
        defer file.close(io_g.io());
        const raw = io_g.readToEndAlloc(file, alloc, 4 * 1024 * 1024) catch return notFound(stream);
        owned_body = raw;
        body = raw;
    }

    // `no-cache` without a validator is worse than no header at all: it forces
    // the browser to revalidate and then re-download the whole body, because
    // there is nothing to compare against. With an ETag, `must-revalidate`
    // yields a cheap 304 instead.
    const cache_header: []const u8 = switch (asset.cache) {
        .no_store => "Cache-Control: no-store\r\n",
        .revalidate => "Cache-Control: max-age=0, must-revalidate\r\n",
        .immutable => "Cache-Control: public, max-age=31536000, immutable\r\n",
    };
    const privacy_header: []const u8 = if (std.mem.eql(u8, asset.content_type, "text/html"))
        "Referrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; media-src 'self' blob:; connect-src 'self'\r\n"
    else
        "";
    const validator: []const u8 = if (etag.len > 0) "ETag: " else "";
    const etag_line: []const u8 = if (etag.len > 0) etag else "";
    const etag_end: []const u8 = if (etag.len > 0) "\r\n" else "";

    if (etag.len > 0 and clientHasEtag(raw_request, etag)) {
        var header: [1024]u8 = undefined;
        const h = std.fmt.bufPrint(&header, "HTTP/1.1 304 Not Modified\r\n{s}{s}{s}{s}{s}\r\n", .{ validator, etag_line, etag_end, cache_header, privacy_header }) catch return;
        io_g.streamWriteAll(stream, h) catch {};
        return;
    }

    var header: [1024]u8 = undefined;
    const h = std.fmt.bufPrint(&header, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nX-Content-Type-Options: nosniff\r\n{s}{s}{s}{s}{s}Content-Length: {d}\r\n\r\n", .{ asset.content_type, validator, etag_line, etag_end, cache_header, privacy_header, body.len }) catch return;
    io_g.streamWriteAll(stream, h) catch return;
    io_g.streamWriteAll(stream, body) catch {};
}

fn notFound(stream: std.Io.net.Stream) void {
    io_g.streamWriteAll(stream, "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found") catch {};
}

test "asset table exposes only explicit web paths" {
    var found_css = false;
    for (assets) |asset| {
        try std.testing.expect(std.mem.startsWith(u8, asset.route, "/"));
        if (std.mem.eql(u8, asset.route, "/styles/app.css")) found_css = true;
    }
    try std.testing.expect(found_css);
}
