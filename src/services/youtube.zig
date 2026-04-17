const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");

pub const alloc = @import("../core/alloc.zig").allocator;

var yt_mutex: @import("../core/sync.zig").Mutex = .{};

// ══════════════════════════════════════════════════════════
// YouTube Core Service & UI (Piped API + yt-dlp fallback)
// ══════════════════════════════════════════════════════════

const piped_instances = [_][]const u8{
    "pipedapi.kavin.rocks",
    "pipedapi.adminforge.de",
    "api.piped.yt",
};

pub fn fetchYoutube(query: []const u8) void {
    if (state.app.yt.is_loading) return;
    state.app.yt.is_loading = true;
    
    const actual_query = if (query.len == 0) "trending music 2024" else query;
    
    const S = struct {
        var q_buf: [256]u8 = undefined;
        var q_len: usize = 0;
    };
    
    S.q_len = @min(actual_query.len, 255);
    @memcpy(S.q_buf[0..S.q_len], actual_query[0..S.q_len]);

    state.app.yt.thread = std.Thread.spawn(.{}, struct {
        fn worker() void {
            defer { state.app.yt.is_loading = false; }
            
            yt_mutex.lock();
            state.app.yt.results.clearRetainingCapacity();
            yt_mutex.unlock();
            
            // Try Piped API first (fast, direct HTTP ~0.5s)
            if (fetchViaPiped(S.q_buf[0..S.q_len])) return;
            
            // Fallback to yt-dlp (slow, ~5-10s)
            fetchViaYtdlp(S.q_buf[0..S.q_len]);
        }
    }.worker, .{}) catch blk: {
        state.app.yt.is_loading = false;
        break :blk null;
    };
}

fn urlEncode(input: []const u8, out: []u8) usize {
    const hex = "0123456789ABCDEF";
    var olen: usize = 0;
    for (input) |ch| {
        if (olen + 3 >= out.len) break;
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            out[olen] = ch;
            olen += 1;
        } else if (ch == ' ') {
            out[olen] = '+';
            olen += 1;
        } else {
            out[olen] = '%';
            out[olen + 1] = hex[ch >> 4];
            out[olen + 2] = hex[ch & 0xf];
            olen += 3;
        }
    }
    return olen;
}

fn fetchViaPiped(query: []const u8) bool {
    var encoded: [512]u8 = undefined;
    const elen = urlEncode(query, &encoded);
    if (elen == 0) return false;
    
    for (piped_instances) |host| {
        var url_buf: [768]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://{s}/search?q={s}&filter=videos", .{ host, encoded[0..elen] }) catch continue;
        
        var client = std.http.Client{ .allocator = alloc , .io = @import("../core/io_global.zig").io() };
        defer client.deinit();
        
        const uri = std.Uri.parse(url) catch continue;
        var req = client.request(.GET, uri, .{
            .extra_headers = &.{
                .{ .name = "Accept", .value = "application/json" },
                .{ .name = "User-Agent", .value = "Mozilla/5.0 (X11; Linux x86_64) ZigZag/1.0" },
            },
        }) catch continue;
        defer req.deinit();
        req.sendBodiless() catch continue;
        
        var redirect_buf: [8192]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch continue;
        if (response.head.status != .ok) continue;
        
        var transfer_buf: [4096]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        var rdr = response.readerDecompressing(&transfer_buf, &decompress, &.{});
        
        const body = rdr.allocRemaining(alloc, std.Io.Limit.limited(512 * 1024)) catch continue;
        defer alloc.free(body);
        
        if (body.len < 10) continue;
        
        // Parse Piped JSON response: {"items":[{"url":"/watch?v=...","title":"...","uploaderName":"...","duration":123,"views":456,"thumbnail":"..."},...]}
        parsePipedResults(body);
        return state.app.yt.results.items.len > 0;
    }
    return false;
}

