//! Plex client — PIN auth (plex.tv/link) → server discovery → library browse →
//! direct-play. Plex's API differs from Jellyfin/Emby: plex.tv auth + X-Plex-Token
//! + server discovery via plex.tv/api/v2/resources. JSON is requested with an
//! Accept header. The user's auth token is persisted at ~/.config/opal/plex.json.

const std = @import("std");
const dvui = @import("dvui");
const theme = @import("../ui/theme.zig");
const io = @import("../core/io_global.zig");
const alloc = @import("../core/alloc.zig").allocator;
const paths = @import("../core/paths.zig");
const logs = @import("../core/logs.zig");
const state = @import("../core/state.zig");
const plex_pure = @import("plex_pure.zig");

const CLIENT_ID = "opal-media-9a3f"; // X-Plex-Client-Identifier (stable per build)
const Json = std.json.Value;

pub const ConnState = enum(u8) { disconnected, awaiting, connected, err };
pub var conn_state: std.atomic.Value(ConnState) = std.atomic.Value(ConnState).init(.disconnected);
pub var status_msg: [160]u8 = std.mem.zeroes([160]u8);
pub var status_msg_len: usize = 0;
pub var pin_code: [12]u8 = std.mem.zeroes([12]u8);
pub var pin_code_len: usize = 0;

var token_buf: [128]u8 = std.mem.zeroes([128]u8);
var token_len: usize = 0;
var server_uri: [256]u8 = std.mem.zeroes([256]u8);
var server_uri_len: usize = 0;
var server_token: [128]u8 = std.mem.zeroes([128]u8); // per-server access token
var server_token_len: usize = 0;
pub var server_name: [64]u8 = std.mem.zeroes([64]u8);
pub var server_name_len: usize = 0;

const Section = struct {
    key: [16]u8 = std.mem.zeroes([16]u8),
    key_len: usize = 0,
    title: [64]u8 = std.mem.zeroes([64]u8),
    title_len: usize = 0,
};
pub var sections: [32]Section = undefined;
pub var section_count: usize = 0;
pub var active_section: usize = 0;

const Item = struct {
    title: [160]u8 = std.mem.zeroes([160]u8),
    title_len: usize = 0,
    year: [8]u8 = std.mem.zeroes([8]u8),
    year_len: usize = 0,
    part: [256]u8 = std.mem.zeroes([256]u8), // /library/parts/.../file.ext
    part_len: usize = 0,
};
pub var items: [300]Item = undefined;
pub var item_count: usize = 0;
pub var is_loading: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// ── Infinite-scroll pagination ──
// Plex paginates a section's /all listing via X-Plex-Container-Start/Size query
// params. `current_start` is the offset the NEXT window should ask for (equal to
// the server-reported count already merged into items[]); `more_available`
// clears once a window returns fewer than PLEX_PAGE_SIZE rows or the fixed
// buffer fills. `loading_more` serializes append fetches so a single
// near-bottom scroll can't spawn a burst (mirrors services/drama.zig).
// `active_section` (declared above) doubles as "which section is currently
// open" — loadMore's worker captures it before fetching and re-checks it after
// the network round-trip so a mid-fetch tab switch drops the stale window
// instead of corrupting the newly-selected section's list.
const PLEX_PAGE_SIZE: usize = 50;
var current_start: usize = 0;
var more_available: bool = true;
var loading_more: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// A section index alone can't tell "still the same fetch" from "the same section
// was re-opened mid-fetch" (see plex_pure.workerMayPublish). `view_gen` is bumped
// on every section switch/reload; workers capture it before spawning and re-check
// it after the round-trip, so an A→B→A switch can't land a stale page.
var view_gen: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);
// Section-load state for the restored-session trigger in renderContent().
// `sections_loaded_once` latches only once a fetch actually PARSES — an empty
// library is a successful load, so this can't be `section_count > 0` (that would
// poll a zero-library server forever), and it must not be set before the fetch
// or one transient failure would blank the tab for the whole run.
var sections_loading: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var sections_loaded_once: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var sections_last_attempt_s: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);

