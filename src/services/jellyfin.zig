const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const player = @import("../player/player.zig");

const alloc = @import("../core/alloc.zig").allocator;

// On refetch/disconnect the old JfItems own a GPU poster_tex + heap
// poster_pixels that resetting item_count alone would leak. dvui.textureDestroyLater
// is UI-thread only, so workers (parseItemsResponse) and the possibly-off-UI-thread
// disconnect() queue the old textures here; fetchPoster (UI thread) drains them.
var pending_tex_free: [512]dvui.Texture = undefined;
var pending_tex_free_count: usize = 0;
var pending_tex_free_mutex: @import("../core/sync.zig").Mutex = .{};

fn queueJfTexFree(tex: dvui.Texture) void {
    pending_tex_free_mutex.lock();
    defer pending_tex_free_mutex.unlock();
    if (pending_tex_free_count < pending_tex_free.len) {
        pending_tex_free[pending_tex_free_count] = tex;
        pending_tex_free_count += 1;
    }
}

/// Destroy queued poster textures. UI-THREAD ONLY — call once per render pass.
fn drainJfTexFrees() void {
    pending_tex_free_mutex.lock();
    defer pending_tex_free_mutex.unlock();
    for (pending_tex_free[0..pending_tex_free_count]) |t| dvui.textureDestroyLater(t);
    pending_tex_free_count = 0;
}

/// Queue an item's GPU texture for UI-thread destroy and free its pixel buffer.
fn freeItemPoster(item: *state.JfItem) void {
    if (item.poster_tex) |t| {
        queueJfTexFree(t);
        item.poster_tex = null;
    }
    if (item.poster_pixels) |px| {
        alloc.free(px);
        item.poster_pixels = null;
    }
}

fn escapeJsonStr(input: []const u8, out: *[256]u8) []const u8 {
    var o: usize = 0;
    for (input) |ch| {
        if (o + 2 > out.len) break;
        if (ch == '\\') {
            out[o] = '\\';
            out[o + 1] = '\\';
            o += 2;
        } else if (ch == '"') {
            out[o] = '\\';
            out[o + 1] = '"';
            o += 2;
        } else {
            out[o] = ch;
            o += 1;
        }
    }
    return out[0..o];
}

// ══════════════════════════════════════════════════════════
// Authentication
// ══════════════════════════════════════════════════════════

