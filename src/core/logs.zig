const std = @import("std");
const dvui = @import("dvui");

pub const LogEntry = struct {
    timestamp: i64,
    level: []const u8,
    prefix: []const u8,
    text: []const u8,
    is_error: bool,
};

// ── Ring buffer for O(1) log eviction ──
const MAX_LOGS = 1024;
var log_ring: [MAX_LOGS]LogEntry = undefined;
var log_head: usize = 0; // next write position
var log_count: usize = 0;
var log_mutex: @import("sync.zig").Mutex = .{};

pub var show_logs_ui: bool = false;
pub var logs_allocator: std.mem.Allocator = undefined;
pub var show_only_errors: bool = false;

// ── Public accessors for ring buffer ──
pub fn logCount() usize {
    return log_count;
}

pub fn getLog(index: usize) *const LogEntry {
    return getLogAt(index);
}

pub fn clearAll() void {
    var ci: usize = 0;
    while (ci < log_count) : (ci += 1) {
        const entry = getLogAt(ci);
        logs_allocator.free(entry.level);
        logs_allocator.free(entry.prefix);
        logs_allocator.free(entry.text);
    }
    log_count = 0;
    log_head = 0;
}

/// Free all log entries — call during app shutdown to prevent GPA leak reports
pub fn deinit() void {
    log_mutex.lock();
    defer log_mutex.unlock();
    clearAll();
}

pub fn pushLog(level: []const u8, prefix: []const u8, text: []const u8, is_error: bool) void {
    // Severity is derived from `level`, not the call-site `is_error` bool: that
    // bool was set inconsistently across the codebase (dozens of plain "info"
    // logs passed `true`), which painted the whole Logs view red. `level`
    // ("info"/"warn"/"error"/…) is the reliable signal. The param is kept for
    // source compatibility but a non-error level can no longer render as error.
    const effective_error = is_error and
        !std.ascii.eqlIgnoreCase(level, "info") and
        !std.ascii.eqlIgnoreCase(level, "debug") and
        !std.ascii.eqlIgnoreCase(level, "warn") and
        !std.ascii.eqlIgnoreCase(level, "trace");

    // Clean up trailing newlines from MPV
    var clean_text = text;
    while (clean_text.len > 0 and (clean_text[clean_text.len - 1] == '\n' or clean_text[clean_text.len - 1] == '\r')) {
        clean_text = clean_text[0 .. clean_text.len - 1];
    }

    log_mutex.lock();
    defer log_mutex.unlock();

    // Free old entry if ring is full (O(1) — no shifting)
    if (log_count >= MAX_LOGS) {
        const old = &log_ring[log_head];
        logs_allocator.free(old.level);
        logs_allocator.free(old.prefix);
        logs_allocator.free(old.text);
    }

    const new_level = logs_allocator.dupe(u8, level) catch return;
    const new_prefix = logs_allocator.dupe(u8, prefix) catch {
        logs_allocator.free(new_level);
        return;
    };
    const new_text = logs_allocator.dupe(u8, clean_text) catch {
        logs_allocator.free(new_level);
        logs_allocator.free(new_prefix);
        return;
    };

    log_ring[log_head] = .{
        .timestamp = @import("io_global.zig").milliTimestamp(),
        .level = new_level,
        .prefix = new_prefix,
        .text = new_text,
        .is_error = effective_error,
    };
    log_head = (log_head + 1) % MAX_LOGS;
    if (log_count < MAX_LOGS) log_count += 1;
}

/// Iterate logs in chronological order (oldest first)
fn getLogAt(index: usize) *const LogEntry {
    // Oldest log is at (head - count) mod MAX_LOGS
    const start = (log_head + MAX_LOGS - log_count) % MAX_LOGS;
    return &log_ring[(start + index) % MAX_LOGS];
}

pub fn renderDevLogWindow() void {
    if (!show_logs_ui) return;

    var opts = dvui.Options{ .id_extra = 99999, .color_fill = dvui.Color{ .r = 10, .g = 10, .b = 15, .a = 240 }, .color_border = dvui.Color{ .r = 80, .g = 30, .b = 30, .a = 255 }, .border = dvui.Rect.all(2) };
    var overlay = dvui.overlay(@src(), .{});
    defer overlay.deinit();

    opts.min_size_content = .{ .w = 700, .h = 600 };
    var vbox = dvui.box(@src(), .{ .dir = .vertical }, opts);
    defer vbox.deinit();

    _ = dvui.label(@src(), "Developer Console & Logs", .{}, .{});

    var controls = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .x = 0, .y = 0, .w = 0, .h = 10 } });
    {
        defer controls.deinit();
        if (dvui.button(@src(), if (show_only_errors) "Showing: Errors Only" else "Showing: All Logs", .{}, .{})) {
            show_only_errors = !show_only_errors;
        }
        if (dvui.button(@src(), "Clear", .{}, .{})) {
            log_mutex.lock();
            defer log_mutex.unlock();
            clearAll();
        }
        if (dvui.button(@src(), "Close", .{}, .{})) {
            show_logs_ui = false;
        }
    }

    // background=false: don't paint the scrollArea's own (default light theme)
    // fill — it would render as a pale box over this dark dev-log window. Let the
    // dark window (vbox color_fill above) show through. (User report: the Logs
    // tab "doesn't respect theme colors.")
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false });
    defer scroll.deinit();
    var inner = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    defer inner.deinit();

    var li: usize = 0;
    while (li < log_count) : (li += 1) {
        const l = getLogAt(li);
        if (show_only_errors and !l.is_error) continue;
        const col = if (l.is_error) dvui.Color{ .r = 255, .g = 80, .b = 80, .a = 255 } else dvui.Color{ .r = 180, .g = 180, .b = 180, .a = 255 };
        _ = dvui.labelNoFmt(@src(), l.text, .{}, .{ .id_extra = li, .color_text = col });
    }
}
