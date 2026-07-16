const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const logs = @import("../core/logs.zig");
const alloc = @import("../core/alloc.zig").allocator;
const safeUtf8Buf = @import("../core/text.zig").safeUtf8Buf;
const pure = @import("browser_pure.zig");
const io_g = @import("../core/io_global.zig");

// Keep the anti-block scrape-fetch layer (services/scrape_fetch.zig) in the
// build graph and compile-checked even before any scraper is wired through it
// (that wiring is a deliberate follow-up). It calls fetchHtmlBlocking() below.
comptime {
    _ = @import("scrape_fetch.zig").scrapeFetch;
}

// ══════════════════════════════════════════════════════════
// Browser Engine — Playwright bridge + JPEG frame streaming
// Two engines, one protocol (scripts/camoufox_bridge.py):
//   camoufox     — Firefox-based anti-detect (default)
//   cloakbrowser — Chromium-based anti-detect (free tier)
// ══════════════════════════════════════════════════════════

const BRIDGE_SCRIPT = "camoufox_bridge.py";

// Selected engine — persisted as config key "browser_engine" (config.zig).
// UI thread writes it (settings picker); the bridge-start thread reads it.
// A switch takes effect on the next bridge start (settings kills any running
// bridge). Enum load/store is a single byte — benign to read cross-thread.
pub const Engine = pure.Engine;
pub var active_engine: Engine = .camoufox;

pub fn engineDisplayName(e: Engine) []const u8 {
    return switch (e) {
        .camoufox => "Camoufox",
        .cloakbrowser => "CloakBrowser",
    };
}

// Resolve the venv python under the Opal config dir (~/.config/opal/venv/bin/python3).
// Returns null if $HOME is unset. Falls back to bare "python3" handled by callers.
fn getVenvPython() ?[]const u8 {
    const home = @import("../core/io_global.zig").getenv("HOME") orelse return null;
    const S = struct {
        var buf: [512]u8 = undefined;
    };
    return std.fmt.bufPrint(&S.buf, "{s}/.config/opal/venv/bin/python3", .{home}) catch null;
}

// Bridge process state (singleton — one browser instance shared across all panes)
var bridge_process: ?@import("../core/io_global.zig").Child = null;
var bridge_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var bridge_starting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var bridge_reader_thread: ?std.Thread = null;

// Frame buffer — latest screenshot from Camoufox, already decoded to RGBA on
// the reader thread (a 12fps JPEG decode on the UI thread stalled the whole
// app; the reader owns the bytes anyway). frame_lock scopes the pointer swap.
// RGBA buffers use the C allocator to match the stbi/poster-daemon pattern.
const frame_alloc = std.heap.c_allocator;
var frame_pixels: ?[]u8 = null; // RGBA, len == frame_pix_w * frame_pix_h * 4
var frame_pix_w: u32 = 0;
var frame_pix_h: u32 = 0;
var frame_texture: ?dvui.Texture = null;
var frame_w: u32 = 0; // dims of the CURRENT texture (UI thread only)
var frame_h: u32 = 0;
var frame_dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var frame_lock: @import("../core/sync.zig").Mutex = .{};

// Nav updates (url/title) are STAGED by the reader thread and applied on the
// UI thread at frame start — the URL bar's textEntry edits state.app.browser
// .url_buf live, so a worker-side write would race it (and clobber typing).
var nav_stage_lock: @import("../core/sync.zig").Mutex = .{};
var nav_stage_url: [2048]u8 = undefined;
var nav_stage_url_len: usize = 0;
var nav_stage_title: [256]u8 = undefined;
var nav_stage_title_len: usize = 0;
var nav_stage_dirty: bool = false; // guarded by nav_stage_lock
var url_bar_focused: bool = false; // UI thread only

// Loading watchdog: navigate() stamps this; renderContent clears is_loading
// if no response arrives within the deadline (bridge missing/crashed).
var loading_since_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);
const LOADING_TIMEOUT_MS: i64 = 25_000; // just beyond the bridge's 20s goto timeout

// Pending navigate URL (queued before bridge is ready). Written by the UI
// thread (navigate) and consumed by the bridge-start thread — lock both sides.
var pending_url: [2048]u8 = undefined;
var pending_url_len: usize = 0;
var pending_lock: @import("../core/sync.zig").Mutex = .{};

// ── Anti-block scrape fetch (fetchhtml / fetchapi) ──
// scrape_fetch.zig calls fetchHtmlBlocking() from a scraper WORKER thread when
// a plain HTTP fetch came back blocked (Cloudflare / DDoS-Guard interstitial).
// The bridge loads the URL on a DEDICATED page in a separate context, waits
// out the challenge, and returns the unblocked bytes as an 'H' binary frame.
// The reader thread parks them in scrape_buf and flips scrape_ready; the worker
// polls scrape_ready (bounded) — the same publish/poll style as bridge startup.
// scrape_req_mutex serializes requests (one scrape page). 2MB matches the
// bridge's MAX_SCRAPE_BYTES cap.
const SCRAPE_BUF_CAP = 2 * 1024 * 1024;
var scrape_buf: [SCRAPE_BUF_CAP]u8 = undefined; // reader writes, worker copies out
var scrape_len: usize = 0; // guarded by scrape_lock
var scrape_err: bool = false; // guarded by scrape_lock — fetchhtml failed
var scrape_lock: @import("../core/sync.zig").Mutex = .{};
var scrape_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var scrape_req_mutex: @import("../core/sync.zig").Mutex = .{}; // one request at a time

// ── Engine installer (venv + pip package [+ browser download]) ──
// One idempotent worker: creates ~/.config/opal/venv if missing, pip-installs
// the selected engine into it. Camoufox additionally runs `python -m camoufox
// fetch` (~200 MB now); CloakBrowser downloads its ~200 MB binary on FIRST
// LAUNCH instead (cached). Progress streams line-by-line into install_msg.
pub const InstallState = enum(u8) { idle, running, failed, done };
var install_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);
var install_msg: [256]u8 = undefined;
var install_msg_len: usize = 0;
var install_lock: @import("../core/sync.zig").Mutex = .{};
// Engine the running/last install targets — copied from active_engine BEFORE
// the worker spawns (struct{var}-style input snapshot).
var install_engine_target: Engine = .camoufox;

fn setInstallMsg(msg: []const u8) void {
    install_lock.lock();
    const n = @min(msg.len, install_msg.len);
    @memcpy(install_msg[0..n], msg[0..n]);
    install_msg_len = n;
    install_lock.unlock();
    state.wakeUi();
}

pub fn installEngine() void {
    if (install_state.load(.acquire) == @intFromEnum(InstallState.running)) return;
    install_engine_target = active_engine; // snapshot input before spawn
    install_state.store(@intFromEnum(InstallState.running), .release);
    setInstallMsg("Preparing…");
    if (std.Thread.spawn(.{}, installWorker, .{})) |t| t.detach() else |_| {
        install_state.store(@intFromEnum(InstallState.failed), .release);
        setInstallMsg("Could not start the installer thread");
    }
}

/// Run a command, streaming its output (split on \n AND \r so pip/download
/// progress bars surface) into install_msg. Returns true on exit code 0.
fn runInstallStep(argv: []const []const u8) bool {
    var child = io_g.Child.init(argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    _ = child.spawn() catch return false;

    if (child.stdout) |*stdout| {
        var line_buf: [240]u8 = undefined;
        var pos: usize = 0;
        var ch: [1]u8 = undefined;
        while (true) {
            const n = io_g.read(stdout, &ch) catch break;
            if (n == 0) break;
            if (ch[0] == '\n' or ch[0] == '\r') {
                if (pos > 0) setInstallMsg(line_buf[0..pos]);
                pos = 0;
            } else if (pos < line_buf.len) {
                line_buf[pos] = ch[0];
                pos += 1;
            }
        }
        if (pos > 0) setInstallMsg(line_buf[0..pos]);
    }

    const term = child.wait() catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn installWorker() void {
    const fail = struct {
        fn f(msg: []const u8) void {
            install_state.store(@intFromEnum(InstallState.failed), .release);
            setInstallMsg(msg);
            logs.pushLog("error", "browser", msg, false);
        }
    }.f;

    const engine = install_engine_target;
    const pkg = pure.enginePipPackage(engine);

    const home = io_g.getenv("HOME") orelse return fail("HOME not set");
    var venv_buf: [512]u8 = undefined;
    const venv = std.fmt.bufPrint(&venv_buf, "{s}/.config/opal/venv", .{home}) catch return fail("path too long");
    var py_buf: [512]u8 = undefined;
    const py = std.fmt.bufPrint(&py_buf, "{s}/bin/python3", .{venv}) catch return fail("path too long");

    // 1) venv (idempotent — skip when its python already exists)
    if (io_g.cwdAccess(py, .{})) |_| {} else |_| {
        setInstallMsg("Creating Python environment…");
        if (!runInstallStep(&.{ "python3", "-m", "venv", venv }))
            return fail("Failed to create the Python venv (is python3 installed?)");
    }

    // 2) the engine package
    {
        var msg_buf: [96]u8 = undefined;
        setInstallMsg(std.fmt.bufPrint(&msg_buf, "Installing {s} (pip)…", .{pkg}) catch pkg);
    }
    if (!runInstallStep(&.{ py, "-m", "pip", "install", "--upgrade", pkg }))
        return fail("pip install failed — see Logs");

    // 3) the browser binary
    switch (engine) {
        .camoufox => {
            setInstallMsg("Downloading the Camoufox browser (~200 MB)…");
            if (!runInstallStep(&.{ py, "-m", "camoufox", "fetch" }))
                return fail("Browser download failed — check network and retry");
            setInstallMsg("Engine installed — starting…");
        },
        // CloakBrowser has no fetch step — its ~200 MB Chromium binary
        // auto-downloads on the first launch and is cached after that.
        .cloakbrowser => setInstallMsg("Installed — first launch downloads ~200 MB (cached)"),
    }

    engine_ready_state[@intFromEnum(engine)].store(2, .release);
    install_state.store(@intFromEnum(InstallState.done), .release);
    logs.pushLog("info", "browser", "Browser engine installed", true);
    ensureBridge();
}

/// Per-engine readiness: venv python present AND the engine's package dir
/// exists in the venv's site-packages. 0 = unchecked, 1 = missing, 2 = ready;
/// checked lazily once per session (a finished install stamps 2 directly).
var engine_ready_state = [_]std.atomic.Value(u8){
    std.atomic.Value(u8).init(0),
    std.atomic.Value(u8).init(0),
};

pub fn engineReady(e: Engine) bool {
    const idx = @intFromEnum(e);
    const v = engine_ready_state[idx].load(.acquire);
    if (v != 0) return v == 2;
    const ok = checkVenvPackage(pure.enginePipPackage(e));
    engine_ready_state[idx].store(if (ok) 2 else 1, .release);
    return ok;
}

/// Does the Opal venv contain `pkg` in site-packages? Scans venv/lib for the
/// python3.x dir (version varies across machines) — cheap, cached by caller.
fn checkVenvPackage(pkg: []const u8) bool {
    const home = io_g.getenv("HOME") orelse return false;
    var py_buf: [512]u8 = undefined;
    const py = std.fmt.bufPrint(&py_buf, "{s}/.config/opal/venv/bin/python3", .{home}) catch return false;
    io_g.cwdAccess(py, .{}) catch return false;
    var lib_buf: [512]u8 = undefined;
    const lib = std.fmt.bufPrint(&lib_buf, "{s}/.config/opal/venv/lib", .{home}) catch return false;
    var dir = io_g.cwdOpenDir(lib, .{ .iterate = true }) catch return false;
    defer dir.close(io_g.io());
    var iter = dir.iterate();
    while (iter.next(io_g.io()) catch null) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "python")) continue;
        var pkg_buf: [768]u8 = undefined;
        const p = std.fmt.bufPrint(&pkg_buf, "{s}/{s}/site-packages/{s}", .{ lib, entry.name, pkg }) catch continue;
        if (io_g.cwdAccess(p, .{})) |_| return true else |_| {}
    }
    return false;
}

