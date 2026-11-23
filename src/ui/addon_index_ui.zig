//! Plugins > Sources > Advanced: the community add-on index and the add-ons
//! installed from signed repositories (update / remove). Decisions live in
//! services/addon_index*.zig; this file only draws and dispatches workers.
const std = @import("std");
const dvui = @import("dvui");
const i18n = @import("../core/i18n.zig");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const workers = @import("../core/workers.zig");
const alloc = @import("../core/alloc.zig").allocator;
const theme = @import("theme.zig");
const components = @import("components.zig");
const index = @import("../services/addon_index.zig");

const Ui = struct {
    var url: [1025]u8 = @splat(0);
    var key: [65]u8 = @splat(0);
    var query: [129]u8 = @splat(0);
    var last_query: [129]u8 = @splat(0);
    var loaded_fields = false;
    var snapshot: ?std.json.Parsed(std.json.Value) = null;
    var busy = std.atomic.Value(bool).init(false);
    var changed = std.atomic.Value(bool).init(true);

    const Job = struct { repo: [32]u8 = undefined, len: usize = 0 };
    /// Fetch the index (len == 0) or a just-added repository's catalog.
    fn work(job: Job) void {
        defer @This().busy.store(false, .release);
        const result = if (job.len == 0) index.refresh() else @import("../services/addon_repositories.zig").refresh(job.repo[0..job.len]);
        result catch |err| logs.pushLog("warn", "addon-index", @errorName(err), true);
        @This().changed.store(true, .release);
        state.wakeUi();
    }
};

pub fn deinit() void {
    if (Ui.snapshot) |s| s.deinit();
    Ui.snapshot = null;
}

fn spawn(job: Ui.Job) void {
    if (Ui.busy.swap(true, .acq_rel)) return;
    if (workers.spawnLegacy(Ui.work, .{job})) |t| workers.release(t) else |_| Ui.busy.store(false, .release);
}

fn field(buf: []u8, placeholder: []const u8, id: usize) void {
    var entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = buf }, .placeholder = placeholder }, .{
        .id_extra = id,
        .expand = .horizontal,
        .color_fill = .{ .color = theme.colors.bg_elevated },
        .color_border = .{ .color = theme.colors.border_subtle },
        .color_text = .{ .color = theme.colors.text_primary },
        .border = dvui.Rect.all(1),
        .corners = dvui.CornerRect.all(theme.radius.sm),
    });
    entry.deinit();
}

fn str(value: std.json.Value, name: []const u8) []const u8 {
    if (value != .object) return "";
    const v = value.object.get(name) orelse return "";
    return if (v == .string) v.string else "";
}

fn flag(value: std.json.Value, name: []const u8) bool {
    if (value != .object) return false;
    const v = value.object.get(name) orelse return false;
    return v == .bool and v.bool;
}

fn reload() void {
    const q = std.mem.sliceTo(&Ui.query, 0);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    index.writeSnapshot(&out.writer, q) catch return;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, out.written(), .{ .allocate = .alloc_always }) catch return;
    deinit();
    Ui.snapshot = parsed;
    if (!Ui.loaded_fields) {
        Ui.loaded_fields = true;
        const cfg = parsed.value.object.get("index") orelse return;
        const u = str(cfg, "url");
        const k = str(cfg, "public_key");
        if (u.len < Ui.url.len) @memcpy(Ui.url[0..u.len], u);
        if (k.len < Ui.key.len) @memcpy(Ui.key[0..k.len], k);
    }
}

fn label(text: []const u8, color: dvui.Color, id: usize) void {
    _ = dvui.label(@src(), "{s}", .{text}, .{ .color_text = .{ .color = color }, .id_extra = id });
}

