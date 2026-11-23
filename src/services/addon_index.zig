//! Community add-on index: browse, search, add, update and remove.
//!
//! Off by default: there is no built-in index URL; the user sets one. The
//! index only suggests repositories. Every path below goes through the
//! existing trust chain:
//!   add      -> addon_repositories.add   (pins the listed key; never replaces one)
//!   catalogs -> addon_repo_pure.verify   (Ed25519 over exact manifest bytes)
//!   install/update -> addon_repositories.install (verify + confirmation digest)
//!   executable trust -> the host's content-trust prompt; new bytes are a new
//!                       tree digest, so an update is never pre-approved.
const std = @import("std");
const db = @import("../core/household_db.zig");
const io = @import("../core/io_global.zig");
const alloc = @import("../core/alloc.zig").allocator;
const paths = @import("../core/paths.zig");
const pure = @import("addon_index_pure.zig");
const repo_pure = @import("addon_repo_pure.zig");
const repos = @import("addon_repositories.zig");
const wire = @import("remote_http.zig");

fn ensure() void {
    repos.ensure();
    db.exec("CREATE TABLE IF NOT EXISTS addon_index(slot INTEGER PRIMARY KEY CHECK(slot=1),url TEXT NOT NULL,public_key TEXT NOT NULL DEFAULT '',body TEXT NOT NULL DEFAULT '')");
    db.exec("CREATE TABLE IF NOT EXISTS addon_installs(addon_id TEXT PRIMARY KEY,repo_id TEXT NOT NULL,version TEXT NOT NULL)");
}

// ── Index configuration ────────────────────────────────────────────────

/// Set the index URL (and optional signing key). An empty URL turns the
/// index off and forgets the cached copy.
pub fn configure(url: []const u8, key: []const u8) !void {
    ensure();
    if (url.len == 0) {
        db.exec("DELETE FROM addon_index");
        return;
    }
    if (!repo_pure.validRepoUrl(url)) return error.InvalidIndexUrl;
    if (key.len > 0 and !pure.validKey(key)) return error.InvalidKey;
    const stmt = db.prepare("INSERT INTO addon_index(slot,url,public_key,body) VALUES(1,?1,?2,'') ON CONFLICT(slot) DO UPDATE SET url=excluded.url,public_key=excluded.public_key,body=''") orelse return error.Storage;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, url);
    db.bindText(stmt, 2, key);
    if (db.step(stmt) != db.c.SQLITE_DONE) return error.Storage;
}

const Config = struct {
    url: []u8,
    key: []u8,
    body: []u8,
    fn deinit(self: Config) void {
        alloc.free(self.url);
        alloc.free(self.key);
        alloc.free(self.body);
    }
};

fn loadConfig() !?Config {
    ensure();
    const stmt = db.prepare("SELECT url,public_key,body FROM addon_index WHERE slot=1") orelse return error.Storage;
    defer db.finalize(stmt);
    if (db.step(stmt) != db.c.SQLITE_ROW) return null;
    const url = try alloc.dupe(u8, db.columnText(stmt, 0) orelse "");
    errdefer alloc.free(url);
    const key = try alloc.dupe(u8, db.columnText(stmt, 1) orelse "");
    errdefer alloc.free(key);
    return .{ .url = url, .key = key, .body = try alloc.dupe(u8, db.columnText(stmt, 2) orelse "") };
}

/// Blocking: call from a worker or a request thread, never the draw thread.
pub fn refresh() !void {
    const cfg = (try loadConfig()) orelse return error.IndexOff;
    defer cfg.deinit();
    const buf = try alloc.alloc(u8, pure.MAX_INDEX_BYTES);
    defer alloc.free(buf);
    @import("../core/rate_limit.zig").acquireUrl(cfg.url, 1.0);
    const bytes = @import("reliable_fetch.zig").fetch(cfg.url, buf, .{ .timeout_secs = 15, .follow_redirects = false, .use_dpi_proxy = false }) orelse return error.FetchFailed;
    const parsed = try pure.parse(alloc, bytes, cfg.key);
    parsed.deinit();
    // Bound to the URL/key that was fetched, so a concurrent reconfigure wins.
    const stmt = db.prepare("UPDATE addon_index SET body=?1 WHERE slot=1 AND url=?2 AND public_key=?3") orelse return error.Storage;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, bytes);
    db.bindText(stmt, 2, cfg.url);
    db.bindText(stmt, 3, cfg.key);
    if (db.step(stmt) != db.c.SQLITE_DONE) return error.Storage;
}

