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
        fetchSectionsSync();
        return;
    }
    conn_state.store(.err, .release);
    setStatus("No Plex server found on this account", .{});
}

// ── libraries + items ────────────────────────────────────────────────────────
pub fn fetchSections() void {
    if (!isConnected()) return;
    (std.Thread.spawn(.{}, fetchSectionsSync, .{}) catch return).detach();
}
fn fetchSectionsSync() void {
    var url: [320]u8 = undefined;
    const u = std.fmt.bufPrint(&url, "{s}/library/sections", .{server_uri[0..server_uri_len]}) catch return;
    var buf: [65536]u8 = undefined;
    const n = httpGet(u, false, serverTok(), &buf);
    if (n == 0) return;
    var parsed = std.json.parseFromSlice(Json, alloc, buf[0..n], .{}) catch return;
    defer parsed.deinit();
    const mc = parsed.value.object.get("MediaContainer") orelse return;
    const dirs = mc.object.get("Directory") orelse return;
    if (dirs != .array) return;
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
        fetchItemsSync(0);
    }
}

pub fn fetchItems(section_idx: usize) void {
    if (!isConnected() or section_idx >= section_count) return;
    active_section = section_idx;
    const S = struct {
        var idx: usize = 0;
        fn run() void {
            fetchItemsSync(idx);
        }
    };
    S.idx = section_idx;
    (std.Thread.spawn(.{}, S.run, .{}) catch return).detach();
}
fn fetchItemsSync(section_idx: usize) void {
    if (section_idx >= section_count) return;
    is_loading.store(true, .release);
    defer is_loading.store(false, .release);
    const sec = &sections[section_idx];
    var url: [400]u8 = undefined;
    const u = std.fmt.bufPrint(&url, "{s}/library/sections/{s}/all", .{ server_uri[0..server_uri_len], sec.key[0..sec.key_len] }) catch return;
    var buf: [524288]u8 = undefined;
    const n = httpGet(u, false, serverTok(), &buf);
    if (n == 0) return;
    var parsed = std.json.parseFromSlice(Json, alloc, buf[0..n], .{}) catch return;
    defer parsed.deinit();
    const mc = parsed.value.object.get("MediaContainer") orelse return;
    const meta = mc.object.get("Metadata") orelse {
        item_count = 0;
        return;
    };
    if (meta != .array) return;
    item_count = 0;
    for (meta.array.items) |m| {
        if (item_count >= items.len or m != .object) continue;
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
}