pub fn authenticate() void {
    if (state.app.jf.is_loading.load(.acquire)) return;
    state.app.jf.is_loading.store(true, .release);
    state.app.jf.login_error_len = 0;

    state.app.jf.thread = std.Thread.spawn(.{}, struct {
        fn worker() void {
            defer {
                state.app.jf.is_loading.store(false, .release);
            }

            const server = state.app.jf.server_url[0..state.app.jf.server_url_len];
            if (server.len == 0) {
                setLoginError("Server URL is empty");
                return;
            }

            // Get username (null-terminated -> slice)
            const user = blk: {
                const idx = std.mem.indexOfScalar(u8, &state.app.jf.login_user_buf, 0) orelse 128;
                break :blk state.app.jf.login_user_buf[0..idx];
            };
            const pass = blk: {
                const idx = std.mem.indexOfScalar(u8, &state.app.jf.login_pass_buf, 0) orelse 128;
                break :blk state.app.jf.login_pass_buf[0..idx];
            };

            if (user.len == 0) {
                setLoginError("Username is empty");
                return;
            }

            // Build POST body: {"Username": "xxx", "Pw": "yyy"}
            var safe_user: [256]u8 = undefined;
            var safe_pass: [256]u8 = undefined;
            const su = escapeJsonStr(user, &safe_user);
            const sp = escapeJsonStr(pass, &safe_pass);
            var body_buf: [512]u8 = undefined;
            const body = std.fmt.bufPrint(&body_buf, "{{\"Username\":\"{s}\",\"Pw\":\"{s}\"}}", .{ su, sp }) catch {
                setLoginError("Failed to build request");
                return;
            };

            var url_buf: [512]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "{s}/Users/AuthenticateByName", .{server}) catch return;

            var auth_hdr: [256]u8 = undefined;
            const auth_val = std.fmt.bufPrint(&auth_hdr, "X-Emby-Authorization: MediaBrowser Client=\"ZigZag\", Device=\"Desktop\", DeviceId=\"zigzag-001\", Version=\"1.0\"", .{}) catch return;

            var resp_buf: [16384]u8 = undefined;
            const resp = @import("../core/http.zig").fetch(url, &resp_buf, .{
                .method = .POST,
                .payload = body,
                .content_type = "application/json",
                .auth_header = auth_val,
                .timeout_secs = 10,
            }) orelse {
                setLoginError("Failed to connect or no response");
                return;
            };



            // Extract AccessToken
            const token = extractJsonString(resp, "\"AccessToken\":\"") orelse {
                setLoginError("Auth failed — check credentials");
                return;
            };

            // Extract User.Id (nested inside "User":{...,"Id":"xxx"})
            // The first "Id" is the session Id, so we need to find the one after "User":
            const uid = blk: {
                const user_key = "\"User\":";
                const user_idx = std.mem.indexOf(u8, resp, user_key) orelse {
                    // Fallback: try first "Id" if no "User" found
                    break :blk extractJsonString(resp, "\"Id\":\"") orelse {
                        setLoginError("Could not parse user ID");
                        return;
                    };
                };
                break :blk extractJsonString(resp[user_idx..], "\"Id\":\"") orelse {
                    setLoginError("Could not parse user ID");
                    return;
                };
            };

            // Store credentials
            const tlen = @min(token.len, state.app.jf.token.len);
            @memcpy(state.app.jf.token[0..tlen], token[0..tlen]);
            state.app.jf.token_len = tlen;

            const ulen = @min(uid.len, state.app.jf.user_id.len);
            @memcpy(state.app.jf.user_id[0..ulen], uid[0..ulen]);
            state.app.jf.user_id_len = ulen;

            state.app.jf.connected = true;
            state.markConfigDirty();

            // Immediately fetch libraries
            fetchLibrariesSync();
        }
    }.worker, .{}) catch blk: {
        state.app.jf.is_loading.store(false, .release);
        break :blk null;
    };
    // Detach: the result is observed via state.app.jf, never joined — otherwise the
    // joinable thread handle leaks on every login/library/search.
    if (state.app.jf.thread) |t| t.detach();
}

// ══════════════════════════════════════════════════════════
// Library / Item Fetching
// ══════════════════════════════════════════════════════════

pub fn fetchLibraries() void {
    if (state.app.jf.is_loading.load(.acquire) or !state.app.jf.connected) return;
    state.app.jf.is_loading.store(true, .release);

    state.app.jf.thread = std.Thread.spawn(.{}, struct {
        fn worker() void {
            defer {
                state.app.jf.is_loading.store(false, .release);
            }
            fetchLibrariesSync();
        }
    }.worker, .{}) catch blk: {
        state.app.jf.is_loading.store(false, .release);
        break :blk null;
    };
    // Detach: the result is observed via state.app.jf, never joined — otherwise the
    // joinable thread handle leaks on every login/library/search.
    if (state.app.jf.thread) |t| t.detach();
}

