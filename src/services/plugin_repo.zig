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
    // The endpoints object, serialized verbatim ({"base":"…"}) — written on install
    // when no `file` is given (legacy inline manifest).
    endpoints: [512]u8 = std.mem.zeroes([512]u8),
    endpoints_len: usize = 0,
    // Repo path to the plugin's own file (e.g. "plugins/torrentio.json"); when
    // present, Install FETCHES it from the repo and writes it as the source config.
    file: [128]u8 = std.mem.zeroes([128]u8),
    file_len: usize = 0,

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

// Debrid config — turns torrent results into instant cached HTTP streams via a
// Stremio add-on (Torrentio/Comet/…). `provider` is the add-on's provider id
// (realdebrid, alldebrid, premiumize, torbox, debridlink); `key` is the API key.
// Applied at addon-load time (stremio.loadInstalledAddons) to a plugin's "debrid"
// URL template, so changing it takes effect on the next search — no reinstall.
pub var debrid_provider_buf: [32]u8 = std.mem.zeroes([32]u8);
pub var debrid_provider_len: usize = 0;
pub var debrid_key_buf: [128]u8 = std.mem.zeroes([128]u8);
pub var debrid_key_len: usize = 0;

pub fn debridProvider() []const u8 {
    return if (debrid_provider_len > 0) debrid_provider_buf[0..debrid_provider_len] else "realdebrid";
}
pub fn debridKey() []const u8 {
    return debrid_key_buf[0..debrid_key_len];
}

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

fn debridPath(buf: []u8) []const u8 {
    var cfg: [512]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/plugins/debrid.json", .{paths.configDir(&cfg)}) catch "";
}

/// Load the persisted GitHub token + debrid config (if any). Call at startup.
pub fn init() void {
    var pb: [600]u8 = undefined;
    const tp = tokenPath(&pb);
    if (io.cwdReadFileAlloc(tp, alloc, 4096)) |body| {
        defer alloc.free(body);
        const t = std.mem.trim(u8, body, " \r\n\t");
        if (t.len > 0 and t.len <= token_buf.len) {
            @memcpy(token_buf[0..t.len], t);
            token_len = t.len;
        }
    } else |_| {}
    loadDebrid();
}

fn loadDebrid() void {
    var pb: [600]u8 = undefined;
    const dp = debridPath(&pb);
    const body = io.cwdReadFileAlloc(dp, alloc, 4096) catch return;
    defer alloc.free(body);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    if (parsed.value.object.get("provider")) |v| if (v == .string and v.string.len <= debrid_provider_buf.len) {
        @memcpy(debrid_provider_buf[0..v.string.len], v.string);
        debrid_provider_len = v.string.len;
    };
    if (parsed.value.object.get("key")) |v| if (v == .string and v.string.len <= debrid_key_buf.len) {
        @memcpy(debrid_key_buf[0..v.string.len], v.string);
        debrid_key_len = v.string.len;
    };
}

