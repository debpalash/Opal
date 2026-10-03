//! Native manager for the persistent local-media index.
const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme.zig");
const state = @import("../core/state.zig");
const library = @import("../services/local_library.zig");
const layout = @import("local_library_layout_pure.zig");

var test_rows: [3]dvui.Rect.Physical = undefined;
var test_editor_fields: [2]dvui.Rect.Physical = undefined;
pub fn editorFieldsForTest() [2]dvui.Rect.Physical {
    if (!@import("builtin").is_test) @compileError("Native editor snapshot is test-only");
    return test_editor_fields;
}
var fixture_items: ?[]const library.Item = null;
var fixture_roots: ?[]const library.Root = null;
pub fn layoutRowsForTest() [3]dvui.Rect.Physical {
    if (!@import("builtin").is_test) @compileError("Native layout snapshot is test-only");
    return test_rows;
}

pub fn setFixtureForTest(items: ?[]const library.Item, roots: ?[]const library.Root, editor: ?library.Item) void {
    if (!@import("builtin").is_test) @compileError("Native local-library fixture is test-only");
    fixture_items = items;
    fixture_roots = roots;
    edit_id = 0;
    if (editor) |item| {
        edit_id = item.id;
        @memset(&edit_title, 0);
        @memset(&edit_kind, 0);
        @memcpy(edit_title[0..item.title_len], item.title[0..item.title_len]);
        @memcpy(edit_kind[0..item.kind_len], item.kind[0..item.kind_len]);
    }
}

fn loadRoots(out: []library.Root) usize {
    if (@import("builtin").is_test) if (fixture_roots) |rows| {
        const count = @min(out.len, rows.len);
        @memcpy(out[0..count], rows[0..count]);
        return count;
    };
    return library.listRoots(out);
}

fn loadItems(query: []const u8, out: []library.Item) usize {
    if (@import("builtin").is_test) if (fixture_items) |rows| {
        const count = @min(out.len, rows.len);
        @memcpy(out[0..count], rows[0..count]);
        return count;
    };
    return library.search(query, duplicates_only, out);
}

var query_buf: [256]u8 = std.mem.zeroes([256]u8);
var root_buf: [1024]u8 = std.mem.zeroes([1024]u8);
var duplicates_only = false;
var edit_id: i64 = 0;
var edit_title: [256]u8 = std.mem.zeroes([256]u8);
var edit_kind: [16]u8 = std.mem.zeroes([16]u8);

