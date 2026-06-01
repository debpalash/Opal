const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const icons = @import("icons");
const logs = @import("../core/logs.zig");
const player = @import("../player/player.zig");

const alloc = @import("../core/alloc.zig").allocator;


// ══════════════════════════════════════════════════════════
// Anime Tab — allanime.day API integration (built-in, no ani-cli)
// Trending -> Search → Select → Pick Episode → Stream to MPV
// ══════════════════════════════════════════════════════════

const allanime_api = "https://api.allanime.day";

const allanime_refr = "https://allmanga.to";
const agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/121.0";

// NOTE: state.app.anime.is_loading / stream_loading / episodes_loading are plain
// bools in the global state struct, shared between UI and bg threads without
// atomics. Acceptable — worst case is one stale UI frame before the flag is seen.
pub var has_loaded_trending: bool = false;

pub fn loadTrendingAnime() void {
    if (state.app.anime.is_loading or has_loaded_trending) return;
    
    state.app.anime.is_loading = true;
    state.app.anime.result_count = 0;
    state.app.anime.selected_idx = null;
    state.app.anime.episode_count = 0;
    has_loaded_trending = true;
    
    state.app.anime.thread = std.Thread.spawn(.{}, trendingThread, .{}) catch {
        state.app.anime.is_loading = false;
        return;
    };
}

fn trendingThread() void {
    defer state.app.anime.is_loading = false;
    
    const jikan_api = "https://api.jikan.moe/v4/top/anime";
    var arg1_buf: [256]u8 = undefined;
    const arg1 = std.fmt.bufPrint(&arg1_buf, "{s}?filter=airing&limit=24", .{jikan_api}) catch return;
    
    const argv = [_][]const u8{
        "curl", "-s", "-A", agent, arg1,
    };
    
    var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return;
    
    const buf = alloc.alloc(u8, 256 * 1024) catch return;
    defer alloc.free(buf);
    const bytes = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, buf) catch 0 else 0;
    _ = child.wait() catch {};
    
    if (bytes == 0) return;
    
    parseJikanData(buf[0..bytes]);
    logs.pushLog("info", "anime", "Trending loaded (Jikan API)", false);
}

pub fn searchAnime(query: []const u8) void {
    if (state.app.anime.is_loading) return;
    if (query.len == 0) return;
    
    state.app.anime.is_loading = true;
    state.app.anime.result_count = 0;
    state.app.anime.selected_idx = null;
    state.app.anime.episode_count = 0;
    
    // Copy query into a static buffer so the spawned thread doesn't read
    // from the potentially-mutated UI search_buf.
    const safe_len = @min(query.len, search_query_buf.len);
    @memcpy(search_query_buf[0..safe_len], query[0..safe_len]);
    search_query_len = safe_len;
    
    state.app.anime.thread = std.Thread.spawn(.{}, searchThread, .{}) catch {
        state.app.anime.is_loading = false;
        return;
    };
}

var search_query_buf: [256]u8 = undefined;
var search_query_len: usize = 0;

fn searchThread() void {
    defer state.app.anime.is_loading = false;
    const query = search_query_buf[0..search_query_len];
    
    const jikan_api = "https://api.jikan.moe/v4/anime";
    
    var enc_buf: [768]u8 = undefined;
    var enc_len: usize = 0;
    for (query) |c| {
        if (enc_len + 3 > enc_buf.len) break;
        const pct: ?[2]u8 = switch (c) {
            '%' => .{ '2', '5' },
            ' ' => .{ '2', '0' },
            '&' => .{ '2', '6' },
            '=' => .{ '3', 'D' },
            '#' => .{ '2', '3' },
            '?' => .{ '3', 'F' },
            '+' => .{ '2', 'B' },
            else => null,
        };
        if (pct) |hex| {
            enc_buf[enc_len] = '%';
            enc_buf[enc_len + 1] = hex[0];
            enc_buf[enc_len + 2] = hex[1];
            enc_len += 3;
        } else {
            enc_buf[enc_len] = c;
            enc_len += 1;
        }
    }
    
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}?q={s}&limit=24", .{jikan_api, enc_buf[0..enc_len]}) catch return;
    
    const argv = [_][]const u8{
        "curl", "-s", "-A", agent, url,
    };
    
    var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return;
    
    const buf = alloc.alloc(u8, 256 * 1024) catch return;
    defer alloc.free(buf);
    const bytes = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, buf) catch 0 else 0;
    _ = child.wait() catch {};
    
    if (bytes == 0) return;
    
    parseJikanData(buf[0..bytes]);
    logs.pushLog("info", "anime", "Search done (Jikan API)", false);
}