fn engineInstalled() bool {
    if (install_state.load(.acquire) == @intFromEnum(InstallState.done)) return true;
    return engineReady(active_engine);
}

// ── Find-in-page / zoom / bookmarks (UI thread only unless noted) ──
var find_open: bool = false;
var find_buf: [256]u8 = std.mem.zeroes([256]u8);
// Last find match count from the bridge — written by the reader thread.
// -1 means "no result yet" (nothing searched / response pending).
var find_count: std.atomic.Value(i64) = std.atomic.Value(i64).init(-1);

var zoom_level: f32 = 1.0;
// Host the current zoom_level belongs to (per-site zoom, browser_zoom table).
var zoom_host: [256]u8 = undefined;
var zoom_host_len: usize = 0;

// ── Reader overlay (readtext event) ──
// Stage written by the reader thread under reader_lock; the UI thread copies
// it into reader_buf at frame start (same staging pattern as nav updates).
var reader_open: bool = false; // UI thread only
var reader_buf: [8192]u8 = undefined; // UI thread only
var reader_len: usize = 0;
var reader_stage: [8192]u8 = undefined;
var reader_stage_len: usize = 0;
var reader_stage_dirty: bool = false; // guarded by reader_lock
var reader_lock: @import("../core/sync.zig").Mutex = .{};

// ── Intercepted downloads (bridge "download" events) ──
// Staged by the reader thread; the UI thread hands them to the downloader.
var dl_stage_url: [2048]u8 = undefined;
var dl_stage_url_len: usize = 0;
var dl_stage_name: [256]u8 = undefined;
var dl_stage_name_len: usize = 0;
var dl_stage_dirty: bool = false; // guarded by dl_stage_lock
var dl_stage_lock: @import("../core/sync.zig").Mutex = .{};

const db = @import("../core/db.zig");
var bookmarks: [64]state.BrowserLink = std.mem.zeroes([64]state.BrowserLink);
var bookmark_count: usize = 0;
var bookmarks_loaded: bool = false;

// ── Visit history cache (browser_history table; URL-bar autocomplete) ──
// UI thread only, like bookmarks. Reloaded lazily after each recorded visit.
const HIST_MAX = 64;
var hist_urls: [HIST_MAX][512]u8 = undefined;
var hist_url_lens: [HIST_MAX]usize = std.mem.zeroes([HIST_MAX]usize);
var hist_titles: [HIST_MAX][128]u8 = undefined;
var hist_title_lens: [HIST_MAX]usize = std.mem.zeroes([HIST_MAX]usize);
var hist_count: usize = 0;
var hist_loaded: bool = false;
// Last URL written to browser_history — dedups the staged-nav replay.
var last_visit_url: [2048]u8 = undefined;
var last_visit_url_len: usize = 0;

// ── Bridge lifecycle ──

fn getBridgePath() ?[]const u8 {
    const io = @import("../core/io_global.zig");

    // 1) Look for camoufox_bridge.py relative to the working dir (bundled scripts dir).
    const rel = "scripts/" ++ BRIDGE_SCRIPT;
    if (io.cwdAccess(rel, .{})) |_| {
        return rel;
    } else |_| {}

    // 2) Look under the Opal config dir (~/.config/opal/scripts/camoufox_bridge.py).
    if (io.getenv("HOME")) |home| {
        const S = struct {
            var buf: [512]u8 = undefined;
        };
        const p = std.fmt.bufPrint(&S.buf, "{s}/.config/opal/scripts/{s}", .{ home, BRIDGE_SCRIPT }) catch return null;
        if (io.cwdAccess(p, .{})) |_| {
            return p;
        } else |_| {}
    }

    return null;
}

pub fn ensureBridge() void {
    if (bridge_ready.load(.acquire) or bridge_starting.load(.acquire)) return;
    bridge_starting.store(true, .release);

    if (std.Thread.spawn(.{}, startBridgeThread, .{})) |t| {
        t.detach();
    } else |_| {
        bridge_starting.store(false, .release);
        logs.pushLog("error", "browser", "Failed to spawn bridge thread", false);
    }
}

fn startBridgeThread() void {
    defer bridge_starting.store(false, .release);

    const script_path = getBridgePath() orelse {
        logs.pushLog("error", "browser", "camoufox_bridge.py not found", false);
        return;
    };

    // Resolve and check the venv python under the Opal config dir.
    const venv_python = getVenvPython() orelse {
        logs.pushLog("error", "browser", "$HOME not set — cannot locate Python venv", false);
        return;
    };
    @import("../core/io_global.zig").cwdAccess(venv_python, .{}) catch {
        logs.pushLog("error", "browser", "Python venv not found — run install", false);
        return;
    };

    const engine = active_engine;
    {
        var lb: [96]u8 = undefined;
        const lmsg = std.fmt.bufPrint(&lb, "Starting {s} browser...", .{engineDisplayName(engine)}) catch "Starting browser...";
        logs.pushLog("info", "browser", lmsg, true);
    }

    const argv = [_][]const u8{ venv_python, script_path, "--engine", @tagName(engine) };
    var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    _ = child.spawn() catch {
        logs.pushLog("error", "browser", "Failed to spawn browser bridge", false);
        return;
    };

    bridge_process = child;

    // Start reader thread to process stdout
    bridge_reader_thread = std.Thread.spawn(.{}, bridgeReaderThread, .{}) catch null;

    // Wait for ready signal (up to 15 seconds)
    var waited: usize = 0;
    while (waited < 150) : (waited += 1) {
        if (bridge_ready.load(.acquire)) {
            logs.pushLog("info", "browser", "Browser engine ready", true);

            // Send any pending navigate command (snapshot under lock — the UI
            // thread may be queueing a newer URL concurrently).
            var pend_buf: [2048]u8 = undefined;
            var pend_len: usize = 0;
            pending_lock.lock();
            if (pending_url_len > 0) {
                pend_len = pending_url_len;
                @memcpy(pend_buf[0..pend_len], pending_url[0..pend_len]);
                pending_url_len = 0;
            }
            pending_lock.unlock();
            if (pend_len > 0) {
                sendNavigate(pend_buf[0..pend_len]);
            }
            return;
        }
        @import("../core/io_global.zig").sleep(100 * std.time.ns_per_ms);
    }

    logs.pushLog("error", "browser", "Browser engine startup timeout", false);
}

fn bridgeReaderThread() void {
    const proc = bridge_process orelse return;
    const stdout_pipe = proc.stdout orelse return;
    const stdout = stdout_pipe;

    while (true) {
        // Read tag byte: 'J' for JSON, 'F' for frame
        var tag: [1]u8 = undefined;
        const n = @import("../core/io_global.zig").read(stdout, &tag) catch break;
        if (n == 0) break;

        if (tag[0] == 'J') {
            // JSON response — read until newline. Oversized lines (scrape/eval
            // payloads) are drained to the newline so the framing never
            // desyncs into interpreting mid-JSON bytes as the next tag.
            // 24K: the readtext event carries up to 3500 chars of page text,
            // ~21K worst-case once JSON-escaped.
            var buf: [24576]u8 = undefined;
            var pos: usize = 0;
            while (true) {
                var ch: [1]u8 = undefined;
                const cn = @import("../core/io_global.zig").read(stdout, &ch) catch break;
                if (cn == 0) break;
                if (ch[0] == '\n') break;
                // Past capacity: keep DRAINING to the newline without storing —
                // stopping mid-line would desync the tag framing.
                if (pos < buf.len) {
                    buf[pos] = ch[0];
                    pos += 1;
                }
            }

            if (pos > 0) {
                // Stable-prefix classification (contract with the bridge; see
                // browser_pure.classifyBridgeMsg) — substring matching used to
                // mistake scrape/eval payloads containing "title" for navs.
                switch (pure.classifyBridgeMsg(buf[0..pos])) {
                    .ready => bridge_ready.store(true, .release),
                    .nav => {
                        // Stage url/title for the UI thread to apply at frame
                        // start — direct writes raced the URL bar's textEntry.
                        nav_stage_lock.lock();
                        if (extractJsonField(buf[0..pos], "title")) |title| {
                            const tlen = @min(title.len, nav_stage_title.len);
                            @memcpy(nav_stage_title[0..tlen], title[0..tlen]);
                            nav_stage_title_len = tlen;
                        }
                        if (extractJsonField(buf[0..pos], "url")) |url| {
                            const ulen = @min(url.len, nav_stage_url.len);
                            @memcpy(nav_stage_url[0..ulen], url[0..ulen]);
                            nav_stage_url_len = ulen;
                        }
                        nav_stage_dirty = true;
                        nav_stage_lock.unlock();
                        state.app.browser.is_loading.store(false, .release);
                    },
                    .err => {
                        // Failed navigation (or command error): stop the
                        // loading indicator and surface the reason — the old
                        // path reported success with the previous page's URL.
                        state.app.browser.is_loading.store(false, .release);
                        var msg_buf: [256]u8 = undefined;
                        const detail = extractJsonField(buf[0..pos], "error") orelse "unknown error";
                        if (!bridge_ready.load(.acquire)) {
                            // Startup failure (engine import failed — e.g.
                            // "cloakbrowser not installed — install it in
                            // Settings"): surface it on the landing page via
                            // the installer's failed state, not a silent hang.
                            install_state.store(@intFromEnum(InstallState.failed), .release);
                            setInstallMsg(detail[0..@min(detail.len, 200)]);
                            // Force a fresh package presence check next frame.
                            engine_ready_state[@intFromEnum(active_engine)].store(0, .release);
                            logs.pushLog("error", "browser", detail[0..@min(detail.len, 200)], false);
                        } else {
                            const msg = std.fmt.bufPrint(&msg_buf, "Navigation failed: {s}", .{detail[0..@min(detail.len, 180)]}) catch "Navigation failed";
                            logs.pushLog("error", "browser", msg, false);
                        }
                    },
                    .find => {
                        // {"ok": true, "found": bool, "count": N} — shown in
                        // the find bar ("N matches" / "No matches").
                        const cnt = pure.extractJsonUint(buf[0..pos], "count") orelse 0;
                        find_count.store(@intCast(@min(cnt, 999_999)), .release);
                    },
                    .download => {
                        // Intercepted page download → stage for the UI thread,
                        // which hands it to Opal's downloader.
                        var url_tmp: [2048]u8 = undefined;
                        var name_tmp: [256]u8 = undefined;
                        const url_raw = pure.extractJsonStringRaw(buf[0..pos], "url") orelse "";
                        const name_raw = pure.extractJsonStringRaw(buf[0..pos], "filename") orelse "";
                        const url_dec = pure.jsonUnescape(url_raw, &url_tmp);
                        const name_dec = pure.jsonUnescape(name_raw, &name_tmp);
                        if (url_dec.len > 0) {
                            dl_stage_lock.lock();
                            @memcpy(dl_stage_url[0..url_dec.len], url_dec);
                            dl_stage_url_len = url_dec.len;
                            const nn = @min(name_dec.len, dl_stage_name.len);
                            @memcpy(dl_stage_name[0..nn], name_dec[0..nn]);
                            dl_stage_name_len = nn;
                            dl_stage_dirty = true;
                            dl_stage_lock.unlock();
                        }
                    },
                    .readtext => {
                        // Reader overlay text — stage for the UI thread.
                        const raw = pure.extractJsonStringRaw(buf[0..pos], "text") orelse "";
                        reader_lock.lock();
                        const dec = pure.jsonUnescape(raw, &reader_stage);
                        reader_stage_len = dec.len;
                        reader_stage_dirty = true;
                        reader_lock.unlock();
                    },
                    .fetchhtml_err => {
                        // Anti-block fetch failed (goto error / no scrape page).
                        // Publish an empty, error-flagged result so the waiting
                        // worker stops polling and falls back to the plain body.
                        const detail = extractJsonField(buf[0..pos], "error") orelse "unknown error";
                        scrape_lock.lock();
                        scrape_len = 0;
                        scrape_err = true;
                        scrape_lock.unlock();
                        scrape_ready.store(true, .release);
                        var mb: [256]u8 = undefined;
                        const msg = std.fmt.bufPrint(&mb, "Anti-block fetch failed: {s}", .{detail[0..@min(detail.len, 180)]}) catch "Anti-block fetch failed";
                        logs.pushLog("warn", "scrape", msg, false);
                    },
                    .other => {},
                }
                state.wakeUi();
            }
        } else if (tag[0] == 'H') {
            // Anti-block scrape payload: 4-byte big-endian length + raw UTF-8.
            // Bulk-read into scrape_buf (capped at SCRAPE_BUF_CAP; any overflow
            // is drained so the tag framing never desyncs), then flip
            // scrape_ready for the waiting scrapeFetch worker.
            var len_buf: [4]u8 = undefined;
            var len_read: usize = 0;
            while (len_read < 4) {
                const lr = @import("../core/io_global.zig").read(stdout, len_buf[len_read..4]) catch break;
                if (lr == 0) break;
                len_read += lr;
            }
            if (len_read < 4) break;
            const payload_size = @as(usize, len_buf[0]) << 24 |
                @as(usize, len_buf[1]) << 16 |
                @as(usize, len_buf[2]) << 8 |
                @as(usize, len_buf[3]);

            scrape_lock.lock();
            var got: usize = 0;
            const want = @min(payload_size, scrape_buf.len);
            while (got < want) {
                const r = @import("../core/io_global.zig").read(stdout, scrape_buf[got..want]) catch break;
                if (r == 0) break;
                got += r;
            }
            scrape_len = got;
            scrape_err = false;
            scrape_lock.unlock();

            // Drain any bytes past our cap so framing stays aligned.
            var drained = got;
            var junk: [4096]u8 = undefined;
            while (drained < payload_size) {
                const chunk = @min(payload_size - drained, junk.len);
                const r = @import("../core/io_global.zig").read(stdout, junk[0..chunk]) catch break;
                if (r == 0) break;
                drained += r;
            }
            scrape_ready.store(true, .release);
            state.wakeUi();
        } else if (tag[0] == 'F') {
            // Frame: 4-byte big-endian length + JPEG data
            var len_buf: [4]u8 = undefined;
            var len_read: usize = 0;
            while (len_read < 4) {
                const lr = @import("../core/io_global.zig").read(stdout, len_buf[len_read..4]) catch break;
                if (lr == 0) break;
                len_read += lr;
            }
            if (len_read < 4) continue;

            const frame_size = @as(usize, len_buf[0]) << 24 |
                @as(usize, len_buf[1]) << 16 |
                @as(usize, len_buf[2]) << 8 |
                @as(usize, len_buf[3]);

            if (frame_size == 0 or frame_size > 5 * 1024 * 1024) continue;

            // Read JPEG data
            const jpeg_buf = alloc.alloc(u8, frame_size) catch continue;
            defer alloc.free(jpeg_buf);
            var total_read: usize = 0;
            while (total_read < frame_size) {
                const fr = @import("../core/io_global.zig").read(stdout, jpeg_buf[total_read..frame_size]) catch break;
                if (fr == 0) break;
                total_read += fr;
            }

            if (total_read == frame_size) {
                // Decode HERE (reader thread) — a 12fps JPEG decode on the UI
                // thread stuttered the whole app. The UI only uploads RGBA.
                // NOTE: frames deliberately do NOT clear is_loading — the pump
                // streams continuously, so a pre-goto frame arriving 80ms
                // after Enter used to dismiss the loading bar mid-navigation.
                // is_loading clears on the navigate response / error instead.
                var w: c_int = 0;
                var h: c_int = 0;
                var ch: c_int = 0;
                const rgba = dvui.c.stbi_load_from_memory(jpeg_buf.ptr, @intCast(frame_size), &w, &h, &ch, 4);
                if (rgba != null and w > 0 and h > 0 and w <= 8192 and h <= 8192) {
                    defer dvui.c.stbi_image_free(rgba);
                    const p_len: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
                    if (frame_alloc.alloc(u8, p_len)) |p_slice| {
                        @memcpy(p_slice, rgba[0..p_len]);
                        frame_lock.lock();
                        if (frame_pixels) |old| frame_alloc.free(old);
                        frame_pixels = p_slice;
                        frame_pix_w = @intCast(w);
                        frame_pix_h = @intCast(h);
                        frame_dirty.store(true, .release);
                        frame_lock.unlock();
                        // Wake the UI so streamed frames paint at the pump's
                        // rate instead of on the next incidental mouse move.
                        state.wakeUi();
                    } else |_| {}
                }
            }
        }
    }

    bridge_ready.store(false, .release);
    logs.pushLog("info", "browser", "Browser bridge disconnected", false);
}

