//! Mihon / Aniyomi extension DISCOVERY + INSTALL panel.
//!
//! The tested pure layer (mihon_repo_pure.zig, re-exported as
//! manga_suwayomi_pure.repo) owns the curated repo list, the index.min.json
//! parser, the Suwayomi `/api/v1/extension/*` URL builders and the extension/
//! list installed-state readers. THIS module owns the glue: fetching a repo's
//! catalog + the server's installed list, holding the browse state, driving
//! install/uninstall against the user's Suwayomi server, and drawing the panel.
//!
//! Inert without a Suwayomi server: the base URL comes from source_config
//! ("suwayomi"/"base"), same as comics.zig. No server → the panel explains how
//! to configure one and does nothing else. Adult extensions are gated by the
//! global NSFW setting (state.app.nsfw_filter_enabled), like Live TV.

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const logs = @import("../core/logs.zig");
const io = @import("../core/io_global.zig");
const source_config = @import("../core/source_config.zig");
const repo = @import("mihon_repo_pure.zig");
const sync = @import("../core/sync.zig");

const alloc = @import("../core/alloc.zig").allocator;

// ── Browse state ──

// Storage cap — must exceed the largest real catalog so nothing is dropped:
// Keiyoushi/Yuzono carry ~1,370 extensions each (verified against the live
// index.min.json). ~600B/row → ~1.2 MB static at 2000.
const MAX_ROWS: usize = 2000;

// Display cap — how many filtered rows are drawn at once. The list isn't
// virtualized, so drawing all ~1,370 rows every frame would stutter; the filter
// box narrows to what you want, and a footer notes when more are hidden.
const RENDER_CAP: usize = 300;

const ExtRow = struct {
    name: [128]u8 = std.mem.zeroes([128]u8),
    name_len: usize = 0,
    pkg: [256]u8 = std.mem.zeroes([256]u8),
    pkg_len: usize = 0,
    lang: [16]u8 = std.mem.zeroes([16]u8),
    lang_len: usize = 0,
    version: [32]u8 = std.mem.zeroes([32]u8),
    version_len: usize = 0,
    source_name: [128]u8 = std.mem.zeroes([128]u8),
    source_name_len: usize = 0,
    // First source's numeric id — the key comics.zig browses by (suwayomi/source).
    source_id: [32]u8 = std.mem.zeroes([32]u8),
    source_id_len: usize = 0,
    source_count: usize = 0,
    nsfw: bool = false,
    installed: bool = false,
};

var rows: [MAX_ROWS]ExtRow = undefined;
var row_count: usize = 0;
var rows_mutex: sync.Mutex = .{};

var panel_open: bool = false;
var fetching: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var status_buf: [128]u8 = std.mem.zeroes([128]u8);
var status_len: usize = 0;

// Custom repo URL input (persisted to source_config "mihon"/"repo"), and the
// name-filter input for the loaded catalog.
var custom_buf: [512]u8 = std.mem.zeroes([512]u8);
var custom_prefilled: bool = false;
var filter_buf: [64]u8 = std.mem.zeroes([64]u8);

fn setStatus(msg: []const u8) void {
    const n = @min(msg.len, status_buf.len);
    @memcpy(status_buf[0..n], msg[0..n]);
    status_len = n;
}

fn nudge() void {
    if (state.app.dvui_win) |w| dvui.refresh(w, @src(), null);
}

/// The configured Suwayomi server base URL, or null when none is set (→ inert).
fn suwayomiBase() ?[]const u8 {
    const b = source_config.get("suwayomi", "base") orelse return null;
    return if (repo.isValidBase(b)) b else null;
}

// ── Panel open/close (called from comics.zig) ──

pub fn isOpen() bool {
    return panel_open;
}

pub fn open() void {
    panel_open = true;
}

pub fn close() void {
    panel_open = false;
}

// ── HTTP ──

/// GET `url` into `dst`, returning bytes read (0 on failure). std.http is avoided
/// project-wide (SEGVs on some ISP TLS resets); curl matches comics.zig.
fn curl(url: []const u8, dst: []u8) usize {
    const argv = [_][]const u8{ "curl", "-sL", "--max-time", "25", url };
    var child = io.Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return 0;
    const n = if (child.stdout) |*so| io.readAll(so, dst) catch 0 else 0;
    _ = child.wait() catch {};
    return n;
}