pub fn render() void {
    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .corner_radius = theme.dims.rad_md,
        .padding = dvui.Rect.all(theme.spacing.md),
        .margin = dvui.Rect.all(theme.spacing.lg),
    });
    defer panel.deinit();

    var header = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    _ = dvui.label(@src(), "Local library", .{}, .{
        .expand = .horizontal,
        .font = dvui.themeGet().font_heading,
        .color_text = theme.colors.text_primary,
    });
    if (dvui.button(@src(), if (library.scanning.load(.acquire)) "Scanning…" else "Scan files", .{}, .{
        .color_fill = theme.colors.bg_elevated,
        .color_text = theme.colors.text_secondary,
    }) and !library.scanning.load(.acquire)) library.scanAsync();
    if (@import("builtin").is_test) test_rows[0] = header.data().borderRectScale().r;
    header.deinit();

    const stacked = layout.stackFormControls(panel.data().contentRect().w);
    var root_controls = dvui.box(@src(), .{ .dir = if (stacked) .vertical else .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = theme.spacing.sm },
    });
    var root_entry = dvui.textEntry(@src(), .{
        .text = .{ .buffer = &root_buf },
        .placeholder = "Add a media folder path",
    }, .{
        .expand = .horizontal,
        .color_fill = theme.colors.bg_elevated,
        .color_text = theme.colors.text_primary,
        .corner_radius = theme.dims.rad_sm,
    });
    root_entry.deinit();
    if (dvui.button(@src(), "Import folder", .{}, .{ .color_fill = theme.colors.accent, .color_text = theme.colors.text_on_accent })) {
        if (library.addRoot(std.mem.sliceTo(&root_buf, 0))) {
            @memset(&root_buf, 0);
            library.scanAsync();
            state.showToast("Media folder added");
        } else state.showToast("Folder is unavailable");
    }
    if (@import("builtin").is_test) test_rows[1] = root_controls.data().borderRectScale().r;
    root_controls.deinit();

    var roots: [library.MAX_ROOTS]library.Root = undefined;
    const root_count = loadRoots(&roots);
    for (roots[0..root_count], 0..) |*root, index| {
        var root_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = index, .expand = .horizontal });
        defer root_row.deinit();
        _ = dvui.labelNoFmt(@src(), root.path[0..root.path_len], .{}, .{
            .id_extra = index,
            .expand = .horizontal,
            .color_text = theme.colors.text_secondary,
        });
        if (dvui.button(@src(), "Remove", .{}, .{ .id_extra = index, .color_fill = theme.colors.bg_elevated })) {
            if (library.removeRoot(root.id)) state.showToast("Media folder removed");
            break;
        }
    }

    var controls = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    var search = dvui.textEntry(@src(), .{
        .text = .{ .buffer = &query_buf },
        .placeholder = "Search indexed files…",
    }, .{
        .expand = .horizontal,
        .color_fill = theme.colors.bg_elevated,
        .color_text = theme.colors.text_primary,
        .corner_radius = theme.dims.rad_sm,
    });
    search.deinit();
    if (dvui.button(@src(), if (duplicates_only) "Likely duplicates: on" else "Likely duplicates: off", .{}, .{
        .color_fill = theme.colors.bg_elevated,
        .color_text = if (duplicates_only) theme.colors.accent else theme.colors.text_secondary,
    })) duplicates_only = !duplicates_only;
    if (@import("builtin").is_test) test_rows[2] = controls.data().borderRectScale().r;
    controls.deinit();

    var items: [library.MAX_RESULTS]library.Item = undefined;
    const query = std.mem.sliceTo(&query_buf, 0);
    const count = loadItems(query, &items);
    for (items[0..count], 0..) |*item, index| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = index,
            .expand = .horizontal,
            .padding = .{ .x = 4, .y = 5, .w = 4, .h = 5 },
            .color_border = theme.colors.border_subtle,
            .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        });
        defer row.deinit();
        _ = dvui.labelNoFmt(@src(), item.title[0..item.title_len], .{}, .{
            .id_extra = index,
            .expand = .horizontal,
            .color_text = theme.colors.text_primary,
        });
        var meta_buf: [80]u8 = undefined;
        const meta = std.fmt.bufPrint(&meta_buf, "{d} MB{s}", .{
            item.size / (1024 * 1024),
            if (item.duplicate_count > 1) " · likely duplicate" else "",
        }) catch "";
        _ = dvui.labelNoFmt(@src(), meta, .{}, .{ .id_extra = index, .color_text = theme.colors.text_tertiary });
        if (dvui.button(@src(), "Edit", .{}, .{ .id_extra = index, .color_fill = theme.colors.bg_elevated })) {
            edit_id = item.id;
            @memset(&edit_title, 0);
            @memcpy(edit_title[0..item.title_len], item.title[0..item.title_len]);
            @memset(&edit_kind, 0);
            @memcpy(edit_kind[0..item.kind_len], item.kind[0..item.kind_len]);
        }
    }
    if (count == 0)
        _ = dvui.labelNoFmt(@src(), layout.emptyHint(query.len, duplicates_only, root_count), .{}, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 },
            .color_text = theme.colors.text_tertiary,
        });

    if (edit_id > 0) renderEditor();
}

fn renderEditor() void {
    const stacked = layout.stackFormControls(dvui.parentGet().data().contentRect().w);
    var editor = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_elevated,
        .padding = dvui.Rect.all(theme.spacing.sm),
    });
    defer editor.deinit();
    var fields = dvui.box(@src(), .{ .dir = if (stacked) .vertical else .horizontal }, .{ .expand = .horizontal });
    var title = dvui.textEntry(@src(), .{ .text = .{ .buffer = &edit_title }, .placeholder = "Corrected title" }, .{
        .expand = .horizontal,
        .color_fill = theme.colors.bg_app,
        .color_text = theme.colors.text_primary,
    });
    if (@import("builtin").is_test) test_editor_fields[0] = title.data().borderRectScale().r;
    title.deinit();
    var kind = dvui.textEntry(@src(), .{ .text = .{ .buffer = &edit_kind }, .placeholder = "movie / tv / music / audiobook / other" }, .{
        .expand = if (stacked) .horizontal else .none,
        .min_size_content = .{ .w = 220, .h = dvui.themeGet().font_body.sizeM(1, 1).h },
        .color_fill = theme.colors.bg_app,
        .color_text = theme.colors.text_primary,
    });
    if (@import("builtin").is_test) test_editor_fields[1] = kind.data().borderRectScale().r;
    kind.deinit();
    fields.deinit();
    var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer actions.deinit();
    if (dvui.button(@src(), "Save", .{}, .{ .color_fill = theme.colors.accent, .color_text = theme.colors.text_on_accent })) {
        if (library.correct(edit_id, std.mem.sliceTo(&edit_title, 0), std.mem.sliceTo(&edit_kind, 0))) {
            state.showToast("Metadata saved");
            edit_id = 0;
        } else state.showToast("Use a supported media type");
    }
    if (dvui.button(@src(), "Cancel", .{}, .{ .color_fill = theme.colors.bg_surface })) edit_id = 0;
}
