//! First-class setup for the installed Jackett source; Jackett owns tracker auth.
const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const theme = @import("theme.zig");
const cc = @import("color_compat.zig");
const components = @import("components.zig");
const surfaces = @import("service_surfaces.zig");
const state = @import("../core/state.zig");
const sources = @import("../core/source_config.zig");
const alloc = @import("../core/alloc.zig").allocator;
const pure = @import("../services/jackett_pure.zig");
const sync = @import("../core/sync.zig");
const server = @import("../services/jackett_server.zig");

var base: [512]u8 = @splat(0);
var key: [512]u8 = @splat(0);
var selection: [512]u8 = @splat(0);
var initialized = false;
var revision: u64 = 0;
var catalog_revision: ?u64 = null;
var all_public = true;
var chosen: [pure.MAX_INDEXERS]bool = @splat(false);
const Result = struct {
    items: [pure.MAX_INDEXERS]pure.Indexer = undefined,
    count: usize = 0,
    message: [128]u8 = @splat(0),
    revision: u64 = 0,
    ready: bool = false,
    success: bool = false,
};
var result: Result = .{};
var mutex: sync.Mutex = .{};
var busy = std.atomic.Value(bool).init(false);
var message: [128]u8 = @splat(0);
var managed_attached = false;
var advanced = false;
pub var field_label_ids_for_test: [2]dvui.Id = undefined;
pub var field_bounds_for_test: [2]dvui.Rect.Physical = undefined;
pub var panel_bounds_for_test: dvui.Rect.Physical = .{};

pub fn setFixtureForTest(existing_server: bool) void {
    if (!@import("builtin").is_test) @compileError("test only");
    initialized = true;
    put(&base, "http://127.0.0.1:9117");
    put(&key, "owned-test-key");
    put(&selection, "nyaasi");
    advanced = existing_server;
    all_public = false;
    revision = 100;
    catalog_revision = if (existing_server) revision else null;
    result = .{};
    result.count = pure.parseCatalog(alloc, "<indexers><indexer id=\"nyaasi\" configured=\"true\"><title>Nyaa · anime</title><type>public</type></indexer><indexer id=\"torrentleech\" configured=\"true\"><title>TorrentLeech</title><type>private</type></indexer></indexers>", &result.items) catch unreachable;
    result.success = existing_server;
    chosen = @splat(false);
    chosen[0] = true;
    put(&message, "");
}

fn text(buffer: []const u8) []const u8 {
    return std.mem.sliceTo(buffer, 0);
}
fn put(out: []u8, value: []const u8) void {
    @memset(out, 0);
    @memcpy(out[0..@min(out.len - 1, value.len)], value[0..@min(out.len - 1, value.len)]);
}
pub fn configured() bool {
    var b: [512]u8 = undefined;
    var k: [512]u8 = undefined;
    var url: [2400]u8 = undefined;
    return pure.catalogUrl(sources.copyValue("jackett", "base", &b) orelse return false, sources.copyValue("jackett", "apikey", &k) orelse return false, &url) != null;
}

fn init() void {
    if (initialized) return;
    initialized = true;
    var fields: [12]sources.EntryFieldSnapshot = undefined;
    const count = sources.copyEntry("jackett", &fields) orelse 0;
    put(&base, "http://127.0.0.1:9117");
    put(&selection, "*");
    for (fields[0..count]) |*f| {
        if (f.value("base") orelse f.value("url")) |v| put(&base, v);
        if (f.value("apikey") orelse f.value("api_key")) |v| {
            if (!std.mem.eql(u8, v, "YOUR_API_KEY_HERE")) put(&key, v);
        }
        if (f.value("indexers")) |v| put(&selection, v);
    }
    all_public = std.mem.eql(u8, text(&selection), "*");
}

