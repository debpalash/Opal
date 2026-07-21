//! Installed source endpoints / credentials.
//!
//! Opal holds the connector CODE; the actual source URLs + API keys are migrated
//! to the `opal-plugins` repo and written here by the in-app plugin manager when
//! the user installs a source. No file / no entry for a source → that source is
//! INERT (its code looks up its endpoint, gets null, and skips). Nothing
//! infringing is hardcoded in the running binary.
//!
//! On-disk format: one file per installed source under
//! `~/.config/opal/plugins/sources/<id>.json`, each a flat JSON string map of
//! named endpoints/creds (id = filename stem). e.g. `sources/1337x.json`:
//!   { "base": "https://1337x.to" }
//! Install = write the file; uninstall = delete it (the plugin manager does this).

const std = @import("std");
const paths = @import("paths.zig");
const io = @import("io_global.zig");
const alloc = @import("alloc.zig").allocator;

const MAX_ENTRIES = 64;

const Entry = struct {
    id: [32]u8 = std.mem.zeroes([32]u8),
    id_len: usize = 0,
    field: [24]u8 = std.mem.zeroes([24]u8),
    field_len: usize = 0,
    val: [512]u8 = std.mem.zeroes([512]u8),
    val_len: usize = 0,
};

var entries: [MAX_ENTRIES]Entry = undefined;
var entry_count: usize = 0;
var mutex: @import("sync.zig").Mutex = .{};

/// Absolute path of the installed-sources directory.
pub fn sourcesDir(buf: []u8) []const u8 {
    var cfg_buf: [512]u8 = undefined;
    const cfg = paths.configDir(&cfg_buf);
    return std.fmt.bufPrint(buf, "{s}/plugins/sources", .{cfg}) catch cfg;
}

fn putEntry(id: []const u8, field: []const u8, val: []const u8) void {
    if (entry_count >= MAX_ENTRIES) return;
    if (id.len == 0 or id.len > 32 or field.len == 0 or field.len > 24) return;
    if (val.len == 0 or val.len > 512) return;
    var e = &entries[entry_count];
    @memcpy(e.id[0..id.len], id);
    e.id_len = id.len;
    @memcpy(e.field[0..field.len], field);
    e.field_len = field.len;
    @memcpy(e.val[0..val.len], val);
    e.val_len = val.len;
    entry_count += 1;
}

/// (Re)load installed source endpoints from disk. Call once at startup and again
/// after the plugin manager installs/uninstalls a source. Missing file → 0 entries.
pub fn reload() void {
    mutex.lock();
    defer mutex.unlock();
    entry_count = 0;

    var dir_buf: [600]u8 = undefined;
    const dir_path = sourcesDir(&dir_buf);
    var dir = io.cwdOpenDir(dir_path, .{ .iterate = true }) catch return; // missing → all inert
    defer dir.close(io.io());

    var it = dir.iterate();
    while (it.next(io.io()) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const id = entry.name[0 .. entry.name.len - 5]; // strip ".json"
        if (id.len == 0 or id.len > 32) continue;

        var fp_buf: [700]u8 = undefined;
        const fp = std.fmt.bufPrint(&fp_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        const body = io.cwdReadFileAlloc(fp, alloc, 64 * 1024) catch continue;
        defer alloc.free(body);

        var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;

        var fit = parsed.value.object.iterator();
        while (fit.next()) |fkv| {
            if (fkv.value_ptr.* == .string) {
                putEntry(id, fkv.key_ptr.*, fkv.value_ptr.*.string);
            }
        }
    }
}

/// Install (or overwrite) a source by writing its flat JSON string map to
/// `~/.config/opal/plugins/sources/<id>.json`, then reload() so its endpoint is
/// live immediately. `json_fields` must be a complete JSON object body, e.g.
/// `{"base":"https://example.org"}`. Returns false on a bad id or a write error.
/// Used by the browser extension's /api/source/add ("Add this site as an Opal
/// source"): the site the user is browsing becomes a real, searchable source in
/// one click — matching Opal's source-neutral, source_config-driven design.
pub fn install(id: []const u8, json_fields: []const u8) bool {
    if (id.len == 0 or id.len > 32) return false;
    // Reject path separators / traversal in the id — it's used as a filename.
    for (id) |ch| {
        if (ch == '/' or ch == '\\' or ch == '.' or ch == 0) return false;
    }
    var dir_buf: [600]u8 = undefined;
    const dir_path = sourcesDir(&dir_buf);
    io.cwdMakePath(dir_path) catch {};

    var fp_buf: [700]u8 = undefined;
    const fp = std.fmt.bufPrint(&fp_buf, "{s}/{s}.json", .{ dir_path, id }) catch return false;
    io.cwdWriteFile(.{ .sub_path = fp, .data = json_fields }) catch return false;
    reload();
    return true;
}

/// Endpoint URL / credential for `id`.`field`, or null when no plugin has supplied
/// it (→ the source stays inert). The returned slice points into a static table;
/// copy it (e.g. into a bufPrint) before the next reload().
pub fn get(id: []const u8, field: []const u8) ?[]const u8 {
    mutex.lock();
    defer mutex.unlock();
    for (entries[0..entry_count]) |*e| {
        if (std.mem.eql(u8, e.id[0..e.id_len], id) and
            std.mem.eql(u8, e.field[0..e.field_len], field))
        {
            return e.val[0..e.val_len];
        }
    }
    return null;
}

/// True if ANY source plugin is installed at all. False is the fresh-install /
/// post-reset state (Opal ships neutral): every torrent/comics/anime engine is
/// inert, so searches "run" but can't return source hits — surface that in the
/// search UI instead of a bare "No hits" (see search.zig renderSourceStatusLine).
pub fn anyInstalled() bool {
    mutex.lock();
    defer mutex.unlock();
    return entry_count > 0;
}

/// Uninstall a source by id: delete its `<id>.json` and reload so it goes inert
/// immediately. Mirrors plugin_repo.uninstall but keyed by id, for callers (the
/// Live TV settings page) that toggle a source without a plugin-list index.
/// Rejects the same unsafe ids as install(). No-op if the file is absent.
pub fn uninstallById(id: []const u8) void {
    if (id.len == 0 or id.len > 32) return;
    for (id) |ch| {
        if (ch == '/' or ch == '\\' or ch == '.' or ch == 0) return;
    }
    var dir_buf: [600]u8 = undefined;
    const dir_path = sourcesDir(&dir_buf);
    var fp_buf: [700]u8 = undefined;
    const fp = std.fmt.bufPrint(&fp_buf, "{s}/{s}.json", .{ dir_path, id }) catch return;
    io.cwdDeleteFile(fp) catch {};
    reload();
}

/// True if any endpoint is installed for `id`.
pub fn has(id: []const u8) bool {
    mutex.lock();
    defer mutex.unlock();
    for (entries[0..entry_count]) |*e| {
        if (std.mem.eql(u8, e.id[0..e.id_len], id)) return true;
    }
    return false;
}
