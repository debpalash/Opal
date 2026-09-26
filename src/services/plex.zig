//! Plex client — PIN auth (plex.tv/link) → server discovery → library browse →
//! direct-play. Plex's API differs from Jellyfin/Emby: plex.tv auth + X-Plex-Token
//! + server discovery via plex.tv/api/v2/resources. JSON is requested with an
//! Accept header. Auth tokens are persisted in a protected local envelope.

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const theme = @import("../ui/theme.zig");
const components = @import("../ui/components.zig");
const io = @import("../core/io_global.zig");
const alloc = @import("../core/alloc.zig").allocator;
const paths = @import("../core/paths.zig");
const logs = @import("../core/logs.zig");
const state = @import("../core/state.zig");
const plex_pure = @import("plex_pure.zig");
const secret_store = @import("../core/secret_store.zig");

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
    rating_key: [32]u8 = std.mem.zeroes([32]u8),
    rating_key_len: usize = 0,
    title: [160]u8 = std.mem.zeroes([160]u8),
    title_len: usize = 0,
    overview: [768]u8 = std.mem.zeroes([768]u8),
    overview_len: usize = 0,
    year: [8]u8 = std.mem.zeroes([8]u8),
    year_len: usize = 0,
    thumb: [256]u8 = std.mem.zeroes([256]u8),
    thumb_len: usize = 0,
    part: [256]u8 = std.mem.zeroes([256]u8), // /library/parts/.../file.ext
    part_len: usize = 0,
    fallback_part: [256]u8 = std.mem.zeroes([256]u8),
    fallback_part_len: usize = 0,
    view_offset_ms: i64 = 0,
    duration_ms: i64 = 0,
    view_count: i64 = 0,
    user_rating: f32 = 0,
    is_favorite: bool = false,
    watched_gen: u32 = 0,
    rating_gen: u32 = 0,
    media_type: [16]u8 = std.mem.zeroes([16]u8),
    media_type_len: usize = 0,
    is_folder: bool = false,
};

const RATING_LABELS = [_][]const u8{
    "Unrated", "0.5", "1.0", "1.5", "2.0", "2.5", "3.0", "3.5", "4.0", "4.5",  "5.0",
    "5.5",     "6.0", "6.5", "7.0", "7.5", "8.0", "8.5", "9.0", "9.5", "10.0",
};

pub const SearchItem = plex_pure.SearchItem;
pub var items: [300]Item = undefined;
pub var item_count: usize = 0;
pub var is_loading: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
const PLEX_CARD_TARGET_W: f32 = 150;
const PLEX_CARD_GAP: f32 = 4;
const PLEX_CARD_FOOTER_H: f32 = 76;
var item_covers: [300]components.CoverSlot = [_]components.CoverSlot{.{}} ** 300;

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

const MAX_NAV_DEPTH: usize = 8;
var nav_keys: [MAX_NAV_DEPTH][32]u8 = std.mem.zeroes([MAX_NAV_DEPTH][32]u8);
var nav_key_lens: [MAX_NAV_DEPTH]usize = [_]usize{0} ** MAX_NAV_DEPTH;
var nav_titles: [MAX_NAV_DEPTH][160]u8 = std.mem.zeroes([MAX_NAV_DEPTH][160]u8);
var nav_title_lens: [MAX_NAV_DEPTH]usize = [_]usize{0} ** MAX_NAV_DEPTH;
pub var nav_depth: usize = 0;

const BrowseRequest = struct {
    section_idx: usize = 0,
    child_key: [32]u8 = std.mem.zeroes([32]u8),
    child_key_len: usize = 0,

    fn isChild(self: *const BrowseRequest) bool {
        return self.child_key_len > 0;
    }
};

