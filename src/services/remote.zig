const std = @import("std");
const builtin = @import("builtin");
const remote_url_pure = @import("remote_url_pure.zig");
const state = @import("../core/state.zig");
const c = @import("../core/c.zig");
const player = @import("../player/player.zig");
const paths_mod = @import("../core/paths.zig");
const logs = @import("../core/logs.zig");
const sync = @import("../core/sync.zig");
const io_g = @import("../core/io_global.zig");
const txt = @import("../core/text.zig");
const access_pure = @import("access_pure.zig");
const sap = @import("settings_api_pure.zig");
const login_rate = @import("login_rate_pure.zig");

// ══════════════════════════════════════════════════════════
// Web Remote Control — JSON API + the web UI, both on :41595.
// One process, one port: `web/index.html` is served from this file. (The old
// separate :3000 Zig web project was retired in Phase S4.)
// ══════════════════════════════════════════════════════════

var server_thread: ?std.Thread = null;
var running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
/// True only once serverLoop's socket is actually bound and accepting.
/// `running` flips in start() *before* the thread exists, so it cannot tell a
/// caller whether a connection would succeed — see isListening().
var listening: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var port: u16 = 41595;

// ── Bearer-token auth ──
// 32 hex chars = 128 bits of entropy. Generated on first launch, persisted to
// ~/.config/opal/api.token (mode 0600), reused on subsequent runs.
const TOKEN_HEX_LEN: usize = 32;
var api_token: [TOKEN_HEX_LEN]u8 = std.mem.zeroes([TOKEN_HEX_LEN]u8);
var api_token_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var csprng_init: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var csprng: std.Random.DefaultCsprng = undefined;
var csprng_mutex = sync.Mutex{};

/// Seed the CSPRNG from the platform entropy source. Returns false if that
/// fails — we do NOT fall back to a timestamp seed: a predictable bearer token
/// is worse than no remote API at all (callers leave api_token_ready false so
/// endpoints 401).
///
/// This used to read /dev/urandom directly, which does not exist on Windows —
/// so every Windows user got "CSPRNG unavailable — remote API disabled" and no
/// api.token was ever written, making browser-extension pairing impossible
/// (issue #21). io_g.randomSecure is the portable source.
fn seedCsprng() bool {
    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    if (!io_g.randomSecure(&seed)) return false;
    csprng = std.Random.DefaultCsprng.init(seed);
    return true;
}

/// Fill `out` with random hex. Returns false if the CSPRNG could not be seeded
/// (no platform entropy source) — `out` is left untouched in that case.
fn fillRandomHex(out: *[TOKEN_HEX_LEN]u8) bool {
    csprng_mutex.lock();
    defer csprng_mutex.unlock();
    if (!csprng_init.load(.acquire)) {
        if (!seedCsprng()) return false;
        csprng_init.store(true, .release);
    }
    var bytes: [TOKEN_HEX_LEN / 2]u8 = undefined;
    csprng.fill(&bytes);
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return true;
}

fn tokenPath(buf: []u8) []const u8 {
    var dir_buf: [512]u8 = undefined;
    const dir = paths_mod.configDir(&dir_buf);
    return std.fmt.bufPrint(buf, "{s}/api.token", .{dir}) catch "/tmp/opal_api.token";
}

fn isHexAll(s: []const u8) bool {
    for (s) |ch| {
        const ok = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
        if (!ok) return false;
    }
    return true;
}

fn loadOrCreateToken() void {
    if (api_token_ready.load(.acquire)) return;
    var path_buf: [768]u8 = undefined;
    const tok_path = tokenPath(&path_buf);

    // Reuse existing token if present and well-formed.
    if (io_g.openFileAbsolute(tok_path, .{})) |f| {
        var fh = f;
        defer fh.close(io_g.io());
        var read_buf: [TOKEN_HEX_LEN]u8 = undefined;
        const n = io_g.readAll(fh, &read_buf) catch 0;
        if (n == TOKEN_HEX_LEN and isHexAll(read_buf[0..TOKEN_HEX_LEN])) {
            @memcpy(&api_token, &read_buf);
            api_token_ready.store(true, .release);
            var msg_buf: [768]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "API token loaded from {s}", .{tok_path}) catch tok_path;
            logs.pushLog("info", "remote", msg, false);
            return;
        }
    } else |_| {}

    // Ensure config dir exists before writing.
    var dir_buf: [512]u8 = undefined;
    const dir = paths_mod.configDir(&dir_buf);
    io_g.cwdMakePath(dir) catch {};

    if (!fillRandomHex(&api_token)) {
        logs.pushLog("error", "remote", "CSPRNG unavailable — remote API disabled", true);
        return;
    }
    api_token_ready.store(true, .release);
    persistToken();
}

/// Write `api_token` to <configDir>/api.token with 0600. Shared by first-run
/// generation and rotateToken() so both paths get identical permissions —
/// a rotation that dropped the mode would silently widen a 0600 secret.
fn persistToken() void {
    var path_buf: [768]u8 = undefined;
    const tok_path = tokenPath(&path_buf);
    var dir_buf: [512]u8 = undefined;
    io_g.cwdMakePath(paths_mod.configDir(&dir_buf)) catch {};

    // Create with mode 0600; chmod again after write in case umask widened it.
    // Windows has no POSIX modes (Permissions there is an attributes enum with
    // no fromMode); the profile dir is already user-private, so default suffices.
    const token_perms = if (@import("builtin").os.tag == .windows)
        std.Io.File.Permissions.default_file
    else
        std.Io.File.Permissions.fromMode(0o600);
    const file = io_g.createFileAbsolute(tok_path, .{
        .read = false,
        .truncate = true,
        .permissions = token_perms,
    }) catch {
        logs.pushLog("error", "remote", "Failed to persist API token (in-memory only)", true);
        return;
    };
    defer file.close(io_g.io());
    io_g.writeAll(file, &api_token) catch {
        logs.pushLog("error", "remote", "Failed to write API token", true);
        return;
    };
    if (@import("builtin").os.tag != .windows)
        file.setPermissions(io_g.io(), std.Io.File.Permissions.fromMode(0o600)) catch {};

    var msg_buf: [768]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "API token written to {s}", .{tok_path}) catch tok_path;
    logs.pushLog("info", "remote", msg, false);
}

/// Constant-time byte comparison — always inspects every byte to avoid
/// leaking which byte mismatched via response timing.
fn constantTimeEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

fn extractBearer(request: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, request, '\n');
    _ = lines.next(); // request line
    while (lines.next()) |raw_line| {
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) break; // end of headers
        const name = "authorization:";
        if (line.len < name.len) continue;
        var match = true;
        var i: usize = 0;
        while (i < name.len) : (i += 1) {
            const cc = line[i];
            const lc: u8 = if (cc >= 'A' and cc <= 'Z') cc + 32 else cc;
            if (lc != name[i]) {
                match = false;
                break;
            }
        }
        if (!match) continue;
        var value = line[name.len..];
        while (value.len > 0 and (value[0] == ' ' or value[0] == '\t')) value = value[1..];
        const prefix = "bearer ";
        if (value.len <= prefix.len) return null;
        var bp = true;
        var j: usize = 0;
        while (j < prefix.len) : (j += 1) {
            const cc = value[j];
            const lc: u8 = if (cc >= 'A' and cc <= 'Z') cc + 32 else cc;
            if (lc != prefix[j]) {
                bp = false;
                break;
            }
        }
        if (!bp) return null;
        return value[prefix.len..];
    }
    return null;
}

fn sendUnauthorized(stream: std.Io.net.Stream) void {
    const resp = "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: 24\r\n\r\n{\"error\":\"unauthorized\"}";
    _ = io_g.streamWriteAll(stream, resp) catch {};
}

// ── LAN address for the Settings hint ──
var lan_ip_buf: [48]u8 = std.mem.zeroes([48]u8);
var lan_ip_len: usize = 0;
var lan_ip_checked: bool = false;

/// Best-effort LAN IPv4 for "open this on your phone". Empty when undetermined.
///
/// Two bugs lived here. It spawned a bare `ipconfig`, which resolves only if
/// the process PATH carries /usr/sbin -- true from a terminal, not true for a
/// double-clicked .app, which is how users actually run this. And it latched
/// `checked` BEFORE trying, so a single failure cached "no address" for the
/// rest of the session with no way to retry. Measured 2026-08-04: en0 held
/// 192.168.0.198 and /api/webui still reported "".
///
/// Now: absolute paths, every en* an Apple machine is likely to use, a Linux
/// arm, and the latch is only set once an address is actually found.
pub fn lanIp() []const u8 {
    if (lan_ip_len > 0) return lan_ip_buf[0..lan_ip_len];
    if (lan_ip_checked) return "";

    const alloc_m = @import("../core/alloc.zig").allocator;
    const Probe = struct { argv: []const []const u8 };
    const probes: []const Probe = if (builtin.os.tag == .macos) &.{
        // en0 is Wi-Fi on laptops and Ethernet on desktops; the rest cover
        // Thunderbolt/USB adapters and a second NIC.
        .{ .argv = &.{ "/usr/sbin/ipconfig", "getifaddr", "en0" } },
        .{ .argv = &.{ "/usr/sbin/ipconfig", "getifaddr", "en1" } },
        .{ .argv = &.{ "/usr/sbin/ipconfig", "getifaddr", "en2" } },
        .{ .argv = &.{ "/usr/sbin/ipconfig", "getifaddr", "en3" } },
    } else if (builtin.os.tag == .linux) &.{
        // -I prints every address, space separated; take the first.
        .{ .argv = &.{ "/usr/bin/hostname", "-I" } },
        .{ .argv = &.{ "/bin/hostname", "-I" } },
    } else &.{};

    for (probes) |probe| {
        var child = io_g.Child.init(probe.argv, alloc_m);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.spawn() catch continue;
        var buf: [128]u8 = undefined;
        const n = if (child.stdout) |*so| io_g.readAll(so, &buf) catch 0 else 0;
        _ = child.wait() catch {};
        const addr = remote_url_pure.firstIpv4(buf[0..n]) orelse continue;
        if (addr.len > lan_ip_buf.len) continue;
        @memcpy(lan_ip_buf[0..addr.len], addr);
        lan_ip_len = addr.len;
        lan_ip_checked = true;
        return lan_ip_buf[0..lan_ip_len];
    }
    // Only latch once every probe has been tried and none produced an address;
    // a later call still gets a fresh attempt if the machine had no link yet.
    lan_ip_checked = probes.len == 0;
    return "";
}

pub fn start() void {
    if (running.load(.acquire)) return;
    loadOrCreateToken();
    running.store(true, .release);
    server_thread = std.Thread.spawn(.{}, serverLoop, .{}) catch null;
}

/// Loopback-only companion listener, ALWAYS on, serving exactly one route:
/// `/api/scrape`.
///
/// The nova2 Python engines reach Opal's anti-detect browser over HTTP because
/// they run in a child process. Hanging that on `start()` tied it to Settings ›
/// Web Remote, which is off by default — so the bot-wall fallback that gets
/// `1337x` and `uindex` off zero was itself off by default, and turning it on
/// meant exposing the whole JSON API to the LAN. Two unrelated things behind one
/// switch.
///
/// This binds 127.0.0.1 only, so it is not reachable from the network no matter
/// what the Web Remote toggle says, and it still requires the same bearer token.
pub var local_port: u16 = 41596;
var local_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var local_thread: ?std.Thread = null;

pub fn startLocal() void {
    if (local_running.swap(true, .acq_rel)) return;
    loadOrCreateToken();
    local_thread = std.Thread.spawn(.{}, localLoop, .{}) catch {
        local_running.store(false, .release);
        return;
    };
}

pub fn stopLocal() void {
    if (!local_running.swap(false, .acq_rel)) return;
    // Kick accept() awake with a local connection, same as stop() does.
    if (std.Io.net.IpAddress.parseIp4("127.0.0.1", local_port)) |addr| {
        if (addr.connect(io_g.io(), .{ .mode = .stream })) |conn| {
            var c2 = conn;
            c2.close(io_g.io());
        } else |_| {}
    } else |_| {}
    if (local_thread) |t| {
        t.join();
        local_thread = null;
    }
}

fn localLoop() void {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", local_port) catch return;
    var server = addr.listen(io_g.io(), .{ .reuse_address = true }) catch return;
    defer server.deinit(io_g.io());

    while (local_running.load(.acquire)) {
        const conn = server.accept(io_g.io()) catch continue;
        const Handler = struct {
            fn run(c2: std.Io.net.Stream) void {
                const workers = @import("../core/workers.zig");
                workers.enter();
                defer workers.leave();
                var c3 = c2;
                defer c3.close(io_g.io());
                if (workers.isQuitting()) return;
                handleLocalRequest(c3);
            }
        };
        if (std.Thread.spawn(.{}, Handler.run, .{conn})) |t| {
            t.detach();
        } else |_| {
            var c4 = conn;
            defer c4.close(io_g.io());
            handleLocalRequest(c4);
        }
    }
}

/// `/api/scrape` and nothing else. Deliberately NOT a second door into handleApi:
/// this listener exists whether or not the user opted into the remote API, so its
/// surface stays exactly one route.
fn handleLocalRequest(stream: std.Io.net.Stream) void {
    var buf: [4096]u8 = undefined;
    const n = io_g.streamReadAll(stream, &buf) catch return;
    if (n == 0) return;
    const request = buf[0..n];

    var lines = std.mem.splitScalar(u8, request, '\n');
    const first_line = lines.next() orelse return;
    var parts = std.mem.splitScalar(u8, first_line, ' ');
    _ = parts.next() orelse return; // method
    const full_path = parts.next() orelse return;
    var path_parts = std.mem.splitScalar(u8, full_path, '?');
    const path = path_parts.next() orelse return;
    const query = path_parts.next() orelse "";

    if (!std.mem.eql(u8, path, "/api/scrape")) {
        const resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found";
        _ = io_g.streamWriteAll(stream, resp) catch {};
        return;
    }
    const presented = extractBearer(request) orelse {
        sendUnauthorized(stream);
        return;
    };
    if (!isAuthorized(presented)) {
        sendUnauthorized(stream);
        return;
    }
    // A body (everything past the blank line) means "replay this as a POST".
    // Bounded by the 4 KB request buffer above, which is far more than a form
    // body like `layout=def_wlinks` needs.
    const post: ?[]const u8 = blk: {
        const sep = std.mem.indexOf(u8, request, "\r\n\r\n") orelse break :blk null;
        const b = request[sep + 4 ..];
        break :blk if (b.len > 0) b else null;
    };
    handleScrapeBody(stream, query, post);
}

pub fn stop() void {
    if (!running.load(.acquire)) return;
    running.store(false, .release);
    // Kick accept() awake by making a local connection.
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return;
    if (addr.connect(io_g.io(), .{ .mode = .stream })) |conn| {
        var c2 = conn;
        c2.close(io_g.io());
    } else |_| {}
    if (server_thread) |t| {
        t.join();
        server_thread = null;
    }
}

pub fn isRunning() bool {
    return running.load(.acquire);
}

/// Whether the listening socket is up, i.e. whether a browser pointed at
/// `port` right now would connect. start() returns as soon as the thread is
/// spawned, so anything that launches a client (the header Web UI button)
/// must wait on this rather than on isRunning().
pub fn isListening() bool {
    return listening.load(.acquire);
}

/// Which interfaces serverLoop binds. Persisted as `web_bind` (see config.zig);
/// changed from the web UI's Access page, which calls restart() after.
pub var bind_mode: access_pure.BindMode = .lan;

/// Apply a new bind mode / port. No-op when nothing changed. When the server is
/// live it is stopped and restarted so the new socket takes effect immediately
/// rather than at next launch.
///
/// stop() wakes accept() by connecting to 127.0.0.1:<old port>, so it must run
/// BEFORE `port` is reassigned — otherwise the wakeup knocks on the new port,
/// nothing is listening there, and the accept loop blocks until some unrelated
/// connection arrives.
pub fn applyBinding(new_mode: access_pure.BindMode, new_port: u16) void {
    if (new_mode == bind_mode and new_port == port) return;
    const was_running = running.load(.acquire);
    if (was_running) stop();
    bind_mode = new_mode;
    port = new_port;
    if (was_running) start();
}

/// The live bearer token, or "" if the CSPRNG never produced one.
pub fn tokenHex() []const u8 {
    if (!api_token_ready.load(.acquire)) return "";
    return api_token[0..TOKEN_HEX_LEN];
}

/// Generate a fresh bearer token and persist it, invalidating the old one.
/// Anything holding the previous token (browser extension, scripts) must be
/// re-paired. Returns false if the CSPRNG is unavailable — in that case the
/// existing token is left intact rather than being zeroed into an open door.
pub fn rotateToken() bool {
    var fresh: [TOKEN_HEX_LEN]u8 = undefined;
    if (!fillRandomHex(&fresh)) return false;
    @memcpy(&api_token, &fresh);
    api_token_ready.store(true, .release);
    persistToken();
    logs.pushLog("info", "remote", "API token rotated — re-pair the browser extension", false);
    return true;
}

fn serverLoop() void {
    // Default binds all interfaces: the server itself is OPT-IN (Settings ›
    // Web Remote / the header globe, off by default) and its whole point is
    // reaching Opal from a phone on the LAN. Users who only drive it from this
    // machine can switch to loopback in the web UI's Access page.
    // Auth: bearer token from account login (/api/auth) or the api.token file.
    const ip = bind_mode.address();
    const addr = std.Io.net.IpAddress.parseIp4(ip, port) catch return;
    var server = addr.listen(io_g.io(), .{ .reuse_address = true }) catch return;
    defer server.deinit(io_g.io());
    // Only now is a connection possible. The header's Web UI button waits on
    // this before launching the browser (see isListening()).
    listening.store(true, .release);
    defer listening.store(false, .release);

    std.debug.print("[remote] web UI + JSON API on http://{s}:{d}\n", .{ ip, port });

    // Thread-per-connection: a video /stream (H2) or a slow client must not
    // freeze every other request the way the old sequential accept→handle
    // loop did. API handler logic stays serialized via api_mutex, so the
    // shared-state assumptions of the single-thread era still hold.
    while (running.load(.acquire)) {
        const conn = server.accept(io_g.io()) catch continue;
        const Handler = struct {
            fn run(c2: std.Io.net.Stream) void {
                const workers = @import("../core/workers.zig");
                workers.enter();
                defer workers.leave();
                var c3 = c2;
                defer c3.close(io_g.io());
                if (workers.isQuitting()) return;
                handleRequest(c3) catch {};
            }
        };
        if (std.Thread.spawn(.{}, Handler.run, .{conn})) |t| {
            t.detach();
        } else |_| {
            var c4 = conn;
            defer c4.close(io_g.io());
            handleRequest(c4) catch {}; // degraded: serve inline
        }
    }
}

/// Serializes /api/* handler logic across connection threads — exactly the
/// guarantees handlers were written under when the server was sequential.
/// Static/stream paths do NOT take it (they touch no shared app state).
var api_mutex: @import("../core/sync.zig").Mutex = .{};


