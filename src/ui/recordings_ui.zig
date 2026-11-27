//! Live TV recording UI (issue #240): the "Record" panel a channel card opens,
//! and the list of scheduled / running / finished recordings. Scheduling and
//! ffmpeg live in services/recorder.zig; this file only draws and dispatches.

const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme.zig");
const components = @import("components.zig");
const icons = @import("icons");
const io = @import("../core/io_global.zig");
const recorder = @import("../services/recorder.zig");
const epg = @import("../services/epg.zig");
const ipure = @import("../services/iptv_pure.zig");

/// The channel the Record panel is open for (a copy: the results grid is
/// rewritten by fetch workers).
var target: ?ipure.IptvChannel = null;
var start_choice: usize = 0;
var length_choice: usize = 1;
var message: [160]u8 = undefined;
var message_len: usize = 0;

const START_LABELS = [_][]const u8{ "Now", "In 15 min", "In 30 min", "In 1 h", "In 2 h" };
const START_OFFSETS = [_]i64{ 0, 15 * 60, 30 * 60, 3600, 2 * 3600 };
const LENGTH_LABELS = [_][]const u8{ "30 min", "1 h", "2 h", "3 h", "4 h" };
const LENGTH_SECS = [_]u32{ 30 * 60, 3600, 2 * 3600, 3 * 3600, 4 * 3600 };

pub fn openFor(ch: *const ipure.IptvChannel) void {
    target = ch.*;
    message_len = 0;
}

fn setMessage(text: []const u8) void {
    message_len = @min(text.len, message.len);
    @memcpy(message[0..message_len], text[0..message_len]);
}

fn scheduleFor(ch: *const ipure.IptvChannel, start_s: i64, duration_s: u32) void {
    const name = ch.name[0..@min(ch.name_len, ch.name.len)];
    const url = ch.url[0..@min(ch.url_len, ch.url.len)];
    const ua = ch.user_agent[0..@min(ch.user_agent_len, ch.user_agent.len)];
    const ref = ch.referrer[0..@min(ch.referrer_len, ch.referrer.len)];
    if (recorder.schedule(name, url, ua, ref, start_s, duration_s)) |_| {
        target = null;
    } else |err| setMessage(switch (err) {
        error.InvalidStream => "This channel's stream can't be recorded.",
        error.InvalidDuration => "Pick a length between 1 minute and 12 hours.",
        error.AlreadyOver => "That programme has already ended.",
        error.TooLong => "This channel's details are too long to save.",
        error.Full => "Too many recordings. Remove finished ones first.",
    });
}

/// The Record panel (when open) and the recordings list (when any exist).
pub fn render() void {
    if (target) |*ch| renderPanel(ch);
    renderList();
}