/// Add one listed repository under its listed id, pinning its listed key.
/// `addon_repositories.add` refuses an id that already exists, so an index
/// can never swap the key of a repository the user already trusts.
pub fn addFromIndex(entry_id: []const u8) !void {
    const cfg = (try loadConfig()) orelse return error.IndexOff;
    defer cfg.deinit();
    if (cfg.body.len == 0) return error.IndexNotFetched;
    const parsed = try pure.parse(alloc, cfg.body, cfg.key);
    defer parsed.deinit();
    for (parsed.value.repositories) |e| {
        if (!std.mem.eql(u8, e.id, entry_id)) continue;
        var own_buf: [8]OwnRow = undefined;
        const own = try ownRepos(&own_buf);
        defer for (own) |r| r.deinit();
        var views: [8]pure.OwnRepo = undefined;
        for (own, 0..) |r, i| views[i] = r.view();
        return switch (pure.status(e, views[0..own.len])) {
            .available => repos.add(e.id, e.url, e.public_key),
            .added => error.AlreadyAdded,
            .conflict => error.KeyConflict,
        };
    }
    return error.NotFound;
}

const OwnRow = struct {
    id: []u8,
    url: []u8,
    key: []u8,
    envelope: []u8,
    fn deinit(self: OwnRow) void {
        alloc.free(self.id);
        alloc.free(self.url);
        alloc.free(self.key);
        alloc.free(self.envelope);
    }
    fn view(self: OwnRow) pure.OwnRepo {
        return .{ .id = self.id, .url = self.url, .public_key = self.key };
    }
};

/// The user's own repositories (at most 8, enforced by `addon_repositories.add`).
fn ownRepos(out: *[8]OwnRow) ![]OwnRow {
    ensure();
    const stmt = db.prepare("SELECT id,url,public_key,envelope FROM addon_repositories ORDER BY id LIMIT 8") orelse return error.Storage;
    defer db.finalize(stmt);
    var n: usize = 0;
    errdefer for (out[0..n]) |r| r.deinit();
    while (n < out.len and db.step(stmt) == db.c.SQLITE_ROW) {
        const id = try alloc.dupe(u8, db.columnText(stmt, 0) orelse "");
        errdefer alloc.free(id);
        const url = try alloc.dupe(u8, db.columnText(stmt, 1) orelse "");
        errdefer alloc.free(url);
        const key = try alloc.dupe(u8, db.columnText(stmt, 2) orelse "");
        errdefer alloc.free(key);
        out[n] = .{ .id = id, .url = url, .key = key, .envelope = try alloc.dupe(u8, db.columnText(stmt, 3) orelse "") };
        n += 1;
    }
    return out[0..n];
}

// ── Install provenance ─────────────────────────────────────────────────

/// Called by `addon_repositories.install` after the files are published.
pub fn recordInstall(repo_id: []const u8, addon_id: []const u8, version: []const u8) void {
    ensure();
    const stmt = db.prepare("INSERT INTO addon_installs(addon_id,repo_id,version) VALUES(?1,?2,?3) ON CONFLICT(addon_id) DO UPDATE SET repo_id=excluded.repo_id,version=excluded.version") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, addon_id);
    db.bindText(stmt, 2, repo_id);
    db.bindText(stmt, 3, version);
    _ = db.step(stmt);
}

const Installed = struct { repo: []const u8, version: []const u8 };

fn installed(addon_id: []const u8, repo_buf: *[64]u8, version_buf: *[64]u8) ?Installed {
    ensure();
    const stmt = db.prepare("SELECT repo_id,version FROM addon_installs WHERE addon_id=?1") orelse return null;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, addon_id);
    if (db.step(stmt) != db.c.SQLITE_ROW) return null;
    const repo = db.columnText(stmt, 0) orelse "";
    const version = db.columnText(stmt, 1) orelse "";
    if (repo.len > repo_buf.len or version.len > version_buf.len) return null;
    @memcpy(repo_buf[0..repo.len], repo);
    @memcpy(version_buf[0..version.len], version);
    return .{ .repo = repo_buf[0..repo.len], .version = version_buf[0..version.len] };
}

fn pluginDir(addon_id: []const u8, out: []u8) ![]const u8 {
    if (!repo_pure.validId(addon_id)) return error.InvalidAddon;
    var cfg_buf: [512]u8 = undefined;
    return std.fmt.bufPrint(out, "{s}/plugins/{s}", .{ paths.configDir(&cfg_buf), addon_id });
}

