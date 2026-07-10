const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const io = @import("../core/io_global.zig");
const workers = @import("../core/workers.zig");

pub const alloc = @import("../core/alloc.zig").allocator;

const safeUtf8 = @import("../core/text.zig").safeUtf8;

var yt_mutex: @import("../core/sync.zig").Mutex = .{};
// Seamless refresh: instead of clearing results up-front (which blanks the
// grid for the whole ~3s fetch), the worker arms this and the first new item
// to arrive clears the old ones — so a stale-refresh swaps in place.
var pending_clear: bool = false;

// On re-search, appendYt (worker thread) drops the old results via
// clearRetainingCapacity — but those YtItems own a GPU thumb_tex + heap
// thumb_pixels that would otherwise leak. dvui.textureDestroyLater is UI-thread
// only, so the worker queues the old textures here and renderContent drains them.
var pending_tex_free: [512]dvui.Texture = undefined;
var pending_tex_free_count: usize = 0;
var pending_tex_free_mutex: @import("../core/sync.zig").Mutex = .{};

fn queueYtTexFree(tex: dvui.Texture) void {
    pending_tex_free_mutex.lock();
    defer pending_tex_free_mutex.unlock();
    if (pending_tex_free_count < pending_tex_free.len) {
        pending_tex_free[pending_tex_free_count] = tex;
        pending_tex_free_count += 1;
    }
}

/// Destroy queued thumbnail textures. UI-THREAD ONLY — call once per frame.
fn drainYtTexFrees() void {
    pending_tex_free_mutex.lock();
    defer pending_tex_free_mutex.unlock();
    for (pending_tex_free[0..pending_tex_free_count]) |t| dvui.textureDestroyLater(t);
    pending_tex_free_count = 0;
}

// ── Publish dates (parallel to state.app.yt.results) ──
// YtItem can't be extended, so the upload_date (YYYYMMDD) for each result lives
// here, kept index-aligned with results: appended in appendYt(), cleared by the
// same lazy-clear so a stale-refresh swaps it in place too. Guarded by yt_mutex
// (every reader/writer below already holds it).
var dates: std.ArrayListUnmanaged([8]u8) = .empty;
var dates_lens: std.ArrayListUnmanaged(u8) = .empty;
// Staging for the date of the item currently being parsed (parseYtdlpLine /
// parsePipedResults fill this just before calling appendYt).
var staged_date: [8]u8 = std.mem.zeroes([8]u8);
var staged_date_len: u8 = 0;

// ── Live / incremental search ──
// Debounced search-as-you-type. The UI thread records the last keystroke time;
// once the buffer has been stable for the debounce window it auto-fires.
var last_edit_ms: i64 = 0;
var last_fired_query: [256]u8 = std.mem.zeroes([256]u8);
var last_fired_len: usize = 0;
// Buffer contents observed on the previous frame — used to detect a keystroke
// (buffer changed) so the debounce window measures *inactivity*, not total time.
var last_seen_query: [256]u8 = std.mem.zeroes([256]u8);
var last_seen_len: usize = 0;
// Monotonic search generation. Each fetch captures the value at spawn time; a
// worker that finds itself superseded (a newer search bumped this) discards its
// results instead of racing them onto the grid out of order.
var search_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
const DEBOUNCE_MS: i64 = 400;

// ── UI controls (module-level, not in state.zig) ──
var card_w: f32 = 200; // user-cyclable card width, clamp 150..360
const CARD_MIN: f32 = 150;
const CARD_MAX: f32 = 360;

// ── Infinite scroll / load-more ──
// yt-dlp's flat search has no page cursor, so we re-run `ytsearch{N}:` with a
// larger N and append only the rows past what's already on screen (deduped by
// video_id). `loaded_count` is how many we've asked for so far; `loading_more`
// gates the auto-fetch so a near-bottom scroll doesn't spam fetches.
const PAGE_SIZE: usize = 20;
const ITEM_CAP: usize = 200; // below the 256 reserved capacity → appends never realloc
var loaded_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var loading_more: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
// The query the current result set is paged on — captured at first fetch so
// load-more re-runs the right search even if the text box changes mid-scroll.
var paged_query: [256]u8 = std.mem.zeroes([256]u8);
var paged_query_len: usize = 0;

// Set for the duration of a load-more fetch: appendYt then dedupes against the
// existing grid (yt-dlp re-sends the earlier page) and honours ITEM_CAP.
var appending_more: bool = false;

/// Append a result, clearing stale results lazily on the first new one.
/// Caller must hold yt_mutex. Keeps the `dates` arrays index-aligned.
fn appendYt(item: state.YtItem) void {
    if (pending_clear) {
        // Free the old items' GPU textures (queued for the UI thread) and heap
        // pixel buffers before dropping them — clearRetainingCapacity won't.
        for (state.app.yt.results.items) |*old| {
            if (old.thumb_tex) |t| {
                queueYtTexFree(t);
                old.thumb_tex = null;
            }
            if (old.thumb_pixels) |px| {
                alloc.free(px);
                old.thumb_pixels = null;
            }
        }
        state.app.yt.results.clearRetainingCapacity();
        dates.clearRetainingCapacity();
        dates_lens.clearRetainingCapacity();
        pending_clear = false;
    }
    if (appending_more) {
        if (state.app.yt.results.items.len >= ITEM_CAP) return;
        if (videoIdExists(item.video_id[0..item.video_id_len])) return;
    }
    state.app.yt.results.append(alloc, item) catch return;
    // Mirror the staged date so indices stay aligned even on alloc failure.
    dates.append(alloc, staged_date) catch {
        // Roll the result back so the two stay aligned.
        _ = state.app.yt.results.pop();
        return;
    };
    dates_lens.append(alloc, staged_date_len) catch {
        _ = state.app.yt.results.pop();
        _ = dates.pop();
        return;
    };
    // Reset staging for the next row.
    staged_date_len = 0;
}

/// True if a result with `video_id` is already in the grid. Caller holds yt_mutex.
/// Used by load-more to skip the overlap with the previously-loaded page.
fn videoIdExists(video_id: []const u8) bool {
    for (state.app.yt.results.items) |*r| {
        if (std.mem.eql(u8, r.video_id[0..r.video_id_len], video_id)) return true;
    }
    return false;
}