/// POST `body` (JSON) to `url`, returning bytes read into `dst`. Used for the
/// Suwayomi GraphQL calls that register a repo on the server.
fn curlPost(url: []const u8, body: []const u8, dst: []u8) usize {
    const argv = [_][]const u8{ "curl", "-sL", "-X", "POST", "-H", "Content-Type: application/json", "--data-binary", body, "--max-time", "25", url };
    var child = io.Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return 0;
    const n = if (child.stdout) |*so| io.readAll(so, dst) catch 0 else 0;
    _ = child.wait() catch {};
    return n;
}

/// Register `repo_url` in the server's `extensionRepos` (merging with what's
/// already there) and refresh its extension list, so a subsequent install of one
/// of this repo's packages actually resolves. Best-effort: any failure just means
/// the user may need to add the repo in Suwayomi's own settings. GraphQL bodies +
/// the merge come from the tested pure module.
fn registerRepoOnServer(repo_url: []const u8) void {
    const base = suwayomiBase() orelse return;
    var gurl_buf: [600]u8 = undefined;
    const gurl = repo.buildGraphqlUrl(&gurl_buf, base) orelse return;

    var resp: [16384]u8 = undefined;
    const n = curlPost(gurl, repo.GQL_GET_REPOS, &resp);

    var slots: [64][]const u8 = undefined;
    var scratch: [8192]u8 = undefined;
    var count = if (n > 0) repo.extractRepos(resp[0..n], &slots, &scratch) else 0;

    if (!repo.reposContain(slots[0..count], repo_url) and count < slots.len) {
        slots[count] = repo_url; // valid for the life of this call
        count += 1;
    }

    var body_buf: [12288]u8 = undefined;
    if (repo.buildSetReposBody(&body_buf, slots[0..count])) |body| {
        var out: [4096]u8 = undefined;
        _ = curlPost(gurl, body, &out);
        _ = curlPost(gurl, repo.GQL_FETCH_EXTENSIONS, &out);
    }
}

/// GET `url` and return the HTTP status code (0 on transport failure). Used for
/// install/uninstall, where Suwayomi returns 200 with no useful body.
fn curlCode(url: []const u8) u32 {
    const argv = [_][]const u8{ "curl", "-sL", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "25", url };
    var child = io.Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return 0;
    var code_buf: [16]u8 = undefined;
    const n = if (child.stdout) |*so| io.readAll(so, &code_buf) catch 0 else 0;
    _ = child.wait() catch {};
    return std.fmt.parseInt(u32, std.mem.trim(u8, code_buf[0..n], " \r\n"), 10) catch 0;
}

// ── Load a repo catalog ──

/// Start loading `url` (already an index.min.json URL) in the background. Also
/// persists it as the last-used repo. No-op while a fetch is in flight.
pub fn loadRepoUrl(url: []const u8) void {
    if (fetching.load(.acquire)) return;
    const S = struct {
        var url_copy: [512]u8 = undefined;
        var url_len: usize = 0;
        var busy: bool = false;
        fn go() void {
            const Self = @This();
            defer Self.busy = false;
            worker(Self.url_copy[0..Self.url_len]);
        }
    };
    if (S.busy) return;
    const n = @min(url.len, S.url_copy.len);
    @memcpy(S.url_copy[0..n], url[0..n]);
    S.url_len = n;
    S.busy = true;
    // Persist so the panel reopens on the same repo next session.
    var body: [640]u8 = undefined;
    if (std.fmt.bufPrint(&body, "{{\"repo\":\"{s}\"}}", .{url[0..n]})) |b| {
        _ = source_config.install("mihon", b);
    } else |_| {}
    if (std.Thread.spawn(.{}, S.go, .{})) |t| t.detach() else |_| {
        S.busy = false;
    }
}