fn sendCommand(cmd: []const u8) void {
    var proc = bridge_process orelse return;
    if (proc.stdin) |*stdin| {
        @import("../core/io_global.zig").writeAll(stdin, cmd) catch return;
        @import("../core/io_global.zig").writeAll(stdin, "\n") catch return;
    }
}

fn sendCommandFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, fmt, args) catch return;
    sendCommand(cmd);
}

fn extractJsonField(json: []const u8, field: []const u8) ?[]const u8 {
    // Simple JSON field extractor — finds "field":"value"
    var search_buf: [64]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{field}) catch return null;

    const field_pos = std.mem.indexOf(u8, json, search) orelse return null;
    var pos = field_pos + search.len;

    // Skip colon and whitespace
    while (pos < json.len and (json[pos] == ':' or json[pos] == ' ')) pos += 1;
    if (pos >= json.len or json[pos] != '"') return null;
    pos += 1; // skip opening quote

    const end = std.mem.indexOfScalar(u8, json[pos..], '"') orelse return null;
    return json[pos .. pos + end];
}

/// Escape a string for safe JSON interpolation — escapes \\ and \"
fn escapeJsonString(input: []const u8, buf: *[4096]u8) []const u8 {
    var out: usize = 0;
    for (input) |ch| {
        if (out + 2 > buf.len) break;
        if (ch == '\\') {
            buf[out] = '\\';
            out += 1;
            buf[out] = '\\';
            out += 1;
        } else if (ch == '"') {
            buf[out] = '\\';
            out += 1;
            buf[out] = '"';
            out += 1;
        } else if (ch == '\n') {
            buf[out] = '\\';
            out += 1;
            buf[out] = 'n';
            out += 1;
        } else if (ch == '\r') {
            buf[out] = '\\';
            out += 1;
            buf[out] = 'r';
            out += 1;
        } else if (ch == '\t') {
            buf[out] = '\\';
            out += 1;
            buf[out] = 't';
            out += 1;
        } else if (ch < 0x20) {
            // Other control characters → \u00XX. Needs 6 bytes.
            if (out + 6 > buf.len) break;
            const hex = "0123456789abcdef";
            buf[out] = '\\';
            buf[out + 1] = 'u';
            buf[out + 2] = '0';
            buf[out + 3] = '0';
            buf[out + 4] = hex[(ch >> 4) & 0xF];
            buf[out + 5] = hex[ch & 0xF];
            out += 6;
        } else {
            buf[out] = ch;
            out += 1;
        }
    }
    return buf[0..out];
}

// ── Public API ──

pub fn navigate(url: []const u8) void {
    const b = &state.app.browser;
    if (url.len == 0 or url.len >= 2048) return;

    // Store URL. `url` may be a slice INTO url_buf at a nonzero offset — the
    // smart address bar trims whitespace, so scheme'd input with a leading
    // space aliases the buffer. @memcpy forbids overlap; copyForwards is safe
    // here because src is always at or after dst (buffer start).
    const buf_start = @intFromPtr(&b.url_buf[0]);
    const url_addr = @intFromPtr(url.ptr);
    if (url_addr != buf_start) {
        if (url_addr > buf_start and url_addr < buf_start + b.url_buf.len) {
            std.mem.copyForwards(u8, b.url_buf[0..url.len], url);
        } else {
            @memcpy(b.url_buf[0..url.len], url);
        }
    }
    // NUL-terminate so the URL bar's sliceTo(0) never shows a stale tail from
    // a previously longer URL.
    if (url.len < b.url_buf.len) b.url_buf[url.len] = 0;
    b.url_len = url.len;
    b.is_loading.store(true, .release);
    loading_since_ms.store(io_g.milliTimestamp(), .release);
    b.title_len = 0;

    // Push to history — a ring: when full, the oldest entry falls off instead
    // of navigation silently stopping being recorded. Consecutive duplicates
    // (refresh, redirect echo) are suppressed.
    if (!state.app.incognito_mode) {
        const is_dup = b.history_count > 0 and blk: {
            const li = b.history_count - 1;
            break :blk std.mem.eql(u8, b.history[li][0..b.history_lens[li]], b.url_buf[0..url.len]);
        };
        if (!is_dup) {
            if (b.history_count == b.history.len) {
                var hi: usize = 0;
                while (hi + 1 < b.history.len) : (hi += 1) {
                    b.history[hi] = b.history[hi + 1];
                    b.history_lens[hi] = b.history_lens[hi + 1];
                }
                b.history_count -= 1;
            }
            const hi = b.history_count;
            @memcpy(b.history[hi][0..url.len], b.url_buf[0..url.len]);
            b.history_lens[hi] = url.len;
            b.history_count += 1;
            b.history_pos = b.history_count;
        }
    }

    if (bridge_ready.load(.acquire)) {
        sendNavigate(b.url_buf[0..url.len]);
    } else {
        // Bridge not ready yet — queue URL for when it starts
        const ulen = @min(url.len, 2047);
        pending_lock.lock();
        @memcpy(pending_url[0..ulen], b.url_buf[0..ulen]);
        pending_url_len = ulen;
        pending_lock.unlock();
        ensureBridge();
    }
}

pub fn sendFind(text: []const u8, backwards: bool) void {
    if (!bridge_ready.load(.acquire)) return;
    var esc_buf: [4096]u8 = undefined;
    const esc = escapeJsonString(text, &esc_buf);
    sendCommandFmt("{{\"cmd\":\"find\",\"text\":\"{s}\",\"dir\":\"{s}\"}}", .{ esc, if (backwards) "prev" else "next" });
}

pub fn sendZoom(factor: f32) void {
    if (!bridge_ready.load(.acquire)) return;
    sendCommandFmt("{{\"cmd\":\"zoom\",\"factor\":{d:.2}}}", .{factor});
}

/// Request the page's visible text for the reader overlay.
pub fn requestReadText() void {
    if (!bridge_ready.load(.acquire)) return;
    sendCommand("{\"cmd\":\"readtext\"}");
}

/// Clamp + apply + announce a zoom change (Cmd/Ctrl +/-/0 or the toolbar),
/// and persist it for the current site (browser_zoom table).
fn setZoom(z: f32) void {
    zoom_level = std.math.clamp(z, 0.25, 4.0);
    sendZoom(zoom_level);
    if (zoom_host_len > 0) saveZoomFor(zoom_host[0..zoom_host_len], zoom_level);
    var tb: [32]u8 = undefined;
    if (std.fmt.bufPrint(&tb, "Zoom {d}%", .{@as(i32, @intFromFloat(zoom_level * 100))})) |msg| {
        state.showToast(msg);
    } else |_| {}
}

// ── Per-site zoom persistence (browser_zoom table; UI thread only) ──

fn loadZoomFor(host: []const u8) ?f32 {
    if (host.len == 0) return null;
    const stmt = db.prepare("SELECT factor FROM browser_zoom WHERE host = ?1") orelse return null;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, host);
    if (db.step(stmt) != db.c.SQLITE_ROW) return null;
    const f: f32 = @floatCast(db.columnDouble(stmt, 0));
    if (!(f >= 0.25 and f <= 4.0)) return null; // NaN/garbage guard
    return f;
}