fn fetchLibrariesSync() void {
    const server = state.app.jf.server_url[0..state.app.jf.server_url_len];
    const uid = state.app.jf.user_id[0..state.app.jf.user_id_len];

    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/Users/{s}/Views", .{ server, uid }) catch return;

    const body = jfGet(url) orelse return;
    defer alloc.free(body);

    // Parse Items array
    state.app.jf.library_count = 0;
    var pos: usize = 0;
    while (pos < body.len and state.app.jf.library_count < 16) {
        const item_start = std.mem.indexOf(u8, body[pos..], "{\"Name\":\"") orelse break;
        const abs_start = pos + item_start;

        const lib = &state.app.jf.libraries[state.app.jf.library_count];

        // Extract Name
        if (extractJsonStringAt(body, abs_start, "\"Name\":\"")) |name| {
            const nlen = @min(name.len, lib.name.len);
            @memcpy(lib.name[0..nlen], name[0..nlen]);
            lib.name_len = nlen;
        }

        // Extract Id
        if (extractJsonStringAt(body, abs_start, "\"Id\":\"")) |id| {
            const ilen = @min(id.len, lib.id.len);
            @memcpy(lib.id[0..ilen], id[0..ilen]);
            lib.id_len = ilen;
        }

        // Extract CollectionType
        if (extractJsonStringAt(body, abs_start, "\"CollectionType\":\"")) |ct| {
            const clen = @min(ct.len, lib.collection_type.len);
            @memcpy(lib.collection_type[0..clen], ct[0..clen]);
            lib.collection_type_len = clen;
        }

        state.app.jf.library_count += 1;
        pos = abs_start + 10;
    }
}

pub fn fetchItems(parent_id: []const u8) void {
    if (state.app.jf.is_loading.load(.acquire) or !state.app.jf.connected) return;
    state.app.jf.is_loading.store(true, .release);

    // Store parent_id
    const plen = @min(parent_id.len, state.app.jf.parent_id.len);
    @memcpy(state.app.jf.parent_id[0..plen], parent_id[0..plen]);
    state.app.jf.parent_id_len = plen;

    state.app.jf.thread = std.Thread.spawn(.{}, struct {
        fn worker() void {
            defer {
                state.app.jf.is_loading.store(false, .release);
            }
            fetchItemsSync(state.app.jf.parent_id[0..state.app.jf.parent_id_len], false);
        }
    }.worker, .{}) catch blk: {
        state.app.jf.is_loading.store(false, .release);
        break :blk null;
    };
    // Detach: the result is observed via state.app.jf, never joined — otherwise the
    // joinable thread handle leaks on every login/library/search.
    if (state.app.jf.thread) |t| t.detach();
}

pub fn searchItems() void {
    if (state.app.jf.is_loading.load(.acquire) or !state.app.jf.connected) return;

    const qlen = std.mem.indexOfScalar(u8, &state.app.jf.search_buf, 0) orelse 0;
    if (qlen == 0) return;

    state.app.jf.is_loading.store(true, .release);

    state.app.jf.thread = std.Thread.spawn(.{}, struct {
        fn worker() void {
            defer {
                state.app.jf.is_loading.store(false, .release);
            }
            const qlen2 = std.mem.indexOfScalar(u8, &state.app.jf.search_buf, 0) orelse 0;
            if (qlen2 == 0) return;

            const server = state.app.jf.server_url[0..state.app.jf.server_url_len];
            const uid = state.app.jf.user_id[0..state.app.jf.user_id_len];
            const query = state.app.jf.search_buf[0..qlen2];

            var enc_buf: [256]u8 = undefined;
            const enc = urlEncode(query, &enc_buf);

            var url_buf: [1024]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "{s}/Users/{s}/Items?SearchTerm={s}&Recursive=true&Limit=50&Fields=Overview,Path&IncludeItemTypes=Movie,Series,Episode,Audio,MusicAlbum", .{ server, uid, enc }) catch return;

            const body = jfGet(url) orelse return;
            defer alloc.free(body);

            parseItemsResponse(body);
        }
    }.worker, .{}) catch blk: {
        state.app.jf.is_loading.store(false, .release);
        break :blk null;
    };
    // Detach: the result is observed via state.app.jf, never joined — otherwise the
    // joinable thread handle leaks on every login/library/search.
    if (state.app.jf.thread) |t| t.detach();
}

