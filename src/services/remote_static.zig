//! Allowlisted static assets for the web companion.
//!
//! Routing an explicit table keeps arbitrary filesystem paths off the network
//! surface. Development reads `web/`; packaged builds resolve the same relative
//! paths below the runtime resource root.

const std = @import("std");
const state = @import("../core/state.zig");
const io_g = @import("../core/io_global.zig");
const alloc = @import("../core/alloc.zig").allocator;

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
    .{ .route = "/js/catalog.js", .bundled = "js/catalog.js", .dev = "web/js/catalog.js", .content_type = "application/javascript", .cache = .revalidate },
    .{ .route = "/js/playback.js", .bundled = "js/playback.js", .dev = "web/js/playback.js", .content_type = "application/javascript", .cache = .revalidate },
    .{ .route = "/js/integrations.js", .bundled = "js/integrations.js", .dev = "web/js/integrations.js", .content_type = "application/javascript", .cache = .revalidate },
    .{ .route = "/js/media.js", .bundled = "js/media.js", .dev = "web/js/media.js", .content_type = "application/javascript", .cache = .revalidate },
    .{ .route = "/js/discovery.js", .bundled = "js/discovery.js", .dev = "web/js/discovery.js", .content_type = "application/javascript", .cache = .revalidate },
    .{ .route = "/js/boot.js", .bundled = "js/boot.js", .dev = "web/js/boot.js", .content_type = "application/javascript", .cache = .revalidate },
    .{ .route = "/icon.svg", .bundled = "icon.svg", .dev = "assets/logo.svg", .content_type = "image/svg+xml", .cache = .immutable },
    .{ .route = "/favicon.ico", .bundled = "icon.svg", .dev = "assets/logo.svg", .content_type = "image/svg+xml", .cache = .immutable },
    .{ .route = "/vendor/hls.min.js", .bundled = "vendor/hls.min.js", .dev = "web/vendor/hls.min.js", .content_type = "application/javascript", .cache = .immutable },
};

/// Serve an allowlisted asset. Returns false when `route` belongs to another
/// handler, allowing the caller to continue API/media routing.
pub fn serve(stream: std.Io.net.Stream, route: []const u8) bool {
    for (assets) |asset| {
        if (!std.mem.eql(u8, route, asset.route)) continue;
        serveAsset(stream, asset);
        return true;
    }
    return false;
}

fn serveAsset(stream: std.Io.net.Stream, asset: Asset) void {
    var path_buf: [800]u8 = undefined;
    if (state.resourceRoot()) |root| {
        const bundled = std.fmt.bufPrint(&path_buf, "{s}/web/{s}", .{ root, asset.bundled }) catch "";
        if (bundled.len > 0 and exists(bundled)) return serveFile(stream, bundled, asset);
    }
    serveFile(stream, asset.dev, asset);
}

fn exists(path: []const u8) bool {
    const file = io_g.cwdOpenFile(path, .{}) catch return false;
    file.close(io_g.io());
    return true;
}

fn serveFile(stream: std.Io.net.Stream, path: []const u8, asset: Asset) void {
    const file = io_g.cwdOpenFile(path, .{}) catch return notFound(stream);
    defer file.close(io_g.io());
    const body = io_g.readToEndAlloc(file, alloc, 4 * 1024 * 1024) catch return notFound(stream);
    defer alloc.free(body);

    const cache_header: []const u8 = switch (asset.cache) {
        .no_store => "Cache-Control: no-store\r\n",
        .revalidate => "Cache-Control: no-cache\r\n",
        .immutable => "Cache-Control: public, max-age=31536000, immutable\r\n",
    };
    const privacy_header: []const u8 = if (std.mem.eql(u8, asset.content_type, "text/html"))
        "Referrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; media-src 'self' blob:; connect-src 'self'\r\n"
    else
        "";
    var header: [1024]u8 = undefined;
    const h = std.fmt.bufPrint(&header, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nX-Content-Type-Options: nosniff\r\n{s}{s}Content-Length: {d}\r\n\r\n", .{ asset.content_type, cache_header, privacy_header, body.len }) catch return;
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
