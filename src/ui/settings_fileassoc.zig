const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const builtin = @import("builtin");

const TRANSPARENT: dvui.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

const is_macos = builtin.os.tag == .macos;

const DESKTOP_ID = "opal.desktop";
const BUNDLE_ID  = "com.debpalash.opal";

const MimeGroup = struct {
    label:   []const u8,
    desc:    []const u8,
    mimes:   []const []const u8,      // Linux MIME types
    utis:    []const []const u8,      // macOS UTI identifiers
    id_base: usize,
};

// ── Linux MIME types ──────────────────────────────────────
const VIDEO_MIMES    = &[_][]const u8{ "video/mp4","video/x-matroska","video/x-msvideo","video/webm","video/quicktime","video/mpeg","video/ogg","video/x-flv","video/x-ms-wmv","video/3gpp" };
const AUDIO_MIMES    = &[_][]const u8{ "audio/mpeg","audio/flac","audio/ogg","audio/wav","audio/x-wav","audio/aac","audio/mp4","audio/x-m4a","audio/opus","audio/webm" };
const TORRENT_MIMES  = &[_][]const u8{ "application/x-bittorrent","x-scheme-handler/magnet" };
const PLAYLIST_MIMES = &[_][]const u8{ "audio/x-mpegurl","application/x-mpegurl","audio/mpegurl","application/vnd.apple.mpegurl" };
const COMICS_MIMES   = &[_][]const u8{ "application/x-cbz","application/x-cbr","application/x-cb7","application/x-cbt","application/vnd.comicbook+zip","application/vnd.comicbook-rar" };

// ── macOS UTI identifiers ─────────────────────────────────
const VIDEO_UTIS    = &[_][]const u8{ "public.movie","public.video","public.mpeg-4","com.apple.quicktime-movie","public.avi","org.matroska.mkv","org.webmproject.webm","com.adobe.flash.video","public.mpeg","public.mpeg-2-video","com.microsoft.windows-media-wmv","public.mpeg-2-transport-stream" };
const AUDIO_UTIS    = &[_][]const u8{ "public.audio","public.mp3","public.mpeg-4-audio","com.apple.m4a-audio","org.xiph.flac","org.xiph.ogg-vorbis","org.xiph.opus","com.microsoft.waveform-audio","public.aiff-audio","com.microsoft.windows-media-wma" };
const TORRENT_UTIS  = &[_][]const u8{ "org.bittorrent.torrent" };
const PLAYLIST_UTIS = &[_][]const u8{ "public.m3u-playlist","public.pls-playlist" };
const COMICS_UTIS   = &[_][]const u8{ "com.yacreader.cbz","com.yacreader.cbr" };

const mime_groups = [_]MimeGroup{
    .{ .label = "Video",            .desc = "mp4, mkv, avi, webm, mov",    .mimes = VIDEO_MIMES,    .utis = VIDEO_UTIS,    .id_base = 70000 },
    .{ .label = "Audio",            .desc = "mp3, flac, ogg, wav, aac",    .mimes = AUDIO_MIMES,    .utis = AUDIO_UTIS,    .id_base = 71000 },
    .{ .label = "Torrent / Magnet", .desc = ".torrent + magnet: links",    .mimes = TORRENT_MIMES,  .utis = TORRENT_UTIS,  .id_base = 72000 },
    .{ .label = "Playlists (M3U)",  .desc = "m3u, m3u8 playlist files",    .mimes = PLAYLIST_MIMES, .utis = PLAYLIST_UTIS, .id_base = 73000 },
    .{ .label = "Comics",           .desc = "cbz, cbr archives",           .mimes = COMICS_MIMES,   .utis = COMICS_UTIS,   .id_base = 74000 },
};

// ── Background-thread state ────────────────────────────────
const AssocState = struct {
    mutex:          @import("../core/sync.zig").Mutex = .{},
    status:         [mime_groups.len]bool = [_]bool{false} ** mime_groups.len,
    checking:       bool = false,
    last_check_ms:  i64  = 0,
    action_pending: bool = false,
};

var g: AssocState = .{};

// ── Background workers ────────────────────────────────────

