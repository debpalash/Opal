//! gallery-dl download backend — the app-flavored wrapper around the CLI.
//!
//! gallery-dl covers hundreds of image-gallery / art / booru sites yt-dlp
//! doesn't. It's spawned exactly like yt-dlp (a child process); this file owns
//! the binary resolver, the async fetch worker, and the handoff of completed
//! files into download history + toasts. All classification / argv / output
//! parsing lives in gallerydl_pure.zig so the shipped logic is the tested one.
//!
//! If no gallery-dl binary is installed the feature is inert: available()
//! returns false, enabled() returns false, and the dispatch point falls
//! through to the existing yt-dlp / HTTP path — same as any optional dep.

const std = @import("std");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const io_g = @import("../core/io_global.zig");
const pure = @import("gallerydl_pure.zig");
const history = @import("history.zig");

const alloc = @import("../core/alloc.zig").allocator;

// ══════════════════════════════════════════════════════════
// Binary resolver (mirrors ytdlp.binary())
// ══════════════════════════════════════════════════════════

const CANDIDATES = [_][]const u8{
    "/opt/homebrew/bin/gallery-dl",
    "/usr/local/bin/gallery-dl",
    "/usr/bin/gallery-dl",
    // pipx / user installs
    "/opt/homebrew/bin/gallery-dl.exe",
};

var resolved_buf: [512]u8 = undefined;
var resolved_len: usize = 0;
var resolved_done: bool = false;
var resolved_found: bool = false;

fn resolve() void {
    if (resolved_done) return;
    for (CANDIDATES) |c| {
        if (io_g.cwdAccess(c, .{})) {
            @memcpy(resolved_buf[0..c.len], c);
            resolved_len = c.len;
            resolved_found = true;
            resolved_done = true;
            return;
        } else |_| {}
    }
    // Not at a known absolute path — fall back to a bare PATH lookup, but mark
    // it "not found" so available() reports the feature inert (the GUI process
    // PATH usually lacks /opt/homebrew/bin, same caveat as yt-dlp).
    const fallback = "gallery-dl";
    @memcpy(resolved_buf[0..fallback.len], fallback);
    resolved_len = fallback.len;
    resolved_found = false;
    resolved_done = true;
}

/// The gallery-dl executable to spawn (absolute path when found, else the bare
/// name). Cached after the first call.
pub fn binary() []const u8 {
    resolve();
    return resolved_buf[0..resolved_len];
}

/// True when a gallery-dl binary was found at a known absolute path. When
/// false the feature is inert and callers fall through to the existing path.
pub fn available() bool {
    resolve();
    return resolved_found;
}

/// The dispatch gate: use gallery-dl only when the user hasn't disabled it AND
/// a binary is actually installed. Config default is ON, so the effective
/// behavior is "on when installed".
pub fn enabled() bool {
    return state.app.gallerydl_enabled and available();
}

// ══════════════════════════════════════════════════════════
// Async fetch
// ══════════════════════════════════════════════════════════

