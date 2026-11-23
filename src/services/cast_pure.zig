//! Pure cast helpers shared by every protocol: the device model, media-source
//! classification and URLs for the receiver, plus the AirPlay (pyatv) tool
//! parsing and argv. Chromecast (Cast v2) and DLNA (UPnP AVTransport) are
//! native: their wire formats live in cast_v2_pure.zig and dlna_pure.zig.
//! cast.zig routes through these so the tested logic is the shipped logic.
//!
//! pyatv syntax (verified against pyatv 0.18.0 sources):
//!   atvscript scan                 -> one JSON object:
//!     {"result":"success","devices":[{"name","address","identifier",
//!      "all_identifiers","device_info",{..},"services":[{"protocol","port"}]}]}
//!   atvremote --id <identifier> play_url=<url>
//!     (blocks until playback ends; a local path is served by pyatv itself;
//!      stopping = closing that connection, i.e. ending the process)
//!
//! AirPlay pairing (pyatv 0.18 scripts/atvremote.py, protocols/airplay/pairing.py):
//!   atvremote --id <identifier> --protocol airplay --remote-name Opal pair
//!     scans for the device, starts pair-setup (the TV shows a 4-digit PIN),
//!     writes "Enter PIN on screen: " (no newline) and reads one stdin line.
//!     Then prints "Pairing seems to have succeeded, yey!" (exit 0) or
//!     "Pairing failed!" (exit 0); an exception logs "Pairing failed" plus a
//!     traceback (exit 3); an unknown id logs "Could not find any Apple TV on
//!     current network" (exit 2). atvremote logs to STDOUT.
//!   Credentials: pyatv >= 0.14 saves them in its own settings file
//!     ($HOME/.pyatv.conf, FileStorage.default_storage) on exit, and every
//!     later atvremote/atvscript run loads them for that device, so play_url
//!     needs no --airplay-credentials flag (which would also put the secret
//!     in the process list).
//!   atvscript scan JSON carries only {"protocol","port"} per service — no
//!     pairing requirement — so "needs pairing" is learned from a play_url
//!     failure (`playNeedsPairing`).

const std = @import("std");

const cv2 = @import("cast_v2_pure.zig");
const dlna = @import("dlna_pure.zig");

pub const Protocol = enum { chromecast, airplay, dlna };

pub const max_devices = 16;

pub const CastDevice = struct {
    protocol: Protocol = .chromecast,
    /// AirPlay only: a cast was refused for missing/invalid credentials.
    /// Learned at cast time (scan output has no pairing info); survives a
    /// rescan via `carryNeedsPairing`, cleared by a successful pair.
    needs_pairing: bool = false,
    name: [64]u8 = std.mem.zeroes([64]u8),
    name_len: usize = 0,
    ip: [46]u8 = std.mem.zeroes([46]u8),
    ip_len: usize = 0,
    /// Stable identity: Chromecast mDNS id (else ip:port), pyatv `--id`
    /// identifier, DLNA UDN (else the control URL).
    ident: [96]u8 = std.mem.zeroes([96]u8),
    ident_len: usize = 0,
    /// Chromecast: the Cast v2 TLS port (8009 unless mDNS says otherwise).
    port: u16 = 0,
    /// DLNA: absolute AVTransport control URL.
    control: [512]u8 = std.mem.zeroes([512]u8),
    control_len: usize = 0,

    pub fn nameSlice(self: *const CastDevice) []const u8 {
        return self.name[0..@min(self.name_len, self.name.len)];
    }
    pub fn ipSlice(self: *const CastDevice) []const u8 {
        return self.ip[0..@min(self.ip_len, self.ip.len)];
    }
    pub fn identSlice(self: *const CastDevice) []const u8 {
        return self.ident[0..@min(self.ident_len, self.ident.len)];
    }
    pub fn controlSlice(self: *const CastDevice) []const u8 {
        return self.control[0..@min(self.control_len, self.control.len)];
    }
    /// Same physical target (protocol + tool identifier).
    pub fn sameTarget(self: *const CastDevice, other: *const CastDevice) bool {
        return self.protocol == other.protocol and std.mem.eql(u8, self.identSlice(), other.identSlice());
    }
};

fn setField(buf: []u8, len: *usize, value: []const u8) void {
    const n = @min(value.len, buf.len);
    @memcpy(buf[0..n], value[0..n]);
    len.* = n;
}

pub fn makeDevice(protocol: Protocol, name: []const u8, ip: []const u8, ident: []const u8) CastDevice {
    var d = CastDevice{ .protocol = protocol };
    setField(&d.name, &d.name_len, name);
    setField(&d.ip, &d.ip_len, ip);
    setField(&d.ident, &d.ident_len, ident);
    return d;
}

fn str(v: std.json.Value, key: []const u8) []const u8 {
    if (v != .object) return "";
    const f = v.object.get(key) orelse return "";
    return if (f == .string) f.string else "";
}

