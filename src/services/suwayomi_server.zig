//! Embedded Suwayomi-Server lifecycle — Opal owns the whole server so the user
//! never runs it separately: download the runnable jar once, launch it headless,
//! stop it, and auto-point Opal's Suwayomi source at it. The extension INDEX,
//! install and content browse then all happen in-app (Comics → Extensions).
//!
//! The server is a Java jar (needs a JRE). It's launched headless with the flags
//! that were verified to bind the port in a GUI-less session (systemTray +
//! webUI + browser-open all off — the tray init otherwise blocks before the HTTP
//! port binds). First launch also downloads a CEF bundle inside the server (for
//! its Cloudflare-bypass browser), so "starting" can take a while — the status
//! text reflects each phase.
//!
//! Managed like the AI llama-server sidecar (ai_server.zig): spawn + stop by
//! `pkill -f`, status atomics the UI polls, background worker for the blocking
//! download/start. Killed on app shutdown (main.zig) so no orphaned JVM.

const std = @import("std");
const io = @import("../core/io_global.zig");
const paths = @import("../core/paths.zig");
const logs = @import("../core/logs.zig");
const source_config = @import("../core/source_config.zig");
const state = @import("../core/state.zig");

const alloc = @import("../core/alloc.zig").allocator;

// Pinned server version. The jar filename + download URL derive from it. Bumping
// this points at a newer release (the user re-downloads on next start).
const VERSION = "v2.3.2243";
const JAR_NAME = "Suwayomi-Server-" ++ VERSION ++ ".jar";
const DL_URL = "https://github.com/Suwayomi/Suwayomi-Server/releases/download/" ++ VERSION ++ "/" ++ JAR_NAME;
const PORT = "4567";
pub const BASE_URL = "http://localhost:" ++ PORT;
// The jar is identified for pkill by this substring (unique to our launch).
const PKILL_PAT = "Suwayomi-Server-";

pub const Status = enum(u8) { idle, no_java, downloading, starting, running, err };

var status: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(Status.idle));
var msg_buf: [96]u8 = std.mem.zeroes([96]u8);
var msg_len: usize = 0;
var busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn setStatus(s: Status, m: []const u8) void {
    status.store(@intFromEnum(s), .release);
    const k = @min(m.len, msg_buf.len);
    @memcpy(msg_buf[0..k], m[0..k]);
    msg_len = k;
    if (state.app.dvui_win) |w| @import("dvui").refresh(w, @src(), null);
}

pub fn statusEnum() Status {
    return @enumFromInt(status.load(.acquire));
}
pub fn statusText() []const u8 {
    return msg_buf[0..msg_len];
}
pub fn isRunning() bool {
    return statusEnum() == .running;
}

/// `<config>/suwayomi/<JAR_NAME>`.
fn jarPath(buf: []u8) ?[]const u8 {
    var cfg_buf: [512]u8 = undefined;
    const cfg = paths.configDir(&cfg_buf);
    return std.fmt.bufPrint(buf, "{s}/suwayomi/{s}", .{ cfg, JAR_NAME }) catch null;
}

/// Suwayomi's default data root (where it reads `server.conf` + keeps its DB).
/// The `-DrootDir` system property is ignored by v2.3, so we target the
/// per-platform default that the server actually uses.
fn dataDir(buf: []u8) ?[]const u8 {
    const builtin = @import("builtin");
    const home = io.getenv("HOME") orelse io.getenv("USERPROFILE") orelse return null;
    return switch (builtin.os.tag) {
        .macos => std.fmt.bufPrint(buf, "{s}/Library/Application Support/Tachidesk", .{home}) catch null,
        .windows => blk: {
            const appdata = io.getenv("APPDATA") orelse break :blk null;
            break :blk std.fmt.bufPrint(buf, "{s}/Tachidesk", .{appdata}) catch null;
        },
        else => blk: {
            const xdg = io.getenv("XDG_DATA_HOME");
            break :blk if (xdg) |x|
                std.fmt.bufPrint(buf, "{s}/Tachidesk", .{x}) catch null
            else
                std.fmt.bufPrint(buf, "{s}/.local/share/Tachidesk", .{home}) catch null;
        },
    };
}