fn handleRequest(stream: std.Io.net.Stream) !void {
    var buf: [4096]u8 = undefined;
    const n = io_g.streamReadAll(stream, &buf) catch return;
    if (n == 0) return;
    const request = buf[0..n];

    // NOTE: no DNS-rebinding Host gate here anymore. It existed to protect the
    // token-INJECTED page; the token is no longer injected anywhere (the browser
    // logs in via /api/auth for a session token) and the gate 403'd real phones
    // (Host: 192.168.x.x) once windowed mode started binding the LAN.
    // Unauthenticated surface is now: static page, /api/auth/*, /health.

    var lines = std.mem.splitScalar(u8, request, '\n');
    const first_line = lines.next() orelse return;
    var parts = std.mem.splitScalar(u8, first_line, ' ');
    _ = parts.next() orelse return; // method
    const full_path = parts.next() orelse return;

    // Parse path and query string
    var path_parts = std.mem.splitScalar(u8, full_path, '?');
    const path = path_parts.next() orelse return;
    const query = path_parts.next() orelse "";

    // /health is unauthenticated, for liveness probes.
    if (std.mem.eql(u8, path, "/health")) {
        sendJson(stream, "{\"ok\":true}");
        return;
    }

    // The HTML shell is served unauthenticated (there is no way to bootstrap
    // otherwise); it contains NO secrets — the page presents the account
    // login/register (which POST to /api/auth). Bundled copy first (installed
    // .app), repo copy in dev.
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        var res_buf: [700]u8 = undefined;
        const bundled: ?[]const u8 = if (state.resourceRoot()) |r|
            (std.fmt.bufPrint(&res_buf, "{s}/web/index.html", .{r}) catch null)
        else
            null;
        if (bundled) |bp| {
            if (io_g.cwdOpenFile(bp, .{})) |f| {
                var fh = f;
                fh.close(io_g.io());
                serveStaticFile(stream, bp, "text/html");
                return;
            } else |_| {}
        }
        serveStaticFile(stream, "web/index.html", "text/html");
        return;
    }

    // Browsers request /favicon.ico on their own, unauthenticated. Falling
    // through to the bearer gate answered 401 and put a red error in every
    // console. 204 is the correct "there isn't one, stop asking".
    if (std.mem.eql(u8, path, "/favicon.ico")) {
        _ = io_g.streamWriteAll(stream, "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nCache-Control: max-age=86400\r\n\r\n") catch {};
        return;
    }

    // Vendored browser deps, served next to the page. Unauthenticated for the
    // same reason index.html is: the login form itself needs them, and they are
    // public third-party libraries, not user data.
    if (std.mem.eql(u8, path, "/vendor/hls.min.js")) {
        var res_buf: [700]u8 = undefined;
        const bundled: ?[]const u8 = if (state.resourceRoot()) |r|
            (std.fmt.bufPrint(&res_buf, "{s}/web/vendor/hls.min.js", .{r}) catch null)
        else
            null;
        if (bundled) |bp| {
            if (io_g.cwdOpenFile(bp, .{})) |f| {
                var fh = f;
                fh.close(io_g.io());
                serveStaticFile(stream, bp, "application/javascript");
                return;
            } else |_| {}
        }
        serveStaticFile(stream, "web/vendor/hls.min.js", "application/javascript");
        return;
    }

    // Media routes (/stream, /vtt, /poster): <video>/<img> can't attach an
    // Authorization header, so these take the token as ?t= instead. Same
    // constant-time check as the Bearer gate; dispatch lives in
    // remote_stream.zig to keep this file to routing/auth.
    if (std.mem.eql(u8, path, "/events") or std.mem.eql(u8, path, "/stream") or std.mem.eql(u8, path, "/transcode") or std.mem.eql(u8, path, "/vtt") or std.mem.eql(u8, path, "/poster") or std.mem.eql(u8, path, "/api/jellyfin/poster") or std.mem.eql(u8, path, "/api/podcasts/poster") or std.mem.eql(u8, path, "/api/comics/page")) {
        // isAuthorized, not a bare api_token compare: the web UI authenticates
        // with a SESSION token (there is no token injection into the page any
        // more), so a logged-in user could not stream their own files — the
        // "Play here" destination had nothing to point <video> at. A session
        // token is already a full-power bearer for every /api/* route, so
        // honouring it here is consistency, not a widening of access.
        var t_dec: [96]u8 = undefined;
        const t_raw = getQueryParam(query, "t") orelse "";
        const t = urlDecode(t_raw, &t_dec) orelse t_raw;
        if (!isAuthorized(t)) {
            sendUnauthorized(stream);
            return;
        }
        // SSE status stream — pushes playback status ~1×/s so the web client
        // drops its 1s polling. Held OPEN on this connection thread (not under
        // api_mutex), so it never blocks other requests. Bounded to ~1h.
        if (std.mem.eql(u8, path, "/events")) {
            const hdr = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n";
            io_g.streamWriteAll(stream, hdr) catch return;
            var json: [512]u8 = undefined;
            var frame: [640]u8 = undefined;
            var ticks: usize = 0;
            while (running.load(.acquire) and ticks < 3600) : (ticks += 1) {
                const body = buildStatusJson(&json);
                const ev = std.fmt.bufPrint(&frame, "data: {s}\n\n", .{body}) catch break;
                io_g.streamWriteAll(stream, ev) catch break; // client closed
                io_g.sleep(1 * std.time.ns_per_s);
            }
            return;
        }
        const rs = @import("remote_stream.zig");
        var dec_buf: [1200]u8 = undefined;
        if (std.mem.eql(u8, path, "/stream")) {
            const rel = urlDecode(getQueryParam(query, "file") orelse "", &dec_buf) orelse "";
            rs.handleStream(stream, request, rel);
        } else if (std.mem.eql(u8, path, "/transcode")) {
            const rel = urlDecode(getQueryParam(query, "file") orelse "", &dec_buf) orelse "";
            // Seeking restarts the encode at an offset; there is no Range on a
            // stream that does not exist yet.
            const start_secs = std.fmt.parseInt(u32, getQueryParam(query, "start") orelse "0", 10) catch 0;
            rs.handleTranscode(stream, rel, start_secs);
        } else if (std.mem.eql(u8, path, "/vtt")) {
            const rel = urlDecode(getQueryParam(query, "file") orelse "", &dec_buf) orelse "";
            rs.handleVtt(stream, rel);
        } else if (std.mem.eql(u8, path, "/api/jellyfin/poster")) {
            const id = urlDecode(getQueryParam(query, "id") orelse "", &dec_buf) orelse "";
            rs.handleJfPoster(stream, id);
        } else if (std.mem.eql(u8, path, "/api/podcasts/poster")) {
            // Bad/missing idx → maxInt, which handlePodcastPoster's bounds check
            // rejects with a 404.
            const idx = std.fmt.parseInt(usize, getQueryParam(query, "idx") orelse "", 10) catch std.math.maxInt(usize);
            rs.handlePodcastPoster(stream, idx);
        } else if (std.mem.eql(u8, path, "/api/comics/page")) {
            const i = std.fmt.parseInt(usize, getQueryParam(query, "i") orelse "", 10) catch std.math.maxInt(usize);
            rs.handleComicPage(stream, i);
        } else {
            const pp = urlDecode(getQueryParam(query, "path") orelse "", &dec_buf) orelse "";
            rs.handlePoster(stream, pp);
        }
        return;
    }

    // ── Account auth (same for headless AND desktop-remote; supersedes the
    // account) ── the only unauthenticated data routes besides /health,
    // since they are how a browser OBTAINS a session token. Credentials arrive
    // in the POST body so they never land in URLs / access logs.
    if (std.mem.startsWith(u8, path, "/api/auth/")) {
        const auth_store = @import("auth_store.zig");
        const sub = path["/api/auth/".len..];

        if (std.mem.eql(u8, sub, "status")) {
            const authed = if (extractBearer(request)) |b| isAuthorized(b) else false;
            var jb: [64]u8 = undefined;
            const j = std.fmt.bufPrint(&jb, "{{\"needs_setup\":{s},\"authed\":{s}}}", .{
                if (auth_store.userCount() == 0) "true" else "false",
                if (authed) "true" else "false",
            }) catch return;
            sendJson(stream, j);
            return;
        }

        if (std.mem.eql(u8, sub, "logout")) {
            if (extractBearer(request)) |b| auth_store.revokeSession(b);
            sendJson(stream, "{\"ok\":true}");
            return;
        }

        if (std.mem.eql(u8, sub, "register") or std.mem.eql(u8, sub, "login")) {
            const body = requestBody(request);
            var ubuf: [96]u8 = undefined;
            var pbuf: [256]u8 = undefined;
            const username = credParam(body, query, "username", &ubuf) orelse {
                sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"missing username\"}");
                return;
            };
            const password = credParam(body, query, "password", &pbuf) orelse {
                sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"missing password\"}");
                return;
            };

            if (std.mem.eql(u8, sub, "register")) {
                // First-run only: the first account becomes the admin. Once any
                // account exists registration is closed (admin adds users later).
                if (auth_store.userCount() != 0) {
                    sendJsonStatus(stream, "403 Forbidden", "{\"error\":\"registration closed\"}");
                    return;
                }
                auth_store.createUser(username, password, true) catch |e| {
                    switch (e) {
                        error.Taken => sendJsonStatus(stream, "409 Conflict", "{\"error\":\"username taken\"}"),
                        error.Invalid => sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"username 3-32 chars [a-zA-Z0-9._-], password 8+ chars\"}"),
                        error.Db => sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"server error\"}"),
                    }
                    return;
                };
            }

            // Throttle guessing. bcrypt is slow but not slow enough to make an
            // unbounded loop pointless, and the server binds 0.0.0.0.
            const wait = loginRetryAfter(username);
            if (wait > 0) {
                var rb: [96]u8 = undefined;
                const r = std.fmt.bufPrint(&rb,
                    "{{\"error\":\"too many attempts — try again in {d}s\"}}", .{wait}) catch
                    "{\"error\":\"too many attempts\"}";
                sendJsonStatus(stream, "429 Too Many Requests", r);
                return;
            }
            const uid = auth_store.authenticate(username, password) orelse {
                loginNoteFailure(username);
                sendUnauthorized(stream);
                return;
            };
            loginNoteSuccess(username);
            var tok: [auth_store.TOKEN_HEX]u8 = undefined;
            if (!auth_store.issueSession(uid, &tok)) {
                sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"server error\"}");
                return;
            }
            var jb: [96]u8 = undefined;
            const j = std.fmt.bufPrint(&jb, "{{\"token\":\"{s}\"}}", .{tok[0..]}) catch return;
            sendJson(stream, j);
            return;
        }

        sendUnauthorized(stream);
        return;
    }

    // All other endpoints require Bearer auth: the static api.token (automation
    // / the browser extension) OR a live web-login session token.
    const presented = extractBearer(request) orelse {
        sendUnauthorized(stream);
        return;
    };
    if (!isAuthorized(presented)) {
        sendUnauthorized(stream);
        return;
    }

    // ── Access control (web UI › Setup › Access) ──
    // Deliberately after the Bearer gate: every one of these mutates auth
    // state, so an unauthenticated caller must never reach them.
    if (std.mem.startsWith(u8, path, "/api/access/")) {
        handleAccess(stream, path["/api/access/".len..], query, request, presented);
        return;
    }

    // Anti-block fetch, exposed to local automation and — the reason it exists —
    // to the nova2 Python engines, which have no way to reach Opal's anti-detect
    // browser from their own process. `uindex` and `one337x` answer 403 to a
    // plain urllib GET (measured: 1337x.to 403 on 7 of 10 tries), and no retry
    // policy can fix a bot wall. scrape_fetch already defeats exactly that for
    // the Zig scrapers; this is the same call, reachable over the API.
    //
    // Deliberately handled BEFORE the api_mutex block below: scrapeFetch blocks
    // up to ~45s on the browser fallback, and holding api_mutex for that long
    // would freeze every other endpoint (playback control included). It runs on
    // this connection thread, which satisfies scrapeFetch's worker-thread-only
    // contract — never the UI thread.
    if (std.mem.eql(u8, path, "/api/scrape")) {
        handleScrape(stream, query);
        return;
    }

    if (std.mem.startsWith(u8, path, "/api/")) {
        api_mutex.lock();
        defer api_mutex.unlock();
        handleApi(stream, path[4..], query, request);
    } else {
        const resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found";
        _ = io_g.streamWriteAll(stream, resp) catch {};
    }
}

fn getQueryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        var kv = std.mem.splitScalar(u8, pair, '=');
        const k = kv.next() orelse continue;
        const v = kv.next() orelse continue;
        if (std.mem.eql(u8, k, key)) return v;
    }
    return null;
}

/// Stash a URL + optional type/metadata for the UI thread to open. Backs both
/// /api/open and /api/ingest (browser extension): the UI thread consumes this
/// once, routing by `kind` (queue vs play) and, when meta is present, showing a
/// proper now-playing card via browser.loadContentDirectMeta. All strings must
/// already be percent-decoded. Empty `url` is a no-op. Wakes the idle UI loop.
fn stashRemoteOpen(url: []const u8, kind: []const u8, title: []const u8, art: []const u8, subtitle: []const u8) void {
    if (url.len == 0) return;
    state.app.remote_open_lock.lock();
    defer state.app.remote_open_lock.unlock();
    const n = @min(url.len, state.app.remote_open_path.len);
    @memcpy(state.app.remote_open_path[0..n], url[0..n]);
    state.app.remote_open_len = n;
    const kn = @min(kind.len, state.app.remote_open_type.len);
    @memcpy(state.app.remote_open_type[0..kn], kind[0..kn]);
    state.app.remote_open_type_len = kn;
    const tn = @min(title.len, state.app.remote_open_title.len);
    @memcpy(state.app.remote_open_title[0..tn], title[0..tn]);
    state.app.remote_open_title_len = tn;
    const an = @min(art.len, state.app.remote_open_art.len);
    @memcpy(state.app.remote_open_art[0..an], art[0..an]);
    state.app.remote_open_art_len = an;
    const sn = @min(subtitle.len, state.app.remote_open_subtitle.len);
    @memcpy(state.app.remote_open_subtitle[0..sn], subtitle[0..sn]);
    state.app.remote_open_subtitle_len = sn;
    state.app.remote_open_ready.store(true, .release);
    state.wakeUi(); // idle UI loop won't run a frame otherwise
}

fn handleApi(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8, request: []const u8) void {
    // The POST body, for the routes that take credentials. credParam() reads it
    // ahead of the query string so a debrid key or a GitHub token can be sent
    // where it will not be logged as part of a URL.
    const body = requestBody(request);
    // ── Non-player endpoints checked first ──
    // Search
    if (std.mem.eql(u8, api_path, "/search")) {
        apiSearch(stream, query);
        return;
    }
    if (std.mem.eql(u8, api_path, "/livetv")) {
        apiLiveTv(stream, query);
        return;
    }
    if (std.mem.startsWith(u8, api_path, "/ai")) {
        apiAi(stream, api_path, query);
        return;
    }
    if (std.mem.startsWith(u8, api_path, "/music")) {
        apiMusic(stream, api_path, query);
        return;
    }
    if (std.mem.startsWith(u8, api_path, "/radio")) {
        apiRadio(stream, api_path, query);
        return;
    }
    if (std.mem.eql(u8, api_path, "/history")) {
        apiHistory(stream);
        return;
    }
    if (std.mem.eql(u8, api_path, "/rss")) {
        apiRssList(stream);
        return;
    }
    if (std.mem.eql(u8, api_path, "/rss/refresh")) {
        const rss = @import("rss.zig");
        const idx_str = getQueryParam(query, "idx") orelse "0";
        const idx = std.fmt.parseInt(usize, idx_str, 10) catch 0;
        rss.fetchFeed(idx);
        sendJson(stream, "{\"ok\":true}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/downloads")) {
        apiDownloads(stream, query);
        return;
    }
    if (std.mem.eql(u8, api_path, "/downloads/play")) {
        apiDownloadsPlay(stream, query);
        return;
    }
    if (std.mem.eql(u8, api_path, "/download/url")) {
        // Direct HTTP download into the download dir via the segmented
        // downloader (services/download_engine.zig).
        if (getQueryParam(query, "url")) |raw| {
            var dec: [2048]u8 = undefined;
            const u = urlDecode(raw, &dec) orelse raw;
            const ok = @import("downloads.zig").startUrl(u);
            sendJson(stream, if (ok) "{\"ok\":true}" else "{\"ok\":false}");
        } else {
            sendJson(stream, "{\"ok\":false,\"error\":\"missing url\"}");
        }
        return;
    }
    // Host capabilities — lets the web client pick hosted (browser <video>)
    // vs companion (control the desktop player) behavior.
    if (std.mem.eql(u8, api_path, "/host")) {
        var jb: [128]u8 = undefined;
        const j = std.fmt.bufPrint(&jb, "{{\"headless\":{s},\"version\":\"0.1.2\"}}", .{
            if (state.app.is_headless) "true" else "false",
        }) catch return;
        sendJson(stream, j);
        return;
    }
    // Active torrents with live progress — the hosted download-then-stream
    // loop's status feed.
    if (std.mem.eql(u8, api_path, "/torrents")) {
        apiTorrents(stream);
        return;
    }
    // ── First-run setup over the API (hosted mode has no desktop Settings) ──
    if (std.mem.eql(u8, api_path, "/setup")) {
        var jb: [128]u8 = undefined;
        const j = std.fmt.bufPrint(&jb, "{{\"has_sources\":{s},\"has_tmdb\":{s}}}", .{
            if (@import("../core/source_config.zig").anyInstalled()) "true" else "false",
            if (state.app.tmdb.api_key_len > 0) "true" else "false",
        }) catch return;
        sendJson(stream, j);
        return;
    }
    if (std.mem.eql(u8, api_path, "/setup/sources")) {
        const n = @import("plugin_repo.zig").installStarterPack();
        var jb: [48]u8 = undefined;
        sendJson(stream, std.fmt.bufPrint(&jb, "{{\"installed\":{d}}}", .{n}) catch "{\"installed\":0}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/setup/tmdb")) {
        if (getQueryParam(query, "key")) |raw| {
            var dec: [400]u8 = undefined;
            const key = urlDecode(raw, &dec) orelse raw;
            if (key.len > 0) {
                state.setTmdbKey(key);
                state.markConfigDirty();
            }
        }
        sendJson(stream, "{\"ok\":true}");
        return;
    }
    // Coming-up rail (tv_calendar): next-episode countdowns + EZTV availability.
    if (std.mem.eql(u8, api_path, "/calendar")) {
        apiCalendar(stream);
        return;
    }
    // TV drill-down: pass the TMDB /tv/{id} (or season) JSON through verbatim —
    // the API key stays server-side; the client parses the standard TMDB shape.
    if (std.mem.eql(u8, api_path, "/tv")) {
        apiTvPassthrough(stream, query);
        return;
    }
    // The Watching library — tracked TV, anime and movies with progress and
    // what's next. Desktop parity for the `.watching` route.
    if (std.mem.eql(u8, api_path, "/library")) {
        apiLibrary(stream);
        return;
    }
    // Most recently aired episode of a show + whether it has been watched.
    // Backs the web show page's Play-latest button, and answers from the SAME
    // tv_library/tv_pure path the desktop button uses so the two can't disagree.
    if (std.mem.eql(u8, api_path, "/tv/recent")) {
        apiTvRecent(stream, query);
        return;
    }
    // Files inside a torrent, so the web player can stream one straight off
    // disk via /stream while it is still downloading.
    if (std.mem.eql(u8, api_path, "/transcode/available")) {
        sendJson(stream, if (@import("remote_stream.zig").haveFfmpeg())
            "{\"available\":true}"
        else
            "{\"available\":false}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/torrent/files")) {
        apiTorrentFiles(stream, query);
        return;
    }
    // Watch party (LAN sync) — desktop parity for the Scripts tab's host/join.
    if (std.mem.eql(u8, api_path, "/party")) {
        apiParty(stream, query);
        return;
    }
    // Installed source plugins + the debrid / repo integration config.
    if (std.mem.eql(u8, api_path, "/plugins")) {
        apiPlugins(stream, query, body);
        return;
    }
    // Settings › Web UI. Read-mostly on purpose: the only write is the kill
    // switch, and it needs confirm=1 because it ends the caller's own session.
    if (std.mem.eql(u8, api_path, "/webui")) {
        if (std.mem.eql(u8, getQueryParam(query, "action") orelse "", "disable")) {
            if (!std.mem.eql(u8, getQueryParam(query, "confirm") orelse "", "1")) {
                sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"disabling the web UI ends this session — pass confirm=1\"}");
                return;
            }
            state.app.web_remote_enabled = false;
            state.markConfigDirty();
            // Answer BEFORE stopping: stop() tears down the listener this
            // response is being written to, so the caller would otherwise see a
            // dropped connection and not know whether it worked.
            sendJson(stream, "{\"ok\":true,\"stopping\":true}");
            stop();
            return;
        }
        var out: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&out);
        w.print("{{\"enabled\":{s},\"running\":{s},\"port\":{d},\"address\":\"", .{
            if (state.app.web_remote_enabled) "true" else "false",
            if (isRunning()) "true" else "false",
            port,
        }) catch return;
        escJsonWrite(&w, lanIp());
        w.writeAll("\"}") catch return;
        sendJson(stream, out[0..w.end]);
        return;
    }
    // Live TV settings — the curated source list behind Settings › Live TV.
    // The /livetv *browser* was already covered; this is the part that decides
    // what is in the catalog at all.
    if (std.mem.eql(u8, api_path, "/livetv/sources")) {
        apiLiveTvSources(stream, query, body);
        return;
    }
    // Version + update state — the desktop Settings › About tab. GET only:
    // triggering a download of a new build from a remote session would install
    // software on someone else's machine, so `?action=check` is as far as it
    // goes and the actual update stays a desktop action.
    if (std.mem.eql(u8, api_path, "/about")) {
        const up = @import("updater.zig");
        if (std.mem.eql(u8, getQueryParam(query, "action") orelse "", "check")) up.checkAsync();
        var out: [512]u8 = undefined;
        var w = std.Io.Writer.fixed(&out);
        w.writeAll("{\"version\":\"") catch return;
        escJsonWrite(&w, up.APP_VERSION);
        w.writeAll("\",\"latest\":\"") catch return;
        escJsonWrite(&w, up.latestTag());
        w.print("\",\"has_update\":{s},\"checking\":{s},\"error\":\"", .{
            if (up.has_update) "true" else "false",
            if (up.is_checking) "true" else "false",
        }) catch return;
        escJsonWrite(&w, up.lastError());
        w.writeAll("\"}") catch return;
        sendJson(stream, out[0..w.end]);
        return;
    }
    // Trakt: scrobbling + watch-status sync. GET reports connection state; POST
    // takes ?action=connect|disconnect or a client_id/client_secret write.
    if (std.mem.eql(u8, api_path, "/trakt")) {
        apiTrakt(stream, query, body);
        return;
    }
    // Suwayomi: the manga extension server Opal can run for you. GET reports
    // status; POST takes ?action=start|stop.
    if (std.mem.eql(u8, api_path, "/suwayomi")) {
        apiSuwayomi(stream, query, body);
        return;
    }
    // Home hub: at-a-glance counts + what to continue.
    if (std.mem.eql(u8, api_path, "/home")) {
        apiHome(stream);
        return;
    }
    // Web settings: GET the whole registry with current values, POST one key.
    // Desktop parity for the Playback / Subtitles / Network settings tabs.
    if (std.mem.eql(u8, api_path, "/settings")) {
        apiSettings(stream, query);
        return;
    }
    if (std.mem.eql(u8, api_path, "/settings/toggle")) {
        apiSettingsToggle(query);
        sendJson(stream, "{\"ok\":true}");
        return;
    }
    // Single-instance forwarding: a second `opal <path>` launch posts its
    // argument here and exits (main.zig forwardToRunningInstance). Deferred to
    // the UI thread instead of driving mpv directly so the open runs through
    // browser.loadContent exactly like a direct CLI launch (magnet/torrent/
    // playlist dispatch included).
    if (std.mem.eql(u8, api_path, "/open")) {
        // Accept `url` as an alias for `path`: the browser extension (and this
        // endpoint's documented shape) POST /api/open?url=<enc>, while the web
        // UI uses ?path=. Both route through the same UI-thread hand-off.
        // Optional `title`/`art`/`subtitle` (browser extension rich-metadata
        // send) render a proper now-playing card instead of a bare URL.
        if (getQueryParam(query, "path") orelse getQueryParam(query, "url")) |raw| {
            var dec_buf: [2048]u8 = undefined;
            const decoded = urlDecode(raw, &dec_buf) orelse raw;
            var title_buf: [512]u8 = undefined;
            const title = if (getQueryParam(query, "title")) |t| (urlDecode(t, &title_buf) orelse "") else "";
            var art_buf: [1024]u8 = undefined;
            const art = if (getQueryParam(query, "art")) |a| (urlDecode(a, &art_buf) orelse "") else "";
            var sub_buf: [256]u8 = undefined;
            const subtitle = if (getQueryParam(query, "subtitle")) |s| (urlDecode(s, &sub_buf) orelse "") else "";
            stashRemoteOpen(decoded, "media", title, art, subtitle);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"open\"}");
        return;
    }
    // Opt-in SFW manga source catalog — a curated array of
    // {name,base,framework,lang} for Madara/MangaThemesia/HeanCms sites the user
    // can browse and install. NOT auto-loaded: install an entry by POSTing its
    // base+framework to /source/add below (that writes source_config). Empty
    // array when the catalog file isn't bundled.
    if (std.mem.eql(u8, api_path, "/source/catalog")) {
        if (@import("plugin_repo.zig").readMangaCatalog()) |catalog| {
            defer @import("../core/alloc.zig").allocator.free(catalog);
            sendJson(stream, catalog);
        } else {
            sendJson(stream, "[]");
        }
        return;
    }
    // "Add this site as an Opal source" — the extension detects the manga/novel
    // framework a page uses and installs it as a source in one click. framework
    // ∈ {madara,mangathemesia,heancms,madara_novel,lightnovelwp,readwn} maps 1:1
    // to the source_config id each engine reads; base is the site origin.
    if (std.mem.eql(u8, api_path, "/source/add")) {
        var fw_buf: [32]u8 = undefined;
        const framework = if (getQueryParam(query, "framework")) |f| (urlDecode(f, &fw_buf) orelse "") else "";
        const valid_fw = std.mem.eql(u8, framework, "madara") or
            std.mem.eql(u8, framework, "mangathemesia") or
            std.mem.eql(u8, framework, "heancms") or
            std.mem.eql(u8, framework, "madara_novel") or
            std.mem.eql(u8, framework, "lightnovelwp") or
            std.mem.eql(u8, framework, "readwn");
        var base_buf: [512]u8 = undefined;
        const base = if (getQueryParam(query, "base")) |b| (urlDecode(b, &base_buf) orelse "") else "";
        const valid_base = std.mem.startsWith(u8, base, "http://") or std.mem.startsWith(u8, base, "https://");
        if (!valid_fw or !valid_base) {
            sendJson(stream, "{\"ok\":false,\"error\":\"need framework∈{madara,mangathemesia,heancms,madara_novel,lightnovelwp,readwn} and an http(s) base\"}");
            return;
        }
        // Flat JSON body {"base":"<origin>"}, origin escaped so it can't break JSON.
        var body_buf: [640]u8 = undefined;
        var bw = std.Io.Writer.fixed(&body_buf);
        bw.writeAll("{\"base\":\"") catch return;
        escJsonWrite(&bw, base);
        bw.writeAll("\"}") catch return;
        const ok = @import("../core/source_config.zig").install(framework, body_buf[0..bw.end]);
        var jb: [96]u8 = undefined;
        // framework is from the fixed whitelist above → safe to echo verbatim.
        const j = std.fmt.bufPrint(&jb, "{{\"ok\":{s},\"framework\":\"{s}\"}}", .{ if (ok) "true" else "false", framework }) catch "{\"ok\":false}";
        sendJson(stream, j);
        return;
    }
    // Scrape/ingest from the browser extension: route a page's media/article/
    // chapter data into Opal. Body fields arrive as query params (the server
    // reads the request line + headers, not a JSON body) — see /api/open. The
    // URL (page/media URL, or the first chapter) is dispatched through the same
    // UI-thread hand-off as /open so it runs the full browser.loadContent path.
    if (std.mem.eql(u8, api_path, "/ingest")) {
        var type_buf: [32]u8 = undefined;
        const raw_type = if (getQueryParam(query, "type")) |t| (urlDecode(t, &type_buf) orelse "media") else "media";
        // Clamp to the known set so the echoed value can't inject into the JSON,
        // and so the UI-thread router only sees types it knows. The extension
        // classifies the page (content.ts) and sends the hint here.
        const ingest_type = if (std.mem.eql(u8, raw_type, "article") or
            std.mem.eql(u8, raw_type, "chapters") or
            std.mem.eql(u8, raw_type, "manga") or
            std.mem.eql(u8, raw_type, "novel") or
            std.mem.eql(u8, raw_type, "anime") or
            std.mem.eql(u8, raw_type, "video") or
            std.mem.eql(u8, raw_type, "magnet") or
            std.mem.eql(u8, raw_type, "queue"))
            raw_type
        else
            "media";
        if (getQueryParam(query, "url")) |raw| {
            var dec_buf: [2048]u8 = undefined;
            const decoded = urlDecode(raw, &dec_buf) orelse raw;
            var title_buf: [512]u8 = undefined;
            const title = if (getQueryParam(query, "title")) |t| (urlDecode(t, &title_buf) orelse "") else "";
            var art_buf: [1024]u8 = undefined;
            const art = if (getQueryParam(query, "art")) |a| (urlDecode(a, &art_buf) orelse "") else "";
            var sub_buf: [256]u8 = undefined;
            const subtitle = if (getQueryParam(query, "subtitle")) |s| (urlDecode(s, &sub_buf) orelse "") else "";
            // queue → the UI thread adds to the watch queue instead of playing;
            // every other type routes through loadContent (with meta if given).
            stashRemoteOpen(decoded, ingest_type, title, art, subtitle);
        }
        var jb: [96]u8 = undefined;
        const j = std.fmt.bufPrint(&jb, "{{\"ok\":true,\"action\":\"ingest\",\"type\":\"{s}\"}}", .{ingest_type}) catch "{\"ok\":true,\"action\":\"ingest\"}";
        sendJson(stream, j);
        return;
    }
    if (std.mem.eql(u8, api_path, "/settings/open")) {
        state.app.settings_open = true;
        sendJson(stream, "{\"ok\":true,\"action\":\"settings_open\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/settings/close")) {
        state.app.settings_open = false;
        sendJson(stream, "{\"ok\":true,\"action\":\"settings_close\"}");
        return;
    }
    // TMDB
    if (std.mem.startsWith(u8, api_path, "/tmdb")) {
        apiTmdb(stream, api_path, query);
        return;
    }
    // YouTube
    if (std.mem.startsWith(u8, api_path, "/youtube")) {
        apiYoutube(stream, api_path, query);
        return;
    }
    // Anime
    if (std.mem.startsWith(u8, api_path, "/anime")) {
        apiAnime(stream, api_path, query);
        return;
    }
    // Podcasts
    if (std.mem.startsWith(u8, api_path, "/podcasts")) {
        apiPodcasts(stream, api_path, query);
        return;
    }
    // Comics
    if (std.mem.startsWith(u8, api_path, "/comics")) {
        apiComics(stream, api_path, query);
        return;
    }
    // Server logs — the desktop Logs tab, over HTTP. Especially load-bearing
    // headless, where `docker logs` only carries stdout.
    if (std.mem.startsWith(u8, api_path, "/logs")) {
        apiLogs(stream, api_path, query);
        return;
    }
    // Visual novels (catalog only — VNs aren't launchable).
    if (std.mem.startsWith(u8, api_path, "/vndb")) {
        apiVndb(stream, api_path, query);
        return;
    }
    // Asian drama catalog.
    if (std.mem.startsWith(u8, api_path, "/drama")) {
        apiDrama(stream, api_path, query);
        return;
    }
    // Novels — search → chapters → reader.
    if (std.mem.startsWith(u8, api_path, "/novels")) {
        apiNovels(stream, api_path, query);
        return;
    }
    // Self-hosted servers: Audiobookshelf, OPDS catalogs, Plex.
    if (std.mem.startsWith(u8, api_path, "/abs")) {
        apiAbs(stream, api_path, query);
        return;
    }
    if (std.mem.startsWith(u8, api_path, "/opds")) {
        apiOpds(stream, api_path, query);
        return;
    }
    if (std.mem.startsWith(u8, api_path, "/plex")) {
        apiPlex(stream, api_path, query);
        return;
    }
    // Jellyfin
    if (std.mem.startsWith(u8, api_path, "/jellyfin")) {
        apiJellyfin(stream, api_path, query);
        return;
    }
    // Unified Search — fans out to all sources
    if (std.mem.eql(u8, api_path, "/unified_search")) {
        apiUnifiedSearch(stream, query);
        return;
    }
    if (std.mem.eql(u8, api_path, "/recommendations")) {
        apiRecommendations(stream, query);
        return;
    }
    // Watch party + cast — deliberately ABOVE the players_mutex tail: party
    // status and device discovery are meaningful with nothing playing, and the
    // tail's "no player" early-return would have answered them all with an error.
    if (std.mem.startsWith(u8, api_path, "/party/") or std.mem.startsWith(u8, api_path, "/cast/")) {
        apiPartyCast(stream, api_path, query);
        return;
    }

    // ── Player-dependent endpoints ──
    // Hold players_mutex across the whole dispatch below: the UI thread frees
    // players at frame top (main.zig), so without this the captured `ap` could
    // become a dangling *MediaPlayer mid-mpv-call → use-after-free. defer covers
    // every exit path of this tail section (the chain runs to the function end).
    state.players_mutex.lock();
    defer state.players_mutex.unlock();
    if (state.app.active_player_idx >= state.app.players.items.len) {
        sendJson(stream, "{\"error\":\"no player\"}");
        return;
    }
    const ap = state.app.players.items[state.app.active_player_idx];

    // ── Player controls ──
    if (std.mem.eql(u8, api_path, "/toggle")) {
        _ = c.mpv.mpv_command_string(ap.mpv_ctx, "cycle pause");
        sendJson(stream, "{\"ok\":true,\"action\":\"toggle\"}");
    } else if (std.mem.eql(u8, api_path, "/playpause")) {
        // Browser-extension side-panel remote: toggle the active player's pause.
        // Held under players_mutex (this whole tail section) so the UI thread
        // can't free the player mid-call.
        _ = c.mpv.mpv_command_string(ap.mpv_ctx, "cycle pause");
        sendJson(stream, "{\"ok\":true,\"action\":\"playpause\"}");
    } else if (std.mem.eql(u8, api_path, "/fwd")) {
        _ = c.mpv.mpv_command_string(ap.mpv_ctx, "seek 10");
        sendJson(stream, "{\"ok\":true,\"action\":\"fwd\"}");
    } else if (std.mem.eql(u8, api_path, "/back")) {
        _ = c.mpv.mpv_command_string(ap.mpv_ctx, "seek -10");
        sendJson(stream, "{\"ok\":true,\"action\":\"back\"}");
    } else if (std.mem.eql(u8, api_path, "/vol_up")) {
        _ = c.mpv.mpv_command_string(ap.mpv_ctx, "add volume 5");
        sendJson(stream, "{\"ok\":true,\"action\":\"vol_up\"}");
    } else if (std.mem.eql(u8, api_path, "/vol_down")) {
        _ = c.mpv.mpv_command_string(ap.mpv_ctx, "add volume -5");
        sendJson(stream, "{\"ok\":true,\"action\":\"vol_down\"}");
    } else if (std.mem.eql(u8, api_path, "/mute")) {
        _ = c.mpv.mpv_command_string(ap.mpv_ctx, "cycle mute");
        sendJson(stream, "{\"ok\":true,\"action\":\"mute\"}");
    } else if (std.mem.eql(u8, api_path, "/fullscreen")) {
        state.app.fullscreen_player_idx = if (state.app.fullscreen_player_idx == null) state.app.active_player_idx else null;
        sendJson(stream, "{\"ok\":true,\"action\":\"fullscreen\"}");
    } else if (std.mem.eql(u8, api_path, "/next_audio")) {
        _ = c.mpv.mpv_command_string(ap.mpv_ctx, "cycle audio");
        sendJson(stream, "{\"ok\":true,\"action\":\"next_audio\"}");
    } else if (std.mem.eql(u8, api_path, "/next_sub")) {
        _ = c.mpv.mpv_command_string(ap.mpv_ctx, "cycle sub");
        sendJson(stream, "{\"ok\":true,\"action\":\"next_sub\"}");
    } else if (std.mem.eql(u8, api_path, "/flip")) {
        ap.toggleFlip();
        sendJson(stream, "{\"ok\":true,\"action\":\"flip\"}");
    } else if (std.mem.eql(u8, api_path, "/rotate")) {
        ap.cycleRotation();
        sendJson(stream, "{\"ok\":true,\"action\":\"rotate\"}");

        // ── Volume set ──
    } else if (std.mem.eql(u8, api_path, "/volume")) {
        if (getQueryParam(query, "v")) |v_str| {
            const vol = std.fmt.parseFloat(f64, v_str) catch return;
            if (vol < 0 or vol > 150) return;
            var cmd_buf: [64]u8 = undefined;
            const cmd = std.fmt.bufPrintZ(&cmd_buf, "set volume {d:.1}", .{vol}) catch return;
            _ = c.mpv.mpv_command_string(ap.mpv_ctx, cmd.ptr);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"volume\"}");

        // ── Seek by percentage ──
    } else if (std.mem.eql(u8, api_path, "/seek_pct")) {
        if (getQueryParam(query, "v")) |v_str| {
            const pct = std.fmt.parseInt(i32, v_str, 10) catch 0;
            var dur: f64 = 0;
            _ = c.mpv.mpv_get_property(ap.mpv_ctx, "duration", c.mpv.MPV_FORMAT_DOUBLE, &dur);
            if (dur > 0) {
                const target = dur * @as(f64, @floatFromInt(pct)) / 100.0;
                var cmd_buf: [64]u8 = undefined;
                const cmd = std.fmt.bufPrintZ(&cmd_buf, "seek {d:.1} absolute", .{target}) catch return;
                _ = c.mpv.mpv_command_string(ap.mpv_ctx, cmd.ptr);
            }
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"seek_pct\"}");

        // ── Load URL/magnet ──
    } else if (std.mem.eql(u8, api_path, "/load")) {
        // Body first, then query. A magnet is long and full of & and %; putting
        // it in a POST body is what a non-browser client naturally does, and this
        // route used to read the query ONLY — a POSTed url silently matched
        // nothing and still answered ok:true, so the caller saw success and the
        // player never moved.
        var dec_buf: [2048]u8 = undefined;
        if (credParam(body, query, "url", &dec_buf)) |decoded| {
            if (decoded.len == 0) {
                sendJson(stream, "{\"ok\":false,\"error\":\"empty url\"}");
                return;
            }
            // A magnet is not a file. This handed every magnet straight to mpv,
            // which treated the whole URI as a path and failed with "File name
            // too long" — so tapping ANY torrent search result in the web UI did
            // nothing but log an error. The desktop has always branched here
            // (ui/header.zig on drop/paste, services/search.zig on a result
            // click); routing through the same entry point keeps the two in step
            // rather than reimplementing the player/session setup.
            if (std.mem.startsWith(u8, decoded, "magnet:")) {
                @import("search.zig").loadTorrentToPlayer(decoded);
            } else {
                var url_buf: [2049]u8 = undefined;
                const url_z = std.fmt.bufPrintZ(&url_buf, "{s}", .{decoded}) catch return;
                ap.load_file(url_z.ptr);
            }
            // This ran on the connection thread; the UI loop blocks when idle, so
            // without a wake the loading screen (and, for a torrent, the whole
            // handoff to mpv) waited for the user to move the mouse.
            state.wakeUi();
            sendJson(stream, "{\"ok\":true,\"action\":\"load\"}");
            return;
        }
        // No url at all: say so rather than reporting a load that never happened.
        sendJson(stream, "{\"ok\":false,\"error\":\"missing url\"}");

        // ── Status (enhanced) ──
    } else if (std.mem.eql(u8, api_path, "/status")) {
        var json: [512]u8 = undefined;
        sendJson(stream, buildStatusJson(&json));

        // ── Queue ──
    } else if (std.mem.eql(u8, api_path, "/queue/move")) {
        const q = @import("queue.zig");
        const idx = std.fmt.parseInt(usize, getQueryParam(query, "idx") orelse "999", 10) catch 999;
        const dir: i32 = if (std.mem.eql(u8, getQueryParam(query, "dir") orelse "", "up")) -1 else 1;
        q.moveQueueItem(idx, dir);
        sendJson(stream, "{\"ok\":true}");
    } else if (std.mem.eql(u8, api_path, "/queue")) {
        const queue_svc = @import("queue.zig");
        var json_buf: [8192]u8 = undefined;
        var w = std.Io.Writer.fixed(&json_buf);
        w.writeAll("{\"items\":[") catch return;
        var i: usize = 0;
        while (i < queue_svc.queue_count) : (i += 1) {
            const item = queue_svc.queue_items[i];
            if (i > 0) w.writeAll(",") catch return;
            w.writeAll("{\"url\":\"") catch return;
            escJsonWrite(&w, item.url[0..item.url_len]);
            w.print("\",\"played\":{s}}}", .{
                if (item.played) "true" else "false",
            }) catch return;
        }
        w.writeAll("]}") catch return;
        sendJson(stream, json_buf[0..w.end]);

        // Watch party + cast dispatch earlier (apiPartyCast) — they must work
        // with no player loaded, so they never reach this tail.
    } else {
        sendJson(stream, "{\"error\":\"unknown\"}");
    }
}

