const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const logs = @import("../core/logs.zig");
const alloc = @import("../core/alloc.zig").allocator;

// ══════════════════════════════════════════════════════════
// Camoufox Browser Engine — CDP screenshot streaming
// Replaces LightPanda with real Firefox rendering + anti-bot
// ══════════════════════════════════════════════════════════

const BRIDGE_SCRIPT = "camoufox_bridge.py";

// Resolve the venv python under the zigzag config dir (~/.config/zigzag/venv/bin/python3).
// Returns null if $HOME is unset. Falls back to bare "python3" handled by callers.
fn getVenvPython() ?[]const u8 {
    const home = @import("../core/io_global.zig").getenv("HOME") orelse return null;
    const S = struct {
        var buf: [512]u8 = undefined;
    };
    return std.fmt.bufPrint(&S.buf, "{s}/.config/zigzag/venv/bin/python3", .{home}) catch null;
}

// Bridge process state (singleton — one browser instance shared across all panes)
var bridge_process: ?@import("../core/io_global.zig").Child = null;
var bridge_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var bridge_starting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var bridge_reader_thread: ?std.Thread = null;

// Frame buffer — latest screenshot from Camoufox
var frame_jpeg: ?[]u8 = null;
var frame_jpeg_len: usize = 0;
var frame_texture: ?dvui.Texture = null;
var frame_w: u32 = 0;
var frame_h: u32 = 0;
var frame_dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var frame_lock: @import("../core/sync.zig").Mutex = .{};

// JSON response buffer
var json_response: [8192]u8 = undefined;
var json_response_len: usize = 0;
var json_response_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// Pending navigate URL (queued before bridge is ready)
var pending_url: [2048]u8 = undefined;
var pending_url_len: usize = 0;

// ── Bridge lifecycle ──

fn getBridgePath() ?[]const u8 {
    const io = @import("../core/io_global.zig");

    // 1) Look for camoufox_bridge.py relative to the working dir (bundled scripts dir).
    const rel = "scripts/" ++ BRIDGE_SCRIPT;
    if (io.cwdAccess(rel, .{})) |_| {
        return rel;
    } else |_| {}

    // 2) Look under the zigzag config dir (~/.config/zigzag/scripts/camoufox_bridge.py).
    if (io.getenv("HOME")) |home| {
        const S = struct {
            var buf: [512]u8 = undefined;
        };
        const p = std.fmt.bufPrint(&S.buf, "{s}/.config/zigzag/scripts/{s}", .{ home, BRIDGE_SCRIPT }) catch return null;
        if (io.cwdAccess(p, .{})) |_| {
            return p;
        } else |_| {}
    }

    return null;
}

pub fn ensureBridge() void {
    if (bridge_ready.load(.acquire) or bridge_starting.load(.acquire)) return;
    bridge_starting.store(true, .release);

    _ = std.Thread.spawn(.{}, startBridgeThread, .{}) catch {
        bridge_starting.store(false, .release);
        logs.pushLog("error", "browser", "Failed to spawn bridge thread", false);
    };
}

fn startBridgeThread() void {
    defer bridge_starting.store(false, .release);

    const script_path = getBridgePath() orelse {
        logs.pushLog("error", "browser", "camoufox_bridge.py not found", false);
        return;
    };

    // Resolve and check the venv python under the zigzag config dir.
    const venv_python = getVenvPython() orelse {
        logs.pushLog("error", "browser", "$HOME not set — cannot locate Python venv", false);
        return;
    };
    @import("../core/io_global.zig").cwdAccess(venv_python, .{}) catch {
        logs.pushLog("error", "browser", "Python venv not found — run install", false);
        return;
    };

    logs.pushLog("info", "browser", "Starting Camoufox browser...", true);

    const argv = [_][]const u8{ venv_python, script_path };
    var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    _ = child.spawn() catch {
        logs.pushLog("error", "browser", "Failed to spawn Camoufox bridge", false);
        return;
    };

    bridge_process = child;

    // Start reader thread to process stdout
    bridge_reader_thread = std.Thread.spawn(.{}, bridgeReaderThread, .{}) catch null;

    // Wait for ready signal (up to 15 seconds)
    var waited: usize = 0;
    while (waited < 150) : (waited += 1) {
        if (bridge_ready.load(.acquire)) {
            logs.pushLog("info", "browser", "Camoufox ready", true);

            // Send any pending navigate command
            if (pending_url_len > 0) {
                var esc_buf: [4096]u8 = undefined;
                const esc_url = escapeJsonString(pending_url[0..pending_url_len], &esc_buf);
                var cmd_buf: [4200]u8 = undefined;
                const pcmd = std.fmt.bufPrint(&cmd_buf, "{{\"cmd\":\"navigate\",\"url\":\"{s}\"}}", .{esc_url}) catch return;
                sendCommand(pcmd);
                pending_url_len = 0;
            }
            return;
        }
        @import("../core/io_global.zig").sleep(100 * std.time.ns_per_ms);
    }

    logs.pushLog("error", "browser", "Camoufox startup timeout", false);
}

