//! How an Ask Opal answer looks in the chat transcript.
//!
//! One assistant message per ask, signed "Opal (via Claude Code)". While the agent
//! works it shows a spinner, the elapsed time and a Cancel button. A finished
//! answer shows its text, the proposed actions as buttons, catalog cards and the
//! cost. The agent's data is only ever drawn: a button runs `ask.runAction` on a
//! click, and spend actions (Wanted, Download) are captioned from validated
//! fields, never from the agent's own label.

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const theme = @import("theme.zig");
const components = @import("components.zig");
const state = @import("../core/state.zig");
const io_g = @import("../core/io_global.zig");
const poster = @import("../core/poster.zig");
const text_util = @import("../core/text.zig");
const ai_chat = @import("../services/ai_chat.zig");
const ask = @import("../services/ask.zig");
const pure = @import("../services/ask_pure.zig");

const ID_BASE: usize = 74000;
const CARD_W: f32 = 104;
const POSTER_H: f32 = CARD_W * 1.5;

/// Poster pixels per card of the latest answer. Reset when a new ask starts.
const PosterSlot = struct {
    pixels: ?[]u8 = null,
    w: u32 = 0,
    h: u32 = 0,
    tex: ?dvui.Texture = null,
    fetching: bool = false,
    attempted: bool = false,
    failed: bool = false,
};
var slots: [pure.MAX_CARDS]PosterSlot = [_]PosterSlot{.{}} ** pure.MAX_CARDS;
var slots_seq: u32 = 0;

fn resetSlots() void {
    for (&slots) |*s| {
        // A fetch in flight owns the slot until it finishes; leak nothing, reuse next frame.
        if (s.fetching) continue;
        poster.deinitPoster(&s.pixels, &s.tex);
        s.* = .{};
    }
}

/// A small quiet line that wraps instead of being cut off in a narrow window.
fn note(id: usize, text: []const u8, color: dvui.Color, top: f32) void {
    var tl = dvui.textLayout(@src(), .{}, .{
        .id_extra = id,
        .background = false,
        .expand = .horizontal,
        .padding = dvui.Rect.all(0),
        .margin = .{ .x = 2, .y = top, .w = 0, .h = 0 },
    });
    tl.addText(text, .{ .color_text = color });
    tl.deinit();
}

/// Draw the assistant message at transcript index `mi` (one written by Ask Opal).
pub fn renderMessage(mi: usize) void {
    var click_seq: u32 = 0;
    var click_idx: ?usize = null;
    var card_query: ?[pure.TEXT_MAX + 8]u8 = null;
    var card_query_len: usize = 0;
    var do_cancel = false;
    {
        const t = ask.lock();
        defer ask.unlock();
        drawLocked(mi, t, &click_seq, &click_idx, &card_query, &card_query_len, &do_cancel);
    }
    if (do_cancel) ask.cancel();
    if (click_idx) |i| _ = ask.runAction(click_seq, i);
    if (card_query) |q| {
        @import("../services/search.zig").submitQuery(q[0..card_query_len]);
        state.app.router.navigate(.search);
    }
}

fn drawLocked(
    mi: usize,
    t: *ask.Turn,
    click_seq: *u32,
    click_idx: *?usize,
    card_query: *?[pure.TEXT_MAX + 8]u8,
    card_query_len: *usize,
    do_cancel: *bool,
) void {
    const msg = &ai_chat.messages[mi];
    const agent: pure.Agent = if (msg.via == 2) .codex else .claude;
    const latest = t.msg_index == mi and t.seq != 0;
    const working = latest and t.status == .working;
    const base = ID_BASE + mi * 64;

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = base,
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = theme.spacing.sm },
    });
    defer row.deinit();

    {
        var av = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = base + 1,
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .corner_radius = dvui.Rect.all(theme.radius.pill),
            .min_size_content = .{ .w = 26, .h = 26 },
            .max_size_content = dvui.Options.MaxSize.size(.{ .w = 26, .h = 26 }),
            .margin = .{ .x = 0, .y = 2, .w = theme.spacing.sm, .h = 0 },
        });
        defer av.deinit();
        dvui.icon(@src(), "ask-avatar", icons.tvg.lucide.sparkles, .{}, .{
            .id_extra = base + 2,
            .color_text = theme.colors.accent,
            .min_size_content = .{ .w = 14, .h = 14 },
            .gravity_x = 0.5,
            .gravity_y = 0.5,
        });
    }

    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = base + 3, .expand = .horizontal });
    defer col.deinit();

    _ = dvui.label(@src(), "{s}", .{agent.label()}, .{
        .id_extra = base + 4,
        .expand = .horizontal,
        .color_text = theme.colors.text_tertiary,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 2 },
    });

    if (working) {
        drawWorking(base, t, agent, do_cancel);
        return;
    }

    // The text lives in the transcript message, so older asks still read naturally.
    if (msg.text_len > 0) {
        var mbuf: [ai_chat.MAX_MSG_LEN]u8 = undefined;
        const safe = text_util.safeUtf8Buf(msg.text[0..msg.text_len], &mbuf);
        var plain_buf: [ai_chat.MAX_MSG_LEN]u8 = undefined;
        const shown = pure.plainMarkdown(&plain_buf, safe);
        const failed = latest and (t.status == .failed or t.status == .cancelled);
        var tl = dvui.textLayout(@src(), .{}, .{
            .id_extra = base + 5,
            .background = false,
            .padding = dvui.Rect.all(0),
        });
        tl.addText(shown, .{ .color_text = if (failed) theme.colors.warning else theme.colors.text_primary });
        tl.deinit();
    }
    if (!latest) return;

    if (t.status == .done) {
        drawActions(base, t, click_seq, click_idx);
        drawCards(base, t, card_query, card_query_len);
        if (t.answer.dropped > 0) {
            var nb: [160]u8 = undefined;
            const dropped_note = std.fmt.bufPrint(&nb, "{d} suggested {s} did not pass Opal's checks and {s} hidden.", .{
                t.answer.dropped,
                if (t.answer.dropped == 1) "action" else "actions",
                if (t.answer.dropped == 1) "was" else "were",
            }) catch "";
            note(base + 6, dropped_note, theme.colors.text_tertiary, 4);
        }
    }
    if ((t.status == .done or t.status == .failed or t.status == .cancelled) and t.cost_cents > 0) {
        var cb: [160]u8 = undefined;
        note(base + 7, pure.costLine(&cb, agent, t.cost_cents), theme.colors.text_tertiary, 6);
    }
}