fn worker(url: []const u8) void {
    if (fetching.swap(true, .acq_rel)) return;
    defer fetching.store(false, .release);
    setStatus("Loading catalog…");
    nudge();

    // index.min.json can be a few hundred KB (keiyoushi). Heap, not the worker
    // stack (macOS 512KB limit — CLAUDE.md).
    const buf = alloc.alloc(u8, 6 * 1024 * 1024) catch {
        setStatus("Out of memory loading catalog");
        nudge();
        return;
    };
    defer alloc.free(buf);

    const n = curl(url, buf);
    if (n == 0) {
        setStatus("Could not fetch the repository");
        nudge();
        return;
    }

    // Parse into rows under the mutex. Temp field buffers are reused per row.
    rows_mutex.lock();
    row_count = 0;
    var nb: [128]u8 = undefined;
    var pb: [256]u8 = undefined;
    var ab: [256]u8 = undefined;
    var lb: [16]u8 = undefined;
    var vb: [32]u8 = undefined;
    var sib: [64]u8 = undefined;
    var snb: [128]u8 = undefined;
    var sbb: [256]u8 = undefined;
    var it = repo.ExtIter{ .json = buf[0..n] };
    while (it.next()) |obj| {
        if (row_count >= rows.len) break;
        const e = repo.parseExtension(obj, &nb, &pb, &ab, &lb, &vb, &sib, &snb, &sbb) orelse continue;
        var r = &rows[row_count];
        r.* = .{};
        copyField(&r.name, &r.name_len, e.name);
        copyField(&r.pkg, &r.pkg_len, e.pkg);
        copyField(&r.lang, &r.lang_len, e.lang);
        copyField(&r.version, &r.version_len, e.version);
        copyField(&r.source_name, &r.source_name_len, e.source_name);
        copyField(&r.source_id, &r.source_id_len, e.source_id);
        r.source_count = e.source_count;
        r.nsfw = e.nsfw;
        row_count += 1;
    }
    const loaded = row_count;
    rows_mutex.unlock();

    // Register this repo on the Suwayomi server (best-effort) so installs of its
    // packages resolve, then read back the installed state.
    registerRepoOnServer(url);
    markInstalled(buf); // reuse the big buffer for the server's list

    var sb: [64]u8 = undefined;
    setStatus(std.fmt.bufPrint(&sb, "{d} extensions", .{loaded}) catch "loaded");
    nudge();
}

/// Fetch the server's extension/list and flag rows whose pkg is installed.
/// Best-effort: no server / a bad response just leaves everything as "Install".
fn markInstalled(buf: []u8) void {
    const base = suwayomiBase() orelse return;
    var url_buf: [600]u8 = undefined;
    const url = repo.buildExtensionListUrl(&url_buf, base) orelse return;
    const n = curl(url, buf);
    if (n == 0) return;

    var pb: [256]u8 = undefined;
    var it = repo.ExtIter{ .json = buf[0..n] };
    rows_mutex.lock();
    defer rows_mutex.unlock();
    while (it.next()) |obj| {
        if (!repo.listObjInstalled(obj)) continue;
        const pn = repo.listObjPkg(obj, &pb);
        if (pn == 0) continue;
        for (rows[0..row_count]) |*r| {
            if (std.mem.eql(u8, r.pkg[0..r.pkg_len], pb[0..pn])) {
                r.installed = true;
                break;
            }
        }
    }
}

fn copyField(dst: []u8, len: *usize, src: []const u8) void {
    const k = @min(src.len, dst.len);
    @memcpy(dst[0..k], src[0..k]);
    len.* = k;
}

// ── Install / uninstall ──

/// Install (want=true) or uninstall (want=false) the extension `pkg` on the
/// server, then flip the row optimistically. Background thread; copies pkg in.
fn setInstalled(pkg: []const u8, want: bool) void {
    const Job = struct {
        var pkg_copy: [256]u8 = undefined;
        var pkg_len: usize = 0;
        var want_install: bool = false;
        var busy: bool = false;
        fn go() void {
            const Self = @This();
            defer Self.busy = false;
            const base = suwayomiBase() orelse return;
            var url_buf: [600]u8 = undefined;
            const p = Self.pkg_copy[0..Self.pkg_len];
            const url = if (Self.want_install)
                repo.buildInstallUrl(&url_buf, base, p)
            else
                repo.buildUninstallUrl(&url_buf, base, p);
            const code = if (url) |u| curlCode(u) else 0;
            const ok = code >= 200 and code < 300;
            if (ok) {
                rows_mutex.lock();
                for (rows[0..row_count]) |*r| {
                    if (std.mem.eql(u8, r.pkg[0..r.pkg_len], p)) {
                        r.installed = Self.want_install;
                        break;
                    }
                }
                rows_mutex.unlock();
                setStatus(if (Self.want_install) "Extension installed" else "Extension removed");
            } else {
                setStatus("Server request failed — is Suwayomi running?");
            }
            nudge();
        }
    };
    if (Job.busy) return;
    const k = @min(pkg.len, Job.pkg_copy.len);
    @memcpy(Job.pkg_copy[0..k], pkg[0..k]);
    Job.pkg_len = k;
    Job.want_install = want;
    Job.busy = true;
    if (std.Thread.spawn(.{}, Job.go, .{})) |t| t.detach() else |_| {
        Job.busy = false;
    }
}