/// Decode common JSON string escapes (\" \\ \/ \n \r \t \b \f \uXXXX) from
/// `src` into `dst`, returning the number of bytes written. Bounded by dst.len.
/// Anything that isn't a recognized escape is copied verbatim (the backslash is
/// kept) so we never silently corrupt content.
fn decodeJsonEscapes(src: []const u8, dst: []u8) usize {
    var out: usize = 0;
    var i: usize = 0;
    while (i < src.len and out < dst.len) {
        const ch = src[i];
        if (ch != '\\' or i + 1 >= src.len) {
            dst[out] = ch;
            out += 1;
            i += 1;
            continue;
        }
        const esc = src[i + 1];
        switch (esc) {
            '"' => { dst[out] = '"'; out += 1; i += 2; },
            '\\' => { dst[out] = '\\'; out += 1; i += 2; },
            '/' => { dst[out] = '/'; out += 1; i += 2; },
            'n' => { dst[out] = '\n'; out += 1; i += 2; },
            'r' => { dst[out] = '\r'; out += 1; i += 2; },
            't' => { dst[out] = '\t'; out += 1; i += 2; },
            'b' => { dst[out] = 0x08; out += 1; i += 2; },
            'f' => { dst[out] = 0x0c; out += 1; i += 2; },
            'u' => {
                // \uXXXX — decode 4 hex digits to a codepoint, then UTF-8 encode.
                if (i + 6 <= src.len) {
                    if (std.fmt.parseInt(u21, src[i + 2 .. i + 6], 16)) |cp| {
                        var utf8_buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &utf8_buf) catch 0;
                        if (n > 0 and out + n <= dst.len) {
                            @memcpy(dst[out .. out + n], utf8_buf[0..n]);
                            out += n;
                        }
                        i += 6;
                    } else |_| {
                        // Malformed — keep the backslash and continue.
                        dst[out] = '\\';
                        out += 1;
                        i += 1;
                    }
                } else {
                    dst[out] = '\\';
                    out += 1;
                    i += 1;
                }
            },
            else => {
                // Unknown escape — preserve the backslash verbatim.
                dst[out] = '\\';
                out += 1;
                i += 1;
            },
        }
    }
    return out;
}

fn parseJikanData(json: []const u8) void {
    var count: usize = 0;
    var pos: usize = 0;
    
    // Clear old result states including poster textures
    for (0..state.app.anime.results.len) |i| {
        state.app.anime.results[i].poster_fetching = false;
        state.app.anime.results[i].expanded = false;
        if (state.app.anime.results[i].poster_tex) |tex| {
            dvui.textureDestroyLater(tex);
            state.app.anime.results[i].poster_tex = null;
        }
    }
    
    while (pos < json.len and count < 24) {
        // Find next mal_id object securely to avoid nested array overlap
        const id_idx = std.mem.indexOf(u8, json[pos..], "\"mal_id\":") orelse break;
        pos += id_idx + 9;
        
        var next_obj_pos = json.len;
        if (std.mem.indexOf(u8, json[pos..], "\"mal_id\":")) |nidx| {
            next_obj_pos = pos + nidx;
        }
        
        const obj_slice = json[pos..next_obj_pos];
        
        // Extract ID
        var id_str: []const u8 = "0";
        var num_end: usize = 0;
        while (num_end < obj_slice.len and obj_slice[num_end] >= '0' and obj_slice[num_end] <= '9') : (num_end += 1) {}
        if (num_end > 0) id_str = obj_slice[0..num_end];
        
        // Extract Title
        var name_str: []const u8 = "";
        if (std.mem.indexOf(u8, obj_slice, "\"title\":\"")) |title_idx| {
            const start = title_idx + 9;
            var in_esc = false;
            var end: usize = start;
            while (end < obj_slice.len) : (end += 1) {
                if (in_esc) { in_esc = false; }
                else if (obj_slice[end] == '\\') { in_esc = true; }
                else if (obj_slice[end] == '"') { break; }
            }
            if (end < obj_slice.len) name_str = obj_slice[start..end];
        }

        // Extract Title English (optional fallback)
        if (name_str.len == 0) {
            if (std.mem.indexOf(u8, obj_slice, "\"title_english\":\"")) |title_idx| {
                const start = title_idx + 17;
                var in_esc = false;
                var end: usize = start;
                while (end < obj_slice.len) : (end += 1) {
                    if (in_esc) { in_esc = false; }
                    else if (obj_slice[end] == '\\') { in_esc = true; }
                    else if (obj_slice[end] == '"') { break; }
                }
                if (end < obj_slice.len) name_str = obj_slice[start..end];
            }
        }
        
        // Extract Episodes
        var ep_count: u16 = 100;
        if (std.mem.indexOf(u8, obj_slice, "\"episodes\":")) |ep_idx| {
            const num_st = ep_idx + 11;
            if (num_st < obj_slice.len and obj_slice[num_st] >= '0' and obj_slice[num_st] <= '9') {
                var ne = num_st;
                while (ne < obj_slice.len and obj_slice[ne] >= '0' and obj_slice[ne] <= '9') : (ne += 1) {}
                if (ne > num_st) ep_count = std.fmt.parseInt(u16, obj_slice[num_st..ne], 10) catch 100;
            }
        }

        // Extract Poster URL
        var poster_url: []const u8 = "";
        if (std.mem.indexOf(u8, obj_slice, "\"large_image_url\":\"")) |img_idx| {
            const start = img_idx + 19;
            var end = start;
            while (end < obj_slice.len and obj_slice[end] != '"') : (end += 1) {}
            if (end < obj_slice.len) poster_url = obj_slice[start..end];
        }

        // Extract Synopsis
        var synopsis: []const u8 = "";
        if (std.mem.indexOf(u8, obj_slice, "\"synopsis\":\"")) |syn_idx| {
            const start = syn_idx + 12;
            var in_esc = false;
            var end: usize = start;
            while (end < obj_slice.len) : (end += 1) {
                if (in_esc) { in_esc = false; }
                else if (obj_slice[end] == '\\') { in_esc = true; }
                else if (obj_slice[end] == '"') { break; }
            }
            if (end < obj_slice.len) synopsis = obj_slice[start..end];
        }

        // Extract Score
        var score: f32 = 0.0;
        if (std.mem.indexOf(u8, obj_slice, "\"score\":")) |sc_idx| {
            const start = sc_idx + 8;
            if (start < obj_slice.len and ((obj_slice[start] >= '0' and obj_slice[start] <= '9') or obj_slice[start] == '.')) {
                var end = start;
                while (end < obj_slice.len and ((obj_slice[end] >= '0' and obj_slice[end] <= '9') or obj_slice[end] == '.')) : (end += 1) {}
                if (end > start) score = std.fmt.parseFloat(f32, obj_slice[start..end]) catch 0.0;
            }
        }

        if (name_str.len > 0 and name_str.len <= 128) {
            var item = &state.app.anime.results[count];
            @memcpy(item.id[0..id_str.len], id_str);
            item.id_len = id_str.len;
            
            // Decode JSON escapes in name (\" \\ \/ \n \t \uXXXX, etc.)
            item.name_len = decodeJsonEscapes(name_str, &item.name);
            item.episodes = ep_count;
            item.score = score;
            
            const purl = @min(poster_url.len, 128);
            @memcpy(item.poster_url[0..purl], poster_url[0..purl]);
            item.poster_url_len = purl;
            
            // Decode JSON escapes in synopsis (\" \\ \/ \n \t \uXXXX, etc.)
            item.overview_len = decodeJsonEscapes(synopsis, &item.overview);
            
            item.poster_fetching = false;
            if (item.poster_tex) |tx| {
                dvui.textureDestroyLater(tx);
            }
            item.poster_tex = null;
            item.expanded = false;

            count += 1;
        }
        
        pos = next_obj_pos;
    }
    
    state.app.anime.result_count = count;
}

