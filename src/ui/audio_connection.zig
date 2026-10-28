//! Audio output arrival prompt. All mpv writes happen on the UI owner thread.
const std = @import("std");
const dvui = @import("dvui");
const c = @import("../core/c.zig");
const state = @import("../core/state.zig");
const io = @import("../core/io_global.zig");
const pure = @import("../player/av_device_pure.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const icons = @import("icons");
var saw_entrance_for_test = false;

var connections: pure.Connections = .{};
var pending: ?pure.AudioDevice = null;
var last_poll: i64 = 0;

fn pauseAll() void {
    for (state.app.players.items) |p| {
        var paused: c_int = 1;
        _ = c.mpv.mpv_set_property(p.mpv_ctx, "pause", c.mpv.MPV_FORMAT_FLAG, &paused);
    }
}

pub fn render() void {
    if (state.app.players.items.len == 0) {
        connections = .{};
        pending = null;
        return;
    }
    const timer_id = dvui.Id.extendId(null, @src(), 0);
    if (dvui.timerDoneOrNone(timer_id)) dvui.timer(timer_id, 500_000);
    const now = io.milliTimestamp();
    if (now - last_poll >= 500) {
        last_poll = now;
        const p = state.app.players.items[0];
        const json = c.mpv.mpv_get_property_string(p.mpv_ctx, "audio-device-list");
        if (json != null) {
            defer c.mpv.mpv_free(@ptrCast(json));
            var devices: [pure.max_devices]pure.AudioDevice = undefined;
            const count = pure.parseAudioDevices(std.mem.span(json), &devices);
            // A transient backend failure must not turn the next good list
            // into a batch of fake connections.
            if (count > 0) {
                if (pending) |device| {
                    if (!pure.Connections.contains(devices[0..count], device.nameSlice())) pending = null;
                }
                if (connections.update(devices[0..count])) |device| {
                    pauseAll();
                    pending = device;
                }
            }
        }
    }
    renderPrompt();
}

fn renderPrompt() void {
    const device = pending orelse return;
    var open = true;
    const size = theme.fitWindowSize(.{ .w = 440, .h = 300 }, .{ .w = 280, .h = 260 });
    var win = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &open, .resize = .none }, .{
        .min_size_content = size,
        .color_fill = theme.colors.bg_surface,
        .corner_radius = dvui.Rect.all(theme.radius.lg),
    });
    defer win.deinit();
    win.autoPosition();
    win.autoSize();
    var entrance = dvui.animate(@src(), .{
        .kind = .alpha,
        .duration = theme.motionDuration(theme.motion.base),
        .easing = theme.motion.enter,
    }, .{ .expand = .both });
    defer entrance.deinit();
    if (@import("builtin").is_test) {
        if (entrance.val) |value| {
            if (value > 0 and value < 1) saw_entrance_for_test = true;
        }
    }
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = dvui.Rect.all(if (size.w < 360) theme.spacing.md else theme.spacing.xl),
    });
    defer body.deinit();
    {
        var header = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .h = theme.spacing.lg } });
        defer header.deinit();
        dvui.icon(@src(), "Playback paused", icons.tvg.lucide.pause, .{}, .{
            .min_size_content = theme.iconSize(.sm),
            .color_text = theme.colors.accent,
            .gravity_y = 0.5,
            .margin = .{ .w = theme.spacing.sm },
        });
        _ = dvui.labelNoFmt(@src(), "PLAYBACK PAUSED", .{}, .{ .color_text = theme.colors.text_secondary, .gravity_y = 0.5 });
        var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
        spacer.deinit();
        if (components.iconButton(@src(), icons.tvg.lucide.x, "Dismiss", false)) pending = null;
    }
    var title_font = dvui.themeGet().font_heading;
    title_font.size = if (size.w < 360) theme.font_size.headline else theme.font_size.display;
    var heading = dvui.textLayout(@src(), .{ .break_lines = true }, .{
        .expand = .horizontal,
        .background = false,
        .font = title_font,
        .color_text = theme.colors.text_primary,
        .margin = .{ .h = theme.spacing.sm },
    });
    heading.addText(if (size.w < 360) "Switch audio\noutput?" else "Switch audio output?", .{});
    heading.deinit();
    components.bodyText(@src(), "A new device is ready to use.", theme.colors.text_secondary);
    {
        var device_card = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .corner_radius = dvui.Rect.all(theme.radius.md),
            .padding = dvui.Rect.all(theme.spacing.md),
            .margin = .{ .y = theme.spacing.md, .h = theme.spacing.lg },
        });
        defer device_card.deinit();
        dvui.icon(@src(), "Audio output", icons.tvg.lucide.speaker, .{}, .{
            .min_size_content = theme.iconSize(.lg),
            .color_text = theme.colors.accent,
            .gravity_y = 0.5,
            .margin = .{ .w = theme.spacing.md },
        });
        var details = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
        defer details.deinit();
        components.bodyText(@src(), @import("../core/text.zig").safeUtf8(device.label()), theme.colors.text_primary);
    }
    var actions = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal, .margin = .{ .h = theme.spacing.md } });
    {
        var dismiss = dvui.box(@src(), .{}, .{ .margin = .{ .w = theme.spacing.sm, .h = theme.spacing.sm } });
        defer dismiss.deinit();
        if (components.actionButton(@src(), "Not now", .secondary, 1)) pending = null;
    }
    if (components.iconActionButton(@src(), icons.tvg.lucide.@"arrow-right", "Switch output", .primary, 0)) {
        var name: [pure.name_cap + 1]u8 = @splat(0);
        @memcpy(name[0..device.name_len], device.nameSlice());
        var success = true;
        for (state.app.players.items) |p| {
            if (c.mpv.mpv_set_property_string(p.mpv_ctx, "audio-device", &name) < 0) success = false;
        }
        if (success) {
            @memset(&state.app.audio_device_buf, 0);
            @memcpy(state.app.audio_device_buf[0..device.name_len], device.nameSlice());
            state.app.audio_device_len = device.name_len;
            state.markConfigDirty();
            pending = null;
            state.showToast("Audio output switched. Press play to resume.");
        } else state.showToast("Could not switch audio output. Check the device and retry.");
    }
    actions.deinit();
    components.bodyText(@src(), "Press play when you’re ready to resume.", theme.colors.text_tertiary);
}

fn drawPromptFixture() !void {
    renderPrompt();
}

test "Native shell offline audio connection prompt" {
    var devices: [1]pure.AudioDevice = undefined;
    _ = pure.parseAudioDevices("[{\"name\":\"coreaudio/fixture\",\"description\":\"USB headphones — external audio output\"}]", &devices);
    pending = devices[0];
    defer pending = null;
    saw_entrance_for_test = false;
    theme.setReducedMotion(true);
    defer theme.setReducedMotion(false);
    try @import("native_capture.zig").capture(640, 480, "audio-connection", null, drawPromptFixture, null);
    try @import("native_capture.zig").capture(390, 480, "audio-connection", null, drawPromptFixture, null);
    try @import("native_capture.zig").capture(320, 560, "audio-connection", null, drawPromptFixture, null);
    try std.testing.expect(!saw_entrance_for_test);
    theme.setReducedMotion(false);
    saw_entrance_for_test = false;
    try @import("native_capture.zig").capture(390, 480, "audio-connection-entering", null, drawPromptFixture, null);
    try std.testing.expect(saw_entrance_for_test);
}
