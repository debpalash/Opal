const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const logs = @import("../core/logs.zig");
const player = @import("../player/player.zig");
const paths = @import("../core/paths.zig");
const sync = @import("../core/sync.zig");

// ══════════════════════════════════════════════════════════
// Opal Plugin System
//
// Plugins are external, user-installed modules that provide
// content sources. The core app ships clean with no
// scraping/piracy code. Plugins are language-agnostic 
// executables that communicate via JSON over stdin/stdout.
//
// Plugin directory: ~/.config/opal/plugins/<name>/
// Each plugin has:
//   manifest.json — metadata + capabilities
//   search        — executable: search <query> → JSON results
//   resolve       — executable: resolve <id> <ep> → JSON stream URLs
//   trending      — executable: trending → JSON results (optional)
// ══════════════════════════════════════════════════════════

const c_alloc = std.heap.c_allocator;

pub const MAX_PLUGINS = 64;
pub const MAX_RESULTS = 32;

// ── Plugin Result Item ──
pub const PluginResult = struct {
    id: [128]u8 = std.mem.zeroes([128]u8),
    id_len: usize = 0,
    title: [128]u8 = std.mem.zeroes([128]u8),
    title_len: usize = 0,
    overview: [512]u8 = std.mem.zeroes([512]u8),
    overview_len: usize = 0,
    poster_url: [256]u8 = std.mem.zeroes([256]u8),
    poster_url_len: usize = 0,
    stream_url: [512]u8 = std.mem.zeroes([512]u8),
    stream_url_len: usize = 0,
    episodes: u16 = 0,
    score: f32 = 0.0,
    year: [8]u8 = std.mem.zeroes([8]u8),
    year_len: usize = 0,
    media_type: [16]u8 = std.mem.zeroes([16]u8),
    media_type_len: usize = 0,
    // Poster state
    poster_fetching: bool = false,
    poster_pixels: ?[]u8 = null,
    poster_w: u32 = 0,
    poster_h: u32 = 0,
    poster_tex: ?dvui.Texture = null,
    expanded: bool = false,
};

// ── Plugin Manifest ──
pub const Plugin = struct {
    name: [64]u8 = std.mem.zeroes([64]u8),
    name_len: usize = 0,
    version: [16]u8 = std.mem.zeroes([16]u8),
    version_len: usize = 0,
    description: [256]u8 = std.mem.zeroes([256]u8),
    description_len: usize = 0,
    author: [64]u8 = std.mem.zeroes([64]u8),
    author_len: usize = 0,
    // Plugin directory path
    path: [512]u8 = std.mem.zeroes([512]u8),
    path_len: usize = 0,
    // Capabilities
    has_search: bool = false,
    has_resolve: bool = false,
    has_trending: bool = false,
    // State
    enabled: bool = true,
    loaded: bool = false,
    allow_unsafe: bool = false,
    // User-created trust marker (`<plugin_dir>/.trusted`). `allow_unsafe` is only
    // honored when this is also set — the plugin can't forge it. See
    // plugins_pure.runMode.
    user_trusted: bool = false,
};

// ── Global Plugin State ──
pub var plugins: [MAX_PLUGINS]Plugin = std.mem.zeroes([MAX_PLUGINS]Plugin);
pub var plugin_count: usize = 0;
pub var active_plugin: usize = 0;
pub var scanned: bool = false;

// Per-plugin results.
//
// `results`/`result_count`/`is_loading` are read by the UI thread every
// frame and written by background plugin workers. All access goes through
// `results_mutex`. `is_loading` doubles as a spawn gate: it is set to true
// under the lock only if it was previously false (compare-and-set), so two
// rapid clicks cannot launch two workers racing on the same buffers.
pub var results: [MAX_RESULTS]PluginResult = std.mem.zeroes([MAX_RESULTS]PluginResult);
pub var result_count: usize = 0;
pub var is_loading: bool = false;
pub var results_mutex = sync.Mutex{};
pub var search_buf: [256]u8 = std.mem.zeroes([256]u8);

/// Atomically claim the loading slot. Returns true if the caller now owns
/// it (was idle), false if a worker is already running. Caller must release
/// via `endLoading()` when done.
fn beginLoading() bool {
    results_mutex.lock();
    defer results_mutex.unlock();
    if (is_loading) return false;
    is_loading = true;
    result_count = 0;
    return true;
}

fn endLoading() void {
    results_mutex.lock();
    defer results_mutex.unlock();
    is_loading = false;
}

// ══════════════════════════════════════════════════════════
// Plugin Discovery
// ══════════════════════════════════════════════════════════

pub fn getPluginDir(buf: *[512]u8) []const u8 {
    if (@import("../core/io_global.zig").getenv("HOME")) |home| {
        return std.fmt.bufPrint(buf, "{s}/.config/opal/plugins", .{home}) catch "";
    }
    return "";
}

pub fn scanPlugins() void {
    plugin_count = 0;
    
    var dir_buf: [512]u8 = undefined;
    const plugin_dir = getPluginDir(&dir_buf);
    if (plugin_dir.len == 0) return;
    
    // Ensure plugin directory exists
    @import("../core/io_global.zig").cwdMakePath(plugin_dir) catch {};
    
    var dir = @import("../core/io_global.zig").cwdOpenDir(plugin_dir, .{ .iterate = true }) catch return;
    defer dir.close(@import("../core/io_global.zig").io());
    
    var it = dir.iterate();
    while (it.next(@import("../core/io_global.zig").io()) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (plugin_count >= MAX_PLUGINS) break;
        
        // Check for manifest.json
        var manifest_path: [600]u8 = undefined;
        const mp = std.fmt.bufPrint(&manifest_path, "{s}/{s}/manifest.json", .{plugin_dir, entry.name}) catch continue;
        
        const file = @import("../core/io_global.zig").cwdOpenFile(mp, .{}) catch continue;
        defer file.close(@import("../core/io_global.zig").io());
        
        var manifest_buf: [4096]u8 = undefined;
        const manifest_len = @import("../core/io_global.zig").readAll(file, &manifest_buf) catch continue;
        if (manifest_len < 5) continue;
        const json = manifest_buf[0..manifest_len];
        
        var p = &plugins[plugin_count];
        p.* = std.mem.zeroes(Plugin);
        
        // Parse manifest fields
        extractJsonString(json, "name", &p.name, &p.name_len);
        extractJsonString(json, "version", &p.version, &p.version_len);
        extractJsonString(json, "description", &p.description, &p.description_len);
        extractJsonString(json, "author", &p.author, &p.author_len);
        if (extractField(json, "allow_unsafe")) |v| {
            p.allow_unsafe = std.mem.eql(u8, v, "true");
        }
        
        if (p.name_len == 0) {
            // Use directory name as fallback
            const nl = @min(entry.name.len, 64);
            @memcpy(p.name[0..nl], entry.name[0..nl]);
            p.name_len = nl;
        }
        
        // Store path
        var full_path: [512]u8 = undefined;
        const fp = std.fmt.bufPrint(&full_path, "{s}/{s}", .{plugin_dir, entry.name}) catch continue;
        const fpl = @min(fp.len, 512);
        @memcpy(p.path[0..fpl], fp[0..fpl]);
        p.path_len = fpl;
        
        // Check which executables exist
        p.has_search = fileExists(p.path[0..p.path_len], "search");
        p.has_resolve = fileExists(p.path[0..p.path_len], "resolve");
        p.has_trending = fileExists(p.path[0..p.path_len], "trending");

        // User trust marker: allow_unsafe (and unsandboxed native execution) is
        // only honored when the user has created `<plugin_dir>/.trusted`.
        p.user_trusted = fileExists(p.path[0..p.path_len], ".trusted");
        
        p.enabled = true;
        p.loaded = true;
        
        plugin_count += 1;
        
        var log_buf: [128]u8 = undefined;
        const lm = std.fmt.bufPrintZ(&log_buf, "Plugin loaded: {s}", .{p.name[0..p.name_len]}) catch "Plugin loaded";
        logs.pushLog("info", "plugin", lm, false);
    }
    
    scanned = true;
}

