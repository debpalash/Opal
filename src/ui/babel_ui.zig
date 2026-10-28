//! Babel UI — live-caption / translate controls in the subtitle drop-up, the
//! "Previously on…" player button and card, and the Settings › Subtitles
//! section. Every control is a themed components.* helper; colors are read
//! from theme.colors per frame.
const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const babel = @import("../services/babel.zig");
const live = @import("../services/live_captions.zig");
const translate = @import("../services/translate.zig");
const recap = @import("../services/recap.zig");
const translate_pure = @import("../services/translate_pure.zig");
const text_mod = @import("../core/text.zig");

/// Row of Babel actions inside the "Find subtitles" drop-up.
pub fn pickerRow() void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = theme.spacing.xs },
    });
    defer row.deinit();

    const on = live.enabled.load(.acquire);
    if (components.iconActionButton(@src(), if (on) icons.tvg.lucide.captions else icons.tvg.lucide.@"captions-off", if (on) "Live captions: on" else "Live captions", if (on) .primary else .secondary, 58101)) {
        live.setEnabled(!on);
    }
    const busy = translate.in_progress.load(.acquire);
    const tl = babel.translateLang();
    var tr_buf: [48]u8 = undefined;
    const tr_label = if (busy) "Translating…" else if (tl.len > 0) (std.fmt.bufPrint(&tr_buf, "Translate to {s}", .{translate_pure.langName(tl) orelse tl}) catch "Translate") else "Translate…";
    if (components.iconActionButton(@src(), icons.tvg.lucide.languages, tr_label, .secondary, 58102) and !busy) {
        translate.translateActiveTrack();
    }

    // One status line: translation wins while it runs, else live captions.
    const tr = translate.statusSnapshot();
    const lv = live.statusSnapshot();
    const msg = if (busy or (tr.len > 0 and !on)) tr.text[0..tr.len] else lv.text[0..lv.len];
    if (msg.len > 0) {
        var safe: [160]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{text_mod.safeUtf8Buf(msg, &safe)}, .{
            .color_text = theme.colors.text_tertiary,
            .gravity_y = 0.5,
            .margin = .{ .x = theme.spacing.xs, .y = 0, .w = 0, .h = 0 },
        });
    }
    if (on or busy) components.pollRefresh(250_000);
}

/// "Previously on…" button in the player controls. Shown for a tracked TV
/// episode (not a pilot) during its first five minutes, or while the card is
/// open. Returns true when it drew.
pub fn recapButton() bool {
    if (!recap.eligible()) return false;
    if (!recap.card_open) {
        if (state.app.active_player_idx >= state.app.players.items.len) return false;
        const p = state.app.players.items[state.app.active_player_idx];
        const pos = babel.mpvDouble(p.mpv_ctx, "time-pos") orelse return false;
        if (pos > 300) return false;
    }
    if (components.iconButtonOverlay(@src(), icons.tvg.lucide.history, "Previously on… (spoiler-safe recap)", recap.card_open, true)) {
        if (recap.card_open) recap.card_open = false else recap.request(false);
    }
    return true;
}

/// The recap card (rendered with the other overlays, UI thread).
pub fn renderRecapCard() void {
    if (!recap.card_open) return;
    if (!recap.eligible()) {
        recap.card_open = false;
        return;
    }
    const snap = recap.snapshot();
    const size = theme.fitWindowSize(.{ .w = 460, .h = 260 }, .{ .w = 260, .h = 160 });
    var open = true;
    var win = dvui.floatingWindow(@src(), .{
        .modal = false,
        .center_on = dvui.windowRect(),
        .window_avoid = .none,
        .open_flag = &open,
        .resize = .none,
    }, .{
        .min_size_content = size,
        .max_size_content = dvui.Options.MaxSize.size(size),
        .color_fill = theme.colors.bg_elevated,
        .color_border = theme.colors.border_subtle,
        .border = dvui.Rect.all(1),
        .corner_radius = theme.dims.rad_lg,
    });
    defer win.deinit();
    win.autoPosition();

    var title_buf: [200]u8 = undefined;
    const show = snap.show[0..snap.show_len];
    const title = if (show.len > 0)
        std.fmt.bufPrint(&title_buf, "Previously on {s}", .{show}) catch "Previously on…"
    else
        "Previously on…";
    var safe_title: [220]u8 = undefined;
    win.dragAreaSet(dvui.windowHeader(text_mod.safeUtf8Buf(title, &safe_title), "", &open));
    if (!open) {
        recap.card_open = false;
        return;
    }

    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
    });
    defer col.deinit();

    switch (snap.phase) {
        .working, .idle => {
            components.loadingState("Writing a spoiler-safe recap…");
            components.pollRefresh(200_000);
        },
        .ready, .nothing, .failed => {
            var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false });
            var tl = dvui.textLayout(@src(), .{ .break_lines = true }, .{
                .expand = .horizontal,
                .background = false,
                .color_text = if (snap.phase == .ready) theme.colors.text_primary else theme.colors.text_secondary,
            });
            var safe: [1100]u8 = undefined;
            tl.addText(text_mod.safeUtf8Buf(snap.text[0..snap.text_len], &safe), .{});
            tl.deinit();
            scroll.deinit();
        },
    }

    var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 },
    });
    defer actions.deinit();
    if (snap.phase == .ready) {
        if (components.iconActionButton(@src(), icons.tvg.lucide.@"volume-2", "Read aloud", .secondary, 58201)) recap.readAloud();
    }
    if (snap.phase != .working) {
        if (components.iconActionButton(@src(), icons.tvg.lucide.@"refresh-cw", "Regenerate", .secondary, 58202)) recap.request(true);
    }
    if (components.actionButton(@src(), "Close", .secondary, 58203)) recap.card_open = false;

    // Optional auto read-aloud once per fresh result.
    const S = struct {
        var spoken_key: u64 = 0;
    };
    if (snap.phase == .ready and state.app.babel_recap_tts) {
        const key = (@as(u64, @bitCast(@as(i64, snap.tmdb_id))) << 20) ^ (@as(u64, @intCast(@max(0, snap.ep.season))) << 10) ^ @as(u64, @intCast(@max(0, snap.ep.episode)));
        if (S.spoken_key != key) {
            S.spoken_key = key;
            recap.readAloud();
        }
    }
}

