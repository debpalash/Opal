const std = @import("std");
const state = @import("../core/state.zig");
const c = @import("../core/c.zig");

// ══════════════════════════════════════════════════════════
// Watch Party — real-time playback sync over LAN
// Host broadcasts play/pause/seek/load events + chat
// ══════════════════════════════════════════════════════════

pub const PartyRole = enum { none, host, client };
pub var role: PartyRole = .none;
pub var party_port: u16 = 41596;

// Host state
var host_thread: ?std.Thread = null;
var host_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var client_streams: [8]?std.Io.net.Stream = .{null} ** 8;
var client_count: usize = 0;
var clients_mutex: @import("../core/sync.zig").Mutex = .{};

// Client state
var client_thread: ?std.Thread = null;
var client_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var client_stream: ?std.Io.net.Stream = null;

// Chat buffer (visible in UI)
pub var chat_msgs: [32][128]u8 = std.mem.zeroes([32][128]u8);
pub var chat_msg_lens: [32]u8 = .{0} ** 32;
pub var chat_count: usize = 0;
pub var chat_input: [128]u8 = std.mem.zeroes([128]u8);

// Sync messages
const MSG_PAUSE = "PAUSE\n";
const MSG_PLAY = "PLAY\n";
const MSG_PREFIX_SEEK = "SEEK "; // followed by seconds
const MSG_PREFIX_LOAD = "LOAD "; // followed by URL
const MSG_PREFIX_CHAT = "CHAT "; // followed by message

pub fn hostParty() void {
    if (role != .none) return;
    role = .host;
    host_running.store(true, .release);
    client_count = 0;
    chat_count = 0;
    host_thread = std.Thread.spawn(.{}, hostLoop, .{}) catch null;
    state.showToast("Watch Party hosting on :41596");
    pushChat(">> Party started");
}

pub fn joinParty(host_ip: []const u8) void {
    if (role != .none) return;
    if (host_ip.len == 0 or host_ip.len > 45) return;
    role = .client;
    client_running.store(true, .release);
    chat_count = 0;

    var ip_buf: [46]u8 = undefined;
    @memcpy(ip_buf[0..host_ip.len], host_ip);
    ip_buf[host_ip.len] = 0;

    client_thread = std.Thread.spawn(.{}, clientLoop, .{ ip_buf, host_ip.len }) catch null;
}

pub fn leaveParty() void {
    if (role == .host) {
        host_running.store(false, .release);
        // Kick the blocking accept() awake with a throwaway local connection
        // so hostLoop can observe host_running=false and exit, then join the
        // thread (mirrors stream_proxy.stopProxy). Without this the listening
        // socket + host thread leak until process exit.
        {
            const io_g = @import("../core/io_global.zig");
            if (std.Io.net.IpAddress.parseIp4("127.0.0.1", party_port)) |addr| {
                if (addr.connect(io_g.io(), .{ .mode = .stream })) |conn| {
                    var c2 = conn;
                    c2.close(io_g.io());
                } else |_| {}
            } else |_| {}
        }
        if (host_thread) |t| t.join();
        host_thread = null;
        clients_mutex.lock();
        for (&client_streams) |*cs| {
            if (cs.*) |s| {
                s.close(@import("../core/io_global.zig").io());
                cs.* = null;
            }
        }
        client_count = 0;
        clients_mutex.unlock();
    } else if (role == .client) {
        client_running.store(false, .release);
        if (client_stream) |s| {
            s.close(@import("../core/io_global.zig").io());
            client_stream = null;
        }
    }
    role = .none;
    state.showToast("Left Watch Party");
    pushChat(">> Party ended");
}

/// Called by input.zig when host pauses/plays
pub fn broadcastPause() void {
    if (role != .host) return;
    broadcast(MSG_PAUSE);
}

pub fn broadcastPlay() void {
    if (role != .host) return;
    broadcast(MSG_PLAY);
}

pub fn broadcastSeek(seconds: f64) void {
    if (role != .host) return;
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "SEEK {d:.1}\n", .{seconds}) catch return;
    broadcast(msg);
}

/// Sync current video URL to all clients
pub fn broadcastLoad(url: []const u8) void {
    if (role != .host) return;
    var buf: [2200]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "LOAD {s}\n", .{url}) catch return;
    broadcast(msg);
    pushChat(">> Loading video...");
}

