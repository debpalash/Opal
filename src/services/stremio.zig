const std = @import("std");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");

const alloc = @import("../core/alloc.zig").allocator;

// ══════════════════════════════════════════════════════════
// Stremio Addon Catalog — browse community addons and
// install them to get streaming sources
// ══════════════════════════════════════════════════════════

pub const Addon = struct {
    name: [64]u8 = std.mem.zeroes([64]u8),
    name_len: usize = 0,
    description: [256]u8 = std.mem.zeroes([256]u8),
    desc_len: usize = 0,
    url: [256]u8 = std.mem.zeroes([256]u8),
    url_len: usize = 0,
    types: [64]u8 = std.mem.zeroes([64]u8),  // "movie,series"
    types_len: usize = 0,
    installed: bool = false,
};

pub var addons: [32]Addon = undefined;
pub var addon_count: usize = 0;
pub var installed_addons: [16]Addon = undefined;
pub var installed_count: usize = 0;
pub var is_loading: bool = false;
pub var catalog_loaded: bool = false;

// Stream results from addon queries
pub const StreamResult = struct {
    title: [128]u8 = std.mem.zeroes([128]u8),
    title_len: usize = 0,
    url: [512]u8 = std.mem.zeroes([512]u8),
    url_len: usize = 0,
    addon_name: [32]u8 = std.mem.zeroes([32]u8),
    addon_name_len: usize = 0,
};

pub var streams: [32]StreamResult = undefined;
pub var stream_count: usize = 0;
pub var stream_loading: bool = false;

/// Fetch community addon catalog
pub fn fetchCatalog() void {
    if (is_loading) return;
    is_loading = true;
    addon_count = 0;

    _ = std.Thread.spawn(.{}, struct {
        fn worker() void {
            defer is_loading = false;

            // Fetch the community addon list from Stremio's public API
            const url = "https://stremio-addons.com/catalog.json";
            const argv = [_][]const u8{
                "curl", "-sL", "--max-time", "15", url,
            };
            var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Ignore;
            _ = child.spawn() catch {
                logs.pushLog("error", "stremio", "Failed to fetch catalog", true);
                return;
            };

            var buf: [256 * 1024]u8 = undefined;
            const n = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, &buf) catch 0 else 0;
            _ = child.wait() catch {};

            if (n < 10) {
                // Fallback: add well-known community addons
                addKnownAddons();
                catalog_loaded = true;
                return;
            }

            // Parse JSON array of addons
            // Format: [{"name":"...","description":"...","transportUrl":"...","types":["movie","series"]}]
            var pos: usize = 0;
            while (pos < n and addon_count < 32) {
                const name_key = "\"name\":\"";
                const next = std.mem.indexOf(u8, buf[pos..], name_key) orelse break;
                const abs = pos + next;

                var addon = &addons[addon_count];
                addon.* = std.mem.zeroes(Addon);

                // Name
                const ns = abs + name_key.len;
                const ne = std.mem.indexOfScalar(u8, buf[ns..], '"') orelse break;
                const nlen = @min(ne, 63);
                @memcpy(addon.name[0..nlen], buf[ns .. ns + nlen]);
                addon.name_len = nlen;

                // Description
                if (std.mem.indexOf(u8, buf[ns..], "\"description\":\"")) |dp| {
                    const ds = ns + dp + 15;
                    if (ds < n) {
                        const de = std.mem.indexOfScalar(u8, buf[ds..], '"') orelse 0;
                        const dlen = @min(de, 255);
                        @memcpy(addon.description[0..dlen], buf[ds .. ds + dlen]);
                        addon.desc_len = dlen;
                    }
                }

                // Transport URL
                if (std.mem.indexOf(u8, buf[ns..], "\"transportUrl\":\"")) |tp| {
                    const ts = ns + tp + 16;
                    if (ts < n) {
                        const te = std.mem.indexOfScalar(u8, buf[ts..], '"') orelse 0;
                        const tlen = @min(te, 255);
                        @memcpy(addon.url[0..tlen], buf[ts .. ts + tlen]);
                        addon.url_len = tlen;
                    }
                }

                // Check if installed
                addon.installed = isInstalled(addon.name[0..addon.name_len]);

                addon_count += 1;
                pos = ns + ne;
            }

            if (addon_count == 0) addKnownAddons();
            catalog_loaded = true;
            logs.pushLog("info", "stremio", "Catalog loaded", false);
        }
    }.worker, .{}) catch {};
}