fn setStatus(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&status_msg, fmt, args) catch status_msg[0..0];
    status_msg_len = s.len;
}
pub fn isConnected() bool {
    return token_len > 0;
}
fn token() []const u8 {
    return token_buf[0..token_len];
}
fn serverTok() []const u8 {
    return if (server_token_len > 0) server_token[0..server_token_len] else token();
}

// ── persistence ──────────────────────────────────────────────────────────────
fn cfgPath(buf: []u8) []const u8 {
    var c: [512]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/plex.json", .{paths.configDir(&c)}) catch "";
}
fn save() void {
    var b: [1024]u8 = undefined;
    const body = std.fmt.bufPrint(&b, "{{\"token\":\"{s}\",\"server\":\"{s}\",\"server_token\":\"{s}\",\"name\":\"{s}\"}}", .{ token(), server_uri[0..server_uri_len], serverTok(), server_name[0..server_name_len] }) catch return;
    var pb: [600]u8 = undefined;
    io.cwdWriteFile(.{ .sub_path = cfgPath(&pb), .data = body }) catch {};
}
fn loadStr(obj: Json, key: []const u8, buf: []u8, len: *usize) void {
    if (obj.object.get(key)) |v| if (v == .string and v.string.len <= buf.len) {
        @memcpy(buf[0..v.string.len], v.string);
        len.* = v.string.len;
    };
}
pub fn init() void {
    var pb: [600]u8 = undefined;
    const body = io.cwdReadFileAlloc(cfgPath(&pb), alloc, 8192) catch return;
    defer alloc.free(body);
    var parsed = std.json.parseFromSlice(Json, alloc, body, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    loadStr(parsed.value, "token", &token_buf, &token_len);
    loadStr(parsed.value, "server", &server_uri, &server_uri_len);
    loadStr(parsed.value, "server_token", &server_token, &server_token_len);
    loadStr(parsed.value, "name", &server_name, &server_name_len);
    if (token_len > 0) conn_state.store(.connected, .release);
}
pub fn disconnect() void {
    token_len = 0;
    server_uri_len = 0;
    server_token_len = 0;
    section_count = 0;
    item_count = 0;
    current_start = 0;
    more_available = true;
    // Clear the load latch too — otherwise signing into a DIFFERENT account
    // would skip the section fetch and land on a permanently blank library.
    sections_loaded_once.store(false, .release);
    sections_last_attempt_s.store(0, .release);
    _ = view_gen.fetchAdd(1, .acq_rel); // supersede any in-flight worker
    conn_state.store(.disconnected, .release);
    save();
}

// ── curl helper ──────────────────────────────────────────────────────────────
fn httpGet(url: []const u8, post: bool, tok: []const u8, buf: []u8) usize {
    var tok_hdr: [180]u8 = undefined;
    const th = std.fmt.bufPrint(&tok_hdr, "X-Plex-Token: {s}", .{tok}) catch return 0;
    var argv_storage = [_][]const u8{
        "curl",                                       "-s",
        "--connect-timeout",                          "3",
        "-H",                                         "Accept: application/json",
        "-H",                                         "X-Plex-Product: Opal",
        "-H",                                         "X-Plex-Client-Identifier: " ++ CLIENT_ID,
        "-H",                                         th,
        "--max-time",                                 "15",
        url,
    };
    var child = if (post) blk: {
        var a2: [argv_storage.len + 2][]const u8 = undefined;
        a2[0] = "curl";
        a2[1] = "-s";
        a2[2] = "-X";
        a2[3] = "POST";
        for (argv_storage[2..], 0..) |x, i| a2[4 + i] = x;
        break :blk io.Child.init(&a2, alloc);
    } else io.Child.init(&argv_storage, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return 0;
    const n = if (child.stdout) |*so| io.readAll(so, buf) catch 0 else 0;
    _ = child.wait() catch {};
    return n;
}

fn jstr(obj: Json, key: []const u8) ?[]const u8 {
    if (obj != .object) return null;
    const v = obj.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

// ── PIN auth flow ────────────────────────────────────────────────────────────
pub fn connect() void {
    if (conn_state.load(.acquire) == .awaiting) return;
    conn_state.store(.awaiting, .release);
    setStatus("Requesting PIN…", .{});
    (std.Thread.spawn(.{}, pinWorker, .{}) catch {
        conn_state.store(.err, .release);
        return;
    }).detach();
}

fn pinWorker() void {
    var buf: [16384]u8 = undefined;
    // Plain pin → a short 4-char code usable at plex.tv/link (strong pins are long).
    const n = httpGet("https://plex.tv/api/v2/pins", true, "", &buf);
    if (n == 0) {
        conn_state.store(.err, .release);
        setStatus("Network error", .{});
        return;
    }
    var parsed = std.json.parseFromSlice(Json, alloc, buf[0..n], .{}) catch {
        conn_state.store(.err, .release);
        setStatus("Bad PIN response", .{});
        return;
    };
    defer parsed.deinit();
    const pin_id: i64 = if (parsed.value.object.get("id")) |v| (if (v == .integer) v.integer else 0) else 0;
    const code = jstr(parsed.value, "code") orelse {
        conn_state.store(.err, .release);
        return;
    };
    const cl = @min(code.len, pin_code.len);
    @memcpy(pin_code[0..cl], code[0..cl]);
    pin_code_len = cl;
    setStatus("Enter {s} at plex.tv/link", .{code});

    var poll_url: [128]u8 = undefined;
    const purl = std.fmt.bufPrint(&poll_url, "https://plex.tv/api/v2/pins/{d}", .{pin_id}) catch return;

    var waited: usize = 0;
    while (waited < 120) : (waited += 3) {
        io.sleep(3 * std.time.ns_per_s);
        const m = httpGet(purl, false, "", &buf);
        if (m == 0) continue;
        var pp = std.json.parseFromSlice(Json, alloc, buf[0..m], .{}) catch continue;
        defer pp.deinit();
        if (jstr(pp.value, "authToken")) |at| {
            const tl = @min(at.len, token_buf.len);
            @memcpy(token_buf[0..tl], at[0..tl]);
            token_len = tl;
            setStatus("Linked — finding servers…", .{});
            discoverServers();
            return;
        }
    }
    conn_state.store(.err, .release);
    setStatus("PIN expired — try again", .{});
}

fn discoverServers() void {
    var buf: [262144]u8 = undefined;
    const n = httpGet("https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1", false, token(), &buf);
    if (n == 0) {
        conn_state.store(.err, .release);
        setStatus("Server lookup failed", .{});
        return;
    }
    var parsed = std.json.parseFromSlice(Json, alloc, buf[0..n], .{}) catch {
        conn_state.store(.err, .release);
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .array) {
        conn_state.store(.err, .release);
        return;
    }
    // First resource that provides "server" with a usable connection.
    for (parsed.value.array.items) |res| {
        if (res != .object) continue;
        const provides = jstr(res, "provides") orelse "";
        if (std.mem.indexOf(u8, provides, "server") == null) continue;
        const conns = res.object.get("connections") orelse continue;
        if (conns != .array) continue;

        // Prefer a non-relay public https connection.
        var chosen: ?[]const u8 = null;
        for (conns.array.items) |c| {
            const uri = jstr(c, "uri") orelse continue;
            const relay = if (c.object.get("relay")) |r| (r == .bool and r.bool) else false;
            if (!relay) {
                chosen = uri;
                break;
            }
            if (chosen == null) chosen = uri;
        }
        const uri = chosen orelse continue;
        const ul = @min(uri.len, server_uri.len);
        @memcpy(server_uri[0..ul], uri[0..ul]);
        server_uri_len = ul;
        if (jstr(res, "accessToken")) |st| {
            const sl = @min(st.len, server_token.len);
            @memcpy(server_token[0..sl], st[0..sl]);
            server_token_len = sl;
        }
        if (jstr(res, "name")) |nm| {
            const nl = @min(nm.len, server_name.len);
            @memcpy(server_name[0..nl], nm[0..nl]);
            server_name_len = nl;
        }
        conn_state.store(.connected, .release);
        setStatus("Connected: {s}", .{server_name[0..server_name_len]});
        save();
        state.showToastTyped("Connected to Plex", .success);
        // Claim the in-flight flag so the renderContent() trigger can't stack a
        // second worker on top of this inline load (and so its defer clears a
        // flag we actually own).
        _ = sections_loading.swap(true, .acq_rel);
        sections_last_attempt_s.store(io.timestamp(), .release);
        fetchSectionsSync();
        return;
    }
    conn_state.store(.err, .release);
    setStatus("No Plex server found on this account", .{});
}

// ── libraries + items ────────────────────────────────────────────────────────
pub fn fetchSections() void {
    if (!isConnected()) return;
    if (sections_loading.swap(true, .acq_rel)) return; // a worker is already in flight
    sections_last_attempt_s.store(io.timestamp(), .release);
    (std.Thread.spawn(.{}, fetchSectionsSync, .{}) catch {
        sections_loading.store(false, .release);
        return;
    }).detach();
}
fn fetchSectionsSync() void {
    defer sections_loading.store(false, .release);
    var url: [320]u8 = undefined;
    const u = std.fmt.bufPrint(&url, "{s}/library/sections", .{server_uri[0..server_uri_len]}) catch return;
    var buf: [65536]u8 = undefined;
    const n = httpGet(u, false, serverTok(), &buf);
    if (n == 0) {
        logs.pushLog("warn", "plex", "Library list failed — retrying shortly", true);
        return;
    }
    var parsed = std.json.parseFromSlice(Json, alloc, buf[0..n], .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const mc = parsed.value.object.get("MediaContainer") orelse return;
    if (mc != .object) return;
    const dirs = mc.object.get("Directory") orelse {
        // A server with no libraries answers without a Directory array. That's a
        // successful (empty) load, not a failure — latch so we stop re-fetching.
        sections_loaded_once.store(true, .release);
        return;
    };
    if (dirs != .array) return;
    // Past parsing — whatever the count, this fetch succeeded.
    sections_loaded_once.store(true, .release);
    section_count = 0;
    for (dirs.array.items) |d| {
        if (section_count >= sections.len or d != .object) continue;
        const key = jstr(d, "key") orelse continue;
        const title = jstr(d, "title") orelse continue;
        var s = &sections[section_count];
        s.* = .{};
        const kl = @min(key.len, s.key.len);
        @memcpy(s.key[0..kl], key[0..kl]);
        s.key_len = kl;
        const tl = @min(title.len, s.title.len);
        @memcpy(s.title[0..tl], title[0..tl]);
        s.title_len = tl;
        section_count += 1;
    }
    if (section_count > 0) {
        active_section = 0;
        fetchItemsSync(0, view_gen.fetchAdd(1, .acq_rel) + 1);
    }
}

/// Reset the grid + pagination for a fresh section load, and claim `is_loading`.
/// Callers MUST do this before the fetch worker spawns, never inside it — see
/// fetchItems().
fn beginSectionLoad() void {
    is_loading.store(true, .release);
    item_count = 0;
    current_start = 0;
    more_available = true;
}

pub fn fetchItems(section_idx: usize) void {
    if (!isConnected() or section_idx >= section_count) return;
    active_section = section_idx;
    // Supersede every in-flight worker: re-opening the SAME section still yields
    // a new generation, which is what an index compare alone can't express.
    const new_gen = view_gen.fetchAdd(1, .acq_rel) + 1;
    // Reset on THIS (UI) thread, before the spawn. Doing it inside the worker
    // leaves a window where renderContent's infinite-scroll block — which runs
    // later in this SAME frame, since the tab click doesn't return — sees the
    // NEW active_section beside the OLD section's current_start, with is_loading
    // still false because the worker hasn't been scheduled yet. loadMore() then
    // appends the new section at the old section's offset (e.g. TV Shows rows
    // 0-49 followed by 100-149, 50 titles silently missing, current_start
    // stranded at 150). The generation guard can't catch that: loadMore reads
    // view_gen after this bump, so its stale append carries the CURRENT gen.
    beginSectionLoad();
    const S = struct {
        var idx: usize = 0;
        var gen: u64 = 0;
        fn run() void {
            defer is_loading.store(false, .release);
            fetchWindow(@This().idx, 0, @This().gen);
        }
    };
    S.idx = section_idx;
    S.gen = new_gen;
    if (std.Thread.spawn(.{}, S.run, .{})) |t| {
        t.detach();
    } else |_| {
        is_loading.store(false, .release); // never strand the tab "loading"
    }
}
/// Initial load driven by the section-list worker. Unlike fetchItems() this
/// already runs off the UI thread, and item_count == 0 makes loadMore() bail, so
/// there's no same-frame append to race with.
fn fetchItemsSync(section_idx: usize, gen: u64) void {
    if (section_idx >= section_count) return;
    beginSectionLoad();
    defer is_loading.store(false, .release);
    fetchWindow(section_idx, 0, gen);
}

/// Fetch one X-Plex-Container-Start/Size window for `section_idx` and append
/// the parsed rows onto items[] starting at the current item_count. Shared by
/// the initial section load (start=0) and loadMore() (start=current_start).
/// Never clears item_count itself — the caller decides fresh-vs-append.
/// Advances `current_start` by the server-reported row count (not just the
/// rows we managed to store) and clears `more_available` once a window comes
/// back short or the fixed items[] buffer fills.
fn fetchWindow(section_idx: usize, start: usize, gen: u64) void {
    if (section_idx >= section_count) return;
    const sec = &sections[section_idx];
    var url: [460]u8 = undefined;
    const u = std.fmt.bufPrint(&url, "{s}/library/sections/{s}/all?X-Plex-Container-Start={d}&X-Plex-Container-Size={d}", .{ server_uri[0..server_uri_len], sec.key[0..sec.key_len], start, PLEX_PAGE_SIZE }) catch return;
    // Heap buffer — never a big stack buffer on a spawned thread (CLAUDE.md).
    const buf = alloc.alloc(u8, 524288) catch return;
    defer alloc.free(buf);
    const n = httpGet(u, false, serverTok(), buf);
    if (n == 0) return;
    var parsed = std.json.parseFromSlice(Json, alloc, buf[0..n], .{}) catch return;
    defer parsed.deinit();

    // The user may have switched sections — or re-opened THIS one, which resets
    // item_count/current_start — while this window was in flight. Bail before
    // touching ANY shared pagination state (item_count, current_start,
    // more_available all belong to whichever load is currently live; a stale
    // response — even an error/empty one — must not clobber it). The generation
    // is what catches the A→B→A case the index compare passes.
    if (!plex_pure.workerMayPublish(section_idx, gen, active_section, view_gen.load(.acquire))) return;

    const mc = parsed.value.object.get("MediaContainer") orelse return;
    const meta = mc.object.get("Metadata") orelse {
        more_available = false;
        return;
    };
    if (meta != .array) {
        more_available = false;
        return;
    }

    const returned = meta.array.items.len;
    for (meta.array.items) |m| {
        if (item_count >= items.len) break;
        if (m != .object) continue;
        const title = jstr(m, "title") orelse continue;
        var it = &items[item_count];
        it.* = .{};
        const tl = @min(title.len, it.title.len);
        @memcpy(it.title[0..tl], title[0..tl]);
        it.title_len = tl;
        if (m.object.get("year")) |y| if (y == .integer) {
            const ys = std.fmt.bufPrint(&it.year, "{d}", .{y.integer}) catch "";
            it.year_len = ys.len;
        };
        // First Media → first Part → key (direct-play file).
        if (m.object.get("Media")) |media| if (media == .array and media.array.items.len > 0) {
            const m0 = media.array.items[0];
            if (m0 == .object) if (m0.object.get("Part")) |parts| if (parts == .array and parts.array.items.len > 0) {
                if (jstr(parts.array.items[0], "key")) |pk| {
                    const pl = @min(pk.len, it.part.len);
                    @memcpy(it.part[0..pl], pk[0..pl]);
                    it.part_len = pl;
                }
            };
        };
        item_count += 1;
    }
    current_start = start + returned;
    if (returned < PLEX_PAGE_SIZE or item_count >= items.len) more_available = false;
}

/// Infinite-scroll appender: fetch the NEXT Container-Start/Size window for the
/// currently-open section and append it onto items[]. Guarded by `loading_more`
/// + the main `is_loading` atomic so a near-bottom scroll can't spawn a burst.
/// No-op once `more_available` clears (short window or the fixed buffer
/// filled). Captures `active_section` before spawning; fetchWindow() re-checks
/// it after the network round-trip so a mid-fetch section switch is dropped
/// rather than corrupting the newly-selected section's list.
pub fn loadMore() void {
    if (!more_available) return;
    if (!isConnected()) return;
    if (is_loading.load(.acquire)) return;
    if (loading_more.load(.acquire)) return;
    if (item_count == 0) return;
    if (item_count >= items.len) {
        more_available = false;
        return;
    }
    if (loading_more.swap(true, .acq_rel)) return; // lost the race — another append in flight

    const S = struct {
        var section_idx: usize = 0;
        var start: usize = 0;
        var gen: u64 = 0;
        fn run() void {
            defer loading_more.store(false, .release);
            fetchWindow(@This().section_idx, @This().start, @This().gen);
        }
    };
    S.section_idx = active_section;
    S.start = current_start;
    // Capture (not bump) — an append belongs to the load that's already live.
    S.gen = view_gen.load(.acquire);
    if (std.Thread.spawn(.{}, S.run, .{})) |t| {
        t.detach();
    } else |_| {
        loading_more.store(false, .release);
    }
}

pub fn play(idx: usize) void {
    if (idx >= item_count) return;
    const it = &items[idx];
    if (it.part_len == 0) {
        state.showToastTyped("No playable part", .warning);
        return;
    }
    var url: [600]u8 = undefined;
    const u = std.fmt.bufPrint(&url, "{s}{s}?X-Plex-Token={s}", .{ server_uri[0..server_uri_len], it.part[0..it.part_len], serverTok() }) catch return;
    @import("browser.zig").loadContent(u);
}

// ── UI ───────────────────────────────────────────────────────────────────────
pub fn renderContent() void {
    var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer page.deinit();

    if (!isConnected()) {
        var panel = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = dvui.Rect.all(16) });
        defer panel.deinit();
        _ = dvui.label(@src(), "Plex", .{}, .{ .color_text = theme.colors.accent });
        _ = dvui.label(@src(), "Sign in with your Plex account.", .{}, .{ .color_text = theme.colors.text_secondary, .padding = .{ .x = 0, .y = 4, .w = 0, .h = 8 } });
        const awaiting = conn_state.load(.acquire) == .awaiting;
        if (dvui.button(@src(), if (awaiting) "Waiting…" else "Connect with Plex", .{}, .{
            .color_fill = theme.colors.accent,
            .color_text = dvui.Color.white,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
        })) {
            connect();
        }
        if (status_msg_len > 0) {
            _ = dvui.label(@src(), "{s}", .{status_msg[0..status_msg_len]}, .{ .color_text = if (conn_state.load(.acquire) == .err) theme.colors.danger else theme.colors.accent, .padding = .{ .x = 0, .y = 10, .w = 0, .h = 0 } });
        }
        return;
    }

    // A restored token (init() → conn_state = .connected) skips the sign-in panel
    // above, but nothing else ever loaded the library: fetchSections() had zero
    // callers, so every relaunch drew this header over an empty tab. Kick the
    // load here, backed off so a failure retries instead of latching blank.
    if (plex_pure.shouldFetchSections(
        isConnected(),
        sections_loaded_once.load(.acquire),
        sections_loading.load(.acquire),
        sections_last_attempt_s.load(.acquire),
        io.timestamp(),
    )) fetchSections();

    // Header: server + section tabs + disconnect.
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 8, .y = 8, .w = 8, .h = 6 }, .background = true, .color_fill = theme.colors.bg_app });
        defer hdr.deinit();
        _ = dvui.label(@src(), "Plex · {s}", .{server_name[0..server_name_len]}, .{ .color_text = theme.colors.accent, .gravity_y = 0.5 });
        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }
        if (dvui.button(@src(), "Disconnect", .{}, .{ .color_fill = theme.colors.bg_elevated, .color_text = theme.colors.text_secondary, .corner_radius = theme.dims.rad_sm, .padding = .{ .x = 8, .y = 5, .w = 8, .h = 5 }, .gravity_y = 0.5 })) {
            disconnect();
            return;
        }
    }
    {
        var tabs = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 } });
        defer tabs.deinit();
        for (0..section_count) |i| {
            const sec = &sections[i];
            const active = i == active_section;
            if (dvui.button(@src(), sec.title[0..sec.title_len], .{}, .{
                .id_extra = i + 90000,
                .color_fill = if (active) theme.colors.accent else theme.colors.bg_elevated,
                .color_text = if (active) dvui.Color.white else theme.colors.text_secondary,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
                .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
            })) {
                fetchItems(i);
            }
        }
    }

    var sc = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer sc.deinit();
    for (0..item_count) |i| {
        const it = &items[i];
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i + 91000, .expand = .horizontal, .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 } });
        defer row.deinit();
        var tb: [180]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{@import("../core/text.zig").safeUtf8Buf(it.title[0..it.title_len], &tb)}, .{ .id_extra = i + 91100, .color_text = theme.colors.text_primary, .gravity_y = 0.5 });
        if (it.year_len > 0) _ = dvui.label(@src(), "  {s}", .{it.year[0..it.year_len]}, .{ .id_extra = i + 91200, .color_text = theme.colors.text_tertiary, .gravity_y = 0.5 });
        {
            var sp = dvui.box(@src(), .{}, .{ .id_extra = i + 91300, .expand = .horizontal });
            sp.deinit();
        }
        if (it.part_len > 0 and dvui.button(@src(), "Play", .{}, .{ .id_extra = i + 91400, .color_fill = theme.colors.accent, .color_text = dvui.Color.white, .corner_radius = theme.dims.rad_sm, .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 }, .gravity_y = 0.5 })) {
            play(i);
        }
    }

    // Infinite scroll: fetch + append the next Container-Start/Size window as
    // the user nears the bottom. Bounded by more_available + loading_more so a
    // single scroll can't spawn a burst; `underfilled` keeps paging when the
    // first window is shorter than the viewport. Mirrors services/drama.zig.
    if (more_available) {
        const loading = loading_more.load(.acquire);
        const max_y = sc.si.scrollMax(.vertical);
        const near_bottom = max_y > 0 and sc.si.viewport.y >= max_y - 800;
        const underfilled = max_y <= 0 and item_count > 0;
        if ((near_bottom or underfilled) and !loading and !is_loading.load(.acquire)) {
            loadMore();
        }
        if (loading or underfilled) {
            dvui.spinner(@src(), .{
                .color_text = theme.colors.accent,
                .min_size_content = theme.iconSize(.lg),
                .gravity_x = 0.5,
                .margin = dvui.Rect.all(12),
            });
            dvui.refresh(null, @src(), null); // wake until the worker's items land
        }
    }
}