fn fileExists(dir: []const u8, name: []const u8) bool {
    var path_buf: [600]u8 = undefined;
    const p = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{dir, name}) catch return false;
    const f = @import("../core/io_global.zig").cwdOpenFile(p, .{}) catch return false;
    f.close(@import("../core/io_global.zig").io());
    return true;
}

// ══════════════════════════════════════════════════════════
// Plugin Execution
// ══════════════════════════════════════════════════════════

// Lua sandbox prelude — nils dangerous globals before the plugin
// chunk runs. Plugins are community-supplied; without this, a
// malicious "media search" plugin can `os.execute("rm -rf $HOME")`.
//
// Defense-in-depth only: a sandboxed Lua plugin can still consume
// CPU/memory and the OS-level uid is unchanged. Real isolation
// needs a per-spawn OS sandbox (macOS sandbox-exec / Linux
// bubblewrap) — see TODO below.
//
// `require` is replaced with a deny-all hook (empty allow-list by
// default; manifest opt-in for specific modules in a later pass).
//
// NOTE: this only fires when the plugin executable is interpreted
// by `lua` (detected via `.lua` suffix or a `lua` shebang). Native
// binaries and non-Lua interpreters bypass this and need OS sandbox
// hardening instead.
//
// TODO(security): per-spawn OS sandboxing (macOS `sandbox-exec -p`
// / Linux `bwrap`), manifest `require` allow-list, and a one-time
// user consent prompt for `allow_unsafe = true` plugins.
const LUA_SANDBOX_PRELUDE: []const u8 =
    \\os.execute=nil os.remove=nil os.rename=nil os.exit=nil os.tmpname=nil os.getenv=nil
    \\io.popen=nil io.open=nil io.input=nil io.output=nil io.lines=nil
    \\if package then package.loadlib=nil package.path="" package.cpath="" package.preload={} end
    \\debug=nil
    \\dofile=nil loadfile=nil loadstring=nil load=nil
    \\require=function(m) error("require denied: "..tostring(m)) end
    \\
;

/// Detect whether `exec_path` points at a Lua script (by `.lua`
/// suffix or a shebang line containing `lua`). Used to decide
/// whether the sandbox prelude needs to wrap the invocation.
fn detectLuaScript(exec_path: []const u8) bool {
    if (std.mem.endsWith(u8, exec_path, ".lua")) return true;
    const f = @import("../core/io_global.zig").cwdOpenFile(exec_path, .{}) catch return false;
    defer f.close(@import("../core/io_global.zig").io());
    var hdr: [128]u8 = undefined;
    const n = @import("../core/io_global.zig").readAll(f, &hdr) catch return false;
    if (n < 4) return false;
    if (hdr[0] != '#' or hdr[1] != '!') return false;
    const line_end = std.mem.indexOfScalar(u8, hdr[0..n], '\n') orelse n;
    return std.mem.indexOf(u8, hdr[0..line_end], "lua") != null;
}

/// Build an argv that runs `exec_path` under the sandboxed Lua VM:
/// `lua -e <PRELUDE> -- <script> <extras...>`. Caller-supplied
/// `out_argv` must have at least `4 + extras.len` slots.
fn buildSandboxedLuaArgv(
    out_argv: [][]const u8,
    exec_path: []const u8,
    extras: []const []const u8,
) []const []const u8 {
    out_argv[0] = "lua";
    out_argv[1] = "-e";
    out_argv[2] = LUA_SANDBOX_PRELUDE;
    out_argv[3] = exec_path;
    for (extras, 0..) |a, i| out_argv[4 + i] = a;
    return out_argv[0 .. 4 + extras.len];
}

fn logSandboxed(name: []const u8) void {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, "Sandboxed: {s}", .{name}) catch "Sandboxed";
    logs.pushLog("info", "plugins", msg, false);
}

fn logUnsafeWarn(name: []const u8) void {
    var buf: [160]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, "Lua sandbox skipped (allow_unsafe + user-trusted): {s}", .{name}) catch "Lua sandbox skipped";
    logs.pushLog("warn", "plugins", msg, false);
}

fn logUntrustedNative(name: []const u8) void {
    var buf: [200]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, "Running UNSANDBOXED native plugin (no .trusted marker): {s}", .{name}) catch "Unsandboxed native plugin";
    logs.pushLog("warn", "plugins", msg, true);
}

/// Surface a plugin/child-process spawn failure (e.g. missing `lua` or
/// `curl`, or a non-executable plugin script) instead of swallowing it.
fn logSpawnFail(argv0: []const u8) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, "spawn failed: {s} not found or not executable", .{argv0}) catch "plugin spawn failed";
    logs.pushLog("error", "plugin", msg, true);
}

pub fn runPluginSearch(query: []const u8) void {
    if (active_plugin >= plugin_count) return;
    if (!plugins[active_plugin].has_search) return;
    if (!beginLoading()) return;

    // Copy the query into a fixed buffer passed *by value* to the worker —
    // the caller's `query` aliases the live `search_buf`, which keeps
    // mutating as the user types.
    var q_buf: [256]u8 = std.mem.zeroes([256]u8);
    const qlen = @min(query.len, q_buf.len);
    @memcpy(q_buf[0..qlen], query[0..qlen]);

    if (std.Thread.spawn(.{}, struct {
        fn worker(q_owned: [256]u8, q_len: usize, pidx: usize) void {
            defer endLoading();
            const q = q_owned[0..q_len];

            const p = plugins[pidx];
            var exec_buf: [600]u8 = undefined;
            const exec = std.fmt.bufPrint(&exec_buf, "{s}/search", .{p.path[0..p.path_len]}) catch return;

            const pp = @import("plugins_pure.zig");
            const is_lua = detectLuaScript(exec);
            switch (pp.runMode(is_lua, p.allow_unsafe, p.user_trusted)) {
                .sandbox_lua => {
                    var sandbox_argv: [8][]const u8 = undefined;
                    const extras = [_][]const u8{q};
                    const argv = buildSandboxedLuaArgv(&sandbox_argv, exec, &extras);
                    logSandboxed(p.name[0..p.name_len]);
                    executeAndParse(argv);
                },
                .direct => {
                    if (p.allow_unsafe and p.user_trusted) logUnsafeWarn(p.name[0..p.name_len]);
                    if (pp.untrustedNative(is_lua, p.user_trusted)) logUntrustedNative(p.name[0..p.name_len]);
                    const argv = [_][]const u8{ exec, q };
                    executeAndParse(&argv);
                },
            }
        }
    }.worker, .{ q_buf, qlen, active_plugin })) |t| t.detach() else |_| {
        endLoading();
    }
}