fn saveZoomFor(host: []const u8, factor: f32) void {
    if (host.len == 0) return;
    if (factor == 1.0) {
        // Default zoom — drop the row instead of storing a no-op.
        const stmt = db.prepare("DELETE FROM browser_zoom WHERE host = ?1") orelse return;
        defer db.finalize(stmt);
        db.bindText(stmt, 1, host);
        _ = db.step(stmt);
        return;
    }
    const stmt = db.prepare("INSERT OR REPLACE INTO browser_zoom (host, factor) VALUES (?1, ?2)") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, host);
    db.bindDouble(stmt, 2, factor);
    _ = db.step(stmt);
}

// ── Bookmarks (browser_bookmarks table; newest first, capped at 64) ──

fn loadBookmarks() void {
    if (bookmarks_loaded) return;
    bookmarks_loaded = true;
    const stmt = db.prepare("SELECT url, title FROM browser_bookmarks ORDER BY added_at DESC LIMIT 64") orelse return;
    defer db.finalize(stmt);
    while (db.step(stmt) == db.c.SQLITE_ROW and bookmark_count < bookmarks.len) {
        const bm = &bookmarks[bookmark_count];
        db.copyColumn(stmt, 0, &bm.url, &bm.url_len);
        db.copyColumn(stmt, 1, &bm.text, &bm.text_len);
        if (bm.url_len > 0) bookmark_count += 1;
    }
}

fn findBookmark(url: []const u8) ?usize {
    loadBookmarks();
    for (bookmarks[0..bookmark_count], 0..) |*bm, bi| {
        if (std.mem.eql(u8, bm.url[0..bm.url_len], url)) return bi;
    }
    return null;
}

fn toggleBookmark() void {
    const b = &state.app.browser;
    if (b.url_len == 0) return;
    const url = b.url_buf[0..b.url_len];
    if (findBookmark(url)) |bi| {
        const stmt = db.prepare("DELETE FROM browser_bookmarks WHERE url = ?1") orelse return;
        defer db.finalize(stmt);
        db.bindText(stmt, 1, url);
        _ = db.step(stmt);
        var i = bi;
        while (i + 1 < bookmark_count) : (i += 1) bookmarks[i] = bookmarks[i + 1];
        bookmark_count -= 1;
        state.showToast("Bookmark removed");
    } else {
        const stmt = db.prepare("INSERT OR REPLACE INTO browser_bookmarks (url, title) VALUES (?1, ?2)") orelse return;
        defer db.finalize(stmt);
        db.bindText(stmt, 1, url);
        db.bindText(stmt, 2, b.title[0..b.title_len]);
        _ = db.step(stmt);
        if (bookmark_count < bookmarks.len) {
            var i = bookmark_count;
            while (i > 0) : (i -= 1) bookmarks[i] = bookmarks[i - 1];
            const bm = &bookmarks[0];
            const ulen = @min(url.len, bm.url.len);
            @memcpy(bm.url[0..ulen], url[0..ulen]);
            bm.url_len = ulen;
            const tlen = @min(b.title_len, bm.text.len);
            @memcpy(bm.text[0..tlen], b.title[0..tlen]);
            bm.text_len = tlen;
            bookmark_count += 1;
        }
        state.showToast("Bookmarked");
    }
}

// ── Visit history (browser_history table; URL-bar autocomplete) ──

/// Upsert one visit. Only http(s) pages count; incognito never records.
fn recordVisit(url: []const u8, title: []const u8) void {
    if (state.app.incognito_mode) return;
    if (!std.mem.startsWith(u8, url, "http")) return;
    const stmt = db.prepare(
        \\INSERT INTO browser_history (url, title) VALUES (?1, ?2)
        \\ON CONFLICT(url) DO UPDATE SET
        \\  visits = visits + 1,
        \\  last_visit = strftime('%s','now'),
        \\  title = CASE WHEN excluded.title != '' THEN excluded.title ELSE title END
    ) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, url);
    db.bindText(stmt, 2, title);
    _ = db.step(stmt);
    hist_loaded = false; // autocomplete cache refreshes lazily
}

/// (Re)load the top history rows for autocomplete — most-visited first, so
/// the pure ranking only has to break ties within this working set.
fn loadHistoryRows() void {
    if (hist_loaded) return;
    hist_loaded = true;
    hist_count = 0;
    const stmt = db.prepare("SELECT url, title FROM browser_history ORDER BY visits DESC, last_visit DESC LIMIT 64") orelse return;
    defer db.finalize(stmt);
    while (db.step(stmt) == db.c.SQLITE_ROW and hist_count < HIST_MAX) {
        db.copyColumn(stmt, 0, &hist_urls[hist_count], &hist_url_lens[hist_count]);
        db.copyColumn(stmt, 1, &hist_titles[hist_count], &hist_title_lens[hist_count]);
        if (hist_url_lens[hist_count] > 0) hist_count += 1;
    }
}

// ── Download handoff ──

/// Single, minimal handoff point from an intercepted page download into
/// Opal's downloads: record it in download_history (the Transfers › History
/// list) and fetch the file into the save dir on a worker thread. Kept as
/// ONE function so a future transfers-service enqueue API can slot in
/// without touching the bridge/reader plumbing.
fn enqueueBrowserDownload(url: []const u8, filename: []const u8) void {
    const S = struct {
        var busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
        var url_buf: [2048]u8 = undefined;
        var url_len: usize = 0;
        var path_buf: [1024]u8 = undefined;
        var path_len: usize = 0;
        var name_buf: [256]u8 = undefined;
        var name_len: usize = 0;

        fn worker() void {
            const Z = @This();
            defer Z.busy.store(false, .release);
            var child = io_g.Child.init(&.{
                "curl",       "-L",  "--fail", "--silent",                "--show-error",
                "--max-time", "600", "-o",     Z.path_buf[0..Z.path_len], Z.url_buf[0..Z.url_len],
            }, alloc);
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;
            _ = child.spawn() catch {
                logs.pushLog("error", "browser", "Download failed to start (curl missing?)", false);
                return;
            };
            const term = child.wait() catch {
                logs.pushLog("error", "browser", "Download failed", false);
                return;
            };
            const ok = switch (term) {
                .exited => |code| code == 0,
                else => false,
            };
            var mb: [320]u8 = undefined;
            const msg = std.fmt.bufPrint(&mb, "{s}: {s}", .{
                if (ok) "Download finished" else "Download failed",
                Z.name_buf[0..Z.name_len],
            }) catch "Download finished";
            logs.pushLog(if (ok) "info" else "error", "browser", msg, ok);
            state.wakeUi();
        }
    };

    if (url.len == 0 or url.len > S.url_buf.len) return;
    if (S.busy.load(.acquire)) {
        state.showToast("A browser download is already running");
        return;
    }

    var name_tmp: [256]u8 = undefined;
    const safe_name = pure.sanitizeFilename(filename, &name_tmp);

    const paths = @import("../core/paths.zig");
    var dir_buf: [512]u8 = undefined;
    const save_dir = if (state.app.save_path_len > 0)
        state.app.save_path_buf[0..state.app.save_path_len]
    else
        paths.defaultSavePath(&dir_buf);

    // Copy ALL inputs into the struct statics BEFORE spawning (CLAUDE.md).
    @memcpy(S.url_buf[0..url.len], url);
    S.url_len = url.len;
    const nn = @min(safe_name.len, S.name_buf.len);
    @memcpy(S.name_buf[0..nn], safe_name[0..nn]);
    S.name_len = nn;
    const full = std.fmt.bufPrint(&S.path_buf, "{s}/{s}", .{ save_dir, safe_name }) catch return;
    S.path_len = full.len;

    S.busy.store(true, .release);
    if (std.Thread.spawn(.{}, S.worker, .{})) |t| t.detach() else |_| {
        S.busy.store(false, .release);
        logs.pushLog("error", "browser", "Could not start the download thread", false);
        return;
    }

    @import("history.zig").addDownloadHistory(safe_name, url);
    var tb: [300]u8 = undefined;
    if (std.fmt.bufPrint(&tb, "Downloading {s}", .{safe_name})) |msg| {
        state.showToast(msg);
    } else |_| {}
}

/// Apply a staged download event (reader thread → UI thread).
fn applyStagedDownload() void {
    var url_tmp: [2048]u8 = undefined;
    var name_tmp: [256]u8 = undefined;
    var url_len: usize = 0;
    var name_len: usize = 0;
    dl_stage_lock.lock();
    if (dl_stage_dirty) {
        dl_stage_dirty = false;
        url_len = dl_stage_url_len;
        @memcpy(url_tmp[0..url_len], dl_stage_url[0..url_len]);
        name_len = dl_stage_name_len;
        @memcpy(name_tmp[0..name_len], dl_stage_name[0..name_len]);
    }
    dl_stage_lock.unlock();
    if (url_len > 0) {
        // The aborted download also aborted the page's loading state.
        state.app.browser.is_loading.store(false, .release);
        enqueueBrowserDownload(url_tmp[0..url_len], name_tmp[0..name_len]);
    }
}

/// Escape + frame + send a navigate command (shared by navigate() and the
/// pending-URL flush in startBridgeThread — keeping the two paths identical).
fn sendNavigate(url: []const u8) void {
    var esc_buf: [4096]u8 = undefined;
    const esc_url = escapeJsonString(url, &esc_buf);
    var cmd_buf: [4200]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "{{\"cmd\":\"navigate\",\"url\":\"{s}\"}}", .{esc_url}) catch return;
    sendCommand(cmd);
}

/// Anti-block fetch: load `url` through the anti-detect browser on a dedicated
/// scrape page, wait out any Cloudflare / DDoS-Guard challenge, and copy the
/// unblocked HTML (or fetchapi text) into `out_buf`. Returns the slice, or null
/// on failure / timeout. SYNCHRONOUS — call ONLY from a scraper worker thread
/// (like curl today), never the UI thread; it blocks up to ~45s. One scrape
/// runs at a time (scrape_req_mutex). Starts the bridge if it isn't running.
pub fn fetchHtmlBlocking(url: []const u8, out_buf: []u8) ?[]const u8 {
    if (url.len == 0 or url.len >= 2048) return null;

    // Bring the bridge up if needed and wait (bounded ~20s) for it to be ready.
    if (!bridge_ready.load(.acquire)) {
        ensureBridge();
        var w: usize = 0;
        while (w < 200 and !bridge_ready.load(.acquire)) : (w += 1) {
            io_g.sleep(100 * std.time.ns_per_ms);
        }
        if (!bridge_ready.load(.acquire)) return null;
    }

    // Serialize scrape requests — a single dedicated scrape page on the bridge.
    scrape_req_mutex.lock();
    defer scrape_req_mutex.unlock();

    scrape_ready.store(false, .release);
    scrape_lock.lock();
    scrape_len = 0;
    scrape_err = false;
    scrape_lock.unlock();

    var esc_buf: [4096]u8 = undefined;
    const esc_url = escapeJsonString(url, &esc_buf);
    var cmd_buf: [4200]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "{{\"cmd\":\"fetchhtml\",\"url\":\"{s}\",\"wait\":15000}}", .{esc_url}) catch return null;
    sendCommand(cmd);

    // Poll for the 'H' frame / fetchhtml error (bounded: goto 25s + challenge
    // wait 15s + slack). Same publish/poll style as the bridge-startup wait.
    var waited: usize = 0;
    while (waited < 450) : (waited += 1) { // 450 * 100ms = 45s ceiling
        if (scrape_ready.load(.acquire)) break;
        io_g.sleep(100 * std.time.ns_per_ms);
    }
    if (!scrape_ready.load(.acquire)) return null;

    scrape_lock.lock();
    defer scrape_lock.unlock();
    if (scrape_err or scrape_len == 0) return null;
    const n = @min(scrape_len, out_buf.len);
    @memcpy(out_buf[0..n], scrape_buf[0..n]);
    return out_buf[0..n];
}

pub fn sendClickButton(x: f32, y: f32, button: []const u8) void {
    if (!bridge_ready.load(.acquire)) return;
    sendCommandFmt("{{\"cmd\":\"click\",\"x\":{d},\"y\":{d},\"button\":\"{s}\"}}", .{ @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)), button });
}

