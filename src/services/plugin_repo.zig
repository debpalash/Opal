//! Source-endpoint plugin manager (qBittorrent-style). Fetches a manifest from
//! the `opal-plugins` repo and Installs/Uninstalls *endpoints* for Opal's built-in
//! connectors. Installing writes `~/.config/opal/plugins/sources/<id>.json`
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
const pure = @import("../core/source_config_pure.zig");
const state = @import("../core/state.zig");
const sync = @import("../core/sync.zig");

// Cap on parsed manifest entries. The bundled plugins-manifest.json already
// exceeds 32 (47 entries), so a low cap silently drops sources past the limit
// in both the bundled parse and the remote refresh (parseManifest :262). Keep
// this comfortably above the manifest size; each Plugin is fixed-size buffers.
pub const MAX = 128;

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
pub const Action = enum { refresh, install, uninstall, update };
pub const ApplyResult = enum { applied, accepted, unchanged, busy, not_found, failed };
pub var status: std.atomic.Value(Status) = std.atomic.Value(Status).init(.idle);
pub var status_msg: [128]u8 = std.mem.zeroes([128]u8);
pub var status_msg_len: usize = 0;

pub var plugins: [MAX]Plugin = undefined;
pub var plugin_count: usize = 0;
var catalog_mutex: sync.Mutex = .{};

/// Copy an immutable catalog view for UI/API callers. Remote refresh publishes
/// under the same lock, so a client never pairs half of one manifest with half
/// of another or acts on an index that changed underneath it.
pub fn snapshotCopy(out: []Plugin) usize {
    catalog_mutex.lock();
    defer catalog_mutex.unlock();
    const n = @min(out.len, plugin_count);
    for (0..n) |i| out[i] = plugins[i];
    return n;
}

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
    @import("../core/secret_file.zig").restrictExisting(tp);
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
    @import("../core/secret_file.zig").restrictExisting(dp);
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
    @import("../core/secret_file.zig").write(debridPath(&pb), body) catch {};
}

/// Persist the token entered in the UI.
pub fn saveToken() void {
    var cfg: [512]u8 = undefined;
    var dir_buf: [600]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buf, "{s}/plugins", .{paths.configDir(&cfg)}) catch return;
    io.cwdMakePath(dir) catch {};
    var pb: [600]u8 = undefined;
    const tp = tokenPath(&pb);
    @import("../core/secret_file.zig").write(tp, token_buf[0..token_len]) catch {};
}

// ── Fetch manifest ───────────────────────────────────────────────────────────

/// Load the plugin list from the bundled manifest (no token, no network) so the
/// Plugins page shows everything immediately. Bundled into the .app at build time
/// (Resources/plugins-manifest.json); in dev it's read from the project root.
pub fn loadLocalManifest() void {
    catalog_mutex.lock();
    const loaded = plugin_count > 0;
    catalog_mutex.unlock();
    if (loaded) return;
    var path_buf: [700]u8 = undefined;
    const path: []const u8 = if (state.resourceRoot()) |r|
        (std.fmt.bufPrint(&path_buf, "{s}/plugins-manifest.json", .{r}) catch return)
    else
        "data/plugins-manifest.json";
    const body = io.cwdReadFileAlloc(path, alloc, 262144) catch return;
    defer alloc.free(body);
    parseManifest(body);
}