/// Send chat message
pub fn sendChat() void {
    const len = std.mem.indexOfScalar(u8, &chat_input, 0) orelse 0;
    if (len == 0) return;
    const msg_text = chat_input[0..len];

    var buf: [200]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, "CHAT {s}\n", .{msg_text}) catch return;

    if (role == .host) {
        broadcast(full);
        // Also show locally
        var display: [128]u8 = undefined;
        const dlen = std.fmt.bufPrint(&display, "Host: {s}", .{msg_text}) catch return;
        pushChat(dlen);
    } else if (role == .client) {
        if (client_stream) |s| {
            _ = @import("../core/io_global.zig").streamWriteAll(s, full) catch {};
        }
        var display: [128]u8 = undefined;
        const dlen = std.fmt.bufPrint(&display, "You: {s}", .{msg_text}) catch return;
        pushChat(dlen);
    }

    // Clear input
    @memset(&chat_input, 0);
}

pub fn pushChat(msg: []const u8) void {
    clients_mutex.lock();
    defer clients_mutex.unlock();
    if (chat_count >= 32) {
        // Shift messages up
        for (0..31) |i| {
            chat_msgs[i] = chat_msgs[i + 1];
            chat_msg_lens[i] = chat_msg_lens[i + 1];
        }
        chat_count = 31;
    }
    const mlen: u8 = @intCast(@min(msg.len, 127));
    @memcpy(chat_msgs[chat_count][0..mlen], msg[0..mlen]);
    chat_msg_lens[chat_count] = mlen;
    chat_count += 1;
}

fn broadcast(msg: []const u8) void {
    clients_mutex.lock();
    defer clients_mutex.unlock();
    for (&client_streams) |*cs| {
        if (cs.*) |s| {
            _ = @import("../core/io_global.zig").streamWriteAll(s, msg) catch {
                s.close(@import("../core/io_global.zig").io());
                cs.* = null;
                client_count -|= 1;
            };
        }
    }
}

fn hostLoop() void {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", party_port) catch return;
    var server = addr.listen(@import("../core/io_global.zig").io(), .{ .reuse_address = true }) catch return;
    defer server.deinit(@import("../core/io_global.zig").io());

    while (host_running.load(.acquire)) {
        const conn = server.accept(@import("../core/io_global.zig").io()) catch continue;
        // Re-check after accept: leaveParty() kicks accept() awake with a
        // throwaway connection — don't register it as a phantom client.
        if (!host_running.load(.acquire)) {
            conn.close(@import("../core/io_global.zig").io());
            break;
        }
        clients_mutex.lock();
        if (client_count >= 8) {
            clients_mutex.unlock();
            conn.close(@import("../core/io_global.zig").io());
            continue;
        }
        for (&client_streams) |*cs| {
            if (cs.* == null) {
                cs.* = conn;
                client_count += 1;
                var msg_buf: [64]u8 = undefined;
                const toast_msg = std.fmt.bufPrint(&msg_buf, "Party: {d} viewers", .{client_count}) catch "Party: +1";
                clients_mutex.unlock();
                state.showToast(toast_msg);

                var chat_buf: [64]u8 = undefined;
                const chat_msg = std.fmt.bufPrint(&chat_buf, ">> Guest joined ({d} total)", .{client_count}) catch ">> Guest joined";
                pushChat(chat_msg);

                // Send current URL to new client
                if (state.app.active_player_idx < state.app.players.items.len) {
                    const p = state.app.players.items[state.app.active_player_idx];
                    if (p.current_url_len > 0) {
                        var url_msg: [2200]u8 = undefined;
                        const um = std.fmt.bufPrint(&url_msg, "LOAD {s}\n", .{p.current_url[0..p.current_url_len]}) catch "";
                        if (um.len > 0) _ = @import("../core/io_global.zig").streamWriteAll(conn, um) catch {};
                    }
                }

                // Start reader thread for this client (for chat messages from clients)
                _ = std.Thread.spawn(.{}, hostClientReader, .{conn}) catch {};
                break;
            }
        } else {
            clients_mutex.unlock();
        }
    }
}