/// Replace an installed add-on with a newer signed version from the same
/// repository. Revokes the old approval first; the new bytes have a new tree
/// digest and wait for the host's approval like any fresh install.
pub fn update(repo_id: []const u8, addon_id: []const u8, confirmation: []const u8) !void {
    var rb: [64]u8 = undefined;
    var vb: [64]u8 = undefined;
    const rec = installed(addon_id, &rb, &vb) orelse return error.NotInstalled;
    if (!std.mem.eql(u8, rec.repo, repo_id)) return error.RepositoryMismatch;
    var ab: [64]u8 = undefined;
    const available = try catalogVersion(repo_id, addon_id, &ab);
    if (!pure.updateAvailable(rec.version, available)) return error.UpToDate;

    var dir_buf: [700]u8 = undefined;
    const dir = try pluginDir(addon_id, &dir_buf);
    var cfg_buf: [512]u8 = undefined;
    var stash_root_buf: [600]u8 = undefined;
    // Outside `<config>/plugins` so the scanner never sees the old copy.
    const stash_root = try std.fmt.bufPrint(&stash_root_buf, "{s}/plugin-updates", .{paths.configDir(&cfg_buf)});
    try io.cwdMakePath(stash_root);
    var stash_buf: [700]u8 = undefined;
    const stash = try std.fmt.bufPrint(&stash_buf, "{s}/{s}", .{ stash_root, addon_id });
    io.cwdDeleteTree(stash) catch {};

    _ = @import("plugins.zig").setContentTrust(addon_id, false);
    try io.renameAbsolute(dir, stash);
    repos.install(repo_id, addon_id, confirmation) catch |err| {
        io.cwdDeleteTree(dir) catch {};
        io.renameAbsolute(stash, dir) catch {};
        return err;
    };
    io.cwdDeleteTree(stash) catch {};
}

/// Remove an add-on that was installed from a signed repository. Add-ons the
/// user created by hand are not touched by this path.
pub fn uninstall(addon_id: []const u8) !void {
    var dir_buf: [700]u8 = undefined;
    const dir = try pluginDir(addon_id, &dir_buf);
    var rb: [64]u8 = undefined;
    var vb: [64]u8 = undefined;
    _ = installed(addon_id, &rb, &vb) orelse return error.NotInstalled;
    _ = @import("plugins.zig").setContentTrust(addon_id, false);
    // deleteTree treats an already-missing directory as success.
    try io.cwdDeleteTree(dir);
    const stmt = db.prepare("DELETE FROM addon_installs WHERE addon_id=?1") orelse return error.Storage;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, addon_id);
    if (db.step(stmt) != db.c.SQLITE_DONE) return error.Storage;
}

/// Version of `addon_id` in the repository's verified catalog.
fn catalogVersion(repo_id: []const u8, addon_id: []const u8, out: *[64]u8) ![]const u8 {
    var own_buf: [8]OwnRow = undefined;
    const own = try ownRepos(&own_buf);
    defer for (own) |r| r.deinit();
    for (own) |r| {
        if (!std.mem.eql(u8, r.id, repo_id)) continue;
        const verified = try repo_pure.verify(alloc, r.envelope, r.key);
        defer verified.deinit();
        for (verified.catalog.value.addons) |addon| {
            if (!std.mem.eql(u8, addon.id, addon_id)) continue;
            if (addon.version.len > out.len) return error.InvalidAddon;
            @memcpy(out[0..addon.version.len], addon.version);
            return out[0..addon.version.len];
        }
        return error.NotFound;
    }
    return error.NotFound;
}

// ── Snapshot (host UI and web) ─────────────────────────────────────────

/// `{"index":{...},"entries":[...],"addons":[...]}`. Entries and add-ons are
/// ranked by `query`. Script contents never leave the host.
pub fn writeSnapshot(w: *std.Io.Writer, query: []const u8) !void {
    var own_buf: [8]OwnRow = undefined;
    const own = try ownRepos(&own_buf);
    defer for (own) |r| r.deinit();
    var views: [8]pure.OwnRepo = undefined;
    for (own, 0..) |r, i| views[i] = r.view();

    const cfg = try loadConfig();
    defer if (cfg) |c| c.deinit();
    try w.writeAll("{\"index\":");
    var parsed: ?std.json.Parsed(pure.Index) = null;
    defer if (parsed) |p| p.deinit();
    var index_error: []const u8 = "";
    if (cfg) |c| {
        if (c.body.len > 0) {
            if (pure.parse(alloc, c.body, c.key)) |p| parsed = p else |err| index_error = @errorName(err);
        }
        try std.json.Stringify.value(.{ .enabled = true, .url = c.url, .public_key = c.key, .fetched = c.body.len > 0, .@"error" = index_error }, .{}, w);
    } else try w.writeAll("{\"enabled\":false,\"url\":\"\",\"public_key\":\"\",\"fetched\":false,\"error\":\"\"}");

    try w.writeAll(",\"entries\":[");
    if (parsed) |p| {
        var cands: [pure.MAX_ENTRIES]pure.Candidate = undefined;
        const entries = p.value.repositories;
        for (entries, 0..) |e, i| cands[i] = .{ .name = e.name, .id = e.id, .description = e.description, .tags = e.tags };
        var order: [pure.MAX_ENTRIES]usize = undefined;
        const n = pure.rank(cands[0..entries.len], query, &order);
        for (order[0..n], 0..) |idx, k| {
            if (k > 0) try w.writeByte(',');
            const e = entries[idx];
            try std.json.Stringify.value(.{ .id = e.id, .name = e.name, .url = e.url, .public_key = e.public_key, .description = e.description, .tags = e.tags, .status = @tagName(pure.status(e, views[0..own.len])) }, .{}, w);
        }
    }
    try w.writeAll("],\"addons\":[");
    try writeAddons(w, own, query);
    try w.writeAll("]}");
}