pub fn refresh() ApplyResult {
    // Checking then storing an atomic in two separate operations still lets two
    // HTTP workers launch refreshes together. Use the catalog lock as the short
    // admission gate; the network request itself runs after it is released.
    catalog_mutex.lock();
    if (status.load(.acquire) == .fetching) {
        catalog_mutex.unlock();
        return .busy;
    }
    status.store(.fetching, .release);
    catalog_mutex.unlock();
    setMsg("Fetching…", .{});
    const t = @import("../core/workers.zig").spawnLegacy(refreshWorker, .{}) catch {
        fail("spawn failed");
        return .failed;
    };
    @import("../core/workers.zig").release(t);
    return .accepted;
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

    const buf = alloc.alloc(u8, 256 * 1024) catch {
        fail("oom");
        return;
    };
    defer alloc.free(buf);
    // Native HTTP keeps the PAT out of the process table. Passing it through
    // curl's `-H` argv made private-repo credentials visible to every local
    // process that can inspect command lines.
    const body = @import("../core/http.zig").fetch(url, buf, .{
        .timeout_secs = 15,
        .user_agent = "Opal",
        .accept = "application/vnd.github.raw",
        .auth_header = if (have_token) auth else null,
    }) orelse {
        fail("empty (check repo/token)");
        return;
    };
    parseManifest(body);
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

fn copyId(dst: []u8, dst_len: *usize, v: ?std.json.Value) bool {
    const val = v orelse return false;
    if (val != .string or val.string.len == 0 or val.string.len > dst.len) return false;
    if (!pure.validId(val.string)) return false;
    @memcpy(dst[0..val.string.len], val.string);
    dst_len.* = val.string.len;
    return true;
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

    catalog_mutex.lock();
    defer catalog_mutex.unlock();
    plugin_count = 0;
    for (arr_v.array.items) |p| {
        if (plugin_count >= MAX or p != .object) continue;
        var pl = Plugin{};
        // IDs become file names and remote command targets. Reject malformed
        // or overlong values instead of truncating them into a different ID.
        if (!copyId(&pl.id, &pl.id_len, p.object.get("id"))) continue;
        copyField(&pl.name, &pl.name_len, p.object.get("name"));
        copyField(&pl.kind, &pl.kind_len, p.object.get("type"));
        copyField(&pl.version, &pl.version_len, p.object.get("version"));
        copyField(&pl.file, &pl.file_len, p.object.get("file"));
        if (findPluginLocked(pl.idSlice()) != null) continue;

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
                // A list-valued endpoint (`"mirrors": [...]`) is flattened to the
                // comma-separated string source_config stores, so it survives the
                // install instead of being dropped on the floor here.
                var joined: [512]u8 = undefined;
                const val: []const u8 = switch (kv.value_ptr.*) {
                    .string => |s| s,
                    .array => |list| blk: {
                        var jw: usize = 0;
                        for (list.items) |el| {
                            if (el != .string or el.string.len == 0) continue;
                            if (jw + el.string.len + 1 > joined.len) break;
                            if (jw > 0) {
                                joined[jw] = ',';
                                jw += 1;
                            }
                            @memcpy(joined[jw..][0..el.string.len], el.string);
                            jw += el.string.len;
                        }
                        break :blk joined[0..jw];
                    },
                    else => continue,
                };
                // An empty STRING is kept — torznab ships `"base":""` as a
                // skeleton for the user to fill in — but an empty list is not.
                if (kv.value_ptr.* == .array and val.len == 0) continue;
                const seg = std.fmt.bufPrint(out[w..], "{s}\"{s}\":\"{s}\"", .{ if (first) "" else ",", kv.key_ptr.*, val }) catch break;
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

fn findPluginLocked(id: []const u8) ?usize {
    for (plugins[0..plugin_count], 0..) |*plugin, i| {
        if (std.mem.eql(u8, plugin.idSlice(), id)) return i;
    }
    return null;
}

/// Operate on a stable source id, never a catalog index supplied by a client.
/// Refresh/update are catalog-wide; install/uninstall are idempotent and report
/// whether work completed synchronously or was accepted by the fetch worker.
pub fn apply(action: Action, id: []const u8) ApplyResult {
    switch (action) {
        .refresh => {
            return refresh();
        },
        .update => return if (migrateStaleSources() > 0) .applied else .unchanged,
        .install, .uninstall => {},
    }

    catalog_mutex.lock();
    defer catalog_mutex.unlock();
    const idx = findPluginLocked(id) orelse return .not_found;
    const installed = isInstalled(id);
    if (action == .install) {
        if (installed) return .unchanged;
        const async_install = plugins[idx].endpoints_len == 0 and plugins[idx].file_len > 0;
        install(idx);
        if (async_install) return .accepted;
        return if (isInstalled(id)) .applied else .failed;
    }
    if (!installed) return .unchanged;
    uninstall(idx);
    return if (isInstalled(id)) .failed else .applied;
}

/// Installed == the source file exists on disk.
///
/// This used to ask the parsed endpoint table (`source_config.has`), which is a
/// different question: a source whose fields did not fit the table reported
/// "not installed" even though install() had written its file, so the page kept
/// offering Install and clicking it changed nothing visible. Install writes the
/// file and uninstall deletes it, so the file is the authority. (The table
/// overflow that exposed this is fixed too — see source_config_pure — but the
/// button must not depend on table capacity in the first place.)
pub fn isInstalled(id: []const u8) bool {
    if (!@import("../core/source_config_pure.zig").validId(id)) return false;
    var fp_buf: [700]u8 = undefined;
    const fp = sourceFilePath(&fp_buf, id);
    if (fp.len == 0) return false;
    _ = io.cwdStatFile(fp) catch return false;
    return true;
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
    const body = @import("../core/http.zig").fetch(url, out, .{
        .timeout_secs = 15,
        .user_agent = "Opal",
        .accept = "application/vnd.github.raw",
        .auth_header = if (have_token) auth else null,
    }) orelse return 0;
    return body.len;
}

fn writeSource(id: []const u8, data: []const u8) bool {
    return writeSourceVersioned(id, data, "");
}

/// Write an installed source, stamping the manifest version it came from.
///
/// The stamp is what makes upgrades possible at all: without it there is no way
/// to tell a source installed from today's manifest from one installed a year
/// ago, so a corrected endpoint could never reach an existing install. See
/// `migrateStaleSources`.
///
/// The version is spliced in as the first key rather than appended, so it
/// survives a `data` payload that ends in a trailing newline or whitespace.
fn writeSourceVersioned(id: []const u8, data: []const u8, version: []const u8) bool {
    var dir_buf: [600]u8 = undefined;
    io.cwdMakePath(source_config.sourcesDir(&dir_buf)) catch {};
    var fp_buf: [700]u8 = undefined;
    const path = sourceFilePath(&fp_buf, id);

    var stamped: [2048]u8 = undefined;
    var payload = data;
    // Only splice when we have a version AND the payload is a JSON object we
    // recognise. Anything else is written through untouched — a source that
    // cannot be stamped is still better than a source that fails to install.
    if (version.len > 0 and data.len >= 2 and data[0] == '{') {
        const rest = std.mem.trimStart(u8, data[1..], " \t\r\n");
        const sep: []const u8 = if (rest.len > 0 and rest[0] != '}') "," else "";
        payload = std.fmt.bufPrint(&stamped, "{{\"{s}\":\"{s}\"{s}{s}", .{
            pure.VERSION_KEY, version, sep, rest,
        }) catch data;
    }

    io.cwdWriteFile(.{ .sub_path = path, .data = payload }) catch return false;
    source_config.reload();
    return true;
}

/// Rewrite installed sources whose manifest entry has since been corrected.
///
/// Without this, a fixed endpoint never reaches anyone who already installed the
/// source: `reload()` reads the file on disk, and the file wins over both the
/// manifest and the engine's own default. That is not hypothetical — `yts.mx`
/// lost its NS delegation at the .mx registry and `limetorrent.in` began serving
/// a TheRarBg page under a 200 OK, and both were corrected in the manifest while
/// every existing install carried on querying the dead host.
///
/// Only rewrites when the manifest version is strictly newer than the stamp on
/// disk, so a user's own edits to an up-to-date source are never clobbered.
/// Returns how many were migrated.
pub fn migrateStaleSources() usize {
    catalog_mutex.lock();
    defer catalog_mutex.unlock();
    var migrated: usize = 0;
    for (plugins[0..plugin_count]) |*pl| {
        if (pl.endpoints_len == 0) continue;
        const id = pl.idSlice();
        if (!source_config.has(id)) continue; // not installed — nothing to migrate
        const manifest_v = pl.version[0..pl.version_len];
        const installed_v = source_config.get(id, pure.VERSION_KEY) orelse "";
        if (!pure.versionNewer(manifest_v, installed_v)) continue;
        if (writeSourceVersioned(id, pl.endpoints[0..pl.endpoints_len], manifest_v)) {
            migrated += 1;
            var lb: [96]u8 = undefined;
            logs.pushLog("info", "sources", std.fmt.bufPrint(
                &lb,
                "updated {s} endpoints to manifest v{s}",
                .{ id, manifest_v },
            ) catch "source endpoints updated", false);
        }
    }
    return migrated;
}

/// Uninstall sources whose consumer or host is gone (`pure.RETIRED`).
///
/// migrateStaleSources only rewrites ids the manifest still carries, so a source
/// dropped from the manifest is exactly the one it cannot reach. Those installs
/// keep working: `stremio.loadInstalledAddons()` enumerates the sources
/// directory itself, so a retired add-on stays live — and burns one of the
/// sixteen installed slots — until its file is gone. Returns how many were
/// removed. Only fires while the value on disk still names the dead host (see
/// `pure.shouldRetire`), so a user's own re-pointed instance survives.
pub fn retireDeadSources() usize {
    var retired: usize = 0;
    for (pure.RETIRED) |r| {
        if (!source_config.has(r.id)) continue; // not installed — nothing to do
        const installed_val = source_config.get(r.id, r.field) orelse "";
        if (!pure.shouldRetire(r.host, installed_val)) continue;
        source_config.uninstallById(r.id);
        retired += 1;
        var lb: [160]u8 = undefined;
        logs.pushLog("info", "sources", std.fmt.bufPrint(
            &lb,
            "retired dead source {s}: {s}",
            .{ r.id, r.why },
        ) catch "retired a dead source", false);
    }
    return retired;
}

pub fn install(idx: usize) void {
    if (idx >= plugin_count) return;
    const pl = &plugins[idx];

    // Prefer the manifest's INLINE endpoints (already in memory) over a network
    // fetch. Every bundled/remote entry inlines its endpoints, so fetching the
    // per-plugin repo file for each install was pure waste — and worse, it
    // burned GitHub's 60-req/hour unauthenticated limit, so after a handful of
    // clicks every further install 403'd ("a few install, most don't"). Only
    // fall back to the network file when the manifest didn't inline endpoints.
    if (pl.endpoints_len == 0 and pl.file_len > 0) {
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
        @import("../core/workers.zig").release(@import("../core/workers.zig").spawnLegacy(S.worker, .{}) catch {
            S.busy = false;
            return;
        });
        state.showToastTyped("Installing", .info);
        return;
    }

    // Legacy: endpoints inline in the manifest → write directly.
    if (pl.endpoints_len == 0) {
        state.showToastTyped("Plugin has no endpoint", .warning);
        return;
    }
    if (!writeSourceVersioned(pl.idSlice(), pl.endpoints[0..pl.endpoints_len], pl.version[0..pl.version_len])) {
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

/// One-click starter pack for onboarding: install a curated set of reliable
/// source plugins from the BUNDLED manifest's inline endpoints (no network,
/// no GitHub fetch). Skips anything already installed. Deliberately excludes
/// jackett (needs a local server), academictorrents (junk for media queries)
/// and region-specific trackers. Returns how many were installed.
pub fn installStarterPack() usize {
    loadLocalManifest();
    catalog_mutex.lock();
    defer catalog_mutex.unlock();
    const starter_ids = [_][]const u8{
        "apibay",      "one337x",       "yts",      "eztv",
        "bitsearch",   "solidtorrents", "therarbg", "torrentgalaxy",
        "torrentscsv", "limetorrents",  "torlock",  "glotorrents",
        "nyaa",        "torrentio",
    };
    var installed: usize = 0;
    for (plugins[0..plugin_count]) |*pl| {
        const id = pl.idSlice();
        var wanted = false;
        for (starter_ids) |sid| {
            if (std.mem.eql(u8, sid, id)) {
                wanted = true;
                break;
            }
        }
        if (!wanted or pl.endpoints_len == 0) continue;
        if (source_config.has(id)) continue;
        if (writeSourceVersioned(id, pl.endpoints[0..pl.endpoints_len], pl.version[0..pl.version_len])) installed += 1;
    }
    return installed;
}

// ── Opt-in SFW manga source catalog ──────────────────────────────────────────
//
// `manga-sources-sfw.json` is a CATALOG, not a live source list: a curated array
// of `{ name, base, framework, lang }` for SFW manga sites classified (by the
// keiyoushi index) as one of Opal's framework engines — Madara, MangaThemesia,
// HeanCms. It is browsed/installed by the user (Plugins tab or the remote
// `/api/source/catalog` + `/api/source/add` endpoints); NOTHING here is active
// until the user picks an entry. Consistent with Opal's source-neutral design:
// the binary ships no scraper URL; installing just writes `source_config`.
//
// NOTE: the current source_config model keys by framework id, so only ONE base
// per framework is active at a time — this catalog is a PICKER. Installing an
// entry sets that framework's active base (a multi-site-per-framework upgrade is
// a separate task).

/// True for the three framework engines the catalog can drive. `iken` sites are
/// pre-mapped to `heancms` at catalog-build time, so only these three appear.
pub fn isMangaFramework(fw: []const u8) bool {
    return std.mem.eql(u8, fw, "madara") or
        std.mem.eql(u8, fw, "mangathemesia") or
        std.mem.eql(u8, fw, "heancms");
}

/// Install a catalog entry: set `framework`'s active base to `base`. Routes
/// through `source_config.install(framework, {"base":"<base>"})` exactly like
/// the browser extension's /api/source/add. Returns false on a bad framework,
/// a non-http(s) base, or a write error. This is the single opt-in install path
/// for the SFW manga catalog (Plugins tab + remote endpoint call into it).
pub fn installMangaSource(base: []const u8, framework: []const u8) bool {
    if (!isMangaFramework(framework)) return false;
    if (!(std.mem.startsWith(u8, base, "https://") or std.mem.startsWith(u8, base, "http://"))) return false;
    if (base.len > 512) return false;
    // Flat JSON body {"base":"<base>"}; escape so the origin can't break JSON.
    var body_buf: [640]u8 = undefined;
    var bw = std.Io.Writer.fixed(&body_buf);
    bw.writeAll("{\"base\":\"") catch return false;
    for (base) |c| {
        switch (c) {
            '"', '\\' => bw.writeAll(&.{ '\\', c }) catch return false,
            else => bw.writeByte(c) catch return false,
        }
    }
    bw.writeAll("\"}") catch return false;
    return source_config.install(framework, body_buf[0..bw.end]);
}

/// Read the raw SFW manga catalog JSON (caller owns/frees). Bundled into the .app
/// (Resources/manga-sources-sfw.json); in dev it's read from the project root.
/// Returns null when the file is absent (feature simply isn't offered).
pub fn readMangaCatalog() ?[]u8 {
    var path_buf: [700]u8 = undefined;
    const path: []const u8 = if (state.resourceRoot()) |r|
        (std.fmt.bufPrint(&path_buf, "{s}/manga-sources-sfw.json", .{r}) catch return null)
    else
        "data/manga-sources-sfw.json";
    return io.cwdReadFileAlloc(path, alloc, 512 * 1024) catch return null;
}