/// Settings › Subtitles block.
pub fn settingsSection() void {
    components.sectionHeader("Live captions & translation");

    _ = dvui.label(@src(), "Spoken language (live captions)", .{}, .{
        .color_text = theme.colors.text_secondary,
        .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = theme.spacing.xs },
    });
    {
        const codes = [_][]const u8{ "auto", "en", "es", "fr", "de", "pt", "it", "ru", "zh", "ja", "ko", "hi" };
        const names = [_][]const u8{ "Auto", "EN", "ES", "FR", "DE", "PT", "IT", "RU", "ZH", "JA", "KO", "HI" };
        const cur = state.app.babel_caption_lang[0..state.app.babel_caption_lang_len];
        var sel: usize = 0;
        for (codes, 0..) |code, i| if (std.mem.eql(u8, cur, code)) {
            sel = i;
        };
        if (components.segment(@src(), &names, sel)) |i| {
            setBuf(&state.app.babel_caption_lang, &state.app.babel_caption_lang_len, codes[i]);
            state.markConfigDirty();
        }
    }

    _ = dvui.label(@src(), "Translate subtitles to", .{}, .{
        .color_text = theme.colors.text_secondary,
        .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = theme.spacing.xs },
    });
    {
        const codes = [_][]const u8{ "", "en", "es", "fr", "de", "pt", "it", "ru", "zh", "ja", "ko", "hi", "ar", "tr" };
        const names = [_][]const u8{ "Off", "EN", "ES", "FR", "DE", "PT", "IT", "RU", "ZH", "JA", "KO", "HI", "AR", "TR" };
        const cur = babel.translateLang();
        var sel: usize = 0;
        for (codes, 0..) |code, i| if (std.mem.eql(u8, cur, code)) {
            sel = i;
        };
        if (components.segment(@src(), &names, sel)) |i| {
            setBuf(&state.app.babel_translate_lang, &state.app.babel_translate_lang_len, codes[i]);
            state.markConfigDirty();
        }
    }
    _ = dvui.label(@src(), "Uses your local AI model (Settings › AI); a cloud provider only if you chose one there. Lines the model can't translate keep their original text.", .{}, .{
        .color_text = theme.colors.text_tertiary,
        .margin = .{ .x = 0, .y = 2, .w = 0, .h = theme.spacing.sm },
    });

    {
        const before = state.app.babel_recap_enabled;
        components.toggleRow(@src(), "\"Previously on…\" recaps", "Offer a spoiler-safe recap at the start of a TV episode, built only from episodes you've watched", &state.app.babel_recap_enabled);
        if (state.app.babel_recap_enabled != before) state.markConfigDirty();
    }
    {
        const before = state.app.babel_recap_tts;
        components.toggleRow(@src(), "Read recaps aloud", "Speak the recap with the voice assistant's text-to-speech", &state.app.babel_recap_tts);
        if (state.app.babel_recap_tts != before) state.markConfigDirty();
    }
}

fn setBuf(buf: *[8]u8, len: *usize, v: []const u8) void {
    @memset(buf, 0);
    const n = @min(v.len, buf.len);
    @memcpy(buf[0..n], v[0..n]);
    len.* = n;
}