pub fn sendMouseMove(x: f32, y: f32) void {
    if (!bridge_ready.load(.acquire)) return;
    sendCommandFmt("{{\"cmd\":\"mousemove\",\"x\":{d},\"y\":{d}}}", .{ @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)) });
}

pub fn sendResize(w: u32, h: u32) void {
    if (!bridge_ready.load(.acquire)) return;
    sendCommandFmt("{{\"cmd\":\"resize\",\"w\":{d},\"h\":{d}}}", .{ w, h });
}

pub fn sendScroll(dy: f32) void {
    if (!bridge_ready.load(.acquire)) return;
    sendCommandFmt("{{\"cmd\":\"scroll\",\"dx\":0,\"dy\":{d}}}", .{@as(i32, @intFromFloat(dy * 100))});
}

pub fn sendKeypress(key: []const u8) void {
    if (!bridge_ready.load(.acquire)) return;
    var esc_buf: [4096]u8 = undefined;
    const esc_key = escapeJsonString(key, &esc_buf);
    sendCommandFmt("{{\"cmd\":\"keypress\",\"key\":\"{s}\"}}", .{esc_key});
}

pub fn sendType(text: []const u8) void {
    if (!bridge_ready.load(.acquire)) return;
    var esc_buf: [4096]u8 = undefined;
    const esc_text = escapeJsonString(text, &esc_buf);
    sendCommandFmt("{{\"cmd\":\"type\",\"text\":\"{s}\"}}", .{esc_text});
}

pub fn requestScreenshot() void {
    if (!bridge_ready.load(.acquire)) return;
    sendCommand("{\"cmd\":\"screenshot\"}");
}

pub fn goBack() void {
    if (!bridge_ready.load(.acquire)) return;
    sendCommand("{\"cmd\":\"back\"}");
}

pub fn goForward() void {
    if (!bridge_ready.load(.acquire)) return;
    sendCommand("{\"cmd\":\"forward\"}");
}

pub fn killBridge() void {
    if (bridge_process) |*proc| {
        // Send quit command gracefully
        if (proc.stdin) |*stdin| {
            @import("../core/io_global.zig").writeAll(stdin, "{\"cmd\":\"quit\"}\n") catch {};
        }
        @import("../core/io_global.zig").sleep(500 * std.time.ns_per_ms);
        _ = proc.kill() catch {};
        _ = proc.wait() catch {};
        bridge_process = null;
    }
    bridge_ready.store(false, .release);
    bridge_starting.store(false, .release);
}

const enums = @import("dvui").enums;

/// Map dvui Key enum to Playwright key name string
fn mapKeyToPlaywright(key: enums.Key) ?[]const u8 {
    return switch (key) {
        .enter => "Enter",
        .backspace => "Backspace",
        .tab => "Tab",
        .escape => "Escape",
        .space => "Space",
        .delete => "Delete",
        .home => "Home",
        .end => "End",
        .page_up => "PageUp",
        .page_down => "PageDown",
        .left => "ArrowLeft",
        .right => "ArrowRight",
        .up => "ArrowUp",
        .down => "ArrowDown",
        .a => "a",
        .b => "b",
        .c => "c",
        .d => "d",
        .e => "e",
        .f => "f",
        .g => "g",
        .h => "h",
        .i => "i",
        .j => "j",
        .k => "k",
        .l => "l",
        .m => "m",
        .n => "n",
        .o => "o",
        .p => "p",
        .q => "q",
        .r => "r",
        .s => "s",
        .t => "t",
        .u => "u",
        .v => "v",
        .w => "w",
        .x => "x",
        .y => "y",
        .z => "z",
        .zero => "0",
        .one => "1",
        .two => "2",
        .three => "3",
        .four => "4",
        .five => "5",
        .six => "6",
        .seven => "7",
        .eight => "8",
        .nine => "9",
        .minus => "-",
        .equal => "=",
        .left_bracket => "[",
        .right_bracket => "]",
        .backslash => "\\",
        .semicolon => ";",
        .apostrophe => "'",
        .comma => ",",
        .period => ".",
        .slash => "/",
        .grave => "`",
        .f1 => "F1",
        .f2 => "F2",
        .f3 => "F3",
        .f4 => "F4",
        .f5 => "F5",
        .f6 => "F6",
        .f7 => "F7",
        .f8 => "F8",
        .f9 => "F9",
        .f10 => "F10",
        .f11 => "F11",
        .f12 => "F12",
        else => null,
    };
}

// ── Texture management ──

fn updateFrameTexture() void {
    frame_lock.lock();
    defer frame_lock.unlock();

    if (!frame_dirty.load(.acquire)) return;
    frame_dirty.store(false, .release);

    // RGBA was decoded on the reader thread — this is only a GPU upload.
    const pixels = frame_pixels orelse return;
    const uw = frame_pix_w;
    const uh = frame_pix_h;
    const count = @as(usize, uw) * @as(usize, uh);
    if (count == 0 or pixels.len != count * 4) return;

    const pma: []const dvui.Color.PMA = @as([*]const dvui.Color.PMA, @ptrCast(@alignCast(pixels.ptr)))[0..count];

    if (frame_texture != null and frame_w == uw and frame_h == uh) {
        // Same dims — in-place update, no texture churn.
        dvui.Texture.update(&frame_texture.?, pma, .linear) catch {
            frame_texture.?.destroyLater();
            frame_texture = dvui.textureCreate(pma, uw, uh, .linear, .rgba_32) catch null;
        };
    } else {
        if (frame_texture) |old| old.destroyLater();
        frame_texture = dvui.textureCreate(pma, uw, uh, .linear, .rgba_32) catch null;
    }
    frame_w = uw;
    frame_h = uh;
}

/// Apply reader-thread nav updates on the UI thread. The URL is skipped while
/// the address bar has focus — an SPA pushState firing mid-edit must not
/// clobber what the user is typing (the title still updates).
fn applyStagedNav(b: *@TypeOf(state.app.browser)) void {
    nav_stage_lock.lock();
    defer nav_stage_lock.unlock();
    if (!nav_stage_dirty) return;

    if (nav_stage_title_len > 0) {
        @memcpy(b.title[0..nav_stage_title_len], nav_stage_title[0..nav_stage_title_len]);
        b.title_len = nav_stage_title_len;
    }
    if (nav_stage_url_len > 0 and !url_bar_focused) {
        const ulen = @min(nav_stage_url_len, b.url_buf.len - 1);
        @memcpy(b.url_buf[0..ulen], nav_stage_url[0..ulen]);
        b.url_buf[ulen] = 0; // sliceTo(0) must not see a stale tail
        b.url_len = ulen;
    }
    // URL held back while focused stays staged (dirty) so it applies once the
    // user leaves the field without submitting.
    nav_stage_dirty = url_bar_focused and nav_stage_url_len > 0;

    if (nav_stage_url_len > 0) {
        const staged = nav_stage_url[0..nav_stage_url_len];

        // Record the visit ONCE per navigation (the stage can stay dirty for
        // many frames while the URL bar is focused — dedup by last URL).
        if (!std.mem.eql(u8, staged, last_visit_url[0..last_visit_url_len])) {
            const vn = @min(staged.len, last_visit_url.len);
            @memcpy(last_visit_url[0..vn], staged[0..vn]);
            last_visit_url_len = vn;
            recordVisit(staged, nav_stage_title[0..nav_stage_title_len]);

            // Per-site zoom: entering a different site swaps in its persisted
            // factor (default 1.0).
            const host = pure.urlHost(staged);
            if (!std.mem.eql(u8, host, zoom_host[0..zoom_host_len])) {
                const hn = @min(host.len, zoom_host.len);
                @memcpy(zoom_host[0..hn], host[0..hn]);
                zoom_host_len = hn;
                zoom_level = loadZoomFor(zoom_host[0..zoom_host_len]) orelse 1.0;
                // The page just loaded at zoom 1.0 — a site stored at 1.0
                // needs no command; a zoomed site gets it re-applied below.
            }
        }
    }

    // CSS zoom is per-document — re-apply after every navigation.
    if (zoom_level != 1.0) sendZoom(zoom_level);
}

