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

pub fn setFixtureForTest() void {
    if (!@import("builtin").is_test) @compileError("test only");
    initialized = true;
    put(&base, "http://127.0.0.1:9117");
    put(&key, "owned-test-key");
    put(&selection, "nyaasi");
    advanced = false;
    all_public = false;
    revision = 100;
    catalog_revision = revision;
    result = .{};
    result.count = pure.parseCatalog(alloc, "<indexers><indexer id=\"nyaasi\" configured=\"true\"><title>Nyaa · anime</title><type>public</type></indexer><indexer id=\"torrentleech\" configured=\"true\"><title>TorrentLeech</title><type>private</type></indexer></indexers>", &result.items) catch unreachable;
    chosen = @splat(false);
    chosen[0] = true;
    put(&message, "Connected. Choose trackers, then save.");
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
    const before = std.hash.Wyhash.hash(0, text(buffer));
    components.bodyText(@src(), label, theme.colors.text_secondary);
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

fn save() void {
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
        mutex.lock();
        defer mutex.unlock();
        for (result.items[0..result.count], 0..) |*item, i| {
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

pub fn render() void {
    init();
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();
    var content = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = dvui.Rect.all(12) });
    defer content.deinit();
    surfaces.heading(@src(), "Jackett", "Torrent sources");
    components.bodyText(@src(), "Opal downloads and runs Jackett for you. Add sources and manage tracker accounts here.", theme.colors.text_secondary);
    const owned = server.snapshot();
    if (!owned.active) {
        managed_attached = false;
        if (components.actionButton(@src(), "Set up / start Jackett", .primary, 10)) server.start();
    } else {
        if (components.iconButton(@src(), icons.tvg.lucide.square, "Stop Jackett", false)) server.stop();
    }
    if (text(&owned.status).len > 0) components.bodyText(@src(), text(&owned.status), theme.colors.text_secondary);
    if (owned.ready and !managed_attached) {
        managed_attached = true;
        put(&base, text(&owned.base));
        put(&key, text(&owned.key));
        revision +%= 1;
        catalog_revision = null;
        var selected_buf: [512]u8 = undefined;
        put(&selection, sources.copyValue("jackett", "indexers", &selected_buf) orelse "*");
        all_public = std.mem.eql(u8, text(&selection), "*");
        if (busy.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
            @import("../core/workers.zig").spawn(worker, .{Job{ .base = base, .key = key, .revision = revision }}) catch {
                busy.store(false, .release);
            };
        }
    }
    components.compactToggle(@src(), "Existing server", &advanced);
    if (advanced) {
        field("Server URL", &base, false, 0);
        field("API key", &key, true, 1);
    }
    var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 8, .h = 8 } });
    if (busy.load(.acquire)) components.bodyText(@src(), "Connecting…", theme.colors.text_secondary) else {
        if (components.actionButton(@src(), "Test / refresh", .secondary, 0)) {
            if (busy.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
                put(&message, "Connecting…");
                @import("../core/workers.zig").spawn(worker, .{Job{ .base = base, .key = key, .revision = revision }}) catch {
                    busy.store(false, .release);
                    put(&message, "Could not start connection test.");
                };
            }
        }
    }
    if (components.iconButton(@src(), icons.tvg.lucide.settings, "Manage trackers in Opal", false) and pure.validBase(text(&base))) {
        state.navigateToTab(.Web);
        @import("../services/browser.zig").navigate(text(&base));
    }
    if (components.actionButton(@src(), "Save", .primary, 0)) save();
    actions.deinit();
    mutex.lock();
    defer mutex.unlock();
    if (result.ready) {
        if (result.revision == revision) {
            put(&message, text(&result.message));
            catalog_revision = if (result.success) revision else null;
            for (result.items[0..result.count], 0..) |*item, i| chosen[i] = item.public and pure.selected(text(&selection), item.idSlice());
        }
        result.ready = false;
    }
    if (text(&message).len > 0) components.bodyText(@src(), text(&message), theme.colors.text_secondary);
    components.toggleRow(@src(), "All configured public trackers", "New public trackers added in Jackett are included automatically.", &all_public);
    if (catalog_revision == revision) {
        for (result.items[0..result.count], 0..) |*item, i| {
            var row = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = i, .expand = .horizontal });
            if (item.public) {
                if (!all_public) components.toggleRow(@src(), item.nameSlice(), item.idSlice(), &chosen[i]) else components.bodyText(@src(), item.nameSlice(), theme.colors.text_primary);
            } else {
                components.bodyText(@src(), item.nameSlice(), theme.colors.text_tertiary);
            }
            row.deinit();
        }
    }
    components.bodyText(@src(), "Account-required trackers are listed for reference. Searching them is disabled until a persistent seeding client is connected.", theme.colors.text_tertiary);
}
