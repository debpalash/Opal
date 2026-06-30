//! Source-endpoint plugin manager (qBittorrent-style). Fetches a manifest from
//! the `opal-plugins` repo and Installs/Uninstalls *endpoints* for Opal's built-in
//! connectors. Installing writes `~/.config/zigzag/plugins/sources/<id>.json`
//! (read by core/source_config); the app holds the connector CODE, the plugin
//! supplies only the URL/creds. Nothing is active until the user installs it.
//!
//! Distinct from services/plugins.zig (which runs external executable plugins).

const std = @import("std");
const paths = @import("../core/paths.zig");
const io = @import("../core/io_global.zig");
const alloc = @import("../core/alloc.zig").allocator;
const source_config = @import("../core/source_config.zig");
const logs = @import("../core/logs.zig");
const state = @import("../core/state.zig");

pub const MAX = 32;

pub const Plugin = struct {
    id: [32]u8 = std.mem.zeroes([32]u8),
    id_len: usize = 0,
    name: [48]u8 = std.mem.zeroes([48]u8),
    name_len: usize = 0,
    kind: [16]u8 = std.mem.zeroes([16]u8),
    kind_len: usize = 0,
    version: [16]u8 = std.mem.zeroes([16]u8),
    version_len: usize = 0,
    // The endpoints object, serialized verbatim ({"base":"…"}) — written on install.
    endpoints: [512]u8 = std.mem.zeroes([512]u8),
    endpoints_len: usize = 0,

    pub fn idSlice(self: *const Plugin) []const u8 {
        return self.id[0..self.id_len];
    }
    pub fn nameSlice(self: *const Plugin) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn kindSlice(self: *const Plugin) []const u8 {
        return self.kind[0..self.kind_len];
    }
};

pub const Status = enum(u8) { idle, fetching, ok, err };
pub var status: std.atomic.Value(Status) = std.atomic.Value(Status).init(.idle);
pub var status_msg: [128]u8 = std.mem.zeroes([128]u8);
pub var status_msg_len: usize = 0;

pub var plugins: [MAX]Plugin = undefined;
pub var plugin_count: usize = 0;

// User-editable in the Plugins UI. `repo` is "owner/name"; `token` is a GitHub PAT
// (needed only for a private repo).
pub var repo_buf: [128]u8 = std.mem.zeroes([128]u8);
pub var repo_len: usize = 0;
pub var token_buf: [256]u8 = std.mem.zeroes([256]u8);
pub var token_len: usize = 0;

fn setMsg(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&status_msg, fmt, args) catch status_msg[0..0];
    status_msg_len = s.len;
}

pub fn repo() []const u8 {
    return if (repo_len > 0) repo_buf[0..repo_len] else "debpalash/opal-plugins";
}

fn tokenPath(buf: []u8) []const u8 {
    var cfg: [512]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/plugins/gh_token", .{paths.configDir(&cfg)}) catch "";
}

/// Load the persisted GitHub token (if any). Call at startup.
pub fn init() void {
    var pb: [600]u8 = undefined;
    const tp = tokenPath(&pb);
    const body = io.cwdReadFileAlloc(tp, alloc, 4096) catch return;
    defer alloc.free(body);
    const t = std.mem.trim(u8, body, " \r\n\t");
    if (t.len > 0 and t.len <= token_buf.len) {
        @memcpy(token_buf[0..t.len], t);
        token_len = t.len;
    }
}

/// Persist the token entered in the UI.
pub fn saveToken() void {
    var cfg: [512]u8 = undefined;
    var dir_buf: [600]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buf, "{s}/plugins", .{paths.configDir(&cfg)}) catch return;
    io.cwdMakePath(dir) catch {};
    var pb: [600]u8 = undefined;
    const tp = tokenPath(&pb);
    io.cwdWriteFile(.{ .sub_path = tp, .data = token_buf[0..token_len] }) catch {};
}

// ── Fetch manifest ───────────────────────────────────────────────────────────

pub fn refresh() void {
    if (status.load(.acquire) == .fetching) return;
    status.store(.fetching, .release);
    setMsg("Fetching…", .{});
    const t = std.Thread.spawn(.{}, refreshWorker, .{}) catch {
        fail("spawn failed");
        return;
    };
    t.detach();
}

fn fail(comptime msg: []const u8) void {
    status.store(.err, .release);
    setMsg(msg, .{});
}

