//! Native manager for the persistent local-media index.
const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme.zig");
const state = @import("../core/state.zig");
const library = @import("../services/local_library.zig");

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
    defer header.deinit();
    _ = dvui.label(@src(), "Local library", .{}, .{
        .expand = .horizontal,
        .font = dvui.themeGet().font_heading,
        .color_text = theme.colors.text_primary,
    });
    if (dvui.button(@src(), if (library.scanning.load(.acquire)) "Scanning…" else "Scan files", .{}, .{
        .color_fill = theme.colors.bg_elevated,
        .color_text = theme.colors.text_secondary,
    }) and !library.scanning.load(.acquire)) library.scanAsync();

    var root_controls = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer root_controls.deinit();
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

    var roots: [library.MAX_ROOTS]library.Root = undefined;
    const root_count = library.listRoots(&roots);
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
    defer controls.deinit();
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

    var items: [library.MAX_RESULTS]library.Item = undefined;
    const query = std.mem.sliceTo(&query_buf, 0);
    const count = library.search(query, duplicates_only, &items);
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
        _ = dvui.label(@src(), "No indexed files match. Scan after changing the download folder.", .{}, .{ .color_text = theme.colors.text_tertiary });

    if (edit_id > 0) renderEditor();
}

fn renderEditor() void {
    var editor = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_elevated,
        .padding = dvui.Rect.all(theme.spacing.sm),
    });
    defer editor.deinit();
    var title = dvui.textEntry(@src(), .{ .text = .{ .buffer = &edit_title }, .placeholder = "Corrected title" }, .{
        .expand = .horizontal,
        .color_fill = theme.colors.bg_app,
        .color_text = theme.colors.text_primary,
    });
    title.deinit();
    var kind = dvui.textEntry(@src(), .{ .text = .{ .buffer = &edit_kind }, .placeholder = "movie / tv / music / audiobook / other" }, .{
        .min_size_content = .{ .w = 220, .h = 0 },
        .color_fill = theme.colors.bg_app,
        .color_text = theme.colors.text_primary,
    });
    kind.deinit();
    if (dvui.button(@src(), "Save", .{}, .{ .color_fill = theme.colors.accent, .color_text = theme.colors.text_on_accent })) {
        if (library.correct(edit_id, std.mem.sliceTo(&edit_title, 0), std.mem.sliceTo(&edit_kind, 0))) {
            state.showToast("Metadata saved");
            edit_id = 0;
        } else state.showToast("Use a supported media type");
    }
    if (dvui.button(@src(), "Cancel", .{}, .{ .color_fill = theme.colors.bg_surface })) edit_id = 0;
}
