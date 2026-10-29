//! Native wallpaper browser; gallery-dl owns site extraction and authentication.
const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const io = @import("../core/io_global.zig");
const alloc = @import("../core/alloc.zig").allocator;
const workers = @import("../core/workers.zig");
const pure = @import("wallpapers_pure.zig");
const theme = @import("../ui/theme.zig");
const components = @import("../ui/components.zig");
const filters = @import("../ui/browse_filters.zig");
const images = @import("../ui/anime_images.zig");
const db = @import("../core/db.zig");
const bounded = @import("../core/bounded_process.zig");
const gallery = @import("gallerydl.zig");
const Source = pure.Source;
var mutex: @import("../core/sync.zig").Mutex = .{};
var rows: std.ArrayList(pure.Row) = .empty;
var count: usize = 0;
var pending: usize = 0;
var failures: usize = 0;
var generation: std.atomic.Value(u32) = .init(0);
var loaded = false;
var selected: Source = .all;
var query: pure.Field(1024) = .{};
var page: u32 = 1;
var more = true;
var preview: ?usize = null;
var actual_size = false;
var show_filmstrip = true;
const full_image = @import("../ui/wallpaper_image.zig");
const desktop = @import("wallpaper_desktop.zig");
var motion: @import("../ui/media_preview.zig").Player = .{};
var apply_options = false;
var fill_desktop = true;
var configured = false;
var templates: [4096]u8 = @splat(0);
var browser_index: usize = 0;
const browsers = [_][]const u8{ "No browser cookies", "chrome", "firefox", "safari", "edge", "brave" };
const default_templates = "https://www.flickr.com/search/?text={query}\nhttps://www.artstation.com/search?query={query}\nhttps://www.deviantart.com/search?q={query}";
fn readSetting(key: []const u8, out: []u8) usize {
    const stmt = db.prepare("SELECT value FROM config WHERE key=?1") orelse return 0;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, key);
    if (db.step(stmt) != db.c.SQLITE_ROW) return 0;
    const value = db.columnText(stmt, 0) orelse return 0;
    const n = @min(value.len, out.len);
    @memcpy(out[0..n], value[0..n]);
    return n;
}
fn saveSetting(key: []const u8, value: []const u8) bool {
    const stmt = db.prepare("INSERT OR REPLACE INTO config(key,value) VALUES(?1,?2)") orelse return false;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, key);
    db.bindText(stmt, 2, value);
    return db.step(stmt) == db.c.SQLITE_DONE;
}
fn configure() void {
    if (configured) return;
    configured = true;
    const n = readSetting("wallpaper_gallery_searches", templates[0 .. templates.len - 1]);
    if (n == 0) @memcpy(templates[0..default_templates.len], default_templates);
    var buf: [32]u8 = undefined;
    const b = buf[0..readSetting("wallpaper_gallery_browser", &buf)];
    for (browsers, 0..) |name, i| if (std.mem.eql(u8, name, b)) {
        browser_index = i;
        break;
    };
    _ = gallery.binary(); // Resolve on owner thread before parallel jobs.
}
const Job = struct { gen: u32, source: Source, url: pure.Field(4096) = .{}, browser: pure.Field(32) = .{}, page: u32 = 1 };
fn finish(job: Job, result: []const pure.Row, failed: bool) void {
    mutex.lock();
    defer mutex.unlock();
    if (generation.load(.acquire) != job.gen) return;
    if (failed) failures += 1;
    const before = count;
    for (result) |row| {
        var duplicate = false;
        for (rows.items[0..count]) |*old| if (std.mem.eql(u8, old.original.text(), row.original.text())) {
            duplicate = true;
            break;
        };
        if (!duplicate) {
            rows.append(alloc, row) catch {
                failures += 1;
                break;
            };
            count = rows.items.len;
        }
    }
    if (result.len >= 24 and count > before) more = true;
    pending -|= 1;
    state.wakeUi();
}
const Batch = struct { jobs: [17]Job, len: usize };
fn runBatch(batch: *Batch) void {
    defer alloc.destroy(batch);
    @import("browse_fanout.zig").run(Job, batch.jobs[0..batch.len], {}, performJob, .{
        .limit = 4,
        .cancel_epoch = .{ .epoch32 = .{ .value = &generation, .expected = batch.jobs[0].gen } },
    });
}
fn performJob(_: void, job: Job) void {
    worker(job);
}
fn worker(job: Job) void {
    if (generation.load(.acquire) != job.gen or workers.isQuitting()) return;
    const buffer = alloc.alloc(u8, 4 * 1024 * 1024) catch {
        finish(job, &.{}, true);
        return;
    };
    defer alloc.free(buffer);
    const cancel: bounded.CancelEpoch = .{ .epoch32 = .{ .value = &generation, .expected = job.gen } };
    var private_url: [8192]u8 = undefined;
    defer @memset(&private_url, 0);
    const request_url = if (job.source == .wallhaven) authenticatedWallhavenUrl(job.url.text(), &private_url) else job.url.text();
    const body = if (job.source == .wallhaven)
        @import("reliable_fetch.zig").fetch(request_url, buffer, .{ .timeout_secs = 8, .connect_timeout_secs = 3, .impersonate = false, .cancel_epoch = cancel, .secret_url = true })
    else blk: {
        var range_buf: [40]u8 = undefined;
        const range = std.fmt.bufPrint(&range_buf, "{d}-{d}", .{ (job.page - 1) * 24 + 1, job.page * 24 }) catch unreachable;
        var config_buf: [1024]u8 = undefined;
        const config_path = authPath(&config_buf);
        var args: [24][]const u8 = undefined;
        var n: usize = 0;
        for ([_][]const u8{ gallery.binary(), "--no-input", "--resolve-json", "--range", range, "--retries", "0", "--http-timeout", "5" }) |arg| {
            args[n] = arg;
            n += 1;
        }
        if (job.browser.len > 0) {
            args[n] = "--cookies-from-browser";
            args[n + 1] = job.browser.text();
            n += 2;
        }
        if (io.cwdAccess(config_path, .{})) {
            args[n] = "--config";
            args[n + 1] = config_path;
            n += 2;
        } else |_| {}
        const dpi = @import("dpi_bypass.zig");
        if (dpi.enabled() and dpi.isRunning()) {
            args[n] = "--proxy";
            args[n + 1] = "http://127.0.0.1:8881";
            n += 2;
        }
        args[n] = "--";
        args[n + 1] = job.url.text();
        n += 2;
        const result = bounded.run(args[0..n], buffer, .{ .timeout_ms = 30_000, .cancel_epoch = cancel });
        break :blk if (result.ok() and result.exit_code == 0) result.output else null;
    };
    const data = body orelse {
        finish(job, &.{}, true);
        return;
    };
    const parsed = alloc.alloc(pure.Row, 24) catch {
        finish(job, &.{}, true);
        return;
    };
    defer alloc.free(parsed);
    const n = pure.parse(alloc, job.source, data, parsed) catch {
        finish(job, &.{}, true);
        return;
    };
    finish(job, parsed[0..n], false);
}
pub fn search(text: []const u8) void {
    configure();
    const local = std.fs.path.isAbsolute(text);
    if (pure.urlExtension(text)) |ext| if (local or pure.mediaUrl(text)) {
        _ = generation.fetchAdd(1, .acq_rel);
        closeGallery();
        mutex.lock();
        rows.clearRetainingCapacity();
        var row: pure.Row = .{ .media = pure.mediaKind(ext) };
        row.original.set(text);
        row.extension.set(ext);
        row.page.set(if (local) "" else text);
        if (row.media != .video) row.preview.set(text);
        rows.append(alloc, row) catch {};
        count = rows.items.len;
        pending = 0;
        failures = 0;
        more = false;
        loaded = true;
        mutex.unlock();
        query.set(text);
        return;
    };
    query.set(text);
    page = 1;
    closeGallery();
    start(false);
}
fn start(append: bool) void {
    const gen = generation.fetchAdd(1, .acq_rel) +% 1;
    var jobs: [17]Job = undefined;
    var n: usize = 0;
    const is_url = pure.publicUrl(query.text());
    if (!is_url and (selected == .all or selected == .wallhaven)) {
        var encoded: [3072]u8 = undefined;
        const q = @import("../core/http.zig").urlEncode(query.text(), &encoded);
        jobs[n] = .{ .gen = gen, .source = .wallhaven, .page = page };
        var url: [4096]u8 = undefined;
        jobs[n].url.set(std.fmt.bufPrint(&url, "https://wallhaven.cc/api/v1/search?q={s}&purity=100&sorting={s}&page={d}", .{ q, if (query.len == 0) "toplist" else "relevance", page }) catch "");
        n += 1;
    }
    if ((is_url or selected == .gallery or (selected == .all and query.len > 0)) and gallery.available()) {
        var lines = std.mem.splitScalar(u8, std.mem.sliceTo(&templates, 0), '\n');
        while (n < jobs.len) {
            const template = if (is_url) "" else std.mem.trim(u8, lines.next() orelse break, " \r\t");
            var url: [4096]u8 = undefined;
            const target = pure.expand(template, query.text(), &url) orelse continue;
            jobs[n] = .{ .gen = gen, .source = .gallery, .page = page };
            jobs[n].url.set(target);
            if (browser_index > 0) jobs[n].browser.set(browsers[browser_index]);
            n += 1;
            if (is_url) break;
        }
    }
    mutex.lock();
    if (!append) {
        rows.clearRetainingCapacity();
        count = 0;
    }
    pending = n;
    failures = if (n == 0) 1 else 0;
    more = false;
    mutex.unlock();
    loaded = true;
    if (n == 0) return;
    const batch = alloc.create(Batch) catch {
        for (jobs[0..n]) |job| finish(job, &.{}, true);
        return;
    };
    batch.len = n;
    @memcpy(batch.jobs[0..n], jobs[0..n]);
    workers.spawn(runBatch, .{batch}) catch {
        alloc.destroy(batch);
        for (jobs[0..n]) |job| finish(job, &.{}, true);
    };
}
fn external(source: Source) void {
    var encoded: [3072]u8 = undefined;
    const q = @import("../core/http.zig").urlEncode(query.text(), &encoded);
    var url: [4096]u8 = undefined;
    const target = std.fmt.bufPrint(&url, "{s}{s}{s}", .{ if (source == .pexels) "https://www.pexels.com/search/" else "https://unsplash.com/s/photos/", q, if (source == .pexels) "/" else "" }) catch return;
    @import("../ui/settings.zig").openExternal(target);
}
fn download(row: pure.Row) void {
    if (@import("downloads.zig").startUrl(row.original.text())) state.showToast("Wallpaper added to Downloads") else state.showToast("Choose a download folder in Settings");
}
pub fn renderContent() void {
    configure();
    desktop.poll();
    if (!loaded) search("");
    if (preview == null) full_image.releaseIfClosed();
    var toolbar = filters.begin(@src());
    if (preview != null) {
        renderGallery(&toolbar);
        return;
    }
    for ([_]Source{ .all, .wallhaven, .gallery }) |source| {
        const name: []const u8 = switch (source) {
            .all => "All",
            .wallhaven => "Wallhaven",
            .gallery => "gallery-dl",
            else => unreachable,
        };
        if (filters.item(@src(), .{ .id = @intFromEnum(source), .label = name, .presentation = .label, .active = selected == source })) {
            selected = source;
            page = 1;
            start(false);
        }
    }
    for ([_]Source{ .pexels, .unsplash }) |source| if (filters.item(@src(), .{ .id = @intFromEnum(source), .label = if (source == .pexels) "Pexels" else "Unsplash", .icon = icons.tvg.lucide.@"external-link", .presentation = .icon_label })) external(source);
    if (components.iconButton(@src(), icons.tvg.lucide.@"refresh-cw", "Refresh wallpapers", false)) {
        page = 1;
        start(false);
    }
    if (components.iconButton(@src(), icons.tvg.lucide.settings, "Wallpaper sources and accounts", false)) @import("../ui/connections.zig").editWallpapers();
    mutex.lock();
    const total = count;
    const busy = pending > 0;
    const failed = failures;
    const has_more = more;
    mutex.unlock();
    if (busy) dvui.spinner(@src(), .{ .min_size_content = theme.iconSize(.sm), .gravity_y = 0.5 });
    if (failed > 0) {
        if (components.iconButton(@src(), icons.tvg.lucide.@"circle-alert", "Some sources unavailable · check account or retry", false)) @import("../ui/connections.zig").editWallpapers();
    }
    toolbar.deinit();
    if (total == 0) {
        if (busy) components.coverSkeletonGrid(@src(), 95000, 3, 240, 150, 28, 3) else components.emptyState(icons.tvg.lucide.image, "No wallpapers found", if (failed > 0) "Source unavailable. Retry or check Connect." else "Search for a theme or paste a gallery link.");
        return;
    }
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();
    const width = @max(240, scroll.data().contentRect().w);
    const cols: usize = @max(1, @as(usize, @intFromFloat(width / 340)));
    const w = (width / @as(f32, @floatFromInt(cols))) - 8;
    const h = w * 9 / 16;
    const pitch = h + 8;
    const row_count = (total + cols - 1) / cols;
    const visible = @import("tmdb_pure.zig").visibleRows(row_count, pitch, scroll.si.viewport.y, scroll.si.viewport.h, 1);
    if (visible.first > 0) {
        var gap = dvui.box(@src(), .{}, .{ .min_size_content = .{ .h = pitch * @as(f32, @floatFromInt(visible.first)) } });
        gap.deinit();
    }
    for (visible.first..visible.last) |r| {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = r, .expand = .horizontal });
        defer line.deinit();
        for (r * cols..@min(total, (r + 1) * cols)) |i| {
            mutex.lock();
            const row = rows.items[i];
            mutex.unlock();
            var card = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = i, .min_size_content = .{ .w = w, .h = h }, .max_size_content = .{ .w = w, .h = h }, .margin = dvui.Rect.all(4) });
            defer card.deinit();
            var button: dvui.ButtonWidget = undefined;
            button.init(@src(), .{}, .{ .id_extra = i, .min_size_content = .{ .w = w, .h = h }, .max_size_content = .{ .w = w, .h = h }, .padding = dvui.Rect.all(0), .background = true, .color_fill = theme.colors.bg_elevated, .corner_radius = theme.dims.rad_md });
            button.processEvents();
            button.drawBackground();
            var stack = dvui.overlay(@src(), .{ .min_size_content = .{ .w = w, .h = h }, .max_size_content = .{ .w = w, .h = h } });
            if (images.get(row.preview.text())) |tex| {
                const crop = @import("../ui/search_gallery_pure.zig").coverCrop(.{ .w = @floatFromInt(tex.width), .h = @floatFromInt(tex.height) }, .{ .w = w, .h = h });
                _ = dvui.image(@src(), .{ .source = .{ .texture = tex }, .uv = .{ .x = crop.x, .y = crop.y, .w = crop.w, .h = crop.h } }, .{ .min_size_content = .{ .w = w, .h = h }, .max_size_content = .{ .w = w, .h = h }, .corner_radius = theme.dims.rad_md });
            } else dvui.icon(@src(), "Wallpaper", icons.tvg.lucide.image, .{}, .{ .gravity_x = 0.5, .gravity_y = 0.5, .min_size_content = theme.iconSize(.lg), .color_text = theme.colors.text_tertiary });
            if (row.media != .image) {
                _ = dvui.label(@src(), "{s}", .{if (row.media == .gif) "GIF" else "VIDEO"}, .{ .gravity_x = 1, .gravity_y = 0, .padding = dvui.Rect.all(6), .background = true, .color_fill = theme.playerGlass(200), .color_text = .white, .font = dvui.themeGet().font_body.withSize(11) });
            }
            if (button.hovered()) {
                var caption = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 1, .expand = .horizontal, .background = true, .color_fill = theme.playerGlass(210), .padding = dvui.Rect.all(8) });
                _ = dvui.label(@src(), "{d} × {d}", .{ row.width, row.height }, .{ .font = dvui.themeGet().font_body.withSize(12), .color_text = .white });
                caption.deinit();
            }
            stack.deinit();
            if (button.clicked()) openGallery(i);
            button.drawFocus();
            button.deinit();
        }
    }
    if (visible.last < row_count) {
        var gap = dvui.box(@src(), .{}, .{ .min_size_content = .{ .h = pitch * @as(f32, @floatFromInt(row_count - visible.last)) } });
        gap.deinit();
    }
    if (pure.shouldLoadNext(row_count, pitch, scroll.si.viewport.y, scroll.si.viewport.h, busy, has_more)) {
        page += 1;
        start(true);
    }
}
fn openGallery(index: usize) void {
    motion.deinit();
    mutex.lock();
    const row = if (index < count) rows.items[index] else pure.Row{};
    mutex.unlock();
    if (row.media != .image) _ = motion.start(row.original.text(), row.page.text());
    preview = index;
    actual_size = false;
    full_image.reset();
    dvui.focusWidget(null, null, null);
}
fn closeGallery() void {
    motion.deinit();
    preview = null;
    full_image.reset();
}
fn moveGallery(direction: i32) void {
    mutex.lock();
    const total = count;
    mutex.unlock();
    if (total == 0) return;
    const current = preview orelse return;
    openGallery(pure.galleryIndex(current, total, direction) orelse return);
}
pub fn galleryKey(key: dvui.enums.Key) bool {
    if (preview == null or state.app.browse_source != .Wallpapers or state.app.router.current != .browse) return false;
    switch (key) {
        .left => moveGallery(-1),
        .right => moveGallery(1),
        .escape => closeGallery(),
        else => return false,
    }
    return true;
}
fn renderGallery(toolbar: anytype) void {
    mutex.lock();
    const total = count;
    const index = @min(preview orelse 0, total -| 1);
    const row = if (total > 0) rows.items[index] else pure.Row{};
    mutex.unlock();
    if (total == 0) {
        closeGallery();
        toolbar.deinit();
        return;
    }
    if (components.iconButton(@src(), icons.tvg.lucide.@"arrow-left", "Back to wallpapers · Esc", false)) closeGallery();
    if (components.iconButton(@src(), icons.tvg.lucide.@"chevron-left", "Previous · Left arrow", false)) moveGallery(-1);
    _ = dvui.label(@src(), "{d} / {d}", .{ index + 1, total }, .{ .gravity_y = 0.5, .color_text = theme.colors.text_secondary });
    if (components.iconButton(@src(), icons.tvg.lucide.@"chevron-right", "Next · Right arrow", false)) moveGallery(1);
    if (row.media == .image and components.iconButton(@src(), icons.tvg.lucide.@"maximize-2", "Fit / actual size · scroll to pan", actual_size)) {
        actual_size = !actual_size;
        dvui.focusWidget(null, null, null);
    }
    if (row.media != .image and components.iconButton(@src(), if (motion.paused) icons.tvg.lucide.play else icons.tvg.lucide.pause, "Play / pause motion preview", false)) motion.togglePause();
    if (components.iconButton(@src(), icons.tvg.lucide.monitor, "Set as desktop wallpaper", apply_options)) apply_options = !apply_options;
    if (components.iconButton(@src(), icons.tvg.lucide.images, "Show thumbnail strip", show_filmstrip)) {
        show_filmstrip = !show_filmstrip;
        dvui.focusWidget(null, null, null);
    }
    if (components.iconButton(@src(), icons.tvg.lucide.download, "Download original", false)) {
        download(row);
        dvui.focusWidget(null, null, null);
    }
    if (components.iconButton(@src(), icons.tvg.lucide.@"external-link", "Open source / photographer", false)) @import("../ui/settings.zig").openExternal(row.page.text());
    if (preview == null or preview.? != index) {
        toolbar.deinit();
        return;
    }
    const original = if (row.media == .image) full_image.get(row.original.text(), row.page.text()) else null;
    if (row.media == .image and original == null) {
        if (full_image.failed()) {
            if (components.iconButton(@src(), icons.tvg.lucide.@"refresh-cw", "Original unavailable · retry", false)) full_image.reset();
        } else dvui.spinner(@src(), .{ .gravity_y = 0.5, .min_size_content = theme.iconSize(.sm) });
    }
    toolbar.deinit();
    if (apply_options) {
        var apply_bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = dvui.Rect.all(8) });
        if (components.iconButton(@src(), icons.tvg.lucide.@"maximize-2", "Fill desktop", fill_desktop)) fill_desktop = true;
        if (components.iconButton(@src(), icons.tvg.lucide.@"minimize-2", "Fit desktop", !fill_desktop)) fill_desktop = false;
        if (dvui.button(@src(), if (row.media == .image) "Apply wallpaper" else "Apply live wallpaper", .{}, .{})) desktop.request(row, fill_desktop);
        if (desktop.snapshot() == .active or desktop.snapshot() == .downloading or desktop.snapshot() == .applying) {
            if (components.iconButton(@src(), icons.tvg.lucide.square, "Stop wallpaper / cancel", false)) desktop.stop();
        }
        apply_bar.deinit();
        if (desktop.label().len > 0) components.bodyText(@src(), desktop.label(), theme.colors.text_secondary);
    }
    // Render the small cached image immediately, then replace it with the original.
    var canvas = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .color_fill = .black });
    {
        const view_height = @max(1, canvas.data().contentRect().h - @as(f32, if (show_filmstrip) 80 else 0));
        var view = dvui.scrollArea(@src(), .{ .horizontal = .auto, .vertical = .auto }, .{
            .expand = .horizontal,
            .min_size_content = .{ .h = view_height },
            .max_size_content = .{ .w = dvui.max_float_safe, .h = view_height },
        });
        const available = view.data().contentRect();
        const tex = original orelse images.get(row.preview.text());
        if (row.media != .image) {
            const w = @min(available.w, available.h * 16 / 9);
            if (!motion.draw(w, w * 9 / 16)) {
                if (motion.failed) {
                    if (dvui.button(@src(), "Retry motion preview", .{}, .{})) _ = motion.start(row.original.text(), row.page.text());
                } else dvui.spinner(@src(), .{ .gravity_x = 0.5, .gravity_y = 0.5 });
            }
        } else if (tex) |texture| {
            const tw: f32 = @floatFromInt(texture.width);
            const th: f32 = @floatFromInt(texture.height);
            const fit = @max(0.01, @min(available.w / tw, available.h / th));
            const scale = if (actual_size and original != null) 1 / dvui.windowNaturalScale() else fit;
            const size: dvui.Size = .{ .w = tw * scale, .h = th * scale };
            _ = dvui.image(@src(), .{ .source = .{ .texture = texture } }, .{ .gravity_x = 0.5, .gravity_y = 0.5, .min_size_content = size, .max_size_content = .{ .w = size.w, .h = size.h } });
        } else dvui.icon(@src(), "Wallpaper", icons.tvg.lucide.image, .{}, .{ .gravity_x = 0.5, .gravity_y = 0.5, .color_text = theme.colors.text_tertiary });
        view.deinit();
    }
    if (show_filmstrip) {
        var strip = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5, .padding = dvui.Rect.all(8) });
        const slots: usize = @max(1, @as(usize, @intFromFloat(@max(100, canvas.data().contentRect().w - 16) / 100)));
        const first = @min(index -| (slots / 2), total -| slots);
        for (first..@min(total, first + slots)) |i| {
            mutex.lock();
            const item = rows.items[i];
            mutex.unlock();
            var thumb: dvui.ButtonWidget = undefined;
            thumb.init(@src(), .{}, .{ .id_extra = i, .min_size_content = .{ .w = 84, .h = 48 }, .max_size_content = .{ .w = 84, .h = 48 }, .padding = dvui.Rect.all(2), .margin = dvui.Rect.all(2), .border = dvui.Rect.all(2), .color_border = if (i == index) theme.colors.accent else theme.colors.bg_elevated });
            thumb.processEvents();
            thumb.drawBackground();
            if (images.get(item.preview.text())) |texture| {
                const crop = @import("../ui/search_gallery_pure.zig").coverCrop(.{ .w = @floatFromInt(texture.width), .h = @floatFromInt(texture.height) }, .{ .w = 84, .h = 48 });
                _ = dvui.image(@src(), .{ .source = .{ .texture = texture }, .uv = .{ .x = crop.x, .y = crop.y, .w = crop.w, .h = crop.h } }, .{ .min_size_content = .{ .w = 84, .h = 48 }, .max_size_content = .{ .w = 84, .h = 48 } });
            }
            if (thumb.clicked()) openGallery(i);
            thumb.drawFocus();
            thumb.deinit();
        }
        strip.deinit();
    }
    canvas.deinit();
}
pub fn openGalleryForTest(index: usize) void {
    if (!@import("builtin").is_test) @compileError("test only");
    openGallery(index);
}
pub fn actualSizeForTest() void {
    if (!@import("builtin").is_test) @compileError("test only");
    actual_size = true;
}
fn authPath(buf: []u8) []const u8 {
    var config: [512]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/wallpaper-gallery-auth.json", .{@import("../core/paths.zig").configDir(&config)}) catch "";
}
// Pass authenticated URLs through curl stdin, never process arguments.
fn authenticatedWallhavenUrl(base: []const u8, out: []u8) []const u8 {
    var path: [1024]u8 = undefined;
    const bytes = io.cwdReadFileAlloc(authPath(&path), alloc, 64 * 1024) catch return base;
    defer {
        @memset(bytes, 0);
        alloc.free(bytes);
    }
    const doc = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return base;
    defer doc.deinit();
    var value = doc.value;
    for ([_][]const u8{ "extractor", "wallhaven", "api-key" }) |key| {
        if (value != .object) return base;
        value = value.object.get(key) orelse return base;
    }
    if (value != .string or value.string.len == 0) return base;
    var encoded: [4096]u8 = undefined;
    defer @memset(&encoded, 0);
    const key = @import("audio_sources_pure.zig").encode(&encoded, value.string) orelse return base;
    return std.fmt.bufPrint(out, "{s}&apikey={s}", .{ base, key }) catch base;
}
var auth_site: [64]u8 = @splat(0);
var auth_field: [64]u8 = @splat(0);
var auth_value: [4096]u8 = @splat(0);
fn saveAuth() bool {
    const site = std.mem.sliceTo(&auth_site, 0);
    const field = std.mem.sliceTo(&auth_field, 0);
    const value = std.mem.sliceTo(&auth_value, 0);
    var path_buf: [1024]u8 = undefined;
    const path = authPath(&path_buf);
    const existing = io.cwdReadFileAlloc(path, alloc, 64 * 1024) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return false,
    };
    defer if (existing) |bytes| {
        @memset(bytes, 0);
        alloc.free(bytes);
    };
    const json = pure.authConfig(alloc, existing orelse "", site, field, value) catch return false;
    defer {
        @memset(json, 0);
        alloc.free(json);
    }
    @import("../core/secret_file.zig").write(path, json) catch return false;
    @memset(&auth_value, 0);
    return true;
}
var account_choice: usize = 1;
var credential_choice: usize = 0;
var show_search_sources = false;
var show_credentials = false;
const account_names = [_][]const u8{ "Wallhaven", "Flickr", "ArtStation", "DeviantArt", "Pixiv", "Reddit", "Other" };
const account_ids = [_][]const u8{ "wallhaven", "flickr", "artstation", "deviantart", "pixiv", "reddit", "" };
const account_urls = [_][]const u8{ "https://wallhaven.cc", "https://www.flickr.com", "https://www.artstation.com", "https://www.deviantart.com", "https://www.pixiv.net", "https://www.reddit.com" };
const credential_names = [_][]const u8{ "API key", "Access token", "Refresh token", "Username", "Password", "Custom field" };
const credential_fields = [_][]const u8{ "api-key", "access-token", "refresh-token", "username", "password", "" };
pub fn renderConnections() void {
    configure();
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();
    var content = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = dvui.Rect.all(16) });
    defer content.deinit();
    components.sectionHeader("Wallpaper accounts");
    components.bodyText(@src(), if (gallery.available()) "gallery-dl is ready" else "Install gallery-dl to connect more sources", theme.colors.text_secondary);
    var site_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    if (dvui.dropdown(@src(), &account_names, .{ .choice = &account_choice }, .{}, .{})) @memset(&auth_value, 0);
    if (account_choice < account_urls.len and components.actionButton(@src(), "Sign in", .primary, 98004)) @import("../ui/settings.zig").openExternal(account_urls[account_choice]);
    if (components.iconButton(@src(), icons.tvg.lucide.info, "Supported sites and account setup", false)) @import("../ui/settings.zig").openExternal("https://github.com/mikf/gallery-dl/blob/master/docs/supportedsites.md");
    site_row.deinit();
    if (account_choice < account_urls.len) {
        @memset(&auth_site, 0);
        const id = account_ids[account_choice];
        @memcpy(auth_site[0..id.len], id);
    } else {
        var site = dvui.textEntry(@src(), .{ .text = .{ .buffer = &auth_site }, .placeholder = "Source ID" }, .{ .expand = .horizontal });
        site.deinit();
    }
    components.bodyText(@src(), "Sign in on the source, then select that browser.", theme.colors.text_secondary);
    var browser_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    _ = dvui.dropdown(@src(), &browsers, .{ .choice = &browser_index }, .{}, .{});
    if (components.actionButton(@src(), "Save", .primary, 98002)) {
        if (saveSetting("wallpaper_gallery_browser", browsers[browser_index])) state.showToast("Browser login preference saved");
    }
    browser_row.deinit();
    if (components.actionButton(@src(), if (show_credentials) "Hide API credentials" else "API credentials", .secondary, 98005)) show_credentials = !show_credentials;
    if (show_credentials) {
        if (dvui.dropdown(@src(), &credential_names, .{ .choice = &credential_choice }, .{}, .{})) @memset(&auth_value, 0);
        if (credential_choice < credential_fields.len - 1) {
            @memset(&auth_field, 0);
            const field = credential_fields[credential_choice];
            @memcpy(auth_field[0..field.len], field);
        } else {
            var field = dvui.textEntry(@src(), .{ .text = .{ .buffer = &auth_field }, .placeholder = "Credential field" }, .{ .expand = .horizontal });
            field.deinit();
        }
        var value = dvui.textEntry(@src(), .{ .text = .{ .buffer = &auth_value }, .placeholder = "Credential value", .password_char = "•" }, .{ .expand = .horizontal });
        value.deinit();
        var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        if (components.actionButton(@src(), "Save credential", .primary, 98003)) {
            state.showToast(if (auth_value[0] == 0) "Enter a credential value" else if (saveAuth()) "Credential saved locally" else "Could not save credential");
        }
        if (components.iconButton(@src(), icons.tvg.lucide.@"trash-2", "Remove this saved credential", false)) {
            @memset(&auth_value, 0);
            state.showToast(if (saveAuth()) "Credential removed" else "Could not remove credential");
        }
        actions.deinit();
    }
    if (components.actionButton(@src(), if (show_search_sources) "Hide search sources" else "Search sources", .secondary, 98006)) show_search_sources = !show_search_sources;
    if (show_search_sources) {
        components.bodyText(@src(), "Up to 16 search URLs, one per line. {query} inserts keywords.", theme.colors.text_secondary);
        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &templates }, .multiline = true }, .{ .expand = .horizontal, .min_size_content = .{ .h = 100 } });
        te.deinit();
        if (components.actionButton(@src(), "Save search sources", .primary, 98007)) {
            if (saveSetting("wallpaper_gallery_searches", std.mem.sliceTo(&templates, 0))) state.showToast("Search sources saved");
        }
    }
}
pub fn setNativeFixtureForTest() void {
    if (!@import("builtin").is_test) @compileError("test only");
    preview = null;
    apply_options = false;
    configured = true;
    loaded = true;
    rows.resize(alloc, 6) catch unreachable;
    count = 6;
    more = false;
    pending = 0;
    failures = 0;
    for (rows.items[0..count], 0..) |*row, i| {
        row.* = .{ .width = 3840, .height = 2160 };
        var url: [128]u8 = undefined;
        row.preview.set(std.fmt.bufPrint(&url, "https://fixture.test/wallpaper-{d}.jpg", .{i}) catch unreachable);
        row.original.set(row.preview.text());
        row.page.set(row.preview.text());
    }
}
test "Browse regression wallpaper parser module" {
    _ = pure;
}