pub fn runPluginTrending() void {
    if (active_plugin >= plugin_count) return;
    if (!plugins[active_plugin].has_trending) return;
    if (!beginLoading()) return;

    if (std.Thread.spawn(.{}, struct {
        fn worker(pidx: usize) void {
            defer endLoading();

            const p = plugins[pidx];
            var exec_buf: [600]u8 = undefined;
            const exec = std.fmt.bufPrint(&exec_buf, "{s}/trending", .{p.path[0..p.path_len]}) catch return;

            const pp = @import("plugins_pure.zig");
            const is_lua = detectLuaScript(exec);
            switch (pp.runMode(is_lua, p.allow_unsafe, p.user_trusted)) {
                .sandbox_lua => {
                    var sandbox_argv: [8][]const u8 = undefined;
                    const argv = buildSandboxedLuaArgv(&sandbox_argv, exec, &.{});
                    logSandboxed(p.name[0..p.name_len]);
                    executeAndParse(argv);
                },
                .direct => {
                    if (p.allow_unsafe and p.user_trusted) logUnsafeWarn(p.name[0..p.name_len]);
                    if (pp.untrustedNative(is_lua, p.user_trusted)) logUntrustedNative(p.name[0..p.name_len]);
                    const argv = [_][]const u8{exec};
                    executeAndParse(&argv);
                },
            }
        }
    }.worker, .{active_plugin})) |t| t.detach() else |_| {
        endLoading();
    }
}