fn drawWorking(base: usize, t: *ask.Turn, agent: pure.Agent, do_cancel: *bool) void {
    // Keep the elapsed time ticking without spinning the frame loop.
    const timer_id = dvui.Id.extendId(null, @src(), base);
    if (dvui.timerDoneOrNone(timer_id)) dvui.timer(timer_id, 500_000);

    var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = base + 10, .expand = .horizontal });
    defer line.deinit();
    dvui.spinner(@src(), .{
        .id_extra = base + 11,
        .color_text = theme.colors.accent,
        .min_size_content = .{ .w = 14, .h = 14 },
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
    });
    const secs: i64 = @max(0, @divFloor(io_g.milliTimestamp() - t.started_ms, 1000));
    var wb: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&wb, "Working with {s}… {d}s", .{ if (agent == .codex) "Codex" else "Claude Code", secs }) catch "Working…";
    _ = dvui.label(@src(), "{s}", .{text}, .{
        .id_extra = base + 12,
        .color_text = theme.colors.text_secondary,
        .gravity_y = 0.5,
    });
    {
        var sp = dvui.box(@src(), .{}, .{ .id_extra = base + 13, .expand = .horizontal });
        sp.deinit();
    }
    if (components.actionButton(@src(), "Cancel", .secondary, base + 14)) do_cancel.* = true;

    var hb: [96]u8 = undefined;
    const hint = std.fmt.bufPrint(&hb, "Uses your {s} credit, up to ${d}.{d:0>2}.", .{ if (agent == .codex) "Codex" else "Claude Code", pure.BUDGET_CENTS / 100, pure.BUDGET_CENTS % 100 }) catch "";
    note(base + 15, hint, theme.colors.text_tertiary, 2);
}

fn drawActions(base: usize, t: *ask.Turn, click_seq: *u32, click_idx: *?usize) void {
    if (t.answer.action_count == 0) return;
    var i: usize = 0;
    while (i < t.answer.action_count) : (i += 1) {
        const act = &t.answer.actions[i];
        var cap_buf: [220]u8 = undefined;
        const caption = pure.caption(&cap_buf, act);
        const id = base + 20 + i * 3;
        const st = t.action_state[i];

        var item = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = id,
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 6, .w = 0, .h = 0 },
        });
        defer item.deinit();

        switch (st) {
            .ready => {
                if (dvui.button(@src(), caption, .{}, .{
                    .id_extra = id + 1,
                    .color_fill = if (act.kind.spends()) theme.colors.accent else theme.colors.bg_elevated,
                    .color_fill_hover = theme.colors.bg_hover,
                    .color_text = if (act.kind.spends()) theme.colors.text_on_accent else theme.colors.text_primary,
                    .corner_radius = dvui.Rect.all(theme.radius.md),
                    .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
                })) {
                    click_seq.* = t.seq;
                    click_idx.* = i;
                }
                var db: [200]u8 = undefined;
                const detail = pure.detail(&db, act);
                if (detail.len > 0) {
                    note(id + 2, detail, theme.colors.text_tertiary, 2);
                }
            },
            .done, .failed => {
                var lb: [260]u8 = undefined;
                const text = std.fmt.bufPrint(&lb, "{s}: {s}", .{ if (st == .done) "Done" else "Could not run", caption }) catch caption;
                _ = dvui.label(@src(), "{s}", .{text}, .{
                    .id_extra = id + 1,
                    .expand = .horizontal,
                    .color_text = if (st == .done) theme.colors.text_secondary else theme.colors.warning,
                });
            },
        }
    }
}