/// Write `server.conf` so the embedded server runs cleanly, verified end-to-end
/// against a live v2.3 server:
///   • systemTrayEnabled=false — the `-D` property is ignored, and forcing
///     `java.awt.headless=true` instead makes the tray code NPE-crash the JVM.
///   • kcefEnabled=false — the bundled Chromium (CEF) WebView otherwise loads a
///     native lib at startup that crashes headless AND pulls a ~226 MB download;
///     disabling it makes the server start fast and reliably. (Trade-off: no
///     built-in Cloudflare bypass; most Mihon sources don't need it.)
///   • extensionStores = [curated repos] — v2.3 loads repos from THIS config key
///     (not the GraphQL extensionRepos setting), so pre-seeding it means every
///     curated extension is installable via the REST endpoint the panel uses.
/// Best-effort: a write failure just means the user manages the server manually.
fn writeServerConf() void {
    var dd_buf: [700]u8 = undefined;
    const dd = dataDir(&dd_buf) orelse return;
    io.cwdMakePath(dd) catch {};
    var path_buf: [800]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/server.conf", .{dd}) catch return;

    // Build the extensionStores array from the curated repo list.
    const repo = @import("mihon_repo_pure.zig");
    var buf: [4096]u8 = undefined;
    var w: usize = 0;
    const head =
        "server.systemTrayEnabled = false\n" ++
        "server.webUIEnabled = false\n" ++
        "server.initialOpenInBrowserEnabled = false\n" ++
        "server.kcefEnabled = false\n" ++
        "server.extensionStores = [";
    appendConf(&buf, &w, head);
    for (repo.REPOS, 0..) |r, i| {
        if (i > 0) appendConf(&buf, &w, ",");
        appendConf(&buf, &w, "\"");
        appendConf(&buf, &w, r.url);
        appendConf(&buf, &w, "\"");
    }
    appendConf(&buf, &w, "]\n");
    io.cwdWriteFile(.{ .sub_path = path, .data = buf[0..w] }) catch {};
}

fn appendConf(buf: []u8, w: *usize, s: []const u8) void {
    if (w.* + s.len > buf.len) return;
    @memcpy(buf[w.*..][0..s.len], s);
    w.* += s.len;
}