pub fn loadEpisodes(idx: usize) void {
    if (idx >= state.app.anime.result_count) return;
    state.app.anime.selected_idx = idx;
    
    // Instantly populate numbered episode slots so UI is responsive
    const max_eps = state.app.anime.results[idx].episodes;
    var ep_count: usize = 0;
    
    while (ep_count < max_eps and ep_count < 200) : (ep_count += 1) {
        var str_buf: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&str_buf, "{d}", .{ep_count + 1}) catch "1";
        @memcpy(state.app.anime.episode_list[ep_count][0..s.len], s);
        state.app.anime.episode_list_lens[ep_count] = s.len;
        state.app.anime.episode_title_lens[ep_count] = 0;
        state.app.anime.episode_aired_lens[ep_count] = 0;
        state.app.anime.episode_scores[ep_count] = 0;
        state.app.anime.episode_filler[ep_count] = false;
    }
    state.app.anime.episode_count = ep_count;
    state.app.anime.is_loading = false;
    
    // Now kick off Jikan episodes enrichment in background
    if (!state.app.anime.episodes_loading) {
        state.app.anime.episodes_loading = true;
        _ = std.Thread.spawn(.{}, fetchEpisodeDataThread, .{idx}) catch {
            state.app.anime.episodes_loading = false;
        };
    }
}