fn currentBrowseRequest() BrowseRequest {
    var request: BrowseRequest = .{ .section_idx = active_section };
    if (nav_depth > 0) {
        request.child_key = nav_keys[nav_depth - 1];
        request.child_key_len = nav_key_lens[nav_depth - 1];
    }
    return request;
}

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
    var protected_token: [512]u8 = undefined;
    defer @memset(&protected_token, 0);
    var protected_server_token: [512]u8 = undefined;
    defer @memset(&protected_server_token, 0);
    const sealed_token = secret_store.seal(token(), &protected_token) orelse return;
    const sealed_server_token = secret_store.seal(serverTok(), &protected_server_token) orelse return;
    var b: [3072]u8 = undefined;
    const body = std.fmt.bufPrint(&b, "{{\"token\":\"{s}\",\"server\":\"{s}\",\"server_token\":\"{s}\",\"name\":\"{s}\"}}", .{ sealed_token, server_uri[0..server_uri_len], sealed_server_token, server_name[0..server_name_len] }) catch return;
    var pb: [600]u8 = undefined;
    @import("../core/secret_file.zig").write(cfgPath(&pb), body) catch {};
}
fn loadSecretStr(obj: Json, key: []const u8, buf: []u8, len: *usize) bool {
    const v = obj.object.get(key) orelse return false;
    if (v != .string or v.string.len == 0) return false;
    const plain = secret_store.reveal(v.string, buf) orelse {
        std.log.warn("could not unlock saved Plex credentials", .{});
        return false;
    };
    len.* = plain.len;
    return !secret_store.isSealed(v.string);
}
fn loadStr(obj: Json, key: []const u8, buf: []u8, len: *usize) void {
    if (obj.object.get(key)) |v| if (v == .string and v.string.len <= buf.len) {
        @memcpy(buf[0..v.string.len], v.string);
        len.* = v.string.len;
    };
}
pub fn init() void {
    var pb: [600]u8 = undefined;
    const path = cfgPath(&pb);
    @import("../core/secret_file.zig").restrictExisting(path);
    const body = io.cwdReadFileAlloc(path, alloc, 8192) catch return;
    defer alloc.free(body);
    var parsed = std.json.parseFromSlice(Json, alloc, body, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const legacy_token = loadSecretStr(parsed.value, "token", &token_buf, &token_len);
    loadStr(parsed.value, "server", &server_uri, &server_uri_len);
    const legacy_server_token = loadSecretStr(parsed.value, "server_token", &server_token, &server_token_len);
    loadStr(parsed.value, "name", &server_name, &server_name_len);
    if (token_len > 0) conn_state.store(.connected, .release);
    if (@import("builtin").os.tag == .windows and (legacy_token or legacy_server_token)) save();
}
pub fn disconnect() void {
    @import("server_progress.zig").clearPlexConnection();
    token_len = 0;
    server_uri_len = 0;
    server_token_len = 0;
    section_count = 0;
    item_count = 0;
    nav_depth = 0;
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

// ── pooled HTTP helper ───────────────────────────────────────────────────────
fn httpGet(url: []const u8, post: bool, tok: []const u8, buf: []u8, status_out: ?*?std.http.Status) usize {
    var tok_hdr: [180]u8 = undefined;
    const th = std.fmt.bufPrint(&tok_hdr, "X-Plex-Token: {s}", .{tok}) catch return 0;
    const client_id = if (state.app.install_id[0] != 0) state.app.install_id[0..] else "opal";
    const extra_headers = [_]std.http.Header{
        .{ .name = "X-Plex-Product", .value = "Opal" },
        .{ .name = "X-Plex-Client-Identifier", .value = client_id },
        .{ .name = "X-Plex-Version", .value = @import("../core/app_meta.zig").version },
    };
    const body = @import("../core/http.zig").fetch(url, buf, .{
        .method = if (post) .POST else .GET,
        .timeout_secs = 15,
        .max_response = buf.len,
        .accept = "application/json",
        .auth_header = if (tok.len > 0) th else null,
        .extra_headers = &extra_headers,
        .status_out = status_out,
    }) orelse return 0;
    return body.len;
}

fn expireAuthSession() void {
    @import("server_progress.zig").clearPlexConnection();
    @memset(&token_buf, 0);
    token_len = 0;
    @memset(&server_token, 0);
    server_token_len = 0;
    section_count = 0;
    item_count = 0;
    current_start = 0;
    more_available = false;
    sections_loaded_once.store(false, .release);
    _ = view_gen.fetchAdd(1, .acq_rel);
    conn_state.store(.disconnected, .release);
    setStatus("Session expired — sign in again", .{});
    save();
    state.wakeUi();
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
    @import("../core/workers.zig").release(@import("../core/workers.zig").spawnLegacy(pinWorker, .{}) catch {
        conn_state.store(.err, .release);
        return;
    });
}

fn pinWorker() void {
    var buf: [16384]u8 = undefined;
    // Plain pin → a short 4-char code usable at plex.tv/link (strong pins are long).
    const n = httpGet("https://plex.tv/api/v2/pins", true, "", &buf, null);
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
        const m = httpGet(purl, false, "", &buf, null);
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
    var status: ?std.http.Status = null;
    const n = httpGet("https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1", false, token(), &buf, &status);
    if (n == 0) {
        if (status) |s| if (plex_pure.authRejected(@intFromEnum(s))) {
            expireAuthSession();
            return;
        };
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
    @import("../core/workers.zig").release(@import("../core/workers.zig").spawnLegacy(fetchSectionsSync, .{}) catch {
        sections_loading.store(false, .release);
        return;
    });
}
fn fetchSectionsSync() void {
    defer sections_loading.store(false, .release);
    var url: [320]u8 = undefined;
    const u = std.fmt.bufPrint(&url, "{s}/library/sections", .{server_uri[0..server_uri_len]}) catch return;
    var buf: [65536]u8 = undefined;
    var status: ?std.http.Status = null;
    const n = httpGet(u, false, serverTok(), &buf, &status);
    if (n == 0) {
        if (status) |s| if (plex_pure.authRejected(@intFromEnum(s))) {
            expireAuthSession();
            return;
        };
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
    nav_depth = 0;
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
    @import("../core/workers.zig").spawn(runBrowseRequest, .{ BrowseRequest{ .section_idx = section_idx }, new_gen }) catch {
        is_loading.store(false, .release); // never strand the tab "loading"
    };
}

fn runBrowseRequest(request: BrowseRequest, gen: u64) void {
    defer is_loading.store(false, .release);
    fetchWindow(request, 0, gen);
}

pub fn openChild(rating_key: []const u8) bool {
    if (!isConnected() or nav_depth >= MAX_NAV_DEPTH or !plex_pure.validRatingKey(rating_key)) return false;
    var title: [160]u8 = undefined;
    var title_len: usize = 0;
    for (items[0..item_count]) |item| {
        if (!item.is_folder or !std.mem.eql(u8, item.rating_key[0..item.rating_key_len], rating_key)) continue;
        title_len = @min(item.title_len, title.len);
        @memcpy(title[0..title_len], item.title[0..title_len]);
        break;
    }
    if (title_len == 0) return false;
    const key_len = @min(rating_key.len, nav_keys[nav_depth].len);
    @memcpy(nav_keys[nav_depth][0..key_len], rating_key[0..key_len]);
    nav_key_lens[nav_depth] = key_len;
    @memcpy(nav_titles[nav_depth][0..title_len], title[0..title_len]);
    nav_title_lens[nav_depth] = title_len;
    nav_depth += 1;
    const gen = view_gen.fetchAdd(1, .acq_rel) + 1;
    beginSectionLoad();
    @import("../core/workers.zig").spawn(runBrowseRequest, .{ currentBrowseRequest(), gen }) catch {
        nav_depth -= 1;
        is_loading.store(false, .release);
        return false;
    };
    return true;
}

pub fn browseBack() bool {
    if (nav_depth == 0) return false;
    nav_depth -= 1;
    const gen = view_gen.fetchAdd(1, .acq_rel) + 1;
    beginSectionLoad();
    @import("../core/workers.zig").spawn(runBrowseRequest, .{ currentBrowseRequest(), gen }) catch {
        nav_depth += 1;
        is_loading.store(false, .release);
        return false;
    };
    return true;
}
/// Initial load driven by the section-list worker. Unlike fetchItems() this
/// already runs off the UI thread, and item_count == 0 makes loadMore() bail, so
/// there's no same-frame append to race with.
fn fetchItemsSync(section_idx: usize, gen: u64) void {
    if (section_idx >= section_count) return;
    beginSectionLoad();
    defer is_loading.store(false, .release);
    fetchWindow(.{ .section_idx = section_idx }, 0, gen);
}

/// Fetch one X-Plex-Container-Start/Size window for `section_idx` and append
/// the parsed rows onto items[] starting at the current item_count. Shared by
/// the initial section load (start=0) and loadMore() (start=current_start).
/// Never clears item_count itself — the caller decides fresh-vs-append.
/// Advances `current_start` by the server-reported row count (not just the
/// rows we managed to store) and clears `more_available` once a window comes
/// back short or the fixed items[] buffer fills.
fn fetchWindow(request: BrowseRequest, start: usize, gen: u64) void {
    if (!request.isChild() and request.section_idx >= section_count) return;
    var url: [460]u8 = undefined;
    const u = if (request.isChild())
        std.fmt.bufPrint(&url, "{s}/library/metadata/{s}/children?X-Plex-Container-Start={d}&X-Plex-Container-Size={d}", .{ server_uri[0..server_uri_len], request.child_key[0..request.child_key_len], start, PLEX_PAGE_SIZE }) catch return
    else blk: {
        const sec = &sections[request.section_idx];
        break :blk std.fmt.bufPrint(&url, "{s}/library/sections/{s}/all?X-Plex-Container-Start={d}&X-Plex-Container-Size={d}", .{ server_uri[0..server_uri_len], sec.key[0..sec.key_len], start, PLEX_PAGE_SIZE }) catch return;
    };
    // Heap buffer — never a big stack buffer on a spawned thread (CLAUDE.md).
    const buf = alloc.alloc(u8, 524288) catch return;
    defer alloc.free(buf);
    var status: ?std.http.Status = null;
    const n = httpGet(u, false, serverTok(), buf, &status);
    if (n == 0) {
        if (status) |s| if (plex_pure.authRejected(@intFromEnum(s))) expireAuthSession();
        return;
    }
    var parsed = std.json.parseFromSlice(Json, alloc, buf[0..n], .{}) catch return;
    defer parsed.deinit();

    // The user may have switched sections — or re-opened THIS one, which resets
    // item_count/current_start — while this window was in flight. Bail before
    // touching ANY shared pagination state (item_count, current_start,
    // more_available all belong to whichever load is currently live; a stale
    // response — even an error/empty one — must not clobber it). The generation
    // is what catches the A→B→A case the index compare passes.
    if (view_gen.load(.acquire) != gen) return;
    if (!request.isChild() and !plex_pure.workerMayPublish(request.section_idx, gen, active_section, view_gen.load(.acquire))) return;

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
        if (jstr(m, "ratingKey")) |rating_key| {
            if (plex_pure.validRatingKey(rating_key)) {
                const rl = @min(rating_key.len, it.rating_key.len);
                @memcpy(it.rating_key[0..rl], rating_key[0..rl]);
                it.rating_key_len = rl;
            }
        } else if (m.object.get("ratingKey")) |rating_value| if (rating_value == .integer and rating_value.integer >= 0) {
            const rendered = std.fmt.bufPrint(&it.rating_key, "{d}", .{rating_value.integer}) catch "";
            it.rating_key_len = rendered.len;
        };
        const tl = @min(title.len, it.title.len);
        @memcpy(it.title[0..tl], title[0..tl]);
        it.title_len = tl;
        if (jstr(m, "summary")) |overview| {
            const ol = @min(overview.len, it.overview.len);
            @memcpy(it.overview[0..ol], overview[0..ol]);
            it.overview_len = ol;
        }
        if (jstr(m, "thumb")) |thumb| {
            const il = @min(thumb.len, it.thumb.len);
            @memcpy(it.thumb[0..il], thumb[0..il]);
            it.thumb_len = il;
        }
        if (m.object.get("year")) |y| if (y == .integer) {
            const ys = std.fmt.bufPrint(&it.year, "{d}", .{y.integer}) catch "";
            it.year_len = ys.len;
        };
        if (m.object.get("viewOffset")) |value| {
            if (value == .integer and value.integer > 0) it.view_offset_ms = value.integer;
        }
        if (m.object.get("duration")) |value| {
            if (value == .integer and value.integer > 0) it.duration_ms = value.integer;
        }
        if (m.object.get("viewCount")) |value| {
            if (value == .integer and value.integer > 0) it.view_count = value.integer;
        }
        if (m.object.get("userRating")) |value| switch (value) {
            .integer => if (value.integer >= 0 and value.integer <= 10) {
                it.user_rating = @floatFromInt(value.integer);
            },
            .float => if (std.math.isFinite(value.float) and value.float >= 0 and value.float <= 10) {
                it.user_rating = @floatCast(value.float);
            },
            else => {},
        };
        if (jstr(m, "type")) |media_type| {
            const ml = @min(media_type.len, it.media_type.len);
            @memcpy(it.media_type[0..ml], media_type[0..ml]);
            it.media_type_len = ml;
            it.is_folder = std.mem.eql(u8, media_type, "show") or std.mem.eql(u8, media_type, "season") or
                std.mem.eql(u8, media_type, "artist") or std.mem.eql(u8, media_type, "album") or
                std.mem.eql(u8, media_type, "photoalbum");
        }
        if (m.object.get("Media")) |media| if (media == .array and media.array.items.len > 0) {
            var versions: [32][]const u8 = undefined;
            var version_count: usize = 0;
            for (media.array.items) |version| {
                if (version_count >= versions.len) break;
                if (version != .object) continue;
                const parts = version.object.get("Part") orelse continue;
                if (parts != .array or parts.array.items.len == 0) continue;
                const pk = jstr(parts.array.items[0], "key") orelse continue;
                versions[version_count] = pk;
                version_count += 1;
            }
            const selected = plex_pure.selectVersionParts(versions[0..version_count]);
            if (selected.primary) |idx| {
                const pk = versions[idx];
                const pl = @min(pk.len, it.part.len);
                @memcpy(it.part[0..pl], pk[0..pl]);
                it.part_len = pl;
            }
            if (selected.fallback) |idx| {
                const pk = versions[idx];
                const pl = @min(pk.len, it.fallback_part.len);
                @memcpy(it.fallback_part[0..pl], pk[0..pl]);
                it.fallback_part_len = pl;
            }
        };
        if (it.rating_key_len > 0) {
            it.is_favorite = @import("library_store.zig").isFavorite("plex", it.rating_key[0..it.rating_key_len]);
        }
        item_count += 1;
    }
    current_start = start + returned;
    if (returned < PLEX_PAGE_SIZE or item_count >= items.len) more_available = false;
}

/// Search the connected Plex server without touching the Plex tab's live
/// section/items buffers. This makes the omnibox a real cross-library search
/// while keeping worker ownership isolated from browse pagination.
pub fn searchInto(query: []const u8, out: []SearchItem) usize {
    if (query.len == 0 or out.len == 0 or !isConnected() or server_uri_len == 0 or serverTok().len == 0) return 0;

    var enc_buf: [768]u8 = undefined;
    const encoded = @import("../core/http.zig").urlEncode(query, &enc_buf);
    var url_buf: [1200]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/search?query={s}&limit={d}", .{
        server_uri[0..server_uri_len], encoded, @min(out.len, 24),
    }) catch return 0;

    const body = alloc.alloc(u8, 512 * 1024) catch return 0;
    defer alloc.free(body);
    var status: ?std.http.Status = null;
    @import("../core/rate_limit.zig").acquire("plex", 5.0);
    const n = httpGet(url, false, serverTok(), body, &status);
    if (n == 0) {
        if (status) |s| if (plex_pure.authRejected(@intFromEnum(s))) expireAuthSession();
        return 0;
    }

    return plex_pure.parseSearchItems(alloc, body[0..n], out) orelse 0;
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

    const request = currentBrowseRequest();
    const start = current_start;
    const gen = view_gen.load(.acquire);
    @import("../core/workers.zig").spawn(runLoadMore, .{ request, start, gen }) catch {
        loading_more.store(false, .release);
    };
}

fn runLoadMore(request: BrowseRequest, start: usize, gen: u64) void {
    defer loading_more.store(false, .release);
    fetchWindow(request, start, gen);
}

pub fn play(idx: usize) void {
    if (idx >= item_count) return;
    playResolvedItem(items[idx]);
}

/// Stable remote action: resolve the server-owned rating key at execution
/// time instead of trusting an array index from an older paginated snapshot.
pub fn playByRatingKey(rating_key: []const u8) bool {
    if (!plex_pure.validRatingKey(rating_key)) return false;
    for (items[0..item_count]) |item| {
        if (!std.mem.eql(u8, item.rating_key[0..item.rating_key_len], rating_key)) continue;
        playResolvedItem(item);
        return true;
    }
    return false;
}

/// Plex Media Server exposes watched and personal-rating mutations but no
/// server-library favorite flag. Keep this preference in Opal's unified
/// library read model under the stable rating key; it then participates in the
/// same Favorites rail as every other adapter.
pub fn setFavorite(rating_key: []const u8, enabled: bool) bool {
    if (!isConnected() or !plex_pure.validRatingKey(rating_key)) return false;
    for (items[0..item_count]) |*item| {
        if (!std.mem.eql(u8, item.rating_key[0..item.rating_key_len], rating_key)) continue;
        if (item.is_folder) return false;
        var deep_buf: [640]u8 = undefined;
        const deep = if (item.part_len > 0)
            (plex_pure.buildDeepLink(rating_key, item.part[0..item.part_len], &deep_buf) orelse "")
        else
            "";
        @import("library_store.zig").setFavorite(
            "plex",
            rating_key,
            enabled,
            item.title[0..item.title_len],
            "",
            deep,
        );
        item.is_favorite = enabled;
        state.wakeUi();
        return true;
    }
    return false;
}

const WatchedMutation = struct {
    rating_key: [32]u8 = std.mem.zeroes([32]u8),
    rating_key_len: usize = 0,
    server: [256]u8 = std.mem.zeroes([256]u8),
    server_len: usize = 0,
    token: [128]u8 = std.mem.zeroes([128]u8),
    token_len: usize = 0,
    enabled: bool,
    previous_count: i64,
    previous_offset_ms: i64,
    generation: u32,
    browse_generation: u64,
};

/// Optimistically update Plex watched state and send the documented PUT on an
/// owned worker. Generation checks prevent an older failure from undoing a
/// newer click or state from a different browse page.
pub fn setWatched(rating_key: []const u8, enabled: bool) bool {
    if (!isConnected() or !plex_pure.validRatingKey(rating_key)) return false;
    var request: WatchedMutation = .{
        .enabled = enabled,
        .previous_count = 0,
        .previous_offset_ms = 0,
        .generation = 0,
        .browse_generation = view_gen.load(.acquire),
    };
    request.server_len = @min(server_uri_len, request.server.len);
    @memcpy(request.server[0..request.server_len], server_uri[0..request.server_len]);
    request.token_len = @min(server_token_len, request.token.len);
    @memcpy(request.token[0..request.token_len], server_token[0..request.token_len]);
    request.rating_key_len = @min(rating_key.len, request.rating_key.len);
    @memcpy(request.rating_key[0..request.rating_key_len], rating_key[0..request.rating_key_len]);

    var found = false;
    for (items[0..item_count]) |*item| {
        if (!std.mem.eql(u8, item.rating_key[0..item.rating_key_len], rating_key)) continue;
        request.previous_count = item.view_count;
        request.previous_offset_ms = item.view_offset_ms;
        item.watched_gen +%= 1;
        request.generation = item.watched_gen;
        item.view_count = if (enabled) 1 else 0;
        if (!enabled) item.view_offset_ms = 0;
        found = true;
        break;
    }
    if (!found) return false;
    @import("../core/workers.zig").spawn(runWatchedMutation, .{request}) catch {
        rollbackWatched(request);
        return false;
    };
    state.wakeUi();
    return true;
}

fn rollbackWatched(request: WatchedMutation) void {
    if (view_gen.load(.acquire) != request.browse_generation) return;
    for (items[0..item_count]) |*item| {
        if (item.watched_gen != request.generation or
            !std.mem.eql(u8, item.rating_key[0..item.rating_key_len], request.rating_key[0..request.rating_key_len])) continue;
        item.view_count = request.previous_count;
        item.view_offset_ms = request.previous_offset_ms;
        state.wakeUi();
        return;
    }
}

fn runWatchedMutation(value: WatchedMutation) void {
    var request = value;
    defer @memset(&request.token, 0);
    var url_buf: [512]u8 = undefined;
    const url = plex_pure.watchedMutationUrl(request.server[0..request.server_len], request.rating_key[0..request.rating_key_len], request.enabled, &url_buf) orelse return rollbackWatched(request);
    var token_header: [160]u8 = undefined;
    defer @memset(&token_header, 0);
    const auth = std.fmt.bufPrint(&token_header, "X-Plex-Token: {s}", .{request.token[0..request.token_len]}) catch return rollbackWatched(request);
    var response: [1024]u8 = undefined;
    var status: ?std.http.Status = null;
    _ = @import("../core/http.zig").fetch(url, &response, .{
        .method = .PUT,
        .timeout_secs = 10,
        .auth_header = auth,
        .status_out = &status,
    }) orelse {
        if (status) |code| if (plex_pure.authRejected(@intFromEnum(code))) expireAuthSession();
        rollbackWatched(request);
        return;
    };
    const code = if (status) |s| @intFromEnum(s) else 0;
    if (code < 200 or code >= 300) rollbackWatched(request);
}

const RatingMutation = struct {
    rating_key: [32]u8 = std.mem.zeroes([32]u8),
    rating_key_len: usize = 0,
    server: [256]u8 = std.mem.zeroes([256]u8),
    server_len: usize = 0,
    token: [128]u8 = std.mem.zeroes([128]u8),
    token_len: usize = 0,
    rating: f32,
    previous: f32,
    generation: u32,
    browse_generation: u64,
};

pub fn setRating(rating_key: []const u8, rating: f32) bool {
    if (!isConnected() or !std.math.isFinite(rating) or rating < 0 or rating > 10 or !plex_pure.validRatingKey(rating_key)) return false;
    var request: RatingMutation = .{
        .rating = rating,
        .previous = 0,
        .generation = 0,
        .browse_generation = view_gen.load(.acquire),
    };
    request.server_len = @min(server_uri_len, request.server.len);
    @memcpy(request.server[0..request.server_len], server_uri[0..request.server_len]);
    request.token_len = @min(server_token_len, request.token.len);
    @memcpy(request.token[0..request.token_len], server_token[0..request.token_len]);
    request.rating_key_len = @min(rating_key.len, request.rating_key.len);
    @memcpy(request.rating_key[0..request.rating_key_len], rating_key[0..request.rating_key_len]);
    var found = false;
    for (items[0..item_count]) |*item| {
        if (!std.mem.eql(u8, item.rating_key[0..item.rating_key_len], rating_key)) continue;
        request.previous = item.user_rating;
        item.rating_gen +%= 1;
        request.generation = item.rating_gen;
        item.user_rating = rating;
        found = true;
        break;
    }
    if (!found) return false;
    @import("../core/workers.zig").spawn(runRatingMutation, .{request}) catch {
        rollbackRating(request);
        return false;
    };
    state.wakeUi();
    return true;
}

fn rollbackRating(request: RatingMutation) void {
    if (view_gen.load(.acquire) != request.browse_generation) return;
    for (items[0..item_count]) |*item| {
        if (item.rating_gen != request.generation or
            !std.mem.eql(u8, item.rating_key[0..item.rating_key_len], request.rating_key[0..request.rating_key_len])) continue;
        item.user_rating = request.previous;
        state.wakeUi();
        return;
    }
}

fn runRatingMutation(value: RatingMutation) void {
    var request = value;
    defer @memset(&request.token, 0);
    var url_buf: [512]u8 = undefined;
    const url = plex_pure.ratingMutationUrl(request.server[0..request.server_len], request.rating_key[0..request.rating_key_len], request.rating, &url_buf) orelse return rollbackRating(request);
    var token_header: [160]u8 = undefined;
    defer @memset(&token_header, 0);
    const auth = std.fmt.bufPrint(&token_header, "X-Plex-Token: {s}", .{request.token[0..request.token_len]}) catch return rollbackRating(request);
    var response: [1024]u8 = undefined;
    var status: ?std.http.Status = null;
    _ = @import("../core/http.zig").fetch(url, &response, .{
        .method = .PUT,
        .timeout_secs = 10,
        .auth_header = auth,
        .status_out = &status,
    }) orelse {
        if (status) |code| if (plex_pure.authRejected(@intFromEnum(code))) expireAuthSession();
        rollbackRating(request);
        return;
    };
    const code = if (status) |s| @intFromEnum(s) else 0;
    if (code < 200 or code >= 300) rollbackRating(request);
}

fn playResolvedItem(it: Item) void {
    if (it.part_len == 0) {
        state.showToastTyped("No playable part", .warning);
        return;
    }
    if (it.rating_key_len > 0) {
        const position = @as(f64, @floatFromInt(it.view_offset_ms)) / 1000.0;
        const duration = @as(f64, @floatFromInt(it.duration_ms)) / 1000.0;
        const resume_at = if (@import("../player/watch_history_pure.zig").resumeEligible(position, duration)) position else null;
        playPartTrackedAt(it.rating_key[0..it.rating_key_len], it.part[0..it.part_len], it.fallback_part[0..it.fallback_part_len], it.title[0..it.title_len], resume_at);
    } else {
        playPart(it.part[0..it.part_len], it.title[0..it.title_len]);
    }
}

/// Reconstruct a Plex stream from a credential-free media-part path.
pub fn playPart(part: []const u8, title: []const u8) void {
    if (!plex_pure.validPartPath(part) or server_uri_len == 0 or serverTok().len == 0) {
        state.showToastTyped("Reconnect Plex to resume", .warning);
        return;
    }
    var url: [600]u8 = undefined;
    const u = std.fmt.bufPrint(&url, "{s}{s}", .{ server_uri[0..server_uri_len], part }) catch return;
    const headers = [_]@import("../player/player.zig").HttpHeader{.{ .name = "X-Plex-Token", .value = serverTok() }};
    var deep_buf: [320]u8 = undefined;
    const deep = std.fmt.bufPrint(&deep_buf, "opal://plex{s}", .{part}) catch return;
    @import("browser.zig").playDirect(.{
        .url = u,
        .history_identity = deep,
        .restore_target = deep,
        .title = title,
        .headers = &headers,
    });
}

pub fn playPartTracked(rating_key: []const u8, part: []const u8, title: []const u8) void {
    playPartTrackedAt(rating_key, part, "", title, null);
}

/// Build a fresh universal-transcoder URL after all direct versions failed.
/// Authentication stays in the already-staged X-Plex-Token player header.
pub fn transcodeRecoveryUrl(identity: []const u8, out: []u8) ?[]const u8 {
    const parsed = plex_pure.parseDeepLink(identity) orelse return null;
    if (server_uri_len == 0 or serverTok().len == 0) return null;
    var random: [16]u8 = undefined;
    if (!io.randomSecure(&random)) return null;
    defer @memset(&random, 0);
    const session = std.fmt.bytesToHex(random, .lower);
    const client_id = if (state.app.install_id[0] != 0) state.app.install_id[0..] else "opal";
    return plex_pure.transcodeUrl(
        server_uri[0..server_uri_len],
        parsed.rating_key,
        &session,
        client_id,
        @import("../core/app_meta.zig").version,
        out,
    );
}

fn playPartTrackedAt(rating_key: []const u8, part: []const u8, fallback_part: []const u8, title: []const u8, resume_position_secs: ?f64) void {
    if (!plex_pure.validRatingKey(rating_key) or !plex_pure.validPartPath(part) or server_uri_len == 0 or serverTok().len == 0) {
        state.showToastTyped("Reconnect Plex to resume", .warning);
        return;
    }
    var url: [600]u8 = undefined;
    const u = std.fmt.bufPrint(&url, "{s}{s}", .{ server_uri[0..server_uri_len], part }) catch return;
    var fallback_buf: [600]u8 = undefined;
    const fallback = if (plex_pure.validPartPath(fallback_part))
        (std.fmt.bufPrint(&fallback_buf, "{s}{s}", .{ server_uri[0..server_uri_len], fallback_part }) catch "")
    else
        "";
    const headers = [_]@import("../player/player.zig").HttpHeader{.{ .name = "X-Plex-Token", .value = serverTok() }};
    var deep_buf: [384]u8 = undefined;
    const deep = plex_pure.buildDeepLink(rating_key, part, &deep_buf) orelse return;
    @import("server_progress.zig").registerPlexConnection(server_uri[0..server_uri_len], serverTok());
    @import("browser.zig").playDirect(.{
        .url = u,
        .fallback_url = fallback,
        .history_identity = deep,
        .restore_target = deep,
        .title = title,
        .resume_position_secs = resume_position_secs,
        .headers = &headers,
    });
}

pub fn resumePlayback(deep_link: []const u8) void {
    if (plex_pure.parseDeepLink(deep_link)) |parsed| {
        playPartTracked(parsed.rating_key, parsed.part, "Plex");
        return;
    }
    const legacy_prefix = "opal://plex";
    if (std.mem.startsWith(u8, deep_link, legacy_prefix))
        playPart(deep_link[legacy_prefix.len..], "Plex");
}

pub fn playSearchItem(deep_link: []const u8, fallback_part: []const u8, title: []const u8, position_secs: f32, duration_secs: f32) void {
    const parsed = plex_pure.parseDeepLink(deep_link) orelse {
        state.showToastTyped("Plex item is no longer available", .warning);
        return;
    };
    const position: f64 = position_secs;
    const duration: f64 = duration_secs;
    const resume_at = if (@import("../player/watch_history_pure.zig").resumeEligible(position, duration)) position else null;
    playPartTrackedAt(parsed.rating_key, parsed.part, fallback_part, title, resume_at);
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
        if (components.iconButtonEx(@src(), icons.tvg.lucide.@"arrow-left", "Back", false, nav_depth > 0)) _ = browseBack();
        _ = dvui.label(@src(), "Plex · {s}", .{server_name[0..server_name_len]}, .{ .color_text = theme.colors.text_primary, .font = dvui.themeGet().font_heading, .gravity_y = 0.5 });
        if (nav_depth > 0) _ = dvui.label(@src(), "  /  {s}", .{nav_titles[nav_depth - 1][0..nav_title_lens[nav_depth - 1]]}, .{
            .color_text = theme.colors.text_secondary,
            .gravity_y = 0.5,
        });
        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }
        if (components.iconButton(@src(), icons.tvg.lucide.@"log-out", "Disconnect Plex", false)) {
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
            if (components.filterChip(@src(), sec.title[0..sec.title_len], icons.tvg.lucide.library, active, i + 90000)) {
                fetchItems(i);
            }
        }
    }

    var sc = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer sc.deinit();

    const rect_w = sc.data().rect.w;
    const avail_w: f32 = @max(240, (if (rect_w > 1) rect_w else 900) - 8);
    const cols: usize = @max(1, @as(usize, @intFromFloat(avail_w / PLEX_CARD_TARGET_W)));
    const cols_f: f32 = @floatFromInt(cols);
    const card_w: f32 = @max(104, (avail_w - cols_f * 2 * PLEX_CARD_GAP) / cols_f);
    const poster_h = card_w * 1.45;
    const row_h = poster_h + PLEX_CARD_FOOTER_H + 2 * PLEX_CARD_GAP;
    if (item_count == 0) {
        if (is_loading.load(.acquire))
            components.coverSkeletonGrid(@src(), 90000, cols, card_w, poster_h, PLEX_CARD_FOOTER_H, 3)
        else
            components.emptyState(@import("icons").tvg.lucide.library, "This library is empty", "Choose another Plex library.");
        return;
    }
    const total_rows = (item_count + cols - 1) / cols;
    const win = @import("tmdb_pure.zig").visibleRows(total_rows, row_h, sc.si.viewport.y, sc.si.viewport.h, 2);

    if (win.first > 0) {
        var sp = dvui.box(@src(), .{}, .{ .id_extra = 90998, .min_size_content = .{ .w = 1, .h = row_h * @as(f32, @floatFromInt(win.first)) } });
        sp.deinit();
    }
    var r: usize = win.first;
    while (r < win.last) : (r += 1) {
        const base = r * cols;
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = base + 91000, .expand = .horizontal });
        defer row.deinit();
        var col: usize = 0;
        while (col < cols and base + col < item_count) : (col += 1)
            renderItemCard(base + col, card_w, poster_h);
    }
    if (win.last < total_rows) {
        var sp = dvui.box(@src(), .{}, .{ .id_extra = 90999, .min_size_content = .{ .w = 1, .h = row_h * @as(f32, @floatFromInt(total_rows - win.last)) } });
        sp.deinit();
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
            state.wakeUi(); // wake until the worker's items land
        }
    }
}