fn parsePipedResults(json: []const u8) void {
    var pos: usize = 0;
    var count: usize = 0;
    
    while (pos < json.len and count < 20) {
        // Find next video item by looking for "url":"/watch?v=
        const url_marker = std.mem.indexOf(u8, json[pos..], "\"url\":\"/watch?v=") orelse break;
        const abs_url = pos + url_marker + 15; // after "/watch?v=
        const vid_end = std.mem.indexOfAny(u8, json[abs_url..], "\"}&,") orelse break;
        const video_id = json[abs_url .. abs_url + vid_end];
        
        if (video_id.len < 5 or video_id.len > 31) { pos = abs_url + vid_end; continue; }
        
        var item = state.YtItem{};
        const vlen = @min(video_id.len, 31);
        @memcpy(item.video_id[0..vlen], video_id[0..vlen]);
        item.video_id_len = vlen;
        
        // Search window for this item's fields
        const window_end = @min(abs_url + 2000, json.len);
        const window = json[abs_url..window_end];
        
        if (extractJsonStr(window, "\"title\":")) |title| {
            const tlen = @min(title.len, 127);
            @memcpy(item.title[0..tlen], title[0..tlen]);
            item.title_len = tlen;
        }
        
        if (extractJsonStr(window, "\"uploaderName\":")) |up| {
            const ulen = @min(up.len, 63);
            @memcpy(item.uploader[0..ulen], up[0..ulen]);
            item.uploader_len = ulen;
        }
        
        item.duration = extractJsonNum(window, "\"duration\":");
        item.views = extractJsonNum(window, "\"views\":");
        
        // Build thumbnail URL
        var thumb_buf: [128]u8 = undefined;
        if (std.fmt.bufPrint(&thumb_buf, "https://i.ytimg.com/vi/{s}/mqdefault.jpg", .{video_id})) |thumb| {
            const tlen = @min(thumb.len, 511);
            @memcpy(item.thumbnail_url[0..tlen], thumb[0..tlen]);
            item.thumbnail_url_len = tlen;
        } else |_| {}
        
        yt_mutex.lock();
        state.app.yt.results.append(alloc, item) catch {};
        yt_mutex.unlock();
        count += 1;
        
        pos = abs_url + vid_end;
    }
}

fn fetchViaYtdlp(query: []const u8) void {
    var search_arg: [280]u8 = undefined;
    const search_str = std.fmt.bufPrintZ(&search_arg, "ytsearch10:{s}", .{query}) catch return;
    
    const argv = [_][]const u8{
        "yt-dlp",
        "--flat-playlist",
        "-j",
        "--no-warnings",
        "--socket-timeout", "10",
        search_str,
    };
    var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return;
    
    var reader_buf: [8192]u8 = undefined;
    var reader = child.stdout.?.reader(@import("../core/io_global.zig").io(), &reader_buf);
    
    while (reader.interface.takeDelimiter('\n') catch null) |line| {
        if (line.len == 0) continue;
        yt_mutex.lock();
        parseYtdlpLine(line);
        yt_mutex.unlock();
    }
    
    _ = child.wait() catch {};
}

fn parseYtdlpLine(json: []const u8) void {
    var item = state.YtItem{};
    
    if (extractJsonStr(json, "\"id\":")) |vid| {
        const vlen = @min(vid.len, 31);
        @memcpy(item.video_id[0..vlen], vid[0..vlen]);
        item.video_id_len = vlen;
    }
    if (item.video_id_len == 0) return;
    
    if (extractJsonStr(json, "\"title\":")) |title| {
        const tlen = @min(title.len, 127);
        @memcpy(item.title[0..tlen], title[0..tlen]);
        item.title_len = tlen;
    }
    
    if (extractJsonStr(json, "\"channel\":")) |ch| {
        const ulen = @min(ch.len, 63);
        @memcpy(item.uploader[0..ulen], ch[0..ulen]);
        item.uploader_len = ulen;
    } else if (extractJsonStr(json, "\"uploader\":")) |ch| {
        const ulen = @min(ch.len, 63);
        @memcpy(item.uploader[0..ulen], ch[0..ulen]);
        item.uploader_len = ulen;
    }
    
    item.duration = extractJsonNum(json, "\"duration\":");
    item.views = extractJsonNum(json, "\"view_count\":");
    
    var thumb_buf: [128]u8 = undefined;
    if (std.fmt.bufPrint(&thumb_buf, "https://i.ytimg.com/vi/{s}/mqdefault.jpg", .{item.video_id[0..item.video_id_len]})) |thumb| {
        const tlen = @min(thumb.len, 511);
        @memcpy(item.thumbnail_url[0..tlen], thumb[0..tlen]);
        item.thumbnail_url_len = tlen;
    } else |_| {}
    
    state.app.yt.results.append(alloc, item) catch {};
}

