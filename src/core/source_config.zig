//! Installed source endpoints / credentials.
//!
//! Opal holds the connector CODE; the actual source URLs + API keys are migrated
//! to the `opal-plugins` repo and written here by the in-app plugin manager when
//! the user installs a source. No file / no entry for a source → that source is
//! INERT (its code looks up its endpoint, gets null, and skips). Nothing
//! infringing is hardcoded in the running binary.
//!
//! On-disk format: a single JSON object at `~/.config/zigzag/plugins/sources.json`
//! keyed by source id, each value a flat string map of named endpoints/creds, e.g.
//!   { "1337x": { "base": "https://1337x.to" },
//!     "yts":   { "api":  "https://yts.mx/api/v2/list_movies.json" } }

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

/// Absolute path of the installed-sources file.
pub fn filePath(buf: []u8) []const u8 {
    var cfg_buf: [512]u8 = undefined;
    const cfg = paths.configDir(&cfg_buf);
    return std.fmt.bufPrint(buf, "{s}/plugins/sources.json", .{cfg}) catch cfg;
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

    var path_buf: [600]u8 = undefined;
    const fpath = filePath(&path_buf);
    const body = io.cwdReadFileAlloc(fpath, alloc, 256 * 1024) catch return;
    defer alloc.free(body);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;

    var it = parsed.value.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* != .object) continue;
        var fit = kv.value_ptr.*.object.iterator();
        while (fit.next()) |fkv| {
            if (fkv.value_ptr.* == .string) {
                putEntry(kv.key_ptr.*, fkv.key_ptr.*, fkv.value_ptr.*.string);
            }
        }
    }
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

/// True if any endpoint is installed for `id`.
pub fn has(id: []const u8) bool {
    mutex.lock();
    defer mutex.unlock();
    for (entries[0..entry_count]) |*e| {
        if (std.mem.eql(u8, e.id[0..e.id_len], id)) return true;
    }
    return false;
}