const max_addons = 8 * 32;

fn writeAddons(w: *std.Io.Writer, own: []const OwnRow, query: []const u8) !void {
    var verified: [8]?repo_pure.Verified = @splat(null);
    defer for (verified) |v| if (v) |x| x.deinit();
    const Ref = struct { repo: usize, addon: usize };
    var refs: [max_addons]Ref = undefined;
    var cands: [max_addons]pure.Candidate = undefined;
    var n: usize = 0;
    for (own, 0..) |r, ri| {
        verified[ri] = repo_pure.verify(alloc, r.envelope, r.key) catch continue;
        for (verified[ri].?.catalog.value.addons, 0..) |addon, ai| {
            if (n >= max_addons) break;
            refs[n] = .{ .repo = ri, .addon = ai };
            cands[n] = .{ .name = addon.name, .id = addon.id };
            n += 1;
        }
    }
    var order: [max_addons]usize = undefined;
    const m = pure.rank(cands[0..n], query, &order);
    for (order[0..m], 0..) |idx, k| {
        if (k > 0) try w.writeByte(',');
        const ref = refs[idx];
        const v = verified[ref.repo].?;
        const addon = v.catalog.value.addons[ref.addon];
        const hash = repos.digest(v.envelope.value.manifest);
        var rb: [64]u8 = undefined;
        var vb: [64]u8 = undefined;
        const rec = installed(addon.id, &rb, &vb);
        const from_here = if (rec) |r| std.mem.eql(u8, r.repo, own[ref.repo].id) else false;
        try std.json.Stringify.value(.{
            .repo = own[ref.repo].id,
            .confirmation = hash[0..],
            .id = addon.id,
            .name = addon.name,
            .version = addon.version,
            .permissions = addon.permissions,
            .installed = if (rec) |r| r.version else null,
            .installed_from = if (rec) |r| r.repo else null,
            .update = from_here and pure.updateAvailable(rec.?.version, addon.version),
        }, .{}, w);
    }
}

// ── HTTP routes (authorization is decided first by access_pure) ────────

pub fn handle(stream: std.Io.net.Stream, method: []const u8, path: []const u8, query: []const u8, body: []const u8) bool {
    const routes = [_][]const u8{ "/addons/index", "/addons/index/config", "/addons/index/refresh", "/addons/index/add", "/addons/update", "/addons/uninstall" };
    var known = false;
    for (routes) |r| known = known or std.mem.eql(u8, path, r);
    if (!known) return false;
    if (std.mem.eql(u8, path, "/addons/index")) {
        if (!wire.requireMethod(stream, method, "GET")) return true;
        var q_buf: [128]u8 = undefined;
        const q = wire.formParam("", query, "q", &q_buf) orelse "";
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        writeSnapshot(&out.writer, q) catch {
            wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"index storage unavailable\"}");
            return true;
        };
        wire.sendJson(stream, out.written());
        return true;
    }
    if (!wire.requireMethod(stream, method, "POST")) return true;
    var id_buf: [64]u8 = undefined;
    var url_buf: [1100]u8 = undefined;
    var key_buf: [140]u8 = undefined;
    var addon_buf: [64]u8 = undefined;
    var confirm_buf: [80]u8 = undefined;
    const p = struct {
        fn get(b: []const u8, q: []const u8, k: []const u8, buf: []u8) []const u8 {
            return wire.formParam(b, q, k, buf) orelse "";
        }
    }.get;
    const result: anyerror!void = if (std.mem.eql(u8, path, "/addons/index/config"))
        configure(p(body, query, "url", &url_buf), p(body, query, "public_key", &key_buf))
    else if (std.mem.eql(u8, path, "/addons/index/refresh"))
        refresh()
    else if (std.mem.eql(u8, path, "/addons/index/add"))
        addFromIndex(p(body, query, "id", &id_buf))
    else if (std.mem.eql(u8, path, "/addons/update"))
        update(p(body, query, "id", &id_buf), p(body, query, "addon", &addon_buf), p(body, query, "confirmation", &confirm_buf))
    else
        uninstall(p(body, query, "addon", &addon_buf));
    result catch |err| {
        var buf: [160]u8 = undefined;
        wire.sendJsonStatus(stream, "400 Bad Request", std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch "{\"error\":\"index operation failed\"}");
        return true;
    };
    wire.sendJson(stream, "{\"ok\":true}");
    return true;
}