/// Shutdown cleanup. Frees per-result thumbnail pixels the renderer never
/// uploaded (the results ArrayList only owns its own backing, not each item's
/// heap buffer), then the index-aligned date arrays. GPU textures don't need a
/// free here — the window/GL context is already tearing down.
pub fn deinit() void {
    for (state.app.yt.results.items) |*it| {
        if (it.thumb_pixels) |px| {
            alloc.free(px);
            it.thumb_pixels = null;
        }
    }
    state.app.yt.results.deinit(alloc);
    dates.deinit(alloc);
    dates_lens.deinit(alloc);
}

/// Date string for result `idx`, or "" if none/out of range. Caller holds yt_mutex.
fn dateFor(idx: usize) []const u8 {
    if (idx >= dates.items.len or idx >= dates_lens.items.len) return "";
    const n = dates_lens.items[idx];
    if (n == 0) return "";
    return dates.items[idx][0..@min(n, 8)];
}

// ══════════════════════════════════════════════════════════
// YouTube Core Service & UI (Piped API + yt-dlp fallback)
// ══════════════════════════════════════════════════════════

const piped_instances = [_][]const u8{
    "pipedapi.kavin.rocks",
    "pipedapi.adminforge.de",
    "api.piped.yt",
};

pub fn fetchYoutube(query: []const u8) void {
    if (state.app.yt.is_loading.load(.acquire)) return;
    state.app.yt.is_loading.store(true, .release);
    state.app.yt.last_fetch_s = @import("browse_cache.zig").now(); // SWR stamp

    const actual_query = if (query.len == 0) "trending music 2024" else query;

    // Bump the generation; this fetch owns `my_gen`. A later fetch will bump it
    // again, marking this one stale.
    const my_gen = search_gen.fetchAdd(1, .acq_rel) + 1;

    const S = struct {
        var q_buf: [256]u8 = undefined;
        var q_len: usize = 0;
        var gen: u32 = 0;
    };

    S.q_len = @min(actual_query.len, 255);
    @memcpy(S.q_buf[0..S.q_len], actual_query[0..S.q_len]);
    S.gen = my_gen;

    // Fresh search → reset paging. Remember the query this result set is paged
    // on so load-more re-runs the same search even if the text box changes.
    loaded_count.store(PAGE_SIZE, .release);
    loading_more.store(false, .release);
    paged_query_len = S.q_len;
    @memcpy(paged_query[0..S.q_len], S.q_buf[0..S.q_len]);

    // Reserve a stable capacity (on the caller thread, before the worker /
    // any thumb-fetch worker exists) so later appends never realloc the buffer
    // out from under fetchThumb workers holding *YtItem (cf. the TMDB crash).
    state.app.yt.results.ensureTotalCapacity(alloc, 256) catch {};

    state.app.yt.thread = std.Thread.spawn(.{}, struct {
        fn worker() void {
            defer {
                state.app.yt.is_loading.store(false, .release);
            }

            yt_mutex.lock();
            pending_clear = true; // old results stay until the first new one lands
            yt_mutex.unlock();

            // yt-dlp first — reliable (~2s) and always available. Public Piped
            // instances are frequently dead and stall the whole fetch with no
            // timeout, so it's only a backup when yt-dlp yields nothing.
            fetchViaYtdlp(S.q_buf[0..S.q_len], S.gen, PAGE_SIZE);
            // pending_clear still armed ⇒ yt-dlp produced nothing ⇒ try Piped.
            // (Can't use results.len here: lazy-clear keeps the old results.)
            if (pending_clear and isCurrent(S.gen)) _ = fetchViaPiped(S.q_buf[0..S.q_len], S.gen);
        }
    }.worker, .{}) catch blk: {
        state.app.yt.is_loading.store(false, .release);
        break :blk null;
    };
    // Detach: the handle is never joined, so without this each search leaks a
    // thread handle/resources for the life of the process.
    if (state.app.yt.thread) |t| t.detach();
}

/// Load the next page and APPEND it. yt-dlp flat search has no cursor, so we
/// re-run `ytsearch{loaded_count+PAGE_SIZE}:` and dedupe the overlap (the first
/// `loaded_count` rows repeat). Guarded by `loading_more` + the main is_loading
/// so a near-bottom scroll can't spam fetches; the generation guard makes a new
/// search supersede an in-flight load-more.
pub fn fetchMore() void {
    if (state.app.yt.is_loading.load(.acquire)) return;
    if (loading_more.load(.acquire)) return;
    if (loaded_count.load(.acquire) >= ITEM_CAP) return;
    if (paged_query_len == 0) return;
    loading_more.store(true, .release);

    // This load-more belongs to the current generation; a new search bumps the
    // gen and this worker's appends get dropped (isCurrent).
    const my_gen = search_gen.load(.acquire);
    const want = @min(loaded_count.load(.acquire) + PAGE_SIZE, ITEM_CAP);

    const S = struct {
        var q_buf: [256]u8 = undefined;
        var q_len: usize = 0;
        var gen: u32 = 0;
        var n: usize = 0;
    };
    S.q_len = paged_query_len;
    @memcpy(S.q_buf[0..S.q_len], paged_query[0..S.q_len]);
    S.gen = my_gen;
    S.n = want;

    const t = std.Thread.spawn(.{}, struct {
        fn worker() void {
            defer loading_more.store(false, .release);

            yt_mutex.lock();
            appending_more = true;
            yt_mutex.unlock();
            defer {
                yt_mutex.lock();
                appending_more = false;
                yt_mutex.unlock();
            }

            fetchViaYtdlp(S.q_buf[0..S.q_len], S.gen, S.n);

            // Only advance the cursor if this load-more is still current; a
            // superseding search has already reset loaded_count for its own page.
            if (isCurrent(S.gen)) loaded_count.store(S.n, .release);
        }
    }.worker, .{}) catch {
        loading_more.store(false, .release);
        return;
    };
    t.detach();
}