fn fetchEpisodeDataThread(idx: usize) void {
    defer state.app.anime.episodes_loading = false;
    
    const mal_id = state.app.anime.results[idx].id[0..state.app.anime.results[idx].id_len];
    
    // Fetch up to 4 pages of episodes (100 eps per page from Jikan)
    var page: u32 = 1;
    var total_parsed: usize = 0;
    
    while (page <= 4 and total_parsed < state.app.anime.episode_count) : (page += 1) {
        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://api.jikan.moe/v4/anime/{s}/episodes?page={d}", .{ mal_id, page }) catch break;
        
        const argv = [_][]const u8{
            "curl", "-s", "-A", agent, "--max-time", "10", url,
        };
        var child = @import("../core/io_global.zig").Child.init(&argv, std.heap.c_allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        _ = child.spawn() catch break;
        
        var buf: [64 * 1024]u8 = undefined;
        const len = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, &buf) catch 0 else 0;
        _ = child.wait() catch {};
        
        if (len < 10) break;
        const json = buf[0..len];
        
        // Parse each episode in the data array
        var pos: usize = 0;
        var found_any = false;
        
        while (pos < json.len and total_parsed < 200) {
            // Find next "mal_id": in episodes array
            const id_idx = std.mem.indexOf(u8, json[pos..], "\"mal_id\":") orelse break;
            pos += id_idx + 9;
            
            // Extract episode number
            var num_end: usize = 0;
            while (num_end < json.len - pos and json[pos + num_end] >= '0' and json[pos + num_end] <= '9') : (num_end += 1) {}
            if (num_end == 0) continue;
            const ep_num = std.fmt.parseInt(usize, json[pos .. pos + num_end], 10) catch continue;
            if (ep_num == 0 or ep_num > 200) { pos += num_end; continue; }
            const ep_idx = ep_num - 1;
            
            // Find scope of this episode object
            var next_ep = json.len;
            if (std.mem.indexOf(u8, json[pos..], "\"mal_id\":")) |nidx| {
                next_ep = pos + nidx;
            }
            const obj = json[pos..next_ep];
            
            // Extract title
            if (std.mem.indexOf(u8, obj, "\"title\":\"")) |ti| {
                const start = ti + 9;
                var end = start;
                var esc = false;
                while (end < obj.len) : (end += 1) {
                    if (esc) { esc = false; } else if (obj[end] == '\\') { esc = true; } else if (obj[end] == '"') break;
                }
                if (end < obj.len) {
                    const tlen = @min(end - start, 80);
                    @memcpy(state.app.anime.episode_titles[ep_idx][0..tlen], obj[start .. start + tlen]);
                    state.app.anime.episode_title_lens[ep_idx] = tlen;
                }
            }
            
            // Extract aired date (just YYYY-MM-DD)
            if (std.mem.indexOf(u8, obj, "\"aired\":\"")) |ai| {
                const start = ai + 9;
                const dlen = @min(10, obj.len - start);
                @memcpy(state.app.anime.episode_aired[ep_idx][0..dlen], obj[start .. start + dlen]);
                state.app.anime.episode_aired_lens[ep_idx] = dlen;
            }
            
            // Extract score
            if (std.mem.indexOf(u8, obj, "\"score\":")) |si| {
                const start = si + 8;
                if (start < obj.len and ((obj[start] >= '0' and obj[start] <= '9') or obj[start] == '.')) {
                    var end = start;
                    while (end < obj.len and ((obj[end] >= '0' and obj[end] <= '9') or obj[end] == '.')) : (end += 1) {}
                    state.app.anime.episode_scores[ep_idx] = std.fmt.parseFloat(f32, obj[start..end]) catch 0;
                }
            }
            
            // Extract filler flag
            if (std.mem.indexOf(u8, obj, "\"filler\":true")) |_| {
                state.app.anime.episode_filler[ep_idx] = true;
            }
            
            total_parsed += 1;
            found_any = true;
            pos = next_ep;
        }
        
        if (!found_any) break;
        
        // Jikan rate limit: ~3 req/sec
        @import("../core/io_global.zig").sleep(400 * std.time.ns_per_ms);
    }
}

pub fn playEpisode(ep_no: []const u8) void {
    if (state.app.anime.selected_idx == null) return;
    const idx = state.app.anime.selected_idx.?;
    if (idx >= state.app.anime.result_count) return;
    
    state.app.anime.stream_loading = true;
    
    var ep_copy: [8]u8 = std.mem.zeroes([8]u8);
    const ep_len = @min(ep_no.len, 7);
    @memcpy(ep_copy[0..ep_len], ep_no[0..ep_len]);
    
    _ = std.Thread.spawn(.{}, fetchStreamThread, .{ ep_copy, ep_len }) catch {
        state.app.anime.stream_loading = false;
    };
}

fn fetchStreamThread(ep_buf: [8]u8, ep_len: usize) void {
    defer state.app.anime.stream_loading = false;
    
    const ep_no = ep_buf[0..ep_len];
    const sel_idx = state.app.anime.selected_idx orelse return;
    
    var name_buf: [129]u8 = undefined;
    const name_len = state.app.anime.results[sel_idx].name_len;
    @memcpy(name_buf[0..name_len], state.app.anime.results[sel_idx].name[0..name_len]);
    const name_str = name_buf[0..name_len];

    var query_buf: [256]u8 = undefined;
    const query = std.fmt.bufPrintZ(&query_buf, "{s} {s}", .{name_str, ep_no}) catch return;

    // ── Phase 1: Try torrent resolution ──
    logs.pushLog("info", "anime", "Resolving stream via Torrents...", false);

    const resolver = @import("resolver.zig");
    resolver.resolve(query, "anime");

    var waited: usize = 0;
    while (resolver.isResolving() and waited < 100) : (waited += 1) {
        @import("../core/io_global.zig").sleep(100 * std.time.ns_per_ms);
    }

    {
        resolver.results_mutex.lock();
        defer resolver.results_mutex.unlock();

        for (0..resolver.result_count) |i| {
            const item = resolver.results[i];
            if (item.source == .torrent or item.source == .stremio) {
                const srch = @import("search.zig");
                srch.loadTorrentToPlayer(item.url[0..item.url_len]);
                
                var log_buf2: [128]u8 = undefined;
                const log_msg2 = std.fmt.bufPrintZ(&log_buf2, "Playing: {s}", .{item.name[0..@min(item.name_len, 40)]}) catch "Playing";
                logs.pushLog("info", "anime", log_msg2, false);
                return;
            }
        }
    }

    // ── Phase 2: DDL fallback via AnimePahe ──
    logs.pushLog("info", "anime", "No torrent peers. Trying DDL fallback...", false);
    
    if (tryAnimePaheDDL(name_str, ep_no)) return;
    
    logs.pushLog("error", "anime", "No streams found. Try universal search.", true);
}