fn extractJsonStr(json: []const u8, key: []const u8) ?[]const u8 {
    const ki = std.mem.indexOf(u8, json, key) orelse return null;
    const after = json[ki + key.len..];
    var i: usize = 0;
    while (i < after.len and (after[i] == ' ' or after[i] == ':')) i += 1;
    if (i >= after.len or after[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < after.len) : (i += 1) {
        if (after[i] == '"' and (i == 0 or after[i - 1] != '\\')) {
            return after[start..i];
        }
    }
    return null;
}

fn extractJsonNum(json: []const u8, key: []const u8) i64 {
    const ki = std.mem.indexOf(u8, json, key) orelse return 0;
    const after = json[ki + key.len..];
    var i: usize = 0;
    while (i < after.len and (after[i] == ' ' or after[i] == ':')) i += 1;
    if (i + 4 <= after.len and std.mem.eql(u8, after[i..i + 4], "null")) return 0;
    var neg: bool = false;
    if (i < after.len and after[i] == '-') { neg = true; i += 1; }
    const start = i;
    while (i < after.len and after[i] >= '0' and after[i] <= '9') i += 1;
    if (i == start) return 0;
    const val = std.fmt.parseInt(i64, after[start..i], 10) catch 0;
    return if (neg) -val else val;
}

// ══════════════════════════════════════════════════════════
// Thumbnail Fetching
// ══════════════════════════════════════════════════════════

pub fn fetchThumb(item: *state.YtItem) void {
    if (item.thumbnail_url_len == 0 or item.thumb_fetching) return;
    item.thumb_fetching = true;

    _ = std.Thread.spawn(.{}, struct {
        fn worker(ptr: *state.YtItem) void {
            defer ptr.thumb_fetching = false;

            var client = std.http.Client{ .allocator = alloc , .io = @import("../core/io_global.zig").io() };
            defer client.deinit();

            const uri = std.Uri.parse(ptr.thumbnail_url[0..ptr.thumbnail_url_len]) catch return;
            var req = client.request(.GET, uri, .{ .extra_headers = &.{ .{ .name = "Accept", .value = "image/jpeg, image/webp" } } }) catch return;
            defer req.deinit();
            req.sendBodiless() catch return;

            var redirect_buf: [8192]u8 = undefined;
            var response = req.receiveHead(&redirect_buf) catch return;
            if (response.head.status != .ok) return;

            var transfer_buf: [4096]u8 = undefined;
            var decompress: std.http.Decompress = undefined;
            var rdr = response.readerDecompressing(&transfer_buf, &decompress, &.{});

            const body = rdr.allocRemaining(alloc, std.Io.Limit.limited(5 * 1024 * 1024)) catch return;
            defer alloc.free(body);

            var w: c_int = 0;
            var h: c_int = 0;
            var comp: c_int = 0;
            const pixels = dvui.c.stbi_load_from_memory(body.ptr, @intCast(body.len), &w, &h, &comp, 4);
            if (pixels == null) return;
            defer dvui.c.stbi_image_free(pixels);

            const p_len: usize = @intCast(w * h * 4);
            const p_slice = alloc.alloc(u8, p_len) catch return;
            @memcpy(p_slice, pixels[0..p_len]);

            ptr.thumb_w = @intCast(w);
            ptr.thumb_h = @intCast(h);
            ptr.thumb_pixels = p_slice;
        }
    }.worker, .{item}) catch {};
}


// ══════════════════════════════════════════════════════════
// UI Rendering (called from drawer.zig)
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    var content = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = dvui.Rect.all(8) });
    defer content.deinit();

    if (!state.app.yt.loaded_once and !state.app.yt.is_loading) {
        state.app.yt.loaded_once = true;
        fetchYoutube(state.app.yt.search_buf[0..std.mem.indexOfScalar(u8, &state.app.yt.search_buf, 0) orelse state.app.yt.search_buf.len]);
    }

    renderSearchBar();

    if (state.app.yt.is_loading) {
        _ = dvui.label(@src(), "Searching YouTube...", .{}, .{ .color_text = theme.colors.accent, .gravity_x = 0.5, .margin = dvui.Rect.all(12) });
    }

    if (state.app.yt.results.items.len == 0 and !state.app.yt.is_loading) {
        _ = dvui.label(@src(), "No results. Try searching for something.", .{}, .{
            .color_text = theme.colors.text_muted, .gravity_x = 0.5, .margin = dvui.Rect.all(24),
        });
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_drawer });
    defer scroll.deinit();

    yt_mutex.lock();
    defer yt_mutex.unlock();

    for (state.app.yt.results.items, 0..) |*item, idx| {
        renderCard(item, idx);
    }
}