fn hasAirPlay(dev: std.json.Value) bool {
    if (dev != .object) return false;
    const services = dev.object.get("services") orelse return false;
    if (services != .array) return false;
    for (services.array.items) |s| {
        if (std.ascii.eqlIgnoreCase(str(s, "protocol"), "airplay")) return true;
    }
    return false;
}

/// Append AirPlay-capable devices from `atvscript scan` JSON to `out[count..]`;
/// returns the new count. Devices without an "airplay" service (pure MRP /
/// Companion / RAOP speakers) are skipped — play_url needs AirPlay video.
pub fn parseAtvscriptScan(gpa: std.mem.Allocator, text: []const u8, out: []CastDevice, count: usize) usize {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return count;
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{}) catch return count;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return count;
    if (!std.mem.eql(u8, str(root, "result"), "success")) return count;
    const devs = root.object.get("devices") orelse return count;
    if (devs != .array) return count;
    var n = count;
    for (devs.array.items) |d| {
        if (n >= out.len) break;
        if (!hasAirPlay(d)) continue;
        const ident = str(d, "identifier");
        if (ident.len == 0 or ident.len > 64) continue;
        const name = str(d, "name");
        out[n] = makeDevice(.airplay, if (name.len > 0) name else "Apple TV", str(d, "address"), ident);
        n += 1;
    }
    return n;
}

pub const atv_scan_argv = [_][]const u8{ "atvscript", "scan" };

/// Fixed-capacity argv whose slices borrow from the device, the URL and
/// `arg_buf` — keep all three alive while the child runs.
pub const Argv = struct {
    items: [8][]const u8 = undefined,
    len: usize = 0,
    pub fn slice(self: *const Argv) []const []const u8 {
        return self.items[0..self.len];
    }
};

fn argvOf(parts: []const []const u8) Argv {
    var a = Argv{};
    for (parts, 0..) |p, i| a.items[i] = p;
    a.len = parts.len;
    return a;
}

/// argv to start casting `url` to an AirPlay `dev` ("play_url=<url>" is one
/// argument, written into `arg_buf`); null when it does not fit or `dev` is
/// not AirPlay (Chromecast and DLNA are native, see cast_net.zig).
pub fn castArgv(dev: *const CastDevice, url: []const u8, arg_buf: []u8) ?Argv {
    if (dev.protocol != .airplay) return null;
    const arg = std.fmt.bufPrint(arg_buf, "play_url={s}", .{url}) catch return null;
    return argvOf(&.{ "atvremote", "--id", dev.identSlice(), arg });
}

/// argv to pair with an AirPlay device (null for Chromecast and DLNA, which
/// need no pairing). "--remote-name" is the name the TV lists the pairing under.
pub fn pairArgv(dev: *const CastDevice) ?Argv {
    return switch (dev.protocol) {
        .chromecast, .dlna => null,
        .airplay => argvOf(&.{ "atvremote", "--id", dev.identSlice(), "--protocol", "airplay", "--remote-name", "Opal", "pair" }),
    };
}

/// Append `chunk` to the tail buffer `buf[0..len]`, keeping only the newest
/// `buf.len` bytes; returns the new length. Lets a reader classify the end of
/// a long-running tool's output without an unbounded buffer.
pub fn appendTail(buf: []u8, len: usize, chunk: []const u8) usize {
    if (buf.len == 0) return 0;
    if (chunk.len >= buf.len) {
        @memcpy(buf, chunk[chunk.len - buf.len ..]);
        return buf.len;
    }
    const cur = @min(len, buf.len);
    const keep_len = @min(cur, buf.len - chunk.len);
    if (keep_len < cur) std.mem.copyForwards(u8, buf[0..keep_len], buf[cur - keep_len .. cur]);
    @memcpy(buf[keep_len .. keep_len + chunk.len], chunk);
    return keep_len + chunk.len;
}

fn has(text: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, text, needle) != null;
}

/// True when atvremote's output shows it is waiting for the TV's PIN.
pub fn pairPromptSeen(output: []const u8) bool {
    return has(output, "Enter PIN");
}

/// The PIN as typed, or null unless it is exactly 4 ASCII digits (surrounding
/// whitespace ignored). AirPlay receivers show 4 digits; anything else would
/// be zero-padded or rejected by pyatv after a wasted pairing attempt.
pub fn validPin(text: []const u8) ?[4]u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len != 4) return null;
    var out: [4]u8 = undefined;
    for (t, 0..) |ch, i| {
        if (!std.ascii.isDigit(ch)) return null;
        out[i] = ch;
    }
    return out;
}