pub fn render() void {
    if (!std.mem.eql(u8, std.mem.sliceTo(&Ui.query, 0), std.mem.sliceTo(&Ui.last_query, 0))) {
        Ui.last_query = Ui.query;
        Ui.changed.store(true, .release);
    }
    if (Ui.changed.swap(false, .acq_rel)) reload();

    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = theme.colors.bg_surface },
        .corners = dvui.CornerRect.all(theme.radius.lg),
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = theme.colors.border_subtle },
        .padding = dvui.Rect.all(theme.spacing.md),
        .margin = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
    });
    defer card.deinit();
    _ = dvui.label(@src(), "{s}", .{i18n.t(.addons_index_title)}, .{ .color_text = .{ .color = theme.colors.text_primary }, .font = dvui.themeGet().font_heading });
    components.bodyText(@src(), i18n.t(.addons_index_hint), theme.colors.text_secondary);

    field(&Ui.url, i18n.t(.addons_index_url), 9601);
    field(&Ui.key, i18n.t(.addons_index_key), 9602);
    if (components.actionButton(@src(), i18n.t(.addons_index_save), .secondary, 9603)) {
        index.configure(std.mem.sliceTo(&Ui.url, 0), std.mem.sliceTo(&Ui.key, 0)) catch |err| state.showToast(@errorName(err));
        Ui.changed.store(true, .release);
    }
    const snap = Ui.snapshot orelse return;
    const cfg = snap.value.object.get("index") orelse return;
    if (flag(cfg, "enabled")) {
        if (!Ui.busy.load(.acquire) and components.actionButton(@src(), i18n.t(.addons_index_fetch), .secondary, 9604)) spawn(.{});
        if (components.confirmDangerButton(@src(), i18n.t(.addons_index_clear), 9605)) {
            index.configure("", "") catch |err| state.showToast(@errorName(err));
            @memset(&Ui.url, 0);
            @memset(&Ui.key, 0);
            Ui.changed.store(true, .release);
        }
        const err_text = str(cfg, "error");
        if (err_text.len > 0) label(err_text, theme.colors.warning, 9606);
    }
    field(&Ui.query, i18n.t(.addons_index_search), 9607);

    if (snap.value.object.get("entries")) |entries| if (entries == .array) {
        for (entries.array.items, 0..) |e, i| renderEntry(e, i);
    };

    const addons = snap.value.object.get("addons") orelse return;
    if (addons != .array or addons.array.items.len == 0) return;
    label(i18n.t(.addons_installed), theme.colors.text_primary, 9608);
    for (addons.array.items, 0..) |a, i| {
        const installed = str(a, "installed");
        if (installed.len == 0 or !std.mem.eql(u8, str(a, "installed_from"), str(a, "repo"))) continue;
        renderInstalled(a, installed, i);
    }
}

fn renderEntry(e: std.json.Value, i: usize) void {
    const uid = 20000 + i * 10;
    var line_buf: [200]u8 = undefined;
    label(std.fmt.bufPrint(&line_buf, "{s} ({s})", .{ str(e, "name"), str(e, "id") }) catch str(e, "id"), theme.colors.text_primary, uid);
    const desc = str(e, "description");
    if (desc.len > 0) label(desc, theme.colors.text_secondary, uid + 4);
    const key = str(e, "public_key");
    var key_buf: [1200]u8 = undefined;
    // Show the whole key: this is the fingerprint the user is about to pin.
    label(std.fmt.bufPrint(&key_buf, "{s}  {s}", .{ str(e, "url"), key }) catch key, theme.colors.text_tertiary, uid + 1);
    const status = str(e, "status");
    if (std.mem.eql(u8, status, "added")) {
        label(i18n.t(.addons_index_added), theme.colors.text_secondary, uid + 2);
    } else if (std.mem.eql(u8, status, "conflict")) {
        label(i18n.t(.addons_index_conflict), theme.colors.warning, uid + 2);
    } else if (components.confirmDangerButton(@src(), i18n.t(.addons_index_add), uid + 3)) {
        const id = str(e, "id");
        index.addFromIndex(id) catch |err| {
            state.showToast(@errorName(err));
            return;
        };
        @import("../services/plugins.zig").markSignedRepositoriesChanged();
        var job: Ui.Job = .{ .len = @min(id.len, 32) };
        @memcpy(job.repo[0..job.len], id[0..job.len]);
        spawn(job);
    }
}

fn renderInstalled(a: std.json.Value, installed: []const u8, i: usize) void {
    const uid = 30000 + i * 10;
    var line_buf: [240]u8 = undefined;
    label(std.fmt.bufPrint(&line_buf, "{s}  {s} -> {s}", .{ str(a, "name"), installed, str(a, "version") }) catch str(a, "id"), theme.colors.text_primary, uid);
    if (flag(a, "update")) {
        if (components.confirmDangerButton(@src(), i18n.t(.addons_update), uid + 1)) {
            index.update(str(a, "repo"), str(a, "id"), str(a, "confirmation")) catch |err| state.showToast(@errorName(err));
            @import("../services/plugins.zig").markSignedRepositoriesChanged();
            Ui.changed.store(true, .release);
        }
    } else label(i18n.t(.addons_up_to_date), theme.colors.text_tertiary, uid + 2);
    if (components.confirmDangerButton(@src(), i18n.t(.addons_remove), uid + 3)) {
        index.uninstall(str(a, "id")) catch |err| state.showToast(@errorName(err));
        @import("../services/plugins.zig").markSignedRepositoriesChanged();
        Ui.changed.store(true, .release);
    }
}