fn sendJson(stream: std.Io.net.Stream, json: []const u8) void {
    var header: [256]u8 = undefined;
    const h = std.fmt.bufPrint(&header, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nContent-Length: {d}\r\n\r\n", .{json.len}) catch return;
    _ = @import("../core/io_global.zig").streamWriteAll(stream, h) catch {};
    _ = @import("../core/io_global.zig").streamWriteAll(stream, json) catch {};
}

/// GET /api/scrape?url=<percent-encoded> → the page body, fetched through
/// scrape_fetch (plain curl fast path, anti-detect browser when the response is
/// a Cloudflare / DDoS-Guard / captcha interstitial).
///
/// Exists for the nova2 Python engines: they run in a child process and cannot
/// call browser.fetchHtmlBlocking, so a walled site is simply zero rows for
/// them. `helpers.retrieve_url` falls back here when a fetch comes back walled.
///
/// Body is returned as-is with `text/plain` — the caller is a scraper parsing
/// HTML/JSON, and text/plain keeps a browser from ever rendering a scraped page
/// as live markup from Opal's own origin. 502 when nothing could be fetched, so
/// the caller can tell "walled and unrecoverable" from "empty page".
fn handleScrape(stream: std.Io.net.Stream, query: []const u8) void {
    handleScrapeBody(stream, query, null);
}

/// `post` is the form body to replay, or null for a GET. Sites that only emit
/// what a scraper needs in response to a POST (EZTV gates its magnet links
/// behind `layout=def_wlinks`) are unreachable over GET no matter how well the
/// challenge is cleared.
fn handleScrapeBody(stream: std.Io.net.Stream, query: []const u8, post: ?[]const u8) void {
    var dec_buf: [2048]u8 = undefined;
    const raw = getQueryParam(query, "url") orelse {
        sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"url required\"}");
        return;
    };
    const url = urlDecode(raw, &dec_buf) orelse raw;
    if (url.len == 0 or !(std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://"))) {
        sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"url must be http(s)\"}");
        return;
    }

    // 2 MB: a torrent search page with 250 rows measured 722 KB (torrentfunk),
    // so this has room for the largest listing observed with headroom. Heap, not
    // stack — this runs on a connection thread (see the CLAUDE.md 64KB rule).
    const cap = 2 * 1024 * 1024;
    const alloc = @import("../core/alloc.zig").allocator;
    const buf = alloc.alloc(u8, cap) catch {
        sendJsonStatus(stream, "503 Service Unavailable", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(buf);

    const sf = @import("scrape_fetch.zig");
    const body = (if (post) |p| sf.scrapeFetchPost(url, p, buf) else sf.scrapeFetch(url, buf)) orelse {
        sendJsonStatus(stream, "502 Bad Gateway", "{\"error\":\"fetch failed\"}");
        return;
    };

    var header: [256]u8 = undefined;
    const h = std.fmt.bufPrint(&header, "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\n\r\n", .{body.len}) catch return;
    _ = io_g.streamWriteAll(stream, h) catch {};
    _ = io_g.streamWriteAll(stream, body) catch {};
}

/// Like sendJson but with a caller-chosen status line (e.g. "409 Conflict").
fn sendJsonStatus(stream: std.Io.net.Stream, status: []const u8, json: []const u8) void {
    var header: [256]u8 = undefined;
    const h = std.fmt.bufPrint(&header, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {d}\r\n\r\n", .{ status, json.len }) catch return;
    _ = io_g.streamWriteAll(stream, h) catch {};
    _ = io_g.streamWriteAll(stream, json) catch {};
}

/// True if the presented Bearer token is the static api.token (automation /
/// extension) OR a live web-login session token.
fn isAuthorized(token: []const u8) bool {
    if (api_token_ready.load(.acquire) and constantTimeEqual(token, api_token[0..])) return true;
    return @import("auth_store.zig").validSession(token);
}

/// Bytes after the HTTP header terminator (the request body), or "".
fn requestBody(request: []const u8) []const u8 {
    if (std.mem.indexOf(u8, request, "\r\n\r\n")) |i| return request[i + 4 ..];
    return "";
}

/// A credential param from the POST body (form-encoded) then the query, decoded.
/// Body-first keeps passwords out of the URL / access logs.
/// Failed-login throttle state. Guarded because every connection runs on its
/// own thread and they all touch the same table.
var login_rate_table: login_rate.Table = .{};
var login_rate_mutex: @import("../core/sync.zig").Mutex = .{};

/// 0 when the attempt may proceed, else the seconds left on the lockout.
fn loginRetryAfter(username: []const u8) i64 {
    login_rate_mutex.lock();
    defer login_rate_mutex.unlock();
    return login_rate.retryAfter(&login_rate_table, username, io_g.timestamp());
}

fn loginNoteFailure(username: []const u8) void {
    login_rate_mutex.lock();
    defer login_rate_mutex.unlock();
    _ = login_rate.recordFailure(&login_rate_table, username, io_g.timestamp());
}

fn loginNoteSuccess(username: []const u8) void {
    login_rate_mutex.lock();
    defer login_rate_mutex.unlock();
    login_rate.recordSuccess(&login_rate_table, username);
}

fn credParam(body: []const u8, query: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    const raw = getQueryParam(body, key) orelse getQueryParam(query, key) orelse return null;
    return urlDecode(raw, out) orelse raw;
}

/// `/api/access/*` — the web UI's Access page (Setup › Access).
///
/// Two classes of caller reach this, and they get different powers:
///
///   * A **session** token (someone logged into the web UI). Scoped to their
///     own account, and must prove the current password to change it.
///   * The **api.token** (machine-local, 0600 in ~/.config/opal). Its holder
///     already has filesystem access to this machine, so they may reset ANY
///     account's password without knowing the old one. That is deliberate: it
///     is the only recovery path for a forgotten web password, which would
///     otherwise permanently lock the account out with no reset mechanism.
fn handleAccess(
    stream: std.Io.net.Stream,
    sub: []const u8,
    query: []const u8,
    request: []const u8,
    presented: []const u8,
) void {
    const auth_store = @import("auth_store.zig");
    const body = requestBody(request);
    // Null when the caller authenticated with api.token rather than a login.
    const caller_uid = auth_store.userIdForSession(presented);

    // ── status: everything the Access page renders in one round trip.
    if (std.mem.eql(u8, sub, "status")) {
        var name_buf: [96]u8 = undefined;
        const username = if (caller_uid) |uid| (auth_store.usernameForId(uid, &name_buf) orelse "") else "";
        var mask_buf: [64]u8 = undefined;
        const masked = access_pure.maskToken(tokenHex(), &mask_buf);
        var jb: [512]u8 = undefined;
        const j = std.fmt.bufPrint(&jb,
            \\{{"username":"{s}","via_token":{s},"sessions":{d},"token_masked":"{s}","bind":"{s}","port":{d},"lan_ip":"{s}","running":{s}}}
        , .{
            username,
            if (caller_uid == null) "true" else "false",
            auth_store.liveSessionCount(),
            masked,
            bind_mode.id(),
            port,
            lanIp(),
            if (isRunning()) "true" else "false",
        }) catch return;
        sendJson(stream, j);
        return;
    }

    // ── password: change (session caller) or reset (api.token caller).
    if (std.mem.eql(u8, sub, "password")) {
        var cur_buf: [256]u8 = undefined;
        var new_buf: [256]u8 = undefined;
        var conf_buf: [256]u8 = undefined;
        var user_buf: [96]u8 = undefined;
        const current = credParam(body, query, "current", &cur_buf) orelse "";
        const new_pw = credParam(body, query, "password", &new_buf) orelse {
            sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"missing password\"}");
            return;
        };
        const confirm = credParam(body, query, "confirm", &conf_buf) orelse new_pw;

        const verdict = access_pure.checkPasswordChange(current, new_pw, confirm);
        if (verdict != .ok) {
            var eb: [160]u8 = undefined;
            const e = std.fmt.bufPrint(&eb, "{{\"error\":\"{s}\"}}", .{verdict.message()}) catch return;
            sendJsonStatus(stream, "400 Bad Request", e);
            return;
        }

        const target_uid: i64 = if (caller_uid) |uid| blk: {
            // Session caller: prove the current password before replacing it,
            // so a stolen/left-open session cannot lock the owner out.
            var nb: [96]u8 = undefined;
            const uname = auth_store.usernameForId(uid, &nb) orelse {
                sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"server error\"}");
                return;
            };
            const wait = loginRetryAfter(uname);
            if (wait > 0) {
                sendJsonStatus(stream, "429 Too Many Requests", "{\"error\":\"too many attempts — wait a few minutes\"}");
                return;
            }
            if (auth_store.authenticate(uname, current) == null) {
                // Same throttle as login: this check is a password oracle too.
                loginNoteFailure(uname);
                sendJsonStatus(stream, "403 Forbidden", "{\"error\":\"current password is incorrect\"}");
                return;
            }
            loginNoteSuccess(uname);
            break :blk uid;
        } else blk: {
            // api.token caller: machine-local recovery, no old password needed.
            const uname = credParam(body, query, "username", &user_buf) orelse {
                sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"missing username\"}");
                return;
            };
            break :blk auth_store.userIdByName(uname) orelse {
                sendJsonStatus(stream, "404 Not Found", "{\"error\":\"no such user\"}");
                return;
            };
        };

        if (!auth_store.setPassword(target_uid, new_pw)) {
            sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"could not set password\"}");
            return;
        }
        // Every other device's session is now stale by intent — a password
        // change that left old logins working would not actually revoke access.
        const dropped = auth_store.revokeAllSessions(if (caller_uid == null) null else presented);
        logs.pushLog("info", "remote", "Web UI password changed; other sessions revoked", false);
        var jb: [96]u8 = undefined;
        const j = std.fmt.bufPrint(&jb, "{{\"ok\":true,\"revoked\":{d}}}", .{dropped}) catch return;
        sendJson(stream, j);
        return;
    }

    // ── revoke-all: sign out every other device, keeping this one signed in.
    if (std.mem.eql(u8, sub, "revoke-all")) {
        const dropped = auth_store.revokeAllSessions(if (caller_uid == null) null else presented);
        logs.pushLog("info", "remote", "Web UI sessions revoked", false);
        var jb: [64]u8 = undefined;
        const j = std.fmt.bufPrint(&jb, "{{\"ok\":true,\"revoked\":{d}}}", .{dropped}) catch return;
        sendJson(stream, j);
        return;
    }

    // ── token: reveal in full (caller is already authenticated) / rotate.
    if (std.mem.eql(u8, sub, "token")) {
        var jb: [96]u8 = undefined;
        const j = std.fmt.bufPrint(&jb, "{{\"token\":\"{s}\"}}", .{tokenHex()}) catch return;
        sendJson(stream, j);
        return;
    }
    if (std.mem.eql(u8, sub, "token/rotate")) {
        if (!rotateToken()) {
            sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"no entropy source\"}");
            return;
        }
        var jb: [96]u8 = undefined;
        const j = std.fmt.bufPrint(&jb, "{{\"ok\":true,\"token\":\"{s}\"}}", .{tokenHex()}) catch return;
        sendJson(stream, j);
        return;
    }

    // ── bind: loopback-only vs LAN, and the port.
    if (std.mem.eql(u8, sub, "bind")) {
        var mode_buf: [32]u8 = undefined;
        var port_buf: [16]u8 = undefined;
        const mode = if (credParam(body, query, "mode", &mode_buf)) |m|
            access_pure.bindModeFromString(m)
        else
            bind_mode;
        const new_port: u16 = if (credParam(body, query, "port", &port_buf)) |p|
            (access_pure.parsePort(p) orelse {
                sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"port must be 1024-65535\"}");
                return;
            })
        else
            port;

        // Respond BEFORE rebinding: applyBinding tears down the very listener
        // this response is travelling over, so a reply written after it would
        // never reach the browser.
        var jb: [128]u8 = undefined;
        const j = std.fmt.bufPrint(&jb, "{{\"ok\":true,\"bind\":\"{s}\",\"port\":{d}}}", .{ mode.id(), new_port }) catch return;
        sendJson(stream, j);
        applyBinding(mode, new_port);
        state.markConfigDirty(); // persisted as web_bind / web_port
        return;
    }

    sendJsonStatus(stream, "404 Not Found", "{\"error\":\"unknown access route\"}");
}