/// True while `gen` is still the newest search. A stale worker bails so its
/// (out-of-date) results never reach the grid.
fn isCurrent(gen: u32) bool {
    return search_gen.load(.acquire) == gen;
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

fn fetchViaPiped(query: []const u8, gen: u32) bool {
    var encoded: [512]u8 = undefined;
    const elen = urlEncode(query, &encoded);
    if (elen == 0) return false;

    for (piped_instances) |host| {
        if (!isCurrent(gen)) return false;
        var url_buf: [768]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://{s}/search?q={s}&filter=videos", .{ host, encoded[0..elen] }) catch continue;

        var client = std.http.Client{ .allocator = alloc, .io = io.io() };
        defer client.deinit();

        const uri = std.Uri.parse(url) catch continue;
        var req = client.request(.GET, uri, .{
            .extra_headers = &.{
                .{ .name = "Accept", .value = "application/json" },
                .{ .name = "User-Agent", .value = "Mozilla/5.0 (X11; Linux x86_64) Opal/1.0" },
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

        // Parse Piped JSON response.
        parsePipedResults(body, gen);
        return state.app.yt.results.items.len > 0;
    }
    return false;
}

fn parsePipedResults(json: []const u8, gen: u32) void {
    var pos: usize = 0;
    var count: usize = 0;

    while (pos < json.len and count < 20) {
        if (!isCurrent(gen)) return;
        // Find next video item by looking for "url":"/watch?v=
        const url_marker = std.mem.indexOf(u8, json[pos..], "\"url\":\"/watch?v=") orelse break;
        const abs_url = pos + url_marker + 15; // after "/watch?v=
        const vid_end = std.mem.indexOfAny(u8, json[abs_url..], "\"}&,") orelse break;
        const video_id = json[abs_url .. abs_url + vid_end];

        if (video_id.len < 5 or video_id.len > 31) {
            pos = abs_url + vid_end;
            continue;
        }

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

        // Piped has no plain upload_date in this list shape — leave it empty.
        staged_date_len = 0;

        yt_mutex.lock();
        appendYt(item);
        yt_mutex.unlock();
        count += 1;

        pos = abs_url + vid_end;
    }
}

fn fetchViaYtdlp(query: []const u8, gen: u32, count: usize) void {
    var search_arg: [288]u8 = undefined;
    const search_str = std.fmt.bufPrintZ(&search_arg, "ytsearch{d}:{s}", .{ count, query }) catch return;

    // --print with a compact tab template instead of -j: full JSON lines carry
    // a huge `description` that overflows the reader buffer (takeDelimiter then
    // errors and we parse nothing). Tab rows are short, fast, and robust.
    // Use the app's bundled yt-dlp (~/.config/opal/bin) — bare "yt-dlp" isn't
    // on the GUI process PATH, so spawning it fails.
    // Trailing field is %(upload_date)s (YYYYMMDD or NA on flat-playlist).
    const ytdlp_bin = @import("ytdlp.zig").binary();
    const argv = [_][]const u8{
        ytdlp_bin,
        "--flat-playlist",
        "--print",
        "%(id)s\t%(title)s\t%(channel)s\t%(duration)s\t%(view_count)s\t%(upload_date)s",
        "--no-warnings",
        "--socket-timeout",
        "10",
        search_str,
    };
    var child = io.Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return;

    var reader_buf: [8192]u8 = undefined;
    var reader = child.stdout.?.reader(io.io(), &reader_buf);

    while (reader.interface.takeDelimiter('\n') catch null) |line| {
        if (line.len == 0) continue;
        if (!isCurrent(gen)) break; // superseded — stop feeding the grid
        yt_mutex.lock();
        parseYtdlpLine(line);
        yt_mutex.unlock();
    }

    _ = child.wait() catch {};
}

/// Parse one tab-delimited row:
///   id \t title \t channel \t duration \t views \t upload_date
/// yt-dlp prints "NA" for missing fields (flat-playlist) — parseInt then fails
/// and we fall back to 0; an "NA"/short date is just skipped.
fn parseYtdlpLine(line: []const u8) void {
    var item = state.YtItem{};
    staged_date_len = 0;

    var it = std.mem.splitScalar(u8, line, '\t');
    const vid = it.next() orelse return;
    if (vid.len == 0 or vid.len > 31 or std.mem.eql(u8, vid, "NA")) return;
    @memcpy(item.video_id[0..vid.len], vid);
    item.video_id_len = vid.len;

    if (it.next()) |title| {
        const tlen = @min(title.len, 127);
        @memcpy(item.title[0..tlen], title[0..tlen]);
        item.title_len = tlen;
    }
    if (it.next()) |ch| {
        if (!std.mem.eql(u8, ch, "NA")) {
            const ulen = @min(ch.len, 63);
            @memcpy(item.uploader[0..ulen], ch[0..ulen]);
            item.uploader_len = ulen;
        }
    }
    if (it.next()) |dur| item.duration = std.fmt.parseInt(i64, dur, 10) catch 0;
    if (it.next()) |views| item.views = std.fmt.parseInt(i64, views, 10) catch 0;
    if (it.next()) |ud| {
        // Expect exactly YYYYMMDD (8 ASCII digits). Anything else → skip.
        if (ud.len == 8 and isAllDigits(ud)) {
            @memcpy(staged_date[0..8], ud[0..8]);
            staged_date_len = 8;
        }
    }

    var thumb_buf: [128]u8 = undefined;
    if (std.fmt.bufPrint(&thumb_buf, "https://i.ytimg.com/vi/{s}/mqdefault.jpg", .{item.video_id[0..item.video_id_len]})) |thumb| {
        const tlen = @min(thumb.len, 511);
        @memcpy(item.thumbnail_url[0..tlen], thumb[0..tlen]);
        item.thumbnail_url_len = tlen;
    } else |_| {}

    appendYt(item);
}

fn isAllDigits(s: []const u8) bool {
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn extractJsonStr(json: []const u8, key: []const u8) ?[]const u8 {
    const ki = std.mem.indexOf(u8, json, key) orelse return null;
    const after = json[ki + key.len ..];
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
    const after = json[ki + key.len ..];
    var i: usize = 0;
    while (i < after.len and (after[i] == ' ' or after[i] == ':')) i += 1;
    if (i + 4 <= after.len and std.mem.eql(u8, after[i .. i + 4], "null")) return 0;
    var neg: bool = false;
    if (i < after.len and after[i] == '-') {
        neg = true;
        i += 1;
    }
    const start = i;
    while (i < after.len and after[i] >= '0' and after[i] <= '9') i += 1;
    if (i == start) return 0;
    const val = std.fmt.parseInt(i64, after[start..i], 10) catch 0;
    return if (neg) -val else val;
}

// ══════════════════════════════════════════════════════════
// Date formatting
// ══════════════════════════════════════════════════════════

/// Render an upload_date (YYYYMMDD) into a compact human "X ago" string.
/// Returns "" if the date is missing/unparseable. Writes into `out`.
fn formatAgo(ymd: []const u8, out: []u8) []const u8 {
    if (ymd.len != 8 or !isAllDigits(ymd)) return "";
    const y = std.fmt.parseInt(i64, ymd[0..4], 10) catch return "";
    const mo = std.fmt.parseInt(i64, ymd[4..6], 10) catch return "";
    const d = std.fmt.parseInt(i64, ymd[6..8], 10) catch return "";
    if (mo < 1 or mo > 12 or d < 1 or d > 31) return "";

    // Days since a fixed epoch (proleptic Gregorian) for both the upload date
    // and "now", then diff. Good enough for a relative label.
    const up_days = daysFromCivil(y, mo, d);
    const now_s = io.timestamp(); // seconds since unix epoch
    const now_days = @divFloor(now_s, 86400) + 719468; // align to daysFromCivil epoch
    var diff = now_days - up_days;
    if (diff < 0) diff = 0;

    if (diff < 1) return std.fmt.bufPrint(out, "today", .{}) catch "";
    if (diff < 2) return std.fmt.bufPrint(out, "yesterday", .{}) catch "";
    if (diff < 7) return std.fmt.bufPrint(out, "{d}d ago", .{diff}) catch "";
    if (diff < 30) return std.fmt.bufPrint(out, "{d}w ago", .{@divTrunc(diff, 7)}) catch "";
    if (diff < 365) return std.fmt.bufPrint(out, "{d}mo ago", .{@divTrunc(diff, 30)}) catch "";
    return std.fmt.bufPrint(out, "{d}y ago", .{@divTrunc(diff, 365)}) catch "";
}

/// Days from civil date relative to 0000-03-01 epoch shifted to match the
/// unix-epoch alignment used above (Howard Hinnant's algorithm, +719468).
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400; // [0, 399]
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + d - 1; // [0, 365]
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe; // days since 0000-03-01
}

// ══════════════════════════════════════════════════════════
// Thumbnail Fetching
// ══════════════════════════════════════════════════════════

pub fn fetchThumb(item: *state.YtItem) void {
    if (item.thumbnail_url_len == 0 or item.thumb_fetching) return;
    // Shared global poster/thumbnail fetch cap — over the cap, leave thumb_fetching
    // false so the card retries next frame (no fetch storm on a full grid).
    if (!@import("../core/poster.zig").tryClaimSlot()) return;
    item.thumb_fetching = true;

    if (std.Thread.spawn(.{}, struct {
        fn worker(ptr: *state.YtItem) void {
            workers.enter();
            defer workers.leave();
            defer ptr.thumb_fetching = false;
            defer @import("../core/poster.zig").releaseSlot();

            const poster = @import("../core/poster.zig");
            const turl = ptr.thumbnail_url[0..ptr.thumbnail_url_len];

            // Shared poster disk cache: a hit skips the network; a cached blob
            // that fails to decode is deleted and refetched (same policy as
            // fetchAsync in core/poster.zig).
            const cached = poster.cacheLoadForUrl(turl);
            defer if (cached) |cb| poster.cacheFreeEncoded(cb);

            var net_body: ?[]u8 = null;
            defer if (net_body) |bo| alloc.free(bo);

            var pixels: [*c]u8 = null;
            var w: c_int = 0;
            var h: c_int = 0;
            var attempt: u8 = 0;
            while (attempt < 2) : (attempt += 1) {
                const used_cache = attempt == 0 and cached != null;
                const body: []const u8 = if (used_cache) cached.? else blk: {
                    var client = std.http.Client{ .allocator = alloc, .io = io.io() };
                    defer client.deinit();

                    const uri = std.Uri.parse(turl) catch return;
                    var req = client.request(.GET, uri, .{ .extra_headers = &.{.{ .name = "Accept", .value = "image/jpeg, image/webp" }} }) catch return;
                    defer req.deinit();
                    req.sendBodiless() catch return;

                    var redirect_buf: [8192]u8 = undefined;
                    var response = req.receiveHead(&redirect_buf) catch return;
                    if (response.head.status != .ok) return;

                    var transfer_buf: [4096]u8 = undefined;
                    var decompress: std.http.Decompress = undefined;
                    var rdr = response.readerDecompressing(&transfer_buf, &decompress, &.{});

                    const body = rdr.allocRemaining(alloc, std.Io.Limit.limited(5 * 1024 * 1024)) catch return;
                    net_body = body;
                    break :blk body;
                };

                var comp: c_int = 0;
                w = 0;
                h = 0;
                pixels = dvui.c.stbi_load_from_memory(body.ptr, @intCast(body.len), &w, &h, &comp, 4);
                if (pixels != null and w > 0 and h > 0) {
                    if (!used_cache) poster.cacheStoreForUrl(turl, body, @intCast(w), @intCast(h));
                    break;
                }
                if (pixels != null) dvui.c.stbi_image_free(pixels);
                pixels = null;
                if (used_cache) poster.cacheDeleteForUrl(turl) else return;
            }
            if (pixels == null) return;
            defer dvui.c.stbi_image_free(pixels);
            // usize-first: w*h*4 in c_int overflows on a large crafted image and
            // panics this worker thread (whole-app abort).
            const p_len: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
            const p_slice = alloc.alloc(u8, p_len) catch return;
            @memcpy(p_slice, pixels[0..p_len]);

            // Quitting → don't publish into a result the deinit path may have
            // already freed; drop our copy so it isn't reported as a leak.
            if (workers.isQuitting()) {
                alloc.free(p_slice);
                return;
            }

            ptr.thumb_w = @intCast(w);
            ptr.thumb_h = @intCast(h);
            ptr.thumb_pixels = p_slice;
        }
    }.worker, .{item})) |t| t.detach() else |_| {
        item.thumb_fetching = false; // spawn failed — reset so the card isn't stuck on placeholder
        @import("../core/poster.zig").releaseSlot();
    }
}

// ══════════════════════════════════════════════════════════
// UI Rendering (called from drawer.zig)
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    drainYtTexFrees(); // free textures from a re-search clear (UI thread)
    var content = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = dvui.Rect.all(8) });
    defer content.deinit();

    if (!state.app.yt.loaded_once and !state.app.yt.is_loading.load(.acquire)) {
        state.app.yt.loaded_once = true;
        const q = currentQuery();
        recordFired(q);
        fetchYoutube(q);
    } else if (state.app.yt.results.items.len > 0 and !state.app.yt.is_loading.load(.acquire) and
        @import("browse_cache.zig").isStale(state.app.yt.last_fetch_s))
    {
        // SWR background refresh — keep showing current results meanwhile.
        fetchYoutube(currentQuery());
    }

    renderToolbar();

    // Debounced live search: fire once the buffer has settled for DEBOUNCE_MS
    // and differs from what we last fired. Enter/button paths fire immediately
    // (renderSearchInline), this just covers as-you-type.
    maybeFireLiveSearch();

    // Only show the loading line on an INITIAL load (nothing yet) — a
    // stale-refresh keeps current results on screen and swaps in place.
    if (state.app.yt.is_loading.load(.acquire) and state.app.yt.results.items.len == 0) {
        _ = dvui.label(@src(), "Searching YouTube...", .{}, .{ .color_text = theme.colors.accent, .gravity_x = 0.5, .margin = dvui.Rect.all(12) });
    }

    if (state.app.yt.results.items.len == 0 and !state.app.yt.is_loading.load(.acquire)) {
        _ = dvui.label(@src(), "No results. Try searching for something.", .{}, .{
            .color_text = theme.colors.text_secondary,
            .gravity_x = 0.5,
            .margin = dvui.Rect.all(24),
        });
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_surface });
    defer scroll.deinit();

    yt_mutex.lock();
    defer yt_mutex.unlock();

    // Responsive grid of 16:9 video tiles from the LIVE width; the column count
    // derives from the user-cyclable card width.
    const rect_w = scroll.data().rect.w;
    const avail_w: f32 = @max(260, (if (rect_w > 1) rect_w else 900) - 8);
    const cols: usize = @max(1, @as(usize, @intFromFloat(avail_w / card_w)));
    const real_card_w: f32 = @max(120, (avail_w - @as(f32, @floatFromInt(cols)) * 8) / @as(f32, @floatFromInt(cols)));

    var i: usize = 0;
    while (i < state.app.yt.results.items.len) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i + 80000, .expand = .horizontal });
        defer row.deinit();
        var col: usize = 0;
        while (col < cols and i + col < state.app.yt.results.items.len) : (col += 1) {
            renderCard(&state.app.yt.results.items[i + col], i + col, real_card_w);
        }
        i += cols;
    }

    // ── Infinite scroll ──
    // When the viewport nears the bottom, fetch+append the next page. Mirrors
    // tmdb.zig: an 800px trigger band, gated by is_loading + loading_more so a
    // scroll can't spam fetches, and capped at ITEM_CAP (below the reserved 256
    // buffer capacity so appends never realloc out from under thumb workers).
    // fetchMore() only spawns a thread; the mutex we hold here is taken by that
    // worker asynchronously, so calling it under the lock is safe.
    const have = state.app.yt.results.items.len;
    if (have > 0 and have < ITEM_CAP and paged_query_len > 0) {
        const max_y = scroll.si.scrollMax(.vertical);
        const near_bottom = max_y > 0 and scroll.si.viewport.y >= max_y - 800;
        if (near_bottom and !state.app.yt.is_loading.load(.acquire) and !loading_more.load(.acquire)) {
            fetchMore();
        }
        if (loading_more.load(.acquire)) {
            _ = dvui.label(@src(), "Loading more…", .{}, .{
                .color_text = theme.colors.text_secondary,
                .gravity_x = 0.5,
                .padding = dvui.Rect.all(12),
            });
        }
    }
}