pub fn runPluginResolve(id: []const u8, episode: []const u8) void {
    if (active_plugin >= plugin_count) return;
    if (!plugins[active_plugin].has_resolve) return;
    
    // ── Instant feedback: show loading on player immediately ──
    if (state.app.players.items.len > 0 and state.app.active_player_idx < state.app.players.items.len) {
        const pl = state.app.players.items[state.app.active_player_idx];
        pl.is_loading = true;
        pl.provider = .mpv; // Switch to player view
        // Show which episode we're resolving
        var lbl_buf: [64]u8 = undefined;
        const lbl = std.fmt.bufPrint(&lbl_buf, "Resolving Ep {s}...", .{episode}) catch "Resolving...";
        @memcpy(pl.loading_label[0..lbl.len], lbl);
        pl.loading_label_len = lbl.len;
    }
    
    // Copy id/episode into fixed buffers passed *by value* — the caller's
    // slices alias `results[*]` (a live, worker-mutated array) and a stack
    // temporary that is gone the moment this function returns.
    var id_buf: [128]u8 = std.mem.zeroes([128]u8);
    const id_len = @min(id.len, id_buf.len);
    @memcpy(id_buf[0..id_len], id[0..id_len]);
    var ep_buf: [32]u8 = std.mem.zeroes([32]u8);
    const ep_len = @min(episode.len, ep_buf.len);
    @memcpy(ep_buf[0..ep_len], episode[0..ep_len]);

    if (std.Thread.spawn(.{}, struct {
        fn worker(rid_buf: [128]u8, rid_len: usize, rep_buf: [32]u8, rep_len: usize, pidx: usize) void {
            const rid = rid_buf[0..rid_len];
            const rep = rep_buf[0..rep_len];
            const p = plugins[pidx];
            var exec_buf: [600]u8 = undefined;
            const exec = std.fmt.bufPrint(&exec_buf, "{s}/resolve", .{p.path[0..p.path_len]}) catch return;

            const pp = @import("plugins_pure.zig");
            const is_lua = detectLuaScript(exec);
            const direct_argv = [_][]const u8{ exec, rid, rep };
            var sandbox_argv: [8][]const u8 = undefined;
            const argv: []const []const u8 = blk: {
                switch (pp.runMode(is_lua, p.allow_unsafe, p.user_trusted)) {
                    .sandbox_lua => {
                        const extras = [_][]const u8{ rid, rep };
                        logSandboxed(p.name[0..p.name_len]);
                        break :blk buildSandboxedLuaArgv(&sandbox_argv, exec, &extras);
                    },
                    .direct => {
                        if (p.allow_unsafe and p.user_trusted) logUnsafeWarn(p.name[0..p.name_len]);
                        if (pp.untrustedNative(is_lua, p.user_trusted)) logUntrustedNative(p.name[0..p.name_len]);
                        break :blk &direct_argv;
                    },
                }
            };
            var child = @import("../core/io_global.zig").Child.init(argv, c_alloc);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Ignore;
            _ = child.spawn() catch {
                logSpawnFail(argv[0]);
                return;
            };

            var buf: [8192]u8 = undefined;
            const len = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, &buf) catch 0 else 0;
            _ = child.wait() catch {};
            
            if (len < 5) {
                logs.pushLog("error", "plugin", "Resolve returned no data", false);
                return;
            }
            
            const json = buf[0..len];
            
            // Check if this is a manga response (images, not video)
            const is_manga = extractField(json, "type") != null and
                std.mem.eql(u8, extractField(json, "type").?, "manga");
            
            if (is_manga) {
                // ── Manga: parse images array → comic viewer ──
                const comics = @import("comics.zig");
                _ = comics;
                
                // Set title
                if (extractField(json, "title")) |title| {
                    const tlen = @min(title.len, 255);
                    @memcpy(state.app.comic.title[0..tlen], title[0..tlen]);
                    state.app.comic.title_len = tlen;
                }

                // Optional per-plugin Referer for page fetches (some manga CDNs
                // 403 without it). Empty → workers derive it from the image
                // origin. See plugins_pure.refererHeader.
                state.app.comic.referer_len = 0;
                if (extractField(json, "referer")) |ref| {
                    const rlen = @min(ref.len, state.app.comic.referer.len);
                    @memcpy(state.app.comic.referer[0..rlen], ref[0..rlen]);
                    state.app.comic.referer_len = rlen;
                }
                
                // Parse images array
                var img_count: usize = 0;
                if (std.mem.indexOf(u8, json, "\"images\"")) |img_start| {
                    // Find the opening bracket
                    if (std.mem.indexOfScalar(u8, json[img_start..], '[')) |bracket| {
                        var pos = img_start + bracket + 1;
                        while (pos < json.len and img_count < 128) {
                            // Find next quoted string
                            const q1 = std.mem.indexOfScalar(u8, json[pos..], '"') orelse break;
                            const abs_q1 = pos + q1 + 1;
                            if (abs_q1 >= json.len) break;
                            const q2 = std.mem.indexOfScalar(u8, json[abs_q1..], '"') orelse break;
                            const img_url = json[abs_q1 .. abs_q1 + q2];
                            
                            if (img_url.len > 10 and img_url.len < 512) {
                                @memcpy(state.app.comic.page_urls[img_count][0..img_url.len], img_url);
                                state.app.comic.page_url_lens[img_count] = img_url.len;
                                img_count += 1;
                            }
                            
                            pos = abs_q1 + q2 + 1;
                            if (pos < json.len and json[pos] == ']') break;
                        }
                    }
                }
                
                if (img_count > 0) {
                    // Clear old pages. This runs on a detached worker thread, so:
                    //  - GPU textures must be destroyed on the UI thread → queue them
                    //    (dvui.textureDestroyLater is UI-only; nulling here leaked them).
                    //  - page_pixels were allocated with the GLOBAL allocator
                    //    (comics.zig alloc.dupe), NOT c_allocator — free with the same
                    //    one or it's heap corruption.
                    const comics_mod = @import("comics.zig");
                    const page_free_alloc = @import("../core/alloc.zig").allocator;
                    for (0..128) |i| {
                        if (state.app.comic.page_textures[i]) |tex| {
                            comics_mod.queuePageTexFree(tex);
                            state.app.comic.page_textures[i] = null;
                        }
                        if (state.app.comic.page_pixels[i]) |px| {
                            page_free_alloc.free(px);
                            state.app.comic.page_pixels[i] = null;
                        }
                    }
                    
                    state.app.comic.page_count = img_count;
                    state.app.comic.current_page = 0;
                    state.app.comic.dl_progress.store(0, .release);
                    state.app.comic.is_loading.store(false, .release);
                    state.app.comic.next_url_len = 0;
                    state.app.comic.prev_url_len = 0;
                    
                    // Switch to comic viewer
                    if (state.app.active_player_idx < state.app.players.items.len) {
                        const pl2 = state.app.players.items[state.app.active_player_idx];
                        pl2.provider = .comic_viewer;
                        pl2.is_loading = false;
                    }
                    
                    logs.pushLog("info", "plugin", "Manga loaded — opening reader", false);
                    
                    // Start downloading pages in background
                    if (std.Thread.spawn(.{}, struct {
                        fn dl() void {
                            // Download pages in parallel batches of 8
                            const BATCH = 8;
                            var threads: [BATCH]?std.Thread = [_]?std.Thread{null} ** BATCH;
                            var page_i: usize = 0;
                            const page_alloc = @import("../core/alloc.zig").allocator;
                            
                            while (page_i < state.app.comic.page_count) {
                                var active: usize = 0;
                                while (active < BATCH and page_i < state.app.comic.page_count) {
                                    if (state.app.comic.page_pixels[page_i] != null or
                                        state.app.comic.page_url_lens[page_i] == 0) {
                                        page_i += 1;
                                        continue;
                                    }
                                    const pi = page_i;
                                    threads[active] = std.Thread.spawn(.{}, struct {
                                        fn fetch(idx: usize) void {
                                            const u = state.app.comic.page_urls[idx][0..state.app.comic.page_url_lens[idx]];
                                            if (u.len == 0) return;
                                            const a = @import("../core/alloc.zig").allocator;
                                            // Referer: plugin-supplied if any, else this image's own
                                            // origin (replaces a hardcoded coffeemanga.io referer).
                                            const plugin_ref = state.app.comic.referer[0..state.app.comic.referer_len];
                                            var ref_buf: [600]u8 = undefined;
                                            const ref_hdr = @import("plugins_pure.zig").refererHeader(plugin_ref, u, &ref_buf) orelse "Referer:";
                                            const argv2 = [_][]const u8{
                                                "curl", "-sL",
                                                "-H", "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",
                                                "-H", ref_hdr,
                                                "--max-time", "15",
                                                u,
                                            };
                                            var child2 = @import("../core/io_global.zig").Child.init(&argv2, a);
                                            child2.stdout_behavior = .Pipe;
                                            child2.stderr_behavior = .Ignore;
                                            _ = child2.spawn() catch {
                                                logSpawnFail(argv2[0]);
                                                return;
                                            };
                                            const max_img = 5 * 1024 * 1024;
                                            const tmp = a.alloc(u8, max_img) catch return;
                                            defer a.free(tmp);
                                            var total: usize = 0;
                                            if (child2.stdout) |*so| {
                                                while (total < max_img) {
                                                    const n = @import("../core/io_global.zig").read(so, tmp[total..]) catch break;
                                                    if (n == 0) break;
                                                    total += n;
                                                }
                                            }
                                            _ = child2.wait() catch {};
                                            if (total > 100) {
                                                const px = a.dupe(u8, tmp[0..total]) catch return;
                                                state.app.comic.page_pixels[idx] = px;
                                                _ = state.app.comic.dl_progress.fetchAdd(1, .acq_rel);
                                            }
                                        }
                                    }.fetch, .{pi}) catch null;
                                    active += 1;
                                    page_i += 1;
                                }
                                for (0..active) |t| {
                                    if (threads[t]) |th| th.join();
                                    threads[t] = null;
                                }
                            }
                            _ = page_alloc;
                        }
                    }.dl, .{})) |t| t.detach() else |_| {}
                } else {
                    logs.pushLog("error", "plugin", "Manga: no images found", false);
                }
            } else if (extractField(json, "url")) |url| {
                // ── Video/stream: original handler ──
                if (url.len < 5) return;
                
                const c = @import("../core/c.zig");
                if (state.app.players.items.len == 0 or state.app.active_player_idx >= state.app.players.items.len) return;
                
                // Check if it's a magnet link → torrent engine
                if (std.mem.startsWith(u8, url, "magnet:?")) {
                    if (state.app.torrent_ses == null) {
                        logs.pushLog("error", "plugin", "Torrent engine not ready", false);
                        return;
                    }
                    var null_term: [4096]u8 = undefined;
                    @memset(&null_term, 0);
                    const clen = @min(url.len, 4095);
                    @memcpy(null_term[0..clen], url[0..clen]);
                    
                    const tid = c.mpv.torrent_add_magnet(state.app.torrent_ses, @ptrCast(&null_term[0]), state.getSavePath());
                    if (tid >= 0) {
                        const pl = state.app.players.items[state.app.active_player_idx];
                        pl.current_torrent_id = tid;
                        pl.torrent_is_ready = false;
                        pl.has_metadata = false;
                        pl.last_load_time = 0;
                        pl.selected_file_idx = -1;
                        pl.metadata_start_time = @import("../core/io_global.zig").timestamp();
                        pl.is_loading = true;
                        pl.is_torrent = true;
                        const lbl = "Plugin torrent";
                        @memcpy(pl.loading_label[0..lbl.len], lbl);
                        pl.loading_label_len = lbl.len;
                        // Store URL
                        const ulen = @min(url.len, 2048);
                        @memcpy(pl.source_url[0..ulen], url[0..ulen]);
                        pl.source_url_len = ulen;
                        @memcpy(pl.current_url[0..ulen], url[0..ulen]);
                        pl.current_url_len = ulen;
                        logs.pushLog("info", "plugin", "Torrent magnet added", false);
                    } else {
                        logs.pushLog("error", "plugin", "Failed to add magnet", false);
                        state.showToast("Couldn't add torrent (invalid or duplicate magnet)");
                    }
                } else {
                    // Regular URL → mpv loadfile
                    // Reject URLs containing quotes to prevent mpv command injection
                    if (std.mem.indexOfScalar(u8, url, '"') != null) return;
                    const pl = state.app.players.items[state.app.active_player_idx];
                    var cmd_buf2: [600]u8 = undefined;
                    const cmd = std.fmt.bufPrintZ(&cmd_buf2, "loadfile \"{s}\"", .{url}) catch return;
                    _ = c.mpv.mpv_command_string(pl.mpv_ctx, cmd.ptr);
                    logs.pushLog("info", "plugin", "Playing resolved stream", false);
                }
            } else {
                logs.pushLog("error", "plugin", "Resolve: no URL in response", false);
            }
        }
    }.worker, .{ id_buf, id_len, ep_buf, ep_len, active_plugin })) |t| t.detach() else |_| {}
}