/// Where a pairing session is. idle/paired/failed have no running process.
pub const PairPhase = enum {
    idle,
    /// atvremote is scanning / opening pair-setup.
    starting,
    /// The TV shows a PIN; waiting for /cast/pair/pin.
    awaiting_pin,
    /// PIN sent; atvremote is finishing pair-setup.
    verifying,
    paired,
    failed,

    pub fn active(self: PairPhase) bool {
        return self == .starting or self == .awaiting_pin or self == .verifying;
    }
};

pub const PairOutcome = enum { paired, not_found, backoff, connection_failed, rejected, python_incompatible, failed };

/// Classify a finished `atvremote ... pair` run from its stdout (tail) and
/// exit code (null when it did not exit normally).
pub fn pairOutcome(output: []const u8, exit_code: ?u8) PairOutcome {
    if (exit_code == 0 and has(output, "Pairing seems to have succeeded")) return .paired;
    if (has(output, "Could not find any Apple TV")) return .not_found;
    if (has(output, "BackOffError")) return .backoff;
    if (has(output, "ConnectionFailedError")) return .connection_failed;
    if (has(output, "Pairing failed")) return .rejected;
    if (pyatvEventLoopBroken(output)) return .python_incompatible;
    return .failed;
}

pub fn pairOutcomeMessage(o: PairOutcome) []const u8 {
    return switch (o) {
        .paired => "Paired. Casting to this device now uses the saved credentials.",
        .not_found => "Apple TV not found on the network. Scan again, then retry pairing.",
        .backoff => "The Apple TV is refusing pairing attempts for now. Wait a minute and retry.",
        .connection_failed => "Could not connect to the Apple TV to pair.",
        .rejected => "Pairing failed. Check the PIN shown on the TV and try again.",
        .python_incompatible => msg_pyatv_python,
        .failed => "Pairing failed (atvremote exited with an error). pyatv 0.14 or newer is required.",
    };
}

/// pyatv 0.18.0 (latest, Nov 2026) calls asyncio.get_event_loop() at startup
/// in atvscript and atvremote, which raises on Python 3.14. Every scan, cast
/// and pair then exits with this traceback on stderr and finds nothing.
pub fn pyatvEventLoopBroken(output: []const u8) bool {
    return has(output, "There is no current event loop");
}

pub const msg_pyatv_python = "pyatv cannot run on Python 3.14 yet. Reinstall it on Python 3.13: uv tool install --python 3.13 pyatv";

pub const msg_pair_timeout = "Pairing timed out. Start again and enter the PIN shown on the TV.";
pub const msg_pair_cancelled = "Pairing cancelled";
pub const msg_pair_no_tool = "AirPlay pairing needs pyatv (pip install pyatv)";
pub const msg_pair_busy = "A pairing is already in progress";
pub const msg_pair_not_airplay = "Only AirPlay devices need pairing";
pub const msg_pair_bad_pin = "Enter the 4-digit PIN shown on the TV";
pub const msg_pair_no_prompt = "No pairing is waiting for a PIN";
pub const msg_needs_pairing = "AirPlay refused the cast: this device needs pairing. Press Pair, then enter the PIN shown on the TV.";

/// True when a failed `atvremote ... play_url=` run (stdout + stderr tails)
/// was refused for missing or invalid credentials, which is what an AirPlay 2
/// / tvOS 15+ receiver does before pairing. pyatv maps HTTP 401/403 to
/// AuthenticationError("not authenticated"), HTTP 470 on the control channel
/// to InvalidCredentialsError("invalid or missing credentials"), and absent
/// credentials to NoCredentialsError. A bare "status code: 4xx" from play_url
/// is NOT enough on its own (415 = unsupported media).
pub fn playNeedsPairing(output: []const u8) bool {
    return has(output, "not authenticated") or
        has(output, "NoCredentialsError") or
        has(output, "InvalidCredentialsError") or
        has(output, "invalid or missing credentials") or
        has(output, "status code: 401") or
        has(output, "status code: 403") or
        has(output, "status code: 470");
}

/// Copy `needs_pairing` from the previous device list onto a fresh scan, so a
/// rescan does not forget a device the receiver has already refused.
pub fn carryNeedsPairing(old: []const CastDevice, new: []CastDevice) void {
    for (new) |*n| {
        for (old) |*o| {
            if (o.needs_pairing and n.sameTarget(o)) {
                n.needs_pairing = true;
                break;
            }
        }
    }
}

/// Set `needs_pairing` on every listed device that is `target`.
pub fn markNeedsPairing(list: []CastDevice, target: *const CastDevice, value: bool) void {
    for (list) |*d| {
        if (d.sameTarget(target)) d.needs_pairing = value;
    }
}

/// Host part of a URL ("" when there is no "scheme://").
fn urlHost(url: []const u8) []const u8 {
    const sep = std.mem.indexOf(u8, url, "://") orelse return "";
    var rest = url[sep + 3 ..];
    if (std.mem.indexOfAny(u8, rest, "/?#")) |e| rest = rest[0..e];
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| rest = rest[at + 1 ..];
    if (rest.len > 0 and rest[0] == '[') {
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return rest;
        return rest[1..close];
    }
    if (std.mem.indexOfScalar(u8, rest, ':')) |col| rest = rest[0..col];
    return rest;
}