fn hasJava() bool {
    var c = io.Child.init(&.{ "java", "-version" }, alloc);
    c.stdout_behavior = .Ignore;
    c.stderr_behavior = .Ignore;
    c.spawn() catch return false;
    const term = c.wait() catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Whether a file exists (cwdStatFile returns an error union, not an optional).
fn fileExists(path: []const u8) bool {
    _ = io.cwdStatFile(path) catch return false;
    return true;
}

/// True if the server answers on the port.
fn pingPort() bool {
    var c = io.Child.init(&.{ "curl", "-sL", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "4", BASE_URL ++ "/api/v1/extension/list" }, alloc);
    c.stdout_behavior = .Pipe;
    c.stderr_behavior = .Ignore;
    c.spawn() catch return false;
    var b: [16]u8 = undefined;
    const n = if (c.stdout) |*so| io.readAll(so, &b) catch 0 else 0;
    _ = c.wait() catch {};
    return std.mem.startsWith(u8, std.mem.trim(u8, b[0..n], " \r\n"), "200");
}

/// Point Opal's Suwayomi source at the embedded server (keep any picked source id).
fn setBaseUrl() void {
    var body: [256]u8 = undefined;
    const src = source_config.get("suwayomi", "source") orelse "";
    if (std.fmt.bufPrint(&body, "{{\"base\":\"{s}\",\"source\":\"{s}\"}}", .{ BASE_URL, src })) |b| {
        _ = source_config.install("suwayomi", b);
    } else |_| {}
}

// ── Public control ──

/// Ensure the server is downloaded + running (background). Idempotent: if it's
/// already up it just re-points the base URL. UI calls this from a Start button.
pub fn startEmbedded() void {
    if (busy.load(.acquire)) return;
    if (std.Thread.spawn(.{}, worker, .{})) |t| t.detach() else |_| {}
}

fn worker() void {
    if (busy.swap(true, .acq_rel)) return;
    defer busy.store(false, .release);

    if (!hasJava()) {
        setStatus(.no_java, "Java not found — install a JRE (e.g. `brew install openjdk`)");
        return;
    }

    // Already running (this session or a leftover)?
    if (pingPort()) {
        setBaseUrl();
        setStatus(.running, "Server running (" ++ BASE_URL ++ ")");
        return;
    }

    var jar_buf: [700]u8 = undefined;
    const jar = jarPath(&jar_buf) orelse {
        setStatus(.err, "Could not resolve jar path");
        return;
    };

    // Download the jar once (~166 MB).
    if (!fileExists(jar)) {
        setStatus(.downloading, "Downloading Suwayomi server (~166 MB, one time)…");
        var cfg_buf: [512]u8 = undefined;
        const cfg = paths.configDir(&cfg_buf);
        var dir_buf: [700]u8 = undefined;
        const dir = std.fmt.bufPrint(&dir_buf, "{s}/suwayomi", .{cfg}) catch {
            setStatus(.err, "path error");
            return;
        };
        io.cwdMakePath(dir) catch {};
        var dl = io.Child.init(&.{ "curl", "-sL", "--fail", "--max-time", "1200", "-o", jar, DL_URL }, alloc);
        dl.stdout_behavior = .Ignore;
        dl.stderr_behavior = .Ignore;
        dl.spawn() catch {
            setStatus(.err, "Download failed to start");
            return;
        };
        const term = dl.wait() catch {
            setStatus(.err, "Download failed");
            return;
        };
        const ok = switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!ok or !fileExists(jar)) {
            setStatus(.err, "Download failed");
            return;
        }
        logs.pushLog("info", "suwayomi", "Downloaded Suwayomi server", false);
    }

    // Disable the tray/WebUI via server.conf BEFORE launch (the `-D` equivalents
    // are ignored, and `-Djava.awt.headless=true` makes the tray code NPE-crash
    // the JVM — see writeServerConf). Then launch plainly.
    writeServerConf();
    setStatus(.starting, "Starting server (first run also fetches its browser bundle)…");
    var srv = io.Child.init(&.{ "java", "-jar", jar }, alloc);
    srv.stdout_behavior = .Ignore;
    srv.stderr_behavior = .Ignore;
    srv.spawn() catch {
        setStatus(.err, "Failed to launch java");
        return;
    };
    // Do NOT wait() — the server runs for the app's lifetime; stopEmbedded()
    // (and app shutdown) kill it by pattern.

    // Poll for the port. First run downloads a ~226 MB CEF bundle, so allow a
    // generous window.
    var i: usize = 0;
    while (i < 80) : (i += 1) { // up to ~4 min
        io.sleep(3 * std.time.ns_per_s);
        if (pingPort()) {
            setBaseUrl();
            setStatus(.running, "Server running (" ++ BASE_URL ++ ")");
            logs.pushLog("info", "suwayomi", "Suwayomi server up", false);
            return;
        }
    }
    setStatus(.err, "Server did not come up — check Java / logs");
}

/// Stop the embedded server (pkill by pattern). Safe to call any time, incl. on
/// app shutdown (main.zig) so no JVM is orphaned.
pub fn stopEmbedded() void {
    var k = io.Child.init(&.{ "pkill", "-f", PKILL_PAT }, alloc);
    k.stdin_behavior = .Ignore;
    k.stdout_behavior = .Ignore;
    k.stderr_behavior = .Ignore;
    k.spawn() catch return;
    _ = k.wait() catch {};
    if (statusEnum() != .no_java) setStatus(.idle, "Server stopped");
}