/// Current search query from the shared buffer (NUL-trimmed).
fn currentQuery() []const u8 {
    return state.app.yt.search_buf[0 .. std.mem.indexOfScalar(u8, &state.app.yt.search_buf, 0) orelse state.app.yt.search_buf.len];
}

/// Remember which query we last fired so live-search doesn't re-fire it.
fn recordFired(q: []const u8) void {
    last_fired_len = @min(q.len, last_fired_query.len);
    @memcpy(last_fired_query[0..last_fired_len], q[0..last_fired_len]);
    last_edit_ms = io.milliTimestamp();
}

/// Debounced search-as-you-type. Called every frame.
///
/// Design: `last_seen_*` snapshots the buffer each frame; whenever it differs
/// from the previous frame we treat that as a keystroke and reset `last_edit_ms`
/// — so the window measures *inactivity*. Once the buffer has been stable for
/// DEBOUNCE_MS, has ≥2 chars, and differs from what we last fired, we fire.
/// fetchYoutube bumps `search_gen`; an in-flight worker whose gen is superseded
/// drops its results (isCurrent), so fast typing never shows out-of-order rows.
fn maybeFireLiveSearch() void {
    const q = currentQuery();
    const now_ms = io.milliTimestamp();

    // Detect a buffer change since the previous frame → restart the debounce.
    const changed = q.len != last_seen_len or !std.mem.eql(u8, q, last_seen_query[0..last_seen_len]);
    if (changed) {
        last_seen_len = @min(q.len, last_seen_query.len);
        @memcpy(last_seen_query[0..last_seen_len], q[0..last_seen_len]);
        last_edit_ms = now_ms;
        return; // wait at least one settle window before firing
    }

    // Nothing changed this frame; fire if settled, meaningful, and not already
    // the last-fired query.
    const same_as_fired = q.len == last_fired_len and std.mem.eql(u8, q, last_fired_query[0..last_fired_len]);
    if (same_as_fired) return;

    if (q.len >= 2 and now_ms - last_edit_ms >= DEBOUNCE_MS and !state.app.yt.is_loading.load(.acquire)) {
        recordFired(q);
        fetchYoutube(q);
    }
}