/// True for URLs only this machine can open (localhost / 127.x / ::1 / 0.0.0.0)
/// — a Chromecast or Apple TV fetching them would hit itself.
pub fn isLoopbackUrl(url: []const u8) bool {
    const host = urlHost(url);
    if (host.len == 0) return false;
    return std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.startsWith(u8, host, "127.") or
        std.mem.eql(u8, host, "::1") or
        std.mem.eql(u8, host, "0.0.0.0");
}

pub const msg_no_media = "No video loaded to cast";
pub const msg_loopback = "Can't cast a localhost stream: the receiver can't reach this machine's loopback address. Cast a local file or a network URL instead.";
pub const msg_unsupported = "This source can't be cast: only local files and http(s) streams can be sent to a TV";
pub const msg_no_device = "Unknown cast device. Scan again.";
pub const msg_url_too_long = "URL too long to cast";
pub const msg_no_session = "Nothing is being cast";
pub const msg_no_lan = "No network address the receiver can reach; is this machine on the same network as the TV?";
pub const msg_control_unsupported = "AirPlay casts can only be stopped from here";

pub const SourceKind = enum { local_file, network, refused };

pub const Source = struct {
    kind: SourceKind,
    /// local_file: absolute path; network: the URL; refused: the reason.
    text: []const u8,
};

/// How the receiver gets `url`: a local file is served to it through a
/// signed stream session; an http(s) URL on the network it fetches itself.
/// Loopback URLs and non-http schemes (magnet:, ytdl:, ...) are refused.
pub fn classifySource(url: []const u8) Source {
    if (url.len == 0) return .{ .kind = .refused, .text = msg_no_media };
    if (std.mem.startsWith(u8, url, "file://")) {
        const path = url["file://".len..];
        if (path.len > 0 and path[0] == '/') return .{ .kind = .local_file, .text = path };
        return .{ .kind = .refused, .text = msg_unsupported };
    }
    if (url[0] == '/') return .{ .kind = .local_file, .text = url };
    if (std.ascii.startsWithIgnoreCase(url, "http://") or std.ascii.startsWithIgnoreCase(url, "https://")) {
        if (isLoopbackUrl(url)) return .{ .kind = .refused, .text = msg_loopback };
        return .{ .kind = .network, .text = url };
    }
    return .{ .kind = .refused, .text = msg_unsupported };
}

/// Why `url` cannot be cast, or null when it can.
pub fn castRefusal(url: []const u8) ?[]const u8 {
    const s = classifySource(url);
    return if (s.kind == .refused) s.text else null;
}

/// MIME type a receiver expects for `name` (a path or URL; query ignored).
pub fn contentTypeFor(name: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, name, "?#") orelse name.len;
    const base = name[0..end];
    const slash = std.mem.lastIndexOfScalar(u8, base, '/') orelse 0;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "video/mp4";
    if (dot < slash) return "video/mp4";
    const ext = base[dot + 1 ..];
    const table = [_]struct { []const u8, []const u8 }{
        .{ "m3u8", "application/x-mpegURL" }, .{ "mpd", "application/dash+xml" },
        .{ "mp4", "video/mp4" },              .{ "m4v", "video/mp4" },
        .{ "mov", "video/quicktime" },        .{ "mkv", "video/x-matroska" },
        .{ "webm", "video/webm" },            .{ "avi", "video/x-msvideo" },
        .{ "ts", "video/mp2t" },              .{ "mp3", "audio/mpeg" },
        .{ "m4a", "audio/mp4" },              .{ "aac", "audio/aac" },
        .{ "flac", "audio/flac" },            .{ "ogg", "audio/ogg" },
        .{ "opus", "audio/ogg" },             .{ "wav", "audio/wav" },
    };
    for (table) |e| if (std.ascii.eqlIgnoreCase(ext, e[0])) return e[1];
    return "video/mp4";
}

/// What a Chromecast's Default Media Receiver decodes, in stream_pure caps
/// words: a stream session remuxes / transcodes anything else to fMP4 HLS.
pub const chromecast_caps = "h264,aac,mp3,opus,mp4,webm,hls";

/// URL the receiver fetches a stream-session entry from. The token in the
/// path authorizes exactly this session (stream_session.handlePublic).
pub fn streamUrl(buf: []u8, host: []const u8, port: u16, sid: []const u8, token: []const u8, entry: []const u8) ?[]const u8 {
    if (host.len == 0 or sid.len == 0 or token.len == 0) return null;
    return std.fmt.bufPrint(buf, "http://{s}:{d}/api/stream/{s}/{s}/{s}", .{ host, port, sid, token, entry }) catch null;
}

