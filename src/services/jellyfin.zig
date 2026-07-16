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
var pending_pix_free: [512][]u8 = undefined;
var pending_pix_free_count: usize = 0;
var pending_tex_free_mutex: @import("../core/sync.zig").Mutex = .{};

fn queueJfTexFree(tex: dvui.Texture) void {
    pending_tex_free_mutex.lock();
    defer pending_tex_free_mutex.unlock();
    if (pending_tex_free_count < pending_tex_free.len) {
        pending_tex_free[pending_tex_free_count] = tex;
        pending_tex_free_count += 1;
    }
}

fn queueJfPixFree(px: []u8) void {
    pending_tex_free_mutex.lock();
    defer pending_tex_free_mutex.unlock();
    if (pending_pix_free_count < pending_pix_free.len) {
        pending_pix_free[pending_pix_free_count] = px;
        pending_pix_free_count += 1;
    }
}

/// Destroy queued poster textures + free queued pixel buffers. UI-THREAD ONLY.
fn drainJfTexFrees() void {
    pending_tex_free_mutex.lock();
    defer pending_tex_free_mutex.unlock();
    for (pending_tex_free[0..pending_tex_free_count]) |t| dvui.textureDestroyLater(t);
    pending_tex_free_count = 0;
    for (pending_pix_free[0..pending_pix_free_count]) |px| alloc.free(px);
    pending_pix_free_count = 0;
}