// ══════════════════════════════════════════════════════════
// Toolbar (chips, search, count, card-size)
// ══════════════════════════════════════════════════════════

const CatChip = struct { label: []const u8, query: []const u8 };
const cat_chips = [_]CatChip{
    .{ .label = "Trending", .query = "trending 2024" },
    .{ .label = "Music", .query = "music" },
    .{ .label = "Gaming", .query = "gaming" },
    .{ .label = "Tech", .query = "tech" },
    .{ .label = "News", .query = "news" },
};

fn renderToolbar() void {
    var bar = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
    });
    defer bar.deinit();

    dvui.icon(@src(), "yt-icon", icons.tvg.lucide.music, .{}, .{ .color_text = theme.colors.accent, .gravity_y = 0.5, .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 } });

    renderSearchInline();

    // Category preset chips.
    toolbarDivider(901);
    const q = currentQuery();
    for (cat_chips, 0..) |c, ci| {
        renderCatChip(ci, c, q);
    }

    // Item count + card-size controls.
    toolbarDivider(950);
    _ = dvui.label(@src(), "{d} videos", .{state.app.yt.results.items.len}, .{ .color_text = theme.colors.text_secondary, .gravity_y = 0.5 });

    const dim = dvui.Color{ .r = 120, .g = 120, .b = 148, .a = 200 };
    if (dvui.buttonIcon(@src(), "smaller", icons.tvg.lucide.minus, .{}, .{}, .{
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = dim,
        .border = dvui.Rect.all(0),
        .min_size_content = theme.iconSize(.sm),
        .padding = dvui.Rect.all(3),
        .gravity_y = 0.5,
    })) {
        card_w = @max(CARD_MIN, card_w - 40);
    }
    if (dvui.buttonIcon(@src(), "bigger", icons.tvg.lucide.plus, .{}, .{}, .{
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = dim,
        .border = dvui.Rect.all(0),
        .min_size_content = theme.iconSize(.sm),
        .padding = dvui.Rect.all(3),
        .gravity_y = 0.5,
    })) {
        card_w = @min(CARD_MAX, card_w + 40);
    }
}