/// True for a request path the cast media listener may serve: only signed
/// stream-session paths, `/api/stream/<sid>/<token>/<name>`.
pub fn castServePath(path: []const u8) bool {
    const prefix = "/api/stream/";
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    var it = std.mem.splitScalar(u8, path[prefix.len..], '/');
    var parts: usize = 0;
    while (it.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, "..") or std.mem.eql(u8, p, ".")) return false;
        parts += 1;
    }
    return parts == 3;
}

pub const Control = enum {
    play,
    pause,
    toggle,
    stop,
    seek,
    forward,
    back,

    pub fn parse(s: []const u8) ?Control {
        return std.meta.stringToEnum(Control, s);
    }
};

pub const skip_secs: f64 = 30;

/// Absolute seek target for a seek-type control, clamped to [0, duration]
/// (duration 0 = unknown, no upper clamp). Null for non-seek controls or a
/// seek without a finite position.
pub fn seekTarget(c: Control, pos: ?f64, current: f64, duration: f64) ?f64 {
    const raw: f64 = switch (c) {
        .seek => blk: {
            const p = pos orelse return null;
            if (!std.math.isFinite(p)) return null;
            break :blk p;
        },
        .forward => current + skip_secs,
        .back => current - skip_secs,
        else => return null,
    };
    var t = @max(raw, 0);
    if (duration > 0) t = @min(t, duration);
    return t;
}

pub fn fromChromecast(f: *const cv2.Found) CastDevice {
    var ident_buf: [96]u8 = undefined;
    const ident = if (f.id.len > 0) f.id.slice() else (std.fmt.bufPrint(&ident_buf, "{s}:{d}", .{ f.ipSlice(), f.port }) catch f.ipSlice());
    var d = makeDevice(.chromecast, if (f.name.len > 0) f.name.slice() else "Chromecast", f.ipSlice(), ident);
    d.port = f.port;
    return d;
}

pub fn fromRenderer(r: *const dlna.Renderer) CastDevice {
    const ident = if (r.udn_len > 0) r.udnSlice() else r.controlSlice();
    var d = makeDevice(.dlna, r.nameSlice(), urlHost(r.controlSlice()), ident);
    setField(&d.control, &d.control_len, r.controlSlice());
    return d;
}

/// Hosts the cast-probe test tool may talk to: loopback only, so a test can
/// never reach a real TV, speaker or Chromecast.
pub fn isLoopbackHost(host: []const u8) bool {
    return std.mem.startsWith(u8, host, "127.") or std.ascii.eqlIgnoreCase(host, "localhost");
}

/// "chromecast" / "airplay" / "dlna" for JSON.
pub fn protocolName(p: Protocol) []const u8 {
    return @tagName(p);
}

// ── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "atvscript scan: keeps AirPlay devices, skips speakers without airplay" {
    var out: [max_devices]CastDevice = undefined;
    const text =
        \\{"result": "success", "datetime": "2026-01-01T00:00:00+00:00", "devices": [
        \\ {"name": "Vardagsrum", "address": "10.0.10.81", "identifier": "6D797FD3-3538-427E-A47B-A32FC6CF3A69",
        \\  "all_identifiers": ["6D797FD3-3538-427E-A47B-A32FC6CF3A69", "AA:BB:CC:DD:EE:FF"],
        \\  "device_info": {"mac": "AA:BB:CC:DD:EE:FF", "model": "Gen4K", "model_str": "Apple TV 4K", "operating_system": "TvOS", "version": "17.0"},
        \\  "services": [{"protocol": "mrp", "port": 49152}, {"protocol": "airplay", "port": 7000}]},
        \\ {"name": "HomePod", "address": "10.0.10.90", "identifier": "HP1",
        \\  "services": [{"protocol": "raop", "port": 7000}, {"protocol": "companion", "port": 49153}]}
        \\]}
    ;
    const n = parseAtvscriptScan(testing.allocator, text, &out, 0);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(Protocol.airplay, out[0].protocol);
    try testing.expectEqualStrings("Vardagsrum", out[0].nameSlice());
    try testing.expectEqualStrings("10.0.10.81", out[0].ipSlice());
    try testing.expectEqualStrings("6D797FD3-3538-427E-A47B-A32FC6CF3A69", out[0].identSlice());
}

test "atvscript scan: failure result, bad JSON and empty input add nothing" {
    var out: [max_devices]CastDevice = undefined;
    try testing.expectEqual(@as(usize, 0), parseAtvscriptScan(testing.allocator, "{\"result\":\"failure\",\"error\":\"x\"}", &out, 0));
    try testing.expectEqual(@as(usize, 3), parseAtvscriptScan(testing.allocator, "not json", &out, 3));
    try testing.expectEqual(@as(usize, 0), parseAtvscriptScan(testing.allocator, "\n", &out, 0));
    try testing.expectEqual(@as(usize, 0), parseAtvscriptScan(testing.allocator, "{\"result\":\"success\",\"devices\":[{\"name\":\"n\",\"identifier\":\"\",\"services\":[{\"protocol\":\"airplay\",\"port\":7000}]}]}", &out, 0));
}