// Placeholder in the served HTML that the page reads to obtain its bearer
// token. Replaced at serve time with the live api_token so the web UI can
// authenticate without the token ever being committed to disk in the page.
const TOKEN_PLACEHOLDER = "__ZIGZAG_API_TOKEN__";

fn serveStaticFile(stream: std.Io.net.Stream, path: []const u8, content_type: []const u8) void {
    const alloc = @import("../core/alloc.zig").allocator;
    const file = @import("../core/io_global.zig").cwdOpenFile(path, .{}) catch {
        const resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found";
        _ = @import("../core/io_global.zig").streamWriteAll(stream, resp) catch {};
        return;
    };
    defer file.close(@import("../core/io_global.zig").io());
    const raw = @import("../core/io_global.zig").readToEndAlloc(file, alloc, 4 * 1024 * 1024) catch return;
    defer alloc.free(raw);

    // No token injection: since the server binds the LAN (opt-in), a page
    // carrying the bearer token would hand full control to any device that
    // GETs `/`. The page bootstraps via account login (/api/auth) instead.
    const body: []const u8 = raw;

    // SECURITY: deliberately NO `Access-Control-Allow-Origin` here — a
    // cross-origin site the user visits must not be able to read this body.
    // The token-gated JSON API still sends CORS, for the browser extension and
    // external automation; this static-asset path deliberately does not.
    var header: [512]u8 = undefined;
    const h = std.fmt.bufPrint(&header, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nX-Content-Type-Options: nosniff\r\nContent-Length: {d}\r\n\r\n", .{ content_type, body.len }) catch return;
    _ = @import("../core/io_global.zig").streamWriteAll(stream, h) catch {};
    _ = @import("../core/io_global.zig").streamWriteAll(stream, body) catch {};
}

fn urlDecode(src: []const u8, buf: []u8) ?[]const u8 {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len and o < buf.len) {
        if (src[i] == '%' and i + 2 < src.len) {
            buf[o] = std.fmt.parseInt(u8, src[i + 1 .. i + 3], 16) catch {
                buf[o] = src[i];
                i += 1;
                o += 1;
                continue;
            };
            i += 3;
            o += 1;
        } else if (src[i] == '+') {
            buf[o] = ' ';
            i += 1;
            o += 1;
        } else {
            buf[o] = src[i];
            i += 1;
            o += 1;
        }
    }
    if (o == 0) return null;
    return buf[0..o];
}

/// Write `s` to `w` as the *contents* of a JSON string (no surrounding
/// quotes), escaping `"`, `\`, and control chars < 0x20 so the result is
/// always valid JSON. Callers emit their own quotes around it.
fn escJsonWrite(w: *std.Io.Writer, s: []const u8) void {
    for (s) |ch| {
        switch (ch) {
            '"' => w.writeAll("\\\"") catch return,
            '\\' => w.writeAll("\\\\") catch return,
            '\n' => w.writeAll("\\n") catch return,
            '\r' => w.writeAll("\\r") catch return,
            '\t' => w.writeAll("\\t") catch return,
            0x08 => w.writeAll("\\b") catch return,
            0x0c => w.writeAll("\\f") catch return,
            else => {
                if (ch < 0x20) {
                    w.print("\\u{x:0>4}", .{ch}) catch return;
                } else {
                    w.writeByte(ch) catch return;
                }
            },
        }
    }
}

// ══════════════════════════════════════════════════
// Non-player API handlers
// ══════════════════════════════════════════════════

fn apiSearch(stream: std.Io.net.Stream, query: []const u8) void {
    if (getQueryParam(query, "q")) |q| {
        const search_svc = @import("search.zig");
        var decoded: [256]u8 = undefined;
        const dq = urlDecode(q, &decoded) orelse q;
        search_svc.triggerSearch(dq);
    }
    const search_svc = @import("search.zig");
    search_svc.search_results_mutex.lock();
    defer search_svc.search_results_mutex.unlock();
    var json_buf: [32768]u8 = undefined;
    var w = std.Io.Writer.fixed(&json_buf);
    w.writeAll("{\"results\":[") catch return;
    var count: usize = 0;
    for (search_svc.search_results.items) |r| {
        // Reserve tail space so the closing `],"searching":…}` always fits —
        // stop adding items rather than truncate into invalid JSON mid-array.
        if (w.end + 2048 > json_buf.len) break;
        if (count > 0) w.writeAll(",") catch return;
        w.writeAll("{\"title\":\"") catch return;
        escJsonWrite(&w, r.name);
        w.writeAll("\",\"size\":\"") catch return;
        escJsonWrite(&w, r.size);
        w.writeAll("\",\"seeds\":\"") catch return;
        escJsonWrite(&w, r.seeds);
        w.writeAll("\",\"source\":\"") catch return;
        escJsonWrite(&w, r.engine);
        w.writeAll("\",\"magnet\":\"") catch return;
        escJsonWrite(&w, r.link);
        w.writeAll("\"}") catch return;
        count += 1;
        if (count >= 50) break;
    }
    w.writeAll("],\"searching\":") catch return;
    w.writeAll(if (search_svc.is_searching.load(.acquire)) "true" else "false") catch return;
    w.writeAll("}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

/// Music (JioSaavn / Subsonic / Jellyfin / Plex). Async search + poll:
///   POST /api/music/search?q=  → {"ok":true}
///   POST /api/music/play?idx=  → play on the desktop (companion mode)
///   GET  /api/music            → {loading,source,songs:[{title,artist,cover,url}]}
/// `url` is the direct stream, so a hosted browser can play it itself.
fn apiMusic(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    const music = @import("music_subsonic.zig");
    const alloc = @import("../core/alloc.zig").allocator;

    if (std.mem.eql(u8, api_path, "/music/search")) {
        if (getQueryParam(query, "q")) |raw| {
            var dec: [256]u8 = undefined;
            music.searchMusic(urlDecode(raw, &dec) orelse raw);
        }
        sendJson(stream, "{\"ok\":true}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/music/play")) {
        if (getQueryParam(query, "idx")) |v| {
            const idx = std.fmt.parseInt(usize, v, 10) catch 0;
            if (idx < state.app.music.result_count) music.playSong(idx);
        }
        sendJson(stream, "{\"ok\":true}");
        return;
    }

    const buf = alloc.alloc(u8, 96 * 1024) catch {
        sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(buf);
    var w = std.Io.Writer.fixed(buf);
    w.print("{{\"loading\":{s},\"source\":{d},\"songs\":[", .{
        if (state.app.music.is_loading.load(.acquire)) "true" else "false",
        state.app.music.source,
    }) catch return;
    var i: usize = 0;
    const n = @min(state.app.music.result_count, 80);
    while (i < n) : (i += 1) {
        const s = state.app.music.results[i];
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"title\":\"") catch return;
        escJsonWrite(&w, s.title[0..s.title_len]);
        w.writeAll("\",\"artist\":\"") catch return;
        escJsonWrite(&w, s.artist[0..s.artist_len]);
        w.writeAll("\",\"cover\":\"") catch return;
        escJsonWrite(&w, s.cover[0..s.cover_len]);
        w.writeAll("\",\"url\":\"") catch return;
        escJsonWrite(&w, s.play_url[0..s.play_url_len]);
        w.writeAll("\"}") catch return;
    }
    w.writeAll("]}") catch return;
    sendJson(stream, buf[0..w.end]);
}

/// Internet radio (radio-browser). Same async shape as music; GET seeds the
/// once-per-session popular list when nothing has been searched yet.
///   POST /api/radio/search?q= · POST /api/radio/play?idx= · GET /api/radio
fn apiRadio(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    const radio = @import("radio.zig");
    const alloc = @import("../core/alloc.zig").allocator;

    if (std.mem.eql(u8, api_path, "/radio/search")) {
        if (getQueryParam(query, "q")) |raw| {
            var dec: [256]u8 = undefined;
            radio.searchRadio(urlDecode(raw, &dec) orelse raw);
        }
        sendJson(stream, "{\"ok\":true}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/radio/play")) {
        if (getQueryParam(query, "idx")) |v| {
            const idx = std.fmt.parseInt(usize, v, 10) catch 0;
            if (idx < state.app.radio.result_count) radio.playStation(idx);
        }
        sendJson(stream, "{\"ok\":true}");
        return;
    }

    // Nothing loaded yet → seed the popular list (once per session, async).
    if (state.app.radio.result_count == 0) radio.loadPopularOnce();

    const buf = alloc.alloc(u8, 96 * 1024) catch {
        sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(buf);
    var w = std.Io.Writer.fixed(buf);
    w.print("{{\"loading\":{s},\"stations\":[", .{
        if (state.app.radio.is_loading.load(.acquire)) "true" else "false",
    }) catch return;
    var i: usize = 0;
    const n = @min(state.app.radio.result_count, 80);
    while (i < n) : (i += 1) {
        const st = state.app.radio.results[i];
        const u = if (st.url_resolved_len > 0) st.url_resolved[0..st.url_resolved_len] else st.url[0..st.url_len];
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"name\":\"") catch return;
        escJsonWrite(&w, st.name[0..st.name_len]);
        w.writeAll("\",\"url\":\"") catch return;
        escJsonWrite(&w, u);
        w.writeAll("\",\"favicon\":\"") catch return;
        escJsonWrite(&w, st.favicon[0..st.favicon_len]);
        w.writeAll("\",\"tags\":\"") catch return;
        escJsonWrite(&w, st.tags[0..st.tags_len]);
        w.writeAll("\",\"country\":\"") catch return;
        escJsonWrite(&w, st.country[0..st.country_len]);
        w.writeAll("\"}") catch return;
    }
    w.writeAll("]}") catch return;
    sendJson(stream, buf[0..w.end]);
}

/// Local AI copilot. Async like the other verticals: POST /api/ai/send?q= kicks
/// off generation and returns {ok}; poll GET /api/ai for the transcript, the
/// current phase, and any playable picks the model resolved.
///   POST /api/ai/send?q=…   → {"ok":true}
///   POST /api/ai/clear      → {"ok":true}
///   GET  /api/ai            → {generating,phase,messages:[{role,text}],results:[…]}
/// The response is heap-allocated: a 50-message transcript can exceed 100 KB,
/// far past the spawned-thread stack budget.
fn apiAi(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    const chat = @import("ai_chat.zig");
    const alloc = @import("../core/alloc.zig").allocator;

    if (std.mem.eql(u8, api_path, "/ai/send")) {
        if (getQueryParam(query, "q")) |raw| {
            var dec: [1024]u8 = undefined;
            const q = urlDecode(raw, &dec) orelse raw;
            const n = @min(q.len, chat.MAX_INPUT_LEN - 1);
            @memcpy(chat.input_buf[0..n], q[0..n]);
            chat.input_len = n;
            chat.sendMessage();
        }
        sendJson(stream, "{\"ok\":true}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/ai/clear")) {
        chat.clearHistory();
        sendJson(stream, "{\"ok\":true}");
        return;
    }

    const buf = alloc.alloc(u8, 192 * 1024) catch {
        sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(buf);
    var w = std.Io.Writer.fixed(buf);
    w.print("{{\"generating\":{s},\"phase\":\"", .{
        if (chat.is_generating.load(.acquire)) "true" else "false",
    }) catch return;
    escJsonWrite(&w, chat.phaseLabel(chat.phase));
    w.writeAll("\",\"messages\":[") catch return;
    var i: usize = 0;
    while (i < chat.message_count and i < chat.MAX_MESSAGES) : (i += 1) {
        const m = chat.messages[i];
        if (i > 0) w.writeAll(",") catch return;
        w.print("{{\"role\":\"{s}\",\"text\":\"", .{@tagName(m.role)}) catch return;
        escJsonWrite(&w, m.text[0..m.text_len]);
        w.writeAll("\"}") catch return;
    }
    // Playable picks the copilot resolved (magnets/urls) — the web UI can play
    // them straight from the answer.
    w.writeAll("],\"results\":[") catch return;
    var r: usize = 0;
    while (r < chat.chat_result_count and r < chat.chat_results.len) : (r += 1) {
        const it = chat.chat_results[r];
        if (r > 0) w.writeAll(",") catch return;
        w.writeAll("{\"name\":\"") catch return;
        escJsonWrite(&w, it.name[0..it.name_len]);
        w.writeAll("\",\"detail\":\"") catch return;
        escJsonWrite(&w, it.detail[0..it.detail_len]);
        w.writeAll("\",\"url\":\"") catch return;
        escJsonWrite(&w, it.url[0..it.url_len]);
        w.writeAll("\"}") catch return;
    }
    w.writeAll("]}") catch return;
    sendJson(stream, buf[0..w.end]);
}

/// Live TV / IPTV: page the SQLite channel catalog.
/// GET /api/livetv?q=&country=&category=&offset= → {total,offset,channels:[…]}
/// Adult channels follow the app's NSFW filter, exactly like the desktop tab.
/// The page is heap-allocated: IptvChannel is ~1.6 KB, so a stack array would
/// blow the 64 KB spawned-thread budget (see CLAUDE.md thread rules).
fn apiLiveTv(stream: std.Io.net.Stream, query: []const u8) void {
    const cat = @import("iptv_catalog.zig");
    const ipure = @import("iptv_pure.zig");
    const alloc = @import("../core/alloc.zig").allocator;

    var qbuf: [128]u8 = undefined;
    var cbuf: [64]u8 = undefined;
    var gbuf: [64]u8 = undefined;
    const text = if (getQueryParam(query, "q")) |v| (urlDecode(v, &qbuf) orelse v) else "";
    const country = if (getQueryParam(query, "country")) |v| (urlDecode(v, &cbuf) orelse v) else "";
    const category = if (getQueryParam(query, "category")) |v| (urlDecode(v, &gbuf) orelse v) else "";
    const offset: usize = if (getQueryParam(query, "offset")) |v|
        (std.fmt.parseInt(usize, v, 10) catch 0)
    else
        0;

    const q: cat.Query = .{
        .text = text,
        .country = country,
        .category = category,
        .nsfw_allowed = !state.app.nsfw_filter_enabled,
    };

    const PAGE = 50;
    const rows = alloc.alloc(ipure.IptvChannel, PAGE) catch {
        sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(rows);
    const n = cat.queryPage(rows, offset, q);
    const total = cat.count(q);

    var json_buf: [32768]u8 = undefined;
    var w = std.Io.Writer.fixed(&json_buf);
    w.print("{{\"total\":{d},\"offset\":{d},\"channels\":[", .{ total, offset }) catch return;
    for (rows[0..n], 0..) |ch, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"name\":\"") catch return;
        escJsonWrite(&w, ch.name[0..ch.name_len]);
        w.writeAll("\",\"url\":\"") catch return;
        escJsonWrite(&w, ch.url[0..ch.url_len]);
        w.writeAll("\",\"quality\":\"") catch return;
        escJsonWrite(&w, ch.quality[0..ch.quality_len]);
        w.writeAll("\",\"logo\":\"") catch return;
        escJsonWrite(&w, ch.logo[0..ch.logo_len]);
        w.writeAll("\",\"country\":\"") catch return;
        escJsonWrite(&w, ch.country[0..ch.country_len]);
        w.writeAll("\",\"category\":\"") catch return;
        escJsonWrite(&w, ch.category[0..ch.category_len]);
        w.writeAll("\"}") catch return;
    }
    w.writeAll("]}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

fn apiHistory(stream: std.Io.net.Stream) void {
    var json_buf: [16384]u8 = undefined;
    var w = std.Io.Writer.fixed(&json_buf);
    w.writeAll("{\"items\":[") catch return;
    var hi: usize = 0;
    while (hi < state.app.search_history_count) : (hi += 1) {
        const q = state.app.search_history_buf[hi][0..state.app.search_history_len[hi]];
        if (hi > 0) w.writeAll(",") catch return;
        w.writeAll("\"") catch return;
        escJsonWrite(&w, q);
        w.writeAll("\"") catch return;
    }
    w.writeAll("]}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

fn apiRssList(stream: std.Io.net.Stream) void {
    const rss = @import("rss.zig");
    var json_buf: [32768]u8 = undefined;
    var w = std.Io.Writer.fixed(&json_buf);
    w.writeAll("{\"feeds\":[") catch return;
    for (0..rss.feed_count) |fi| {
        const f = &rss.feeds[fi];
        if (fi > 0) w.writeAll(",") catch return;
        w.writeAll("\"") catch return;
        escJsonWrite(&w, f.name[0..f.name_len]);
        w.writeAll("\"") catch return;
    }
    w.writeAll("],\"items\":[") catch return;
    for (0..rss.item_count) |ri| {
        const item = &rss.items[ri];
        if (ri > 0) w.writeAll(",") catch return;
        w.writeAll("{\"title\":\"") catch return;
        escJsonWrite(&w, item.title[0..item.title_len]);
        w.print("\",\"seeds\":{d},\"peers\":{d},\"size\":{d},\"magnet\":\"", .{
            item.seeds, item.peers, item.size_bytes,
        }) catch return;
        escJsonWrite(&w, item.magnet[0..item.magnet_len]);
        w.writeAll("\"}") catch return;
    }
    w.writeAll("],\"fetching\":") catch return;
    w.writeAll(if (rss.is_fetching) "true" else "false") catch return;
    w.writeAll("}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

fn apiDownloads(stream: std.Io.net.Stream, query: []const u8) void {
    const paths = @import("../core/paths.zig");
    var path_buf: [512]u8 = undefined;
    const dl_path = if (state.app.save_path_len > 0)
        state.app.save_path_buf[0..state.app.save_path_len]
    else
        paths.defaultSavePath(&path_buf);

    const subdir = getQueryParam(query, "dir") orelse "";
    if (std.mem.indexOf(u8, subdir, "..") != null) return;
    var full_path_buf: [1024]u8 = undefined;
    const browse_path = if (subdir.len > 0)
        std.fmt.bufPrintZ(&full_path_buf, "{s}/{s}", .{ dl_path, subdir }) catch dl_path
    else
        dl_path;

    var json_buf: [32768]u8 = undefined;
    var w = std.Io.Writer.fixed(&json_buf);
    w.writeAll("{\"path\":\"") catch return;
    escJsonWrite(&w, browse_path);
    w.writeAll("\",\"files\":[") catch return;

    var dir = @import("../core/io_global.zig").cwdOpenDir(browse_path, .{ .iterate = true }) catch {
        w.writeAll("],\"error\":\"cannot open directory\"}") catch return;
        sendJson(stream, json_buf[0..w.end]);
        return;
    };
    defer dir.close(@import("../core/io_global.zig").io());

    var iter = dir.iterate();
    var count: usize = 0;
    while (iter.next(@import("../core/io_global.zig").io()) catch null) |entry| {
        if (count >= 100) break;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (std.mem.endsWith(u8, entry.name, ".torrent")) continue;
        if (std.mem.endsWith(u8, entry.name, ".parts")) continue;
        if (count > 0) w.writeAll(",") catch return;
        const is_dir = entry.kind == .directory;
        var size: u64 = 0;
        if (!is_dir) {
            if (dir.openFile(@import("../core/io_global.zig").io(), entry.name, .{})) |file| {
                if (file.stat(@import("../core/io_global.zig").io())) |st| {
                    size = st.size;
                } else |_| {}
                file.close(@import("../core/io_global.zig").io());
            } else |_| {}
        }
        w.writeAll("{\"name\":\"") catch return;
        escJsonWrite(&w, entry.name);
        w.print("\",\"is_dir\":{s},\"size\":{d}}}", .{
            if (is_dir) "true" else "false",
            size,
        }) catch return;
        count += 1;
    }
    w.writeAll("]}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

fn apiDownloadsPlay(stream: std.Io.net.Stream, query: []const u8) void {
    if (getQueryParam(query, "file")) |file_raw| {
        const paths = @import("../core/paths.zig");
        var path_buf: [512]u8 = undefined;
        const dl_path = if (state.app.save_path_len > 0)
            state.app.save_path_buf[0..state.app.save_path_len]
        else
            paths.defaultSavePath(&path_buf);
        var decoded: [512]u8 = undefined;
        const file_name = urlDecode(file_raw, &decoded) orelse file_raw;
        if (std.mem.indexOf(u8, file_name, "..") != null) return;
        var full_buf: [1024]u8 = undefined;
        if (std.fmt.bufPrintZ(&full_buf, "{s}/{s}", .{ dl_path, file_name })) |full_path| {
            // Hold players_mutex across the lookup + load_file: the UI thread
            // frees players at frame top (main.zig), so without this the
            // captured `plyr` could dangle mid-mpv-call → use-after-free.
            state.players_mutex.lock();
            defer state.players_mutex.unlock();
            if (state.app.active_player_idx < state.app.players.items.len) {
                const plyr = state.app.players.items[state.app.active_player_idx];
                plyr.load_file(full_path.ptr);
            }
        } else |_| {}
    }
    sendJson(stream, "{\"ok\":true}");
}

/// `/api/torrent/files?id=<idx>` → the playable files inside one torrent, with
/// the `/stream?file=` relative path the browser should use.
///
/// libtorrent saves under the downloads root, and /stream serves anything under
/// that root with Range support — so a partially-downloaded file streams as far
/// as it has bytes. `progress` lets the page warn before you hit the edge.
fn apiTorrentFiles(stream: std.Io.net.Stream, query: []const u8) void {
    const idx = std.fmt.parseInt(c_int, getQueryParam(query, "id") orelse "", 10) catch {
        sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"missing id\"}");
        return;
    };
    const ses = state.torrentSession();
    if (idx < 0 or idx >= c.mpv.torrent_count(ses)) {
        sendJsonStatus(stream, "404 Not Found", "{\"error\":\"no such torrent\"}");
        return;
    }

    const alloc = @import("../core/alloc.zig").allocator;
    const out = alloc.alloc(u8, 64 * 1024) catch {
        sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(out);
    var w = std.Io.Writer.fixed(out);

    // These accessors write into a caller buffer and return void — they do
    // not hand back a pointer.
    var tname_buf: [256]u8 = std.mem.zeroes([256]u8);
    c.mpv.torrent_get_name(ses, idx, &tname_buf, tname_buf.len);
    const tname = std.mem.sliceTo(&tname_buf, 0);
    w.writeAll("{\"torrent\":\"") catch return;
    escJsonWrite(&w, tname);
    w.writeAll("\",\"files\":[") catch return;

    const nfiles = c.mpv.torrent_get_file_count(ses, idx);
    var emitted: usize = 0;
    var i: c_int = 0;
    while (i < nfiles) : (i += 1) {
        var fname_buf: [512]u8 = std.mem.zeroes([512]u8);
        c.mpv.torrent_get_file_name(ses, idx, i, &fname_buf, fname_buf.len);
        const fname = std.mem.sliceTo(&fname_buf, 0);
        if (fname.len == 0) continue;
        if (emitted > 0) w.writeAll(",") catch return;
        emitted += 1;
        w.writeAll("{\"name\":\"") catch return;
        escJsonWrite(&w, fname);
        // The torrent's own folder is the first path segment under the root;
        // single-file torrents have no folder, hence the two shapes.
        w.writeAll("\",\"rel\":\"") catch return;
        if (!std.mem.eql(u8, tname, fname) and tname.len > 0) {
            escJsonWrite(&w, tname);
            w.writeAll("/") catch return;
        }
        escJsonWrite(&w, fname);
        w.print("\",\"progress\":{d:.0},\"size\":{d}}}", .{
            c.mpv.torrent_get_file_progress(ses, idx, i) * 100,
            c.mpv.torrent_get_file_size(ses, idx, i),
        }) catch return;
    }
    w.writeAll("]}") catch return;
    sendJson(stream, out[0..w.end]);
}

/// `/api/party` — GET status, or `?action=host|join|leave[&ip=]`.
/// Mirrors the desktop Watch Party controls (Settings › AI, Remote & Scripts).
fn apiParty(stream: std.Io.net.Stream, query: []const u8) void {
    const party = @import("watch_party.zig");
    var abuf: [16]u8 = undefined;
    if (credParam("", query, "action", &abuf)) |action| {
        if (std.mem.eql(u8, action, "host")) {
            party.hostParty();
        } else if (std.mem.eql(u8, action, "leave")) {
            party.leaveParty();
        } else if (std.mem.eql(u8, action, "join")) {
            var ipbuf: [64]u8 = undefined;
            const ip = credParam("", query, "ip", &ipbuf) orelse {
                sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"missing ip\"}");
                return;
            };
            if (ip.len < 7) {
                sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"not an IPv4 address\"}");
                return;
            }
            party.joinParty(ip);
        } else {
            sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"action must be host, join or leave\"}");
            return;
        }
    }
    var sbuf: [64]u8 = undefined;
    const status = party.statusText(&sbuf);
    var jb: [192]u8 = undefined;
    var w = std.Io.Writer.fixed(&jb);
    w.print("{{\"role\":\"{s}\",\"port\":{d},\"status\":\"", .{ @tagName(party.role), party.party_port }) catch return;
    escJsonWrite(&w, status);
    w.writeAll("\"}") catch return;
    sendJson(stream, jb[0..w.end]);
}

/// `/api/plugins` — GET the installed source plugins plus integration config,
/// or write one config key with `?key=&value=`.
///
/// The debrid API key is never echoed back: it is a credential, and the page
/// only needs to know whether one is set.
/// `/api/livetv/sources` — Settings › Live TV, for the web UI.
///
/// GET lists the curated sources with their installed state and channel count.
/// POST takes `?action=refresh`, or `?id=<source>&action=install|remove`, or a
/// custom playlist via `?id=iptv-custom&url=<m3u>`.
///
/// Every id is matched against the compiled-in SOURCES table before use, so a
/// caller cannot name an arbitrary source_config entry and have it written.
fn apiLiveTvSources(stream: std.Io.net.Stream, query: []const u8, body: []const u8) void {
    const iptv = @import("iptv.zig");
    const sources = @import("iptv_sources.zig");
    const source_config = @import("../core/source_config.zig");

    var abuf: [16]u8 = undefined;
    const action = credParam(body, query, "action", &abuf);
    if (action) |a| {
        if (std.mem.eql(u8, a, "refresh")) {
            iptv.refreshAllSources(true);
            sendJson(stream, "{\"ok\":true}");
            return;
        }
    }
    var ibuf: [64]u8 = undefined;
    if (credParam(body, query, "id", &ibuf)) |id| {
        // The custom playlist is the one entry whose URL comes from the caller.
        if (std.mem.eql(u8, id, sources.CUSTOM_ID)) {
            var ubuf: [512]u8 = undefined;
            const url = credParam(body, query, "url", &ubuf) orelse "";
            if (url.len == 0) {
                iptv.uninstallSource(sources.CUSTOM_ID);
                sendJson(stream, "{\"ok\":true}");
                return;
            }
            if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
                sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"url must be http(s)\"}");
                return;
            }
            var jb: [640]u8 = undefined;
            var jw = std.Io.Writer.fixed(&jb);
            jw.writeAll("{\"url\":\"") catch return;
            escJsonWrite(&jw, url);
            jw.writeAll("\"}") catch return;
            const ok = source_config.install(sources.CUSTOM_ID, jb[0..jw.end]);
            if (ok) iptv.refreshAllSources(true);
            sendJson(stream, if (ok) "{\"ok\":true}" else "{\"ok\":false}");
            return;
        }
        if (sources.byId(id) == null) {
            sendJsonStatus(stream, "404 Not Found", "{\"error\":\"unknown source\"}");
            return;
        }
        const a = action orelse "";
        if (std.mem.eql(u8, a, "install")) {
            iptv.installSource(id);
        } else if (std.mem.eql(u8, a, "remove")) {
            iptv.uninstallSource(id);
        } else {
            sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"action must be install or remove\"}");
            return;
        }
        sendJson(stream, "{\"ok\":true}");
        return;
    }

    const alloc = @import("../core/alloc.zig").allocator;
    const out = alloc.alloc(u8, 16 * 1024) catch {
        sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(out);
    var w = std.Io.Writer.fixed(out);
    w.print("{{\"total\":{d},\"ingesting\":{s},\"custom_url\":\"", .{
        iptv.catalogTotal(),
        if (iptv.isIngesting()) "true" else "false",
    }) catch return;
    escJsonWrite(&w, source_config.get(sources.CUSTOM_ID, "url") orelse "");
    w.writeAll("\",\"sources\":[") catch return;
    var first = true;
    for (sources.SOURCES) |src| {
        if (std.mem.eql(u8, src.id, sources.CUSTOM_ID)) continue; // reported above
        if (!first) w.writeAll(",") catch return;
        first = false;
        w.writeAll("{\"id\":\"") catch return;
        escJsonWrite(&w, src.id);
        w.writeAll("\",\"name\":\"") catch return;
        escJsonWrite(&w, src.name);
        w.writeAll("\",\"region\":\"") catch return;
        escJsonWrite(&w, src.region);
        w.writeAll("\",\"note\":\"") catch return;
        escJsonWrite(&w, src.note);
        w.print("\",\"installed\":{s},\"channels\":{d}}}", .{
            if (source_config.has(src.id)) "true" else "false",
            iptv.sourceChannelCount(src.id),
        }) catch return;
    }
    w.writeAll("]}") catch return;
    sendJson(stream, out[0..w.end]);
}

/// `/api/trakt` — the Plugins › Trakt tab, for the web UI.
///
/// GET reports connection state. The access token is never sent: a remote
/// caller only needs to know whether one exists, and `user_code` (the short
/// code trakt.tv/activate asks for) is the only thing it must actually display.
///
/// POST takes `?action=connect|disconnect`, or a `key`/`value` pair writing
/// client_id / client_secret. Device auth is the whole reason this is small:
/// the browser never handles the token, it just shows the code and polls.
fn apiTrakt(stream: std.Io.net.Stream, query: []const u8, body: []const u8) void {
    const trakt = @import("trakt.zig");
    var abuf: [16]u8 = undefined;
    if (credParam(body, query, "action", &abuf)) |action| {
        if (std.mem.eql(u8, action, "connect")) {
            if (trakt.client_id_len == 0) {
                sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"set client_id first\"}");
                return;
            }
            trakt.startDeviceAuth();
            sendJson(stream, "{\"ok\":true,\"pending\":true}");
            return;
        }
        if (std.mem.eql(u8, action, "disconnect")) {
            trakt.disconnect();
            sendJson(stream, "{\"ok\":true}");
            return;
        }
        sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"action must be connect or disconnect\"}");
        return;
    }
    var kbuf: [24]u8 = undefined;
    if (credParam(body, query, "key", &kbuf)) |key| {
        var vbuf: [128]u8 = undefined;
        const val = credParam(body, query, "value", &vbuf) orelse "";
        const Field = struct { name: []const u8, buf: []u8, len: *usize };
        const fields = [_]Field{
            .{ .name = "client_id", .buf = &trakt.client_id, .len = &trakt.client_id_len },
            .{ .name = "client_secret", .buf = &trakt.client_secret, .len = &trakt.client_secret_len },
        };
        for (fields) |f| {
            if (!std.mem.eql(u8, f.name, key)) continue;
            if (val.len > f.buf.len) {
                sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"value too long\"}");
                return;
            }
            @memset(f.buf, 0);
            @memcpy(f.buf[0..val.len], val);
            f.len.* = val.len;
            trakt.save();
            sendJson(stream, "{\"ok\":true}");
            return;
        }
        sendJsonStatus(stream, "404 Not Found", "{\"error\":\"unknown trakt setting\"}");
        return;
    }
    var out: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    // has_client_id / has_client_secret, never the values — same rule the
    // /plugins GET follows for the debrid key.
    w.print("{{\"connected\":{s},\"pending\":{s},\"scrobbling\":{s},\"has_client_id\":{s},\"has_client_secret\":{s},\"user_code\":\"", .{
        if (trakt.isConnected()) "true" else "false",
        if (trakt.auth_pending) "true" else "false",
        if (trakt.is_scrobbling) "true" else "false",
        if (trakt.client_id_len > 0) "true" else "false",
        if (trakt.client_secret_len > 0) "true" else "false",
    }) catch return;
    escJsonWrite(&w, trakt.user_code[0..@min(trakt.user_code_len, trakt.user_code.len)]);
    w.writeAll("\"}") catch return;
    sendJson(stream, out[0..w.end]);
}

/// `/api/suwayomi` — the Plugins › Suwayomi tab, for the web UI.
///
/// The manga extension server Opal can run on the user's behalf. GET reports
/// status; POST takes `?action=start|stop`. No credentials are involved, so
/// this one is only a lifecycle control.
fn apiSuwayomi(stream: std.Io.net.Stream, query: []const u8, body: []const u8) void {
    const suwa = @import("suwayomi_server.zig");
    var abuf: [16]u8 = undefined;
    if (credParam(body, query, "action", &abuf)) |action| {
        if (std.mem.eql(u8, action, "start")) {
            suwa.startEmbedded();
            sendJson(stream, "{\"ok\":true}");
            return;
        }
        if (std.mem.eql(u8, action, "stop")) {
            suwa.stopEmbedded();
            sendJson(stream, "{\"ok\":true}");
            return;
        }
        sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"action must be start or stop\"}");
        return;
    }
    var out: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    w.print("{{\"running\":{s},\"status\":\"", .{if (suwa.isRunning()) "true" else "false"}) catch return;
    escJsonWrite(&w, suwa.statusText());
    w.writeAll("\"}") catch return;
    sendJson(stream, out[0..w.end]);
}

fn apiPlugins(stream: std.Io.net.Stream, query: []const u8, body: []const u8) void {
    const repo = @import("plugin_repo.zig");
    var kbuf: [32]u8 = undefined;
    // body first: debrid_key and the GitHub token are secrets, and a query
    // string is the one place they would end up in a log or a browser history.
    if (credParam(body, query, "key", &kbuf)) |key| {
        var vbuf: [256]u8 = undefined;
        const val = credParam(body, query, "value", &vbuf) orelse "";
        // `persist` is not optional bookkeeping: none of these live in
        // config.tsv, so markConfigDirty() alone left every write in memory and
        // it was gone on restart. The desktop path calls saveDebrid() by hand
        // (plugins.zig); saveToken() had no caller anywhere.
        const Persist = enum { none, debrid, token };
        const Field = struct { name: []const u8, buf: []u8, len: *usize, persist: Persist = .none };
        const fields = [_]Field{
            .{ .name = "repo", .buf = &repo.repo_buf, .len = &repo.repo_len },
            .{ .name = "token", .buf = &repo.token_buf, .len = &repo.token_len, .persist = .token },
            .{ .name = "debrid_provider", .buf = &repo.debrid_provider_buf, .len = &repo.debrid_provider_len, .persist = .debrid },
            .{ .name = "debrid_key", .buf = &repo.debrid_key_buf, .len = &repo.debrid_key_len, .persist = .debrid },
        };
        for (fields) |f| {
            if (!std.mem.eql(u8, f.name, key)) continue;
            if (val.len > f.buf.len) {
                sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"value too long\"}");
                return;
            }
            @memset(f.buf, 0);
            @memcpy(f.buf[0..val.len], val);
            f.len.* = val.len;
            switch (f.persist) {
                .debrid => repo.saveDebrid(),
                .token => repo.saveToken(),
                .none => {},
            }
            state.markConfigDirty();
            sendJson(stream, "{\"ok\":true}");
            return;
        }
        sendJsonStatus(stream, "404 Not Found", "{\"error\":\"unknown plugin setting\"}");
        return;
    }

    const alloc = @import("../core/alloc.zig").allocator;
    const out = alloc.alloc(u8, 64 * 1024) catch {
        sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(out);
    var w = std.Io.Writer.fixed(out);
    w.writeAll("{\"installed\":[") catch return;
    for (repo.plugins[0..@min(repo.plugin_count, repo.plugins.len)], 0..) |*p, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"id\":\"") catch return;
        escJsonWrite(&w, p.id[0..@min(p.id_len, p.id.len)]);
        w.writeAll("\",\"name\":\"") catch return;
        escJsonWrite(&w, p.name[0..@min(p.name_len, p.name.len)]);
        w.writeAll("\",\"kind\":\"") catch return;
        escJsonWrite(&w, p.kind[0..@min(p.kind_len, p.kind.len)]);
        w.writeAll("\",\"version\":\"") catch return;
        escJsonWrite(&w, p.version[0..@min(p.version_len, p.version.len)]);
        w.writeAll("\"}") catch return;
    }
    w.writeAll("],\"repo\":\"") catch return;
    escJsonWrite(&w, repo.repo_buf[0..@min(repo.repo_len, repo.repo_buf.len)]);
    w.writeAll("\",\"debrid_provider\":\"") catch return;
    escJsonWrite(&w, repo.debrid_provider_buf[0..@min(repo.debrid_provider_len, repo.debrid_provider_buf.len)]);
    // Credentials: report presence, never the value.
    w.print("\",\"has_token\":{s},\"has_debrid_key\":{s}}}", .{
        if (repo.token_len > 0) "true" else "false",
        if (repo.debrid_key_len > 0) "true" else "false",
    }) catch return;
    sendJson(stream, out[0..w.end]);
}