fn fetchItemsSync(parent_id: []const u8, recursive: bool) void {
    const server = state.app.jf.server_url[0..state.app.jf.server_url_len];
    const uid = state.app.jf.user_id[0..state.app.jf.user_id_len];

    var url_buf: [1024]u8 = undefined;
    const rec_str: []const u8 = if (recursive) "&Recursive=true" else "";
    const url = std.fmt.bufPrint(&url_buf, "{s}/Users/{s}/Items?ParentId={s}&Fields=Overview,Path&Limit=64{s}", .{ server, uid, parent_id, rec_str }) catch return;

    const body = jfGet(url) orelse return;
    defer alloc.free(body);

    parseItemsResponse(body);
}

fn parseItemsResponse(body: []const u8) void {
    // Free the prior result set's poster textures/pixels before reusing the
    // slots — resetting item_count alone leaks them on every refetch.
    for (state.app.jf.items[0..state.app.jf.item_count]) |*old| freeItemPoster(old);
    state.app.jf.item_count = 0;
    var pos: usize = 0;

    while (pos < body.len and state.app.jf.item_count < 64) {
        // Find next item object by looking for "Id":"
        const id_key = "\"Id\":\"";
        const next_id = std.mem.indexOf(u8, body[pos..], id_key) orelse break;
        const abs = pos + next_id;

        // Find the enclosing object start
        const obj_start = blk: {
            var s = abs;
            while (s > 0) : (s -= 1) {
                if (body[s] == '{') break :blk s;
            }
            break :blk abs;
        };

        // Find obj end (simple brace counting)
        const obj_end = findObjEnd(body, obj_start);

        const obj = body[obj_start..obj_end];
        const item = &state.app.jf.items[state.app.jf.item_count];
        item.* = std.mem.zeroes(state.JfItem);

        // Id
        if (extractJsonString(obj, "\"Id\":\"")) |id| {
            const ilen = @min(id.len, item.id.len);
            @memcpy(item.id[0..ilen], id[0..ilen]);
            item.id_len = ilen;
        }

        // Name
        if (extractJsonString(obj, "\"Name\":\"")) |name| {
            const nlen = @min(name.len, item.name.len);
            @memcpy(item.name[0..nlen], name[0..nlen]);
            item.name_len = nlen;
        }

        // Type
        if (extractJsonString(obj, "\"Type\":\"")) |mt| {
            const mlen = @min(mt.len, item.media_type.len);
            @memcpy(item.media_type[0..mlen], mt[0..mlen]);
            item.media_type_len = mlen;

            // Folders: Series, Season, CollectionFolder, Folder, MusicAlbum
            item.is_folder = std.mem.eql(u8, mt, "Series") or
                std.mem.eql(u8, mt, "Season") or
                std.mem.eql(u8, mt, "CollectionFolder") or
                std.mem.eql(u8, mt, "Folder") or
                std.mem.eql(u8, mt, "MusicAlbum") or
                std.mem.eql(u8, mt, "BoxSet");
        }

        // ProductionYear
        if (extractJsonInt(obj, "\"ProductionYear\":")) |y| {
            item.year = @intCast(@min(y, 9999));
        }

        // Overview
        if (extractJsonString(obj, "\"Overview\":\"")) |ov| {
            const olen = @min(ov.len, item.overview.len);
            @memcpy(item.overview[0..olen], ov[0..olen]);
            item.overview_len = olen;
        }

        // RunTimeTicks
        if (extractJsonInt(obj, "\"RunTimeTicks\":")) |t| {
            item.runtime_ticks = t;
        }

        state.app.jf.item_count += 1;
        pos = obj_end;
    }
}

// ══════════════════════════════════════════════════════════
// Playback
// ══════════════════════════════════════════════════════════

pub fn playItem(item_id: []const u8) void {
    const server = state.app.jf.server_url[0..state.app.jf.server_url_len];
    const token = state.app.jf.token[0..state.app.jf.token_len];

    if (server.len == 0 or token.len == 0) return;

    // Build direct stream URL (null-terminated for C API)
    var url_buf: [1024]u8 = undefined;
    const url = std.fmt.bufPrintZ(&url_buf, "{s}/Videos/{s}/stream?static=true&api_key={s}", .{ server, item_id, token }) catch return;

    // Use the player module to load URL into mpv
    if (state.app.active_player_idx < state.app.players.items.len) {
        const p = state.app.players.items[state.app.active_player_idx];
        p.load_file(url.ptr);
        state.showToast("Playing from Jellyfin");
    }
}