/// Add well-known addons as fallback when the catalog API is unavailable
fn addKnownAddons() void {
    const known = [_]struct { name: []const u8, desc: []const u8, url: []const u8, types: []const u8 }{
        .{ .name = "Torrentio", .desc = "Torrent streams from multiple indexers", .url = "https://torrentio.strem.fun/manifest.json", .types = "movie,series" },
        .{ .name = "CyberFlix", .desc = "Free streaming from multiple sources", .url = "https://cyberflix.elfhosted.com/manifest.json", .types = "movie,series" },
        .{ .name = "MediaFusion", .desc = "Combined torrent and DDL streams", .url = "https://mediafusion.elfhosted.com/manifest.json", .types = "movie,series" },
        .{ .name = "Comet", .desc = "Debrid streaming via Real-Debrid/AllDebrid", .url = "https://comet.elfhosted.com/manifest.json", .types = "movie,series" },
        .{ .name = "Anime Kitsu", .desc = "Anime catalog with Kitsu integration", .url = "https://anime-kitsu.strem.fun/manifest.json", .types = "anime" },
        .{ .name = "OpenSubtitles", .desc = "Subtitles from OpenSubtitles.com", .url = "https://opensubtitles-v3.strem.io/manifest.json", .types = "movie,series" },
    };
    for (known, 0..) |k, i| {
        if (i >= 32) break;
        var a = &addons[i];
        a.* = std.mem.zeroes(Addon);
        const nlen = @min(k.name.len, 63);
        @memcpy(a.name[0..nlen], k.name[0..nlen]);
        a.name_len = nlen;
        const dlen = @min(k.desc.len, 255);
        @memcpy(a.description[0..dlen], k.desc[0..dlen]);
        a.desc_len = dlen;
        const ulen = @min(k.url.len, 255);
        @memcpy(a.url[0..ulen], k.url[0..ulen]);
        a.url_len = ulen;
        const tlen = @min(k.types.len, 63);
        @memcpy(a.types[0..tlen], k.types[0..tlen]);
        a.types_len = tlen;
        a.installed = isInstalled(a.name[0..a.name_len]);
    }
    addon_count = known.len;
}

fn isInstalled(name: []const u8) bool {
    for (0..installed_count) |i| {
        if (std.mem.eql(u8, installed_addons[i].name[0..installed_addons[i].name_len], name)) return true;
    }
    return false;
}

/// Install an addon (store its URL for stream queries)
pub fn installAddon(idx: usize) void {
    if (idx >= addon_count or installed_count >= 16) return;
    const addon = &addons[idx];
    if (addon.installed) return;

    var inst = &installed_addons[installed_count];
    inst.* = addon.*;
    inst.installed = true;
    installed_count += 1;
    addon.installed = true;

    var msg: [128]u8 = undefined;
    const toast = std.fmt.bufPrint(&msg, "Installed {s}", .{addon.name[0..addon.name_len]}) catch "Addon installed";
    state.showToast(toast);
}

/// Remove installed addon
pub fn removeAddon(idx: usize) void {
    if (idx >= installed_count) return;
    const name = installed_addons[idx].name[0..installed_addons[idx].name_len];

    // Unmark in catalog
    for (0..addon_count) |ci| {
        if (std.mem.eql(u8, addons[ci].name[0..addons[ci].name_len], name)) {
            addons[ci].installed = false;
        }
    }

    // Shift installed list
    var i = idx;
    while (i + 1 < installed_count) : (i += 1) {
        installed_addons[i] = installed_addons[i + 1];
    }
    installed_count -= 1;
}