// ══════════════════════════════════════════════════════════
// Render
// ══════════════════════════════════════════════════════════

pub fn renderPanel() void {
    var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = dvui.Rect.all(10) });
    defer page.deinit();

    // Header: title + close.
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 } });
        defer hdr.deinit();
        dvui.icon(@src(), "", icons.tvg.lucide.@"puzzle", .{}, .{ .color_text = theme.colors.accent, .gravity_y = 0.5, .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 } });
        _ = dvui.label(@src(), "Mihon Extensions", .{}, .{ .color_text = theme.colors.text_primary, .gravity_y = 0.5, .font = dvui.themeGet().font_heading });
        { var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal }); sp.deinit(); }
        if (dvui.button(@src(), "Close", .{}, .{
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_secondary,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 12, .y = 5, .w = 12, .h = 5 },
        })) close();
    }

    // Inert without a server.
    if (suwayomiBase() == null) {
        _ = dvui.label(@src(), "Configure a Suwayomi server first (Settings → Plugins → Suwayomi). Extensions install onto that server, then their sources appear in the Comics grid.", .{}, .{
            .color_text = theme.colors.text_secondary,
            .expand = .horizontal,
            .margin = dvui.Rect.all(12),
        });
        return;
    }

    // Repo picker: curated chips + custom URL + Load.
    {
        var repos = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal, .margin = .{ .x = 0, .y = 0, .w = 0, .h = 6 } });
        defer repos.deinit();
        for (repo.REPOS, 0..) |rp, i| {
            if (dvui.button(@src(), rp.name, .{}, .{
                .id_extra = 45000 + i,
                .color_fill = theme.colors.bg_elevated,
                .color_text = theme.colors.text_primary,
                .corner_radius = theme.dims.rad_md,
                .padding = .{ .x = 10, .y = 3, .w = 10, .h = 3 },
                .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
                .font = dvui.themeGet().font_body.withSize(theme.font_size.small),
            })) {
                var nb: [512]u8 = undefined;
                if (repo.normalizeRepoIndexUrl(&nb, rp.url)) |u| loadRepoUrl(u);
            }
        }
    }

    // Custom repo URL row.
    {
        if (!custom_prefilled) {
            custom_prefilled = true;
            if (source_config.get("mihon", "repo")) |u| {
                const k = @min(u.len, custom_buf.len - 1);
                @memcpy(custom_buf[0..k], u[0..k]);
            }
        }
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .x = 0, .y = 0, .w = 0, .h = 6 } });
        defer row.deinit();
        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &custom_buf }, .placeholder = "Custom repo URL (…/index.min.json)" }, .{
            .expand = .horizontal,
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_primary,
            .corner_radius = theme.dims.rad_sm,
            .gravity_y = 0.5,
        });
        te.deinit();
        if (dvui.button(@src(), "Load", .{}, .{
            .color_fill = theme.colors.accent,
            .color_text = dvui.Color.white,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
            .margin = .{ .x = 6, .y = 0, .w = 0, .h = 0 },
            .gravity_y = 0.5,
        })) {
            var nb: [512]u8 = undefined;
            if (repo.normalizeRepoIndexUrl(&nb, std.mem.sliceTo(&custom_buf, 0))) |u| {
                loadRepoUrl(u);
            } else {
                setStatus("Not a valid repo URL");
            }
        }
    }

    // Status + name filter.
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .x = 0, .y = 0, .w = 0, .h = 6 } });
        defer row.deinit();
        _ = dvui.label(@src(), "{s}{s}", .{ if (fetching.load(.acquire)) "… " else "", status_buf[0..status_len] }, .{
            .color_text = theme.colors.text_secondary,
            .gravity_y = 0.5,
        });
        { var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal }); sp.deinit(); }
        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &filter_buf }, .placeholder = "Filter…" }, .{
            .min_size_content = .{ .w = 160, .h = 0 },
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_primary,
            .corner_radius = theme.dims.rad_sm,
            .gravity_y = 0.5,
        });
        te.deinit();
    }

    renderList();
}