// ══════════════════════════════════════════════════════════
// Pane Rendering
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    const b = &state.app.browser;

    const icons = @import("icons");

    // Wrap the whole browser body in ONE expanding container. Without this, the
    // URL bar / title / landing render as bare siblings directly into the shell's
    // content box — next to the Browse sub-tabs row — and the expand=.both frame
    // starves the non-expand siblings (sub-tabs + URL bar) of height, making them
    // vanish. Every other Browse content renderer wraps its body the same way.
    var root = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer root.deinit();

    // Apply reader-thread nav updates (URL bar text + title) on the UI thread.
    applyStagedNav(b);

    // Intercepted downloads → Opal's downloader (staged by the reader thread).
    applyStagedDownload();

    // Reader-overlay text staged by the reader thread → UI copy.
    {
        reader_lock.lock();
        if (reader_stage_dirty) {
            reader_stage_dirty = false;
            reader_len = @min(reader_stage_len, reader_buf.len);
            @memcpy(reader_buf[0..reader_len], reader_stage[0..reader_len]);
        }
        reader_lock.unlock();
    }

    // Loading watchdog: if the bridge never answers (missing camoufox, crashed
    // worker), stop the loading indicator instead of animating it — and its
    // dvui.refresh loop — forever.
    if (b.is_loading.load(.acquire)) {
        const since = loading_since_ms.load(.acquire);
        if (since > 0 and io_g.milliTimestamp() - since > LOADING_TIMEOUT_MS) {
            b.is_loading.store(false, .release);
            logs.pushLog("error", "browser", "Navigation timed out — browser engine not responding", false);
        }
    }

    // Returning to this tab after it was hidden → poke the bridge for a fresh
    // frame (the pump idles out after 2 min of silence; a stale page may have
    // updated underneath). Cheap: the bridge dedups unchanged frames by hash.
    {
        const S = struct {
            var last_seen_ms: i64 = 0;
        };
        const now_ms = io_g.milliTimestamp();
        if (now_ms - S.last_seen_ms > 2000 and bridge_ready.load(.acquire)) requestScreenshot();
        S.last_seen_ms = now_ms;
    }

    // URL bar with icon buttons
    {
        var url_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
            .background = true,
            .color_fill = dvui.Color{ .r = 18, .g = 18, .b = 22, .a = 245 },
        });
        defer url_row.deinit();

        const icon_btn_style = dvui.Options{
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.text_secondary,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 3, .y = 2, .w = 3, .h = 2 },
            .margin = .{ .x = 1, .y = 0, .w = 1, .h = 0 },
        };

        // Back
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"chevron-left", .{}, .{}, icon_btn_style)) {
            goBack();
        }

        // Forward
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"chevron-right", .{}, .{}, icon_btn_style)) {
            goForward();
        }

        // Refresh
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"rotate-cw", .{}, .{}, icon_btn_style)) {
            requestScreenshot();
        }

        // Status indicator: spinner while navigating/starting, check when ready
        {
            if (b.is_loading.load(.acquire) or bridge_starting.load(.acquire)) {
                dvui.spinner(@src(), .{
                    .id_extra = 99,
                    .color_text = theme.colors.accent,
                    .min_size_content = .{ .w = 14, .h = 14 },
                    .padding = .{ .x = 2, .y = 2, .w = 2, .h = 2 },
                    .gravity_y = 0.5,
                });
            } else if (bridge_ready.load(.acquire)) {
                dvui.icon(@src(), "browser-ready", icons.tvg.lucide.@"circle-check", .{}, .{
                    .color_text = theme.colors.accent,
                    .min_size_content = .{ .w = 14, .h = 14 },
                    .padding = .{ .x = 2, .y = 2, .w = 2, .h = 2 },
                });
            }
        }

        // URL input — manual TextEntryWidget so dvui.suggestion can own the
        // event pass (↑/↓ move the dropdown highlight, Enter commits, Esc
        // closes); te.processEvents must NOT run (see youtube.zig's search).
        var te = dvui.widgetAlloc(dvui.TextEntryWidget);
        te.init(@src(), .{ .text = .{ .buffer = &b.url_buf } }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 200, .h = 18 },
            .color_fill = dvui.Color{ .r = 28, .g = 28, .b = 34, .a = 255 },
            .color_border = dvui.Color{ .r = 50, .g = 50, .b = 60, .a = 200 },
            .color_text = theme.colors.text_primary,
            .border = dvui.Rect.all(1),
            .corner_radius = theme.dims.rad_xl,
            .margin = .{ .x = 3, .y = 0, .w = 3, .h = 0 },
            .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
        });
        var sug = dvui.suggestion(te, .{ .open_on_focus = false, .open_on_text_change = true });
        te.draw();

        // History autocomplete: rank the cached top-visited rows against the
        // typed text (browser_pure.historyMatchScore) and offer the best 5.
        var nav_pick: ?usize = null;
        {
            const q = std.mem.sliceTo(&b.url_buf, 0);
            var picks: [5]usize = undefined;
            var scores: [5]u32 = .{ 0, 0, 0, 0, 0 };
            var npicks: usize = 0;
            if (q.len >= 2 and url_bar_focused) {
                loadHistoryRows();
                for (0..hist_count) |hi| {
                    const hurl = hist_urls[hi][0..hist_url_lens[hi]];
                    // The page the user is already on is not a suggestion.
                    if (std.mem.eql(u8, hurl, q)) continue;
                    const sc = pure.historyMatchScore(q, hurl, hist_titles[hi][0..hist_title_lens[hi]]);
                    if (sc == 0) continue;
                    // Insertion sort into the top-5 (rows arrive most-visited
                    // first, so equal scores keep the more-visited row).
                    var ins: usize = npicks;
                    while (ins > 0 and scores[ins - 1] < sc) : (ins -= 1) {}
                    if (ins >= picks.len) continue;
                    var mv: usize = @min(npicks, picks.len - 1);
                    while (mv > ins) : (mv -= 1) {
                        picks[mv] = picks[mv - 1];
                        scores[mv] = scores[mv - 1];
                    }
                    picks[ins] = hi;
                    scores[ins] = sc;
                    if (npicks < picks.len) npicks += 1;
                }
            }
            if (npicks == 0) sug.close();
            if (npicks > 0 and sug.dropped()) {
                for (picks[0..npicks]) |hi| {
                    var disp_buf: [96]u8 = undefined;
                    var disp: []const u8 = hist_urls[hi][0..hist_url_lens[hi]];
                    if (std.mem.indexOf(u8, disp, "://")) |sp| disp = disp[sp + 3 ..];
                    const safe_disp = safeUtf8Buf(disp[0..@min(disp.len, 88)], &disp_buf);
                    if (sug.addChoiceLabel(safe_disp)) nav_pick = hi;
                }
            }
        }
        sug.deinit();
        const enter_pressed = te.enter_pressed;
        // While the user is editing the address, staged nav updates must not
        // overwrite their typing (applyStagedNav checks this each frame).
        url_bar_focused = dvui.focusedWidgetId() == te.data().id;
        te.deinit();
        if (nav_pick) |hi| {
            var nav_buf: [512]u8 = undefined;
            const n = hist_url_lens[hi];
            @memcpy(nav_buf[0..n], hist_urls[hi][0..n]);
            navigate(nav_buf[0..n]);
        }

        // Go (play icon)
        const clicked_go = dvui.buttonIcon(@src(), "", icons.tvg.lucide.play, .{}, .{}, .{
            .color_fill = theme.colors.accent,
            .color_text = dvui.Color.white,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 4, .y = 3, .w = 4, .h = 3 },
            .margin = .{ .x = 1, .y = 0, .w = 1, .h = 0 },
        });
        if (clicked_go or enter_pressed) {
            const input_text = std.mem.sliceTo(&b.url_buf, 0);
            if (input_text.len > 0) {
                // Smart address bar: URLs pass through, bare hosts get https://,
                // anything else becomes a web search (browser_pure logic).
                var addr_buf: [2048]u8 = undefined;
                const resolved = pure.resolveAddress(input_text, &addr_buf);
                if (resolved.len > 0) loadContent(resolved);
            }
        }

        // Bookmark star — gold when the current page is bookmarked.
        if (b.url_len > 0) {
            const bookmarked = findBookmark(b.url_buf[0..b.url_len]) != null;
            var star_wd: dvui.WidgetData = undefined;
            var star_style = icon_btn_style;
            star_style.id_extra = 119;
            star_style.data_out = &star_wd;
            if (bookmarked) star_style.color_text = theme.colors.warning;
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.star, .{}, .{}, star_style)) {
                toggleBookmark();
            }
            @import("../ui/components.zig").tipId(@src(), star_wd, if (bookmarked) "Remove bookmark" else "Bookmark this page", 119);
        }

        // Copy current URL
        if (b.url_len > 0) {
            var copy_wd: dvui.WidgetData = undefined;
            var copy_style = icon_btn_style;
            copy_style.id_extra = 120;
            copy_style.data_out = &copy_wd;
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.copy, .{}, .{}, copy_style)) {
                dvui.clipboardTextSet(b.url_buf[0..b.url_len]);
                state.showToast("URL copied");
            }
            @import("../ui/components.zig").tipId(@src(), copy_wd, "Copy URL", 120);
        }

        // Open the current page in the media player (yt-dlp handles most
        // video pages) — the browse-to-watch handoff in one click.
        if (b.url_len > 0) {
            var mpv_wd: dvui.WidgetData = undefined;
            var mpv_style = icon_btn_style;
            mpv_style.id_extra = 121;
            mpv_style.data_out = &mpv_wd;
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"monitor-play", .{}, .{}, mpv_style)) {
                var url_copy: [2048]u8 = undefined;
                @memcpy(url_copy[0..b.url_len], b.url_buf[0..b.url_len]);
                state.showToast("Opening in player...");
                loadContentDirect(url_copy[0..b.url_len]);
            }
            @import("../ui/components.zig").tipId(@src(), mpv_wd, "Play this page in the media player", 121);
        }

        // Zoom out / in (Cmd/Ctrl - and + work too; Cmd/Ctrl 0 resets)
        {
            var zo_style = icon_btn_style;
            zo_style.id_extra = 123;
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"zoom-out", .{}, .{}, zo_style)) {
                setZoom(zoom_level - 0.1);
            }
            var zi_style = icon_btn_style;
            zi_style.id_extra = 124;
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"zoom-in", .{}, .{}, zi_style)) {
                setZoom(zoom_level + 0.1);
            }
        }

        // Reader — extract the page's text into a scrollable overlay.
        if (b.url_len > 0) {
            var rd_wd: dvui.WidgetData = undefined;
            var rd_style = icon_btn_style;
            rd_style.id_extra = 125;
            rd_style.data_out = &rd_wd;
            if (reader_open) rd_style.color_text = theme.colors.accent;
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"book-open", .{}, .{}, rd_style)) {
                if (reader_open) {
                    reader_open = false;
                } else {
                    reader_open = true;
                    reader_len = 0; // stale text from the previous page hides
                    requestReadText();
                }
            }
            @import("../ui/components.zig").tipId(@src(), rd_wd, "Reader: extract page text", 125);
        }
    }

    // ── Find-in-page bar (Cmd/Ctrl+F; Enter = next match; Esc closes) ──
    if (find_open) {
        var frow = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 6, .y = 3, .w = 6, .h = 3 },
            .background = true,
            .color_fill = dvui.Color{ .r = 22, .g = 22, .b = 28, .a = 255 },
        });
        defer frow.deinit();

        dvui.icon(@src(), "find", icons.tvg.lucide.search, .{}, .{
            .color_text = theme.colors.text_secondary,
            .min_size_content = .{ .w = 13, .h = 13 },
            .gravity_y = 0.5,
            .margin = .{ .x = 2, .y = 0, .w = 6, .h = 0 },
        });

        var fte = dvui.textEntry(@src(), .{ .text = .{ .buffer = &find_buf }, .placeholder = "Find in page…" }, .{
            .min_size_content = .{ .w = 260, .h = 16 },
            .color_fill = dvui.Color{ .r = 28, .g = 28, .b = 34, .a = 255 },
            .color_text = theme.colors.text_primary,
            .border = dvui.Rect.all(1),
            .color_border = dvui.Color{ .r = 50, .g = 50, .b = 60, .a = 200 },
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
            .gravity_y = 0.5,
        });
        const find_enter = fte.enter_pressed;
        // New text → the old result is stale; hide the count until the bridge
        // answers the next search.
        if (fte.text_changed) find_count.store(-1, .release);
        fte.deinit();

        const nav_btn_style = dvui.Options{
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.text_secondary,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 3, .y = 2, .w = 3, .h = 2 },
            .gravity_y = 0.5,
        };
        var prev_style = nav_btn_style;
        prev_style.id_extra = 129;
        const prev_clicked = dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"chevron-left", .{}, .{}, prev_style);
        var next_style = nav_btn_style;
        next_style.id_extra = 130;
        const next_clicked = dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"chevron-right", .{}, .{}, next_style);
        if (next_clicked or prev_clicked or find_enter) {
            const t = std.mem.sliceTo(&find_buf, 0);
            if (t.len > 0) sendFind(t, prev_clicked);
        }

        // Match count from the last bridge response ("N matches" / "No matches").
        {
            const cnt = find_count.load(.acquire);
            if (cnt == 0) {
                _ = dvui.label(@src(), "No matches", .{}, .{
                    .id_extra = 132,
                    .color_text = theme.colors.text_tertiary,
                    .gravity_y = 0.5,
                    .padding = .{ .x = 6, .y = 0, .w = 6, .h = 0 },
                });
            } else if (cnt > 0) {
                _ = dvui.label(@src(), "{d} match{s}", .{ cnt, if (cnt == 1) "" else "es" }, .{
                    .id_extra = 133,
                    .color_text = theme.colors.text_secondary,
                    .gravity_y = 0.5,
                    .padding = .{ .x = 6, .y = 0, .w = 6, .h = 0 },
                });
            }
        }

        var close_style = nav_btn_style;
        close_style.id_extra = 131;
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.x, .{}, .{}, close_style)) {
            find_open = false;
        }
    }

    // Title bar
    if (b.title_len > 0) {
        var tbuf: [256]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{safeUtf8Buf(b.title[0..b.title_len], &tbuf)}, .{
            .color_text = theme.colors.text_primary,
            .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
            .background = true,
            .color_fill = dvui.Color{ .r = 22, .g = 22, .b = 28, .a = 255 },
            .expand = .horizontal,
        });
    }

    // Loading state — a slim indeterminate sweep under the URL bar. The
    // previous page stays visible underneath (browser-style), instead of the
    // whole pane blanking to a "Loading..." label. Only while the engine can
    // actually make progress — a sweep animating over "engine not started"
    // read as a stuck red line.
    if (b.is_loading.load(.acquire) and (bridge_ready.load(.acquire) or bridge_starting.load(.acquire))) {
        renderLoadingBar();
        dvui.refresh(null, @src(), null);
    }

    // ── Frame rendering or landing page ──

    // Update texture from latest frame
    updateFrameTexture();

    if (reader_open) {
        renderReaderOverlay();
    } else if (frame_texture) |tex| {
        // Render the browser frame as a full-pane image
        var img_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .background = true,
            .color_fill = dvui.Color{ .r = 12, .g = 12, .b = 16, .a = 255 },
        });
        defer img_box.deinit();

        _ = dvui.image(@src(), .{ .source = .{ .texture = tex } }, .{
            .expand = .both,
            .gravity_x = 0.5,
            .gravity_y = 0.0,
        });

        // ── Input forwarding ──
        // Guards: skip events other widgets already handled (typing in the
        // URL bar must not leak into the page — it used to double-fire), and
        // skip mouse events belonging to floating windows (pickers, modals).
        const rs = img_box.data().contentRectScale();
        const rect = rs.r;
        const fw: f32 = @floatFromInt(frame_w);
        const fh: f32 = @floatFromInt(frame_h);
        var wheel_accum: f32 = 0;

        for (dvui.events()) |*e| {
            if (e.handled) continue;
            switch (e.evt) {
                .mouse => |mouse| {
                    if (mouse.floating_win != dvui.subwindowCurrentId()) continue;
                    const mx = mouse.p.x - rect.x;
                    const my = mouse.p.y - rect.y;
                    const inside = mx >= 0 and my >= 0 and mx < rect.w and my < rect.h;
                    if (!inside) continue;
                    const sx = mx * fw / rect.w;
                    const sy = my * fh / rect.h;
                    switch (mouse.action) {
                        .press => {
                            switch (mouse.button) {
                                .left => sendClickButton(sx, sy, "left"),
                                .right => sendClickButton(sx, sy, "right"),
                                .middle => sendClickButton(sx, sy, "middle"),
                                else => continue,
                            }
                            e.handled = true;
                        },
                        .wheel_y => |wy| {
                            // Coalesce: a trackpad emits many wheel events per
                            // frame — one combined scroll command per frame.
                            wheel_accum += wy;
                            e.handled = true;
                        },
                        .position => {
                            // Hover pass-through (throttled) — page dropdowns,
                            // hover previews and cursor feedback come alive.
                            const HS = struct {
                                var last_ms: i64 = 0;
                                var last_x: f32 = -1e9;
                                var last_y: f32 = -1e9;
                            };
                            const now_ms = io_g.milliTimestamp();
                            const moved = @abs(mouse.p.x - HS.last_x) > 3 or @abs(mouse.p.y - HS.last_y) > 3;
                            if (moved and now_ms - HS.last_ms >= 50) {
                                HS.last_ms = now_ms;
                                HS.last_x = mouse.p.x;
                                HS.last_y = mouse.p.y;
                                sendMouseMove(sx, sy);
                            }
                        },
                        else => {},
                    }
                },
                .key => |key| {
                    if (key.action != .down and key.action != .repeat) continue;
                    const mod = key.mod;
                    const chord = mod.command() or mod.control();
                    // Local browser shortcuts — handled here, never forwarded.
                    if (chord and key.code == .f) {
                        find_open = true;
                        find_count.store(-1, .release);
                        e.handled = true;
                        continue;
                    }
                    if (chord and (key.code == .equal or key.code == .minus or key.code == .zero)) {
                        setZoom(switch (key.code) {
                            .equal => zoom_level + 0.1,
                            .minus => zoom_level - 0.1,
                            else => 1.0,
                        });
                        e.handled = true;
                        continue;
                    }
                    if (key.code == .escape and find_open) {
                        find_open = false;
                        e.handled = true;
                        continue;
                    }
                    if (mapKeyToPlaywright(key.code)) |base| {
                        // Plain printable keys arrive again as text events —
                        // forwarding both double-typed every character. Only
                        // navigation keys and chords go through keypress.
                        if (pure.shouldForwardKeypress(base, mod.control(), mod.command(), mod.alt())) {
                            var combo_buf: [64]u8 = undefined;
                            const combo = pure.composeKeyCombo(base, mod.control(), mod.command(), mod.alt(), mod.shift(), &combo_buf);
                            sendKeypress(combo);
                            e.handled = true;
                        }
                    }
                },
                .text => |text| {
                    switch (text.action) {
                        .value => |val| {
                            if (val.txt.len > 0) {
                                sendType(val.txt);
                                e.handled = true;
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
        if (wheel_accum != 0) sendScroll(wheel_accum);

        // Keep the remote viewport matched to the pane (LOGICAL pixels — CSS
        // px map 1:1 to dvui points, so page text renders at normal size and
        // the frame fills the pane without stretching).
        if (rs.s > 0) maybeSyncViewport(rect.w / rs.s, rect.h / rs.s);
    } else {
        // Landing page — no frame yet. expand=.both fills the space BELOW the
        // URL bar; do NOT add gravity_y here — gravity on an expanded box makes
        // it claim the full parent height and draw its fill over the URL bar.
        var empty = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .background = true,
            .color_fill = dvui.Color{ .r = 12, .g = 12, .b = 16, .a = 255 },
            .padding = .{ .x = 0, .y = 12, .w = 0, .h = 0 },
        });
        defer empty.deinit();

        _ = dvui.label(@src(), "Opal Browser", .{}, .{
            .color_text = theme.colors.text_primary,
            .gravity_x = 0.5,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
        });

        if (bridge_ready.load(.acquire)) {
            _ = dvui.label(@src(), "Powered by {s} — {s}", .{ engineDisplayName(active_engine), switch (active_engine) {
                .camoufox => "Anti-detect Firefox",
                .cloakbrowser => "Anti-detect Chromium",
            } }, .{
                .id_extra = 3,
                .color_text = theme.colors.accent,
                .gravity_x = 0.5,
                .padding = .{ .x = 0, .y = 0, .w = 0, .h = 2 },
            });
            _ = dvui.label(@src(), "Real browser rendering · Cloudflare bypass · Full JS support", .{}, .{
                .id_extra = 6,
                .color_text = theme.colors.text_secondary,
                .gravity_x = 0.5,
                .padding = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
            });
        } else if (bridge_starting.load(.acquire)) {
            _ = dvui.label(@src(), "Starting the {s} browser engine...", .{engineDisplayName(active_engine)}, .{
                .id_extra = 3,
                .color_text = theme.colors.text_secondary,
                .gravity_x = 0.5,
                .padding = .{ .x = 0, .y = 0, .w = 0, .h = 2 },
            });
        } else {
            renderEngineStatus();
        }

        _ = dvui.label(@src(), "Enter a URL above to browse — or type a search", .{}, .{
            .id_extra = 5,
            .color_text = theme.colors.text_secondary,
            .gravity_x = 0.5,
            .padding = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
        });
        _ = dvui.label(@src(), "Videos auto-route to MPV · Comics to viewer · Web to browser", .{}, .{
            .id_extra = 7,
            .color_text = dvui.Color{ .r = 60, .g = 70, .b = 90, .a = 255 },
            .gravity_x = 0.5,
        });

        renderBookmarksSection();
        renderQuickLaunch(b);

        // Auto-start bridge on first render if not started
        ensureBridge();
    }
}

/// Landing-page engine status: install CTA with LIVE progress when the
/// Camoufox venv is missing, plain status otherwise. The installer streams
/// pip/download output line-by-line into the label.
fn renderEngineStatus() void {
    const inst: InstallState = @enumFromInt(install_state.load(.acquire));

    if (inst == .running) {
        var prow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 10, .gravity_x = 0.5 });
        defer prow.deinit();
        dvui.spinner(@src(), .{
            .color_text = theme.colors.accent,
            .min_size_content = .{ .w = 13, .h = 13 },
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
        });
        install_lock.lock();
        var mbuf: [280]u8 = undefined;
        const msg = safeUtf8Buf(install_msg[0..install_msg_len], &mbuf);
        install_lock.unlock();
        _ = dvui.label(@src(), "{s}", .{msg}, .{
            .id_extra = 11,
            .color_text = theme.colors.text_secondary,
            .gravity_y = 0.5,
        });
        return;
    }

    if (!engineInstalled()) {
        _ = dvui.label(@src(), "Browser engine not installed", .{}, .{
            .id_extra = 3,
            .color_text = theme.colors.text_secondary,
            .gravity_x = 0.5,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 2 },
        });
        if (inst == .failed) {
            install_lock.lock();
            var mbuf: [280]u8 = undefined;
            const msg = safeUtf8Buf(install_msg[0..install_msg_len], &mbuf);
            install_lock.unlock();
            _ = dvui.label(@src(), "{s}", .{msg}, .{
                .id_extra = 12,
                .color_text = theme.colors.danger,
                .gravity_x = 0.5,
                .padding = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
            });
        }
        if (dvui.button(@src(), if (inst == .failed) "Retry install" else "Install browser engine (~200 MB)", .{}, .{
            .id_extra = 13,
            .gravity_x = 0.5,
            .margin = .{ .x = 0, .y = 8, .w = 0, .h = 8 },
            .color_fill = theme.colors.accent,
            .color_text = theme.colors.text_on_accent,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 14, .y = 6, .w = 14, .h = 6 },
        })) {
            installEngine();
        }
        _ = dvui.label(@src(), "{s}", .{switch (active_engine) {
            .camoufox => "Headless Firefox (Camoufox) rendered inside this pane — anti-bot, full JS",
            .cloakbrowser => "Headless Chromium (CloakBrowser) rendered inside this pane — anti-bot, full JS",
        }}, .{
            .id_extra = 14,
            .color_text = theme.colors.text_tertiary,
            .gravity_x = 0.5,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
        });
        return;
    }

    _ = dvui.label(@src(), "Browser engine not started", .{}, .{
        .id_extra = 3,
        .color_text = theme.colors.text_secondary,
        .gravity_x = 0.5,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 2 },
    });
    _ = dvui.label(@src(), "Enter a URL above to launch {s}", .{engineDisplayName(active_engine)}, .{
        .id_extra = 6,
        .color_text = theme.colors.text_tertiary,
        .gravity_x = 0.5,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
    });
}