const Job = struct { base: [512]u8, key: [512]u8, revision: u64 };
fn worker(job: Job) void {
    defer {
        busy.store(false, .release);
        state.wakeUi();
    }
    var response: Result = .{ .revision = job.revision, .ready = true };
    defer {
        mutex.lock();
        result = response;
        mutex.unlock();
    }
    var url_buf: [2400]u8 = undefined;
    const url = pure.catalogUrl(text(&job.base), text(&job.key), &url_buf) orelse {
        put(&response.message, "Enter a valid server URL and API key.");
        return;
    };
    const body = alloc.alloc(u8, 256 * 1024) catch {
        put(&response.message, "Not enough memory.");
        return;
    };
    defer alloc.free(body);
    var headers: [4096]u8 = undefined;
    const fetched = @import("../services/reliable_fetch.zig").request(url, body, &headers, .{
        .timeout_secs = 8,
        .connect_timeout_secs = 4,
        .impersonate = false,
        .use_dpi_proxy = false,
        .secret_url = true,
        .follow_redirects = false,
        .max_filesize = 256 * 1024,
    });
    if (!fetched.ok()) {
        put(&response.message, if (fetched.status == 401 or fetched.status == 403) "Jackett rejected the API key." else "Cannot reach Jackett. Check its URL, API key and service.");
        return;
    }
    response.count = pure.parseCatalog(alloc, fetched.body, &response.items) catch {
        put(&response.message, "Invalid or oversized Jackett catalog. Check the server URL.");
        return;
    };
    response.success = true;
    put(&response.message, if (response.count == 0) "Connected. Add trackers in Jackett, then refresh." else "Connected. Choose trackers, then save.");
}

fn field(label: []const u8, buffer: []u8, password: bool, id: usize) void {
    var group = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = id, .expand = .horizontal, .margin = .{ .y = 6, .h = 4 } });
    defer group.deinit();
    if (@import("builtin").is_test) field_bounds_for_test[id] = group.data().borderRectScale().r;
    const before = std.hash.Wyhash.hash(0, text(buffer));
    const label_src = @src();
    if (@import("builtin").is_test) field_label_ids_for_test[id] = dvui.Id.extendId(dvui.parentGet().data().id, label_src, 0);
    components.bodyText(label_src, label, theme.colors.text_secondary);
    var entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = buffer }, .password_char = if (password) "•" else null }, .{
        .id_extra = id,
        .expand = .horizontal,
        .min_size_content = .{ .w = 180, .h = 24 },
        .color_fill = cc.wrap(theme.colors.bg_elevated),
        .color_text = cc.wrap(theme.colors.text_primary),
        .color_border = cc.wrap(theme.colors.border_subtle),
        .border = dvui.Rect.all(1),
        .corners = theme.dims.rad_sm,
    });
    if (before != std.hash.Wyhash.hash(0, text(buffer))) {
        revision +%= 1;
        catalog_revision = null;
        put(&message, "Test the edited connection before choosing trackers.");
    }
    entry.deinit();
}

fn save(catalog: *const Result) void {
    var url: [2400]u8 = undefined;
    if (pure.catalogUrl(text(&base), text(&key), &url) == null) {
        put(&message, "Enter a valid server URL and API key.");
        return;
    }
    var csv: [512]u8 = @splat(0);
    if (all_public) {
        put(&csv, "*");
    } else {
        if (catalog_revision != revision) {
            put(&message, "Test this connection before selecting trackers.");
            return;
        }
        var writer = std.Io.Writer.fixed(csv[0 .. csv.len - 1]);
        for (catalog.items[0..catalog.count], 0..) |*item, i| {
            if (!chosen[i] or !item.public) continue;
            if (writer.end > 0) writer.writeByte(',') catch {
                put(&message, "Too many selected trackers. Choose fewer, or use all public trackers.");
                return;
            };
            writer.writeAll(item.idSlice()) catch {
                put(&message, "Too many selected trackers. Choose fewer, or use all public trackers.");
                return;
            };
        }
    }
    const owned = server.snapshot();
    const managed = text(&owned.base).len > 0 and std.mem.eql(u8, text(&base), text(&owned.base));
    const json = std.json.Stringify.valueAlloc(alloc, .{ .base = text(&base), .apikey = text(&key), .indexers = text(&csv), .managed = if (managed) "true" else "false", .thread_count = "8" }, .{}) catch {
        put(&message, "Could not save connection.");
        return;
    };
    defer alloc.free(json);
    if (sources.install("jackett", json)) {
        put(&selection, text(&csv));
        put(&message, "Saved. Jackett trackers are available in torrent searches.");
    } else put(&message, "Could not save connection.");
}

