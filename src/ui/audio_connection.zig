//! Audio output arrival prompt. All mpv writes happen on the UI owner thread.
const std = @import("std");
const dvui = @import("dvui");
const c = @import("../core/c.zig");
const state = @import("../core/state.zig");
const io = @import("../core/io_global.zig");
const pure = @import("../player/av_device_pure.zig");
const player = @import("../player/player.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const icons = @import("icons");
var saw_entrance_for_test = false;

var connections: pure.Connections = .{};
var pending: ?pure.AudioDevice = null;
var last_poll: i64 = 0;
var missing_output: pure.MissingOutput = .{};
var dropped_audio: pure.DroppedAudio = .{};

fn pauseAll() void {
    for (state.app.players.items) |p| {
        var paused: c_int = 1;
        _ = c.mpv.mpv_set_property(p.mpv_ctx, "pause", c.mpv.MPV_FORMAT_FLAG, &paused);
    }
}

/// Does the loaded file have an audio track at all? `track-list` is populated
/// once the demuxer has opened, so this is also the "file is far enough along
/// to judge" check the recovery relies on.
fn hasAudioTrack(p: *player.MediaPlayer) bool {
    var count: i64 = 0;
    if (c.mpv.mpv_get_property(p.mpv_ctx, "track-list/count", c.mpv.MPV_FORMAT_INT64, &count) < 0) return false;

    var i: i64 = 0;
    while (i < count and i < 64) : (i += 1) {
        var q: [64]u8 = undefined;
        const query = @import("../core/fmt_compat.zig").bufPrintZ(&q, "track-list/{d}/type", .{i}) catch break;
        const typ = c.mpv.mpv_get_property_string(p.mpv_ctx, query.ptr);
        if (typ == null) continue;
        defer c.mpv.mpv_free(@ptrCast(typ));
        if (std.mem.eql(u8, std.mem.span(typ), "audio")) return true;
    }
    return false;
}

/// The file has audio but mpv is not playing it (`aid` == "no").
fn audioSilent(p: *player.MediaPlayer) bool {
    const aid = c.mpv.mpv_get_property_string(p.mpv_ctx, "aid");
    if (aid == null) return false;
    defer c.mpv.mpv_free(@ptrCast(aid));
    if (!std.mem.eql(u8, std.mem.span(aid), "no")) return false;
    return hasAudioTrack(p);
}

/// The audio driver refused to open the forced device. mpv reports that only by
/// dropping the track, so the failure is "silent with a specific device forced".
fn audioDroppedBy(p: *player.MediaPlayer) bool {
    if (p.audio_off_intent) return false; // the viewer asked for silence

    const dev = c.mpv.mpv_get_property_string(p.mpv_ctx, "audio-device");
    if (dev == null) return false;
    defer c.mpv.mpv_free(@ptrCast(dev));
    if (!pure.isForcedDevice(std.mem.span(dev))) return false;

    return audioSilent(p);
}

/// Re-open the audio chain. Changing `audio-device` alone does NOT bring the
/// track back: mpv has already given up on it for this file. Re-selecting the
/// track is what re-runs output setup — at the current position, no reload.
fn reinitAudio(p: *player.MediaPlayer) void {
    // Both disconnected-device and refused-device recovery come through here.
    if (p.audio_off_intent) return;
    _ = c.mpv.mpv_set_property_string(p.mpv_ctx, "aid", "no");
    _ = c.mpv.mpv_set_property_string(p.mpv_ctx, "aid", "auto");
}

/// The forced output could not be opened: drop to `auto` (which lets mpv pick a
/// driver that works) and re-open the track. Persist the fallback, otherwise the
/// next launch forces the same dead device and every video is silent again.
fn recoverDroppedAudio() void {
    var recovered = false;
    for (state.app.players.items) |p| {
        if (!audioDroppedBy(p)) continue;
        const dev = c.mpv.mpv_get_property_string(p.mpv_ctx, "audio-device") orelse continue;
        defer c.mpv.mpv_free(@ptrCast(dev));
        if (c.mpv.mpv_set_property_string(p.mpv_ctx, "audio-device", "auto") < 0) continue;
        reinitAudio(p);
        recovered = true;
        if (std.mem.eql(u8, state.app.audio_device_buf[0..state.app.audio_device_len], std.mem.span(dev))) {
            @memset(&state.app.audio_device_buf, 0);
            state.app.audio_device_len = 0;
            state.markConfigDirty();
        }
    }

    dropped_audio = .{};
    if (recovered) state.showToast("Audio output could not be opened. Switched to automatic output.");
}

pub fn render() void {
    if (state.app.players.items.len == 0) {
        connections = .{};
        pending = null;
        missing_output = .{};
        dropped_audio = .{};
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
            // A partial or saturated list cannot prove that an output vanished.
            const raw = std.mem.trim(u8, std.mem.span(json), " \t\r\n");
            const complete = raw.len >= 2 and raw[0] == '[' and raw[raw.len - 1] == ']' and count < devices.len and pure.Connections.contains(devices[0..count], "auto");
            if (count > 0) {
                if (complete) {
                    const current = c.mpv.mpv_get_property_string(p.mpv_ctx, "audio-device");
                    if (current != null) {
                        defer c.mpv.mpv_free(@ptrCast(current));
                        const selected = std.mem.span(current);
                        if (missing_output.update(selected, devices[0..count]) and c.mpv.mpv_set_property_string(p.mpv_ctx, "audio-device", "auto") >= 0) {
                            // Switching the device is not enough if the open
                            // already failed: the track stays dropped until it
                            // is re-selected.
                            if (audioSilent(p)) reinitAudio(p);
                            for (state.app.players.items) |sibling| {
                                if (sibling == p) continue;
                                const other = c.mpv.mpv_get_property_string(sibling.mpv_ctx, "audio-device");
                                if (other != null) {
                                    defer c.mpv.mpv_free(@ptrCast(other));
                                    if (std.mem.eql(u8, std.mem.span(other), selected)) {
                                        const sibling_silent = audioSilent(sibling);
                                        _ = c.mpv.mpv_set_property_string(sibling.mpv_ctx, "audio-device", "auto");
                                        if (sibling_silent) reinitAudio(sibling);
                                    }
                                }
                            }
                            dropped_audio = .{};
                            if (std.mem.eql(u8, state.app.audio_device_buf[0..state.app.audio_device_len], selected)) {
                                @memset(&state.app.audio_device_buf, 0);
                                state.app.audio_device_len = 0;
                                state.markConfigDirty();
                            }
                            missing_output = .{};
                            state.showToast("Audio output disconnected. Switched to automatic output.");
                        }
                    }
                } else missing_output = .{};
                if (pending) |device| {
                    if (!pure.Connections.contains(devices[0..count], device.nameSlice())) pending = null;
                }
                if (connections.update(devices[0..count])) |device| {
                    pauseAll();
                    pending = device;
                }
            } else missing_output = .{};
        } else missing_output = .{};

        // A device that is still listed but refuses to open leaves mpv playing
        // video with no audio (it drops the track). Detect that separately: the
        // "disconnected" path above can never see it.
        var any_dropped = false;
        for (state.app.players.items) |pl| {
            if (audioDroppedBy(pl)) {
                any_dropped = true;
                break;
            }
        }
        if (dropped_audio.update(any_dropped)) recoverDroppedAudio();
    }
    renderPrompt();
}