/// Landing-page "Bookmarks" list — one-click relaunch, newest first.
fn renderBookmarksSection() void {
    loadBookmarks();
    if (bookmark_count == 0) return;

    _ = dvui.label(@src(), "Bookmarks", .{}, .{
        .id_extra = 30,
        .color_text = theme.colors.text_secondary,
        .gravity_x = 0.5,
        .padding = .{ .x = 0, .y = 16, .w = 0, .h = 4 },
    });

    var clicked: ?usize = null;
    const show = @min(bookmark_count, 6);
    for (bookmarks[0..show], 0..) |*bm, bi| {
        // Prefer the page title; fall back to the scheme-stripped URL.
        var disp: []const u8 = if (bm.text_len > 0) bm.text[0..bm.text_len] else bm.url[0..bm.url_len];
        if (bm.text_len == 0) {
            if (std.mem.indexOf(u8, disp, "://")) |p| disp = disp[p + 3 ..];
        }
        var dbuf: [64]u8 = undefined;
        const safe_disp = safeUtf8Buf(disp[0..@min(disp.len, 56)], &dbuf);

        if (dvui.button(@src(), safe_disp, .{}, .{
            .id_extra = bi + 31,
            .gravity_x = 0.5,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_fill_hover = theme.colors.bg_hover,
            .color_text = theme.colors.warning,
            .border = dvui.Rect.all(0),
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 12, .y = 4, .w = 12, .h = 4 },
        })) {
            clicked = bi;
        }
    }

    if (clicked) |ci| {
        navigate(bookmarks[ci].url[0..bookmarks[ci].url_len]);
    }
}

/// Landing-page "Recent" list — up to 6 deduped session-history entries as
/// one-click relaunch buttons. Session-only (respects incognito, which never
/// records history in the first place).
fn renderQuickLaunch(b: *@TypeOf(state.app.browser)) void {
    if (b.history_count == 0) return;

    _ = dvui.label(@src(), "Recent", .{}, .{
        .id_extra = 40,
        .color_text = theme.colors.text_secondary,
        .gravity_x = 0.5,
        .padding = .{ .x = 0, .y = 16, .w = 0, .h = 4 },
    });

    const MAX_SHOW: usize = 6;
    var shown_idx: [MAX_SHOW]usize = undefined;
    var shown: usize = 0;
    var clicked: ?usize = null;

    var hi: usize = b.history_count;
    outer: while (hi > 0 and shown < MAX_SHOW) {
        hi -= 1;
        const url = b.history[hi][0..b.history_lens[hi]];
        if (url.len == 0) continue;
        for (shown_idx[0..shown]) |si| {
            if (std.mem.eql(u8, b.history[si][0..b.history_lens[si]], url)) continue :outer;
        }
        shown_idx[shown] = hi;
        shown += 1;

        // Display without scheme, truncated.
        var disp: []const u8 = url;
        if (std.mem.indexOf(u8, disp, "://")) |p| disp = disp[p + 3 ..];
        var dbuf: [64]u8 = undefined;
        const safe_disp = safeUtf8Buf(disp[0..@min(disp.len, 56)], &dbuf);

        if (dvui.button(@src(), safe_disp, .{}, .{
            .id_extra = shown + 41,
            .gravity_x = 0.5,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_fill_hover = theme.colors.bg_hover,
            .color_text = theme.colors.text_secondary,
            .border = dvui.Rect.all(0),
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 12, .y = 4, .w = 12, .h = 4 },
        })) {
            clicked = hi;
        }
    }

    // Navigate after the loop — navigate() mutates the history arrays the
    // loop above is slicing into.
    if (clicked) |ci| {
        var nav_buf: [2048]u8 = undefined;
        const n = b.history_lens[ci];
        @memcpy(nav_buf[0..n], b.history[ci][0..n]);
        navigate(nav_buf[0..n]);
    }
}