fn tryAnimePaheDDL(name: []const u8, ep_no: []const u8) bool {
    const c_alloc = std.heap.c_allocator;
    
    // URL-encode the anime name for search
    var enc_buf: [256]u8 = undefined;
    var enc_len: usize = 0;
    for (name) |ch| {
        if (enc_len + 3 >= enc_buf.len) break;
        if ((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '-' or ch == '_') {
            enc_buf[enc_len] = ch;
            enc_len += 1;
        } else if (ch == ' ') {
            enc_buf[enc_len] = '+';
            enc_len += 1;
        } else {
            enc_buf[enc_len] = '%';
            enc_buf[enc_len + 1] = "0123456789ABCDEF"[ch >> 4];
            enc_buf[enc_len + 2] = "0123456789ABCDEF"[ch & 0xF];
            enc_len += 3;
        }
    }
    
    // Search AnimePahe for the anime
    var url_buf: [512]u8 = undefined;
    const search_url = std.fmt.bufPrint(&url_buf, "https://animepahe.pw/api?m=search&q={s}", .{enc_buf[0..enc_len]}) catch return false;
    
    const argv_search = [_][]const u8{
        "curl", "-sL", "--max-time", "10",
        "-H", "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0",
        "-H", "Referer: https://animepahe.pw",
        search_url,
    };
    var child = @import("../core/io_global.zig").Child.init(&argv_search, c_alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return false;
    
    var buf: [32 * 1024]u8 = undefined;
    const len = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, &buf) catch 0 else 0;
    _ = child.wait() catch {};
    
    if (len < 10) return false;
    const json = buf[0..len];
    
    // Extract first matching session from search results
    // Format: {"data":[{"session":"xxxx-xxxx","title":"...","episodes":N},...]}
    var session: []const u8 = "";
    if (std.mem.indexOf(u8, json, "\"session\":\"")) |si| {
        const start = si + 11;
        var end = start;
        while (end < json.len and json[end] != '"') : (end += 1) {}
        if (end < json.len) session = json[start..end];
    }
    
    if (session.len == 0) {
        logs.pushLog("warn", "anime", "AnimePahe: anime not found", false);
        return false;
    }
    
    // Construct the watch URL for mpv + ytdl-hook
    // AnimePahe format: https://animepahe.pw/anime/{session}
    // mpv will use yt-dlp/ytdl to extract the stream
    var watch_url_buf: [256]u8 = undefined;
    const watch_url = std.fmt.bufPrintZ(&watch_url_buf, "https://animepahe.pw/play/{s}/{s}", .{session, ep_no}) catch return false;
    
    logs.pushLog("info", "anime", "DDL: Loading via AnimePahe...", false);
    
    // Load directly via mpv (it will use ytdl-hook or we can try yt-dlp extraction)
    const c = @import("../core/c.zig");
    if (state.app.players.items.len > 0 and state.app.active_player_idx < state.app.players.items.len) {
        const p = state.app.players.items[state.app.active_player_idx];
        var cmd_buf: [300]u8 = undefined;
        const cmd_str = std.fmt.bufPrintZ(&cmd_buf, "loadfile \"{s}\"", .{watch_url}) catch return false;
        _ = c.mpv.mpv_command_string(p.mpv_ctx, cmd_str.ptr);
        return true;
    }
    
    return false;
}

// ══════════════════════════════════════════════════════════
// UI Rendering (Drawer)
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    if (!has_loaded_trending and state.app.anime.result_count == 0 and state.app.anime.search_buf[0] == 0) {
        loadTrendingAnime();
    }
    
    // Search bar
    {
        var search_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
            .background = true,
            .color_fill = theme.colors.bg_header,
        });
        defer search_row.deinit();
        
        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.anime.search_buf } }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 200, .h = 20 },
            .color_fill = theme.colors.bg_input,
            .color_border = theme.colors.border_input,
            .color_text = theme.colors.text_main,
            .border = dvui.Rect.all(1),
            .corner_radius = theme.dims.rad_sm,
        });
        const enter_pressed = te.enter_pressed;
        te.deinit();
        
        const clicked = dvui.button(@src(), "Search", .{}, .{
            .color_fill = theme.colors.accent,
            .color_text = dvui.Color.white,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
            .margin = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
        });
        if (clicked or enter_pressed) {
            const input = std.mem.sliceTo(&state.app.anime.search_buf, 0);
            if (input.len > 0) {
                searchAnime(input);
            }
        }
    }
    
    // Loading indicator
    if (state.app.anime.is_loading) {
        _ = dvui.label(@src(), "Loading...", .{}, .{
            .color_text = theme.colors.accent,
            .padding = .{ .x = 12, .y = 8, .w = 0, .h = 0 },
        });
        return;
    }
    
    if (state.app.anime.stream_loading) {
        _ = dvui.label(@src(), "Loading stream...", .{}, .{
            .color_text = theme.colors.accent,
            .padding = .{ .x = 12, .y = 8, .w = 0, .h = 0 },
        });
    }
    
    // Episode list (if anime selected)
    if (state.app.anime.selected_idx) |sel_idx| {
        if (sel_idx < state.app.anime.result_count) {
            const r = state.app.anime.results[sel_idx];
            {
                var sel_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
                    .background = true,
                    .color_fill = theme.colors.bg_card,
                });
                defer sel_row.deinit();
                
                if (dvui.button(@src(), "<", .{}, .{
                    .color_fill = theme.colors.accent,
                    .color_text = dvui.Color.white,
                    .corner_radius = theme.dims.rad_sm,
                    .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
                })) {
                    state.app.anime.selected_idx = null;
                    state.app.anime.episode_count = 0;
                }
                
                _ = dvui.label(@src(), "{s}", .{r.name[0..r.name_len]}, .{
                    .color_text = theme.colors.text_main,
                    .expand = .horizontal,
                    .padding = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
                });
                
                // Episode count badge
                {
                    var ep_info: [32]u8 = undefined;
                    const info = std.fmt.bufPrintZ(&ep_info, "{d} ep", .{state.app.anime.episode_count}) catch "?";
                    _ = dvui.label(@src(), "{s}", .{info}, .{
                        .id_extra = 50,
                        .color_text = theme.colors.text_muted,
                    });
                }
            }
            
            // Episode cards
            if (state.app.anime.episode_count > 0) {
                // Loading indicator for episode enrichment
                if (state.app.anime.episodes_loading) {
                    _ = dvui.label(@src(), "Loading episode details...", .{}, .{
                        .color_text = theme.colors.accent,
                        .padding = .{ .x = 12, .y = 4, .w = 0, .h = 0 },
                    });
                }
                
                var scroll = dvui.scrollArea(@src(), .{}, .{
                    .expand = .both,
                });
                defer scroll.deinit();
                
                var ep_i: usize = 0;
                while (ep_i < state.app.anime.episode_count) : (ep_i += 1) {
                    const ep_len = state.app.anime.episode_list_lens[ep_i];
                    if (ep_len == 0) continue;
                    const ep_str = state.app.anime.episode_list[ep_i][0..ep_len];
                    const has_title = state.app.anime.episode_title_lens[ep_i] > 0;
                    const is_filler = state.app.anime.episode_filler[ep_i];
                    
                    // Episode card container
                    const fill_color = if (is_filler) 
                        dvui.Color{ .r = 60, .g = 40, .b = 40, .a = 255 }
                    else 
                        theme.colors.bg_card;
                    
                    var ep_card = dvui.box(@src(), .{ .dir = .vertical }, .{
                        .id_extra = ep_i + 2000,
                        .expand = .horizontal,
                        .background = true,
                        .color_fill = fill_color,
                        .color_border = theme.colors.bg_header_border,
                        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
                        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
                    });
                    defer ep_card.deinit();
                    
                    // Top row: Ep number + play button
                    {
                        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{
                            .id_extra = ep_i + 3000,
                            .expand = .horizontal,
                        });
                        defer top.deinit();
                        
                        // Episode number badge
                        var ep_badge: [16]u8 = undefined;
                        const badge = std.fmt.bufPrintZ(&ep_badge, "Ep {s}", .{ep_str}) catch "?";
                        _ = dvui.label(@src(), "{s}", .{badge}, .{
                            .id_extra = ep_i + 3100,
                            .color_text = theme.colors.accent,
                        });
                        
                        // Filler badge
                        if (is_filler) {
                            _ = dvui.label(@src(), " FILLER", .{}, .{
                                .id_extra = ep_i + 3200,
                                .color_text = dvui.Color{ .r = 255, .g = 100, .b = 100, .a = 200 },
                            });
                        }
                        
                        // Score on the right
                        const sc = state.app.anime.episode_scores[ep_i];
                        if (sc > 0) {
                            var sc_buf: [8]u8 = undefined;
                            const sc_pct = @as(u8, @intFromFloat(std.math.clamp(sc * 20.0, 0.0, 100.0)));
                            const sc_color = if (sc_pct >= 70) theme.colors.success else if (sc_pct >= 50) theme.colors.warning else theme.colors.danger;
                            if (std.fmt.bufPrintZ(&sc_buf, " {d}%", .{sc_pct})) |scs| {
                                _ = dvui.label(@src(), "{s}", .{scs}, .{
                                    .id_extra = ep_i + 3300,
                                    .color_text = sc_color,
                                });
                            } else |_| {}
                        }
                    }
                    
                    // Title row (if enriched)
                    if (has_title) {
                        const title = state.app.anime.episode_titles[ep_i][0..state.app.anime.episode_title_lens[ep_i]];
                        if (dvui.button(@src(), title, .{}, .{
                            .id_extra = ep_i + 4000,
                            .expand = .horizontal,
                            .color_text = theme.colors.text_main,
                            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                            .padding = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
                        })) {
                            playEpisode(ep_str);
                        }
                    } else {
                        // Fallback: plain play button
                        if (dvui.button(@src(), "▶ Play", .{}, .{
                            .id_extra = ep_i + 4000,
                            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                            .color_text = theme.colors.text_main,
                            .padding = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
                        })) {
                            playEpisode(ep_str);
                        }
                    }
                    
                    // Aired date
                    const aired_len = state.app.anime.episode_aired_lens[ep_i];
                    if (aired_len > 0) {
                        _ = dvui.label(@src(), "{s}", .{state.app.anime.episode_aired[ep_i][0..aired_len]}, .{
                            .id_extra = ep_i + 5000,
                            .color_text = theme.colors.text_muted,
                        });
                    }
                }
            } else {
                _ = dvui.label(@src(), "No episodes available", .{}, .{
                    .color_text = theme.colors.text_muted,
                    .padding = .{ .x = 12, .y = 8, .w = 0, .h = 0 },
                });
            }
            return;
        }
    }
    
    // Gallery cards
    renderGallery();
}