fn bridgeReaderThread() void {
    const proc = bridge_process orelse return;
    const stdout_pipe = proc.stdout orelse return;
    const stdout = stdout_pipe;

    while (true) {
        // Read tag byte: 'J' for JSON, 'F' for frame
        var tag: [1]u8 = undefined;
        const n = @import("../core/io_global.zig").read(stdout, &tag) catch break;
        if (n == 0) break;

        if (tag[0] == 'J') {
            // JSON response — read until newline
            var buf: [8192]u8 = undefined;
            var pos: usize = 0;
            while (pos < buf.len) {
                var ch: [1]u8 = undefined;
                const cn = @import("../core/io_global.zig").read(stdout, &ch) catch break;
                if (cn == 0) break;
                if (ch[0] == '\n') break;
                buf[pos] = ch[0];
                pos += 1;
            }

            if (pos > 0) {
                // Check for ready signal
                if (std.mem.indexOf(u8, buf[0..pos], "\"ready\"")) |_| {
                    bridge_ready.store(true, .release);
                }

                // Check for title update (navigate response)
                if (std.mem.indexOf(u8, buf[0..pos], "\"title\"")) |_| {
                    // Extract title from JSON
                    if (extractJsonField(buf[0..pos], "title")) |title| {
                        const b = &state.app.browser;
                        const tlen = @min(title.len, 255);
                        @memcpy(b.title[0..tlen], title[0..tlen]);
                        b.title_len = tlen;
                        b.is_loading = false;
                    }
                    // Extract url
                    if (extractJsonField(buf[0..pos], "url")) |url| {
                        const b = &state.app.browser;
                        const ulen = @min(url.len, 2047);
                        @memcpy(b.url_buf[0..ulen], url[0..ulen]);
                        b.url_len = ulen;
                    }
                    // Auto-request screenshot after navigation
                    sendCommand("{\"cmd\":\"screenshot\"}");
                }

                // Store for general use
                @memcpy(json_response[0..pos], buf[0..pos]);
                json_response_len = pos;
                json_response_ready.store(true, .release);
            }
        } else if (tag[0] == 'F') {
            // Frame: 4-byte big-endian length + JPEG data
            var len_buf: [4]u8 = undefined;
            var len_read: usize = 0;
            while (len_read < 4) {
                const lr = @import("../core/io_global.zig").read(stdout, len_buf[len_read..4]) catch break;
                if (lr == 0) break;
                len_read += lr;
            }
            if (len_read < 4) continue;

            const frame_size = @as(usize, len_buf[0]) << 24 |
                @as(usize, len_buf[1]) << 16 |
                @as(usize, len_buf[2]) << 8 |
                @as(usize, len_buf[3]);

            if (frame_size == 0 or frame_size > 5 * 1024 * 1024) continue;

            // Read JPEG data
            const jpeg_buf = alloc.alloc(u8, frame_size) catch continue;
            var total_read: usize = 0;
            while (total_read < frame_size) {
                const fr = @import("../core/io_global.zig").read(stdout, jpeg_buf[total_read..frame_size]) catch break;
                if (fr == 0) break;
                total_read += fr;
            }

            if (total_read == frame_size) {
                frame_lock.lock();
                if (frame_jpeg) |old| alloc.free(old);
                frame_jpeg = jpeg_buf;
                frame_jpeg_len = frame_size;
                frame_dirty.store(true, .release);
                frame_lock.unlock();

                // Mark loading done
                state.app.browser.is_loading = false;
            } else {
                alloc.free(jpeg_buf);
            }
        }
    }

    bridge_ready.store(false, .release);
    logs.pushLog("info", "browser", "Camoufox bridge disconnected", false);
}