fn bgCheckAll(_: void) void {
    var tmp: [mime_groups.len]bool = undefined;
    inline for (mime_groups, 0..) |grp, gi| {
        if (is_macos)
            tmp[gi] = checkGroupBlockingMac(grp.utis)
        else
            tmp[gi] = checkGroupBlocking(grp.mimes);
    }
    g.mutex.lock();
    g.status = tmp;
    g.checking = false;
    g.last_check_ms = @import("../core/io_global.zig").milliTimestamp();
    g.mutex.unlock();
}

fn bgRegisterAll(_: void) void {
    if (is_macos) {
        inline for (mime_groups) |grp| registerGroupBlockingMac(grp.utis);
    } else {
        ensureDesktopFileBlocking();
        inline for (mime_groups) |grp| registerGroupBlocking(grp.mimes);
    }
    g.mutex.lock();
    g.action_pending = false;
    g.last_check_ms = 0;
    g.mutex.unlock();
    bgCheckAll({});
}

fn bgUnregisterAll(_: void) void {
    if (is_macos) {
        inline for (mime_groups) |grp| unregisterGroupBlockingMac(grp.utis);
    } else {
        inline for (mime_groups) |grp| unregisterGroupBlocking(grp.mimes);
    }
    g.mutex.lock();
    g.action_pending = false;
    g.last_check_ms = 0;
    g.mutex.unlock();
    bgCheckAll({});
}

const GroupAction = struct { idx: usize, register: bool };
fn bgGroupAction(act: GroupAction) void {
    if (is_macos) {
        const utis = mime_groups[act.idx].utis;
        if (act.register) registerGroupBlockingMac(utis) else unregisterGroupBlockingMac(utis);
    } else {
        const mimes = mime_groups[act.idx].mimes;
        if (act.register) {
            ensureDesktopFileBlocking();
            registerGroupBlocking(mimes);
        } else {
            unregisterGroupBlocking(mimes);
        }
    }
    g.mutex.lock();
    g.action_pending = false;
    g.last_check_ms = 0;
    g.mutex.unlock();
    bgCheckAll({});
}

fn triggerCheck() void {
    g.mutex.lock();
    if (g.checking) { g.mutex.unlock(); return; }
    g.checking = true;
    g.mutex.unlock();
    const t = std.Thread.spawn(.{}, bgCheckAll, .{{}}) catch {
        g.mutex.lock(); g.checking = false; g.mutex.unlock();
        return;
    };
    t.detach();
}

fn triggerRegisterAll() void {
    g.mutex.lock();
    if (g.action_pending) { g.mutex.unlock(); return; }
    g.action_pending = true;
    g.mutex.unlock();
    const t = std.Thread.spawn(.{}, bgRegisterAll, .{{}}) catch {
        g.mutex.lock(); g.action_pending = false; g.mutex.unlock();
        return;
    };
    t.detach();
}

fn triggerUnregisterAll() void {
    g.mutex.lock();
    if (g.action_pending) { g.mutex.unlock(); return; }
    g.action_pending = true;
    g.mutex.unlock();
    const t = std.Thread.spawn(.{}, bgUnregisterAll, .{{}}) catch {
        g.mutex.lock(); g.action_pending = false; g.mutex.unlock();
        return;
    };
    t.detach();
}

fn triggerGroupAction(idx: usize, register: bool) void {
    g.mutex.lock();
    if (g.action_pending) { g.mutex.unlock(); return; }
    g.action_pending = true;
    g.mutex.unlock();
    const act = GroupAction{ .idx = idx, .register = register };
    const t = std.Thread.spawn(.{}, bgGroupAction, .{act}) catch {
        g.mutex.lock(); g.action_pending = false; g.mutex.unlock();
        return;
    };
    t.detach();
}

// ══════════════════════════════════════════════════════════
//  macOS — uses swift -e + CoreServices (always available)
// ══════════════════════════════════════════════════════════