pub fn playAudioItem(item_id: []const u8) void {
    const server = state.app.jf.server_url[0..state.app.jf.server_url_len];
    const token = state.app.jf.token[0..state.app.jf.token_len];

    if (server.len == 0 or token.len == 0) return;

    var url_buf: [1024]u8 = undefined;
    const url = std.fmt.bufPrintZ(&url_buf, "{s}/Audio/{s}/universal?api_key={s}&UserId={s}", .{
        server,
        item_id,
        token,
        state.app.jf.user_id[0..state.app.jf.user_id_len],
    }) catch return;

    if (state.app.active_player_idx < state.app.players.items.len) {
        const p = state.app.players.items[state.app.active_player_idx];
        p.load_file(url.ptr);
        state.showToast("Playing audio from Jellyfin");
    }
}

/// Disconnect from Jellyfin
pub fn disconnect() void {
    // Free poster textures/pixels before clearing — item_count=0 alone leaks them.
    for (state.app.jf.items[0..state.app.jf.item_count]) |*old| freeItemPoster(old);
    state.app.jf.connected = false;
    state.app.jf.token_len = 0;
    state.app.jf.user_id_len = 0;
    state.app.jf.item_count = 0;
    state.app.jf.library_count = 0;
    state.app.jf.view = .Libraries;
    state.markConfigDirty();
}

/// Navigate back to libraries view
pub fn goToLibraries() void {
    state.app.jf.view = .Libraries;
    state.app.jf.parent_id_len = 0;
    state.app.jf.parent_name_len = 0;
}

// ══════════════════════════════════════════════════════════
// Poster Thumbnails
// ══════════════════════════════════════════════════════════

pub fn fetchPoster(item: *state.JfItem) void {
    // fetchPoster is only ever called from the Jellyfin render (UI thread) for
    // cards lacking a poster, so it is the reliable UI-thread drain point for
    // textures a prior parseItemsResponse/disconnect queued on a worker thread.
    drainJfTexFrees();
    if (item.id_len == 0 or item.poster_fetching) return;
    // Global poster-fetch cap (shared with all providers) — over the cap, leave
    // poster_fetching false so the card retries next frame.
    if (!@import("../core/poster.zig").tryClaimSlot()) return;
    item.poster_fetching = true;

    if (std.Thread.spawn(.{}, struct {
        fn worker(ptr: *state.JfItem) void {
            defer ptr.poster_fetching = false;
            defer @import("../core/poster.zig").releaseSlot();

            const server = state.app.jf.server_url[0..state.app.jf.server_url_len];
            const token = state.app.jf.token[0..state.app.jf.token_len];
            const item_id = ptr.id[0..ptr.id_len];

            var url_buf: [512]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "{s}/Items/{s}/Images/Primary?maxWidth=200&quality=80&api_key={s}", .{ server, item_id, token }) catch return;

            const img_buf = alloc.alloc(u8, 512 * 1024) catch return;
            defer alloc.free(img_buf);
            const img = @import("../core/http.zig").fetch(url, img_buf, .{ .timeout_secs = 8 }) orelse return;
            const img_len = img.len;

            var w: c_int = 0;
            var h: c_int = 0;
            var comp: c_int = 0;
            const pixels = dvui.c.stbi_load_from_memory(img_buf[0..img_len].ptr, @intCast(img_len), &w, &h, &comp, 4);
            if (pixels == null) return;
            defer dvui.c.stbi_image_free(pixels);

            if (w <= 0 or h <= 0) return;
            // usize-first: w*h*4 in c_int overflows on a large crafted image and
            // panics this worker thread (whole-app abort).
            const p_len: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
            const p_slice = alloc.alloc(u8, p_len) catch return;
            @memcpy(p_slice, pixels[0..p_len]);

            ptr.poster_w = @intCast(w);
            ptr.poster_h = @intCast(h);
            ptr.poster_pixels = p_slice;
        }
    }.worker, .{item})) |t| t.detach() else |_| {
        item.poster_fetching = false;
        @import("../core/poster.zig").releaseSlot(); // spawn failed — release the slot
    }
}