/// `/api/home` — the numbers the desktop Home hub leads with, plus the few
/// things worth continuing. The page composes this with /calendar, which
/// already existed, rather than duplicating the coming-up rail here.
fn apiHome(stream: std.Io.net.Stream) void {
    const lib = @import("tv_library.zig");
    const tp = @import("tv_pure.zig");
    const alloc = @import("../core/alloc.zig").allocator;

    const rowbuf = alloc.alloc(tp.Row, tp.MAX_SHOWS) catch {
        sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(rowbuf);
    const n = lib.snapshotCopy(rowbuf);

    var watching: usize = 0;
    var caught_up: usize = 0;
    var unstarted: usize = 0;
    for (rowbuf[0..n]) |*r| {
        switch (tp.effectiveStatus(r.user, r.status)) {
            .watching => watching += 1,
            .caught_up => caught_up += 1,
            .unstarted => unstarted += 1,
            else => {},
        }
    }

    const out = alloc.alloc(u8, 32 * 1024) catch {
        sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(out);
    var w = std.Io.Writer.fixed(out);
    w.print("{{\"tracked\":{d},\"watching\":{d},\"caught_up\":{d},\"unstarted\":{d},\"torrents\":{d},\"continue\":[", .{
        n, watching, caught_up, unstarted,
        @as(i64, @intCast(c.mpv.torrent_count(state.torrentSession()))),
    }) catch return;

    // "Continue" = things with a next episode, in the library's own order, so
    // the hub agrees with the Watching page rather than ranking differently.
    var emitted: usize = 0;
    for (rowbuf[0..n]) |*r| {
        if (emitted >= 12) break;
        if (!r.has_next and r.pct <= 0) continue;
        if (emitted > 0) w.writeAll(",") catch return;
        emitted += 1;
        w.writeAll("{\"name\":\"") catch return;
        escJsonWrite(&w, r.name[0..@min(r.name_len, r.name.len)]);
        w.print("\",\"kind\":\"{s}\",\"tmdb_id\":{d},\"next_season\":{d},\"next_episode\":{d},\"has_next\":{s},\"poster\":\"", .{
            @tagName(r.kind), r.tmdb_id, r.next.season, r.next.episode,
            if (r.has_next) "true" else "false",
        }) catch return;
        escJsonWrite(&w, r.poster_url[0..@min(r.poster_url_len, r.poster_url.len)]);
        w.writeAll("\"}") catch return;
    }
    w.writeAll("]}") catch return;
    sendJson(stream, out[0..w.end]);
}

/// Current value of one registry key, written into `w` as a JSON value.
fn settingValueWrite(w: *std.Io.Writer, k: sap.Key) void {
    const b = struct {
        fn j(x: bool) []const u8 {
            return if (x) "true" else "false";
        }
    };
    if (std.mem.eql(u8, k.name, "hwdec")) return w.writeAll(b.j(state.app.hwdec_enabled)) catch {};
    if (std.mem.eql(u8, k.name, "auto_advance")) return w.writeAll(b.j(state.app.auto_advance)) catch {};
    if (std.mem.eql(u8, k.name, "seek_sync")) return w.writeAll(b.j(state.app.seek_sync)) catch {};
    if (std.mem.eql(u8, k.name, "sponsorblock")) return w.writeAll(b.j(state.app.sponsorblock_enabled)) catch {};
    if (std.mem.eql(u8, k.name, "auto_download_subs")) return w.writeAll(b.j(state.app.auto_download_subs)) catch {};
    if (std.mem.eql(u8, k.name, "nsfw_filter")) return w.writeAll(b.j(state.app.nsfw_filter_enabled)) catch {};
    if (std.mem.eql(u8, k.name, "incognito")) return w.writeAll(b.j(state.app.incognito_mode)) catch {};
    if (std.mem.eql(u8, k.name, "ui_scale_auto")) return w.writeAll(b.j(state.app.ui_scale_auto)) catch {};
    if (std.mem.eql(u8, k.name, "taste_enabled")) return w.writeAll(b.j(state.app.taste_enabled)) catch {};
    if (std.mem.eql(u8, k.name, "ui_scale")) return w.print("{d}", .{@as(i32, @intFromFloat(state.app.ui_scale * 100))}) catch {};
    if (std.mem.eql(u8, k.name, "theme")) {
        w.writeAll("\"") catch return;
        const th = @import("../ui/theme.zig");
        escJsonWrite(w, th.presetName(th.active_preset));
        w.writeAll("\"") catch return;
        return;
    }
    // KB/s on the wire, bytes/s in state — see settings_api_pure.rateBytesToKb.
    if (std.mem.eql(u8, k.name, "download_rate_limit")) return w.print("{d}", .{sap.rateBytesToKb(state.app.download_rate_limit)}) catch {};
    if (std.mem.eql(u8, k.name, "lang_learn")) return w.writeAll(b.j(state.app.lang_learn_enabled)) catch {};
    if (std.mem.eql(u8, k.name, "translate")) return w.writeAll(b.j(state.app.translate_enabled)) catch {};
    if (std.mem.eql(u8, k.name, "dubbing")) return w.writeAll(b.j(state.app.dubbing_enabled)) catch {};
    // f32 multiplier internally, integer percent on the wire.
    if (std.mem.eql(u8, k.name, "tts_speed")) return w.print("{d}", .{@as(i32, @intFromFloat(state.app.tts_speed * 100))}) catch {};
    if (std.mem.eql(u8, k.name, "sub_lang")) {
        w.writeAll("\"") catch return;
        escJsonWrite(w, state.app.sub_lang_buf[0..@min(state.app.sub_lang_len, state.app.sub_lang_buf.len)]);
        w.writeAll("\"") catch return;
        return;
    }
    if (std.mem.eql(u8, k.name, "save_path")) {
        w.writeAll("\"") catch return;
        escJsonWrite(w, state.app.save_path_buf[0..@min(state.app.save_path_len, state.app.save_path_buf.len)]);
        w.writeAll("\"") catch return;
        return;
    }
    if (std.mem.eql(u8, k.name, "tts_voice")) {
        w.writeAll("\"") catch return;
        escJsonWrite(w, state.app.tts_voice_buf[0..@min(state.app.tts_voice_len, state.app.tts_voice_buf.len)]);
        w.writeAll("\"") catch return;
        return;
    }
    if (std.mem.eql(u8, k.name, "translate_lang")) {
        w.writeAll("\"") catch return;
        escJsonWrite(w, state.app.translate_lang_buf[0..@min(state.app.translate_lang_len, state.app.translate_lang_buf.len)]);
        w.writeAll("\"") catch return;
        return;
    }
    if (std.mem.eql(u8, k.name, "proxy_url")) {
        w.writeAll("\"") catch return;
        escJsonWrite(w, state.app.proxy_url[0..@min(state.app.proxy_url_len, state.app.proxy_url.len)]);
        w.writeAll("\"") catch return;
        return;
    }
    w.writeAll("null") catch {};
}

/// Apply one validated value. Returns false when the key has no writer — which
/// would mean the registry and this switch drifted, so the route reports it
/// rather than answering ok to a write that never happened.
fn settingApply(k: sap.Key, raw: []const u8) bool {
    switch (k.kind) {
        .boolean => {
            const v = sap.parseBool(raw) orelse return false;
            if (std.mem.eql(u8, k.name, "hwdec")) {
                state.app.hwdec_enabled = v;
                // Push to every live player, exactly like the desktop toggle.
                const hw: []const u8 = if (v) "auto" else "no";
                for (state.app.players.items) |p| {
                    var cmd: [64]u8 = undefined;
                    if (std.fmt.bufPrintZ(&cmd, "set hwdec {s}", .{hw})) |z| {
                        _ = c.mpv.mpv_command_string(p.mpv_ctx, z.ptr);
                    } else |_| {}
                }
            } else if (std.mem.eql(u8, k.name, "auto_advance")) {
                state.app.auto_advance = v;
            } else if (std.mem.eql(u8, k.name, "seek_sync")) {
                state.app.seek_sync = v;
            } else if (std.mem.eql(u8, k.name, "sponsorblock")) {
                state.app.sponsorblock_enabled = v;
            } else if (std.mem.eql(u8, k.name, "auto_download_subs")) {
                state.app.auto_download_subs = v;
            } else if (std.mem.eql(u8, k.name, "nsfw_filter")) {
                state.app.nsfw_filter_enabled = v;
            } else if (std.mem.eql(u8, k.name, "incognito")) {
                state.app.incognito_mode = v;
            } else if (std.mem.eql(u8, k.name, "lang_learn")) {
                state.app.lang_learn_enabled = v;
            } else if (std.mem.eql(u8, k.name, "translate")) {
                state.app.translate_enabled = v;
            } else if (std.mem.eql(u8, k.name, "dubbing")) {
                state.app.dubbing_enabled = v;
            } else if (std.mem.eql(u8, k.name, "ui_scale_auto")) {
                state.app.ui_scale_auto = v;
            } else if (std.mem.eql(u8, k.name, "taste_enabled")) {
                state.app.taste_enabled = v;
            } else return false;
        },
        .integer => {
            const n = sap.parseInt(k, raw) orelse return false;
            if (std.mem.eql(u8, k.name, "download_rate_limit")) {
                // The field is KB/s; state and libtorrent are bytes/s.
                state.app.download_rate_limit = sap.rateKbToBytes(n);
                // Apply now: the desktop pickers call torrent_set_download_limit
                // on click, so a limit set from the web that only landed in
                // state would not take effect until the next session.
                state.applyDownloadLimitIfReady();
            } else if (std.mem.eql(u8, k.name, "tts_speed")) {
                state.app.tts_speed = @as(f32, @floatFromInt(n)) / 100.0;
            } else if (std.mem.eql(u8, k.name, "ui_scale")) {
                // Setting an explicit scale means the user is overriding the
                // DPI-derived value, so clear the auto flag — otherwise the next
                // frame recomputes it and the write appears to do nothing.
                state.app.ui_scale = @as(f32, @floatFromInt(n)) / 100.0;
                state.app.ui_scale_auto = false;
            } else return false;
        },
        .text => {
            const t = sap.parseText(k, raw) orelse return false;
            if (std.mem.eql(u8, k.name, "theme")) {
                // Matched against the same presetName() the desktop picker
                // shows, so "Rosé" round-trips and an unknown name is rejected
                // rather than silently leaving the theme unchanged.
                const th = @import("../ui/theme.zig");
                inline for (@typeInfo(th.ThemePreset).@"enum".fields) |f| {
                    const preset: th.ThemePreset = @enumFromInt(f.value);
                    if (std.mem.eql(u8, th.presetName(preset), t)) {
                        th.setPreset(preset);
                        return true;
                    }
                }
                return false;
            } else if (std.mem.eql(u8, k.name, "sub_lang")) {
                const n = @min(t.len, state.app.sub_lang_buf.len);
                @memset(&state.app.sub_lang_buf, 0);
                @memcpy(state.app.sub_lang_buf[0..n], t[0..n]);
                state.app.sub_lang_len = n;
            } else if (std.mem.eql(u8, k.name, "proxy_url")) {
                const n = @min(t.len, state.app.proxy_url.len);
                @memset(&state.app.proxy_url, 0);
                @memcpy(state.app.proxy_url[0..n], t[0..n]);
                state.app.proxy_url_len = n;
                state.applyTorrentProxyIfReady();
            } else if (std.mem.eql(u8, k.name, "save_path")) {
                // Leave room for the NUL state.zig writes at [save_path_len].
                const n = @min(t.len, state.app.save_path_buf.len - 1);
                @memset(&state.app.save_path_buf, 0);
                @memcpy(state.app.save_path_buf[0..n], t[0..n]);
                state.app.save_path_len = n;
            } else if (std.mem.eql(u8, k.name, "tts_voice")) {
                const n = @min(t.len, state.app.tts_voice_buf.len);
                @memset(&state.app.tts_voice_buf, 0);
                @memcpy(state.app.tts_voice_buf[0..n], t[0..n]);
                state.app.tts_voice_len = n;
            } else if (std.mem.eql(u8, k.name, "translate_lang")) {
                const n = @min(t.len, state.app.translate_lang_buf.len);
                @memset(&state.app.translate_lang_buf, 0);
                @memcpy(state.app.translate_lang_buf[0..n], t[0..n]);
                state.app.translate_lang_len = n;
            } else return false;
        },
    }
    state.markConfigDirty();
    return true;
}

/// `/api/settings` — GET the registry with live values, or write one key with
/// `?key=&value=`.
///
/// Values ride in the query string rather than a POST body (which handleApi
/// does not receive): none of these are secrets. Credentials deliberately go
/// the other way — see the /api/auth and /api/access handlers.
fn apiSettings(stream: std.Io.net.Stream, query: []const u8) void {
    var kbuf: [64]u8 = undefined;
    if (credParam("", query, "key", &kbuf)) |key| {
        const k = sap.find(key) orelse {
            sendJsonStatus(stream, "404 Not Found", "{\"error\":\"unknown setting\"}");
            return;
        };
        var vbuf: [256]u8 = undefined;
        const raw = credParam("", query, "value", &vbuf) orelse {
            sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"missing value\"}");
            return;
        };
        if (!settingApply(k, raw)) {
            sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"invalid value for this setting\"}");
            return;
        }
        var jb: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&jb);
        w.print("{{\"ok\":true,\"key\":\"{s}\",\"value\":", .{k.name}) catch return;
        settingValueWrite(&w, k);
        w.writeAll("}") catch return;
        sendJson(stream, jb[0..w.end]);
        return;
    }

    var out: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    w.writeAll("{\"settings\":[") catch return;
    for (sap.KEYS, 0..) |k, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.print("{{\"name\":\"{s}\",\"kind\":\"{s}\",\"group\":\"{s}\",\"label\":\"", .{
            k.name, @tagName(k.kind), k.group,
        }) catch return;
        escJsonWrite(&w, k.label);
        w.print("\",\"min\":{d},\"max\":{d},\"value\":", .{ k.min, k.max }) catch return;
        settingValueWrite(&w, k);
        w.writeAll("}") catch return;
    }
    w.writeAll("],")
        catch return;
    // Legacy top-level booleans from the original /settings shape, kept so an
    // older client (see docs/headless-hosting-spec.md) is not broken by the
    // registry being added alongside it.
    w.print("\"auto_advance\":{s},\"incognito\":{s},\"sponsorblock\":{s},\"nsfw_filter\":{s}}}", .{
        if (state.app.auto_advance) "true" else "false",
        if (state.app.incognito_mode) "true" else "false",
        if (state.app.sponsorblock_enabled) "true" else "false",
        if (state.app.nsfw_filter_enabled) "true" else "false",
    }) catch return;
    sendJson(stream, out[0..w.end]);
}