fn drawCards(base: usize, t: *ask.Turn, card_query: *?[pure.TEXT_MAX + 8]u8, card_query_len: *usize) void {
    if (t.answer.card_count == 0) return;
    if (slots_seq != t.seq) {
        resetSlots();
        slots_seq = t.seq;
    }
    var rail = dvui.scrollArea(@src(), .{ .horizontal = .auto, .vertical = .none }, .{
        .id_extra = base + 50,
        .expand = .horizontal,
        .background = false,
        .min_size_content = .{ .w = 10, .h = POSTER_H + 60 },
        .max_size_content = .{ .w = std.math.floatMax(f32), .h = POSTER_H + 60 },
        .margin = .{ .x = 0, .y = 8, .w = 0, .h = 0 },
    });
    defer rail.deinit();
    var strip = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = base + 51 });
    defer strip.deinit();

    var i: usize = 0;
    while (i < t.answer.card_count) : (i += 1) {
        const card = &t.answer.cards[i];
        const slot = &slots[i];
        const id = base + 52 + i * 4;

        var cbox = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = id,
            .min_size_content = .{ .w = CARD_W, .h = POSTER_H + 48 },
            .max_size_content = .{ .w = CARD_W, .h = std.math.floatMax(f32) },
            .margin = dvui.Rect.all(4),
        });
        defer cbox.deinit();

        var url_buf: [128]u8 = undefined;
        const url: []const u8 = if (card.imdb.len > 0)
            std.fmt.bufPrint(&url_buf, "https://images.metahub.space/poster/small/{s}/img.jpg", .{card.imdb.slice()}) catch ""
        else
            "";

        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{}, .{
            .id_extra = id + 1,
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .corner_radius = dvui.Rect.all(8),
            .min_size_content = .{ .w = CARD_W, .h = POSTER_H },
            .max_size_content = .{ .w = CARD_W, .h = POSTER_H },
            .padding = dvui.Rect.all(0),
        });
        bw.processEvents();
        bw.drawBackground();
        if (bw.clicked()) {
            // A card opens the app's own search for the title: a read, never an action.
            var q: [pure.TEXT_MAX + 8]u8 = undefined;
            const text = if (card.year != 0)
                std.fmt.bufPrint(&q, "{s} {d}", .{ card.title.slice(), card.year }) catch card.title.slice()
            else
                card.title.slice();
            if (text.ptr != &q) @memcpy(q[0..text.len], text);
            card_query.* = q;
            card_query_len.* = text.len;
        }
        _ = poster.uploadIfReady(&slot.pixels, slot.w, slot.h, &slot.tex);
        if (slot.tex) |*tex| {
            _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
                .id_extra = id + 2,
                .expand = .both,
                .corner_radius = dvui.Rect.all(8),
            });
        } else {
            if (slot.fetching) {
                slot.attempted = true;
            } else if (slot.attempted and slot.pixels == null and slot.tex == null) {
                slot.failed = true;
            } else if (!slot.failed and slot.pixels == null and url.len > 0) {
                poster.fetchAsync(url, &slot.pixels, &slot.w, &slot.h, &slot.fetching);
                if (slot.fetching) slot.attempted = true;
            }
            if (!slot.failed and url.len > 0) {
                components.coverSkeleton(@src(), id + 3, 8);
            } else {
                dvui.icon(@src(), "ask-card", icons.tvg.lucide.film, .{}, .{
                    .id_extra = id + 3,
                    .color_text = theme.colors.text_tertiary,
                    .min_size_content = .{ .w = 24, .h = 24 },
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                });
            }
        }
        bw.deinit();

        _ = dvui.label(@src(), "{s}", .{card.title.slice()}, .{
            .id_extra = id + 4 + 1000,
            .color_text = theme.colors.text_primary,
            .expand = .horizontal,
            .padding = .{ .x = 2, .y = 4, .w = 2, .h = 0 },
        });
        var sub: [24]u8 = undefined;
        const sub_text = if (card.year != 0) (std.fmt.bufPrint(&sub, "{d} · {s}", .{ card.year, if (card.kind == .tv) "TV" else "Movie" }) catch "") else (if (card.kind == .tv) "TV" else "Movie");
        _ = dvui.label(@src(), "{s}", .{sub_text}, .{
            .id_extra = id + 4 + 2000,
            .color_text = theme.colors.text_tertiary,
            .expand = .horizontal,
            .padding = .{ .x = 2, .y = 0, .w = 2, .h = 2 },
        });
    }
}