// ══════════════════════════════════════════════════════════
// Continue Watching (Resume)
// ══════════════════════════════════════════════════════════

pub fn fetchResume() void {
    if (state.app.jf.is_loading.load(.acquire) or !state.app.jf.connected) return;

    if (std.Thread.spawn(.{}, struct {
        fn worker() void {
            const server = state.app.jf.server_url[0..state.app.jf.server_url_len];
            const uid = state.app.jf.user_id[0..state.app.jf.user_id_len];

            var url_buf: [512]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "{s}/Users/{s}/Items/Resume?Limit=16&Fields=Overview&MediaTypes=Video", .{ server, uid }) catch return;

            const body = jfGet(url) orelse return;
            defer alloc.free(body);

            // Parse into resume items
            state.app.jf.resume_count = 0;
            var pos: usize = 0;

            while (pos < body.len and state.app.jf.resume_count < 16) {
                const id_key = "\"Id\":\"";
                const next_id = std.mem.indexOf(u8, body[pos..], id_key) orelse break;
                const abs = pos + next_id;

                const obj_start = blk: {
                    var s = abs;
                    while (s > 0) : (s -= 1) {
                        if (body[s] == '{') break :blk s;
                    }
                    break :blk abs;
                };

                const obj_end = findObjEnd(body, obj_start);
                const obj = body[obj_start..obj_end];
                const item = &state.app.jf.resume_items[state.app.jf.resume_count];
                item.* = std.mem.zeroes(state.JfItem);

                if (extractJsonString(obj, "\"Id\":\"")) |id| {
                    const ilen = @min(id.len, item.id.len);
                    @memcpy(item.id[0..ilen], id[0..ilen]);
                    item.id_len = ilen;
                }
                if (extractJsonString(obj, "\"Name\":\"")) |name| {
                    const nlen = @min(name.len, item.name.len);
                    @memcpy(item.name[0..nlen], name[0..nlen]);
                    item.name_len = nlen;
                }
                if (extractJsonString(obj, "\"Type\":\"")) |mt| {
                    const mlen = @min(mt.len, item.media_type.len);
                    @memcpy(item.media_type[0..mlen], mt[0..mlen]);
                    item.media_type_len = mlen;
                }
                if (extractJsonInt(obj, "\"RunTimeTicks\":")) |t| {
                    item.runtime_ticks = t;
                }
                // UserData.PlaybackPositionTicks for progress
                if (std.mem.indexOf(u8, obj, "\"UserData\":")) |ud_start| {
                    const ud = obj[ud_start..];
                    if (extractJsonInt(ud, "\"PlaybackPositionTicks\":")) |pt| {
                        item.played_ticks = pt;
                    }
                }

                state.app.jf.resume_count += 1;
                pos = obj_end;
            }
            state.app.jf.resume_loaded.store(true, .release);
        }
    }.worker, .{})) |t| t.detach() else |_| {}
}

/// Push current browse state onto nav stack before navigating deeper
pub fn pushNav() void {
    if (state.app.jf.nav_depth >= 8) return;
    var entry = &state.app.jf.nav_stack[state.app.jf.nav_depth];
    const plen = state.app.jf.parent_id_len;
    @memcpy(entry.parent_id[0..plen], state.app.jf.parent_id[0..plen]);
    entry.parent_id_len = plen;
    const nlen = state.app.jf.parent_name_len;
    @memcpy(entry.name[0..nlen], state.app.jf.parent_name[0..nlen]);
    entry.name_len = nlen;
    state.app.jf.nav_depth += 1;
}