test "castArgv: atvremote by identifier with play_url=; native protocols have none" {
    var buf: [256]u8 = undefined;
    const ap = makeDevice(.airplay, "ATV", "10.0.0.2", "AA:BB");
    const b = castArgv(&ap, "/Users/me/Movies/a b.mkv", &buf).?;
    const want_ap = [_][]const u8{ "atvremote", "--id", "AA:BB", "play_url=/Users/me/Movies/a b.mkv" };
    try testing.expectEqual(want_ap.len, b.slice().len);
    for (want_ap, b.slice()) |w, g| try testing.expectEqualStrings(w, g);

    var tiny: [8]u8 = undefined;
    try testing.expect(castArgv(&ap, "https://x.test/v.mp4", &tiny) == null);
    const cc = makeDevice(.chromecast, "TV", "192.168.1.20", "192.168.1.20");
    try testing.expect(castArgv(&cc, "https://x.test/v.mp4", &buf) == null);
    const dl = makeDevice(.dlna, "TV", "192.168.1.21", "uuid:1");
    try testing.expect(castArgv(&dl, "https://x.test/v.mp4", &buf) == null);
}

test "castRefusal: loopback URLs refused, LAN/internet URLs and local paths allowed" {
    try testing.expectEqualStrings(msg_no_media, castRefusal("").?);
    try testing.expectEqualStrings(msg_loopback, castRefusal("http://127.0.0.1:8080/stream").?);
    try testing.expect(castRefusal("http://localhost/x") != null);
    try testing.expect(castRefusal("http://LOCALHOST:9/x") != null);
    try testing.expect(castRefusal("http://[::1]:41595/stream") != null);
    try testing.expect(castRefusal("http://user:pw@127.0.0.2/x") != null);
    try testing.expect(castRefusal("http://0.0.0.0:1/x") != null);
    try testing.expect(castRefusal("http://192.168.1.4:41595/x") == null);
    try testing.expect(castRefusal("https://example.com/127.0.0.1.mp4") == null);
    try testing.expect(castRefusal("/Users/me/Movies/a.mkv") == null);
    try testing.expectEqualStrings(msg_unsupported, castRefusal("magnet:?xt=urn:btih:abc").?);
    try testing.expectEqualStrings(msg_unsupported, castRefusal("file://relative").?);
}

test "classifySource: local files are served, network URLs pass through" {
    const a = classifySource("file:///Users/me/a.mkv");
    try testing.expectEqual(SourceKind.local_file, a.kind);
    try testing.expectEqualStrings("/Users/me/a.mkv", a.text);
    try testing.expectEqual(SourceKind.local_file, classifySource("/srv/x.mp4").kind);
    const n = classifySource("HTTPS://cdn.example/v.m3u8");
    try testing.expectEqual(SourceKind.network, n.kind);
    try testing.expectEqualStrings("HTTPS://cdn.example/v.m3u8", n.text);
    try testing.expectEqual(SourceKind.refused, classifySource("http://127.0.0.1:41595/stream").kind);
}

test "contentTypeFor by extension, query ignored" {
    try testing.expectEqualStrings("application/x-mpegURL", contentTypeFor("http://h/api/stream/s/t/index.m3u8"));
    try testing.expectEqualStrings("video/x-matroska", contentTypeFor("/a/B.MKV"));
    try testing.expectEqualStrings("audio/mpeg", contentTypeFor("https://h/song.mp3?sig=1.mp4"));
    try testing.expectEqualStrings("video/mp4", contentTypeFor("http://h/direct"));
    try testing.expectEqualStrings("video/mp4", contentTypeFor("http://h.example/direct"));
}

test "streamUrl and castServePath agree on the signed path" {
    var buf: [256]u8 = undefined;
    const u = streamUrl(&buf, "192.168.1.5", 50123, "abcd", "tok.sig", "index.m3u8").?;
    try testing.expectEqualStrings("http://192.168.1.5:50123/api/stream/abcd/tok.sig/index.m3u8", u);
    try testing.expect(castServePath(u["http://192.168.1.5:50123".len..]));
    try testing.expect(streamUrl(&buf, "", 1, "a", "b", "c") == null);
    try testing.expect(!castServePath("/api/stream/abcd/index.m3u8")); // no token
    try testing.expect(!castServePath("/api/stream/abcd/../x/y"));
    try testing.expect(!castServePath("/api/status"));
    try testing.expect(!castServePath("/api/stream/a//b"));
}

