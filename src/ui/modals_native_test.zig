//! Real global-modal pixels. Static renderer fixtures; no file I/O or downloads.
const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const alloc = @import("../core/alloc.zig").allocator;
const io = @import("../core/io_global.zig");
const workers = @import("../core/workers.zig");
const capture = @import("native_capture.zig");
const metadata = @import("metadata_dialog.zig");
const Case = enum { onboarding, workspace_save, workspace_load_empty, workspace_load_populated, metadata_waiting, metadata_populated };
var current: Case = .onboarding;
const files = [_]metadata.FileFixture{
    .{ .name = "Offline.fixture.with.a.very.long.title.2160p.multilingual.audio.and.director.commentary.mkv", .size = 3_000_000_000 },
    .{ .name = "Subtitles/Offline.fixture.English.SDH.srt", .size = 64_000 },
    .{ .name = "Subtitles/Offline.fixture.日本語.srt", .size = 80_000 },
    .{ .name = "Extras/Offline.fixture.deleted.scenes.and.interviews.with.a.long.filename.mp4", .size = 400_000_000 },
};
fn setup() !void {
    state.app.ws_save_open = current == .workspace_save;
    state.app.ws_load_open = current == .workspace_load_empty or current == .workspace_load_populated;
    state.app.ws_count = if (current == .workspace_load_populated) 16 else 0;
    for (0..state.app.ws_count) |index| {
        @memset(&state.app.ws_names[index], 0);
        const name = try std.fmt.bufPrint(&state.app.ws_names[index], "Offline workspace fixture {d} — a long saved session name", .{index});
        state.app.ws_name_lens[index] = name.len;
    }
    @memset(&state.app.ws_name_input, 0);
    const save_name = "Offline fixture — evening movies and long session name";
    @memcpy(state.app.ws_name_input[0..save_name.len], save_name);
    state.app.onboarded = current != .onboarding;
    state.app.is_headless = false;
    state.app.config_loaded.store(true, .release);
    state.app.pending_magnet_tid = if (current == .metadata_waiting or current == .metadata_populated) 0 else -1;
    state.app.pending_has_metadata = current == .metadata_populated;
    @memset(&state.app.pending_files_selection, true);
    metadata.setFixtureForTest(.{ .name = "Offline torrent metadata fixture with a long multilingual release title", .files = &files });
}
fn draw() !void {
    var background = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .color_fill = @import("theme.zig").colors.bg_app });
    defer background.deinit();
    _ = dvui.label(@src(), "Offline global modal renderer fixture — no download or workspace file operation", .{}, .{ .color_text = @import("theme.zig").colors.text_secondary });
    switch (current) {
        .onboarding => @import("onboarding.zig").render(),
        .workspace_save, .workspace_load_empty, .workspace_load_populated => @import("ui.zig").renderWorkspaceModals(),
        .metadata_waiting, .metadata_populated => metadata.renderMetadataDialog(),
    }
}
fn cleanup() void {
    metadata.setFixtureForTest(null);
    state.app.ws_save_open = false;
    state.app.ws_load_open = false;
    state.app.ws_count = 0;
    state.app.pending_magnet_tid = -1;
    state.app.config_loaded.store(false, .release);
}
test "Native global modals offline SDL pixel capture" {
    const logs = @import("../core/logs.zig");
    logs.logs_allocator = alloc;
    defer logs.deinit();
    workers.init();
    workers.beginShutdownAndDrain(0);
    defer workers.finishShutdown();
    for (std.meta.tags(Case)) |case| {
        const name = @tagName(case);
        if (io.getenv("OPAL_MODAL_CASE")) |filter| if (!std.mem.eql(u8, name, filter)) continue;
        current = case;
        for ([_][2]u32{ .{ 1360, 1000 }, .{ 640, 800 } }) |size| {
            try capture.capture(size[0], size[1], name, setup, draw, cleanup);
            if (case == .metadata_populated or case == .metadata_waiting) {
                const rect = metadata.test_dialog_rect;
                try std.testing.expect(rect.w > 0 and rect.w <= 608);
                try std.testing.expect(rect.h > 0 and rect.h <= 408);
                try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(size[0])) / 2, rect.x + rect.w / 2, 1);
                try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(size[1])) / 2, rect.y + rect.h / 2, 1);
                if (case == .metadata_waiting) {
                    try std.testing.expect(metadata.test_footer_rect.y >= metadata.test_waiting_rect.y + metadata.test_waiting_rect.h);
                }
                if (case == .metadata_populated) {
                    try std.testing.expectEqual(files.len, metadata.test_row_count);
                    for (1..metadata.test_row_count) |i| {
                        const previous = metadata.test_row_rects[i - 1];
                        try std.testing.expect(metadata.test_row_rects[i].y >= previous.y + previous.h);
                    }
                }
            }
        }
    }
}
