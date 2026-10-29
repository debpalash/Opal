//! Apply requests own immutable metadata. Downloads and desktop helpers run off UI.
const std = @import("std");
const builtin = @import("builtin");
const io = @import("../core/io_global.zig");
const alloc = @import("../core/alloc.zig").allocator;
const workers = @import("../core/workers.zig");
const bounded = @import("../core/bounded_process.zig");
const state = @import("../core/state.zig");
const model = @import("wallpapers_pure.zig");
const pure = @import("wallpaper_desktop_pure.zig");
const dvui = @import("dvui");
pub const Status = enum(u8) { idle, downloading, applying, active, applied, stopped, download_failed, invalid_media, apply_failed, missing_player, unsupported };
var status: std.atomic.Value(Status) = .init(.idle);
var busy: std.atomic.Value(bool) = .init(false);
var epoch: std.atomic.Value(u32) = .init(0);
const Job = struct { row: model.Row, fill: bool, generation: u32 };
var pending: ?Job = null; // UI owner only.
var announced: Status = .idle;
pub fn snapshot() Status {
    return status.load(.acquire);
}
pub fn label() []const u8 {
    return switch (snapshot()) {
        .idle => "",
        .downloading => "Preparing original…",
        .applying => "Applying wallpaper…",
        .active => "Live wallpaper · running while Opal is open",
        .applied => "Wallpaper applied",
        .stopped => "Live wallpaper stopped",
        .download_failed => "Could not download original. Try again.",
        .invalid_media => "Image could not be decoded",
        .apply_failed => "Desktop rejected the wallpaper. Check desktop permissions or installed helper.",
        .missing_player => "Install mpv (mpvpaper on supported Wayland desktops) to apply animated wallpapers.",
        .unsupported => "Animated wallpapers need X11 or a supported layer-shell Wayland desktop; GNOME/KDE Wayland are not supported.",
    };
}
pub fn request(row: model.Row, fill: bool) void {
    const gen = epoch.fetchAdd(1, .acq_rel) +% 1;
    pending = .{ .row = row, .fill = fill, .generation = gen };
    poll();
}
pub fn stop() void {
    pending = null;
    _ = epoch.fetchAdd(1, .acq_rel);
}
pub fn poll() void {
    if (pending) |job| if (!busy.load(.acquire)) {
        pending = null;
        busy.store(true, .release);
        status.store(.downloading, .release);
        workers.spawn(run, .{job}) catch {
            busy.store(false, .release);
            status.store(.apply_failed, .release);
        };
    };
    const now = snapshot();
    if (now != announced) {
        announced = now;
        if (now != .idle and now != .downloading and now != .applying) state.showToast(label());
    }
}
fn publish(value: Status) void {
    status.store(value, .release);
    state.wakeUi();
}
fn current(job: Job) bool {
    return !workers.isQuitting() and epoch.load(.acquire) == job.generation;
}
fn token(job: Job) bounded.CancelEpoch {
    return .{ .epoch32 = .{ .value = &epoch, .expected = job.generation } };
}
fn command(job: Job, argv: []const []const u8) bool {
    var output: [16384]u8 = undefined;
    return bounded.run(argv, &output, .{ .timeout_ms = 15_000, .cancel_epoch = token(job) }).ok();
}
fn findBinary(name: []const u8, out: []u8) ?[]const u8 {
    var exe: [1024]u8 = undefined;
    if (io.selfExeDirPath(&exe)) |dir| {
        const path = std.fmt.bufPrint(out, "{s}/{s}", .{ dir, name }) catch return null;
        if (io.cwdAccess(path, .{})) return path else |_| {}
    } else |_| {}
    var paths = std.mem.splitScalar(u8, io.getenv("PATH") orelse "", if (builtin.os.tag == .windows) ';' else ':');
    while (paths.next()) |dir| {
        if (dir.len == 0) continue;
        const path = std.fmt.bufPrint(out, "{s}/{s}", .{ dir, name }) catch continue;
        if (io.cwdAccess(path, .{})) return path else |_| {}
    }
    for ([_][]const u8{ "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin" }) |dir| {
        const path = std.fmt.bufPrint(out, "{s}/{s}", .{ dir, name }) catch continue;
        if (io.cwdAccess(path, .{})) return path else |_| {}
    }
    return null;
}
fn backend(animated: bool) pure.Backend {
    return switch (builtin.os.tag) {
        .macos => .mac,
        .windows => .windows,
        .linux => pure.linuxBackend(io.getenv("XDG_CURRENT_DESKTOP") orelse "", io.getenv("XDG_SESSION_TYPE") orelse (if (io.getenv("WAYLAND_DISPLAY") != null) "wayland" else "x11"), animated),
        else => .unsupported,
    };
}
fn run(job: Job) void {
    defer {
        busy.store(false, .release);
        state.wakeUi();
    }
    const animated = job.row.media != .image;
    const target = backend(animated);
    if (target == .unsupported) {
        publish(.unsupported);
        return;
    }
    var bin_buf: [1024]u8 = undefined;
    const live_process = animated or target == .wayland;
    const binary = if (live_process) findBinary(if (target == .wayland) "mpvpaper" else if (builtin.os.tag == .windows) "mpv.exe" else "mpv", &bin_buf) orelse {
        publish(.missing_player);
        return;
    } else "";
    var base: [512]u8 = undefined;
    var dir_buf: [768]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buf, "{s}/wallpapers", .{@import("../core/paths.zig").configDir(&base)}) catch {
        publish(.download_failed);
        return;
    };
    io.cwdMakePath(dir) catch {
        publish(.download_failed);
        return;
    };
    var path_buf: [1024]u8 = undefined;
    const ext = model.mediaExtension(job.row.extension.text()) orelse "jpg";
    const path = std.fmt.bufPrint(&path_buf, "{s}/{x}.{s}", .{ dir, std.hash.Wyhash.hash(0, job.row.original.text()), ext }) catch {
        publish(.download_failed);
        return;
    };
    const original = job.row.original.text();
    const local = std.fs.path.isAbsolute(original);
    if (!local) {
        if (io.cwdAccess(path, .{})) {} else |_| {
            const result = @import("reliable_fetch.zig").download(original, path, .{ .timeout_secs = 180, .connect_timeout_secs = 8, .max_filesize = 512 * 1024 * 1024, .secret_url = true, .impersonate = false, .referer = if (job.row.page.len > 0) job.row.page.text() else null, .cancel_epoch = token(job) });
            if (!result.ok()) {
                publish(if (current(job)) .download_failed else .stopped);
                return;
            }
        }
    }
    if (!current(job)) {
        publish(.stopped);
        return;
    }
    const media_path = if (local) original else path;
    publish(.applying);
    if (live_process) {
        var args: [32][]const u8 = undefined;
        const argv = pure.animatedArgs(target, binary, media_path, job.fill, &args) orelse {
            publish(.unsupported);
            return;
        };
        var process = bounded.StreamProcess.init(argv, .{ .timeout_ms = 365 * 24 * 60 * 60 * 1000, .max_output_bytes = 64 * 1024, .cancel_epoch = token(job), .cancel_flag = workers.quittingSignal() });
        process.start() catch {
            publish(.apply_failed);
            return;
        };
        publish(.active);
        if (process.stdout()) |stdout| {
            var output: [1024]u8 = undefined;
            while (true) {
                const n = io.read(stdout, &output) catch break;
                if (n == 0 or !process.noteOutput(n)) break;
            }
        }
        const result = process.finish();
        publish(if (!current(job) or result.cancelled) .stopped else .apply_failed);
        return;
    }
    // Normalize static originals to PNG so WebP also works with desktop APIs.
    const bytes = io.cwdReadFileAlloc(media_path, alloc, 32 * 1024 * 1024) catch {
        publish(.invalid_media);
        return;
    };
    defer alloc.free(bytes);
    const decoded = @import("../core/image_decode.zig").browserFrame(bytes) orelse {
        publish(.invalid_media);
        return;
    };
    defer decoded.deinit();
    var png_buf: [1024]u8 = undefined;
    const png = std.fmt.bufPrint(&png_buf, "{s}/{x}-desktop.png", .{ dir, std.hash.Wyhash.hash(0, original) }) catch {
        publish(.apply_failed);
        return;
    };
    const file = io.cwdCreateFile(png, .{ .truncate = true }) catch {
        publish(.apply_failed);
        return;
    };
    const Sink = struct {
        file: std.Io.File,
        failed: bool = false,
        fn write(ctx: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const ptr: [*]const u8 = @ptrCast(data.?);
            io.writeAll(self.file, ptr[0..@intCast(size)]) catch {
                self.failed = true;
            };
        }
    };
    var sink: Sink = .{ .file = file };
    const written = dvui.c.stbi_write_png_to_func(Sink.write, &sink, decoded.width, decoded.height, 4, decoded.pixels, decoded.width * 4);
    file.close(io.io());
    if (written == 0 or sink.failed or !current(job)) {
        publish(.apply_failed);
        return;
    }
    publish(if (applyStatic(job, target, png, dir)) .applied else .apply_failed);
}
fn applyStatic(job: Job, target: pure.Backend, path: []const u8, dir: []const u8) bool {
    const placement = if (job.fill) "fill" else "fit";
    var uri_buf: [3072]u8 = undefined;
    const uri = pure.fileUri(path, &uri_buf) orelse "";
    switch (target) {
        .mac => return command(job, &.{ "/usr/bin/osascript", "-l", "JavaScript", "-e", pure.mac_script, path, placement }),
        .windows => {
            var script_buf: [1024]u8 = undefined;
            const script = std.fmt.bufPrint(&script_buf, "{s}/apply-static.ps1", .{dir}) catch return false;
            io.cwdWriteFile(.{ .sub_path = script, .data = pure.windows_script }) catch return false;
            return command(job, &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-WallpaperPath", path, "-Placement", placement });
        },
        .gnome, .cinnamon, .mate => {
            const schema = switch (target) {
                .gnome => "org.gnome.desktop.background",
                .cinnamon => "org.cinnamon.desktop.background",
                else => "org.mate.background",
            };
            if (!command(job, &.{ "gsettings", "set", schema, if (target == .mate) "picture-filename" else "picture-uri", if (target == .mate) path else uri })) return false;
            if (target == .gnome) _ = command(job, &.{ "gsettings", "set", schema, "picture-uri-dark", uri });
            return command(job, &.{ "gsettings", "set", schema, "picture-options", if (job.fill) "zoom" else "scaled" });
        },
        .kde => {
            const quoted = std.json.Stringify.valueAlloc(alloc, uri, .{}) catch return false;
            defer alloc.free(quoted);
            const script = std.fmt.allocPrint(alloc, "desktops().forEach(function(d){{d.wallpaperPlugin='org.kde.image';d.currentConfigGroup=['Wallpaper','org.kde.image','General'];d.writeConfig('Image',{s});d.writeConfig('FillMode',{d});}});", .{ quoted, @as(u8, if (job.fill) 2 else 1) }) catch return false;
            defer alloc.free(script);
            var bin: [1024]u8 = undefined;
            const tool = findBinary("qdbus6", &bin) orelse findBinary("qdbus", &bin) orelse return false;
            return command(job, &.{ tool, "org.kde.plasmashell", "/PlasmaShell", "org.kde.PlasmaShell.evaluateScript", script });
        },
        .xfce => {
            var output: [16384]u8 = undefined;
            const result = bounded.run(&.{ "xfconf-query", "-c", "xfce4-desktop", "-l" }, &output, .{ .timeout_ms = 5000, .cancel_epoch = token(job) });
            if (!result.ok()) return false;
            var lines = std.mem.tokenizeAny(u8, result.output, "\r\n");
            var applied = false;
            while (lines.next()) |property| if (std.mem.endsWith(u8, property, "/last-image")) {
                if (!command(job, &.{ "xfconf-query", "-c", "xfce4-desktop", "-p", property, "-s", path })) return false;
                var style_buf: [2048]u8 = undefined;
                const style = std.fmt.bufPrint(&style_buf, "{s}/image-style", .{property[0 .. property.len - "/last-image".len]}) catch return false;
                if (!command(job, &.{ "xfconf-query", "-c", "xfce4-desktop", "-p", style, "-s", if (job.fill) "5" else "4" })) return false;
                applied = true;
            };
            return applied;
        },
        .x11 => return command(job, &.{ "feh", if (job.fill) "--bg-fill" else "--bg-max", path }),
        else => return false,
    }
}
test "Browse regression desktop wallpaper command policy" {
    _ = pure;
}