fn renderPanel(ch: *const ipure.IptvChannel) void {
    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = theme.colors.bg_surface },
        .corners = theme.dims.rad_lg,
        .padding = dvui.Rect.all(theme.spacing.md),
        .margin = .{ .x = theme.spacing.sm, .y = theme.spacing.sm, .w = theme.spacing.sm, .h = 0 },
    });
    defer panel.deinit();

    var title_buf: [200]u8 = undefined;
    const name = ch.name[0..@min(ch.name_len, ch.name.len)];
    components.sectionHeader(std.fmt.bufPrint(&title_buf, "Record {s}", .{name}) catch "Record");

    if (!recorder.ffmpegAvailable()) {
        components.bodyText(@src(), "Recording needs ffmpeg. Install it (macOS: brew install ffmpeg; Linux: your package manager), then come back.", theme.colors.danger);
    }

    // Programme guide shortcuts: the programme on air (rest of it) or the next.
    const now = io.timestamp();
    if (epg.nowNextFor(ch, now)) |info| {
        if (info.now) |slot| {
            var b: [220]u8 = undefined;
            var clk: [16]u8 = undefined;
            const label = std.fmt.bufPrint(&b, "This programme: {s} (until {s})", .{ slot.titleSlice(), epg.clock(slot.stop, &clk) }) catch "This programme";
            if (components.actionButton(@src(), label, .secondary, 1)) scheduleFor(ch, now, @intCast(@max(60, slot.stop - now)));
        }
        if (info.next) |slot| {
            var b: [220]u8 = undefined;
            var clk: [32]u8 = undefined;
            const label = std.fmt.bufPrint(&b, "Next: {s} ({s})", .{ slot.titleSlice(), epg.dayClock(slot.start, now, &clk) }) catch "Next programme";
            if (components.actionButton(@src(), label, .secondary, 2)) scheduleFor(ch, slot.start, @intCast(@max(60, slot.stop - slot.start)));
        }
    }

    components.bodyText(@src(), "Start", theme.colors.text_secondary);
    if (components.segment(@src(), &START_LABELS, start_choice)) |i| start_choice = i;
    components.bodyText(@src(), "Length", theme.colors.text_secondary);
    if (components.segment(@src(), &LENGTH_LABELS, length_choice)) |i| length_choice = i;

    var dir_buf: [600]u8 = undefined;
    var where: [700]u8 = undefined;
    components.bodyText(@src(), std.fmt.bufPrint(&where, "Saved to {s}", .{recorder.recordingsDir(&dir_buf)}) catch "", theme.colors.text_tertiary);
    if (message_len > 0) components.bodyText(@src(), message[0..message_len], theme.colors.danger);

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 } });
    defer row.deinit();
    if (components.actionButton(@src(), "Schedule recording", .primary, 3)) {
        scheduleFor(ch, now + START_OFFSETS[start_choice], LENGTH_SECS[length_choice]);
    }
    if (components.actionButton(@src(), "Close", .secondary, 4)) target = null;
}

fn renderList() void {
    var jobs: [32]recorder.Job = undefined;
    const n = recorder.snapshot(&jobs);
    if (n == 0) return;

    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .margin = .{ .x = theme.spacing.sm, .y = theme.spacing.sm, .w = theme.spacing.sm, .h = 0 },
    });
    defer box.deinit();
    components.sectionHeader("Recordings");

    const now = io.timestamp();
    for (jobs[0..n], 0..) |*job, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = theme.colors.bg_surface },
            .corners = theme.dims.rad_sm,
            .padding = dvui.Rect.all(theme.spacing.sm),
            .margin = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
        });
        defer row.deinit();

        dvui.icon(@src(), "", if (job.status == .recording) icons.tvg.lucide.@"circle-dot" else icons.tvg.lucide.@"radio-tower", .{}, .{
            .id_extra = i,
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 16, .h = 16 },
            .color_text = .{ .color = if (job.status == .recording) theme.colors.danger else theme.colors.text_secondary },
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        });
        var text_buf: [300]u8 = undefined;
        var a: [32]u8 = undefined;
        var b: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&text_buf, "{s} · {s} · {s} – {s}", .{
            job.status.label(), job.nameSlice(), epg.dayClock(job.start_s, now, &a), epg.clock(job.endS(), &b),
        }) catch job.nameSlice();
        dvui.labelNoFmt(@src(), text, .{}, .{
            .id_extra = i,
            .gravity_y = 0.5,
            .expand = .horizontal,
            .color_text = .{ .color = if (job.status == .failed) theme.colors.danger else theme.colors.text_primary },
        });

        const base: usize = 9100 + i * 4;
        if (job.status == .done and job.out_len > 0) {
            if (components.actionButton(@src(), "Play", .primary, base)) @import("../services/browser.zig").loadContentDirect(job.outSlice());
        }
        if (job.status == .scheduled or job.status == .recording) {
            if (components.actionButton(@src(), if (job.status == .recording) "Stop" else "Cancel", .secondary, base + 1)) recorder.cancel(job.id);
        } else if (components.actionButton(@src(), "Remove", .secondary, base + 2)) recorder.remove(job.id);
    }
}