fn executeAndParse(argv: []const []const u8) void {
    var child = @import("../core/io_global.zig").Child.init(argv, c_alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch {
        if (argv.len > 0) logSpawnFail(argv[0]);
        return;
    };
    
    var buf: [64 * 1024]u8 = undefined;
    const len = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, &buf) catch 0 else 0;
    _ = child.wait() catch {};
    
    if (len < 5) return;
    const json = buf[0..len];

    // Parse JSON array of results
    // Expected format: [{"id":"..","title":"..","overview":"..","poster":"..","episodes":N,"score":F},...]
    // Hold results_mutex across the parse so the UI thread never observes a
    // half-written `results`/`result_count` pair.
    results_mutex.lock();
    defer results_mutex.unlock();
    var pos: usize = 0;
    result_count = 0;

    while (pos < json.len and result_count < MAX_RESULTS) {
        // Find next object boundary
        const obj_start = std.mem.indexOfScalarPos(u8, json, pos, '{') orelse break;
        
        // Find matching closing brace (simple: count depth)
        var depth: usize = 0;
        var obj_end: usize = obj_start;
        var in_str = false;
        var esc = false;
        while (obj_end < json.len) : (obj_end += 1) {
            if (esc) { esc = false; continue; }
            if (json[obj_end] == '\\') { esc = true; continue; }
            if (json[obj_end] == '"') { in_str = !in_str; continue; }
            if (in_str) continue;
            if (json[obj_end] == '{') depth += 1;
            if (json[obj_end] == '}') {
                depth -= 1;
                if (depth == 0) { obj_end += 1; break; }
            }
        }
        
        if (depth != 0) break;
        const obj = json[obj_start..obj_end];
        
        var r = &results[result_count];
        r.* = std.mem.zeroes(PluginResult);
        
        extractJsonString(obj, "id", &r.id, &r.id_len);
        extractJsonString(obj, "title", &r.title, &r.title_len);
        extractJsonString(obj, "overview", &r.overview, &r.overview_len);
        extractJsonString(obj, "poster", &r.poster_url, &r.poster_url_len);
        extractJsonString(obj, "stream_url", &r.stream_url, &r.stream_url_len);
        extractJsonString(obj, "year", &r.year, &r.year_len);
        extractJsonString(obj, "type", &r.media_type, &r.media_type_len);
        
        // Extract numeric fields
        if (extractField(obj, "episodes")) |eps_s| {
            r.episodes = std.fmt.parseInt(u16, eps_s, 10) catch 0;
        }
        if (extractField(obj, "score")) |sc_s| {
            r.score = std.fmt.parseFloat(f32, sc_s) catch 0;
        }
        
        if (r.title_len > 0 or r.id_len > 0) {
            result_count += 1;
        }
        
        pos = obj_end;
    }
}

// ══════════════════════════════════════════════════════════
// JSON Helpers
// ══════════════════════════════════════════════════════════

fn extractField(json: []const u8, key: []const u8) ?[]const u8 {
    // Search for "key": or "key":
    var key_buf: [64]u8 = undefined;
    const search_key = std.fmt.bufPrint(&key_buf, "\"{s}\":", .{key}) catch return null;
    
    const idx = std.mem.indexOf(u8, json, search_key) orelse return null;
    var start = idx + search_key.len;
    
    // Skip whitespace
    while (start < json.len and (json[start] == ' ' or json[start] == '\t')) start += 1;
    if (start >= json.len) return null;
    
    if (json[start] == '"') {
        // String value
        start += 1;
        var end = start;
        var esc = false;
        while (end < json.len) : (end += 1) {
            if (esc) { esc = false; continue; }
            if (json[end] == '\\') { esc = true; continue; }
            if (json[end] == '"') break;
        }
        return json[start..end];
    } else {
        // Numeric or boolean value
        var end = start;
        while (end < json.len and json[end] != ',' and json[end] != '}' and json[end] != ']' and json[end] != ' ') : (end += 1) {}
        return json[start..end];
    }
}

fn extractJsonString(json: []const u8, key: []const u8, out_buf: []u8, out_len: *usize) void {
    if (extractField(json, key)) |val| {
        const copy_len = @min(val.len, out_buf.len);
        @memcpy(out_buf[0..copy_len], val[0..copy_len]);
        out_len.* = copy_len;
    }
}

// ══════════════════════════════════════════════════════════
// Poster Fetching (shared with anime/tmdb pattern)
// ══════════════════════════════════════════════════════════

pub fn fetchPoster(item: *PluginResult) void {
    if (item.poster_url_len == 0 or item.poster_fetching) return;
    // Global poster-fetch cap (shared with all providers) — over the cap, leave
    // poster_fetching false so the card retries next frame.
    if (!@import("../core/poster.zig").tryClaimSlot()) return;
    item.poster_fetching = true;

    if (std.Thread.spawn(.{}, struct {
        fn worker(ptr: *PluginResult) void {
            defer ptr.poster_fetching = false;
            defer @import("../core/poster.zig").releaseSlot();
            const url = ptr.poster_url[0..ptr.poster_url_len];
            
            const argv = [_][]const u8{ "curl", "-sL", "--max-time", "10", url };
            var child = @import("../core/io_global.zig").Child.init(&argv, c_alloc);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Ignore;
            _ = child.spawn() catch {
                logSpawnFail(argv[0]);
                return;
            };

            const img_buf = c_alloc.alloc(u8, 512 * 1024) catch return;
            defer c_alloc.free(img_buf);
            const img_len = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, img_buf) catch 0 else 0;
            _ = child.wait() catch {};
            if (img_len < 100) return;
            
            var w: c_int = 0;
            var h: c_int = 0;
            var comp: c_int = 0;
            const pixels = dvui.c.stbi_load_from_memory(img_buf[0..img_len].ptr, @intCast(img_len), &w, &h, &comp, 4);
            if (pixels == null) return;
            defer dvui.c.stbi_image_free(pixels);
            
            if (w <= 0 or h <= 0) return;
            // usize-first: w*h*4 in c_int overflows on a large crafted image and
            // panics this worker thread (whole-app abort).
            const p_len: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
            const p_slice = c_alloc.alloc(u8, p_len) catch return;
            @memcpy(p_slice, pixels[0..p_len]);
            
            results_mutex.lock();
            ptr.poster_w = @intCast(w);
            ptr.poster_h = @intCast(h);
            ptr.poster_pixels = p_slice;
            results_mutex.unlock();
        }
    }.worker, .{item})) |t| t.detach() else |_| {
        item.poster_fetching = false;
        @import("../core/poster.zig").releaseSlot(); // spawn failed — release the slot
    }
}

// ══════════════════════════════════════════════════════════
// UI Rendering
// ══════════════════════════════════════════════════════════

/// Source-endpoint plugins (opal-plugins repo): supply URLs/creds for Opal's
/// built-in connectors. Rendered at the top of the Plugins page.
// ── shared card primitives ──────────────────────────────────────────────────
fn cardBegin(src: std.builtin.SourceLocation, id: usize) *dvui.BoxWidget {
    const card = dvui.box(src, .{ .dir = .vertical }, .{
        .id_extra = id,
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .corner_radius = dvui.Rect.all(theme.radius.lg),
        .padding = dvui.Rect.all(theme.spacing.md),
        .margin = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
    });
    return card;
}