fn refreshWorker() void {
    var url_buf: [256]u8 = undefined;
    // Private-repo-friendly: the GitHub contents API returns the raw file with a PAT.
    const url = std.fmt.bufPrint(&url_buf, "https://api.github.com/repos/{s}/contents/manifest.json", .{repo()}) catch {
        fail("bad repo");
        return;
    };

    var auth_buf: [320]u8 = undefined;
    const have_token = token_len > 0;
    const auth = if (have_token)
        (std.fmt.bufPrint(&auth_buf, "Authorization: Bearer {s}", .{token_buf[0..token_len]}) catch {
            fail("token");
            return;
        })
    else
        "";

    var child = if (have_token)
        io.Child.init(&.{ "curl", "-sL", "-H", "Accept: application/vnd.github.raw", "-H", "User-Agent: Opal", "-H", auth, "--max-time", "15", url }, alloc)
    else
        io.Child.init(&.{ "curl", "-sL", "-H", "Accept: application/vnd.github.raw", "-H", "User-Agent: Opal", "--max-time", "15", url }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        fail("curl failed");
        return;
    };
    const buf = alloc.alloc(u8, 256 * 1024) catch {
        _ = child.wait() catch {};
        fail("oom");
        return;
    };
    defer alloc.free(buf);
    const n = if (child.stdout) |*so| io.readAll(so, buf) catch 0 else 0;
    _ = child.wait() catch {};
    if (n == 0) {
        fail("empty (check repo/token)");
        return;
    }
    parseManifest(buf[0..n]);
}

fn copyField(dst: []u8, dst_len: *usize, v: ?std.json.Value) void {
    dst_len.* = 0;
    if (v) |val| if (val == .string) {
        const s = val.string;
        const c = @min(s.len, dst.len);
        @memcpy(dst[0..c], s[0..c]);
        dst_len.* = c;
    };
}

fn parseManifest(body: []const u8) void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        fail("not JSON (check repo/token)");
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        fail("bad manifest");
        return;
    }
    const arr_v = parsed.value.object.get("plugins") orelse {
        fail("no plugins[]");
        return;
    };
    if (arr_v != .array) {
        fail("bad plugins[]");
        return;
    }

    plugin_count = 0;
    for (arr_v.array.items) |p| {
        if (plugin_count >= MAX or p != .object) continue;
        var pl = Plugin{};
        copyField(&pl.id, &pl.id_len, p.object.get("id"));
        copyField(&pl.name, &pl.name_len, p.object.get("name"));
        copyField(&pl.kind, &pl.kind_len, p.object.get("type"));
        copyField(&pl.version, &pl.version_len, p.object.get("version"));
        if (pl.id_len == 0) continue;

        // Serialize the endpoints object verbatim for writing on install.
        if (p.object.get("endpoints")) |ep| if (ep == .object) {
            var w: usize = 0;
            const out = &pl.endpoints;
            if (w < out.len) {
                out[w] = '{';
                w += 1;
            }
            var first = true;
            var it = ep.object.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.* != .string) continue;
                const seg = std.fmt.bufPrint(out[w..], "{s}\"{s}\":\"{s}\"", .{ if (first) "" else ",", kv.key_ptr.*, kv.value_ptr.*.string }) catch break;
                w += seg.len;
                first = false;
            }
            if (w < out.len) {
                out[w] = '}';
                w += 1;
            }
            pl.endpoints_len = w;
        };

        plugins[plugin_count] = pl;
        plugin_count += 1;
    }
    status.store(.ok, .release);
    setMsg("{d} source(s) available", .{plugin_count});
}

// ── Install / uninstall ──────────────────────────────────────────────────────

pub fn isInstalled(id: []const u8) bool {
    return source_config.has(id);
}

fn sourceFilePath(buf: []u8, id: []const u8) []const u8 {
    var dir_buf: [600]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/{s}.json", .{ source_config.sourcesDir(&dir_buf), id }) catch "";
}

pub fn install(idx: usize) void {
    if (idx >= plugin_count) return;
    const pl = &plugins[idx];
    if (pl.endpoints_len == 0) {
        state.showToastTyped("Plugin has no endpoint", .warning);
        return;
    }
    var dir_buf: [600]u8 = undefined;
    io.cwdMakePath(source_config.sourcesDir(&dir_buf)) catch {};
    var fp_buf: [700]u8 = undefined;
    const fp = sourceFilePath(&fp_buf, pl.idSlice());
    io.cwdWriteFile(.{ .sub_path = fp, .data = pl.endpoints[0..pl.endpoints_len] }) catch {
        state.showToastTyped("Install failed (write)", .err);
        return;
    };
    source_config.reload();
    var tb: [80]u8 = undefined;
    state.showToastTyped(std.fmt.bufPrint(&tb, "Installed {s}", .{pl.nameSlice()}) catch "Installed", .success);
    logs.pushLog("info", "plugins", "source endpoint installed", false);
}

pub fn uninstall(idx: usize) void {
    if (idx >= plugin_count) return;
    var fp_buf: [700]u8 = undefined;
    const fp = sourceFilePath(&fp_buf, plugins[idx].idSlice());
    io.cwdDeleteFile(fp) catch {};
    source_config.reload();
    state.showToastTyped("Uninstalled", .info);
}