fn apiSettingsToggle(query: []const u8) void {
    if (getQueryParam(query, "key")) |key| {
        if (std.mem.eql(u8, key, "auto_advance")) {
            state.app.auto_advance = !state.app.auto_advance;
        } else if (std.mem.eql(u8, key, "incognito")) {
            state.app.incognito_mode = !state.app.incognito_mode;
        } else if (std.mem.eql(u8, key, "sponsorblock")) {
            state.app.sponsorblock_enabled = !state.app.sponsorblock_enabled;
        } else if (std.mem.eql(u8, key, "nsfw_filter")) {
            state.app.nsfw_filter_enabled = !state.app.nsfw_filter_enabled;
        }
    }
}

fn apiTmdb(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    // Kick a trending fetch (web Browse tab); results land in the shared
    // list the plain /tmdb GET below returns.
    if (std.mem.eql(u8, api_path, "/tmdb/trending")) {
        if (!state.app.tmdb.is_loading.load(.acquire) and state.app.tmdb.results.items.len == 0) {
            state.app.tmdb.view = .Trending;
            state.app.tmdb.page = 1;
            state.app.tmdb.loaded_once = true;
            @import("tmdb_api.zig").fetchCurrentView(false);
        }
        sendJson(stream, "{\"ok\":true}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/tmdb/search")) {
        if (getQueryParam(query, "q")) |q| {
            var decoded: [256]u8 = undefined;
            const dq = urlDecode(q, &decoded) orelse q;
            // Copy to tmdb search buf and trigger
            const slen = @min(dq.len, 127);
            @memcpy(state.app.tmdb.search_buf[0..slen], dq[0..slen]);
            state.app.tmdb.search_buf[slen] = 0;
            state.app.tmdb.view = .Search;
            state.app.tmdb.page = 1;
            const tmdb_api = @import("tmdb_api.zig");
            tmdb_api.fetchCurrentView(false);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"tmdb_search\"}");
        return;
    }
    // Return current TMDB results. HTTP thread — hold results_mutex while
    // iterating: the UI thread mutates `results` under it (applyPendingResults).
    var json_buf: [32768]u8 = undefined;
    var w = std.Io.Writer.fixed(&json_buf);
    w.writeAll("{\"items\":[") catch return;
    state.app.tmdb.results_mutex.lock();
    defer state.app.tmdb.results_mutex.unlock();
    const items = &state.app.tmdb.results;
    for (items.items, 0..) |item, idx| {
        // Cap BEFORE the separator: writing the comma first emits a trailing
        // comma on the 30th row, producing JSON the web UI can't parse. Latent
        // until a grid actually exceeded 30 rows (YouTube channel pages do).
        if (idx >= 30) break;
        if (idx > 0) w.writeAll(",") catch return;
        const rating_pct = @as(u8, @intFromFloat(std.math.clamp(item.rating * 10.0, 0.0, 100.0)));
        w.print("{{\"id\":{d},\"title\":\"", .{item.id}) catch return;
        escJsonWrite(&w, item.title[0..item.title_len]);
        w.writeAll("\",\"year\":\"") catch return;
        escJsonWrite(&w, item.year[0..item.year_len]);
        w.print("\",\"rating\":{d},\"type\":\"", .{rating_pct}) catch return;
        escJsonWrite(&w, item.media_type[0..item.media_type_len]);
        w.writeAll("\",\"overview\":\"") catch return;
        escJsonWrite(&w, item.overview[0..@min(item.overview_len, 200)]);
        // poster_path feeds the web client's /poster?path= cache proxy.
        w.writeAll("\",\"poster\":\"") catch return;
        escJsonWrite(&w, item.poster_path[0..item.poster_path_len]);
        w.writeAll("\"}") catch return;
    }
    w.writeAll("],\"loading\":") catch return;
    w.writeAll(if (state.app.tmdb.is_loading.load(.acquire)) "true" else "false") catch return;
    w.writeAll(",\"has_key\":") catch return;
    w.writeAll(if (state.app.tmdb.api_key_len > 0) "true" else "false") catch return;
    w.writeAll("}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

fn apiYoutube(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    if (std.mem.eql(u8, api_path, "/youtube/search")) {
        if (getQueryParam(query, "q")) |q| {
            var decoded: [256]u8 = undefined;
            const dq = urlDecode(q, &decoded) orelse q;
            const slen = @min(dq.len, 127);
            @memcpy(state.app.yt.search_buf[0..slen], dq[0..slen]);
            state.app.yt.search_buf[slen] = 0;
            const yt = @import("youtube.zig");
            yt.fetchYoutube(state.app.yt.search_buf[0..slen]);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"yt_search\"}");
        return;
    }
    // Return current results
    var json_buf: [32768]u8 = undefined;
    var w = std.Io.Writer.fixed(&json_buf);
    w.writeAll("{\"items\":[") catch return;
    for (state.app.yt.results.items, 0..) |item, idx| {
        // Cap BEFORE the separator: writing the comma first emits a trailing
        // comma on the 30th row, producing JSON the web UI can't parse. Latent
        // until a grid actually exceeded 30 rows (YouTube channel pages do).
        if (idx >= 30) break;
        if (idx > 0) w.writeAll(",") catch return;
        const dur_min = @divTrunc(item.duration, 60);
        const dur_sec = @rem(item.duration, 60);
        w.writeAll("{\"id\":\"") catch return;
        escJsonWrite(&w, item.video_id[0..item.video_id_len]);
        w.writeAll("\",\"title\":\"") catch return;
        escJsonWrite(&w, item.title[0..item.title_len]);
        w.writeAll("\",\"channel\":\"") catch return;
        escJsonWrite(&w, item.uploader[0..item.uploader_len]);
        w.print("\",\"dur_min\":{d},\"dur_sec\":{d},\"views\":{d}}}", .{
            dur_min, dur_sec, item.views,
        }) catch return;
    }
    w.writeAll("],\"loading\":") catch return;
    w.writeAll(if (state.app.yt.is_loading.load(.acquire)) "true" else "false") catch return;
    w.writeAll("}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

fn apiAnime(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    if (std.mem.eql(u8, api_path, "/anime/search")) {
        if (getQueryParam(query, "q")) |q| {
            var decoded: [256]u8 = undefined;
            const dq = urlDecode(q, &decoded) orelse q;
            const anime_svc = @import("anime.zig");
            anime_svc.searchAnime(dq);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"anime_search\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/anime/episodes")) {
        if (getQueryParam(query, "idx")) |idx_str| {
            const idx = std.fmt.parseInt(usize, idx_str, 10) catch 0;
            const anime_svc = @import("anime.zig");
            anime_svc.loadEpisodes(idx);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"load_episodes\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/anime/play")) {
        if (getQueryParam(query, "ep")) |ep| {
            var decoded: [16]u8 = undefined;
            const ep_str = urlDecode(ep, &decoded) orelse ep;
            const anime_svc = @import("anime.zig");
            anime_svc.playEpisode(ep_str);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"play_episode\"}");
        return;
    }
    // Return results + episodes
    var json_buf: [16384]u8 = undefined;
    var w = std.Io.Writer.fixed(&json_buf);
    w.writeAll("{\"results\":[") catch return;
    for (0..state.app.anime.result_count) |ri| {
        const r = state.app.anime.results[ri];
        if (r.name_len == 0) continue;
        if (ri > 0) w.writeAll(",") catch return;
        w.writeAll("{\"name\":\"") catch return;
        escJsonWrite(&w, r.name[0..r.name_len]);
        w.print("\",\"episodes\":{d}}}", .{r.episodes}) catch return;
    }
    w.writeAll("],\"episodes\":[") catch return;
    for (0..state.app.anime.episode_count) |ei| {
        const ep_len = state.app.anime.episode_list_lens[ei];
        if (ep_len == 0) continue;
        if (ei > 0) w.writeAll(",") catch return;
        w.writeAll("\"") catch return;
        escJsonWrite(&w, state.app.anime.episode_list[ei][0..ep_len]);
        w.writeAll("\"") catch return;
    }
    w.writeAll("],\"selected\":") catch return;
    if (state.app.anime.selected_idx) |si| {
        w.print("{d}", .{si}) catch return;
    } else {
        w.writeAll("null") catch return;
    }
    w.writeAll(",\"loading\":") catch return;
    w.writeAll(if (state.app.anime.is_loading.load(.acquire)) "true" else "false") catch return;
    w.writeAll(",\"stream_loading\":") catch return;
    w.writeAll(if (state.app.anime.stream_loading) "true" else "false") catch return;
    w.writeAll("}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

fn apiPodcasts(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    const podcasts_svc = @import("podcasts.zig");
    if (std.mem.eql(u8, api_path, "/podcasts/search")) {
        if (getQueryParam(query, "q")) |q| {
            var decoded: [256]u8 = undefined;
            const dq = urlDecode(q, &decoded) orelse q;
            podcasts_svc.searchPodcasts(dq);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"podcast_search\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/podcasts/episodes")) {
        if (getQueryParam(query, "idx")) |idx_str| {
            const idx = std.fmt.parseInt(usize, idx_str, 10) catch 0;
            podcasts_svc.loadEpisodes(idx);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"load_episodes\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/podcasts/play")) {
        if (getQueryParam(query, "idx")) |idx_str| {
            const idx = std.fmt.parseInt(usize, idx_str, 10) catch 0;
            podcasts_svc.playEpisode(idx);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"play_episode\"}");
        return;
    }
    // GET /podcasts → results + episodes for the current show.
    var json_buf: [32768]u8 = undefined;
    var w = std.Io.Writer.fixed(&json_buf);
    w.writeAll("{\"results\":[") catch return;
    for (0..state.app.podcasts.result_count) |ri| {
        const r = state.app.podcasts.results[ri];
        if (r.name_len == 0) continue;
        if (ri > 0) w.writeAll(",") catch return;
        w.writeAll("{\"name\":\"") catch return;
        escJsonWrite(&w, r.name[0..r.name_len]);
        // `art` tells the web client whether to request the cover proxy
        // (/api/podcasts/poster?idx=…) or fall back to a placeholder tile.
        w.writeAll("\",\"art\":") catch return;
        w.writeAll(if (r.artwork_len > 0) "true" else "false") catch return;
        w.writeAll("}") catch return;
    }
    w.writeAll("],\"episodes\":[") catch return;
    for (0..state.app.podcasts.episode_count) |ei| {
        const e = state.app.podcasts.episodes[ei];
        if (e.title_len == 0) continue;
        if (ei > 0) w.writeAll(",") catch return;
        w.writeAll("{\"title\":\"") catch return;
        escJsonWrite(&w, e.title[0..e.title_len]);
        w.writeAll("\",\"date\":\"") catch return;
        escJsonWrite(&w, e.date[0..e.date_len]);
        w.writeAll("\",\"duration\":\"") catch return;
        escJsonWrite(&w, e.duration[0..e.duration_len]);
        w.writeAll("\"}") catch return;
    }
    w.writeAll("],\"selected\":") catch return;
    if (state.app.podcasts.selected_idx) |si| {
        w.print("{d}", .{si}) catch return;
    } else {
        w.writeAll("null") catch return;
    }
    w.writeAll(",\"loading\":") catch return;
    w.writeAll(if (state.app.podcasts.is_loading.load(.acquire)) "true" else "false") catch return;
    w.writeAll(",\"episodes_loading\":") catch return;
    w.writeAll(if (state.app.podcasts.episodes_loading.load(.acquire)) "true" else "false") catch return;
    w.writeAll("}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

/// GET /api/logs[?errors=1&limit=N] — the in-app log ring.
///
/// The single most useful route on a headless box: `docker logs` only shows
/// stdout, while everything the desktop Logs tab renders (scraper output, mpv
/// stderr, worker errors) lives in this ring.
///
/// logCount()/getLog() are UNLOCKED accessors — valid only inside a
/// lockRead()/unlockRead() pair, because a worker's pushLog evicts and frees the
/// oldest entry's slices. So the whole serialization happens under the lock, and
/// nothing in this loop may log.
fn apiLogs(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    const a = @import("../core/alloc.zig").allocator;

    if (std.mem.eql(u8, api_path, "/logs/clear")) {
        logs.clear();
        sendJson(stream, "{\"ok\":true,\"action\":\"logs_clear\"}");
        return;
    }

    const errors_only = std.mem.eql(u8, getQueryParam(query, "errors") orelse "", "1");
    // Newest-N window: the ring holds 1024 entries and a browser wants the tail.
    const limit = std.fmt.parseInt(usize, getQueryParam(query, "limit") orelse "200", 10) catch 200;

    // 1024 entries can exceed 256KB of text — heap, never the thread stack.
    const json_buf = a.alloc(u8, 512 * 1024) catch return;
    defer a.free(json_buf);
    var w = std.Io.Writer.fixed(json_buf);
    w.writeAll("{\"entries\":[") catch return;

    logs.lockRead();
    const total = logs.logCount();
    // Walk oldest→newest but start late enough to emit at most `limit` rows.
    var idx: usize = if (total > limit) total - limit else 0;
    var emitted: usize = 0;
    while (idx < total) : (idx += 1) {
        const e = logs.getLog(idx);
        if (errors_only and !e.is_error) continue;
        if (emitted > 0) w.writeAll(",") catch break;
        emitted += 1;
        w.print("{{\"ts\":{d},\"error\":{s},\"level\":\"", .{
            e.timestamp,
            if (e.is_error) "true" else "false",
        }) catch break;
        escJsonWrite(&w, txt.safeUtf8(e.level));
        w.writeAll("\",\"prefix\":\"") catch break;
        escJsonWrite(&w, txt.safeUtf8(e.prefix));
        w.writeAll("\",\"text\":\"") catch break;
        // Log text is untrusted (mpv stderr, scraper output) — invalid UTF-8
        // here would produce a response the browser refuses to parse.
        escJsonWrite(&w, txt.safeUtf8(e.text));
        w.writeAll("\"}") catch break;
    }
    logs.unlockRead();

    w.writeAll("]}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

/// GET /api/vndb[/search?q=] — visual-novel catalog. No play route: VNs aren't
/// launchable, this is a browsable catalog like the desktop tab.
fn apiVndb(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    const vndb = @import("vndb.zig");
    const v = &state.app.vndb;

    if (std.mem.eql(u8, api_path, "/vndb/search")) {
        if (getQueryParam(query, "q")) |q| {
            var decoded: [256]u8 = undefined;
            vndb.searchVndb(txt.safeUtf8(urlDecode(q, &decoded) orelse q));
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"vndb_search\"}");
        return;
    }

    // First GET seeds the popular list, mirroring the desktop tab's one-shot.
    if (v.result_count == 0 and !v.is_loading.load(.acquire)) vndb.loadPopularOnce();

    const a = @import("../core/alloc.zig").allocator;
    // 180 rows × a 1KB description — heap.
    const json_buf = a.alloc(u8, 320 * 1024) catch return;
    defer a.free(json_buf);
    var w = std.Io.Writer.fixed(json_buf);
    w.print("{{\"loading\":{s},\"popular\":{s},\"results\":[", .{
        if (v.is_loading.load(.acquire)) "true" else "false",
        if (v.showing_popular) "true" else "false",
    }) catch return;
    const n = @min(v.result_count, v.results.len);
    for (v.results[0..n], 0..) |*r, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"id\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(r.id[0..@min(r.id_len, r.id.len)]));
        w.writeAll("\",\"title\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(r.title[0..@min(r.title_len, r.title.len)]));
        w.writeAll("\",\"image\":\"") catch return;
        escJsonWrite(&w, r.image_url[0..@min(r.image_url_len, r.image_url.len)]);
        w.writeAll("\",\"released\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(r.released[0..@min(r.released_len, r.released.len)]));
        w.writeAll("\",\"description\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(r.description[0..@min(r.description_len, r.description.len)]));
        w.print("\",\"rating\":{d:.2}}}", .{r.rating}) catch return;
    }
    w.writeAll("]}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

/// GET /api/drama[/play?idx=] — the Asian-drama catalog (TMDB /discover/tv).
/// Browse-only: drama.zig has no search entry point, so neither does this.
fn apiDrama(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    const drama = @import("drama.zig");
    const d = &state.app.drama;

    if (std.mem.eql(u8, api_path, "/drama/play")) {
        const idx = std.fmt.parseInt(usize, getQueryParam(query, "idx") orelse "999", 10) catch 999;
        if (idx >= d.result_count) {
            sendJsonStatus(stream, "404 Not Found", "{\"error\":\"no such drama\"}");
            return;
        }
        // playSelected() takes no index — it reads selected_idx. Set it first.
        d.selected_idx = idx;
        drama.playSelected();
        sendJson(stream, "{\"ok\":true,\"action\":\"drama_play\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/drama/more")) {
        drama.loadMore();
        sendJson(stream, "{\"ok\":true,\"action\":\"drama_more\"}");
        return;
    }

    // Every drama entry point no-ops without a TMDB key — say so rather than
    // returning a permanently empty list the client can't explain.
    if (state.app.tmdb.api_key_len == 0) {
        sendJson(stream, "{\"loading\":false,\"needs_tmdb_key\":true,\"results\":[]}");
        return;
    }
    if (!d.loaded_once and !d.is_loading.load(.acquire)) drama.loadCatalog();

    const a = @import("../core/alloc.zig").allocator;
    const json_buf = a.alloc(u8, 320 * 1024) catch return;
    defer a.free(json_buf);
    var w = std.Io.Writer.fixed(json_buf);
    w.print("{{\"loading\":{s},\"streaming\":{s},\"needs_tmdb_key\":false,\"results\":[", .{
        if (d.is_loading.load(.acquire)) "true" else "false",
        if (d.stream_loading.load(.acquire)) "true" else "false",
    }) catch return;
    const n = @min(d.result_count, d.results.len);
    for (d.results[0..n], 0..) |*r, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"id\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(r.id[0..@min(r.id_len, r.id.len)]));
        w.writeAll("\",\"name\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(r.name[0..@min(r.name_len, r.name.len)]));
        w.writeAll("\",\"year\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(r.year[0..@min(r.year_len, r.year.len)]));
        // A TMDB path like "/abc.jpg"; the client prefixes an image base.
        w.writeAll("\",\"poster_path\":\"") catch return;
        escJsonWrite(&w, r.poster_path[0..@min(r.poster_path_len, r.poster_path.len)]);
        w.writeAll("\",\"overview\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(r.overview[0..@min(r.overview_len, r.overview.len)]));
        w.print("\",\"vote\":{d:.1}}}", .{r.vote}) catch return;
    }
    w.writeAll("]}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

/// GET /api/novels — search → chapter list → chapter text, the desktop drill-down.
///
/// `/novels/search?q=` → results; `/novels/open?idx=` → that novel's chapters;
/// `/novels/chapter?idx=` → its text; `/novels/next|prev`. `GET /novels` returns
/// whichever view is live, so one poll drives the whole flow.
fn apiNovels(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    const nov = @import("novels.zig");
    const n = &state.app.novels;

    if (std.mem.eql(u8, api_path, "/novels/search")) {
        if (getQueryParam(query, "q")) |q| {
            var decoded: [256]u8 = undefined;
            nov.searchNovels(txt.safeUtf8(urlDecode(q, &decoded) orelse q));
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"novel_search\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/novels/open")) {
        const idx = std.fmt.parseInt(usize, getQueryParam(query, "idx") orelse "999", 10) catch 999;
        if (idx >= nov.resultCount()) {
            sendJsonStatus(stream, "404 Not Found", "{\"error\":\"no such novel\"}");
            return;
        }
        nov.openNovel(idx);
        sendJson(stream, "{\"ok\":true,\"action\":\"novel_open\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/novels/chapter")) {
        const idx = std.fmt.parseInt(usize, getQueryParam(query, "idx") orelse "999", 10) catch 999;
        if (idx >= nov.chapterCount()) {
            sendJsonStatus(stream, "404 Not Found", "{\"error\":\"no such chapter\"}");
            return;
        }
        nov.openChapter(idx);
        sendJson(stream, "{\"ok\":true,\"action\":\"novel_chapter\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/novels/next")) {
        nov.nextChapter();
        sendJson(stream, "{\"ok\":true,\"action\":\"novel_next\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/novels/prev")) {
        nov.prevChapter();
        sendJson(stream, "{\"ok\":true,\"action\":\"novel_prev\"}");
        return;
    }

    const a = @import("../core/alloc.zig").allocator;
    // text_buf alone is 128KB, and JSON escaping can nearly double it.
    const json_buf = a.alloc(u8, 384 * 1024) catch return;
    defer a.free(json_buf);
    var w = std.Io.Writer.fixed(json_buf);
    w.print("{{\"view\":\"{s}\",\"loading\":{s},\"chapters_loading\":{s},\"text_loading\":{s},\"error\":{s},\"title\":\"", .{
        @tagName(n.view),
        if (n.is_loading.load(.acquire)) "true" else "false",
        if (n.chapters_loading.load(.acquire)) "true" else "false",
        if (n.text_loading.load(.acquire)) "true" else "false",
        if (n.fetch_error) "true" else "false",
    }) catch return;
    escJsonWrite(&w, txt.safeUtf8(n.work_title[0..@min(n.work_title_len, n.work_title.len)]));
    w.writeAll("\",\"chapter_label\":\"") catch return;
    escJsonWrite(&w, txt.safeUtf8(n.chapter_label[0..@min(n.chapter_label_len, n.chapter_label.len)]));
    w.print("\",\"current_chapter\":{d},\"truncated\":{s},\"results\":[", .{
        n.current_chapter,
        if (n.text_truncated) "true" else "false",
    }) catch return;

    var i: usize = 0;
    const rn = nov.resultCount();
    while (i < rn) : (i += 1) {
        const row = nov.resultRow(i) orelse break;
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"title\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(row.title()));
        w.print("\",\"source\":{d}}}", .{row.source}) catch return;
    }
    w.writeAll("],\"chapters\":[") catch return;
    i = 0;
    const cn = nov.chapterCount();
    while (i < cn) : (i += 1) {
        const row = nov.chapterRow(i) orelse break;
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"title\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(row.title()));
        w.writeAll("\"}") catch return;
    }
    w.writeAll("],\"text\":\"") catch return;
    escJsonWrite(&w, txt.safeUtf8(n.text_buf[0..@min(n.text_len, n.text_buf.len)]));
    w.writeAll("\"}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

/// GET /api/abs — Audiobookshelf: libraries → books → play.
///
/// `/abs/login?server=&user=&pass=`, `/abs/libraries`, `/abs/open?idx=`,
/// `/abs/back`, `/abs/more`, `/abs/play?idx=`, `/abs/logout`.
fn apiAbs(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    const abs = @import("audiobookshelf.zig");
    const s = &state.app.abs;

    if (std.mem.eql(u8, api_path, "/abs/login")) {
        // Credentials come from the POST body where possible (credParam), so a
        // password never lands in a URL or an access log — same rule as
        // /api/auth/login.
        var dec: [256]u8 = undefined;
        if (getQueryParam(query, "server")) |v| {
            const sv = txt.safeUtf8(urlDecode(v, &dec) orelse v);
            const n = @min(sv.len, s.server_url.len);
            @memcpy(s.server_url[0..n], sv[0..n]);
            s.server_url_len = n;
        }
        if (getQueryParam(query, "user")) |v| {
            var d2: [128]u8 = undefined;
            const uv = txt.safeUtf8(urlDecode(v, &d2) orelse v);
            const n = @min(uv.len, s.login_user_buf.len - 1);
            @memcpy(s.login_user_buf[0..n], uv[0..n]);
            s.login_user_buf[n] = 0;
        }
        if (getQueryParam(query, "pass")) |v| {
            var d3: [128]u8 = undefined;
            const pv = urlDecode(v, &d3) orelse v;
            const n = @min(pv.len, s.login_pass_buf.len - 1);
            @memcpy(s.login_pass_buf[0..n], pv[0..n]);
            s.login_pass_buf[n] = 0;
        }
        abs.authenticate();
        sendJson(stream, "{\"ok\":true,\"action\":\"abs_login\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/abs/logout")) {
        abs.disconnect();
        sendJson(stream, "{\"ok\":true,\"action\":\"abs_logout\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/abs/libraries")) {
        abs.fetchLibraries();
        sendJson(stream, "{\"ok\":true,\"action\":\"abs_libraries\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/abs/open")) {
        const idx = std.fmt.parseInt(usize, getQueryParam(query, "idx") orelse "999", 10) catch 999;
        if (idx >= s.library_count) {
            sendJsonStatus(stream, "404 Not Found", "{\"error\":\"no such library\"}");
            return;
        }
        abs.openLibrary(idx);
        sendJson(stream, "{\"ok\":true,\"action\":\"abs_open\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/abs/back")) {
        abs.goToLibraries();
        sendJson(stream, "{\"ok\":true,\"action\":\"abs_back\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/abs/more")) {
        abs.loadMore();
        sendJson(stream, "{\"ok\":true,\"action\":\"abs_more\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/abs/play")) {
        const idx = std.fmt.parseInt(usize, getQueryParam(query, "idx") orelse "999", 10) catch 999;
        if (idx >= s.book_count) {
            sendJsonStatus(stream, "404 Not Found", "{\"error\":\"no such book\"}");
            return;
        }
        abs.playBook(idx);
        sendJson(stream, "{\"ok\":true,\"action\":\"abs_play\"}");
        return;
    }

    const a = @import("../core/alloc.zig").allocator;
    const json_buf = a.alloc(u8, 192 * 1024) catch return;
    defer a.free(json_buf);
    var w = std.Io.Writer.fixed(json_buf);
    w.print("{{\"connected\":{s},\"loading\":{s},\"view\":\"{s}\",\"server\":\"", .{
        if (s.connected) "true" else "false",
        if (s.is_loading.load(.acquire)) "true" else "false",
        @tagName(s.view),
    }) catch return;
    escJsonWrite(&w, s.server_url[0..@min(s.server_url_len, s.server_url.len)]);
    w.writeAll("\",\"error\":\"") catch return;
    escJsonWrite(&w, txt.safeUtf8(s.login_error[0..@min(s.login_error_len, s.login_error.len)]));
    w.writeAll("\",\"library\":\"") catch return;
    escJsonWrite(&w, txt.safeUtf8(s.selected_lib_name[0..@min(s.selected_lib_name_len, s.selected_lib_name.len)]));
    w.writeAll("\",\"libraries\":[") catch return;
    const ln = @min(s.library_count, s.libraries.len);
    for (s.libraries[0..ln], 0..) |*l, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"name\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(l.name[0..@min(l.name_len, l.name.len)]));
        w.writeAll("\",\"media_type\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(l.media_type[0..@min(l.media_type_len, l.media_type.len)]));
        w.writeAll("\"}") catch return;
    }
    w.writeAll("],\"books\":[") catch return;
    const bn = @min(s.book_count, s.books.len);
    for (s.books[0..bn], 0..) |*b, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"title\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(b.title[0..@min(b.title_len, b.title.len)]));
        w.writeAll("\",\"author\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(b.author[0..@min(b.author_len, b.author.len)]));
        w.print("\",\"duration\":{d}}}", .{b.duration_secs}) catch return;
    }
    w.writeAll("]}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

/// GET /api/opds — an OPDS catalog (Komga / Kavita / Calibre-Web / LANraragi).
/// Browse-only: `/opds/connect`, `/opds/open?idx=`, `/opds/back`, `/opds/more`,
/// `/opds/disconnect`.
fn apiOpds(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    const opds = @import("opds.zig");
    const o = &state.app.opds;

    if (std.mem.eql(u8, api_path, "/opds/connect")) {
        var dec: [256]u8 = undefined;
        if (getQueryParam(query, "server")) |v| {
            const sv = txt.safeUtf8(urlDecode(v, &dec) orelse v);
            const n = @min(sv.len, o.server_url.len);
            @memcpy(o.server_url[0..n], sv[0..n]);
            o.server_url_len = n;
        }
        // user_buf/pass_buf are NUL-TERMINATED with no _len companion (see
        // config.zig) — write the terminator, don't set a length.
        if (getQueryParam(query, "user")) |v| {
            var d2: [128]u8 = undefined;
            const uv = txt.safeUtf8(urlDecode(v, &d2) orelse v);
            const n = @min(uv.len, o.user_buf.len - 1);
            @memcpy(o.user_buf[0..n], uv[0..n]);
            o.user_buf[n] = 0;
        }
        if (getQueryParam(query, "pass")) |v| {
            var d3: [128]u8 = undefined;
            const pv = urlDecode(v, &d3) orelse v;
            const n = @min(pv.len, o.pass_buf.len - 1);
            @memcpy(o.pass_buf[0..n], pv[0..n]);
            o.pass_buf[n] = 0;
        }
        opds.connect();
        sendJson(stream, "{\"ok\":true,\"action\":\"opds_connect\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/opds/disconnect")) {
        opds.disconnect();
        sendJson(stream, "{\"ok\":true,\"action\":\"opds_disconnect\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/opds/open")) {
        const idx = std.fmt.parseInt(usize, getQueryParam(query, "idx") orelse "999", 10) catch 999;
        if (idx >= o.entry_count) {
            sendJsonStatus(stream, "404 Not Found", "{\"error\":\"no such entry\"}");
            return;
        }
        opds.openEntry(idx);
        sendJson(stream, "{\"ok\":true,\"action\":\"opds_open\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/opds/back")) {
        opds.goBack();
        sendJson(stream, "{\"ok\":true,\"action\":\"opds_back\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/opds/more")) {
        opds.loadMore();
        sendJson(stream, "{\"ok\":true,\"action\":\"opds_more\"}");
        return;
    }

    const a = @import("../core/alloc.zig").allocator;
    const json_buf = a.alloc(u8, 256 * 1024) catch return;
    defer a.free(json_buf);
    var w = std.Io.Writer.fixed(json_buf);
    w.print("{{\"connected\":{s},\"loading\":{s},\"depth\":{d},\"error\":{s},\"message\":\"", .{
        if (o.connected) "true" else "false",
        if (o.is_loading.load(.acquire)) "true" else "false",
        o.nav_depth,
        if (o.fetch_error) "true" else "false",
    }) catch return;
    escJsonWrite(&w, txt.safeUtf8(o.error_msg[0..@min(o.error_msg_len, o.error_msg.len)]));
    w.writeAll("\",\"feed\":\"") catch return;
    escJsonWrite(&w, txt.safeUtf8(o.feed_title[0..@min(o.feed_title_len, o.feed_title.len)]));
    w.writeAll("\",\"entries\":[") catch return;
    const n = @min(o.entry_count, o.entries.len);
    for (o.entries[0..n], 0..) |*e, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"title\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(e.titleSlice()));
        w.print("\",\"nav\":{s},\"streamable\":{s},\"pages\":{d},\"type\":\"", .{
            if (e.is_navigation) "true" else "false",
            if (e.isPseStreamable()) "true" else "false",
            e.pse_count,
        }) catch return;
        escJsonWrite(&w, txt.safeUtf8(e.contentTypeSlice()));
        w.writeAll("\"}") catch return;
    }
    w.writeAll("]}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

/// GET /api/plex — Plex sections → items → play.
///
/// Sign-in is Plex's PIN flow: `/plex/connect` starts it and the status payload
/// carries `pin`, which the user enters at plex.tv/link. There is no
/// username/password route because plex.zig doesn't have one.
fn apiPlex(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    const plex = @import("plex.zig");

    if (std.mem.eql(u8, api_path, "/plex/connect")) {
        plex.connect();
        sendJson(stream, "{\"ok\":true,\"action\":\"plex_connect\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/plex/disconnect")) {
        plex.disconnect();
        sendJson(stream, "{\"ok\":true,\"action\":\"plex_disconnect\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/plex/sections")) {
        plex.fetchSections();
        sendJson(stream, "{\"ok\":true,\"action\":\"plex_sections\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/plex/open")) {
        const idx = std.fmt.parseInt(usize, getQueryParam(query, "idx") orelse "999", 10) catch 999;
        if (idx >= plex.section_count) {
            sendJsonStatus(stream, "404 Not Found", "{\"error\":\"no such section\"}");
            return;
        }
        plex.fetchItems(idx);
        sendJson(stream, "{\"ok\":true,\"action\":\"plex_open\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/plex/more")) {
        plex.loadMore();
        sendJson(stream, "{\"ok\":true,\"action\":\"plex_more\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/plex/play")) {
        const idx = std.fmt.parseInt(usize, getQueryParam(query, "idx") orelse "999", 10) catch 999;
        if (idx >= plex.item_count) {
            sendJsonStatus(stream, "404 Not Found", "{\"error\":\"no such item\"}");
            return;
        }
        plex.play(idx);
        sendJson(stream, "{\"ok\":true,\"action\":\"plex_play\"}");
        return;
    }

    const a = @import("../core/alloc.zig").allocator;
    const json_buf = a.alloc(u8, 192 * 1024) catch return;
    defer a.free(json_buf);
    var w = std.Io.Writer.fixed(json_buf);
    w.print("{{\"connected\":{s},\"loading\":{s},\"state\":\"{s}\",\"active_section\":{d},\"server\":\"", .{
        if (plex.isConnected()) "true" else "false",
        if (plex.is_loading.load(.acquire)) "true" else "false",
        @tagName(plex.conn_state.load(.acquire)),
        plex.active_section,
    }) catch return;
    escJsonWrite(&w, txt.safeUtf8(plex.server_name[0..@min(plex.server_name_len, plex.server_name.len)]));
    w.writeAll("\",\"pin\":\"") catch return;
    escJsonWrite(&w, txt.safeUtf8(plex.pin_code[0..@min(plex.pin_code_len, plex.pin_code.len)]));
    w.writeAll("\",\"status\":\"") catch return;
    escJsonWrite(&w, txt.safeUtf8(plex.status_msg[0..@min(plex.status_msg_len, plex.status_msg.len)]));
    w.writeAll("\",\"sections\":[") catch return;
    const sn = @min(plex.section_count, plex.sections.len);
    for (plex.sections[0..sn], 0..) |*s, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"title\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(s.title[0..@min(s.title_len, s.title.len)]));
        w.writeAll("\"}") catch return;
    }
    w.writeAll("],\"items\":[") catch return;
    const inn = @min(plex.item_count, plex.items.len);
    for (plex.items[0..inn], 0..) |*it, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"title\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(it.title[0..@min(it.title_len, it.title.len)]));
        w.writeAll("\",\"year\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(it.year[0..@min(it.year_len, it.year.len)]));
        w.writeAll("\"}") catch return;
    }
    w.writeAll("]}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

/// Has /api/recommendations kicked the generator yet this process? Read/written
/// from connection threads → atomic.
var rec_kicked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// GET /api/recommendations — the desktop "For You" rail.
///
/// Async like every other vertical: the first call kicks the generator and comes
/// back `{"loading":true,"items":[]}`; the client re-polls. `recommendations[]`
/// carries no poster/year (see recommendations.zig), so the payload is title +
/// reason + tmdb id, which is exactly what the desktop rail renders.
fn apiRecommendations(stream: std.Io.net.Stream, query: []const u8) void {
    const rec = @import("recommendations.zig");
    // Kick ONCE per process (or on ?refresh=1). Gating on `rec_count == 0`
    // instead would re-kick forever for a user whose history yields no picks —
    // a legitimate empty result — and the client would poll `loading` for good.
    const refresh = std.mem.eql(u8, getQueryParam(query, "refresh") orelse "", "1");
    if ((refresh or !rec_kicked.swap(true, .acq_rel)) and !rec.is_loading.load(.acquire)) {
        // generateRecommendations snapshots the active player on THIS thread.
        state.players_mutex.lock();
        rec.generateRecommendations();
        state.players_mutex.unlock();
        sendJson(stream, "{\"loading\":true,\"items\":[]}");
        return;
    }
    const loading = rec.is_loading.load(.acquire);
    var json_buf: [16 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&json_buf);
    w.print("{{\"loading\":{s},\"items\":[", .{if (loading) "true" else "false"}) catch return;
    // The worker writes rec_count/recommendations[] unlocked — clamp, and treat
    // the lengths as untrusted so a torn read can't slice out of bounds.
    const n = @min(rec.rec_count, rec.recommendations.len);
    for (rec.recommendations[0..n], 0..) |*r, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"title\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(r.title[0..@min(r.title_len, r.title.len)]));
        w.writeAll("\",\"reason\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(r.reason[0..@min(r.reason_len, r.reason.len)]));
        w.print("\",\"id\":{d},\"score\":{d:.3}}}", .{ r.id, r.score }) catch return;
    }
    w.writeAll("]}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

/// Watch party (/party/*) and cast (/cast/*).
///
/// Both are LAN features that must answer with no player loaded, so this runs
/// before remote.zig's players_mutex tail. `/cast/start` is the one exception —
/// it needs the active player's URL, so it takes the mutex itself and hands the
/// URL to cast.zig by value rather than letting cast.zig re-read the list.
fn apiPartyCast(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    const wp = @import("watch_party.zig");
    const cast = @import("cast.zig");

    if (std.mem.eql(u8, api_path, "/party/host")) {
        wp.hostParty();
        sendJson(stream, "{\"ok\":true,\"action\":\"party_host\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/party/join")) {
        var dec: [64]u8 = undefined;
        const ip = urlDecode(getQueryParam(query, "ip") orelse "", &dec) orelse "";
        wp.joinParty(ip); // no-ops on empty / over-long input
        sendJson(stream, "{\"ok\":true,\"action\":\"party_join\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/party/leave")) {
        wp.leaveParty();
        sendJson(stream, "{\"ok\":true,\"action\":\"party_leave\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/party/chat")) {
        if (getQueryParam(query, "msg")) |m| {
            var dec: [256]u8 = undefined;
            const msg = txt.safeUtf8(urlDecode(m, &dec) orelse m);
            const n = @min(msg.len, wp.chat_input.len - 1);
            @memcpy(wp.chat_input[0..n], msg[0..n]);
            wp.chat_input[n] = 0;
            wp.sendChat();
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"party_chat\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/party/status")) {
        var sbuf: [64]u8 = undefined;
        const status = wp.statusText(&sbuf);
        var json_buf: [8 * 1024]u8 = undefined;
        var w = std.Io.Writer.fixed(&json_buf);
        w.print("{{\"role\":\"{s}\",\"connected\":{s},\"peers\":{d},\"port\":{d},\"host_ip\":\"{s}\",\"status\":\"", .{
            @tagName(wp.role),
            if (wp.role != .none) "true" else "false",
            wp.peerCount(),
            wp.party_port,
            lanIp(),
        }) catch return;
        escJsonWrite(&w, status);
        w.writeAll("\",\"chat\":[") catch return;
        const cn = @min(wp.chat_count, wp.chat_msgs.len);
        for (0..cn) |i| {
            if (i > 0) w.writeAll(",") catch return;
            w.writeAll("\"") catch return;
            escJsonWrite(&w, txt.safeUtf8(wp.chat_msgs[i][0..@min(wp.chat_msg_lens[i], wp.chat_msgs[i].len)]));
            w.writeAll("\"") catch return;
        }
        w.writeAll("]}") catch return;
        sendJson(stream, json_buf[0..w.end]);
        return;
    }

    if (std.mem.eql(u8, api_path, "/cast/scan")) {
        cast.scanDevices();
        sendJson(stream, "{\"ok\":true,\"action\":\"cast_scan\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/cast/start")) {
        const idx = std.fmt.parseInt(usize, getQueryParam(query, "idx") orelse "0", 10) catch 0;
        // castActive reads state.app.players — take the same lock the tail does.
        state.players_mutex.lock();
        cast.castActive(idx);
        state.players_mutex.unlock();
        sendJson(stream, "{\"ok\":true,\"action\":\"cast_start\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/cast/stop")) {
        cast.stopCast();
        sendJson(stream, "{\"ok\":true,\"action\":\"cast_stop\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/cast/devices")) {
        // First hit kicks a `catt scan`; the client polls until scanning clears.
        if (cast.device_count == 0 and !cast.is_scanning.load(.acquire)) cast.scanDevices();
        var json_buf: [4 * 1024]u8 = undefined;
        var w = std.Io.Writer.fixed(&json_buf);
        w.print("{{\"scanning\":{s},\"casting\":{s},\"active\":{?d},\"devices\":[", .{
            if (cast.is_scanning.load(.acquire)) "true" else "false",
            if (cast.is_casting.load(.acquire)) "true" else "false",
            cast.active_device_idx,
        }) catch return;
        const n = @min(cast.device_count, cast.devices.len);
        for (cast.devices[0..n], 0..) |*d, i| {
            if (i > 0) w.writeAll(",") catch return;
            w.writeAll("{\"name\":\"") catch return;
            escJsonWrite(&w, txt.safeUtf8(d.name[0..@min(d.name_len, d.name.len)]));
            w.writeAll("\",\"ip\":\"") catch return;
            escJsonWrite(&w, txt.safeUtf8(d.ip[0..@min(d.ip_len, d.ip.len)]));
            w.writeAll("\"}") catch return;
        }
        w.writeAll("]}") catch return;
        sendJson(stream, json_buf[0..w.end]);
        return;
    }
    sendJson(stream, "{\"error\":\"unknown\"}");
}

fn apiComics(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    if (std.mem.eql(u8, api_path, "/comics/load")) {
        if (getQueryParam(query, "url")) |url| {
            var decoded: [512]u8 = undefined;
            const comic_url = urlDecode(url, &decoded) orelse url;
            const comics_svc = @import("comics.zig");
            // Defer to the UI thread: loadComic frees textures via dvui (UI-only).
            comics_svc.requestLoad(comic_url);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"load_comic\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/comics/search")) {
        if (getQueryParam(query, "q")) |q| {
            var decoded: [256]u8 = undefined;
            const term = txt.safeUtf8(urlDecode(q, &decoded) orelse q);
            // searchComics spawns its own worker and no-ops while one is in
            // flight, so this is safe to call straight from a connection thread.
            @import("comics.zig").searchComics(term);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"comic_search\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/comics/results")) {
        const comics_svc = @import("comics.zig");
        const a = @import("../core/alloc.zig").allocator;
        // 120 rows × (url + title + cover url) — heap, not the thread stack.
        const json_buf = a.alloc(u8, 96 * 1024) catch return;
        defer a.free(json_buf);
        var w = std.Io.Writer.fixed(json_buf);
        w.print("{{\"loading\":{s},\"results\":[", .{
            if (comics_svc.searching()) "true" else "false",
        }) catch return;
        var i: usize = 0;
        while (i < comics_svc.searchCount()) : (i += 1) {
            const row = comics_svc.searchRow(i) orelse break;
            if (i > 0) w.writeAll(",") catch return;
            w.writeAll("{\"title\":\"") catch return;
            escJsonWrite(&w, txt.safeUtf8(row.title));
            w.writeAll("\",\"url\":\"") catch return;
            escJsonWrite(&w, row.url);
            w.writeAll("\",\"cover\":\"") catch return;
            escJsonWrite(&w, row.cover_url);
            w.writeAll("\"}") catch return;
        }
        w.writeAll("]}") catch return;
        sendJson(stream, json_buf[0..w.end]);
        return;
    }
    if (std.mem.eql(u8, api_path, "/comics/close")) {
        // closeComic frees dvui textures → UI thread only; requestClose defers.
        @import("comics.zig").requestClose();
        sendJson(stream, "{\"ok\":true,\"action\":\"close_comic\"}");
        return;
    }
    // Return current state. `downloaded` vs `pages` is what the reader polls to
    // know which /api/comics/page?i= indices will answer 200 rather than 404.
    const cm = &state.app.comic;
    var json_buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&json_buf);
    w.print("{{\"loading\":{s},\"pages\":{d},\"downloaded\":{d},\"current\":{d},\"has_next\":{s},\"has_prev\":{s},\"title\":\"", .{
        if (cm.is_loading.load(.acquire)) "true" else "false",
        cm.page_count,
        cm.dl_progress.load(.acquire),
        cm.current_page,
        if (cm.next_url_len > 0) "true" else "false",
        if (cm.prev_url_len > 0) "true" else "false",
    }) catch return;
    escJsonWrite(&w, txt.safeUtf8(cm.title[0..@min(cm.title_len, cm.title.len)]));
    w.writeAll("\",\"url\":\"") catch return;
    escJsonWrite(&w, cm.url_buf[0..cm.url_len]);
    w.writeAll("\"}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

fn apiJellyfin(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    const jf = @import("jellyfin.zig");

    if (std.mem.eql(u8, api_path, "/jellyfin/login")) {
        // Set server URL, username, password then authenticate
        if (getQueryParam(query, "server")) |s| {
            var decoded: [256]u8 = undefined;
            const sv = @import("../core/text.zig").safeUtf8(urlDecode(s, &decoded) orelse s);
            const slen = @min(sv.len, 255);
            @memcpy(state.app.jf.server_url[0..slen], sv[0..slen]);
            state.app.jf.server_url_len = slen;
        }
        if (getQueryParam(query, "user")) |u| {
            var decoded: [128]u8 = undefined;
            const uv = @import("../core/text.zig").safeUtf8(urlDecode(u, &decoded) orelse u);
            const ulen = @min(uv.len, 127);
            @memcpy(state.app.jf.login_user_buf[0..ulen], uv[0..ulen]);
            state.app.jf.login_user_buf[ulen] = 0;
        }
        if (getQueryParam(query, "pass")) |p| {
            var decoded: [128]u8 = undefined;
            const pv = urlDecode(p, &decoded) orelse p;
            const plen = @min(pv.len, 127);
            @memcpy(state.app.jf.login_pass_buf[0..plen], pv[0..plen]);
            state.app.jf.login_pass_buf[plen] = 0;
        }
        jf.authenticate();
        sendJson(stream, "{\"ok\":true,\"action\":\"login\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/jellyfin/disconnect")) {
        jf.disconnect();
        sendJson(stream, "{\"ok\":true,\"action\":\"disconnect\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/jellyfin/libraries")) {
        jf.fetchLibraries();
        sendJson(stream, "{\"ok\":true,\"action\":\"fetch_libraries\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/jellyfin/browse")) {
        if (getQueryParam(query, "id")) |id| {
            var decoded: [64]u8 = undefined;
            const pid = urlDecode(id, &decoded) orelse id;
            jf.fetchItems(pid);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"browse\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/jellyfin/search")) {
        if (getQueryParam(query, "q")) |q| {
            var decoded: [256]u8 = undefined;
            const dq = urlDecode(q, &decoded) orelse q;
            const safe = @import("../core/text.zig").safeUtf8(dq);
            const slen = @min(safe.len, 255);
            @memcpy(state.app.jf.search_buf[0..slen], safe[0..slen]);
            state.app.jf.search_buf[slen] = 0;
            jf.searchItems();
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"search\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/jellyfin/play")) {
        if (getQueryParam(query, "id")) |id| {
            var decoded: [64]u8 = undefined;
            const pid = urlDecode(id, &decoded) orelse id;
            jf.playItem(pid);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"play\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/jellyfin/play_audio")) {
        if (getQueryParam(query, "id")) |id| {
            var decoded: [64]u8 = undefined;
            const pid = urlDecode(id, &decoded) orelse id;
            jf.playAudioItem(pid);
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"play_audio\"}");
        return;
    }

    // Default: return full status
    var json_buf: [32768]u8 = undefined;
    var w = std.Io.Writer.fixed(&json_buf);
    w.writeAll("{\"connected\":") catch return;
    w.writeAll(if (state.app.jf.connected) "true" else "false") catch return;
    w.writeAll(",\"loading\":") catch return;
    w.writeAll(if (state.app.jf.is_loading.load(.acquire)) "true" else "false") catch return;

    // Login error
    if (state.app.jf.login_error_len > 0) {
        w.writeAll(",\"error\":\"") catch return;
        escJsonWrite(&w, state.app.jf.login_error[0..state.app.jf.login_error_len]);
        w.writeAll("\"") catch return;
    }

    // Libraries
    w.writeAll(",\"libraries\":[") catch return;
    for (0..state.app.jf.library_count) |li| {
        const lib = state.app.jf.libraries[li];
        if (li > 0) w.writeAll(",") catch return;
        w.writeAll("{\"id\":\"") catch return;
        escJsonWrite(&w, lib.id[0..lib.id_len]);
        w.writeAll("\",\"name\":\"") catch return;
        escJsonWrite(&w, lib.name[0..lib.name_len]);
        w.writeAll("\",\"type\":\"") catch return;
        escJsonWrite(&w, lib.collection_type[0..lib.collection_type_len]);
        w.writeAll("\"}") catch return;
    }

    // Items
    w.writeAll("],\"items\":[") catch return;
    for (0..state.app.jf.item_count) |ii| {
        const item = state.app.jf.items[ii];
        if (ii > 0) w.writeAll(",") catch return;
        const runtime_sec = @divTrunc(item.runtime_ticks, 10_000_000);
        w.writeAll("{\"id\":\"") catch return;
        escJsonWrite(&w, item.id[0..item.id_len]);
        w.writeAll("\",\"name\":\"") catch return;
        escJsonWrite(&w, item.name[0..item.name_len]);
        w.writeAll("\",\"type\":\"") catch return;
        escJsonWrite(&w, item.media_type[0..item.media_type_len]);
        w.print("\",\"year\":{d},\"folder\":{s},\"runtime\":{d},\"image\":{s}}}", .{
            item.year,
            if (item.is_folder) "true" else "false",
            runtime_sec,
            if (item.has_image) "true" else "false",
        }) catch return;
    }
    w.writeAll("]}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

// ══════════════════════════════════════════════════════════
// Unified Search — "Google for Media"
// Triggers search across all sources and returns merged results.
// Call with ?q=<query> to trigger. Call without to just read current results.
// ══════════════════════════════════════════════════════════

fn apiUnifiedSearch(stream: std.Io.net.Stream, query: []const u8) void {
    if (getQueryParam(query, "q")) |q| {
        var decoded: [256]u8 = undefined;
        const dq = urlDecode(q, &decoded) orelse q;
        const slen = @min(dq.len, 255);

        // 1. Trigger torrent search
        const search_svc = @import("search.zig");
        search_svc.triggerSearch(dq);

        // 2. Trigger TMDB search (if API key set)
        if (state.app.tmdb.api_key_len > 0) {
            @memcpy(state.app.tmdb.search_buf[0..slen], dq[0..slen]);
            state.app.tmdb.search_buf[slen] = 0;
            state.app.tmdb.view = .Search;
            state.app.tmdb.page = 1;
            const tmdb_api = @import("tmdb_api.zig");
            tmdb_api.fetchCurrentView(false);
        }

        // 3. Trigger YouTube search
        @memcpy(state.app.yt.search_buf[0..slen], dq[0..slen]);
        state.app.yt.search_buf[slen] = 0;
        const yt = @import("youtube.zig");
        const yt_qlen = std.mem.indexOfScalar(u8, &state.app.yt.search_buf, 0) orelse state.app.yt.search_buf.len;
        yt.fetchYoutube(state.app.yt.search_buf[0..yt_qlen]);

        // 4. Trigger Anime search
        @memcpy(state.app.anime.search_buf[0..slen], dq[0..slen]);
        state.app.anime.search_buf[slen] = 0;
        const anime = @import("anime.zig");
        const anime_qlen = std.mem.indexOfScalar(u8, &state.app.anime.search_buf, 0) orelse state.app.anime.search_buf.len;
        anime.searchAnime(state.app.anime.search_buf[0..anime_qlen]);

        // 5. Trigger Jellyfin search (if connected)
        if (state.app.jf.connected) {
            @memcpy(state.app.jf.search_buf[0..slen], dq[0..slen]);
            state.app.jf.search_buf[slen] = 0;
            const jf = @import("jellyfin.zig");
            jf.searchItems();
        }
    }

    // ── Collect results from all sources ──
    var json_buf: [65536]u8 = undefined;
    var w = std.Io.Writer.fixed(&json_buf);

    // Track loading state across all sources
    const search_svc = @import("search.zig");
    const any_loading = search_svc.is_searching.load(.acquire) or
        state.app.tmdb.is_loading.load(.acquire) or
        state.app.yt.is_loading.load(.acquire) or
        state.app.anime.is_loading.load(.acquire) or
        state.app.jf.is_loading.load(.acquire);

    w.writeAll("{\"loading\":") catch return;
    w.writeAll(if (any_loading) "true" else "false") catch return;
    w.writeAll(",\"results\":[") catch return;

    var total: usize = 0;

    // ── Torrent results ──
    {
        search_svc.search_results_mutex.lock();
        defer search_svc.search_results_mutex.unlock();
        for (search_svc.search_results.items) |r| {
            if (w.end + 2048 > json_buf.len) break; // reserve tail → never truncate mid-array
            if (total > 0) w.writeAll(",") catch return;
            w.writeAll("{\"source\":\"torrent\",\"title\":\"") catch return;
            escJsonWrite(&w, r.name);
            w.writeAll("\",\"detail\":\"") catch return;
            escJsonWrite(&w, r.size);
            w.writeAll(" · ") catch return;
            escJsonWrite(&w, r.seeds);
            w.writeAll(" seeds\",\"action\":\"magnet\",\"data\":\"") catch return;
            escJsonWrite(&w, r.link);
            w.writeAll("\"}") catch return;
            total += 1;
            if (total >= 80) break;
        }
    }

    // ── TMDB results ── (HTTP thread: iterate under results_mutex — the UI
    // thread mutates `results` under it in applyPendingResults)
    if (state.app.tmdb.api_key_len > 0) {
        state.app.tmdb.results_mutex.lock();
        defer state.app.tmdb.results_mutex.unlock();
        for (state.app.tmdb.results.items, 0..) |item, idx| {
            if (idx >= 10) break;
            if (w.end + 2048 > json_buf.len) break;
            if (total > 0) w.writeAll(",") catch return;
            const rating_pct = @as(u8, @intFromFloat(std.math.clamp(item.rating * 10.0, 0.0, 100.0)));
            w.writeAll("{\"source\":\"tmdb\",\"title\":\"") catch return;
            escJsonWrite(&w, item.title[0..item.title_len]);
            w.writeAll("\",\"detail\":\"") catch return;
            escJsonWrite(&w, item.year[0..item.year_len]);
            w.print(" · {d}%\",\"action\":\"tmdb_detail\",\"data\":\"{d}\"}}", .{
                rating_pct,
                item.id,
            }) catch return;
            total += 1;
        }
    }

    // ── YouTube results ──
    for (state.app.yt.results.items) |yt_item| {
        if (total >= 80) break;
        if (w.end + 2048 > json_buf.len) break;
        if (yt_item.title_len == 0) continue;
        if (total > 0) w.writeAll(",") catch return;
        w.writeAll("{\"source\":\"youtube\",\"title\":\"") catch return;
        escJsonWrite(&w, yt_item.title[0..yt_item.title_len]);
        w.writeAll("\",\"detail\":\"") catch return;
        escJsonWrite(&w, yt_item.uploader[0..yt_item.uploader_len]);
        w.writeAll("\",\"action\":\"yt_play\",\"data\":\"") catch return;
        escJsonWrite(&w, yt_item.video_id[0..yt_item.video_id_len]);
        w.writeAll("\"}") catch return;
        total += 1;
    }

    // ── Anime results ──
    for (0..state.app.anime.result_count) |ai| {
        if (total >= 80) break;
        if (w.end + 2048 > json_buf.len) break;
        const a_item = state.app.anime.results[ai];
        if (a_item.name_len == 0) continue;
        if (total > 0) w.writeAll(",") catch return;
        w.writeAll("{\"source\":\"anime\",\"title\":\"") catch return;
        escJsonWrite(&w, a_item.name[0..a_item.name_len]);
        w.writeAll("\",\"detail\":\"Anime\",\"action\":\"anime_detail\",\"data\":\"") catch return;
        escJsonWrite(&w, a_item.id[0..a_item.id_len]);
        w.writeAll("\"}") catch return;
        total += 1;
    }

    // ── Jellyfin results ──
    if (state.app.jf.connected) {
        for (0..state.app.jf.item_count) |ji| {
            if (total >= 80) break;
            if (w.end + 2048 > json_buf.len) break;
            const jf_item = state.app.jf.items[ji];
            if (jf_item.name_len == 0) continue;
            if (total > 0) w.writeAll(",") catch return;
            const act: []const u8 = if (jf_item.is_folder) "jf_browse" else "jf_play";
            w.writeAll("{\"source\":\"jellyfin\",\"title\":\"") catch return;
            escJsonWrite(&w, jf_item.name[0..jf_item.name_len]);
            w.writeAll("\",\"detail\":\"") catch return;
            escJsonWrite(&w, jf_item.media_type[0..jf_item.media_type_len]);
            w.print("\",\"action\":\"{s}\",\"data\":\"", .{act}) catch return;
            escJsonWrite(&w, jf_item.id[0..jf_item.id_len]);
            w.writeAll("\"}") catch return;
            total += 1;
        }
    }

    w.writeAll("]}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

// ── Web parity handlers (H3) ─────────────────────────────────────────────────

/// Snapshot the active player's status as JSON into `buf`. Empty-media when no
/// player is active. Shared by /api/status and the /events SSE stream.
fn buildStatusJson(buf: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    if (state.app.active_player_idx >= state.app.players.items.len) {
        w.writeAll("{\"pos\":0,\"dur\":0,\"vol\":0,\"paused\":true,\"title\":\"No media\"}") catch return buf[0..0];
        return buf[0..w.end];
    }
    const ap = state.app.players.items[state.app.active_player_idx];
    var pos: f64 = 0;
    var dur: f64 = 0;
    var vol: f64 = 0;
    var paused: c_int = 0;
    _ = c.mpv.mpv_get_property(ap.mpv_ctx, "time-pos", c.mpv.MPV_FORMAT_DOUBLE, &pos);
    _ = c.mpv.mpv_get_property(ap.mpv_ctx, "duration", c.mpv.MPV_FORMAT_DOUBLE, &dur);
    _ = c.mpv.mpv_get_property(ap.mpv_ctx, "volume", c.mpv.MPV_FORMAT_DOUBLE, &vol);
    _ = c.mpv.mpv_get_property(ap.mpv_ctx, "pause", c.mpv.MPV_FORMAT_FLAG, &paused);
    var title_prop: [*c]u8 = null;
    _ = c.mpv.mpv_get_property(ap.mpv_ctx, "media-title", c.mpv.MPV_FORMAT_STRING, @ptrCast(&title_prop));
    defer if (title_prop != null) c.mpv.mpv_free(@ptrCast(title_prop));
    const title_str = if (title_prop != null) std.mem.span(title_prop) else "No media";
    w.print("{{\"pos\":{d:.1},\"dur\":{d:.1},\"vol\":{d:.0},\"paused\":{s},\"title\":\"", .{
        pos, dur, vol, if (paused != 0) "true" else "false",
    }) catch return buf[0..0];
    escJsonWrite(&w, title_str);
    w.writeAll("\"}") catch return buf[0..0];
    return buf[0..w.end];
}

fn apiCalendar(stream: std.Io.net.Stream) void {
    const cal = @import("tv_calendar.zig");
    cal.refreshOnce(); // no-op after the first session refresh
    var jb: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&jb);
    w.writeAll("{\"entries\":[") catch return;
    for (0..cal.count) |i| {
        const e = &cal.entries[i];
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"name\":\"") catch return;
        escJsonWrite(&w, e.name[0..e.name_len]);
        w.print("\",\"tmdb_id\":{d},\"next_season\":{d},\"next_episode\":{d},\"next_air\":{d},\"last_season\":{d},\"last_episode\":{d},\"available\":{s},\"seeds\":{d},\"unseen\":{s},\"poster\":\"", .{
            e.tmdb_id,          e.next_season, e.next_episode,
            e.next_air_epoch,   e.last_season, e.last_episode,
            if (e.available) "true" else "false", e.seeds,
            if (e.unseen) "true" else "false",
        }) catch return;
        escJsonWrite(&w, e.poster_path[0..e.poster_path_len]);
        w.writeAll("\"}") catch return;
    }
    w.writeAll("]}") catch return;
    sendJson(stream, jb[0..w.end]);
}

/// `/api/library` → the Watching library, in the same display order the desktop
/// uses (tv_pure.sortOrder), so the two surfaces list shows identically.
///
/// Both the row buffer and the response are heap-allocated: a Row is ~600 bytes
/// and 200 of them plus the JSON would blow a spawned thread's stack (CLAUDE.md).
fn apiLibrary(stream: std.Io.net.Stream) void {
    const lib = @import("tv_library.zig");
    const tp = @import("tv_pure.zig");
    const alloc = @import("../core/alloc.zig").allocator;

    const buf = alloc.alloc(tp.Row, tp.MAX_SHOWS) catch {
        sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(buf);
    const n = lib.snapshotCopy(buf);

    const out = alloc.alloc(u8, 128 * 1024) catch {
        sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(out);
    var w = std.Io.Writer.fixed(out);

    w.writeAll("{\"items\":[") catch return;
    for (buf[0..n], 0..) |*r, i| {
        if (i > 0) w.writeAll(",") catch return;
        var st_buf: [48]u8 = undefined;
        const st = tp.statusLabel(r, &st_buf);
        w.writeAll("{\"name\":\"") catch return;
        escJsonWrite(&w, r.name[0..@min(r.name_len, r.name.len)]);
        w.writeAll("\",\"id\":\"") catch return;
        escJsonWrite(&w, r.id[0..@min(r.id_len, r.id.len)]);
        // `status` is a human display string ("S01E01 · Next", "78% watched").
        // `state` is the machine tag the desktop's filter chips use — the page
        // must filter on that, not on the label, or "Watching" matches nothing.
        w.print("\",\"kind\":\"{s}\",\"tmdb_id\":{d},\"watched\":{d},\"total\":{d}," ++
            "\"has_next\":{s},\"next_season\":{d},\"next_episode\":{d},\"pct\":{d:.0}," ++
            "\"state\":\"{s}\",\"status\":\"", .{
            @tagName(r.kind),
            r.tmdb_id,
            r.prog.watched,
            r.prog.total,
            if (r.has_next) "true" else "false",
            r.next.season,
            r.next.episode,
            r.pct,
            @tagName(tp.effectiveStatus(r.user, r.status)),
        }) catch return;
        escJsonWrite(&w, st);
        w.writeAll("\",\"poster\":\"") catch return;
        escJsonWrite(&w, r.poster_url[0..@min(r.poster_url_len, r.poster_url.len)]);
        w.writeAll("\"}") catch return;
    }
    w.writeAll("]}") catch return;
    sendJson(stream, out[0..w.end]);
}

/// `/api/tv/recent?id=<tmdb_id>` → the latest aired episode + watched flag.
///
/// `{"found":false}` when the aired frontier is unknown (the show has not been
/// synced yet) — deliberately NOT a 404 and not a guess: the web page hides its
/// Play-latest button rather than offering one that would hunt for an episode
/// nobody knows exists.
fn apiTvRecent(stream: std.Io.net.Stream, query: []const u8) void {
    const id = std.fmt.parseInt(i32, getQueryParam(query, "id") orelse "", 10) catch {
        sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"missing id\"}");
        return;
    };
    const latest = @import("tv_library.zig").lastAiredFor(id) orelse {
        sendJson(stream, "{\"found\":false}");
        return;
    };
    var lbl_buf: [48]u8 = undefined;
    const label = @import("tv_pure.zig").recentEpisodeLabel(latest.ep, latest.watched, &lbl_buf);
    var jb: [192]u8 = undefined;
    const j = std.fmt.bufPrint(&jb,
        \\{{"found":true,"season":{d},"episode":{d},"watched":{s},"label":"{s}"}}
    , .{
        latest.ep.season,
        latest.ep.episode,
        if (latest.watched) "true" else "false",
        label,
    }) catch return;
    sendJson(stream, j);
}

fn apiTorrents(stream: std.Io.net.Stream) void {
    var jb: [16384]u8 = undefined;
    var w = std.Io.Writer.fixed(&jb);
    w.writeAll("{\"torrents\":[") catch return;
    const n = c.mpv.torrent_count(state.torrentSession());
    var emitted: usize = 0;
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        if (c.mpv.torrent_is_alive(state.torrentSession(), i) == 0) continue;
        var t_name: [256]u8 = undefined;
        c.mpv.torrent_get_name(state.torrentSession(), i, &t_name, 256);
        const name_len = std.mem.indexOfScalar(u8, &t_name, 0) orelse 255;
        var progress: f32 = 0;
        var dl_rate: c_int = 0;
        var seeds: c_int = 0;
        _ = c.mpv.torrent_poll(state.torrentSession(), i, -1, null, 0, &progress, &dl_rate, &seeds);
        if (emitted > 0) w.writeAll(",") catch return;
        w.writeAll("{\"name\":\"") catch return;
        escJsonWrite(&w, t_name[0..name_len]);
        // One decimal, not a u8. Measured 2026-08-04 on a 129 MB torrent moving
        // at ~1 KB/s: it read "0%" for the first 1.3 MB, i.e. for twenty minutes,
        // while pieces were genuinely landing. A slow torrent and a dead one
        // looked identical, which is the one distinction this number exists to
        // make.
        w.print("\",\"id\":{d},\"pct\":{d:.1},\"rate\":{d},\"seeds\":{d},\"paused\":{s}}}", .{
            i,
            std.math.clamp(progress * 100.0, 0.0, 100.0),
            dl_rate,
            seeds,
            if (c.mpv.torrent_is_paused(state.torrentSession(), i) != 0) "true" else "false",
        }) catch return;
        emitted += 1;
    }
    w.writeAll("]}") catch return;
    sendJson(stream, jb[0..w.end]);
}

/// /api/tv?id=123[&season=2] → the raw TMDB JSON for /3/tv/{id} or
/// /3/tv/{id}/season/{n}. Passthrough keeps the key server-side and spares
/// us re-modeling TMDB's (already-JSON) shape.
fn apiTvPassthrough(stream: std.Io.net.Stream, query: []const u8) void {
    const id_str = getQueryParam(query, "id") orelse return sendJson(stream, "{\"error\":\"id required\"}");
    const id = std.fmt.parseInt(i32, id_str, 10) catch return sendJson(stream, "{\"error\":\"bad id\"}");
    if (state.app.tmdb.api_key_len == 0) return sendJson(stream, "{\"error\":\"no tmdb key\"}");

    var path_buf: [96]u8 = undefined;
    const api_path2 = if (getQueryParam(query, "season")) |sn_str| blk: {
        const sn = std.fmt.parseInt(i32, sn_str, 10) catch 0;
        break :blk std.fmt.bufPrint(&path_buf, "/3/tv/{d}/season/{d}", .{ id, sn }) catch return;
    } else std.fmt.bufPrint(&path_buf, "/3/tv/{d}", .{id}) catch return;

    const alloc2 = @import("../core/alloc.zig").allocator;
    const body = alloc2.alloc(u8, 256 * 1024) catch return;
    defer alloc2.free(body);
    const n = @import("tmdb_api.zig").tmdbApiInto(api_path2, state.app.tmdb.api_key[0..state.app.tmdb.api_key_len], body);
    if (n == 0) return sendJson(stream, "{\"error\":\"tmdb fetch failed\"}");
    sendJson(stream, body[0..n]);
}