fn renderPrompt() void {
    const device = pending orelse return;
    var open = true;
    const size = theme.fitWindowSize(.{ .w = 360, .h = 220 }, .{ .w = 280, .h = 220 });
    var win = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &open, .resize = .none }, .{
        .min_size_content = size,
        .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_elevated),
        .corners = theme.dims.rad_lg,
    });
    defer win.deinit();
    win.autoPosition();
    win.autoSize();
    win.dragAreaSet(dvui.windowHeader("Audio output", "", &open));
    if (!open) {
        pending = null;
        return;
    }
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
    var body_font = dvui.themeGet().font_body;
    body_font.size = theme.font_size.body;
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .font = body_font,
        .expand = .both,
        .padding = theme.dims.pad_md,
    });
    defer body.deinit();
    components.bodyText(@src(), "Switch to this connected device?", theme.colors.text_secondary);
    {
        var device_card = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_surface),
            .corners = dvui.CornerRect.all(theme.radius.md),
            .padding = theme.dims.pad_sm,
            .margin = .{ .y = theme.spacing.sm, .h = theme.spacing.sm },
        });
        defer device_card.deinit();
        dvui.icon(@src(), "Audio output", icons.tvg.lucide.speaker, .{}, .{
            .min_size_content = theme.iconSize(.sm),
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary),
            .gravity_y = 0.5,
            .margin = .{ .w = theme.spacing.md },
        });
        var details = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
        defer details.deinit();
        components.bodyText(@src(), @import("../core/text.zig").safeUtf8(device.label()), theme.colors.text_primary);
    }
    components.bodyText(@src(), "Press play to resume after switching.", theme.colors.text_tertiary);
    var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = theme.spacing.sm } });
    var action_spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
    action_spacer.deinit();
    {
        var dismiss = dvui.box(@src(), .{}, .{ .margin = .{ .w = theme.spacing.sm, .h = theme.spacing.sm } });
        defer dismiss.deinit();
        if (components.actionButton(@src(), "Not now", .secondary, 1)) pending = null;
    }
    if (components.actionButton(@src(), "Switch output", .primary, 0)) {
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

test "Native shell offline audio connection recovery preserves audio off" {
    const ctx = c.mpv.mpv_create() orelse return error.MpvCreateFailed;
    defer c.mpv.mpv_terminate_destroy(ctx);
    _ = c.mpv.mpv_set_option_string(ctx, "config", "no");
    if (c.mpv.mpv_initialize(ctx) < 0) return error.MpvInitFailed;
    var p: player.MediaPlayer = undefined;
    p.mpv_ctx = ctx;
    p.audio_off_intent = true;
    try std.testing.expect(c.mpv.mpv_set_property_string(ctx, "aid", "no") >= 0);
    reinitAudio(&p);
    const aid = c.mpv.mpv_get_property_string(ctx, "aid") orelse return error.MissingAid;
    defer c.mpv.mpv_free(@ptrCast(aid));
    try std.testing.expectEqualStrings("no", std.mem.span(aid));
    p.audio_off_intent = false;
    reinitAudio(&p);
    const enabled = c.mpv.mpv_get_property_string(ctx, "aid") orelse return error.MissingAid;
    defer c.mpv.mpv_free(@ptrCast(enabled));
    try std.testing.expectEqualStrings("auto", std.mem.span(enabled));

    // A separate player's explicit off choice must not suppress this player.
    const other_ctx = c.mpv.mpv_create() orelse return error.MpvCreateFailed;
    defer c.mpv.mpv_terminate_destroy(other_ctx);
    _ = c.mpv.mpv_set_option_string(other_ctx, "config", "no");
    if (c.mpv.mpv_initialize(other_ctx) < 0) return error.MpvInitFailed;
    var other: player.MediaPlayer = undefined;
    other.mpv_ctx = other_ctx;
    other.audio_off_intent = true;
    _ = c.mpv.mpv_set_property_string(other_ctx, "aid", "no");
    _ = c.mpv.mpv_set_property_string(ctx, "audio-device", "null");
    var players = [_]*player.MediaPlayer{ &p, &other };
    const previous_players = state.app.players;
    defer state.app.players = previous_players;
    state.app.players = .{ .items = &players, .capacity = players.len };
    recoverDroppedAudio();
    const device = c.mpv.mpv_get_property_string(ctx, "audio-device") orelse return error.MissingDevice;
    defer c.mpv.mpv_free(@ptrCast(device));
    try std.testing.expectEqualStrings("null", std.mem.span(device));
    reinitAudio(&p);
    const other_aid = c.mpv.mpv_get_property_string(other_ctx, "aid") orelse return error.MissingAid;
    defer c.mpv.mpv_free(@ptrCast(other_aid));
    try std.testing.expectEqualStrings("no", std.mem.span(other_aid));
}