/// Pop nav stack and navigate back
pub fn popNav() void {
    if (state.app.jf.nav_depth == 0) {
        goToLibraries();
        return;
    }
    state.app.jf.nav_depth -= 1;
    const entry = &state.app.jf.nav_stack[state.app.jf.nav_depth];
    const plen = entry.parent_id_len;
    @memcpy(state.app.jf.parent_id[0..plen], entry.parent_id[0..plen]);
    state.app.jf.parent_id_len = plen;
    const nlen = entry.name_len;
    @memcpy(state.app.jf.parent_name[0..nlen], entry.name[0..nlen]);
    state.app.jf.parent_name_len = nlen;
    fetchItems(state.app.jf.parent_id[0..plen]);
}

// ══════════════════════════════════════════════════════════
// HTTP + JSON Helpers
// ══════════════════════════════════════════════════════════

fn jfGet(url: []const u8) ?[]u8 {
    const token = state.app.jf.token[0..state.app.jf.token_len];

    var auth_buf: [600]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "X-Emby-Authorization: MediaBrowser Client=\"ZigZag\", Device=\"Desktop\", DeviceId=\"zigzag-001\", Version=\"1.0\", Token=\"{s}\"", .{token}) catch return null;

    const resp_buf = alloc.alloc(u8, 256 * 1024) catch return null;
    defer alloc.free(resp_buf);
    const resp = @import("../core/http.zig").fetch(url, resp_buf, .{
        .timeout_secs = 15,
        .accept = "application/json",
        .auth_header = auth,
    }) orelse return null;

    const resp_len = resp.len;

    const result = alloc.alloc(u8, resp_len) catch return null;
    @memcpy(result, resp_buf[0..resp_len]);
    return result;
}

fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, json, key) orelse return null;
    const val_start = idx + key.len;
    if (val_start >= json.len) return null;

    // Find closing quote (handle escaped quotes)
    var end = val_start;
    while (end < json.len) : (end += 1) {
        if (json[end] == '"' and (end == val_start or json[end - 1] != '\\')) break;
    }
    if (end <= val_start) return null;
    return json[val_start..end];
}

fn extractJsonStringAt(json: []const u8, start: usize, key: []const u8) ?[]const u8 {
    if (start >= json.len) return null;
    return extractJsonString(json[start..], key);
}

fn extractJsonInt(json: []const u8, key: []const u8) ?i64 {
    const idx = std.mem.indexOf(u8, json, key) orelse return null;
    const val_start = idx + key.len;
    if (val_start >= json.len) return null;

    var end = val_start;
    while (end < json.len and (json[end] >= '0' and json[end] <= '9')) : (end += 1) {}

    if (end == val_start) return null;
    return std.fmt.parseInt(i64, json[val_start..end], 10) catch null;
}

fn findObjEnd(json: []const u8, start: usize) usize {
    var depth: i32 = 0;
    var i = start;
    var in_string = false;
    while (i < json.len) : (i += 1) {
        if (json[i] == '"' and (i == 0 or json[i - 1] != '\\')) {
            in_string = !in_string;
        } else if (!in_string) {
            if (json[i] == '{') depth += 1;
            if (json[i] == '}') {
                depth -= 1;
                if (depth == 0) return i + 1;
            }
        }
    }
    return json.len;
}

fn urlEncode(input: []const u8, buf: *[256]u8) []const u8 {
    var out: usize = 0;
    for (input) |ch| {
        if (out + 3 >= buf.len) break;
        if ((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.') {
            buf[out] = ch;
            out += 1;
        } else if (ch == ' ') {
            buf[out] = '+';
            out += 1;
        } else {
            buf[out] = '%';
            buf[out + 1] = "0123456789ABCDEF"[ch >> 4];
            buf[out + 2] = "0123456789ABCDEF"[ch & 0xF];
            out += 3;
        }
    }
    return buf[0..out];
}

fn setLoginError(msg: []const u8) void {
    const len = @min(msg.len, state.app.jf.login_error.len);
    @memcpy(state.app.jf.login_error[0..len], msg[0..len]);
    state.app.jf.login_error_len = len;
}