// ══════════════════════════════════════════════════════════
// Gallery Grid & Poster Cards
// ══════════════════════════════════════════════════════════

fn renderGallery() void {
    if (state.app.anime.result_count == 0 and !state.app.anime.is_loading) {
        _ = dvui.label(@src(), "Search for anime or wait for trending...", .{}, .{
            .color_text = theme.colors.text_muted, .gravity_x = 0.5, .margin = dvui.Rect.all(24),
        });
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_drawer });
    defer scroll.deinit();

    for (0..state.app.anime.result_count) |idx| {
        renderCard(&state.app.anime.results[idx], idx);
    }
}

fn renderCard(item: *state.AnimeResult, idx: usize) void {
    if (item.name_len == 0) return;
    const title = item.name[0..item.name_len];
    const hue: u32 = @as(u32, @intCast(idx * 7 + 42)) *% 2654435761;
    const h1: u8 = @truncate(hue & 0xFF);
    const h2: u8 = @truncate((hue >> 8) & 0xFF);

    var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = idx + 1000, .expand = .horizontal, .background = true,
        .color_fill = theme.colors.bg_card, .color_border = theme.colors.bg_header_border,
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .padding = .{ .x = 10, .y = 10, .w = 10, .h = 10 },
    });
    defer card.deinit();

    // Poster placeholder / texture
    {
        var poster = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = idx + 100, .background = true,
            .color_fill = dvui.Color{ .r = 20 + h1 / 6, .g = 25 + h2 / 8, .b = 35 + h1 / 5, .a = 255 },
            .corner_radius = dvui.Rect.all(6),
            .min_size_content = .{ .w = 60, .h = 90 }, .max_size_content = .{ .w = 60, .h = 90 },
        });
        defer poster.deinit();

        // Upload pixels to GPU texture once ready
        if (item.poster_tex == null and item.poster_pixels != null) {
            const num_pixels = item.poster_w * item.poster_h;
            const pixels_pma: []dvui.Color.PMA = @as([*]dvui.Color.PMA, @ptrCast(@alignCast(item.poster_pixels.?.ptr)))[0..num_pixels];
            item.poster_tex = dvui.textureCreate(pixels_pma, item.poster_w, item.poster_h, .linear, .rgba_32) catch null;
            if (item.poster_tex != null) {
                std.heap.c_allocator.free(item.poster_pixels.?);
                item.poster_pixels = null;
            }
        }

        if (item.poster_tex) |*tex| {
            _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
                .id_extra = idx + 150, .expand = .both, .corner_radius = dvui.Rect.all(6),
            });
        } else {
            // Kick off async poster download if not already fetching
            if (!item.poster_fetching and item.poster_url_len > 0) fetchPoster(item);
            dvui.icon(@src(), "", icons.tvg.lucide.@"film", .{}, .{
                .id_extra = idx + 150, .gravity_x = 0.5, .gravity_y = 0.5,
                .color_text = dvui.Color{ .r = h1, .g = h2, .b = 180, .a = 80 },
            });
        }
        _ = &poster;
    }

    // Info column
    {
        var info = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = idx + 200, .expand = .horizontal, .padding = .{ .x = 12, .y = 0, .w = 0, .h = 0 },
        });
        defer info.deinit();

        // Title — click to load episodes
        if (dvui.button(@src(), title, .{}, .{
            .id_extra = idx + 500, .expand = .horizontal,
            .color_text = theme.colors.text_main,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .padding = dvui.Rect.all(0),
        })) {
            loadEpisodes(idx);
        }

        // Meta row: episodes + score
        {
            var meta = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = idx + 600, .expand = .horizontal, .padding = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
            });
            defer meta.deinit();

            // Episode count
            var ep_buf: [32]u8 = undefined;
            if (std.fmt.bufPrintZ(&ep_buf, "{d} eps", .{item.episodes})) |eps| {
                _ = dvui.label(@src(), "{s}", .{eps}, .{ .id_extra = idx + 610, .color_text = theme.colors.text_muted });
            } else |_| {}

            _ = dvui.label(@src(), " · ", .{}, .{ .id_extra = idx + 620, .color_text = theme.colors.text_muted });

            // Score percentage
            const pct = @as(u8, @intFromFloat(std.math.clamp(item.score * 10.0, 0.0, 100.0)));
            const sc = if (pct >= 70) theme.colors.success else if (pct >= 50) theme.colors.warning else theme.colors.danger;
            var pb: [8]u8 = undefined;
            if (std.fmt.bufPrintZ(&pb, "{d}%", .{pct})) |ps| {
                _ = dvui.label(@src(), "{s}", .{ps}, .{ .id_extra = idx + 310, .color_text = sc });
            } else |_| {}
        }

        // Synopsis snippet (click to expand)
        if (item.overview_len > 0) {
            var btn_buf: [128]u8 = undefined;
            const snip_len = @min(item.overview_len, 60);
            const snip = item.overview[0..snip_len];
            const suffix: []const u8 = if (item.overview_len > 60) "..." else "";
            if (std.fmt.bufPrintZ(&btn_buf, "{s}{s}", .{ snip, suffix })) |snip_z| {
                if (dvui.button(@src(), snip_z, .{}, .{
                    .id_extra = idx + 650, .color_text = theme.colors.text_muted, .expand = .horizontal,
                    .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .padding = dvui.Rect.all(0),
                })) {
                    item.expanded = !item.expanded;
                }
            } else |_| {}
        }

        // Full overview when expanded
        if (item.expanded and item.overview_len > 0) {
            _ = dvui.label(@src(), "{s}", .{item.overview[0..item.overview_len]}, .{
                .id_extra = idx + 700, .color_text = theme.colors.text_muted, .expand = .horizontal,
                .padding = .{ .x = 0, .y = 4, .w = 0, .h = 2 },
            });
        }
    }

    // ── Right-click context menu ──
    {
        const ctext = dvui.context(@src(), .{ .rect = card.data().borderRectScale().r }, .{ .id_extra = idx + 3000 });
        defer ctext.deinit();

        if (ctext.activePoint()) |cp| {
            var fw = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(cp) }, .{
                .id_extra = idx + 3000,
                .color_fill = theme.colors.bg_card,
                .color_border = theme.colors.border_drawer,
            });
            defer fw.deinit();

            if ((dvui.menuItemLabel(@src(), "Copy Title", .{}, .{ .expand = .horizontal, .id_extra = idx + 3100 })) != null) {
                dvui.clipboardTextSet(title);
                state.showToast("Title copied");
                fw.close();
            }
        }
    }
}