fn renderSearchBar() void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .x = 0, .y = 0, .w = 0, .h = 12 } });
    defer row.deinit();
    
    dvui.icon(@src(), "", icons.tvg.lucide.@"music", .{}, .{ .color_text = theme.colors.accent, .gravity_y = 0.5, .margin = .{ .x=0, .y=0, .w=8, .h=0 } });
    
    var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.yt.search_buf } }, .{
        .expand = .horizontal, .color_fill = theme.colors.bg_input, .color_border = theme.colors.border_input,
        .color_text = theme.colors.text_main, .border = dvui.Rect.all(1), .corner_radius = theme.dims.rad_sm,
    });
    const ep = te.enter_pressed;
    te.deinit();
    
    if (dvui.button(@src(), "Search", .{}, .{
        .color_fill = theme.colors.accent, .color_text = theme.colors.bg_header,
        .corner_radius = theme.dims.rad_sm, .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
        .margin = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
    }) or ep) { 
        const qlen = std.mem.indexOfScalar(u8, &state.app.yt.search_buf, 0) orelse state.app.yt.search_buf.len;
        fetchYoutube(state.app.yt.search_buf[0..qlen]); 
    }
}

fn renderCard(item: *state.YtItem, idx: usize) void {
    const title = item.title[0..item.title_len];
    
    var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = idx, .expand = .horizontal, .background = true,
        .color_fill = theme.colors.bg_card, .color_border = theme.colors.bg_header_border,
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .padding = .{ .x = 10, .y = 10, .w = 10, .h = 10 },
    });
    defer card.deinit();

    // Thumbnail
    {
        var poster = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = idx + 100, .background = true,
            .color_fill = theme.colors.bg_app,
            .corner_radius = dvui.Rect.all(4),
            .min_size_content = .{ .w = 80, .h = 45 }, .max_size_content = .{ .w = 80, .h = 45 },
        });
        defer poster.deinit();

        if (item.thumb_tex == null and item.thumb_pixels != null) {
            const num_pixels = item.thumb_w * item.thumb_h;
            const pixels_pma: []dvui.Color.PMA = @as([*]dvui.Color.PMA, @ptrCast(@alignCast(item.thumb_pixels.?.ptr)))[0..num_pixels];
            item.thumb_tex = dvui.textureCreate(pixels_pma, item.thumb_w, item.thumb_h, .linear, .rgba_32) catch null;
            if (item.thumb_tex != null) { alloc.free(item.thumb_pixels.?); item.thumb_pixels = null; }
        }

        if (item.thumb_tex) |*tex| {
            _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
                .id_extra = idx + 150, .expand = .both, .corner_radius = dvui.Rect.all(4),
            });
        } else {
            if (!item.thumb_fetching and item.thumbnail_url_len > 0) fetchThumb(item);
            dvui.icon(@src(), "", icons.tvg.lucide.@"image", .{}, .{
                .id_extra = idx + 150, .gravity_x = 0.5, .gravity_y = 0.5,
                .color_text = theme.colors.bg_glass,
            });
        }
        
        if (item.duration > 0) {
            var dur_overlay = dvui.overlay(@src(), .{ .id_extra = idx + 160, .expand = .both });
            defer dur_overlay.deinit();
            
            var dur_box = dvui.box(@src(), .{ .dir = .horizontal }, .{ 
                .id_extra = idx + 161, .gravity_x = 1.0, .gravity_y = 1.0,
                .background = true, .color_fill = dvui.Color{ .r=0, .g=0, .b=0, .a=200 },
                .corner_radius = dvui.Rect.all(2), .padding = .{ .x=4, .y=2, .w=4, .h=2 },
                .margin = dvui.Rect.all(2)
            });
            defer dur_box.deinit();
            
            const dur_min = @divTrunc(item.duration, 60);
            const dur_sec = @rem(item.duration, 60);
            var dur_buf: [16]u8 = undefined;
            if (std.fmt.bufPrintZ(&dur_buf, "{d}:{d:0>2}", .{dur_min, dur_sec})) |dur_str| {
                _ = dvui.labelNoFmt(@src(), dur_str, .{}, .{ .id_extra = idx + 162, .color_text = dvui.Color.white });
            } else |_| {}
        }
    }

    // Info
    {
        var info = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = idx + 200, .expand = .horizontal, .padding = .{ .x = 12, .y = 0, .w = 0, .h = 0 },
        });
        defer info.deinit();

        _ = dvui.labelNoFmt(@src(), title, .{}, .{
            .id_extra = idx + 300, .expand = .horizontal, .color_text = theme.colors.text_main,
        });

        {
            var meta = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = idx + 400, .expand = .horizontal, .padding = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
            });
            defer meta.deinit();
            
            _ = dvui.label(@src(), "{s}", .{item.uploader[0..item.uploader_len]}, .{ .id_extra = idx + 410, .color_text = theme.colors.text_muted });
            
            if (item.views > 0) {
                _ = dvui.label(@src(), " • ", .{}, .{ .id_extra = idx + 420, .color_text = theme.colors.border_drawer });
                
                var vbuf: [32]u8 = undefined;
                const views_f = @as(f64, @floatFromInt(item.views));
                if (views_f >= 1_000_000.0) {
                    if (std.fmt.bufPrintZ(&vbuf, "{d:.1}M views", .{views_f / 1_000_000.0})) |v| {
                        _ = dvui.label(@src(), "{s}", .{v}, .{ .id_extra = idx + 430, .color_text = theme.colors.text_muted });
                    } else |_| {}
                } else if (views_f >= 1_000.0) {
                    if (std.fmt.bufPrintZ(&vbuf, "{d:.1}K views", .{views_f / 1_000.0})) |v| {
                        _ = dvui.label(@src(), "{s}", .{v}, .{ .id_extra = idx + 430, .color_text = theme.colors.text_muted });
                    } else |_| {}
                } else {
                    if (std.fmt.bufPrintZ(&vbuf, "{d} views", .{item.views})) |v| {
                        _ = dvui.label(@src(), "{s}", .{v}, .{ .id_extra = idx + 430, .color_text = theme.colors.text_muted });
                    } else |_| {}
                }
            }
        }
        
        // Actions
        {
            var acts = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = idx + 500, .padding = .{ .x = 0, .y = 6, .w = 0, .h = 0 } });
            defer acts.deinit();
            
            if (dvui.button(@src(), "  Play  ", .{}, .{
                .id_extra = idx + 510, .color_fill = theme.colors.accent, .color_text = dvui.Color.black,
                .corner_radius = theme.dims.rad_sm, .padding = .{ .x=16, .y=4, .w=16, .h=4 }
            })) {
                sendToPlayer(item, false);
            }
            
            if (dvui.button(@src(), "  Queue  ", .{}, .{
                .id_extra = idx + 520, .color_fill = theme.colors.bg_glass, .color_text = theme.colors.accent,
                .color_border = theme.colors.accent, .border = dvui.Rect.all(1),
                .corner_radius = theme.dims.rad_sm, .padding = .{ .x=16, .y=4, .w=16, .h=4 },
                .margin = .{ .x = 8, .y=0, .w=0, .h=0 }
            })) {
                sendToPlayer(item, true);
            }
        }
    }

    // ── Right-click context menu ──
    {
        const ctext = dvui.context(@src(), .{ .rect = card.data().borderRectScale().r }, .{ .id_extra = idx + 700 });
        defer ctext.deinit();

        if (ctext.activePoint()) |cp| {
            var fw = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(cp) }, .{
                .id_extra = idx + 700,
                .color_fill = theme.colors.bg_card,
                .color_border = theme.colors.border_drawer,
            });
            defer fw.deinit();

            if ((dvui.menuItemLabel(@src(), "Copy Title", .{}, .{ .expand = .horizontal, .id_extra = idx + 710 })) != null) {
                dvui.clipboardTextSet(title);
                state.showToast("Title copied");
                fw.close();
            }
            if (item.video_id_len > 0) {
                if ((dvui.menuItemLabel(@src(), "Copy YouTube URL", .{}, .{ .expand = .horizontal, .id_extra = idx + 720 })) != null) {
                    var yt_url_buf: [128]u8 = undefined;
                    if (std.fmt.bufPrint(&yt_url_buf, "https://www.youtube.com/watch?v={s}", .{item.video_id[0..item.video_id_len]})) |yt_url| {
                        dvui.clipboardTextSet(yt_url);
                        state.showToast("YouTube URL copied");
                    } else |_| {}
                    fw.close();
                }
            }
        }
    }
}

fn sendToPlayer(item: *state.YtItem, appendToPlaylist: bool) void {
    if (state.app.players.items.len == 0) return;
    const ap = state.app.players.items[state.app.active_player_idx];
    const queue_svc = @import("queue.zig");
    
    var url_buf: [128]u8 = undefined;
    const yt_url = std.fmt.bufPrintZ(&url_buf, "https://www.youtube.com/watch?v={s}", .{item.video_id[0..item.video_id_len]}) catch return;
    
    queue_svc.addToQueue(yt_url, item.title[0..item.title_len], "youtube");
    
    if (appendToPlaylist) {
        const mpv = @import("../core/c.zig").mpv;
        var args = [_][*c]const u8{ "loadfile", yt_url.ptr, "append", null };
        _ = mpv.mpv_command(ap.mpv_ctx, @ptrCast(&args));
        state.showToast("Track queued!");
    } else {
        ap.load_file(yt_url.ptr);
        state.app.drawer_open = false;
    }
}
