//! Downloads page: "Offline" panel. Browse the paired server's downloads,
//! save files for offline play within a storage limit, and play them back.
//! Decisions (which buttons, labels, percentages) come from offline_pure;
//! this file only draws.

const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme.zig");
const components = @import("components.zig");
const offline = @import("../services/offline.zig");
const pure = offline.pure;
const dp = @import("../services/download_pure.zig");
const wrap = @import("color_compat.zig").wrap;

var expanded = false;
var queue_buf: [pure.MAX_ITEMS]pure.Item = undefined;
var listing: offline.Listing = .{};

fn text(comptime fmt: []const u8, args: anytype, color: anytype, id: usize) void {
    _ = dvui.label(@src(), fmt, args, .{ .id_extra = id, .color_text = wrap(color), .gravity_y = 0.5 });
}

pub fn render() void {
    const n = offline.snapshot(&queue_buf);
    if (!expanded and n == 0) {
        var hint = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 14, .y = 6, .w = 14, .h = 6 },
        });
        defer hint.deinit();
        if (components.actionButton(@src(), "Offline: save files from your Opal server to this device", .secondary, 92000)) {
            expanded = true;
            if (offline.hasServer()) offline.browse("");
        }
        return;
    }

    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = 14, .y = 8, .w = 14, .h = 8 },
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .color_border = wrap(theme.colors.border_subtle),
    });
    defer card.deinit();

    components.sectionHeader("Offline");
    renderQuota();
    renderBrowser();
    for (queue_buf[0..n], 0..) |*it, i| renderItem(it, i);
}

fn renderQuota() void {
    const u = offline.usage();
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();
    var ub: [24]u8 = undefined;
    var qb: [24]u8 = undefined;
    text("Using {s} of {s}", .{ dp.fmtBytes(u.used, &ub), dp.fmtBytes(u.quota, &qb) }, theme.colors.text_secondary, 92001);
    const labels = [_][]const u8{ "2 GB", "8 GB", "32 GB", "128 GB" };
    var sel: usize = 0;
    for (pure.QUOTA_CHOICES, 0..) |q, i| {
        if (q == u.quota) sel = i;
    }
    if (components.segment(@src(), &labels, sel)) |pick| offline.setQuota(pure.QUOTA_CHOICES[pick]);
}

fn renderBrowser() void {
    if (!offline.hasServer()) {
        text("Pair your Opal server under Settings > Web UI > Device sync to browse its files.", .{}, theme.colors.text_tertiary, 92010);
        return;
    }
    offline.listingSnapshot(&listing);
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        if (components.actionButton(@src(), if (listing.busy) "Loading..." else "Browse server", .primary, 92011) and !listing.busy) offline.browse(listing.dirText());
        const dir = listing.dirText();
        if (dir.len > 0) {
            if (components.actionButton(@src(), "Up", .secondary, 92012) and !listing.busy) {
                offline.browse(if (std.mem.lastIndexOfScalar(u8, dir, '/')) |s| dir[0..s] else "");
            }
            text("{s}", .{dir}, theme.colors.text_secondary, 92013);
        }
        if (listing.status_len > 0) text("{s}", .{listing.statusText()}, theme.colors.text_tertiary, 92014);
    }
    for (listing.entries[0..listing.count], 0..) |*e, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .expand = .horizontal });
        defer row.deinit();
        var sb: [24]u8 = undefined;
        if (e.is_dir) {
            text("{s}/", .{e.nameText()}, theme.colors.text_primary, 92100 + i);
            if (components.actionButton(@src(), "Open", .secondary, 92300 + i) and !listing.busy) {
                var pb: [pure.FILE_LEN * 2]u8 = undefined;
                const dir = listing.dirText();
                const next = if (dir.len > 0) std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, e.nameText() }) catch "" else e.nameText();
                if (next.len > 0) offline.browse(next);
            }
        } else {
            text("{s}  {s}", .{ e.nameText(), dp.fmtBytes(e.size, &sb) }, theme.colors.text_primary, 92100 + i);
            if (components.actionButton(@src(), "Save offline", .secondary, 92300 + i)) {
                var pb: [pure.FILE_LEN * 2]u8 = undefined;
                const dir = listing.dirText();
                const rel = if (dir.len > 0) std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, e.nameText() }) catch "" else e.nameText();
                if (rel.len > 0) _ = offline.queueServerFile(rel, e.size);
            }
        }
    }
}

fn renderItem(it: *const pure.Item, i: usize) void {
    const base: usize = 93000 + i * 10;
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = i,
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = 0 },
    });
    defer row.deinit();
    {
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
        defer col.deinit();
        text("{s}", .{it.titleText()}, theme.colors.text_primary, base);
        var hb: [24]u8 = undefined;
        if (it.status == .downloading or it.status == .paused or it.status == .waiting_network) {
            text("{s}  {d}%  {s}", .{ pure.statusLabel(it.status), pure.percentDone(it), dp.fmtBytes(it.have, &hb) }, theme.colors.text_secondary, base + 1);
        } else {
            text("{s}", .{pure.statusLabel(it.status)}, if (it.status == .failed) theme.colors.danger else theme.colors.text_secondary, base + 1);
        }
        if (it.err_len > 0) text("{s}", .{it.errText()}, theme.colors.text_tertiary, base + 2);
    }
    const acts = pure.actionsFor(it.status);
    if (acts.play and components.actionButton(@src(), "Play", .primary, base + 3)) offline.play(it.idText());
    if (acts.pause and components.actionButton(@src(), "Pause", .secondary, base + 4)) offline.apply(it.idText(), .pause);
    if (acts.@"resume" and components.actionButton(@src(), "Resume", .secondary, base + 5)) offline.apply(it.idText(), .@"resume");
    if (acts.retry and components.actionButton(@src(), "Retry", .secondary, base + 6)) offline.apply(it.idText(), .retry);
    if (components.confirmDangerButton(@src(), "Remove", base + 7)) offline.apply(it.idText(), .remove);
}
