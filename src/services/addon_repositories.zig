//! User-configured, key-pinned signed add-on repositories. No built-in URLs.
const std = @import("std");
const db = @import("../core/household_db.zig");
const io = @import("../core/io_global.zig");
const alloc = @import("../core/alloc.zig").allocator;
const paths = @import("../core/paths.zig");
const pure = @import("addon_repo_pure.zig");
const wire = @import("remote_http.zig");

fn ensure() void {
    db.exec("CREATE TABLE IF NOT EXISTS addon_repositories(id TEXT PRIMARY KEY,url TEXT NOT NULL,public_key TEXT NOT NULL,envelope TEXT NOT NULL DEFAULT '')");
}

pub fn add(id: []const u8, url: []const u8, key: []const u8) !void {
    if (!pure.validId(id) or !pure.validRepoUrl(url) or key.len != 64) return error.InvalidRepository;
    var decoded: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&decoded, key) catch return error.InvalidKey;
    _ = std.crypto.sign.Ed25519.PublicKey.fromBytes(decoded) catch return error.InvalidKey;
    ensure();
    const stmt = db.prepare("INSERT INTO addon_repositories(id,url,public_key) SELECT ?1,?2,?3 WHERE (SELECT count(*) FROM addon_repositories)<8") orelse return error.Storage;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, id);
    db.bindText(stmt, 2, url);
    db.bindText(stmt, 3, key);
    if (db.step(stmt) != db.c.SQLITE_DONE) return error.Exists;
    if (db.c.sqlite3_changes(db.c.sqlite3_db_handle(stmt)) != 1) return error.Full;
}

pub fn remove(id: []const u8) !void {
    ensure();
    const stmt = db.prepare("DELETE FROM addon_repositories WHERE id=?1") orelse return error.Storage;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, id);
    if (db.step(stmt) != db.c.SQLITE_DONE) return error.Storage;
}

const Repository = struct {
    url: []u8,
    key: []u8,
    envelope: []u8,
    fn deinit(self: Repository) void {
        alloc.free(self.url);
        alloc.free(self.key);
        alloc.free(self.envelope);
    }
};
fn get(id: []const u8) !Repository {
    ensure();
    const stmt = db.prepare("SELECT url,public_key,envelope FROM addon_repositories WHERE id=?1") orelse return error.Storage;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, id);
    if (db.step(stmt) != db.c.SQLITE_ROW) return error.NotFound;
    const url = try alloc.dupe(u8, db.columnText(stmt, 0) orelse "");
    errdefer alloc.free(url);
    const key = try alloc.dupe(u8, db.columnText(stmt, 1) orelse "");
    errdefer alloc.free(key);
    return .{ .url = url, .key = key, .envelope = try alloc.dupe(u8, db.columnText(stmt, 2) orelse "") };
}

/// Blocking work belongs on a request/owned worker, never the draw thread.
pub fn refresh(id: []const u8) !void {
    const repo = try get(id);
    defer repo.deinit();
    const buf = try alloc.alloc(u8, pure.MAX_BYTES);
    defer alloc.free(buf);
    const bytes = @import("reliable_fetch.zig").fetch(repo.url, buf, .{ .timeout_secs = 15, .follow_redirects = false, .use_dpi_proxy = false }) orelse return error.FetchFailed;
    const verified = try pure.verify(alloc, bytes, repo.key);
    defer verified.deinit();
    const stmt = db.prepare("UPDATE addon_repositories SET envelope=?1 WHERE id=?2 AND url=?3 AND public_key=?4") orelse return error.Storage;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, bytes);
    db.bindText(stmt, 2, id);
    db.bindText(stmt, 3, repo.url);
    db.bindText(stmt, 4, repo.key);
    if (db.step(stmt) != db.c.SQLITE_DONE) return error.Storage;
}

