//! Owner-thread drain shared by the native frame and the headless loop.
const std = @import("std");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");

fn setField(dst: []u8, len: *usize, src: []const u8) void {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    len.* = n;
}

/// Hand a stream a paired browser found to the owner thread: play it (replacing
/// what is playing) or add it to the queue. Unlike `/api/open` this carries the
/// HTTP identity the browser used, so the CDN sees the same Referer/Origin/UA.
/// Strings must already be validated (browser_link_pure). False when the FIFO
/// is full; the newest request is the one dropped, as for every other producer.
pub fn pushBrowser(queue_only: bool, url: []const u8, title: []const u8, art: []const u8, referer: []const u8, origin: []const u8, user_agent: []const u8) bool {
    if (url.len == 0) return false;
    const player = @import("../player/player.zig");
    if (!queue_only and !player.openTriggerArmed()) player.openTriggerNow();
    state.app.remote_open_lock.lock();
    defer state.app.remote_open_lock.unlock();
    if (state.app.remote_open_count >= state.REMOTE_OPEN_QUEUE_CAP) {
        logs.pushLog("warn", "open", "Remote open queue full — dropping newest request", false);
        return false;
    }
    const slot = &state.app.remote_open_queue[(state.app.remote_open_head + state.app.remote_open_count) % state.REMOTE_OPEN_QUEUE_CAP];
    setField(&slot.path, &slot.path_len, url);
    setField(&slot.kind, &slot.kind_len, if (queue_only) "browser_queue" else "browser");
    setField(&slot.title, &slot.title_len, title);
    setField(&slot.art, &slot.art_len, art);
    setField(&slot.referer, &slot.referer_len, referer);
    setField(&slot.origin, &slot.origin_len, origin);
    setField(&slot.user_agent, &slot.user_agent_len, user_agent);
    slot.subtitle_len = 0;
    state.app.remote_open_count += 1;
    state.app.remote_open_ready.store(true, .release);
    state.wakeUi();
    return true;
}

/// Call under the player's owner boundary; snapshot the FIFO before dispatch.
pub fn drain() void {
    var first = true;
    while (true) {
        var fwd_buf: [4096]u8 = undefined;
        var fwd_len: usize = 0;
        var ref_buf: [2048]u8 = undefined;
        var ref_len: usize = 0;
        var origin_buf: [256]u8 = undefined;
        var origin_len: usize = 0;
        var ua_buf: [512]u8 = undefined;
        var ua_len: usize = 0;
        var type_buf: [16]u8 = undefined;
        var type_len: usize = 0;
        var title_buf: [512]u8 = undefined;
        var title_len: usize = 0;
        var art_buf: [1024]u8 = undefined;
        var art_len: usize = 0;
        var sub_buf: [256]u8 = undefined;
        var sub_len: usize = 0;
        if (state.app.remote_open_ready.load(.acquire)) {
            state.app.remote_open_lock.lock();
            if (state.app.remote_open_count > 0) {
                const e = &state.app.remote_open_queue[state.app.remote_open_head];
                fwd_len = e.path_len;
                @memcpy(fwd_buf[0..fwd_len], e.path[0..fwd_len]);
                type_len = e.kind_len;
                @memcpy(type_buf[0..type_len], e.kind[0..type_len]);
                title_len = e.title_len;
                @memcpy(title_buf[0..title_len], e.title[0..title_len]);
                art_len = e.art_len;
                @memcpy(art_buf[0..art_len], e.art[0..art_len]);
                sub_len = e.subtitle_len;
                @memcpy(sub_buf[0..sub_len], e.subtitle[0..sub_len]);
                ref_len = e.referer_len;
                @memcpy(ref_buf[0..ref_len], e.referer[0..ref_len]);
                origin_len = e.origin_len;
                @memcpy(origin_buf[0..origin_len], e.origin[0..origin_len]);
                ua_len = e.user_agent_len;
                @memcpy(ua_buf[0..ua_len], e.user_agent[0..ua_len]);
                state.app.remote_open_head = (state.app.remote_open_head + 1) % state.REMOTE_OPEN_QUEUE_CAP;
                state.app.remote_open_count -= 1;
                state.app.remote_open_ready.store(state.app.remote_open_count > 0, .release);
            } else {
                state.app.remote_open_ready.store(false, .release);
            }
            state.app.remote_open_lock.unlock();
        } else break;
        if (fwd_len == 0) continue;
        // A forwarded file dismisses the launch resume prompt — the user
        // asked for THIS file, not last session's.
        state.app.resume_prompt_active = false;
        const url = fwd_buf[0..fwd_len];
        const kind = type_buf[0..type_len];
        // A paired browser's stream keeps its own HTTP identity, so it never
        // takes the generic "first plays, the rest queue" path below.
        if (std.mem.eql(u8, kind, "browser_queue")) {
            const title = if (title_len > 0) title_buf[0..title_len] else url;
            // The queue row is a bare URL under 2 KB; the Referer, Origin and
            // User-Agent it was found with are kept beside it, keyed by the URL,
            // and handed to the player when the item is played.
            const q = @import("queue.zig");
            q.rememberHttpIdentity(url, ref_buf[0..ref_len], origin_buf[0..origin_len], ua_buf[0..ua_len]);
            q.addToQueue(url, title, "browser");
            logs.pushLog("info", "queue", "Queued from paired browser", false);
            state.showToast("Queued in Opal");
            continue;
        }
        if (std.mem.eql(u8, kind, "browser")) {
            const player = @import("../player/player.zig");
            var headers: [2]player.HttpHeader = undefined;
            var header_count: usize = 0;
            if (ref_len > 0) {
                headers[header_count] = .{ .name = "Referer", .value = ref_buf[0..ref_len] };
                header_count += 1;
            }
            if (origin_len > 0) {
                headers[header_count] = .{ .name = "Origin", .value = origin_buf[0..origin_len] };
                header_count += 1;
            }
            @import("browser.zig").loadContentDirectMetaHeaders(url, art_buf[0..art_len], title_buf[0..title_len], "", ua_buf[0..ua_len], headers[0..header_count]);
            logs.pushLog("info", "open", "Playing stream from paired browser", false);
            state.showToast("Playing in Opal");
            first = false;
            continue;
        }
        if (!first) {
            const title = if (title_len > 0) title_buf[0..title_len] else url;
            @import("queue.zig").addToQueue(url, title, "file-open");
            logs.pushLog("info", "queue", "Queued forwarded file", false);
            continue;
        }
        first = false;
        if (std.mem.eql(u8, kind, "queue")) {
            // "Queue in Opal" — add to the watch queue instead of playing.
            const title = if (title_len > 0) title_buf[0..title_len] else url;
            @import("queue.zig").addToQueue(url, title, "extension");
            logs.pushLog("info", "queue", "Queued from browser extension", false);
            state.showToast("Queued in Opal");
        } else if (title_len > 0 or art_len > 0 or sub_len > 0) {
            // Rich-metadata send: show a proper now-playing card.
            const browser = @import("browser.zig");
            browser.loadContentDirectMeta(url, art_buf[0..art_len], title_buf[0..title_len], sub_buf[0..sub_len]);
            logs.pushLog("info", "open", "Opened from browser extension", false);
            state.showToast("Playing in Opal");
        } else {
            const browser = @import("browser.zig");
            browser.loadContent(url);
            logs.pushLog("info", "open", "Opened from second instance", false);
            state.showToast("Playing forwarded file");
        }
    }
}