test "Control.parse and seekTarget clamps" {
    try testing.expectEqual(Control.pause, Control.parse("pause").?);
    try testing.expect(Control.parse("rm -rf") == null);
    try testing.expectEqual(@as(?f64, 754), seekTarget(.seek, 754, 0, 0));
    try testing.expectEqual(@as(?f64, 100), seekTarget(.seek, 754, 0, 100));
    try testing.expectEqual(@as(?f64, 40), seekTarget(.forward, null, 10, 0));
    try testing.expectEqual(@as(?f64, 0), seekTarget(.back, null, 10, 0));
    try testing.expect(seekTarget(.seek, null, 10, 0) == null);
    try testing.expect(seekTarget(.seek, std.math.inf(f64), 10, 0) == null);
    try testing.expect(seekTarget(.pause, 5, 10, 0) == null);
}

test "fromChromecast / fromRenderer build native devices" {
    var f = cv2.Found{ .port = 8009 };
    f.name.set("Living Room");
    f.id.set("abc123");
    @memcpy(f.ip[0..11], "192.168.1.9");
    f.ip_len = 11;
    const d = fromChromecast(&f);
    try testing.expectEqual(Protocol.chromecast, d.protocol);
    try testing.expectEqualStrings("abc123", d.identSlice());
    try testing.expectEqual(@as(u16, 8009), d.port);
    const r = dlna.parseDescription("<root><device><friendlyName>TV</friendlyName><UDN>uuid:9</UDN><serviceList><service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/avt</controlURL></service></serviceList></device></root>", "http://192.168.1.30:7676/d.xml").?;
    const t = fromRenderer(&r);
    try testing.expectEqual(Protocol.dlna, t.protocol);
    try testing.expectEqualStrings("192.168.1.30", t.ipSlice());
    try testing.expectEqualStrings("http://192.168.1.30:7676/avt", t.controlSlice());
    try testing.expectEqualStrings("uuid:9", t.identSlice());
}

test "isLoopbackHost guards the probe tool" {
    try testing.expect(isLoopbackHost("127.0.0.1"));
    try testing.expect(isLoopbackHost("localhost"));
    try testing.expect(!isLoopbackHost("192.168.1.20"));
    try testing.expect(!isLoopbackHost("224.0.0.251"));
}


test "sameTarget compares protocol and identifier" {
    const a = makeDevice(.chromecast, "A", "1.2.3.4", "1.2.3.4");
    const b = makeDevice(.chromecast, "renamed", "1.2.3.4", "1.2.3.4");
    const c = makeDevice(.airplay, "A", "1.2.3.4", "1.2.3.4");
    try testing.expect(a.sameTarget(&b));
    try testing.expect(!a.sameTarget(&c));
}

test "pairArgv: atvremote pair over the airplay protocol, none for Chromecast" {
    const ap = makeDevice(.airplay, "ATV", "10.0.0.2", "6D797FD3-3538");
    const a = pairArgv(&ap).?;
    const want = [_][]const u8{ "atvremote", "--id", "6D797FD3-3538", "--protocol", "airplay", "--remote-name", "Opal", "pair" };
    try testing.expectEqual(want.len, a.slice().len);
    for (want, a.slice()) |w, g| try testing.expectEqualStrings(w, g);
    const cc = makeDevice(.chromecast, "TV", "1.2.3.4", "1.2.3.4");
    try testing.expect(pairArgv(&cc) == null);
}

test "appendTail keeps the newest bytes" {
    var buf: [8]u8 = undefined;
    var n = appendTail(&buf, 0, "abc");
    try testing.expectEqualStrings("abc", buf[0..n]);
    n = appendTail(&buf, n, "defgh");
    try testing.expectEqualStrings("abcdefgh", buf[0..n]);
    n = appendTail(&buf, n, "XY");
    try testing.expectEqualStrings("cdefghXY", buf[0..n]);
    n = appendTail(&buf, n, "0123456789");
    try testing.expectEqualStrings("23456789", buf[0..n]);
    var empty: [0]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), appendTail(&empty, 0, "x"));
}

test "pairPromptSeen matches atvremote's PIN prompt only" {
    try testing.expect(pairPromptSeen("Enter PIN on screen: "));
    try testing.expect(!pairPromptSeen("2026-01-01 ERROR [pyatv.scripts.atvremote]: Could not find any Apple TV on current network\n"));
    try testing.expect(!pairPromptSeen(""));
}

test "validPin: exactly four digits" {
    try testing.expectEqualStrings("0427", &validPin("0427").?);
    try testing.expectEqualStrings("1234", &validPin(" 1234\n").?);
    for ([_][]const u8{ "", "123", "12345", "12a4", "-123", "12 4" }) |bad| try testing.expect(validPin(bad) == null);
}