fn refresh() void {
    if (busy.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
    put(&message, "Connecting…");
    @import("../core/workers.zig").spawn(worker, .{Job{ .base = base, .key = key, .revision = revision }}) catch {
        busy.store(false, .release);
        put(&message, "Could not start connection test.");
    };
}

fn manageTrackers() void {
    if (!pure.validBase(text(&base))) return;
    state.navigateToTab(.Web);
    @import("../services/browser.zig").navigate(text(&base));
}

fn card(src: std.builtin.SourceLocation) *dvui.BoxWidget {
    return dvui.box(src, .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = cc.wrap(theme.colors.bg_surface),
        .color_border = cc.wrap(theme.colors.border_subtle),
        .border = dvui.Rect.all(1),
        .corners = theme.dims.rad_md,
        .padding = dvui.Rect.all(16),
        .margin = .{ .y = 10 },
    });
}

pub fn render() void {
    init();
    const owned = server.snapshot();
    if (!owned.active) managed_attached = false;
    if (owned.ready and !managed_attached) {
        managed_attached = true;
        put(&base, text(&owned.base));
        put(&key, text(&owned.key));
        revision +%= 1;
        catalog_revision = null;
        var selected_buf: [512]u8 = undefined;
        put(&selection, sources.copyValue("jackett", "indexers", &selected_buf) orelse "*");
        all_public = std.mem.eql(u8, text(&selection), "*");
        refresh();
    }
    // Consume worker publication before drawing actions, never while holding a
    // lock across a button that can save or start another worker.
    mutex.lock();
    const view = result;
    result.ready = false;
    mutex.unlock();
    if (view.ready and view.revision == revision) {
        put(&message, text(&view.message));
        catalog_revision = if (view.success) revision else null;
        for (view.items[0..view.count], 0..) |*item, i| chosen[i] = item.public and pure.selected(text(&selection), item.idSlice());
    }
    const has_catalog = catalog_revision == revision;
    var public_count: usize = 0;
    if (has_catalog) for (view.items[0..view.count]) |item| {
        if (item.public) public_count += 1;
    };

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();
    const panel_width = @max(0, @min(840, scroll.data().contentRect().w - 32));
    var content = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .none,
        .gravity_x = 0.5,
        .min_size_content = .{ .w = panel_width },
        .max_size_content = .{ .w = panel_width, .h = std.math.floatMax(f32) },
        .padding = dvui.Rect.all(16),
    });
    defer content.deinit();
    if (@import("builtin").is_test) panel_bounds_for_test = content.data().borderRectScale().r;
    {
        var heading = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .h = 4 } });
        surfaces.iconTile(@src(), icons.tvg.lucide.magnet, theme.colors.accent, 24);
        dvui.labelNoFmt(@src(), "Jackett", .{}, .{ .font = dvui.themeGet().font_heading, .color_text = cc.wrap(theme.colors.text_primary), .gravity_y = 0.5, .margin = .{ .x = 10 }, .expand = .horizontal });
        const connected = owned.ready or (has_catalog and view.success);
        surfaces.badge(@src(), if (owned.ready) "Running" else if (owned.active) "Starting" else if (connected) "Connected" else "Stopped", if (connected) theme.colors.success else theme.colors.text_secondary);
        heading.deinit();
    }
    components.bodyText(@src(), "Your torrent sources, managed in Opal.", theme.colors.text_secondary);
    {
        var service = card(@src());
        dvui.labelNoFmt(@src(), "Managed by Opal", .{}, .{ .color_text = cc.wrap(theme.colors.text_primary) });
        components.bodyText(@src(), if (text(&owned.status).len > 0) text(&owned.status) else "Install once. Start, stop and manage your trackers here.", theme.colors.text_secondary);
        {
            var actions = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal });
            if (!owned.active) {
                if (components.actionButton(@src(), "Start Jackett", .primary, 10)) server.start();
            } else if (components.iconButton(@src(), icons.tvg.lucide.square, "Stop Jackett", false)) server.stop();
            if (owned.ready) {
                if (components.actionButton(@src(), "Manage trackers", .primary, 11)) manageTrackers();
            }
            if (components.iconButton(@src(), if (advanced) icons.tvg.lucide.@"chevron-up" else icons.tvg.lucide.server, "Existing server settings", advanced)) advanced = !advanced;
            actions.deinit();
        }
        if (advanced) {
            var connection = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .margin = .{ .y = 12 } });
            dvui.labelNoFmt(@src(), "Existing server", .{}, .{ .color_text = cc.wrap(theme.colors.text_primary) });
            field("Server URL", &base, false, 0);
            field("API key", &key, true, 1);
            var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 6 } });
            if (!busy.load(.acquire) and components.actionButton(@src(), "Connect", .secondary, 0)) refresh();
            if (components.actionButton(@src(), "Save connection", .primary, 1)) save(&view);
            if (components.iconButton(@src(), icons.tvg.lucide.settings, "Manage this server's trackers in Opal", false)) manageTrackers();
            actions.deinit();
            connection.deinit();
        }
        service.deinit();
    }
    {
        var trackers = card(@src());
        {
            var heading = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            dvui.labelNoFmt(@src(), "Trackers", .{}, .{ .font = dvui.themeGet().font_heading, .color_text = cc.wrap(theme.colors.text_primary), .expand = .horizontal, .gravity_y = 0.5 });
            if (has_catalog) {
                var count: [48]u8 = undefined;
                surfaces.badge(@src(), std.fmt.bufPrint(&count, "{d} public", .{public_count}) catch "Public", theme.colors.text_secondary);
            }
            if (busy.load(.acquire)) {
                components.bodyText(@src(), "Refreshing…", theme.colors.text_secondary);
            } else if (owned.ready or advanced or has_catalog) {
                if (components.iconButton(@src(), icons.tvg.lucide.@"refresh-cw", "Refresh trackers", false)) refresh();
            }
            if (has_catalog and components.iconButton(@src(), icons.tvg.lucide.save, "Save tracker selection", false)) save(&view);
            heading.deinit();
        }
        if (text(&message).len > 0) components.bodyText(@src(), text(&message), theme.colors.text_secondary);
        if (has_catalog and view.count > 0) {
            components.toggleRow(@src(), "Include all public trackers", null, &all_public);
            for (view.items[0..view.count], 0..) |*item, i| {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .expand = .horizontal, .padding = .{ .y = 3, .h = 3 } });
                if (item.public and !all_public) {
                    components.toggleRow(@src(), item.nameSlice(), null, &chosen[i]);
                } else {
                    dvui.icon(@src(), "", if (item.public) icons.tvg.lucide.check else icons.tvg.lucide.lock, .{}, .{ .min_size_content = theme.iconSize(.sm), .color_text = cc.wrap(if (item.public) theme.colors.accent else theme.colors.text_tertiary), .gravity_y = 0.5, .margin = .{ .x = 8, .w = 8 } });
                    dvui.labelNoFmt(@src(), item.nameSlice(), .{}, .{ .expand = .horizontal, .color_text = cc.wrap(if (item.public) theme.colors.text_primary else theme.colors.text_secondary), .gravity_y = 0.5 });
                    if (!item.public) surfaces.badge(@src(), "Seeding required", theme.colors.text_tertiary);
                }
                row.deinit();
            }
        } else if (!busy.load(.acquire)) components.bodyText(@src(), if (owned.ready) "Add trackers in Manage trackers, then refresh this list." else "Start Jackett to add and choose your torrent sources.", theme.colors.text_tertiary);
        trackers.deinit();
    }
}