fn cardTitle(src: std.builtin.SourceLocation, text: []const u8, sub: []const u8) void {
    _ = dvui.label(src, "{s}", .{text}, .{ .color_text = theme.colors.text_main, .font = dvui.themeGet().font_title });
    if (sub.len > 0) {
        _ = dvui.label(@src(), "{s}", .{sub}, .{ .color_text = theme.colors.text_dim, .expand = .horizontal, .margin = .{ .x = 0, .y = 2, .w = 0, .h = 6 } });
    }
}

fn renderSourcePlugins() void {
    const pr = @import("plugin_repo.zig");

    // Auto-load on first view: show the bundled manifest instantly (offline, no
    // network) so the list is never empty, then kick a network refresh that
    // overwrites it with the live repo list when reachable. On a failed refresh
    // the bundled list stays (refreshWorker leaves plugin_count untouched on
    // error), so the page degrades gracefully with no connectivity.
    const Auto = struct {
        var done: bool = false;
    };
    if (!Auto.done) {
        Auto.done = true;
        pr.loadLocalManifest();
        pr.refresh();
    }

    var card = cardBegin(@src(), 0);
    defer card.deinit();

    // Header row: title + a small Refresh.
    {
        var hrow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hrow.deinit();
        _ = dvui.label(@src(), "Available plugins", .{}, .{ .color_text = theme.colors.text_main, .font = dvui.themeGet().font_title, .gravity_y = 0.5 });
        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }
        if (dvui.button(@src(), "Refresh", .{}, .{ .color_fill = theme.colors.bg_glass, .color_text = theme.colors.text_muted, .corner_radius = theme.dims.rad_sm, .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 }, .gravity_y = 0.5 })) {
            pr.plugin_count = 0;
            pr.refresh();
        }
    }
    _ = dvui.label(@src(), "Click Install to enable a source. Only install sources you trust.", .{}, .{ .color_text = theme.colors.text_dim, .expand = .horizontal, .margin = .{ .x = 0, .y = 2, .w = 0, .h = 4 } });

    if (pr.plugin_count == 0) {
        const fetching = pr.status.load(.acquire) == .fetching;
        _ = dvui.label(@src(), "{s}", .{if (fetching) "Loading sources…" else "No sources available."}, .{ .color_text = theme.colors.text_dim, .margin = .{ .x = 0, .y = 6, .w = 0, .h = 0 } });
        return;
    }

    // Available sources — one tidy row each.
    var list = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 } });
    defer list.deinit();
    for (0..pr.plugin_count) |i| {
        const p = &pr.plugins[i];
        var rowb = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i + 81000, .expand = .horizontal, .padding = .{ .x = 0, .y = 5, .w = 0, .h = 5 } });
        defer rowb.deinit();
        _ = dvui.label(@src(), "{s}", .{p.nameSlice()}, .{ .id_extra = i + 81100, .color_text = theme.colors.text_main, .gravity_y = 0.5 });
        _ = dvui.label(@src(), "  {s}", .{p.kindSlice()}, .{ .id_extra = i + 81200, .color_text = theme.colors.text_dim, .gravity_y = 0.5 });
        {
            var sp = dvui.box(@src(), .{}, .{ .id_extra = i + 81300, .expand = .horizontal });
            sp.deinit();
        }
        const installed = pr.isInstalled(p.idSlice());
        if (dvui.button(@src(), if (installed) "Uninstall" else "Install", .{}, .{ .id_extra = i + 81400, .color_fill = if (installed) theme.colors.bg_glass else theme.colors.accent, .color_text = if (installed) theme.colors.text_muted else dvui.Color.white, .corner_radius = theme.dims.rad_sm, .padding = .{ .x = 12, .y = 5, .w = 12, .h = 5 }, .gravity_y = 0.5 })) {
            if (installed) pr.uninstall(i) else pr.install(i);
        }
    }
}

fn renderDebrid() void {
    const pr = @import("plugin_repo.zig");
    var card = cardBegin(@src(), 1);
    defer card.deinit();

    cardTitle(@src(), "Debrid", "Instant cached streams via Stremio add-ons (Torrentio). Optional.");

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();

    const providers = [_][]const u8{ "realdebrid", "alldebrid", "premiumize", "torbox", "debridlink" };
    if (dvui.button(@src(), pr.debridProvider(), .{}, .{ .color_fill = theme.colors.bg_glass, .color_text = theme.colors.accent, .corner_radius = theme.dims.rad_sm, .padding = .{ .x = 10, .y = 7, .w = 10, .h = 7 }, .gravity_y = 0.5 })) {
        var idx: usize = 0;
        for (providers, 0..) |p, k| {
            if (std.mem.eql(u8, p, pr.debridProvider())) idx = k;
        }
        const next = providers[(idx + 1) % providers.len];
        @memcpy(pr.debrid_provider_buf[0..next.len], next);
        pr.debrid_provider_len = next.len;
        pr.saveDebrid();
    }
    var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &pr.debrid_key_buf }, .placeholder = "debrid API key" }, .{ .expand = .horizontal, .gravity_y = 0.5, .margin = .{ .x = theme.spacing.sm, .y = 0, .w = theme.spacing.sm, .h = 0 } });
    te.deinit();
    pr.debrid_key_len = std.mem.indexOfScalar(u8, &pr.debrid_key_buf, 0) orelse pr.debrid_key_buf.len;
    if (dvui.button(@src(), "Save", .{}, .{ .color_fill = theme.colors.bg_glass, .color_text = theme.colors.text_muted, .corner_radius = theme.dims.rad_sm, .padding = .{ .x = 12, .y = 7, .w = 12, .h = 7 }, .gravity_y = 0.5 })) {
        pr.saveDebrid();
        state.showToastTyped("Debrid saved", .success);
    }
}

/// Trakt.tv connect panel — scrobble + sync watched to the user's Trakt account.
fn renderTrakt() void {
    const tr = @import("trakt.zig");
    var card = cardBegin(@src(), 2);
    defer card.deinit();

    cardTitle(@src(), "Trakt.tv", "Sync your watched history.");

    if (tr.isConnected()) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        _ = dvui.label(@src(), "Connected", .{}, .{ .color_text = theme.colors.success, .gravity_y = 0.5 });
        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }
        if (dvui.button(@src(), "Disconnect", .{}, .{ .color_fill = theme.colors.bg_glass, .color_text = theme.colors.text_muted, .corner_radius = theme.dims.rad_sm, .padding = .{ .x = 12, .y = 5, .w = 12, .h = 5 }, .gravity_y = 0.5 })) {
            tr.disconnect();
        }
        return;
    }

    _ = dvui.label(@src(), "Create an app at trakt.tv/oauth/applications (redirect urn:ietf:wg:oauth:2.0:oob), then paste id + secret.", .{}, .{ .color_text = theme.colors.text_dim, .expand = .horizontal, .margin = .{ .x = 0, .y = 0, .w = 0, .h = 6 } });

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();

    var idte = dvui.textEntry(@src(), .{ .text = .{ .buffer = &tr.client_id }, .placeholder = "Trakt client id" }, .{ .expand = .horizontal, .gravity_y = 0.5 });
    idte.deinit();
    tr.client_id_len = std.mem.indexOfScalar(u8, &tr.client_id, 0) orelse tr.client_id.len;

    var scte = dvui.textEntry(@src(), .{ .text = .{ .buffer = &tr.client_secret }, .placeholder = "client secret" }, .{ .expand = .horizontal, .gravity_y = 0.5, .margin = .{ .x = theme.spacing.sm, .y = 0, .w = theme.spacing.sm, .h = 0 } });
    scte.deinit();
    tr.client_secret_len = std.mem.indexOfScalar(u8, &tr.client_secret, 0) orelse tr.client_secret.len;

    const label_txt = if (tr.auth_pending and tr.user_code_len > 0) "Waiting" else "Connect";
    if (dvui.button(@src(), label_txt, .{}, .{ .color_fill = theme.colors.accent, .color_text = dvui.Color.white, .corner_radius = theme.dims.rad_sm, .padding = .{ .x = 12, .y = 7, .w = 12, .h = 7 }, .gravity_y = 0.5 })) {
        tr.save();
        tr.startDeviceAuth();
    }

    if (tr.auth_pending and tr.user_code_len > 0) {
        _ = dvui.label(@src(), "Enter code {s} at trakt.tv/activate", .{tr.user_code[0..tr.user_code_len]}, .{ .color_text = theme.colors.accent, .margin = .{ .x = 0, .y = 6, .w = 0, .h = 0 } });
    }
}