fn checkGroupBlockingMac(utis: []const []const u8) bool {
    const allocator = @import("../core/alloc.zig").allocator;
    for (utis) |uti| {
        var script_buf: [512]u8 = undefined;
        const script = std.fmt.bufPrint(&script_buf,
            "import Foundation;import CoreServices;let h=LSCopyDefaultRoleHandlerForContentType(\"{s}\" as CFString,.all);print((h?.takeRetainedValue() as String?) ?? \"\")",
            .{uti}) catch continue;

        var child = @import("../core/io_global.zig").Child.init(
            &.{ "swift", "-e", script },
            allocator,
        );
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.spawn() catch return false;
        var rbuf: [256]u8 = undefined;
        var rdr = child.stdout.?.reader(@import("../core/io_global.zig").io(), &rbuf);
        const line = rdr.interface.takeDelimiter('\n') catch {
            _ = child.wait() catch {};
            return false;
        } orelse {
            _ = child.wait() catch {};
            return false;
        };
        _ = child.wait() catch {};
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (!std.ascii.eqlIgnoreCase(trimmed, BUNDLE_ID)) return false;
    }
    return true;
}

fn registerGroupBlockingMac(utis: []const []const u8) void {
    const allocator = @import("../core/alloc.zig").allocator;
    for (utis) |uti| {
        var script_buf: [512]u8 = undefined;
        const script = std.fmt.bufPrint(&script_buf,
            "import Foundation;import CoreServices;LSSetDefaultRoleHandlerForContentType(\"{s}\" as CFString,.all,\"{s}\" as CFString)",
            .{ uti, BUNDLE_ID }) catch continue;

        var child = @import("../core/io_global.zig").Child.init(
            &.{ "swift", "-e", script },
            allocator,
        );
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch continue;
        _ = child.wait() catch {};
    }
}

fn unregisterGroupBlockingMac(utis: []const []const u8) void {
    // Reset each UTI to no handler (reverts to macOS default)
    const allocator = @import("../core/alloc.zig").allocator;
    for (utis) |uti| {
        var script_buf: [512]u8 = undefined;
        const script = std.fmt.bufPrint(&script_buf,
            "import Foundation;import CoreServices;LSSetDefaultRoleHandlerForContentType(\"{s}\" as CFString,.all,\"\" as CFString)",
            .{uti}) catch continue;

        var child = @import("../core/io_global.zig").Child.init(
            &.{ "swift", "-e", script },
            allocator,
        );
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch continue;
        _ = child.wait() catch {};
    }
}

// ══════════════════════════════════════════════════════════
//  Linux — uses xdg-mime
// ══════════════════════════════════════════════════════════