/// A faint vertical separator between toolbar groups.
fn toolbarDivider(id: usize) void {
    var d = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .min_size_content = .{ .w = 1, .h = 18 },
        .background = true,
        .color_fill = theme.colors.border_subtle,
        .margin = .{ .x = 8, .y = 0, .w = 8, .h = 0 },
        .gravity_y = 0.5,
    });
    d.deinit();
}

/// Compact inline search box. Enter/Go fire immediately; typing is handled by
/// the debounced live search in maybeFireLiveSearch().
fn renderSearchInline() void {
    const components = @import("../ui/components.zig");
    // Canonical compact toolbar input — same height/padding as Movies & TV.
    const enter_pressed = components.toolbarSearch(@src(), &state.app.yt.search_buf, "Search YouTube…", 240);

    if (components.toolbarGo(@src(), "Go") or enter_pressed) {
        const q = currentQuery();
        recordFired(q);
        fetchYoutube(q);
    }
}

fn renderCatChip(idx: usize, chip: CatChip, current: []const u8) void {
    const active = std.mem.eql(u8, current, chip.query);
    if (dvui.button(@src(), chip.label, .{}, .{
        .id_extra = idx + 2000,
        .background = true,
        .color_fill = if (active) theme.colors.accent else theme.colors.bg_surface,
        .color_text = if (active) dvui.Color.white else theme.colors.text_secondary,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
        .margin = .{ .x = 0, .y = 0, .w = 3, .h = 0 },
        .gravity_y = 0.5,
    })) {
        setQuery(chip.query);
        recordFired(chip.query);
        fetchYoutube(chip.query);
    }
}

/// Replace the shared search buffer with `q` (NUL-padded).
fn setQuery(q: []const u8) void {
    const n = @min(q.len, state.app.yt.search_buf.len - 1);
    @memset(&state.app.yt.search_buf, 0);
    @memcpy(state.app.yt.search_buf[0..n], q[0..n]);
}

// ══════════════════════════════════════════════════════════
// Cards
// ══════════════════════════════════════════════════════════