fn sendCommand(cmd: []const u8) void {
    var proc = bridge_process orelse return;
    if (proc.stdin) |*stdin| {
        @import("../core/io_global.zig").writeAll(stdin, cmd) catch return;
        @import("../core/io_global.zig").writeAll(stdin, "\n") catch return;
    }
}

fn sendCommandFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, fmt, args) catch return;
    sendCommand(cmd);
}

fn extractJsonField(json: []const u8, field: []const u8) ?[]const u8 {
    // Simple JSON field extractor — finds "field":"value"
    var search_buf: [64]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{field}) catch return null;

    const field_pos = std.mem.indexOf(u8, json, search) orelse return null;
    var pos = field_pos + search.len;

    // Skip colon and whitespace
    while (pos < json.len and (json[pos] == ':' or json[pos] == ' ')) pos += 1;
    if (pos >= json.len or json[pos] != '"') return null;
    pos += 1; // skip opening quote

    const end = std.mem.indexOfScalar(u8, json[pos..], '"') orelse return null;
    return json[pos .. pos + end];
}

/// Escape a string for safe JSON interpolation — escapes \\ and \"
fn escapeJsonString(input: []const u8, buf: *[4096]u8) []const u8 {
    var out: usize = 0;
    for (input) |ch| {
        if (out + 2 > buf.len) break;
        if (ch == '\\') {
            buf[out] = '\\';
            out += 1;
            buf[out] = '\\';
            out += 1;
        } else if (ch == '"') {
            buf[out] = '\\';
            out += 1;
            buf[out] = '"';
            out += 1;
        } else {
            buf[out] = ch;
            out += 1;
        }
    }
    return buf[0..out];
}

// ── Public API ──

pub fn navigate(url: []const u8) void {
    const b = &state.app.browser;
    if (url.len == 0 or url.len >= 2048) return;

    // Store URL
    const buf_ptr: [*]const u8 = @ptrCast(&b.url_buf[0]);
    if (url.ptr != buf_ptr) {
        @memcpy(b.url_buf[0..url.len], url);
    }
    b.url_len = url.len;
    b.is_loading = true;
    b.title_len = 0;

    // Push to history
    if (!state.app.incognito_mode and b.history_count < 32) {
        const hi = b.history_count;
        @memcpy(b.history[hi][0..url.len], url);
        b.history_lens[hi] = url.len;
        b.history_count += 1;
        b.history_pos = b.history_count;
    }

    if (bridge_ready.load(.acquire)) {
        // Bridge is running — send navigate immediately
        var esc_buf: [4096]u8 = undefined;
        const esc_url = escapeJsonString(url, &esc_buf);
        var cmd_buf: [4200]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "{{\"cmd\":\"navigate\",\"url\":\"{s}\"}}", .{esc_url}) catch return;
        sendCommand(cmd);
    } else {
        // Bridge not ready yet — queue URL for when it starts
        const ulen = @min(url.len, 2047);
        @memcpy(pending_url[0..ulen], url[0..ulen]);
        pending_url_len = ulen;
        ensureBridge();
    }
}

pub fn sendClick(x: f32, y: f32) void {
    if (!bridge_ready.load(.acquire)) return;
    sendCommandFmt("{{\"cmd\":\"click\",\"x\":{d},\"y\":{d}}}", .{ @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)) });
}

pub fn sendScroll(dy: f32) void {
    if (!bridge_ready.load(.acquire)) return;
    sendCommandFmt("{{\"cmd\":\"scroll\",\"dx\":0,\"dy\":{d}}}", .{@as(i32, @intFromFloat(dy * 100))});
}

pub fn sendKeypress(key: []const u8) void {
    if (!bridge_ready.load(.acquire)) return;
    var esc_buf: [4096]u8 = undefined;
    const esc_key = escapeJsonString(key, &esc_buf);
    sendCommandFmt("{{\"cmd\":\"keypress\",\"key\":\"{s}\"}}", .{esc_key});
}