fn renderList() void {
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_surface });
    defer scroll.deinit();

    const filter = std.mem.sliceTo(&filter_buf, 0);
    const hide_nsfw = state.app.nsfw_filter_enabled;

    rows_mutex.lock();
    defer rows_mutex.unlock();

    var matched: usize = 0; // total matching the filter
    var drawn: usize = 0; // actually rendered (capped)
    for (rows[0..row_count], 0..) |*r, idx| {
        if (r.nsfw and hide_nsfw) continue;
        const name = r.name[0..r.name_len];
        if (filter.len > 0 and !containsCI(name, filter)) continue;
        matched += 1;
        if (drawn < RENDER_CAP) {
            renderRow(r, idx);
            drawn += 1;
        }
    }

    if (row_count == 0 and !fetching.load(.acquire)) {
        _ = dvui.label(@src(), "Pick a repository above to browse its extensions.", .{}, .{
            .color_text = theme.colors.text_secondary,
            .margin = dvui.Rect.all(16),
        });
    } else if (matched == 0 and row_count > 0) {
        _ = dvui.label(@src(), "No extensions match the filter.", .{}, .{
            .color_text = theme.colors.text_secondary,
            .margin = dvui.Rect.all(16),
        });
    } else if (matched > drawn) {
        var hb: [96]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{std.fmt.bufPrint(&hb, "Showing {d} of {d} — type in Filter to narrow", .{ drawn, matched }) catch "…"}, .{
            .color_text = theme.colors.text_secondary,
            .gravity_x = 0.5,
            .margin = dvui.Rect.all(12),
        });
    }
}

fn renderRow(r: *const ExtRow, idx: usize) void {
    var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = idx,
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .color_border = theme.colors.border_subtle,
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
    });
    defer card.deinit();

    // Name + meta.
    {
        var info = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = idx + 1000, .expand = .horizontal, .gravity_y = 0.5 });
        defer info.deinit();

        {
            var nrow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = idx + 1100, .expand = .horizontal });
            defer nrow.deinit();
            _ = dvui.labelNoFmt(@src(), r.name[0..r.name_len], .{}, .{
                .id_extra = idx + 1200,
                .color_text = theme.colors.text_primary,
                .gravity_y = 0.5,
            });
            if (r.nsfw) {
                _ = dvui.label(@src(), "18+", .{}, .{
                    .id_extra = idx + 1250,
                    .color_text = dvui.Color.white,
                    .color_fill = theme.colors.danger,
                    .background = true,
                    .corner_radius = theme.dims.rad_sm,
                    .padding = .{ .x = 5, .y = 1, .w = 5, .h = 1 },
                    .margin = .{ .x = 6, .y = 0, .w = 0, .h = 0 },
                    .gravity_y = 0.5,
                    .font = dvui.themeGet().font_body.withSize(theme.font_size.micro),
                });
            }
        }

        var meta_buf: [96]u8 = undefined;
        const meta = std.fmt.bufPrint(&meta_buf, "{s} · v{s} · {d} source{s}", .{
            r.lang[0..r.lang_len],
            r.version[0..r.version_len],
            r.source_count,
            if (r.source_count == 1) "" else "s",
        }) catch r.lang[0..r.lang_len];
        _ = dvui.labelNoFmt(@src(), meta, .{}, .{
            .id_extra = idx + 1300,
            .color_text = theme.colors.text_tertiary,
            .font = dvui.themeGet().font_body.withSize(theme.font_size.small),
        });
    }

    // Browse (installed only) → point the Comics grid at this source.
    if (r.installed and r.source_id_len > 0) {
        if (dvui.button(@src(), "Browse", .{}, .{
            .id_extra = idx + 1350,
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.accent,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
            .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
            .gravity_y = 0.5,
        })) {
            @import("comics.zig").browseSuwayomiSource(r.source_id[0..r.source_id_len]);
        }
    }

    // Install / Remove button (fixed width, right-aligned).
    {
        const installed = r.installed;
        if (dvui.button(@src(), if (installed) "Remove" else "Install", .{}, .{
            .id_extra = idx + 1400,
            .color_fill = if (installed) theme.colors.bg_elevated else theme.colors.accent,
            .color_text = if (installed) theme.colors.danger else dvui.Color.white,
            .color_border = if (installed) theme.colors.danger else theme.colors.accent,
            .border = dvui.Rect.all(1),
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 12, .y = 5, .w = 12, .h = 5 },
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 70, .h = 0 },
        })) {
            setInstalled(r.pkg[0..r.pkg_len], !installed);
        }
    }
}

fn containsCI(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(hay[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}