fn renderCard(item: *state.YtItem, idx: usize, the_card_w: f32) void {
    const title = safeUtf8(item.title[0..item.title_len]);
    const thumb_h: f32 = the_card_w * 9.0 / 16.0;

    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = idx,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .corner_radius = dvui.Rect.all(6),
        .min_size_content = .{ .w = the_card_w, .h = 10 },
        .max_size_content = .{ .w = the_card_w, .h = thumb_h + 150 },
        .margin = .{ .x = 3, .y = 3, .w = 3, .h = 3 },
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
    });
    defer card.deinit();

    // Thumbnail (16:9) — a clickable button-widget hosting the image + hover
    // overlay, so the whole poster is one hit-target (quick-play on click).
    {
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{}, .{
            .id_extra = idx + 100,
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_app,
            .corner_radius = .{ .x = theme.radius.md, .y = theme.radius.md, .w = 0, .h = 0 },
            .min_size_content = .{ .w = the_card_w, .h = thumb_h },
            .max_size_content = .{ .w = the_card_w, .h = thumb_h },
            .padding = dvui.Rect.all(0),
        });
        bw.processEvents();
        bw.drawBackground();

        if (item.thumb_tex == null and item.thumb_pixels != null and
            item.thumb_pixels.?.len == @as(usize, item.thumb_w) * @as(usize, item.thumb_h) * 4)
        {
            const num_pixels = item.thumb_w * item.thumb_h;
            const pixels_pma: []dvui.Color.PMA = @as([*]dvui.Color.PMA, @ptrCast(@alignCast(item.thumb_pixels.?.ptr)))[0..num_pixels];
            item.thumb_tex = dvui.textureCreate(pixels_pma, item.thumb_w, item.thumb_h, .linear, .rgba_32) catch null;
            if (item.thumb_tex != null) {
                alloc.free(item.thumb_pixels.?);
                item.thumb_pixels = null;
            }
        }

        // Stack: image (or placeholder) + duration badge + hover overlay.
        {
            var stack = dvui.overlay(@src(), .{ .id_extra = idx + 140, .expand = .both });
            defer stack.deinit();

            if (item.thumb_tex) |*tex| {
                _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
                    .id_extra = idx + 150,
                    .expand = .both,
                    .corner_radius = dvui.Rect.all(4),
                });
            } else {
                // Failure-latch (mirrors TmdbItem/JfItem): stop re-spawning a
                // thumb worker every frame for a dead/undecodable URL.
                if (item.thumb_fetching) {
                    item.thumb_attempted = true;
                } else if (item.thumb_attempted and item.thumb_pixels == null and item.thumb_tex == null) {
                    item.thumb_failed = true;
                } else if (!item.thumb_failed and item.thumb_pixels == null and item.thumbnail_url_len > 0) {
                    fetchThumb(item);
                    if (item.thumb_fetching) item.thumb_attempted = true;
                }
                dvui.icon(@src(), "ph", icons.tvg.lucide.image, .{}, .{
                    .id_extra = idx + 150,
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .color_text = theme.colors.bg_elevated,
                    .expand = .both,
                });
            }

            // Duration badge (bottom-right).
            if (item.duration > 0) {
                var dur_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = idx + 161,
                    .gravity_x = 1.0,
                    .gravity_y = 1.0,
                    .background = true,
                    .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 200 },
                    .corner_radius = dvui.Rect.all(2),
                    .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
                    .margin = dvui.Rect.all(2),
                });
                defer dur_box.deinit();

                const dur_min = @divTrunc(item.duration, 60);
                const dur_sec = @rem(item.duration, 60);
                var dur_buf: [16]u8 = undefined;
                if (std.fmt.bufPrintZ(&dur_buf, "{d}:{d:0>2}", .{ dur_min, dur_sec })) |dur_str| {
                    _ = dvui.labelNoFmt(@src(), dur_str, .{}, .{ .id_extra = idx + 162, .color_text = dvui.Color.white });
                } else |_| {}
            }

            // Hover overlay: dimmed scrim + metadata + centered play affordance.
            if (bw.hovered()) renderHoverMeta(item, idx);
        }

        const clicked = bw.clicked();
        bw.drawFocus();
        bw.deinit();
        if (clicked) sendToPlayer(item, false);
    }

    // Info
    {
        var info = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = idx + 200,
            .expand = .horizontal,
            .padding = .{ .x = 6, .y = 2, .w = 6, .h = 0 },
        });
        defer info.deinit();

        // Title — clamped to two lines (each line auto-ellipsized by dvui),
        // UTF-8 safe. A "\n" split near the width-derived midpoint at a word
        // boundary gives a balanced two-line block; long single words just
        // ellipsize on line one.
        var title_buf: [160]u8 = undefined;
        const title_2l = twoLineTitle(title, the_card_w, &title_buf);
        _ = dvui.labelNoFmt(@src(), title_2l, .{}, .{
            .id_extra = idx + 300,
            .expand = .horizontal,
            .color_text = theme.colors.text_primary,
        });

        // Two-line meta: channel on its own line, then "1.5M views · 3w ago".
        // Splitting them means dvui ellipsizes the CHANNEL (line 1) and trims
        // the date end (line 2) — a view-count digit is never cut.
        {
            var meta = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = idx + 400,
                .expand = .horizontal,
                .padding = .{ .x = 0, .y = 3, .w = 0, .h = 0 },
            });
            defer meta.deinit();

            if (item.uploader_len > 0) {
                var ch_buf: [80]u8 = undefined;
                const ch = truncateUtf8(item.uploader[0..item.uploader_len], 28, &ch_buf);
                _ = dvui.labelNoFmt(@src(), ch, .{}, .{
                    .id_extra = idx + 410,
                    .expand = .horizontal,
                    .color_text = theme.colors.text_secondary,
                });
            }

            const ymd = dateFor(idx);
            var abuf: [16]u8 = undefined;
            const ago = if (ymd.len == 8) formatAgo(ymd, &abuf) else "";
            var mbuf: [64]u8 = undefined;
            const ml = metaLine(item.views, ago, &mbuf);
            if (ml.len > 0) {
                _ = dvui.labelNoFmt(@src(), ml, .{}, .{
                    .id_extra = idx + 430,
                    .expand = .horizontal,
                    .color_text = theme.colors.text_secondary,
                });
            }
        }

        // Actions
        {
            var acts = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = idx + 500, .padding = .{ .x = 0, .y = 6, .w = 0, .h = 0 } });
            defer acts.deinit();

            if (dvui.button(@src(), "  Play  ", .{}, .{ .id_extra = idx + 510, .color_fill = theme.colors.accent, .color_text = dvui.Color.black, .corner_radius = theme.dims.rad_sm, .padding = .{ .x = 16, .y = 4, .w = 16, .h = 4 } })) {
                sendToPlayer(item, false);
            }

            if (dvui.button(@src(), "  Queue  ", .{}, .{ .id_extra = idx + 520, .color_fill = theme.colors.bg_elevated, .color_text = theme.colors.accent, .color_border = theme.colors.accent, .border = dvui.Rect.all(1), .corner_radius = theme.dims.rad_sm, .padding = .{ .x = 16, .y = 4, .w = 16, .h = 4 }, .margin = .{ .x = 8, .y = 0, .w = 0, .h = 0 } })) {
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
                .color_fill = theme.colors.bg_surface,
                .color_border = theme.colors.border_subtle,
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

/// Clamp a title to two lines by inserting a single "\n" near a word boundary.
/// dvui ellipsizes each line independently, so a one-line title that overflows
/// only ever shows ~half; splitting it onto two lines lets far more show before
/// the second line ellipsizes. `card_w` estimates chars-per-line (~7px/char at
/// the default font). UTF-8 safe (input is already safeUtf8'd; we only split on
/// an ASCII space, never inside a codepoint). Writes into `out`.
fn twoLineTitle(title: []const u8, width: f32, out: []u8) []const u8 {
    // Rough glyphs-per-line for this card width (with side padding ~12px).
    const cpl: usize = @max(8, @as(usize, @intFromFloat(@max(0, width - 12) / 7.0)));
    if (title.len <= cpl) return title; // fits on one line, leave it

    // Find the last space at/just before the line-1 budget so line 1 ends on a
    // whole word. Fall back to a hard split if there's no space in range.
    const limit = @min(title.len, cpl);
    var split: usize = 0;
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        if (title[i] == ' ') split = i;
    }
    // If the only space is very early, prefer a hard cut at the budget so line 1
    // isn't nearly empty. Otherwise break on the word boundary.
    if (split < cpl / 2) split = limit;

    // Skip the space we broke on (if we broke on one) so line 2 doesn't start
    // with a leading space.
    const rest_start = if (split < title.len and title[split] == ' ') split + 1 else split;
    const rest = title[rest_start..];
    if (split + 1 + rest.len > out.len) {
        // Won't fit the buffer — just return the (auto-ellipsized) original.
        return title;
    }
    @memcpy(out[0..split], title[0..split]);
    out[split] = '\n';
    @memcpy(out[split + 1 .. split + 1 + rest.len], rest);
    return out[0 .. split + 1 + rest.len];
}

/// Build the "1.5M views · 3w ago" meta line into `out`. Either part may be
/// empty. Views come first so dvui's per-line ellipsize (which trims the END of
/// the line) eats the date before it could ever cut a digit of the count.
fn metaLine(views: i64, ago: []const u8, out: []u8) []const u8 {
    var vbuf: [32]u8 = undefined;
    const vstr = viewsStr(views, &vbuf); // "1.5M views" or ""
    if (vstr.len > 0 and ago.len > 0) return std.fmt.bufPrint(out, "{s}  \u{00b7}  {s}", .{ vstr, ago }) catch vstr;
    if (vstr.len > 0) return std.fmt.bufPrint(out, "{s}", .{vstr}) catch "";
    if (ago.len > 0) return std.fmt.bufPrint(out, "{s}", .{ago}) catch "";
    return "";
}