pub fn sendType(text: []const u8) void {
    if (!bridge_ready.load(.acquire)) return;
    var esc_buf: [4096]u8 = undefined;
    const esc_text = escapeJsonString(text, &esc_buf);
    sendCommandFmt("{{\"cmd\":\"type\",\"text\":\"{s}\"}}", .{esc_text});
}

pub fn requestScreenshot() void {
    if (!bridge_ready.load(.acquire)) return;
    sendCommand("{\"cmd\":\"screenshot\"}");
}

pub fn goBack() void {
    if (!bridge_ready.load(.acquire)) return;
    sendCommand("{\"cmd\":\"back\"}");
}

pub fn goForward() void {
    if (!bridge_ready.load(.acquire)) return;
    sendCommand("{\"cmd\":\"forward\"}");
}

pub fn killBridge() void {
    if (bridge_process) |*proc| {
        // Send quit command gracefully
        if (proc.stdin) |*stdin| {
            _ = stdin.write("{\"cmd\":\"quit\"}\n") catch {};
        }
        @import("../core/io_global.zig").sleep(500 * std.time.ns_per_ms);
        _ = proc.kill() catch {};
        _ = proc.wait() catch {};
        bridge_process = null;
    }
    bridge_ready.store(false, .release);
    bridge_starting.store(false, .release);
}

const enums = @import("dvui").enums;

/// Map dvui Key enum to Playwright key name string
fn mapKeyToPlaywright(key: enums.Key) ?[]const u8 {
    return switch (key) {
        .enter => "Enter",
        .backspace => "Backspace",
        .tab => "Tab",
        .escape => "Escape",
        .space => "Space",
        .delete => "Delete",
        .home => "Home",
        .end => "End",
        .page_up => "PageUp",
        .page_down => "PageDown",
        .left => "ArrowLeft",
        .right => "ArrowRight",
        .up => "ArrowUp",
        .down => "ArrowDown",
        .a => "a",
        .b => "b",
        .c => "c",
        .d => "d",
        .e => "e",
        .f => "f",
        .g => "g",
        .h => "h",
        .i => "i",
        .j => "j",
        .k => "k",
        .l => "l",
        .m => "m",
        .n => "n",
        .o => "o",
        .p => "p",
        .q => "q",
        .r => "r",
        .s => "s",
        .t => "t",
        .u => "u",
        .v => "v",
        .w => "w",
        .x => "x",
        .y => "y",
        .z => "z",
        .zero => "0",
        .one => "1",
        .two => "2",
        .three => "3",
        .four => "4",
        .five => "5",
        .six => "6",
        .seven => "7",
        .eight => "8",
        .nine => "9",
        .minus => "-",
        .equal => "=",
        .left_bracket => "[",
        .right_bracket => "]",
        .backslash => "\\",
        .semicolon => ";",
        .apostrophe => "'",
        .comma => ",",
        .period => ".",
        .slash => "/",
        .grave => "`",
        .f1 => "F1",
        .f2 => "F2",
        .f3 => "F3",
        .f4 => "F4",
        .f5 => "F5",
        .f6 => "F6",
        .f7 => "F7",
        .f8 => "F8",
        .f9 => "F9",
        .f10 => "F10",
        .f11 => "F11",
        .f12 => "F12",
        else => null,
    };
}

// ── Texture management ──

fn updateFrameTexture() void {
    frame_lock.lock();
    defer frame_lock.unlock();

    if (!frame_dirty.load(.acquire)) return;
    frame_dirty.store(false, .release);

    const jpeg = frame_jpeg orelse return;
    if (jpeg.len < 100) return;

    // Decode JPEG → RGBA via stbi
    var w: c_int = 0;
    var h: c_int = 0;
    var ch: c_int = 0;
    const rgba = dvui.c.stbi_load_from_memory(jpeg.ptr, @intCast(jpeg.len), &w, &h, &ch, 4);
    if (rgba == null or w <= 0 or h <= 0) return;

    const uw: u32 = @intCast(w);
    const uh: u32 = @intCast(h);
    const count = @as(usize, uw) * @as(usize, uh);
    const pma: [*]const dvui.Color.PMA = @ptrCast(@alignCast(rgba));

    // Destroy old texture
    if (frame_texture) |old| {
        old.destroyLater();
    }

    frame_texture = dvui.textureCreate(pma[0..count], uw, uh, .linear, .rgba_32) catch null;
    frame_w = uw;
    frame_h = uh;
    dvui.c.stbi_image_free(rgba);
}