/// Reader overlay — the page's extracted text (bridge "readtext" event) in a
/// scrollable pane, in place of the streamed frame. Esc or the X closes it.
fn renderReaderOverlay() void {
    const icons = @import("icons");

    for (dvui.events()) |*e| {
        if (e.handled) continue;
        switch (e.evt) {
            .key => |key| {
                if (key.action == .down and key.code == .escape) {
                    reader_open = false;
                    e.handled = true;
                }
            },
            else => {},
        }
    }

    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = dvui.Color{ .r = 14, .g = 14, .b = 18, .a = 255 },
    });
    defer box.deinit();

    {
        var hrow = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
        });
        defer hrow.deinit();
        _ = dvui.label(@src(), "Reader", .{}, .{
            .color_text = theme.colors.text_primary,
            .gravity_y = 0.5,
        });
        var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
        spacer.deinit();
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.x, .{}, .{}, .{
            .id_extra = 140,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.text_secondary,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 3, .y = 2, .w = 3, .h = 2 },
            .gravity_y = 0.5,
        })) {
            reader_open = false;
        }
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    if (reader_len == 0) {
        _ = dvui.label(@src(), "Extracting page text…", .{}, .{
            .id_extra = 141,
            .color_text = theme.colors.text_secondary,
            .gravity_x = 0.5,
            .padding = .{ .x = 0, .y = 20, .w = 0, .h = 0 },
        });
        dvui.refresh(null, @src(), null);
        return;
    }

    const S = struct {
        var safe_buf: [8192]u8 = undefined;
    };
    var tl = dvui.textLayout(@src(), .{}, .{
        .expand = .horizontal,
        .background = false,
        .padding = .{ .x = 16, .y = 10, .w = 16, .h = 16 },
    });
    tl.addText(safeUtf8Buf(reader_buf[0..reader_len], &S.safe_buf), .{
        .color_text = theme.colors.text_primary,
    });
    tl.deinit();
}

/// Indeterminate 3px sweep — rendered under the URL bar while navigating.
fn renderLoadingBar() void {
    var track = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_elevated,
        .min_size_content = .{ .w = 0, .h = 3 },
        .max_size_content = .{ .w = std.math.floatMax(f32), .h = 3 },
    });
    defer track.deinit();
    const track_w = track.data().contentRectScale().r.w;
    if (track_w <= 0) return;
    const now_ms = io_g.milliTimestamp();
    const frac: f32 = @as(f32, @floatFromInt(@mod(now_ms, 1100))) / 1100.0;
    const seg_w = track_w * 0.28;
    var fill = dvui.box(@src(), .{}, .{
        .background = true,
        .color_fill = theme.colors.accent,
        .corner_radius = dvui.Rect.all(2),
        .margin = .{ .x = frac * (track_w - seg_w), .y = 0, .w = 0, .h = 0 },
        .min_size_content = .{ .w = seg_w, .h = 3 },
        .max_size_content = .{ .w = seg_w, .h = 3 },
    });
    fill.deinit();
}

/// Debounced pane→viewport sync. When the pane's on-screen size settles
/// (300 ms without further change), resize the remote viewport to match.
/// Sizes are LOGICAL px, clamped to the same bounds the bridge enforces —
/// recording an unclamped size would desync and never re-converge.
fn maybeSyncViewport(w_in: f32, h_in: f32) void {
    if (!bridge_ready.load(.acquire)) return;
    if (w_in < 200 or h_in < 150) return;
    // Mirror MIN/MAX_VIEW_* in camoufox_bridge.py.
    const w = std.math.clamp(w_in, 320, 2560);
    const h = std.math.clamp(h_in, 240, 1600);
    const S = struct {
        var sent_w: f32 = 0;
        var sent_h: f32 = 0;
        var pend_w: f32 = 0;
        var pend_h: f32 = 0;
        var pend_since: i64 = 0;
    };
    if (@abs(w - S.sent_w) < 16 and @abs(h - S.sent_h) < 16) return;
    const now_ms = io_g.milliTimestamp();
    if (@abs(w - S.pend_w) > 8 or @abs(h - S.pend_h) > 8) {
        // New candidate size — restart the debounce window.
        S.pend_w = w;
        S.pend_h = h;
        S.pend_since = now_ms;
        dvui.refresh(null, @src(), null);
        return;
    }
    if (now_ms - S.pend_since < 300) {
        dvui.refresh(null, @src(), null);
        return;
    }
    S.sent_w = w;
    S.sent_h = h;
    sendResize(@intFromFloat(w), @intFromFloat(h));
}

// ══════════════════════════════════════════════════════════
// Content Router — auto-detect provider from URL
// ══════════════════════════════════════════════════════════

// Routing logic lives in browser_pure.zig (unit-tested); re-exported here so
// callers keep importing browser.routeContent / browser.ContentRoute.
pub const ContentRoute = pure.ContentRoute;
pub const routeContent = pure.routeContent;

/// Load a URL directly into mpv without content-type routing.
/// Use for URLs already known to be video streams (e.g. Stremio debrid links,
/// direct CDN streams) where routeContent() would misidentify them as web pages.
pub fn loadContentDirect(url: []const u8) void {
    if (state.app.players.items.len == 0) {
        if (@import("../player/player.zig").MediaPlayer.init(alloc)) |np| {
            state.app.players.append(alloc, np) catch {
                np.deinit(alloc);
                return;
            };
            state.app.active_player_idx = 0;
        } else |_| return;
    }
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const p = state.app.players.items[state.app.active_player_idx];
    p.provider = .mpv;
    var url_z: [2049]u8 = undefined;
    const len = @min(url.len, 2048);
    @memcpy(url_z[0..len], url[0..len]);
    url_z[len] = 0;
    p.load_file(@as([*c]const u8, @ptrCast(&url_z[0])));
    state.gotoPlayer();
}

/// Like `loadContentDirect`, but attaches now-playing metadata (cover art URL,
/// title, subtitle) to the player so an audio stream — a podcast episode or a
/// radio station, which have no video and would otherwise show a black pane +
/// bare URL — renders its artwork + rich text on the player pane and in the
/// bottom bar. load_file clears any prior metadata first; setNowPlaying re-sets
/// it after, so the order is clear-then-populate.
pub fn loadContentDirectMeta(url: []const u8, art_url: []const u8, title: []const u8, subtitle: []const u8) void {
    if (state.app.players.items.len == 0) {
        if (@import("../player/player.zig").MediaPlayer.init(alloc)) |np| {
            state.app.players.append(alloc, np) catch {
                np.deinit(alloc);
                return;
            };
            state.app.active_player_idx = 0;
        } else |_| return;
    }
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const p = state.app.players.items[state.app.active_player_idx];
    p.provider = .mpv;
    var url_z: [2049]u8 = undefined;
    const len = @min(url.len, 2048);
    @memcpy(url_z[0..len], url[0..len]);
    url_z[len] = 0;
    p.load_file(@as([*c]const u8, @ptrCast(&url_z[0])));
    p.setNowPlaying(art_url, title, subtitle);
    state.gotoPlayer();
}

/// Load content with automatic provider routing
pub fn loadContent(url: []const u8) void {
    const extractors = @import("extractors.zig");

    // Normalize URL
    var norm_buf: [2048]u8 = undefined;
    const norm_url = extractors.normalizeUrl(url, &norm_buf);

    const route = routeContent(norm_url);

    // Check if this is a playlist URL
    if (route == .mpv and extractors.isPlaylistUrl(norm_url)) {
        state.showToast("Extracting playlist...");
        extractors.extractPlaylist(norm_url);
        return;
    }

    // Torrents → the torrent engine, which streams into the player pane. Both a
    // magnet and a .torrent file used to fall through to the catch-all `.web`
    // route below and get handed to the in-app WEB BROWSER — a silent dead end.
    if (route == .torrent) {
        const search = @import("search.zig");
        if (std.mem.startsWith(u8, norm_url, "magnet:")) {
            search.loadTorrentToPlayer(norm_url); // handles player reveal
            return;
        }
        // A remote .torrent URL has to be fetched before libtorrent can parse it.
        // loadTorrentToPlayer is the existing HTTP entry point (it resolves the
        // link in the background), so remote torrents reuse it rather than growing
        // a second download path here.
        if (std.mem.startsWith(u8, norm_url, "http://") or std.mem.startsWith(u8, norm_url, "https://")) {
            search.loadTorrentToPlayer(norm_url);
            return;
        }
        // Local .torrent file → straight into the engine.
        search.addTorrentFileToEngine(norm_url);
        return;
    }

    // Comics open inside the Browse › Comics tab (the player route is for
    // playback only) — load + reveal that tab, no player pane involved.
    if (route == .comic_viewer) {
        @import("comics.zig").loadComic(norm_url);
        state.app.browse_source = .Comics;
        state.app.router.navigate(.browse);
        return;
    }

    // Web pages open inside the Browse › Web tab — the in-app browser is
    // fully independent of any player now. Load + reveal that tab.
    if (route == .web) {
        navigate(norm_url);
        state.app.browse_source = .Web;
        state.app.router.navigate(.browse);
        return;
    }

    // Video/audio → the MPV player pane. Create a player if none exists yet, so
    // cold-start opens work too (Continue Watching, the launch resume prompt,
    // deep links) — previously these silently no-op'd with no player present.
    if (state.app.players.items.len == 0) {
        if (@import("../player/player.zig").MediaPlayer.init(alloc)) |np| {
            state.app.players.append(alloc, np) catch np.deinit(alloc);
            if (state.app.players.items.len > 0) state.app.active_player_idx = state.app.players.items.len - 1;
        } else |_| {}
    }

    if (state.app.active_player_idx < state.app.players.items.len) {
        const p = state.app.players.items[state.app.active_player_idx];
        p.provider = .mpv;

        var url_z: [2049]u8 = undefined;
        const len = @min(norm_url.len, 2048);
        @memcpy(url_z[0..len], norm_url[0..len]);
        url_z[len] = 0;
        p.load_file(@ptrCast(&url_z[0]));

        // Reveal the player page (and close the legacy drawer) so the user
        // actually sees what they just loaded. Centralized here so search,
        // resolver, queue, drag-drop and Resume all inherit it.
        state.gotoPlayer();
    }
}

/// Resume a previously-played item in the PLAYER. Unlike `loadContent` — which
/// auto-routes by URL shape and sends magnets + extensionless stream URLs to the
/// in-app browser (route == .web) — watch-history, Continue-Watching and the
/// launch Resume prompt are *known playback*, so this forces the player: magnets
/// go through the torrent engine, comics to the reader, everything else into mpv.
pub fn resumePlayback(url: []const u8) void {
    if (std.mem.startsWith(u8, url, "magnet:")) {
        @import("search.zig").loadTorrentToPlayer(url); // handles player reveal
        return;
    }
    if (routeContent(url) == .comic_viewer) {
        @import("comics.zig").loadComic(url);
        state.app.browse_source = .Comics;
        state.app.router.navigate(.browse);
        return;
    }
    // Streams / files / video hosts → straight into mpv (never the browser).
    loadContentDirect(url);
}