fn activateItem(i: usize) void {
    const it = &items[i];
    if (it.is_folder)
        _ = openChild(it.rating_key[0..it.rating_key_len])
    else
        play(i);
}

fn itemCoverUrl(it: *const Item, out: []u8) []const u8 {
    if (it.thumb_len == 0 or server_uri_len == 0 or server_token_len == 0) return "";
    const thumb = it.thumb[0..it.thumb_len];
    if (std.mem.startsWith(u8, thumb, "http://") or std.mem.startsWith(u8, thumb, "https://"))
        return std.fmt.bufPrint(out, "{s}{s}X-Plex-Token={s}", .{ thumb, if (std.mem.indexOfScalar(u8, thumb, '?') == null) "?" else "&", server_token[0..server_token_len] }) catch "";
    return std.fmt.bufPrint(out, "{s}{s}?X-Plex-Token={s}", .{ server_uri[0..server_uri_len], thumb, server_token[0..server_token_len] }) catch "";
}

fn renderItemCard(i: usize, card_w: f32, poster_h: f32) void {
    const it = &items[i];
    const actionable = it.is_folder or it.part_len > 0;
    var tb: [180]u8 = undefined;
    const title = @import("../core/text.zig").safeUtf8Buf(it.title[0..it.title_len], &tb);
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = i + 92000,
        .min_size_content = .{ .w = card_w, .h = poster_h + PLEX_CARD_FOOTER_H },
        .max_size_content = .{ .w = card_w, .h = poster_h + PLEX_CARD_FOOTER_H },
        .margin = dvui.Rect.all(PLEX_CARD_GAP),
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .color_fill_hover = theme.colors.bg_hover,
        .corner_radius = dvui.Rect.all(theme.radius.md),
    });
    defer card.deinit();

    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{}, .{
        .id_extra = i + 92100,
        .background = true,
        .color_fill = theme.colors.bg_elevated,
        .corner_radius = dvui.Rect.all(theme.radius.md),
        .min_size_content = .{ .w = card_w, .h = poster_h },
        .max_size_content = .{ .w = card_w, .h = poster_h },
        .padding = dvui.Rect.all(0),
    });
    bw.processEvents();
    bw.drawBackground();
    var cover_buf: [1024]u8 = undefined;
    components.coverArt(@src(), i + 92200, &item_covers[i], itemCoverUrl(it, &cover_buf), if (it.is_folder) icons.tvg.lucide.folder else if (actionable) icons.tvg.lucide.play else icons.tvg.lucide.image, theme.radius.md);
    const clicked = bw.clicked();
    bw.drawFocus();
    bw.deinit();
    if (clicked and actionable) activateItem(i);

    _ = dvui.label(@src(), "{s}", .{title}, .{
        .id_extra = i + 92300,
        .color_text = theme.colors.text_primary,
        .font = dvui.themeGet().font_heading.withSize(theme.font_size.small),
        .min_size_content = .{ .w = card_w, .h = 22 },
        .max_size_content = .{ .w = card_w, .h = 22 },
        .padding = .{ .x = 5, .y = 5, .w = 5, .h = 0 },
    });
    var tools = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i + 92400, .expand = .horizontal, .padding = .{ .x = 3, .y = 0, .w = 3, .h = 3 } });
    defer tools.deinit();
    if (actionable and components.iconButton(@src(), if (it.is_folder) icons.tvg.lucide.@"folder-open" else icons.tvg.lucide.play, if (it.is_folder) "Open" else if (it.view_offset_ms > 0 and it.view_count == 0) "Resume" else "Play", true)) activateItem(i);
    if (!it.is_folder and it.rating_key_len > 0) {
        if (components.iconButton(@src(), icons.tvg.lucide.check, if (it.view_count > 0) "Mark unwatched" else "Mark watched", it.view_count > 0))
            _ = setWatched(it.rating_key[0..it.rating_key_len], it.view_count == 0);
        if (components.iconButton(@src(), icons.tvg.lucide.heart, if (it.is_favorite) "Remove favorite" else "Favorite", it.is_favorite))
            _ = setFavorite(it.rating_key[0..it.rating_key_len], !it.is_favorite);
        var rating_choice: usize = @intFromFloat(@round(std.math.clamp(it.user_rating, 0, 10) * 2));
        if (dvui.dropdown(@src(), &RATING_LABELS, .{ .choice = &rating_choice }, .{}, .{
            .id_extra = i + 92500,
            .color_fill = theme.colors.bg_elevated,
            .color_text = if (it.user_rating > 0) theme.colors.warning else theme.colors.text_secondary,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 5, .y = 3, .w = 5, .h = 3 },
            .gravity_y = 0.5,
        })) {
            const selected: f32 = @as(f32, @floatFromInt(rating_choice)) / 2.0;
            if (@abs(selected - it.user_rating) >= 0.01) _ = setRating(it.rating_key[0..it.rating_key_len], selected);
        }
    }
}