test "Browse regression wallpaper merge deduplicates and rejects superseded work" {
    const old_gen = generation.load(.acquire);
    defer {
        deinit();
        generation.store(old_gen, .release);
        count = 0;
        pending = 0;
        failures = 0;
        loaded = false;
    }
    generation.store(42, .release);
    rows.clearRetainingCapacity();
    count = 0;
    pending = 2;
    failures = 0;
    var row: pure.Row = .{};
    row.original.set("https://example.org/image.jpg");
    const job: Job = .{ .gen = 42, .source = .wallhaven };
    finish(job, &.{ row, row }, false);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 1), pending);
    generation.store(43, .release);
    finish(job, &.{row}, true);
    try std.testing.expectEqual(@as(usize, 0), failures);
    try std.testing.expectEqual(@as(usize, 1), pending);
    finish(.{ .gen = 43, .source = .gallery }, &.{row}, false);
    try std.testing.expectEqual(@as(usize, 0), pending);
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "Browse regression live wallpaper API and gallery metadata" {
    if (io.getenv("OPAL_TEST_WALLPAPER_FILE")) |path| {
        const data = try io.cwdReadFileAlloc(path, alloc, 4 * 1024 * 1024);
        defer alloc.free(data);
        const result = try alloc.alloc(pure.Row, 24);
        defer alloc.free(result);
        const n = try pure.parse(alloc, .wallhaven, data, result);
        try std.testing.expectEqual(@as(usize, 24), n);
    } else return error.SkipZigTest;
    if (io.getenv("OPAL_TEST_GALLERY_FILE")) |path| {
        const data = try io.cwdReadFileAlloc(path, alloc, 4 * 1024 * 1024);
        defer alloc.free(data);
        const result = try alloc.alloc(pure.Row, 24);
        defer alloc.free(result);
        const n = try pure.parse(alloc, .gallery, data, result);
        try std.testing.expect(n >= 2);
        for (result[0..n]) |*row| try std.testing.expect(pure.publicUrl(row.preview.text()));
    }
}