// ══════════════════════════════════════════════════════════
// Pane Rendering
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    const b = &state.app.browser;

    const icons = @import("icons");

    // URL bar with icon buttons
    {
        var url_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 4, .y = 3, .w = 4, .h = 3 },
            .background = true,
            .color_fill = dvui.Color{ .r = 18, .g = 18, .b = 22, .a = 245 },
        });
        defer url_row.deinit();

        const icon_btn_style = dvui.Options{
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.text_muted,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 3, .y = 2, .w = 3, .h = 2 },
            .margin = .{ .x = 1, .y = 0, .w = 1, .h = 0 },
        };

        // Back
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"chevron-left", .{}, .{}, icon_btn_style)) {
            goBack();
        }

        // Forward
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"chevron-right", .{}, .{}, icon_btn_style)) {
            goForward();
        }

        // Refresh
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"rotate-cw", .{}, .{}, icon_btn_style)) {
            requestScreenshot();
        }

        // Status indicator: 🦊 green if ready, orange if loading
        {
            if (bridge_ready.load(.acquire)) {
                dvui.icon(@src(), "browser-ready", icons.tvg.lucide.@"circle-check", .{}, .{
                    .color_text = theme.colors.accent,
                    .min_size_content = .{ .w = 14, .h = 14 },
                    .padding = .{ .x = 2, .y = 2, .w = 2, .h = 2 },
                });
            } else if (bridge_starting.load(.acquire)) {
                dvui.icon(@src(), "browser-loading", icons.tvg.lucide.@"loader-circle", .{}, .{
                    .id_extra = 99,
                    .color_text = dvui.Color{ .r = 255, .g = 165, .b = 0, .a = 255 },
                    .min_size_content = .{ .w = 14, .h = 14 },
                    .padding = .{ .x = 2, .y = 2, .w = 2, .h = 2 },
                });
            }
        }

        // URL input
        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &b.url_buf } }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 200, .h = 18 },
            .color_fill = dvui.Color{ .r = 28, .g = 28, .b = 34, .a = 255 },
            .color_border = dvui.Color{ .r = 50, .g = 50, .b = 60, .a = 200 },
            .color_text = theme.colors.text_main,
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(12),
            .margin = .{ .x = 3, .y = 0, .w = 3, .h = 0 },
            .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
        });
        const enter_pressed = te.enter_pressed;
        te.deinit();

        // Go (play icon)
        const clicked_go = dvui.buttonIcon(@src(), "", icons.tvg.lucide.play, .{}, .{}, .{
            .color_fill = theme.colors.accent,
            .color_text = dvui.Color.white,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 4, .y = 3, .w = 4, .h = 3 },
            .margin = .{ .x = 1, .y = 0, .w = 1, .h = 0 },
        });
        if (clicked_go or enter_pressed) {
            const input_text = std.mem.sliceTo(&b.url_buf, 0);
            if (input_text.len > 0) {
                if (!std.mem.startsWith(u8, input_text, "http://") and !std.mem.startsWith(u8, input_text, "https://")) {
                    var url_fixed: [2048]u8 = undefined;
                    const fixed = std.fmt.bufPrint(&url_fixed, "https://{s}", .{input_text}) catch input_text;
                    loadContent(fixed);
                } else {
                    loadContent(input_text);
                }
            }
        }
    }

    // Title bar
    if (b.title_len > 0) {
        _ = dvui.label(@src(), "{s}", .{b.title[0..b.title_len]}, .{
            .color_text = theme.colors.text_main,
            .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
            .background = true,
            .color_fill = dvui.Color{ .r = 22, .g = 22, .b = 28, .a = 255 },
            .expand = .horizontal,
        });
    }

    // Loading state
    if (b.is_loading) {
        _ = dvui.label(@src(), "Loading...", .{}, .{
            .color_text = theme.colors.accent,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .expand = .both,
        });
        return;
    }

    // ── Frame rendering or landing page ──

    // Update texture from latest frame
    updateFrameTexture();

    if (frame_texture) |tex| {
        // Render the browser frame as a full-pane image
        var img_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .background = true,
            .color_fill = dvui.Color{ .r = 12, .g = 12, .b = 16, .a = 255 },
        });
        defer img_box.deinit();

        _ = dvui.image(@src(), .{ .source = .{ .texture = tex } }, .{
            .expand = .both,
            .gravity_x = 0.5,
            .gravity_y = 0.0,
        });

        // Handle mouse events in the image area
        for (dvui.events()) |*e| {
            switch (e.evt) {
                .mouse => |mouse| {
                    switch (mouse.action) {
                        .press => {
                            if (mouse.button == .left) {
                                // Get position relative to image
                                const rs = img_box.data().contentRectScale();
                                const rect = rs.r;
                                const mx = mouse.p.x - rect.x;
                                const my = mouse.p.y - rect.y;
                                if (mx >= 0 and my >= 0 and mx < rect.w and my < rect.h) {
                                    const sx = mx * @as(f32, @floatFromInt(frame_w)) / rect.w;
                                    const sy = my * @as(f32, @floatFromInt(frame_h)) / rect.h;
                                    sendClick(sx, sy);
                                    e.handled = true;
                                }
                            }
                        },
                        .wheel_y => |wy| {
                            sendScroll(wy);
                            e.handled = true;
                        },
                        else => {},
                    }
                },
                .key => |key| {
                    if (key.action == .down or key.action == .repeat) {
                        if (mapKeyToPlaywright(key.code)) |pw_key| {
                            sendKeypress(pw_key);
                            e.handled = true;
                        }
                    }
                },
                .text => |text| {
                    switch (text.action) {
                        .value => |val| {
                            if (val.txt.len > 0) {
                                sendType(val.txt);
                                e.handled = true;
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
    } else {
        // Landing page — no frame yet
        var empty = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .background = true,
            .color_fill = dvui.Color{ .r = 12, .g = 12, .b = 16, .a = 255 },
        });
        defer empty.deinit();

        _ = dvui.label(@src(), "ZigZag Browser", .{}, .{
            .color_text = theme.colors.text_main,
            .gravity_x = 0.5,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
        });

        if (bridge_ready.load(.acquire)) {
            _ = dvui.label(@src(), "Powered by Camoufox — Anti-detect Firefox", .{}, .{
                .id_extra = 3,
                .color_text = theme.colors.accent,
                .gravity_x = 0.5,
                .padding = .{ .x = 0, .y = 0, .w = 0, .h = 2 },
            });
            _ = dvui.label(@src(), "Real browser rendering · Cloudflare bypass · Full JS support", .{}, .{
                .id_extra = 6,
                .color_text = theme.colors.text_muted,
                .gravity_x = 0.5,
                .padding = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
            });
        } else if (bridge_starting.load(.acquire)) {
            _ = dvui.label(@src(), "Starting Camoufox browser engine...", .{}, .{
                .id_extra = 3,
                .color_text = theme.colors.text_muted,
                .gravity_x = 0.5,
                .padding = .{ .x = 0, .y = 0, .w = 0, .h = 2 },
            });
        } else {
            _ = dvui.label(@src(), "Browser engine not started", .{}, .{
                .id_extra = 3,
                .color_text = theme.colors.text_muted,
                .gravity_x = 0.5,
                .padding = .{ .x = 0, .y = 0, .w = 0, .h = 2 },
            });
            _ = dvui.label(@src(), "Enter a URL above to launch Camoufox", .{}, .{
                .id_extra = 6,
                .color_text = dvui.Color{ .r = 80, .g = 80, .b = 100, .a = 255 },
                .gravity_x = 0.5,
                .padding = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
            });
        }

        _ = dvui.label(@src(), "Enter a URL above to browse", .{}, .{
            .id_extra = 5,
            .color_text = theme.colors.text_muted,
            .gravity_x = 0.5,
            .padding = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
        });
        _ = dvui.label(@src(), "Videos auto-route to MPV · Comics to viewer · Web to browser", .{}, .{
            .id_extra = 7,
            .color_text = dvui.Color{ .r = 60, .g = 70, .b = 90, .a = 255 },
            .gravity_x = 0.5,
        });

        // Auto-start bridge on first render if not started
        ensureBridge();
    }
}

// ══════════════════════════════════════════════════════════
// Content Router — auto-detect provider from URL
// ══════════════════════════════════════════════════════════

pub const ContentRoute = enum { mpv, comic_viewer, web };

/// Determine the correct pane provider for a given URL
pub fn routeContent(url: []const u8) ContentRoute {
    // Video/audio extensions → mpv
    const mpv_exts = [_][]const u8{
        ".mp4", ".mkv",  ".avi", ".webm", ".flv", ".mov", ".m4v",
        ".mp3", ".flac", ".ogg", ".wav",  ".aac", ".m4a", ".m3u8",
        ".ts",
    };
    for (mpv_exts) |ext| {
        if (std.mem.endsWith(u8, url, ext)) return .mpv;
    }

    // Video hosting sites → mpv (via yt-dlp)
    const mpv_domains = [_][]const u8{
        "youtube.com",     "youtu.be",       "twitch.tv",      "vimeo.com",
        "dailymotion.com", "bilibili.com",   "rumble.com",     "crunchyroll.com",
        "funimation.com",  "allanime.day",   "gogoanime",      "animixplay",
        "pornhub.com",     "pornhub.org",
        // Streamlink-supported live sites
           "chaturbate.com", "stripchat.com",
        "bongacams.com",   "cam4.com",       "camsoda.com",    "myfreecams.com",
        "flirt4free.com",  "livejasmin.com", "kick.com",       "picarto.tv",
        "dlive.tv",        "afreecatv.com",  "pluto.tv",       "odysee.com",
    };
    for (mpv_domains) |domain| {
        if (std.mem.indexOf(u8, url, domain) != null) return .mpv;
    }

    // Comic sites → comic_viewer
    const comic_domains = [_][]const u8{
        "readallcomics.com", "readcomicsonline", "comicextra.net",
        "mangadex.org",      "mangakakalot.com", "manganato.com",
        "webtoons.com",      "tapas.io",
    };
    for (comic_domains) |domain| {
        if (std.mem.indexOf(u8, url, domain) != null) return .comic_viewer;
    }

    // Image galleries → comic_viewer
    const img_exts = [_][]const u8{ ".jpg", ".jpeg", ".png", ".gif", ".webp" };
    for (img_exts) |ext| {
        if (std.mem.endsWith(u8, url, ext)) return .comic_viewer;
    }

    // Everything else → web browser
    return .web;
}

/// Load content with automatic provider routing
pub fn loadContent(url: []const u8) void {
    const extractors = @import("extractors.zig");

    // Normalize URL
    var norm_buf: [2048]u8 = undefined;
    const norm_url = extractors.normalizeUrl(url, &norm_buf);

    const route = routeContent(norm_url);

    // Check if this is a playlist URL
    if (route == .mpv and extractors.isPlaylistUrl(norm_url)) {
        state.showToast("Extracting playlist...");
        extractors.extractPlaylist(norm_url);
        return;
    }

    // Comics open inside the Browse › Comics tab (the player route is for
    // playback only) — load + reveal that tab, no player pane involved.
    if (route == .comic_viewer) {
        @import("comics.zig").loadComic(norm_url);
        state.app.browse_source = .Comics;
        state.app.router.navigate(.browse);
        return;
    }

    // Web pages open inside the Browse › Web tab — the in-app browser is
    // fully independent of any player now. Load + reveal that tab.
    if (route == .web) {
        navigate(norm_url);
        state.app.browse_source = .Web;
        state.app.router.navigate(.browse);
        return;
    }

    // Video/audio → the MPV player pane.
    if (state.app.active_player_idx < state.app.players.items.len) {
        const p = state.app.players.items[state.app.active_player_idx];
        p.provider = .mpv;

        var url_z: [2049]u8 = undefined;
        const len = @min(norm_url.len, 2048);
        @memcpy(url_z[0..len], norm_url[0..len]);
        url_z[len] = 0;
        p.load_file(@ptrCast(&url_z[0]));

        // Reveal the player page (and close the legacy drawer) so the user
        // actually sees what they just loaded. Centralized here so search,
        // resolver, queue, drag-drop and Resume all inherit it.
        state.gotoPlayer();
    }
}