/// Query all installed addons for streams matching an IMDB ID
pub fn queryStreams(imdb_id: []const u8, media_type: []const u8) void {
    if (stream_loading) return;
    stream_loading = true;
    stream_count = 0;

    // Copy args for thread
    var id_buf: [32]u8 = std.mem.zeroes([32]u8);
    const id_len = @min(imdb_id.len, 31);
    @memcpy(id_buf[0..id_len], imdb_id[0..id_len]);

    var type_buf: [16]u8 = std.mem.zeroes([16]u8);
    const type_len = @min(media_type.len, 15);
    @memcpy(type_buf[0..type_len], media_type[0..type_len]);

    _ = std.Thread.spawn(.{}, struct {
        fn worker(id: [32]u8, idl: usize, mt: [16]u8, mtl: usize) void {
            defer stream_loading = false;

            const imdb = id[0..idl];
            const mtype = mt[0..mtl];

            for (0..installed_count) |ai| {
                if (stream_count >= 32) break;
                const addon = &installed_addons[ai];
                const base = addon.url[0..addon.url_len];

                // Stremio addon protocol: {base_url}/stream/{type}/{id}.json
                // Remove /manifest.json suffix to get base
                var base_url: [256]u8 = undefined;
                const blen = if (std.mem.indexOf(u8, base, "/manifest.json")) |mp|
                    @min(mp, 255)
                else
                    @min(base.len, 255);
                @memcpy(base_url[0..blen], base[0..blen]);

                var url_buf: [512]u8 = undefined;
                const url = std.fmt.bufPrint(&url_buf, "{s}/stream/{s}/{s}.json", .{
                    base_url[0..blen], mtype, imdb,
                }) catch continue;

                const argv = [_][]const u8{
                    "curl", "-sL", "--max-time", "10", url,
                };
                var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
                child.stdout_behavior = .Pipe;
                child.stderr_behavior = .Ignore;
                _ = child.spawn() catch continue;

                var resp_buf: [64 * 1024]u8 = undefined;
                const rn = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, &resp_buf) catch 0 else 0;
                _ = child.wait() catch {};

                if (rn < 10) continue;

                // Parse "streams":[{"title":"...","url":"..."},...]
                var pos: usize = 0;
                while (pos < rn and stream_count < 32) {
                    const url_key = "\"url\":\"";
                    const next = std.mem.indexOf(u8, resp_buf[pos..], url_key) orelse break;
                    const uabs = pos + next + url_key.len;
                    const ue = std.mem.indexOfScalar(u8, resp_buf[uabs..], '"') orelse break;

                    var sr = &streams[stream_count];
                    sr.* = std.mem.zeroes(StreamResult);

                    const slen = @min(ue, 511);
                    @memcpy(sr.url[0..slen], resp_buf[uabs .. uabs + slen]);
                    sr.url_len = slen;

                    // Try to get title (look backwards for "title":"...")
                    if (std.mem.lastIndexOf(u8, resp_buf[pos .. pos + next], "\"title\":\"")) |tp| {
                        const tabs = pos + tp + 9;
                        const tee = std.mem.indexOfScalar(u8, resp_buf[tabs..], '"') orelse 0;
                        const tlen = @min(tee, 127);
                        @memcpy(sr.title[0..tlen], resp_buf[tabs .. tabs + tlen]);
                        sr.title_len = tlen;
                    }

                    // Tag which addon this came from
                    const anlen = @min(addon.name_len, 31);
                    @memcpy(sr.addon_name[0..anlen], addon.name[0..anlen]);
                    sr.addon_name_len = anlen;

                    stream_count += 1;
                    pos = uabs + ue;
                }
            }

            if (stream_count > 0) {
                logs.pushLog("info", "stremio", "Streams found", false);
            } else {
                logs.pushLog("info", "stremio", "No streams found", false);
            }
        }
    }.worker, .{ id_buf, id_len, type_buf, type_len }) catch {};
}