pub fn renderContent() void {
    if (!scanned) scanPlugins();

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_app });
    defer scroll.deinit();

    renderSourcePlugins();
    renderDebrid();
    renderTrakt();

    // ── Content plugins (external executables) — advanced, own card ──
    var card = cardBegin(@src(), 3);
    defer card.deinit();
    cardTitle(@src(), "Content plugins", "Advanced: external executable plugins.");

    {
        var top = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
        });
        defer top.deinit();

        if (plugin_count == 0) {
            _ = dvui.label(@src(), "No content plugins installed", .{}, .{
                .color_text = theme.colors.text_muted, .expand = .horizontal,
            });
            
            var hint_buf: [256]u8 = undefined;
            var dir_buf2: [512]u8 = undefined;
            const pd = getPluginDir(&dir_buf2);
            const hint = std.fmt.bufPrintZ(&hint_buf, "Install plugins to: {s}", .{pd}) catch "~/.config/opal/plugins/";
            _ = dvui.label(@src(), "{s}", .{hint}, .{
                .color_text = theme.colors.text_dim, .expand = .horizontal,
            });
            
            if (dvui.button(@src(), "Rescan", .{}, .{
                .color_fill = theme.colors.accent, .color_text = dvui.Color.white,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
            })) {
                scanned = false;
            }
            return;
        }
        
        // Plugin tabs (scrollable for many extensions)
        {
            var tab_scroll = dvui.scrollArea(@src(), .{ .horizontal = .auto, .vertical = .none }, .{
                .expand = .horizontal, 
                .max_size_content = .{ .w = std.math.floatMax(f32), .h = 32 },
                .padding = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
            });
            defer tab_scroll.deinit();
            
            var tab_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            });
            defer tab_row.deinit();
            
            for (0..plugin_count) |pi| {
                const p = plugins[pi];
                const is_active = (pi == active_plugin);
                const name = p.name[0..p.name_len];
                
                if (dvui.button(@src(), @import("../core/text.zig").safeUtf8(name), .{}, .{
                    .id_extra = pi + 8000,
                    .color_fill = if (is_active) theme.colors.accent else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .color_text = if (is_active) dvui.Color.white else theme.colors.text_muted,
                    .corner_radius = dvui.Rect.all(99),
                    .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
                    .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
                })) {
                    active_plugin = pi;
                    {
                        results_mutex.lock();
                        result_count = 0;
                        results_mutex.unlock();
                    }
                    // Auto-trending on select
                    if (plugins[pi].has_trending) runPluginTrending();
                }
            }
        }
        
        // Search bar
        {
            var search_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal, .padding = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
            });
            defer search_row.deinit();
            
            var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &search_buf } }, .{
                .expand = .horizontal, .min_size_content = .{ .w = 200, .h = 20 },
                .color_fill = theme.colors.bg_input, .color_border = theme.colors.border_input,
                .color_text = theme.colors.text_main,
                .border = dvui.Rect.all(1), .corner_radius = theme.dims.rad_sm,
            });
            const enter_pressed = te.enter_pressed;
            te.deinit();
            
            const clicked = dvui.button(@src(), "Search", .{}, .{
                .color_fill = theme.colors.accent, .color_text = dvui.Color.white,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
                .margin = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
            });
            if (clicked or enter_pressed) {
                const q = std.mem.sliceTo(&search_buf, 0);
                if (q.len > 0) runPluginSearch(q);
            }
        }
    }
    
    // Snapshot the worker-shared state under the lock so the rest of the
    // frame renders against a consistent (loading, count) pair.
    results_mutex.lock();
    const loading_now = is_loading;
    const count_now = result_count;
    results_mutex.unlock();

    // Loading
    if (loading_now) {
        _ = dvui.label(@src(), "Loading...", .{}, .{
            .color_text = theme.colors.accent,
            .padding = .{ .x = 12, .y = 8, .w = 0, .h = 0 },
        });
        return;
    }

    // Results
    if (count_now == 0) {
        _ = dvui.label(@src(), "Search or browse content from plugins", .{}, .{
            .color_text = theme.colors.text_muted,
            .padding = .{ .x = 12, .y = 12, .w = 0, .h = 0 },
        });
        return;
    }

    var results_scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer results_scroll.deinit();

    // Hold the lock across the render loop: a worker only ever rewrites
    // `results` while holding `results_mutex` (see executeAndParse), so this
    // prevents the UI from reading a `results[idx]` that is being overwritten
    // mid-frame. The dvui calls below do not re-enter `results_mutex`.
    results_mutex.lock();
    defer results_mutex.unlock();
    var idx: usize = 0;
    while (idx < count_now and idx < MAX_RESULTS) : (idx += 1) {
        renderPluginCard(&results[idx], idx);
    }
}