// ══════════════════════════════════════════════════════════
// Poster Fetching (async, curl + stb_image)
// ══════════════════════════════════════════════════════════

pub fn fetchPoster(item: *state.AnimeResult) void {
    if (item.poster_url_len == 0 or item.poster_fetching) return;
    item.poster_fetching = true;

    // Copy URL and index into struct statics so the thread doesn't hold a
    // pointer into the mutable results array (which can be overwritten by a
    // new search/trending load).
    const S = struct {
        var poster_url_buf: [512]u8 = undefined;
        var poster_url_len: usize = 0;
        var result_idx: usize = 0;

        fn worker() void {
            const idx = @This().result_idx;
            const url = @This().poster_url_buf[0..@This().poster_url_len];

            const argv = [_][]const u8{
                "curl", "-sL", "--max-time", "10", url,
            };
            var child = @import("../core/io_global.zig").Child.init(&argv, std.heap.c_allocator);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Ignore;
            _ = child.spawn() catch {
                markDone(idx, url);
                return;
            };

            const img_buf = @import("../core/alloc.zig").allocator.alloc(u8, 512 * 1024) catch {
                _ = child.wait() catch {};
                markDone(idx, url);
                return;
            };
            defer @import("../core/alloc.zig").allocator.free(img_buf);
            const img_len = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, img_buf) catch 0 else 0;
            _ = child.wait() catch {};

            if (img_len < 100) {
                markDone(idx, url);
                return;
            }

            var w: c_int = 0;
            var h: c_int = 0;
            var comp: c_int = 0;
            const pixels = dvui.c.stbi_load_from_memory(img_buf[0..img_len].ptr, @intCast(img_len), &w, &h, &comp, 4);
            if (pixels == null) {
                markDone(idx, url);
                return;
            }
            defer dvui.c.stbi_image_free(pixels);

            const p_len: usize = @intCast(w * h * 4);
            const p_slice = std.heap.c_allocator.alloc(u8, p_len) catch {
                markDone(idx, url);
                return;
            };
            @memcpy(p_slice, pixels[0..p_len]);

            // Verify the result at this index still has the same URL
            if (idx < state.app.anime.result_count) {
                const ptr = &state.app.anime.results[idx];
                if (ptr.poster_url_len == url.len and
                    std.mem.eql(u8, ptr.poster_url[0..ptr.poster_url_len], url))
                {
                    ptr.poster_w = @intCast(w);
                    ptr.poster_h = @intCast(h);
                    ptr.poster_pixels = p_slice;
                    ptr.poster_fetching = false;
                    return;
                }
            }
            // Mismatch or out of bounds — free pixels
            std.heap.c_allocator.free(p_slice);
        }

        fn markDone(idx: usize, url: []const u8) void {
            if (idx < state.app.anime.result_count) {
                const ptr = &state.app.anime.results[idx];
                if (ptr.poster_url_len == url.len and
                    std.mem.eql(u8, ptr.poster_url[0..ptr.poster_url_len], url))
                {
                    ptr.poster_fetching = false;
                }
            }
        }
    };

    // Find the index of this item in the results array
    const results = state.app.anime.results[0..state.app.anime.result_count];
    var found_idx: ?usize = null;
    for (results, 0..) |*r, i| {
        if (r == item) { found_idx = i; break; }
    }
    const idx = found_idx orelse {
        item.poster_fetching = false;
        return;
    };

    const url = item.poster_url[0..item.poster_url_len];
    if (url.len > S.poster_url_buf.len) {
        item.poster_fetching = false;
        return;
    }
    @memcpy(S.poster_url_buf[0..url.len], url);
    S.poster_url_len = url.len;
    S.result_idx = idx;

    _ = std.Thread.spawn(.{}, S.worker, .{}) catch {
        item.poster_fetching = false;
    };
}