fn hostClientReader(stream: std.Io.net.Stream) void {
    var line_buf: [256]u8 = undefined;
    while (host_running.load(.acquire)) {
        const n = @import("../core/io_global.zig").streamRead(stream, &line_buf) catch break;
        if (n == 0) break;

        var lines = std.mem.splitScalar(u8, line_buf[0..n], '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            // Relay chat from client to all other clients
            if (std.mem.startsWith(u8, line, "CHAT ")) {
                var relay: [200]u8 = undefined;
                const rmsg = std.fmt.bufPrint(&relay, "CHAT Guest: {s}\n", .{line[5..]}) catch continue;
                broadcast(rmsg);
                var display: [128]u8 = undefined;
                const dmsg = std.fmt.bufPrint(&display, "Guest: {s}", .{line[5..]}) catch continue;
                pushChat(dmsg);
            }
        }
    }
}

fn clientLoop(ip_buf: [46]u8, ip_len: usize) void {
    const ip_str = ip_buf[0..ip_len];

    const addr = std.Io.net.IpAddress.parseIp4(ip_str, party_port) catch {
        state.showToast("Invalid host IP");
        role = .none;
        return;
    };

    const stream = addr.connect(@import("../core/io_global.zig").io(), .{ .mode = .stream }) catch {
        state.showToast("Cannot connect to host");
        role = .none;
        return;
    };
    client_stream = stream;
    state.showToast("Connected to Watch Party!");
    pushChat(">> Connected to party");

    var line_buf: [4096]u8 = undefined;
    while (client_running.load(.acquire)) {
        const n = @import("../core/io_global.zig").streamRead(stream, &line_buf) catch break;
        if (n == 0) break;

        var lines = std.mem.splitScalar(u8, line_buf[0..n], '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            applyCommand(line);
        }
    }

    stream.close(@import("../core/io_global.zig").io());
    client_stream = null;
    role = .none;
    state.showToast("Disconnected from party");
    pushChat(">> Disconnected");
}

fn applyCommand(cmd: []const u8) void {
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const ap = state.app.players.items[state.app.active_player_idx];

    if (std.mem.eql(u8, cmd, "PAUSE")) {
        _ = c.mpv.mpv_command_string(ap.mpv_ctx, "set pause yes");
    } else if (std.mem.eql(u8, cmd, "PLAY")) {
        _ = c.mpv.mpv_command_string(ap.mpv_ctx, "set pause no");
    } else if (std.mem.startsWith(u8, cmd, "SEEK ")) {
        // Validate the seek value is numeric (prevent mpv command injection)
        const seek_val = cmd[5..];
        var valid = seek_val.len > 0;
        for (seek_val) |ch| {
            if (!std.ascii.isDigit(ch) and ch != '.' and ch != '-') {
                valid = false;
                break;
            }
        }
        if (!valid) return;
        var seek_buf: [64]u8 = undefined;
        const seek_cmd = std.fmt.bufPrintZ(&seek_buf, "seek {s} absolute", .{seek_val}) catch return;
        _ = c.mpv.mpv_command_string(ap.mpv_ctx, seek_cmd.ptr);
    } else if (std.mem.startsWith(u8, cmd, "LOAD ")) {
        const url = cmd[5..];
        // Validate URL scheme to prevent loading arbitrary protocols
        if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) return;
        if (url.len > 5) {
            var url_z: [2049]u8 = undefined;
            const ulen = @min(url.len, 2048);
            @memcpy(url_z[0..ulen], url[0..ulen]);
            url_z[ulen] = 0;
            var load_args = [_][*c]const u8{ "loadfile", @ptrCast(&url_z[0]), "replace", null };
            _ = c.mpv.mpv_command(ap.mpv_ctx, @ptrCast(&load_args));
            pushChat(">> Loading synced video...");
        }
    } else if (std.mem.startsWith(u8, cmd, "CHAT ")) {
        const msg = cmd[5..];
        pushChat(msg);
    }
}

/// Get party status string for UI
pub fn statusText(buf: *[64]u8) []const u8 {
    return switch (role) {
        .none => "No Party",
        .host => blk: {
            clients_mutex.lock();
            const cc = client_count;
            clients_mutex.unlock();
            break :blk std.fmt.bufPrint(buf, "Hosting ({d} viewers)", .{cc}) catch "Hosting";
        },
        .client => "Connected",
    };
}