pub fn digest(manifest: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(manifest, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}

/// Requires machine authority at the route gate or an explicit host UI action.
/// `confirmation` binds approval to exactly the previewed manifest revision.
/// Installation never grants executable trust; the existing host prompt does.
pub fn install(repo_id: []const u8, addon_id: []const u8, confirmation: []const u8) !void {
    const repo = try get(repo_id);
    defer repo.deinit();
    const verified = try pure.verify(alloc, repo.envelope, repo.key);
    defer verified.deinit();
    const expected = digest(verified.envelope.value.manifest);
    if (!std.mem.eql(u8, confirmation, &expected)) return error.ConfirmationChanged;
    for (verified.catalog.value.addons) |addon| {
        if (!std.mem.eql(u8, addon.id, addon_id)) continue;
        var cfg_buf: [512]u8 = undefined;
        var root_buf: [600]u8 = undefined;
        const root = try std.fmt.bufPrint(&root_buf, "{s}/plugins", .{paths.configDir(&cfg_buf)});
        try io.cwdMakePath(root);
        var dir_buf: [700]u8 = undefined;
        const dir = try std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ root, addon.id });
        // Exclusive directory creation rejects existing installs and symlinks.
        try std.Io.Dir.createDirAbsolute(io.io(), dir, if (@import("builtin").os.tag == .windows) .default_dir else .fromMode(0o700));
        errdefer io.cwdDeleteTree(dir) catch {};
        var file_buf: [800]u8 = undefined;
        for (addon.files) |file| {
            if (std.mem.eql(u8, file.name, "manifest.json")) continue;
            try writeFile(try std.fmt.bufPrint(&file_buf, "{s}/{s}", .{ dir, file.name }), file.content);
        }
        if (addon.panel) |panel| {
            const bytes = try std.json.Stringify.valueAlloc(alloc, panel, .{});
            defer alloc.free(bytes);
            try writeFile(try std.fmt.bufPrint(&file_buf, "{s}/panel.json", .{dir}), bytes);
        }
        // Publish manifest last: scanners cannot observe a partial executable.
        for (addon.files) |file| if (std.mem.eql(u8, file.name, "manifest.json")) {
            try writeFile(try std.fmt.bufPrint(&file_buf, "{s}/manifest.json", .{dir}), file.content);
        };
        return;
    }
    return error.NotFound;
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    const file = try io.createFileAbsolute(path, .{ .exclusive = true, .permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o600) });
    defer file.close(io.io());
    try io.writeAll(file, bytes);
}

pub fn writeSnapshot(w: *std.Io.Writer) !void {
    ensure();
    const stmt = db.prepare("SELECT id,url,public_key,envelope FROM addon_repositories ORDER BY id") orelse return error.Storage;
    defer db.finalize(stmt);
    try w.writeAll("{\"repositories\":[");
    var first = true;
    while (db.step(stmt) == db.c.SQLITE_ROW) {
        if (!first) try w.writeByte(',');
        first = false;
        const key = db.columnText(stmt, 2) orelse "";
        const envelope = db.columnText(stmt, 3) orelse "";
        try w.writeAll("{\"id\":");
        try std.json.Stringify.value(db.columnText(stmt, 0) orelse "", .{}, w);
        try w.writeAll(",\"url\":");
        try std.json.Stringify.value(db.columnText(stmt, 1) orelse "", .{}, w);
        try w.writeAll(",\"public_key\":");
        try std.json.Stringify.value(key, .{}, w);
        if (pure.verify(alloc, envelope, key)) |verified| {
            defer verified.deinit();
            const hash = digest(verified.envelope.value.manifest);
            try w.writeAll(",\"confirmation\":");
            try std.json.Stringify.value(hash[0..], .{}, w);
            try w.writeAll(",\"addons\":[");
            for (verified.catalog.value.addons, 0..) |addon, i| {
                if (i > 0) try w.writeByte(',');
                // Script contents stay off the browser wire.
                try std.json.Stringify.value(.{ .id = addon.id, .name = addon.name, .version = addon.version, .permissions = addon.permissions, .panel = addon.panel }, .{}, w);
            }
            try w.writeByte(']');
        } else |_| try w.writeAll(",\"addons\":[]");
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

pub fn handle(stream: std.Io.net.Stream, method: []const u8, path: []const u8, query: []const u8, body: []const u8) bool {
    if (!std.mem.eql(u8, path, "/addons") and !std.mem.startsWith(u8, path, "/addons/")) return false;
    if (std.mem.eql(u8, path, "/addons")) {
        if (!wire.requireMethod(stream, method, "GET")) return true;
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        writeSnapshot(&out.writer) catch {
            wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"repository storage unavailable\"}");
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
    const id = wire.formParam(body, query, "id", &id_buf) orelse "";
    const result: anyerror!void = if (std.mem.eql(u8, path, "/addons/add"))
        add(id, wire.formParam(body, query, "url", &url_buf) orelse "", wire.formParam(body, query, "public_key", &key_buf) orelse "")
    else if (std.mem.eql(u8, path, "/addons/refresh")) refresh(id) else if (std.mem.eql(u8, path, "/addons/remove")) remove(id) else if (std.mem.eql(u8, path, "/addons/install")) install(id, wire.formParam(body, query, "addon", &addon_buf) orelse "", wire.formParam(body, query, "confirmation", &confirm_buf) orelse "") else error.UnknownAction;
    result catch |err| {
        var buf: [160]u8 = undefined;
        wire.sendJsonStatus(stream, "400 Bad Request", std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch "{\"error\":\"repository operation failed\"}");
        return true;
    };
    wire.sendJson(stream, "{\"ok\":true}");
    return true;
}