/// Release metadata after all catalog workers have joined.
pub fn deinit() void {
    motion.deinit();
    rows.deinit(alloc);
    rows = .empty;
    count = 0;
    loaded = false;
}
test "Browse regression wallpaper pagination grows past old cap and stops duplicate pages" {
    defer deinit();
    rows.clearRetainingCapacity();
    count = 0;
    const job: Job = .{ .gen = generation.load(.acquire), .source = .wallhaven };
    var row: pure.Row = .{};
    var url: [80]u8 = undefined;
    for (0..216) |i| {
        row.original.set(try std.fmt.bufPrint(&url, "https://example.org/{d}.jpg", .{i}));
        finish(job, &.{row}, false);
    }
    try std.testing.expectEqual(@as(usize, 216), count);
    more = false;
    const duplicates: [24]pure.Row = @splat(row);
    finish(job, &duplicates, false);
    try std.testing.expectEqual(@as(usize, 216), count);
    try std.testing.expect(!more);
}

pub fn tick() void {
    desktop.poll();
    if (state.app.router.current != .browse or state.app.browse_source != .Wallpapers) motion.deinit();
}

pub fn setApplyFixtureForTest() void {
    if (!@import("builtin").is_test) @compileError("test only");
    apply_options = true;
}
pub fn setMotionFixtureForTest(path: []const u8) void {
    if (!@import("builtin").is_test) @compileError("test only");
    rows.items[2].original.set(path);
    rows.items[2].media = pure.mediaKind(pure.urlExtension(path) orelse "mp4");
    openGallery(2);
}
pub fn motionReadyForTest() bool {
    if (!@import("builtin").is_test) @compileError("test only");
    return motion.ready and !motion.failed;
}