fn checkGroupBlocking(mimes: []const []const u8) bool {
    const allocator = @import("../core/alloc.zig").allocator;
    for (mimes) |mime| {
        var argv = std.ArrayListUnmanaged([]const u8).empty;
        defer argv.deinit(allocator);
        argv.append(allocator, "xdg-mime") catch return false;
        argv.append(allocator, "query") catch return false;
        argv.append(allocator, "default") catch return false;
        argv.append(allocator, mime) catch return false;
        var child = @import("../core/io_global.zig").Child.init(argv.items, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.spawn() catch return false;
        var rbuf: [128]u8 = undefined;
        var rdr = child.stdout.?.reader(@import("../core/io_global.zig").io(), &rbuf);
        const line = rdr.interface.takeDelimiter('\n') catch {
            _ = child.wait() catch {};
            return false;
        } orelse {
            _ = child.wait() catch {};
            return false;
        };
        _ = child.wait() catch {};
        if (!std.mem.eql(u8, std.mem.trim(u8, line, " \t\r\n"), DESKTOP_ID)) return false;
    }
    return true;
}

fn registerGroupBlocking(mimes: []const []const u8) void {
    const allocator = @import("../core/alloc.zig").allocator;
    for (mimes) |mime| {
        const args = &[_][]const u8{ "xdg-mime", "default", DESKTOP_ID, mime };
        var child = @import("../core/io_global.zig").Child.init(args, allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch continue;
        _ = child.wait() catch {};
    }
    const sh = &[_][]const u8{ "sh", "-c", "update-desktop-database ~/.local/share/applications 2>/dev/null; true" };
    var c2 = @import("../core/io_global.zig").Child.init(sh, allocator);
    c2.stdout_behavior = .Ignore;
    c2.stderr_behavior = .Ignore;
    c2.spawn() catch return;
    _ = c2.wait() catch {};
}

fn unregisterGroupBlocking(mimes: []const []const u8) void {
    const allocator = @import("../core/alloc.zig").allocator;
    const home = @import("../core/io_global.zig").getenv("HOME") orelse return;
    var pb: [512]u8 = undefined;
    const mp = std.fmt.bufPrintZ(&pb, "{s}/.config/mimeapps.list", .{home}) catch return;
    const data = @import("../core/io_global.zig").cwdReadFileAlloc(mp, allocator, 256 * 1024) catch return;
    defer allocator.free(data);
    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |ln| {
        var skip = false;
        for (mimes) |mime| {
            if (std.mem.startsWith(u8, ln, mime) and std.mem.indexOf(u8, ln, DESKTOP_ID) != null) {
                skip = true;
                break;
            }
        }
        if (!skip) {
            out.appendSlice(allocator, ln) catch break;
            out.append(allocator, '\n') catch break;
        }
    }
    @import("../core/io_global.zig").cwdWriteFile(.{ .sub_path = mp, .data = out.items }) catch {};
}

fn ensureDesktopFileBlocking() void {
    const home = @import("../core/io_global.zig").getenv("HOME") orelse return;
    var exb: [512]u8 = undefined;
    const exe = @import("../core/io_global.zig").selfExePath(&exb) catch return;
    var db: [512]u8 = undefined;
    const dp = std.fmt.bufPrintZ(&db, "{s}/.local/share/applications", .{home}) catch return;
    @import("../core/io_global.zig").cwdMakePath(dp) catch {};
    var fb: [512]u8 = undefined;
    const fp = std.fmt.bufPrintZ(&fb, "{s}/opal.desktop", .{dp}) catch return;
    const ml = "video/mp4;video/x-matroska;video/x-msvideo;video/webm;video/quicktime;video/mpeg;video/ogg;video/x-flv;video/x-ms-wmv;video/3gpp;" ++
               "audio/mpeg;audio/flac;audio/ogg;audio/wav;audio/x-wav;audio/aac;audio/mp4;audio/x-m4a;audio/opus;audio/webm;" ++
               "application/x-bittorrent;x-scheme-handler/magnet;" ++
               "audio/x-mpegurl;application/x-mpegurl;audio/mpegurl;application/vnd.apple.mpegurl;" ++
               "application/x-cbz;application/x-cbr;application/x-cb7;application/x-cbt;application/vnd.comicbook+zip;application/vnd.comicbook-rar;";
    var cb: [2560]u8 = undefined;
    const ct = std.fmt.bufPrint(&cb,
        "[Desktop Entry]\nName=Opal\nComment=Opal — Play everything\nExec={s} %U\nIcon=opal\nTerminal=false\nType=Application\nCategories=AudioVideo;Video;Audio;Player;\nMimeType={s}\nStartupNotify=true\n",
        .{ exe, ml }) catch return;
    @import("../core/io_global.zig").cwdWriteFile(.{ .sub_path = fp, .data = ct }) catch {};
}

// ══════════════════════════════════════════════════════════
//  Render — NEVER blocks the UI thread
// ══════════════════════════════════════════════════════════

pub fn render() void {
    // Kick off a background check every 5 seconds (non-blocking)
    const now = @import("../core/io_global.zig").milliTimestamp();
    g.mutex.lock();
    const last = g.last_check_ms;
    const checking = g.checking;
    const pending = g.action_pending;
    const status_snap = g.status;
    g.mutex.unlock();

    // Idle re-check every 30s (was 5s — each sweep spawns ~37 serial `swift -e`
    // interpreter runs on macOS, near-continuous background CPU burn). Actions
    // (register/unregister) still force an immediate re-check by zeroing
    // last_check_ms.
    if (!checking and !pending and now - last > 30_000) {
        triggerCheck();
    }

    const busy = checking or pending;
    // Keep the status text live while the worker runs (no UI wake otherwise).
    if (busy) dvui.refresh(null, @src(), null);

    // Instruction line — quiet tertiary text, no banner box (calm: separate by
    // whitespace, not a colored bordered panel).
    {
        const desc = if (is_macos)
            "Make Opal the default app for these file types."
        else
            "Make Opal the default app (via xdg-mime).";
        _ = dvui.label(@src(), desc, .{}, .{
            .color_text = theme.colors.text_tertiary,
            .margin = .{ .x = theme.spacing.md, .y = 0, .w = theme.spacing.md, .h = theme.spacing.md },
        });
    }

    // Bulk action row. Register-all = the single accent affordance; Unregister
    // = quiet text-only danger; busy state is transient text.
    {
        var brow = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.md, .y = 0, .w = theme.spacing.md, .h = 0 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.md },
        });
        defer brow.deinit();

        if (dvui.button(@src(), if (busy) "Working…" else "Register All", .{}, .{
            .color_fill = if (busy) theme.colors.bg_elevated else theme.colors.accent,
            .color_text = if (busy) theme.colors.text_secondary else theme.colors.text_on_accent,
            .corner_radius = theme.dims.rad_md,
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        })) {
            if (!busy) triggerRegisterAll();
        }

        // Two-step confirm — one click silently reset the default-app handler
        // for all ~37 UTIs across every group.
        if (components.confirmDangerButton(@src(), "Unregister All", 0)) {
            if (!busy) {
                triggerUnregisterAll();
                state.showToast("Removing file associations…");
            }
        }

        if (busy) {
            _ = dvui.label(@src(), "  checking…", .{}, .{
                .color_text = theme.colors.text_tertiary,
                .gravity_y = 0.5,
            });
        }
    }

    // Per-group list — quiet token-driven rows. No per-row border/fill/zebra;
    // separated by whitespace, with one hairline divider between groups.
    inline for (mime_groups, 0..) |grp, gi| {
        const is_reg = status_snap[gi];

        if (gi > 0) components.divider();

        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = grp.id_base,
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
        });
        defer card.deinit();

        // Header row
        {
            var hr = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = grp.id_base + 1,
                .expand = .horizontal,
            });
            defer hr.deinit();

            _ = dvui.label(@src(), "{s}", .{grp.label}, .{
                .id_extra = grp.id_base + 2,
                .color_text = theme.colors.text_primary,
                .gravity_y = 0.5,
            });

            // Flexible spacer absorbs the slack so the status + button keep
            // their natural size (label was expanding and squeezing the button
            // to a clipped sliver for long labels like "Torrent / Magnet").
            { var sp = dvui.box(@src(), .{}, .{ .id_extra = grp.id_base + 6, .expand = .horizontal }); sp.deinit(); }

            {
                // Status as quiet text — success only when set, secondary
                // otherwise. No glyph, no fill.
                const sl: []const u8 = if (is_reg) "Default" else "Not set";
                _ = dvui.label(@src(), "{s}", .{sl}, .{
                    .id_extra = grp.id_base + 3,
                    .color_text = if (is_reg) theme.colors.success else theme.colors.text_tertiary,
                    .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
                    .gravity_y = 0.5,
                });
            }

            if (!is_reg) {
                if (dvui.button(@src(), "Register", .{}, .{
                    .id_extra = grp.id_base + 4,
                    .color_fill = if (pending) theme.colors.bg_elevated else theme.colors.accent,
                    .color_text = if (pending) theme.colors.text_secondary else theme.colors.text_on_accent,
                    .corner_radius = theme.dims.rad_md,
                    .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                    .min_size_content = .{ .w = 76, .h = 0 },
                    .gravity_y = 0.5,
                })) {
                    if (!pending) triggerGroupAction(gi, true);
                }
            } else {
                if (dvui.button(@src(), "Remove", .{}, .{
                    .id_extra = grp.id_base + 4,
                    .color_fill = TRANSPARENT,
                    .color_text = if (pending) theme.colors.text_tertiary else theme.colors.danger,
                    .corner_radius = theme.dims.rad_md,
                    .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                    .min_size_content = .{ .w = 76, .h = 0 },
                    .gravity_y = 0.5,
                })) {
                    if (!pending) triggerGroupAction(gi, false);
                }
            }
        }

        _ = dvui.label(@src(), "{s}", .{grp.desc}, .{
            .id_extra = grp.id_base + 5,
            .color_text = theme.colors.text_tertiary,
            .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = 0 },
        });
    }
}