/// Kick off a gallery-dl fetch of `url` into the downloads directory on a
/// worker thread. Returns false without doing anything if gallery-dl isn't
/// available, a fetch is already running, or inputs don't fit. Never blocks
/// the UI thread. Completed files are logged + registered into download
/// history (visible in Transfers › History); a toast summarizes the count.
pub fn fetch(url: []const u8) bool {
    if (!available()) return false;
    if (url.len == 0) return false;

    const S = struct {
        var busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
        var url_buf: [2048]u8 = undefined;
        var url_len: usize = 0;
        var dest_buf: [1024]u8 = undefined;
        var dest_len: usize = 0;

        fn worker() void {
            const Z = @This();
            defer Z.busy.store(false, .release);

            const u = Z.url_buf[0..Z.url_len];
            const dest = Z.dest_buf[0..Z.dest_len];

            var argv_buf: [pure.ARGV_LEN][]const u8 = undefined;
            const argv = pure.buildArgv(binary(), dest, u, &argv_buf);

            var child = io_g.Child.init(argv, alloc);
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Pipe;
            _ = child.spawn() catch {
                logs.pushLog("error", "gallerydl", "gallery-dl failed to start", true);
                state.showToastTyped("gallery-dl failed to start", .err);
                return;
            };

            // Output (the list of downloaded paths) is small text; read it all.
            // Heap-allocated so nothing large sits on the worker stack.
            const out_cap = 1024 * 1024;
            const out_buf = alloc.alloc(u8, out_cap) catch {
                _ = child.wait() catch {};
                return;
            };
            defer alloc.free(out_buf);

            const stdout = child.stdout orelse {
                _ = child.wait() catch {};
                return;
            };
            const n = io_g.readAll(stdout, out_buf) catch 0;

            // Drain stderr so a chatty child can't deadlock on a full pipe.
            var err_buf: [4096]u8 = undefined;
            const err_n = if (child.stderr) |*se| io_g.readAll(se, &err_buf) catch 0 else 0;
            _ = child.wait() catch {};

            var downloaded: usize = 0;
            var skipped: usize = 0;
            var last_name_buf: [256]u8 = undefined;
            var last_name_len: usize = 0;

            var it = std.mem.splitScalar(u8, out_buf[0..n], '\n');
            while (it.next()) |line| {
                const parsed = pure.parseOutputLine(line);
                switch (parsed.kind) {
                    .downloaded => {
                        downloaded += 1;
                        const base = pure.baseName(parsed.path);
                        // Register into download history (Transfers › History),
                        // the same sink browser/http downloads use.
                        history.addDownloadHistory(base, u);
                        const bn = @min(base.len, last_name_buf.len);
                        @memcpy(last_name_buf[0..bn], base[0..bn]);
                        last_name_len = bn;
                    },
                    .skipped => skipped += 1,
                    .ignore => {},
                }
            }

            if (downloaded == 0 and skipped == 0) {
                if (err_n > 0) {
                    const es = err_buf[0..@min(err_n, 120)];
                    const nl = std.mem.indexOfScalar(u8, es, '\n') orelse es.len;
                    logs.pushLog("error", "gallerydl", es[0..nl], true);
                }
                state.showToastTyped("gallery-dl: nothing downloaded — check Logs", .warning);
                return;
            }

            var lb: [320]u8 = undefined;
            const lmsg = std.fmt.bufPrint(&lb, "gallery-dl: {d} downloaded, {d} already had", .{ downloaded, skipped }) catch "gallery-dl finished";
            logs.pushLog("info", "gallerydl", lmsg, false);

            var tb: [320]u8 = undefined;
            const tmsg = if (downloaded == 1 and last_name_len > 0)
                std.fmt.bufPrint(&tb, "Downloaded {s}", .{last_name_buf[0..last_name_len]}) catch "gallery-dl finished"
            else
                std.fmt.bufPrint(&tb, "gallery-dl: {d} file(s) downloaded", .{downloaded}) catch "gallery-dl finished";
            state.showToast(tmsg);
            state.wakeUi();
        }
    };

    if (S.busy.load(.acquire)) {
        state.showToast("A gallery-dl download is already running");
        return false;
    }

    if (url.len > S.url_buf.len) return false;

    // Destination = configured downloads dir, else the default.
    const paths = @import("../core/paths.zig");
    var dfl: [512]u8 = undefined;
    const dest = if (state.app.save_path_len > 0)
        state.app.save_path_buf[0..state.app.save_path_len]
    else
        paths.defaultSavePath(&dfl);
    if (dest.len == 0 or dest.len > S.dest_buf.len) return false;

    // Copy ALL inputs into the struct statics BEFORE spawning (CLAUDE.md).
    @memcpy(S.url_buf[0..url.len], url);
    S.url_len = url.len;
    @memcpy(S.dest_buf[0..dest.len], dest);
    S.dest_len = dest.len;

    S.busy.store(true, .release);
    if (std.Thread.spawn(.{}, S.worker, .{})) |t| {
        t.detach();
    } else |_| {
        S.busy.store(false, .release);
        logs.pushLog("error", "gallerydl", "Could not start gallery-dl thread", true);
        return false;
    }

    var tb: [300]u8 = undefined;
    if (std.fmt.bufPrint(&tb, "Fetching gallery with gallery-dl…", .{})) |m| {
        state.showToast(m);
    } else |_| {}
    return true;
}