/// UTF-8-safe truncation to at most `max` codepoints, appending "…" when cut.
/// Writes into `out`; returns the slice. Trims a trailing space before the
/// ellipsis so "Some Channel …" reads "Some Channel…". Keeps view counts on the
/// next line intact — only the channel name is ever shortened.
fn truncateUtf8(s_in: []const u8, max: usize, out: []u8) []const u8 {
    const s = safeUtf8(s_in);
    // Count codepoints; if it already fits, pass through unchanged.
    var cps: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch break;
        if (i + n > s.len) break;
        i += n;
        cps += 1;
    }
    if (cps <= max) return s;

    // Re-walk, copying up to `max` codepoints.
    var bi: usize = 0;
    var taken: usize = 0;
    var oi: usize = 0;
    while (bi < s.len and taken < max) {
        const n = std.unicode.utf8ByteSequenceLength(s[bi]) catch break;
        if (bi + n > s.len or oi + n > out.len) break;
        @memcpy(out[oi .. oi + n], s[bi .. bi + n]);
        oi += n;
        bi += n;
        taken += 1;
    }
    // Drop a trailing space so we don't render "Foo …".
    while (oi > 0 and out[oi - 1] == ' ') oi -= 1;
    const ell = "\u{2026}"; // …
    if (oi + ell.len <= out.len) {
        @memcpy(out[oi .. oi + ell.len], ell);
        oi += ell.len;
    }
    return out[0..oi];
}

/// Compact view-count magnitude, e.g. 337000→"337K", 1491000→"1.5M",
/// 114200000→"114M", 0→"". Drops the trailing ".0" so "2.0M" reads "2M". Never
/// truncates mid-digit — the whole formatted token fits. Writes into `buf`.
fn formatViews(views: i64, buf: []u8) []const u8 {
    if (views <= 0) return "";
    const f = @as(f64, @floatFromInt(views));
    if (views < 1_000) return std.fmt.bufPrint(buf, "{d}", .{views}) catch "";
    if (views < 1_000_000) return scaled(buf, f / 1_000.0, "K");
    if (views < 1_000_000_000) return scaled(buf, f / 1_000_000.0, "M");
    return scaled(buf, f / 1_000_000_000.0, "B");
}

/// Render `v` with one decimal place unless it's ≥100 (then no decimal — "337K"
/// not "337.0K") or the decimal is zero ("2M" not "2.0M"), then the suffix.
fn scaled(buf: []u8, v: f64, suffix: []const u8) []const u8 {
    const tenths = @as(i64, @intFromFloat(@round(v * 10.0)));
    const whole = @divTrunc(tenths, 10);
    const frac = @rem(tenths, 10);
    if (v >= 100.0 or frac == 0) return std.fmt.bufPrint(buf, "{d}{s}", .{ whole, suffix }) catch "";
    return std.fmt.bufPrint(buf, "{d}.{d}{s}", .{ whole, frac, suffix }) catch "";
}

/// "1.5M views" / "" — the formatViews magnitude with the unit appended.
fn viewsStr(views: i64, buf: []u8) []const u8 {
    var nbuf: [16]u8 = undefined;
    const n = formatViews(views, &nbuf);
    if (n.len == 0) return "";
    return std.fmt.bufPrint(buf, "{s} views", .{n}) catch "";
}

/// Dimmed scrim + full metadata + a centered ▶ play affordance, over a hovered
/// thumbnail. Clicking the thumbnail (handled by the parent button) plays.
fn renderHoverMeta(item: *state.YtItem, idx: usize) void {
    var ov = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = idx + 600,
        .expand = .both,
        .background = true,
        .color_fill = dvui.Color{ .r = 8, .g = 10, .b = 16, .a = 224 },
        .corner_radius = .{ .x = theme.radius.md, .y = theme.radius.md, .w = 0, .h = 0 },
        .padding = dvui.Rect.all(8),
    });
    defer ov.deinit();

    // Full title (wraps).
    _ = dvui.label(@src(), "{s}", .{safeUtf8(item.title[0..item.title_len])}, .{
        .id_extra = idx + 601,
        .expand = .horizontal,
        .color_text = theme.colors.text_primary,
        .font = dvui.themeGet().font_heading,
    });

    // Channel.
    if (item.uploader_len > 0) {
        _ = dvui.label(@src(), "{s}", .{safeUtf8(item.uploader[0..item.uploader_len])}, .{
            .id_extra = idx + 602,
            .expand = .horizontal,
            .color_text = theme.colors.text_secondary,
        });
    }

    // Views · date line.
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = idx + 603, .expand = .horizontal, .padding = .{ .x = 0, .y = 2, .w = 0, .h = 0 } });
        defer line.deinit();

        if (item.views > 0) {
            var vbuf: [32]u8 = undefined;
            _ = dvui.label(@src(), "{s}", .{viewsStr(item.views, &vbuf)}, .{ .id_extra = idx + 604, .color_text = theme.colors.text_secondary });
        }
        const ymd = dateFor(idx);
        if (ymd.len == 8) {
            var abuf: [16]u8 = undefined;
            const ago = formatAgo(ymd, &abuf);
            if (ago.len > 0) {
                if (item.views > 0) _ = dvui.label(@src(), "  ·  ", .{}, .{ .id_extra = idx + 605, .color_text = theme.colors.border_subtle });
                _ = dvui.label(@src(), "{s}", .{ago}, .{ .id_extra = idx + 606, .color_text = theme.colors.text_secondary });
            }
        }
    }

    // Duration.
    if (item.duration > 0) {
        const dur_min = @divTrunc(item.duration, 60);
        const dur_sec = @rem(item.duration, 60);
        var dbuf: [16]u8 = undefined;
        if (std.fmt.bufPrintZ(&dbuf, "{d}:{d:0>2}", .{ dur_min, dur_sec })) |ds| {
            _ = dvui.label(@src(), "{s}", .{ds}, .{ .id_extra = idx + 607, .color_text = theme.colors.text_secondary });
        } else |_| {}
    }

    // Centered ▶ play affordance.
    {
        var center = dvui.overlay(@src(), .{ .id_extra = idx + 608, .expand = .both });
        defer center.deinit();
        dvui.icon(@src(), "play", icons.tvg.lucide.play, .{}, .{
            .id_extra = idx + 609,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .color_text = theme.colors.accent,
            .min_size_content = .{ .w = 40, .h = 40 },
        });
    }
}

fn sendToPlayer(item: *state.YtItem, appendToPlaylist: bool) void {
    if (state.app.active_player_idx >= state.app.players.items.len) return;
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