/// Queue an item's GPU texture AND its pixel buffer for UI-thread freeing.
/// Called from the fetch WORKER thread, so neither can be freed here: the UI
/// thread may be mid-read of poster_pixels in textureCreate (use-after-free
/// otherwise). Queue both; the UI drains them in drainJfTexFrees next pass.
fn freeItemPoster(item: *state.JfItem) void {
    if (item.poster_tex) |t| {
        queueJfTexFree(t);
        item.poster_tex = null;
    }
    if (item.poster_pixels) |px| {
        queueJfPixFree(px);
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

            // Snapshot the server URL + credentials into worker-local buffers
            // BEFORE the network call. is_loading only prevents a re-spawn — it
            // does NOT stop the UI thread from editing server_url/login_user_buf/
            // login_pass_buf (the user typing in the login fields) while this
            // worker reads them mid-request. Reading them directly during the
            // HTTP call is a torn read; copy the bytes up-front and use only the
            // local copies for the rest of the request.
            var server_buf: [256]u8 = undefined;
            const server_len = @min(state.app.jf.server_url_len, server_buf.len);
            @memcpy(server_buf[0..server_len], state.app.jf.server_url[0..server_len]);
            const server = server_buf[0..server_len];

            var user_buf_local: [128]u8 = undefined;
            @memcpy(&user_buf_local, &state.app.jf.login_user_buf);
            var pass_buf_local: [128]u8 = undefined;
            @memcpy(&pass_buf_local, &state.app.jf.login_pass_buf);

            if (server.len == 0) {
                setLoginError("Server URL is empty");
                return;
            }

            // Get username (null-terminated -> slice) from the local snapshot.
            const user = blk: {
                const idx = std.mem.indexOfScalar(u8, &user_buf_local, 0) orelse user_buf_local.len;
                break :blk user_buf_local[0..idx];
            };
            const pass = blk: {
                const idx = std.mem.indexOfScalar(u8, &pass_buf_local, 0) orelse pass_buf_local.len;
                break :blk pass_buf_local[0..idx];
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
            const auth_val = std.fmt.bufPrint(&auth_hdr, "X-Emby-Authorization: MediaBrowser Client=\"Opal\", Device=\"Desktop\", DeviceId=\"opal-001\", Version=\"1.0\"", .{}) catch return;

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

    // New browse context: snapshot the ParentId loadMore() will re-issue at
    // the next StartIndex, reset infinite-scroll pagination, and bump
    // paging_gen so an append in flight for the PREVIOUS library/search is
    // dropped rather than landing in this grid.
    current_source = .browse;
    const qlen = @min(plen, current_query.len);
    @memcpy(current_query[0..qlen], parent_id[0..qlen]);
    current_query_len = qlen;
    more_available = true;
    const my_gen = paging_gen.fetchAdd(1, .acq_rel) + 1;

    state.app.jf.thread = std.Thread.spawn(.{}, struct {
        fn worker(gen: u32) void {
            defer {
                state.app.jf.is_loading.store(false, .release);
            }
            fetchItemsSync(state.app.jf.parent_id[0..state.app.jf.parent_id_len], false, gen, false);
        }
    }.worker, .{my_gen}) catch blk: {
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

    // New search context: snapshot the query (search_buf is the live
    // textEntry the user can keep typing into) and reset pagination +
    // generation so an append in flight for the PREVIOUS search/library is
    // dropped.
    current_source = .search;
    const cqlen = @min(qlen, current_query.len);
    @memcpy(current_query[0..cqlen], state.app.jf.search_buf[0..cqlen]);
    current_query_len = cqlen;
    more_available = true;
    const my_gen = paging_gen.fetchAdd(1, .acq_rel) + 1;

    state.app.jf.thread = std.Thread.spawn(.{}, struct {
        fn worker(gen: u32) void {
            defer {
                state.app.jf.is_loading.store(false, .release);
            }
            searchItemsSync(current_query[0..current_query_len], gen, false);
        }
    }.worker, .{my_gen}) catch blk: {
        state.app.jf.is_loading.store(false, .release);
        break :blk null;
    };
    // Detach: the result is observed via state.app.jf, never joined — otherwise the
    // joinable thread handle leaks on every login/library/search.
    if (state.app.jf.thread) |t| t.detach();
}

/// One StartIndex/Limit window of a Jellyfin Search fetch. `append=false`
/// (fresh search) rewrites items[] from 0; `append=true` (loadMore) writes
/// starting at the current item_count. `my_gen` is checked against
/// `paging_gen` right before touching shared state so a search superseded by
/// a newer search/browse is dropped instead of corrupting the current grid.
fn searchItemsSync(query: []const u8, my_gen: u32, append: bool) void {
    const server = state.app.jf.server_url[0..state.app.jf.server_url_len];
    const uid = state.app.jf.user_id[0..state.app.jf.user_id_len];

    var enc_buf: [256]u8 = undefined;
    const enc = urlEncode(query, &enc_buf);

    const start_index: usize = if (append) state.app.jf.item_count else 0;
    var url_buf: [1024]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/Users/{s}/Items?SearchTerm={s}&Recursive=true&Limit={d}&StartIndex={d}&Fields=Overview,Path&IncludeItemTypes=Movie,Series,Episode,Audio,MusicAlbum", .{ server, uid, enc, JF_SEARCH_LIMIT, start_index }) catch return;

    const body = jfGet(url) orelse return;
    defer alloc.free(body);

    if (paging_gen.load(.acquire) != my_gen) return; // superseded by a newer search/browse

    const landed = parseItemsResponse(body, append);
    more_available = landed >= JF_SEARCH_LIMIT and state.app.jf.item_count < state.app.jf.items.len;
}

/// One StartIndex/Limit window of a Jellyfin library Browse fetch.
/// `append=false` (fresh ParentId open) rewrites items[] from 0;
/// `append=true` (loadMore) writes starting at the current item_count.
/// `my_gen` is checked against `paging_gen` right before touching shared
/// state so a fetch superseded by a newer browse/search is dropped instead
/// of corrupting the current grid.
fn fetchItemsSync(parent_id: []const u8, recursive: bool, my_gen: u32, append: bool) void {
    const server = state.app.jf.server_url[0..state.app.jf.server_url_len];
    const uid = state.app.jf.user_id[0..state.app.jf.user_id_len];

    var url_buf: [1024]u8 = undefined;
    const rec_str: []const u8 = if (recursive) "&Recursive=true" else "";
    const start_index: usize = if (append) state.app.jf.item_count else 0;
    const url = std.fmt.bufPrint(&url_buf, "{s}/Users/{s}/Items?ParentId={s}&Fields=Overview,Path&Limit={d}&StartIndex={d}{s}", .{ server, uid, parent_id, JF_PAGE_LIMIT, start_index, rec_str }) catch return;

    const body = jfGet(url) orelse return;
    defer alloc.free(body);

    if (paging_gen.load(.acquire) != my_gen) return; // superseded by a newer browse/search

    const landed = parseItemsResponse(body, append);
    more_available = landed >= JF_PAGE_LIMIT and state.app.jf.item_count < state.app.jf.items.len;
}

/// Parse one Jellyfin /Items response window into state.app.jf.items[].
/// `append=false`: frees the OLD result set's poster textures/pixels first
/// (resetting item_count alone would leak them) and writes from index 0.
/// `append=true` (infinite-scroll loadMore): writes starting at the current
/// item_count and never clears — items[] is a fixed [320]JfItem (state.zig),
/// so already-rendered cards' poster_tex/poster_pixels pointers stay valid
/// across the append (no realloc). item_count is only published once, at the
/// end, rather than incrementally per item — narrows the (pre-existing,
/// unsynchronized) window where the UI thread could read a count ahead of a
/// still-being-filled item. Returns the number of items landed in THIS
/// window: the caller compares it against the request Limit to decide
/// whether `more_available` should clear.
fn parseItemsResponse(body: []const u8, append: bool) usize {
    const cap = state.app.jf.items.len;
    var count: usize = 0;
    if (append) {
        count = state.app.jf.item_count;
    } else {
        for (state.app.jf.items[0..state.app.jf.item_count]) |*old| freeItemPoster(old);
        count = 0;
    }
    const base = count;
    var pos: usize = 0;

    while (pos < body.len and count < cap) {
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
        const item = &state.app.jf.items[count];
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

        // Primary image presence: Jellyfin serializes `"ImageTags":{"Primary":…}`
        // on items that have cover art. Scope the "Primary" lookup to the
        // ImageTags object so an unrelated field can't false-positive.
        if (std.mem.indexOf(u8, obj, "\"ImageTags\":{")) |it_at| {
            const it_start = it_at + "\"ImageTags\":".len;
            const it_end = findObjEnd(obj, it_start);
            item.has_image = std.mem.indexOf(u8, obj[it_start..it_end], "\"Primary\"") != null;
        }

        count += 1;
        pos = obj_end;
    }
    state.app.jf.item_count = count;
    return count - base;
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
    // Retire the infinite-scroll context too — a stray loadMore() after
    // disconnect (already blocked by the `connected` guard) shouldn't also
    // find a stale browse/search query lying around.
    current_source = .none;
    current_query_len = 0;
    more_available = false;
    _ = paging_gen.fetchAdd(1, .acq_rel); // drop any append still in flight
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

            const poster = @import("../core/poster.zig");
            const server = state.app.jf.server_url[0..state.app.jf.server_url_len];
            const token = state.app.jf.token[0..state.app.jf.token_len];
            const item_id = ptr.id[0..ptr.id_len];

            const jp = @import("jellyfin_pure.zig");
            var url_buf: [512]u8 = undefined;
            const url = jp.primaryImageUrl(server, item_id, token, &url_buf) orelse return;

            // Cache key EXCLUDES the api_key — a token rotation must not
            // orphan every cached Jellyfin poster.
            var key_buf: [512]u8 = undefined;
            const cache_url = jp.primaryImageCacheKey(server, item_id, &key_buf) orelse return;

            const cached = poster.cacheLoadForUrl(cache_url);
            defer if (cached) |cb| poster.cacheFreeEncoded(cb);

            var img_buf: ?[]u8 = null;
            defer if (img_buf) |ib| alloc.free(ib);

            var pixels: [*c]u8 = null;
            var w: c_int = 0;
            var h: c_int = 0;
            var attempt: u8 = 0;
            while (attempt < 2) : (attempt += 1) {
                const used_cache = attempt == 0 and cached != null;
                const img: []const u8 = if (used_cache) cached.? else blk: {
                    if (img_buf == null) img_buf = alloc.alloc(u8, 512 * 1024) catch return;
                    break :blk @import("../core/http.zig").fetch(url, img_buf.?, .{ .timeout_secs = 8 }) orelse return;
                };

                var comp: c_int = 0;
                w = 0;
                h = 0;
                pixels = dvui.c.stbi_load_from_memory(img.ptr, @intCast(img.len), &w, &h, &comp, 4);
                if (pixels != null and w > 0 and h > 0) {
                    if (!used_cache) poster.cacheStoreForUrl(cache_url, img, @intCast(w), @intCast(h));
                    break;
                }
                if (pixels != null) dvui.c.stbi_image_free(pixels);
                pixels = null;
                if (used_cache) poster.cacheDeleteForUrl(cache_url) else return;
            }
            if (pixels == null) return;
            defer dvui.c.stbi_image_free(pixels);
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
    const auth = std.fmt.bufPrint(&auth_buf, "X-Emby-Authorization: MediaBrowser Client=\"Opal\", Device=\"Desktop\", DeviceId=\"opal-001\", Version=\"1.0\", Token=\"{s}\"", .{token}) catch return null;

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

// ══════════════════════════════════════════════════════════
// Infinite scroll (StartIndex/Limit paging)
// ══════════════════════════════════════════════════════════
//
// Jellyfin's /Users/{uid}/Items paginates via StartIndex+Limit. `items[]` is
// a fixed [320]JfItem (see state.zig) specifically so an append never
// reallocates — lazy-poster pointers/textures handed to already-rendered
// cards stay valid across a loadMore() append.
//
// `current_source` + `current_query` remember whether the grid on screen is
// a library Browse (ParentId) or a Search (SearchTerm), and the exact
// id/term, so loadMore() can re-issue the SAME query at the next StartIndex.
// The query is snapshotted here rather than read live off
// state.app.jf.search_buf, because that buffer is the live textEntry the
// user can keep typing into after a search lands.
//
// `paging_gen` is bumped every time fetchItems()/searchItems() starts a NEW
// context; loadMore()'s worker checks it before writing so a stale in-flight
// append for a library/search the user has since navigated away from is
// dropped instead of corrupting the current grid.
//
// `more_available` clears once a window returns fewer than its request Limit
// or items[] fills. `loading_more` serializes append fetches so a single
// near-bottom scroll can't spawn a burst (mirrors services/drama.zig).
const JfPageSource = enum { none, browse, search };
var current_source: JfPageSource = .none;
var current_query: [256]u8 = undefined;
var current_query_len: usize = 0;
pub var more_available: bool = true;
pub var loading_more: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var paging_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

/// Per-window item cap for a library Browse fetch (unchanged from the
/// original single-page Limit).
const JF_PAGE_LIMIT: usize = 64;
/// Per-window item cap for a Search fetch (unchanged from the original
/// single-page Limit).
const JF_SEARCH_LIMIT: usize = 50;

/// Infinite-scroll appender: fetch the NEXT StartIndex window for whichever
/// context (library ParentId or search SearchTerm) is currently on screen,
/// and append it onto items[] starting at item_count. Guarded by
/// loading_more + the main is_loading so a near-bottom scroll can't spawn a
/// burst; runs under the current paging_gen so switching library or issuing
/// a new search drops a stale in-flight append. No-op once more_available
/// clears (short window or items[] full). Mirrors services/drama.zig's
/// loadMore.
pub fn loadMore() void {
    if (!more_available) return;
    if (!state.app.jf.connected) return;
    if (state.app.jf.is_loading.load(.acquire)) return;
    if (loading_more.load(.acquire)) return;
    if (state.app.jf.item_count == 0) return;
    if (state.app.jf.item_count >= state.app.jf.items.len) {
        more_available = false;
        return;
    }
    if (current_source == .none) return;
    if (loading_more.swap(true, .acq_rel)) return; // lost the race — another append in flight

    const my_gen = paging_gen.load(.acquire); // stay within the current browse/search context
    const src = current_source;

    // struct{var} pattern (CLAUDE.md): copy the query + context into statics
    // BEFORE spawning — current_query could otherwise be rewritten by a
    // concurrent fetchItems()/searchItems() call starting a new context.
    const S = struct {
        var query_buf: [256]u8 = undefined;
        var query_len: usize = 0;
        var gen: u32 = 0;
        var source: JfPageSource = .none;

        fn worker() void {
            defer loading_more.store(false, .release);
            const q = @This().query_buf[0..@This().query_len];
            switch (@This().source) {
                .browse => fetchItemsSync(q, false, @This().gen, true),
                .search => searchItemsSync(q, @This().gen, true),
                .none => {},
            }
        }
    };
    S.query_len = @min(current_query_len, S.query_buf.len);
    @memcpy(S.query_buf[0..S.query_len], current_query[0..S.query_len]);
    S.gen = my_gen;
    S.source = src;

    if (std.Thread.spawn(.{}, S.worker, .{})) |t| {
        t.detach();
    } else |_| {
        loading_more.store(false, .release);
    }
}

fn setLoginError(msg: []const u8) void {
    const len = @min(msg.len, state.app.jf.login_error.len);
    @memcpy(state.app.jf.login_error[0..len], msg[0..len]);
    state.app.jf.login_error_len = len;
}