/// Persist the debrid provider/key entered in the UI.
pub fn saveDebrid() void {
    var cfg: [512]u8 = undefined;
    var dir_buf: [600]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buf, "{s}/plugins", .{paths.configDir(&cfg)}) catch return;
    io.cwdMakePath(dir) catch {};
    var body_buf: [400]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{{\"provider\":\"{s}\",\"key\":\"{s}\"}}", .{ debridProvider(), debridKey() }) catch return;
    var pb: [600]u8 = undefined;
    io.cwdWriteFile(.{ .sub_path = debridPath(&pb), .data = body }) catch {};
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
        copyField(&pl.file, &pl.file_len, p.object.get("file"));
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

/// Fetch a file from the plugin repo (GitHub contents API, raw) into `out`.
fn fetchRepoFile(repo_path: []const u8, out: []u8) usize {
    var url_buf: [320]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://api.github.com/repos/{s}/contents/{s}", .{ repo(), repo_path }) catch return 0;
    var auth_buf: [320]u8 = undefined;
    const have_token = token_len > 0;
    const auth = if (have_token) (std.fmt.bufPrint(&auth_buf, "Authorization: Bearer {s}", .{token_buf[0..token_len]}) catch return 0) else "";
    var child = if (have_token)
        io.Child.init(&.{ "curl", "-s", "-H", "Accept: application/vnd.github.raw", "-H", "User-Agent: Opal", "-H", auth, "--max-time", "15", url }, alloc)
    else
        io.Child.init(&.{ "curl", "-s", "-H", "Accept: application/vnd.github.raw", "-H", "User-Agent: Opal", "--max-time", "15", url }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return 0;
    const n = if (child.stdout) |*so| io.readAll(so, out) catch 0 else 0;
    _ = child.wait() catch {};
    return n;
}

fn writeSource(id: []const u8, data: []const u8) bool {
    var dir_buf: [600]u8 = undefined;
    io.cwdMakePath(source_config.sourcesDir(&dir_buf)) catch {};
    var fp_buf: [700]u8 = undefined;
    io.cwdWriteFile(.{ .sub_path = sourceFilePath(&fp_buf, id), .data = data }) catch return false;
    source_config.reload();
    return true;
}

pub fn install(idx: usize) void {
    if (idx >= plugin_count) return;
    const pl = &plugins[idx];

    // Per-plugin file in the repo → fetch it on install (worker, network).
    if (pl.file_len > 0) {
        const S = struct {
            var busy: bool = false;
            var id: [32]u8 = undefined;
            var id_len: usize = 0;
            var file: [128]u8 = undefined;
            var file_len: usize = 0;
            var name: [48]u8 = undefined;
            var name_len: usize = 0;
            fn worker() void {
                defer busy = false;
                var buf: [16384]u8 = undefined;
                const n = fetchRepoFile(file[0..file_len], &buf);
                const ok = n > 0 and buf[0] == '{' and std.mem.indexOf(u8, buf[0..n], "\"Not Found\"") == null;
                if (!ok) {
                    state.showToastTyped("Install failed (fetch)", .err);
                    return;
                }
                if (!writeSource(id[0..id_len], buf[0..n])) {
                    state.showToastTyped("Install failed (write)", .err);
                    return;
                }
                var tb: [80]u8 = undefined;
                state.showToastTyped(std.fmt.bufPrint(&tb, "Installed {s}", .{name[0..name_len]}) catch "Installed", .success);
            }
        };
        if (S.busy) return;
        S.busy = true;
        @memcpy(S.id[0..pl.id_len], pl.idSlice());
        S.id_len = pl.id_len;
        @memcpy(S.file[0..pl.file_len], pl.file[0..pl.file_len]);
        S.file_len = pl.file_len;
        @memcpy(S.name[0..pl.name_len], pl.nameSlice());
        S.name_len = pl.name_len;
        (std.Thread.spawn(.{}, S.worker, .{}) catch {
            S.busy = false;
            return;
        }).detach();
        state.showToastTyped("Installing", .info);
        return;
    }

    // Legacy: endpoints inline in the manifest → write directly.
    if (pl.endpoints_len == 0) {
        state.showToastTyped("Plugin has no endpoint", .warning);
        return;
    }
    if (!writeSource(pl.idSlice(), pl.endpoints[0..pl.endpoints_len])) {
        state.showToastTyped("Install failed (write)", .err);
        return;
    }
    var tb: [80]u8 = undefined;
    state.showToastTyped(std.fmt.bufPrint(&tb, "Installed {s}", .{pl.nameSlice()}) catch "Installed", .success);
}

pub fn uninstall(idx: usize) void {
    if (idx >= plugin_count) return;
    var fp_buf: [700]u8 = undefined;
    const fp = sourceFilePath(&fp_buf, plugins[idx].idSlice());
    io.cwdDeleteFile(fp) catch {};
    source_config.reload();
    state.showToastTyped("Uninstalled", .info);
}