test "pairOutcome: atvremote 0.18 success, failure and not-found output" {
    try testing.expectEqual(PairOutcome.paired, pairOutcome("Enter PIN on screen: Pairing seems to have succeeded, yey!\nYou may now use these credentials: abc:def\n", 0));
    // has_paired == false still exits 0.
    try testing.expectEqual(PairOutcome.rejected, pairOutcome("Enter PIN on screen: Pairing failed!\n", 0));
    try testing.expectEqual(PairOutcome.rejected, pairOutcome("Enter PIN on screen: 2026-01-01 ERROR [pyatv.scripts.atvremote]: Pairing failed\nTraceback ...\npyatv.exceptions.PairingError: x\n", 3));
    try testing.expectEqual(PairOutcome.backoff, pairOutcome("ERROR [x]: Pairing failed\npyatv.exceptions.BackOffError: wait\n", 3));
    try testing.expectEqual(PairOutcome.connection_failed, pairOutcome("ERROR [x]: Pairing failed\npyatv.exceptions.ConnectionFailedError: [Errno 61]\n", 3));
    try testing.expectEqual(PairOutcome.not_found, pairOutcome("2026-01-01 ERROR [pyatv.scripts.atvremote]: Could not find any Apple TV on current network\n", 2));
    // Success text without a clean exit is not trusted.
    try testing.expectEqual(PairOutcome.failed, pairOutcome("Pairing seems to have succeeded, yey!\n", null));
    try testing.expectEqual(PairOutcome.failed, pairOutcome("", 1));
}

test "PairPhase.active covers only phases with a running process" {
    try testing.expect(PairPhase.starting.active());
    try testing.expect(PairPhase.awaiting_pin.active());
    try testing.expect(PairPhase.verifying.active());
    try testing.expect(!PairPhase.idle.active());
    try testing.expect(!PairPhase.paired.active());
    try testing.expect(!PairPhase.failed.active());
}

test "playNeedsPairing: credential refusals yes, other play_url errors no" {
    try testing.expect(playNeedsPairing("2026-01-01 ERROR [pyatv.scripts.atvremote]: Authentication error: not authenticated\n"));
    try testing.expect(playNeedsPairing("ERROR [x]: Authentication error: status code: 403\n"));
    try testing.expect(playNeedsPairing("pyatv.exceptions.InvalidCredentialsError: invalid or missing credentials\n"));
    try testing.expect(playNeedsPairing("pyatv.exceptions.NoCredentialsError: no credentials\n"));
    // 415 from play_url is unsupported media, not pairing.
    try testing.expect(!playNeedsPairing("ERROR [x]: Authentication error: status code: 415\n"));
    try testing.expect(!playNeedsPairing("pyatv.exceptions.ConnectionFailedError: [Errno 64] Host is down\n"));
    try testing.expect(!playNeedsPairing(""));
}

test "carryNeedsPairing survives a rescan; markNeedsPairing sets and clears by target" {
    var old = [_]CastDevice{ makeDevice(.airplay, "ATV", "10.0.0.2", "ID1"), makeDevice(.chromecast, "CC", "10.0.0.3", "10.0.0.3") };
    old[0].needs_pairing = true;
    var new = [_]CastDevice{ makeDevice(.chromecast, "CC", "10.0.0.3", "10.0.0.3"), makeDevice(.airplay, "ATV renamed", "10.0.0.9", "ID1"), makeDevice(.airplay, "Other", "10.0.0.4", "ID2") };
    carryNeedsPairing(&old, &new);
    try testing.expect(!new[0].needs_pairing);
    try testing.expect(new[1].needs_pairing);
    try testing.expect(!new[2].needs_pairing);
    markNeedsPairing(&new, &new[2], true);
    try testing.expect(new[2].needs_pairing);
    const target = makeDevice(.airplay, "", "", "ID1");
    markNeedsPairing(&new, &target, false);
    try testing.expect(!new[1].needs_pairing);
    try testing.expect(new[2].needs_pairing);
}

test "pyatv on Python 3.14: event-loop crash is recognised for scan, cast and pair" {
    // Verbatim tail of `atvscript scan` / `atvremote pair` from pyatv 0.18.0
    // on CPython 3.14.5 (no AirPlay device was ever listed).
    const crash =
        \\  File "/lib/python3.14/site-packages/pyatv/scripts/atvscript.py", line 424, in main
        \\    loop = asyncio.get_event_loop()
        \\RuntimeError: There is no current event loop in thread 'MainThread'.
    ;
    try std.testing.expect(pyatvEventLoopBroken(crash));
    try std.testing.expectEqual(PairOutcome.python_incompatible, pairOutcome(crash, 1));
    try std.testing.expectEqualStrings(msg_pyatv_python, pairOutcomeMessage(.python_incompatible));
    try std.testing.expect(!pyatvEventLoopBroken("Pairing failed!"));
    try std.testing.expect(!playNeedsPairing(crash));
}
