//! Owner-thread drain shared by the native frame and the headless loop.
const std = @import("std");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");

/// Call under the player's owner boundary; snapshot the FIFO before dispatch.
pub fn drain() void {
    var first = true;
    while (true) {
        var fwd_buf: [2048]u8 = undefined;
        var fwd_len: usize = 0;
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