fn renderPluginCard(item: *PluginResult, idx: usize) void {
    if (item.title_len == 0) return;
    const title = item.title[0..item.title_len];
    const hue: u32 = @as(u32, @intCast(idx * 7 + 42)) *% 2654435761;
    const h1: u8 = @truncate(hue & 0xFF);
    const h2: u8 = @truncate((hue >> 8) & 0xFF);
    
    // Outer card — vertical so episode grid can go below
    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = idx + 1000, .expand = .horizontal, .background = true,
        .color_fill = if (item.expanded) theme.colors.bg_card_hover else theme.colors.bg_card,
        .color_border = if (item.expanded) theme.colors.accent_glow else theme.colors.bg_header_border,
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .padding = .{ .x = 10, .y = 10, .w = 10, .h = 10 },
    });
    defer outer.deinit();
    
    // Top row: poster + info
    {
        var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = idx + 1100, .expand = .horizontal,
        });
        defer card.deinit();
        
        // Poster
        {
            var poster = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = idx + 100, .background = true,
                .color_fill = dvui.Color{ .r = 20 + h1 / 6, .g = 25 + h2 / 8, .b = 35 + h1 / 5, .a = 255 },
                .corner_radius = dvui.Rect.all(6),
                .min_size_content = .{ .w = 60, .h = 90 }, .max_size_content = .{ .w = 60, .h = 90 },
            });
            defer poster.deinit();
            
            if (item.poster_tex == null and item.poster_pixels != null) {
                const num_pixels = item.poster_w * item.poster_h;
                const pixels_pma: []dvui.Color.PMA = @as([*]dvui.Color.PMA, @ptrCast(@alignCast(item.poster_pixels.?.ptr)))[0..num_pixels];
                item.poster_tex = dvui.textureCreate(pixels_pma, item.poster_w, item.poster_h, .linear, .rgba_32) catch null;
                if (item.poster_tex != null) { c_alloc.free(item.poster_pixels.?); item.poster_pixels = null; }
            }
            
            if (item.poster_tex) |*tex| {
                _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
                    .id_extra = idx + 150, .expand = .both, .corner_radius = dvui.Rect.all(6),
                });
            } else {
                if (!item.poster_fetching and item.poster_url_len > 0) fetchPoster(item);
            }
            _ = &poster;
        }
        
        // Info column
        {
            var info = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = idx + 200, .expand = .horizontal, .padding = .{ .x = 12, .y = 0, .w = 0, .h = 0 },
            });
            defer info.deinit();
            
            // Title — click to toggle episode selection
            if (dvui.button(@src(), @import("../core/text.zig").safeUtf8(title), .{}, .{
                .id_extra = idx + 500, .expand = .horizontal,
                .color_text = if (item.expanded) theme.colors.accent else theme.colors.text_main,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .padding = dvui.Rect.all(0),
            })) {
                // If stream_url is already set, play directly
                if (item.stream_url_len > 0) {
                    const cc = @import("../core/c.zig");
                    // Reject URLs containing quotes to prevent mpv command injection
                    const stream_slice = item.stream_url[0..item.stream_url_len];
                    if (std.mem.indexOfScalar(u8, stream_slice, '"') != null) return;
                    if (state.app.players.items.len > 0 and state.app.active_player_idx < state.app.players.items.len) {
                        const p = state.app.players.items[state.app.active_player_idx];
                        var cmd_buf: [600]u8 = undefined;
                        const cmd = std.fmt.bufPrintZ(&cmd_buf, "loadfile \"{s}\"", .{stream_slice}) catch "";
                        if (cmd.len > 0) _ = cc.mpv.mpv_command_string(p.mpv_ctx, cmd.ptr);
                    }
                } else if (item.episodes > 0) {
                    // Toggle episode selector
                    item.expanded = !item.expanded;
                } else if (item.id_len > 0) {
                    // No episode info — resolve episode 1
                    runPluginResolve(item.id[0..item.id_len], "1");
                }
            }
            
            // Meta row
            {
                var meta = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = idx + 600, .expand = .horizontal, .padding = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
                });
                defer meta.deinit();
                
                if (item.year_len > 0) {
                    _ = dvui.label(@src(), "{s}", .{@import("../core/text.zig").safeUtf8(item.year[0..item.year_len])}, .{
                        .id_extra = idx + 610, .color_text = theme.colors.text_muted,
                    });
                    _ = dvui.label(@src(), " · ", .{}, .{ .id_extra = idx + 615, .color_text = theme.colors.text_muted });
                }
                
                if (item.episodes > 0) {
                    var ep_buf: [16]u8 = undefined;
                    if (std.fmt.bufPrintZ(&ep_buf, "{d} eps", .{item.episodes})) |eps| {
                        _ = dvui.label(@src(), "{s}", .{eps}, .{ .id_extra = idx + 620, .color_text = theme.colors.text_muted });
                    } else |_| {}
                }
                
                if (item.score > 0) {
                    _ = dvui.label(@src(), " · ", .{}, .{ .id_extra = idx + 625, .color_text = theme.colors.text_muted });
                    const pct = @as(u8, @intFromFloat(std.math.clamp(item.score * 10.0, 0.0, 100.0)));
                    const sc = if (pct >= 70) theme.colors.success else if (pct >= 50) theme.colors.warning else theme.colors.danger;
                    var pb: [8]u8 = undefined;
                    if (std.fmt.bufPrintZ(&pb, "{d}%", .{pct})) |ps| {
                        _ = dvui.label(@src(), "{s}", .{ps}, .{ .id_extra = idx + 630, .color_text = sc });
                    } else |_| {}
                }
            }
            
            // Overview snippet
            if (item.overview_len > 0) {
                const snip_len = @min(item.overview_len, 60);
                const suffix: []const u8 = if (item.overview_len > 60) "..." else "";
                var btn_buf: [128]u8 = undefined;
                if (std.fmt.bufPrintZ(&btn_buf, "{s}{s}", .{item.overview[0..snip_len], suffix})) |snip| {
                    _ = dvui.label(@src(), "{s}", .{@import("../core/text.zig").safeUtf8(snip)}, .{
                        .id_extra = idx + 650, .color_text = theme.colors.text_dim, .expand = .horizontal,
                        .padding = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
                    });
                } else |_| {}
            }
        }
    }
    
    // ── Episode Grid (expanded) ──
    if (item.expanded and item.episodes > 0) {
        // Divider
        {
            var div = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = idx + 750, .expand = .horizontal, .background = true,
                .color_fill = theme.colors.divider,
                .min_size_content = .{ .w = 0, .h = 1 },
                .margin = .{ .x = 0, .y = 6, .w = 0, .h = 6 },
            });
            div.deinit();
        }
        
        _ = dvui.label(@src(), "Select Episode", .{}, .{
            .id_extra = idx + 760,
            .color_text = theme.colors.accent,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
        });
        
        // Episode number buttons in a wrapping grid
        const ep_count: usize = @intCast(item.episodes);
        const max_show: usize = @min(ep_count, 200); // cap at 200 for performance
        
        var row_start: usize = 0;
        while (row_start < max_show) {
            const row_end = @min(row_start + 10, max_show); // 10 per row
            
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = idx * 300 + row_start + 2000,
                .expand = .horizontal,
                .padding = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
            });
            defer row.deinit();
            
            for (row_start..row_end) |ep_i| {
                const ep_num = ep_i + 1;
                var lbl: [8]u8 = undefined;
                if (std.fmt.bufPrintZ(&lbl, "{d}", .{ep_num})) |ep_str| {
                    if (dvui.button(@src(), @import("../core/text.zig").safeUtf8(ep_str), .{}, .{
                        .id_extra = idx * 300 + ep_i + 3000,
                        .color_fill = theme.colors.bg_input,
                        .color_text = theme.colors.text_main,
                        .color_border = theme.colors.border_input,
                        .border = dvui.Rect.all(1),
                        .corner_radius = dvui.Rect.all(4),
                        .padding = .{ .x = 6, .y = 3, .w = 6, .h = 3 },
                        .margin = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
                        .min_size_content = .{ .w = 24, .h = 14 },
                    })) {
                        // Resolve this specific episode
                        if (item.id_len > 0) {
                            var ep_arg: [8]u8 = undefined;
                            if (std.fmt.bufPrintZ(&ep_arg, "{d}", .{ep_num})) |ea| {
                                runPluginResolve(item.id[0..item.id_len], ea);
                            } else |_| {}
                        }
                    }
                } else |_| {}
            }
            
            row_start = row_end;
        }
    }
}

