//! Pure decision logic for Continuum (ROADMAP 7.4): on-demand streaming of
//! local media to browsers/phones/peers, and playback handoff between Opals.
//!
//! No io_global / db / state reach — this file unit-tests standalone and the
//! production code in stream_session.zig and handoff.zig routes through it:
//!   * ffprobe JSON -> Probe; client capability string -> Caps
//!   * decide(): direct-play vs HLS remux vs HLS transcode, with a quality ladder
//!   * chooseEncoder(): VideoToolbox / VAAPI / NVENC / libx264 fallback
//!   * buildFfmpegArgs(): the exact ffmpeg argv (fMP4 HLS, ~4 s segments)
//!   * stream path parsing + segment-name allowlist (no traversal)
//!   * session ids and HMAC-SHA256 stream tokens scoped to one session
//!   * the handoff wire payload and which host a peer should call back

const std = @import("std");

// ── Probe ────────────────────────────────────────────────────────────────

pub const Container = enum { mp4, webm, mkv, other };
pub const VideoCodec = enum { none, h264, hevc, av1, vp9, other };
pub const AudioCodec = enum { none, aac, opus, ac3, eac3, mp3, flac, other };

pub const Probe = struct {
    container: Container = .other,
    video: VideoCodec = .none,
    width: u32 = 0,
    height: u32 = 0,
    /// 10-bit (or higher) pixel format. Browsers cannot decode 10-bit H.264.
    high_bit_depth: bool = false,
    audio: AudioCodec = .none,
    channels: u32 = 0,
    duration: f64 = 0,
};

fn videoCodec(name: []const u8) VideoCodec {
    if (std.mem.eql(u8, name, "h264")) return .h264;
    if (std.mem.eql(u8, name, "hevc")) return .hevc;
    if (std.mem.eql(u8, name, "av1")) return .av1;
    if (std.mem.eql(u8, name, "vp9")) return .vp9;
    return .other;
}

fn audioCodec(name: []const u8) AudioCodec {
    if (std.mem.eql(u8, name, "aac")) return .aac;
    if (std.mem.eql(u8, name, "opus")) return .opus;
    if (std.mem.eql(u8, name, "ac3")) return .ac3;
    if (std.mem.eql(u8, name, "eac3")) return .eac3;
    if (std.mem.eql(u8, name, "mp3")) return .mp3;
    if (std.mem.eql(u8, name, "flac")) return .flac;
    return .other;
}

fn strField(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = obj.get(key) orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

fn numField(obj: std.json.ObjectMap, key: []const u8) f64 {
    const v = obj.get(key) orelse return 0;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        // ffprobe prints durations as strings ("20.000000").
        .string => |s| std.fmt.parseFloat(f64, s) catch 0,
        else => 0,
    };
}

fn attachedPicture(obj: std.json.ObjectMap) bool {
    const d = obj.get("disposition") orelse return false;
    if (d != .object) return false;
    return numField(d.object, "attached_pic") == 1;
}

/// Parse `ffprobe -show_format -show_streams -of json`. `ext` (".mkv", ".webm",
/// ...) disambiguates ffprobe's shared "matroska,webm" format name.
pub fn parseProbe(allocator: std.mem.Allocator, json: []const u8, ext: []const u8) !Probe {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidProbe;
    const root = parsed.value.object;
    var out: Probe = .{};
    if (root.get("format")) |fmt| if (fmt == .object) {
        const name = strField(fmt.object, "format_name");
        if (std.mem.indexOf(u8, name, "mp4") != null or std.mem.indexOf(u8, name, "mov") != null) {
            out.container = .mp4;
        } else if (std.mem.indexOf(u8, name, "matroska") != null) {
            out.container = if (std.ascii.eqlIgnoreCase(ext, ".webm")) .webm else .mkv;
        }
        const d = numField(fmt.object, "duration");
        if (std.math.isFinite(d) and d > 0) out.duration = d;
    };
    const streams = root.get("streams") orelse return error.InvalidProbe;
    if (streams != .array) return error.InvalidProbe;
    for (streams.array.items) |s| {
        if (s != .object) continue;
        const kind = strField(s.object, "codec_type");
        if (std.mem.eql(u8, kind, "video") and out.video == .none and !attachedPicture(s.object)) {
            out.video = videoCodec(strField(s.object, "codec_name"));
            out.width = @intFromFloat(std.math.clamp(numField(s.object, "width"), 0, 16384));
            out.height = @intFromFloat(std.math.clamp(numField(s.object, "height"), 0, 16384));
            const pix = strField(s.object, "pix_fmt");
            out.high_bit_depth = std.mem.indexOf(u8, pix, "10") != null or std.mem.indexOf(u8, pix, "12") != null;
        } else if (std.mem.eql(u8, kind, "audio") and out.audio == .none) {
            out.audio = audioCodec(strField(s.object, "codec_name"));
            out.channels = @intFromFloat(std.math.clamp(numField(s.object, "channels"), 0, 64));
        }
    }
    if (out.video == .none and out.audio == .none) return error.NoMedia;
    return out;
}

// ── Client capabilities ───────────────────────────────────────────────────

pub const Caps = struct {
    h264: bool = false,
    hevc: bool = false,
    av1: bool = false,
    aac: bool = false,
    opus: bool = false,
    ac3: bool = false,
    eac3: bool = false,
    mp3: bool = false,
    /// Progressive containers the client's <video> plays directly.
    mp4: bool = false,
    webm: bool = false,
    /// HLS playback (native or via hls.js).
    hls: bool = false,

    /// The capabilities every current browser has; used when a client sends none.
    pub const baseline: Caps = .{ .h264 = true, .aac = true, .mp3 = true, .mp4 = true, .hls = true };
};

/// Comma list from the client ("h264,hevc,aac,opus,hls,mp4"). Unknown tokens are
/// ignored; an empty list yields the browser baseline.
pub fn parseCaps(text: []const u8) Caps {
    var c: Caps = .{};
    var any = false;
    var it = std.mem.tokenizeAny(u8, text, ", ");
    while (it.next()) |word| {
        inline for (std.meta.fields(Caps)) |f| {
            if (std.mem.eql(u8, word, f.name)) {
                @field(c, f.name) = true;
                any = true;
            }
        }
    }
    return if (any) c else Caps.baseline;
}

fn videoSupported(p: Probe, c: Caps) bool {
    return switch (p.video) {
        .none => true,
        .h264 => c.h264 and !p.high_bit_depth,
        .hevc => c.hevc,
        .av1 => c.av1,
        else => false,
    };
}

fn audioSupported(a: AudioCodec, c: Caps) bool {
    return switch (a) {
        .none => true,
        .aac => c.aac,
        .opus => c.opus,
        .ac3 => c.ac3,
        .eac3 => c.eac3,
        .mp3 => c.mp3,
        else => false,
    };
}

fn containerSupported(k: Container, c: Caps) bool {
    return switch (k) {
        .mp4 => c.mp4,
        .webm => c.webm,
        else => false,
    };
}

// ── Decision ──────────────────────────────────────────────────────────────

pub const Quality = enum { original, p1080, p720, p480 };

pub fn parseQuality(text: []const u8) Quality {
    if (std.mem.eql(u8, text, "1080p") or std.mem.eql(u8, text, "1080")) return .p1080;
    if (std.mem.eql(u8, text, "720p") or std.mem.eql(u8, text, "720")) return .p720;
    if (std.mem.eql(u8, text, "480p") or std.mem.eql(u8, text, "480")) return .p480;
    return .original;
}

pub fn qualityName(q: Quality) []const u8 {
    return switch (q) {
        .original => "original",
        .p1080 => "1080p",
        .p720 => "720p",
        .p480 => "480p",
    };
}

fn rungHeight(q: Quality) u32 {
    return switch (q) {
        .original => 0,
        .p1080 => 1080,
        .p720 => 720,
        .p480 => 480,
    };
}

/// Output height for a rung: 0 = keep the source height. Never upscales.
pub fn ladderHeight(q: Quality, source_height: u32) u32 {
    const rung = rungHeight(q);
    if (rung == 0 or source_height == 0 or source_height <= rung) return 0;
    return rung;
}

/// Target video bitrate (kbit/s) for an encode at `height` (0 = source).
pub fn ladderKbps(height: u32, source_height: u32) u32 {
    const h = if (height > 0) height else source_height;
    if (h >= 1440) return 12000;
    if (h >= 1080) return 6000;
    if (h >= 720) return 3000;
    if (h >= 480) return 1200;
    return 800;
}

pub const Mode = enum { direct, remux, transcode };

pub const Plan = struct {
    mode: Mode,
    has_video: bool,
    has_audio: bool,
    copy_video: bool,
    copy_audio: bool,
    /// 0 = keep source height.
    height: u32 = 0,
    video_kbps: u32 = 0,
    /// The copied video is HEVC (Safari needs the hvc1 sample-entry tag).
    hevc_tag: bool = false,
};

/// Direct play when the client decodes the file as-is; otherwise an HLS remux
/// (stream copy into fMP4) when only the container is wrong; otherwise an HLS
/// transcode to H.264/AAC at the requested rung. Audio is copied whenever the
/// client decodes it, so a remux of an AC-3 track stays bit-exact on Safari.
pub fn decide(p: Probe, c: Caps, q: Quality) Plan {
    const has_video = p.video != .none;
    const has_audio = p.audio != .none;
    const height = if (has_video) ladderHeight(q, p.height) else 0;
    const v_ok = videoSupported(p, c);
    const a_ok = audioSupported(p.audio, c);
    if (v_ok and a_ok and height == 0 and containerSupported(p.container, c)) {
        return .{ .mode = .direct, .has_video = has_video, .has_audio = has_audio, .copy_video = true, .copy_audio = true };
    }
    // fMP4 HLS carries H.264, HEVC and AV1; anything else must be re-encoded.
    const hls_copyable = switch (p.video) {
        .none, .h264, .hevc, .av1 => true,
        else => false,
    };
    // MP3/FLAC are not reliable in fMP4 HLS across hls.js + Safari; re-encode.
    const audio_copy = a_ok and p.audio != .mp3 and p.audio != .flac;
    if (v_ok and hls_copyable and height == 0) {
        return .{
            .mode = .remux,
            .has_video = has_video,
            .has_audio = has_audio,
            .copy_video = true,
            .copy_audio = audio_copy,
            .hevc_tag = p.video == .hevc,
        };
    }
    return .{
        .mode = .transcode,
        .has_video = has_video,
        .has_audio = has_audio,
        .copy_video = !has_video,
        .copy_audio = audio_copy,
        .height = height,
        .video_kbps = if (has_video) ladderKbps(height, p.height) else 0,
    };
}

// ── Encoder ───────────────────────────────────────────────────────────────

pub const Encoder = enum { videotoolbox, vaapi, nvenc, libx264 };

pub const VAAPI_DEVICE = "/dev/dri/renderD128";

/// Hardware first when this ffmpeg build lists the encoder AND the device is
/// present (`ffmpeg -encoders` lists NVENC/VAAPI on machines without the GPU).
pub fn chooseEncoder(os: std.Target.Os.Tag, encoders_text: []const u8, has_render_node: bool, has_nvidia: bool) Encoder {
    const has = struct {
        fn f(text: []const u8, name: []const u8) bool {
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                var words = std.mem.tokenizeAny(u8, line, " \t\r");
                _ = words.next() orelse continue; // flags column ("V....D")
                const enc = words.next() orelse continue;
                if (std.mem.eql(u8, enc, name)) return true;
            }
            return false;
        }
    }.f;
    switch (os) {
        .macos => if (has(encoders_text, "h264_videotoolbox")) return .videotoolbox,
        .linux => {
            if (has_nvidia and has(encoders_text, "h264_nvenc")) return .nvenc;
            if (has_render_node and has(encoders_text, "h264_vaapi")) return .vaapi;
        },
        else => {},
    }
    return .libx264;
}

pub fn encoderName(e: Encoder) []const u8 {
    return switch (e) {
        .videotoolbox => "h264_videotoolbox",
        .vaapi => "h264_vaapi",
        .nvenc => "h264_nvenc",
        .libx264 => "libx264",
    };
}

// ── ffmpeg argv ───────────────────────────────────────────────────────────

pub const SEGMENT_SECONDS = 4;
pub const PLAYLIST = "index.m3u8";
pub const INIT = "init.mp4";

/// Fixed storage for one argv: no allocation, lives in the caller's frame.
pub const ArgBuf = struct {
    args: [72][]const u8 = undefined,
    len: usize = 0,
    text: [4096]u8 = undefined,
    text_len: usize = 0,

    fn add(self: *ArgBuf, a: []const u8) !void {
        if (self.len >= self.args.len) return error.TooManyArgs;
        self.args[self.len] = a;
        self.len += 1;
    }

    fn addFmt(self: *ArgBuf, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.bufPrint(self.text[self.text_len..], fmt, args);
        self.text_len += s.len;
        try self.add(s);
    }

    pub fn slice(self: *const ArgBuf) []const []const u8 {
        return self.args[0..self.len];
    }
};

/// ffmpeg argv for an HLS (fMP4, event playlist, ~4 s segments) remux or
/// transcode. Output names are relative: the caller runs ffmpeg with the
/// session directory as cwd. The input is passed as `file:<abs>` so a path can
/// never be read as a protocol URL.
pub fn buildFfmpegArgs(out: *ArgBuf, ffmpeg: []const u8, input_abs: []const u8, plan: Plan, encoder: Encoder, start_secs: u32) ![]const []const u8 {
    if (plan.mode == .direct) return error.DirectNeedsNoFfmpeg;
    if (input_abs.len == 0 or input_abs[0] != '/') return error.InputNotAbsolute;
    out.* = .{};
    try out.add(ffmpeg);
    for ([_][]const u8{ "-hide_banner", "-nostdin", "-loglevel", "error", "-y" }) |a| try out.add(a);
    const encode_video = plan.has_video and !plan.copy_video;
    if (encode_video and encoder == .vaapi) {
        try out.add("-vaapi_device");
        try out.add(VAAPI_DEVICE);
    }
    if (start_secs > 0) {
        try out.add("-ss");
        try out.addFmt("{d}", .{start_secs});
    }
    try out.add("-i");
    try out.addFmt("file:{s}", .{input_abs});
    for ([_][]const u8{ "-map", "0:v:0?", "-map", "0:a:0?", "-sn", "-dn" }) |a| try out.add(a);

    if (plan.has_video) {
        if (!encode_video) {
            try out.add("-c:v");
            try out.add("copy");
            if (plan.hevc_tag) {
                try out.add("-tag:v");
                try out.add("hvc1");
            }
        } else {
            try out.add("-c:v");
            try out.add(encoderName(encoder));
            switch (encoder) {
                .libx264 => for ([_][]const u8{ "-preset", "veryfast", "-crf", "23" }) |a| try out.add(a),
                .videotoolbox => for ([_][]const u8{ "-allow_sw", "1", "-realtime", "1" }) |a| try out.add(a),
                .nvenc => for ([_][]const u8{ "-preset", "p4" }) |a| try out.add(a),
                .vaapi => {},
            }
            const kbps = if (plan.video_kbps > 0) plan.video_kbps else 4000;
            if (encoder == .libx264) {
                try out.add("-maxrate");
                try out.addFmt("{d}k", .{kbps});
            } else {
                try out.add("-b:v");
                try out.addFmt("{d}k", .{kbps});
            }
            try out.add("-bufsize");
            try out.addFmt("{d}k", .{kbps * 2});
            try out.add("-vf");
            if (encoder == .vaapi) {
                if (plan.height > 0)
                    try out.addFmt("scale=-2:{d},format=nv12,hwupload", .{plan.height})
                else
                    try out.add("format=nv12,hwupload");
            } else if (plan.height > 0) {
                try out.addFmt("scale=-2:{d},format=yuv420p", .{plan.height});
            } else {
                try out.add("format=yuv420p");
            }
            // Keyframe every segment boundary so every segment starts decodable.
            try out.add("-force_key_frames");
            try out.addFmt("expr:gte(t,n_forced*{d})", .{SEGMENT_SECONDS});
        }
    }
    if (plan.has_audio) {
        if (plan.copy_audio) {
            try out.add("-c:a");
            try out.add("copy");
        } else {
            for ([_][]const u8{ "-c:a", "aac", "-ac", "2", "-b:a", "160k" }) |a| try out.add(a);
        }
    }
    try out.add("-f");
    try out.add("hls");
    try out.add("-hls_time");
    try out.addFmt("{d}", .{SEGMENT_SECONDS});
    for ([_][]const u8{
        "-hls_playlist_type",      "event",
        "-hls_segment_type",       "fmp4",
        "-hls_fmp4_init_filename", INIT,
        "-hls_segment_filename",   "seg_%05d.m4s",
        "-hls_flags",              "independent_segments+temp_file",
        PLAYLIST,
    }) |a| try out.add(a);
    return out.slice();
}

/// The ffprobe that ships beside `ffmpeg_path` ("/opt/homebrew/bin/ffmpeg" ->
/// "/opt/homebrew/bin/ffprobe"; bare "ffmpeg" -> "ffprobe").
pub fn siblingTool(ffmpeg_path: []const u8, tool: []const u8, out: []u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, ffmpeg_path, '/');
    const dir = if (slash) |i| ffmpeg_path[0 .. i + 1] else "";
    return std.fmt.bufPrint(out, "{s}{s}", .{ dir, tool }) catch null;
}

// ── Stream paths ──────────────────────────────────────────────────────────

pub const SID_LEN = 32;

pub fn validSessionId(s: []const u8) bool {
    if (s.len != SID_LEN) return false;
    for (s) |ch| if (!std.ascii.isDigit(ch) and !(ch >= 'a' and ch <= 'f')) return false;
    return true;
}

pub fn sessionIdFromBytes(bytes: [SID_LEN / 2]u8, out: *[SID_LEN]u8) []const u8 {
    out.* = std.fmt.bytesToHex(bytes, .lower);
    return out[0..];
}

/// Allowlisted file names inside a session: the playlist, the fMP4 init
/// segment, numbered media segments, `direct` (the source file itself, Range),
/// and the two control verbs. Everything else — dots, slashes, NULs, `..` — is
/// refused, so a name can never escape <cache>/hls/<sid>/.
pub fn validName(name: []const u8) bool {
    for ([_][]const u8{ PLAYLIST, INIT, "direct", "progress", "stop" }) |n| if (std.mem.eql(u8, name, n)) return true;
    const pre = "seg_";
    const suf = ".m4s";
    if (!std.mem.startsWith(u8, name, pre) or !std.mem.endsWith(u8, name, suf)) return false;
    const digits = name[pre.len .. name.len - suf.len];
    if (digits.len < 5 or digits.len > 8) return false;
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

pub fn isFileName(name: []const u8) bool {
    return validName(name) and !std.mem.eql(u8, name, "progress") and !std.mem.eql(u8, name, "stop") and !std.mem.eql(u8, name, "direct");
}

pub const StreamPath = struct {
    sid: []const u8,
    token: ?[]const u8 = null,
    name: []const u8,
};

/// `rest` = what follows "/api/stream/": "<sid>/<name>" (API-authenticated) or
/// "<sid>/<token>/<name>" (stream-token authenticated). The token rides in the
/// PATH, not the query, so relative segment URIs in the playlist inherit it.
pub fn parseStreamPath(rest: []const u8) ?StreamPath {
    var parts: [4][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, rest, '/');
    while (it.next()) |p| {
        if (n == parts.len) return null;
        parts[n] = p;
        n += 1;
    }
    if (n < 2 or n > 3) return null;
    if (!validSessionId(parts[0])) return null;
    const name = parts[n - 1];
    if (!validName(name)) return null;
    if (n == 3) {
        if (!tokenShape(parts[1])) return null;
        return .{ .sid = parts[0], .token = parts[1], .name = name };
    }
    return .{ .sid = parts[0], .name = name };
}

// ── Stream tokens ─────────────────────────────────────────────────────────

pub const KEY_LEN = 32;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
pub const TOKEN_MAX = 20 + 1 + Hmac.mac_length * 2;
/// Long enough for a feature film paused for dinner, short enough that a
/// leaked URL dies the same evening. Sessions also die on idle (see
/// stream_session.IDLE_MS), which ends a token's use earlier still.
pub const TOKEN_TTL_SECS: i64 = 6 * 3600;

fn tokenShape(tok: []const u8) bool {
    if (tok.len < 3 or tok.len > TOKEN_MAX) return false;
    const dot = std.mem.indexOfScalar(u8, tok, '.') orelse return false;
    if (dot == 0 or tok.len - dot - 1 != Hmac.mac_length * 2) return false;
    for (tok[0..dot]) |ch| if (!std.ascii.isDigit(ch)) return false;
    for (tok[dot + 1 ..]) |ch| if (!std.ascii.isDigit(ch) and !(ch >= 'a' and ch <= 'f')) return false;
    return true;
}

fn tokenMac(key: *const [KEY_LEN]u8, sid: []const u8, expires_at: i64) [Hmac.mac_length]u8 {
    var h = Hmac.init(key);
    h.update("opal-stream-v1|");
    h.update(sid);
    var num: [24]u8 = undefined;
    h.update("|");
    h.update(std.fmt.bufPrint(&num, "{d}", .{expires_at}) catch "");
    var mac: [Hmac.mac_length]u8 = undefined;
    h.final(&mac);
    return mac;
}

/// "<unix expiry>.<hex HMAC-SHA256(key, sid|expiry)>" — valid only for `sid`.
pub fn mintToken(key: *const [KEY_LEN]u8, sid: []const u8, expires_at: i64, out: *[TOKEN_MAX]u8) []const u8 {
    const mac = tokenMac(key, sid, expires_at);
    const hex = std.fmt.bytesToHex(mac, .lower);
    return std.fmt.bufPrint(out, "{d}.{s}", .{ expires_at, hex[0..] }) catch out[0..0];
}

pub const Verdict = enum { ok, expired, invalid };

pub fn verifyToken(key: *const [KEY_LEN]u8, sid: []const u8, token: []const u8, now: i64) Verdict {
    if (!tokenShape(token)) return .invalid;
    const dot = std.mem.indexOfScalar(u8, token, '.').?;
    const expires_at = std.fmt.parseInt(i64, token[0..dot], 10) catch return .invalid;
    var got: [Hmac.mac_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&got, token[dot + 1 ..]) catch return .invalid;
    const want = tokenMac(key, sid, expires_at);
    // MAC first, constant time: an attacker learns nothing from expiry timing.
    if (!std.crypto.timing_safe.eql([Hmac.mac_length]u8, got, want)) return .invalid;
    if (now >= expires_at) return .expired;
    return .ok;
}

// ── Handoff ───────────────────────────────────────────────────────────────

pub const SOURCE_MAX = 2048;
pub const TITLE_MAX = 256;
pub const MAX_POSITION: f64 = 7 * 24 * 3600;

pub const Handoff = struct {
    source: [SOURCE_MAX]u8 = undefined,
    source_len: usize = 0,
    title: [TITLE_MAX]u8 = undefined,
    title_len: usize = 0,
    position: f64 = 0,
    duration: f64 = 0,

    pub fn sourceText(self: *const Handoff) []const u8 {
        return self.source[0..self.source_len];
    }
    pub fn titleText(self: *const Handoff) []const u8 {
        return self.title[0..self.title_len];
    }
};

/// A receiver plays only network sources: http(s) or a magnet. Never a local
/// path or file:// — a peer must not be able to make this machine open its
/// own files (or devices) by name.
pub fn validSource(s: []const u8) bool {
    if (s.len == 0 or s.len > SOURCE_MAX) return false;
    for (s) |ch| if (ch <= 0x20 or ch == 0x7f) return false;
    if (std.ascii.startsWithIgnoreCase(s, "magnet:?")) return true;
    const rest = if (std.ascii.startsWithIgnoreCase(s, "https://"))
        s["https://".len..]
    else if (std.ascii.startsWithIgnoreCase(s, "http://"))
        s["http://".len..]
    else
        return false;
    return rest.len > 0 and rest[0] != '/';
}

fn cleanPosition(v: f64) f64 {
    if (!std.math.isFinite(v) or v < 0) return 0;
    return @min(v, MAX_POSITION);
}

fn writeEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try w.writeByte(ch);
        } else {
            try w.print("%{X:0>2}", .{ch});
        }
    }
}

/// Form-encoded wire payload: `source=..&title=..&pos=..&dur=..`.
pub fn encodeHandoff(w: *std.Io.Writer, source: []const u8, title: []const u8, position: f64, duration: f64) !void {
    try w.writeAll("source=");
    try writeEscaped(w, source);
    try w.writeAll("&title=");
    try writeEscaped(w, title[0..@min(title.len, TITLE_MAX)]);
    try w.print("&pos={d:.3}&dur={d:.3}", .{ cleanPosition(position), cleanPosition(duration) });
}

fn formValue(body: []const u8, key: []const u8) ?[]const u8 {
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

fn percentDecode(src: []const u8, out: []u8) ?[]const u8 {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len) {
        if (o >= out.len) return null;
        const ch = src[i];
        if (ch == '%') {
            if (i + 2 >= src.len) return null;
            out[o] = std.fmt.parseInt(u8, src[i + 1 .. i + 3], 16) catch return null;
            i += 3;
        } else {
            out[o] = if (ch == '+') ' ' else ch;
            i += 1;
        }
        o += 1;
    }
    return out[0..o];
}

pub const HandoffError = error{ MissingSource, BadSource, BadTitle, BadPosition };

/// Parse + validate a received payload into `out`.
pub fn decodeHandoff(body: []const u8, out: *Handoff) HandoffError!void {
    const raw_source = formValue(body, "source") orelse return error.MissingSource;
    const source = percentDecode(raw_source, &out.source) orelse return error.BadSource;
    if (!validSource(source)) return error.BadSource;
    out.source_len = source.len;
    out.title_len = 0;
    if (formValue(body, "title")) |raw_title| {
        const title = percentDecode(raw_title, &out.title) orelse return error.BadTitle;
        if (!std.unicode.utf8ValidateSlice(title)) return error.BadTitle;
        for (title) |ch| if (ch < 0x20) return error.BadTitle;
        out.title_len = title.len;
    }
    out.position = 0;
    if (formValue(body, "pos")) |p| {
        const v = std.fmt.parseFloat(f64, p) catch return error.BadPosition;
        if (!std.math.isFinite(v) or v < 0 or v > MAX_POSITION) return error.BadPosition;
        out.position = v;
    }
    out.duration = 0;
    if (formValue(body, "dur")) |d| out.duration = cleanPosition(std.fmt.parseFloat(f64, d) catch 0);
}

/// A local file in a handoff travels as a URL back to THIS host. Which address
/// can the peer reach? A loopback peer is this machine: use 127.0.0.1. Any
/// other peer gets our LAN address (null when none is known — the caller
/// refuses rather than send a URL nobody can open).
pub fn advertiseHost(peer_url: []const u8, lan_ip: []const u8) ?[]const u8 {
    const host = urlHost(peer_url) orelse return null;
    if (isLoopbackHost(host)) return "127.0.0.1";
    if (lan_ip.len == 0) return null;
    return lan_ip;
}

/// The host part of "http://host:port/..." (brackets kept for IPv6).
pub fn urlHost(url: []const u8) ?[]const u8 {
    const after = if (std.mem.indexOf(u8, url, "://")) |i| url[i + 3 ..] else return null;
    const end = std.mem.indexOfAny(u8, after, "/?#") orelse after.len;
    const authority = after[0..end];
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return null;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
        return authority[0 .. close + 1];
    }
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse authority.len;
    return authority[0..colon];
}

pub fn isLoopbackHost(host: []const u8) bool {
    return std.mem.startsWith(u8, host, "127.") or std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, "[::1]");
}

/// A request's Host header, if it is a plain host[:port] we may echo into a
/// URL (letters, digits, '.', '-', ':', brackets). Used so "Bring here"
/// returns a stream URL on the very address the caller already reached.
pub fn safeHostHeader(h: []const u8) ?[]const u8 {
    const v = std.mem.trim(u8, h, " \t");
    if (v.len == 0 or v.len > 255) return null;
    for (v) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-' or ch == ':' or ch == '[' or ch == ']')) return null;
    return v;
}

pub fn percentOf(pos: f64, dur: f64) f64 {
    if (!std.math.isFinite(pos) or !std.math.isFinite(dur) or dur <= 0 or pos <= 0) return 0;
    return @min(100.0, pos / dur * 100.0);
}

pub fn idleExpired(last_ms: i64, now_ms: i64, idle_ms: i64) bool {
    return now_ms - last_ms > idle_ms;
}

// ── Tests ─────────────────────────────────────────────────────────────────

const t = std.testing;

const probe_mkv_hevc =
    \\{"streams":[{"codec_type":"video","codec_name":"hevc","width":3840,"height":2160,"pix_fmt":"yuv420p10le"},
    \\{"codec_type":"audio","codec_name":"eac3","channels":6}],
    \\"format":{"format_name":"matroska,webm","duration":"5400.5"}}
;
const probe_mp4_h264 =
    \\{"streams":[{"codec_type":"video","codec_name":"h264","width":1920,"height":1080,"pix_fmt":"yuv420p"},
    \\{"codec_type":"audio","codec_name":"aac","channels":2}],
    \\"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"20.000000"}}
;

test "stream probe parses ffprobe JSON (container, codecs, size, depth, duration)" {
    const a = try parseProbe(t.allocator, probe_mkv_hevc, ".mkv");
    try t.expectEqual(Container.mkv, a.container);
    try t.expectEqual(VideoCodec.hevc, a.video);
    try t.expectEqual(@as(u32, 2160), a.height);
    try t.expect(a.high_bit_depth);
    try t.expectEqual(AudioCodec.eac3, a.audio);
    try t.expectApproxEqAbs(@as(f64, 5400.5), a.duration, 0.001);
    const b = try parseProbe(t.allocator, probe_mp4_h264, ".mp4");
    try t.expectEqual(Container.mp4, b.container);
    try t.expect(!b.high_bit_depth);
    const w = try parseProbe(t.allocator, "{\"streams\":[{\"codec_type\":\"video\",\"codec_name\":\"vp9\",\"height\":720}],\"format\":{\"format_name\":\"matroska,webm\"}}", ".webm");
    try t.expectEqual(Container.webm, w.container);
    try t.expectError(error.NoMedia, parseProbe(t.allocator, "{\"streams\":[],\"format\":{}}", ".mp4"));
    try t.expectError(error.InvalidProbe, parseProbe(t.allocator, "[]", ".mp4"));
}

test "stream probe skips cover art as the video stream" {
    const json =
        \\{"streams":[{"codec_type":"audio","codec_name":"mp3","channels":2},
        \\{"codec_type":"video","codec_name":"mjpeg","width":500,"height":500,"disposition":{"attached_pic":1}}],
        \\"format":{"format_name":"mp3"}}
    ;
    const p = try parseProbe(t.allocator, json, ".mp3");
    try t.expectEqual(VideoCodec.none, p.video);
    try t.expectEqual(AudioCodec.mp3, p.audio);
}

test "stream caps parse a client list and fall back to the browser baseline" {
    const c = parseCaps("h264,hevc, opus,hls,bogus");
    try t.expect(c.h264 and c.hevc and c.opus and c.hls);
    try t.expect(!c.av1 and !c.aac and !c.mp4);
    const base = parseCaps("");
    try t.expect(base.h264 and base.aac and base.mp4 and base.hls and !base.hevc);
}

test "stream decision matrix: direct, remux, transcode" {
    const mp4 = try parseProbe(t.allocator, probe_mp4_h264, ".mp4");
    const mkv = try parseProbe(t.allocator, probe_mkv_hevc, ".mkv");
    const chrome = parseCaps("h264,aac,opus,mp4,webm,hls");
    const safari = parseCaps("h264,hevc,aac,ac3,eac3,mp4,hls");

    // H.264/AAC MP4 at original -> direct play, no ffmpeg at all.
    try t.expectEqual(Mode.direct, decide(mp4, chrome, .original).mode);
    // Same file at 720p -> transcode, scaled, bitrate from the rung.
    const p720 = decide(mp4, chrome, .p720);
    try t.expectEqual(Mode.transcode, p720.mode);
    try t.expectEqual(@as(u32, 720), p720.height);
    try t.expectEqual(@as(u32, 3000), p720.video_kbps);
    try t.expect(p720.copy_audio); // AAC is still decodable: copy it
    // HEVC/E-AC-3 MKV on Safari -> remux (copy both, hvc1 tag), no re-encode.
    const s = decide(mkv, safari, .original);
    try t.expectEqual(Mode.remux, s.mode);
    try t.expect(s.copy_video and s.copy_audio and s.hevc_tag);
    // Same MKV on Chrome (no HEVC, no E-AC-3) -> full transcode, audio to AAC.
    const c = decide(mkv, chrome, .original);
    try t.expectEqual(Mode.transcode, c.mode);
    try t.expect(!c.copy_video and !c.copy_audio);
    try t.expectEqual(@as(u32, 0), c.height);
    try t.expectEqual(@as(u32, 12000), c.video_kbps);
    // H.264 in MKV on Chrome -> remux only (container is the only problem).
    var h264mkv = mp4;
    h264mkv.container = .mkv;
    try t.expectEqual(Mode.remux, decide(h264mkv, chrome, .original).mode);
    // 10-bit H.264 is undecodable in browsers -> transcode.
    var hi10 = mp4;
    hi10.high_bit_depth = true;
    try t.expectEqual(Mode.transcode, decide(hi10, chrome, .original).mode);
    // A rung at/above the source never upscales: 1080p of a 1080p file is direct.
    try t.expectEqual(Mode.direct, decide(mp4, chrome, .p1080).mode);
}

test "stream ladder never upscales and sizes bitrates" {
    try t.expectEqual(@as(u32, 0), ladderHeight(.original, 2160));
    try t.expectEqual(@as(u32, 1080), ladderHeight(.p1080, 2160));
    try t.expectEqual(@as(u32, 0), ladderHeight(.p720, 480));
    try t.expectEqual(@as(u32, 480), ladderHeight(.p480, 720));
    try t.expectEqual(@as(u32, 1200), ladderKbps(480, 1080));
    try t.expectEqual(Quality.p720, parseQuality("720p"));
    try t.expectEqual(Quality.original, parseQuality("auto"));
}

test "stream encoder choice prefers present hardware, falls back to libx264" {
    const listing =
        \\ V....D h264_videotoolbox    VideoToolbox H.264 Encoder (codec h264)
        \\ V....D h264_vaapi           H.264/AVC (VAAPI) (codec h264)
        \\ V....D h264_nvenc           NVIDIA NVENC H.264 encoder (codec h264)
        \\ V....D libx264              libx264 H.264 / AVC (codec h264)
    ;
    try t.expectEqual(Encoder.videotoolbox, chooseEncoder(.macos, listing, false, false));
    try t.expectEqual(Encoder.nvenc, chooseEncoder(.linux, listing, true, true));
    try t.expectEqual(Encoder.vaapi, chooseEncoder(.linux, listing, true, false));
    // Listed but no device: software.
    try t.expectEqual(Encoder.libx264, chooseEncoder(.linux, listing, false, false));
    try t.expectEqual(Encoder.libx264, chooseEncoder(.macos, " V....D libx264  x\n", false, false));
    // Substring of another encoder name does not count.
    try t.expectEqual(Encoder.libx264, chooseEncoder(.macos, " V....D h264_videotoolbox_x  y\n", false, false));
}

test "stream ffmpeg argv: HLS fMP4 event playlist, copy vs encode" {
    var buf: ArgBuf = .{};
    const remux: Plan = .{ .mode = .remux, .has_video = true, .has_audio = true, .copy_video = true, .copy_audio = false, .hevc_tag = true };
    const a = try buildFfmpegArgs(&buf, "/opt/homebrew/bin/ffmpeg", "/m/a b.mkv", remux, .libx264, 90);
    const joined = try std.mem.join(t.allocator, " ", a);
    defer t.allocator.free(joined);
    try t.expect(std.mem.indexOf(u8, joined, "-ss 90 -i file:/m/a b.mkv") != null);
    try t.expect(std.mem.indexOf(u8, joined, "-c:v copy -tag:v hvc1") != null);
    try t.expect(std.mem.indexOf(u8, joined, "-c:a aac -ac 2") != null);
    try t.expect(std.mem.indexOf(u8, joined, "-hls_playlist_type event -hls_segment_type fmp4") != null);
    try t.expect(std.mem.endsWith(u8, joined, "independent_segments+temp_file index.m3u8"));
    try t.expect(std.mem.indexOf(u8, joined, "-hls_time 4") != null);

    var buf2: ArgBuf = .{};
    const tc: Plan = .{ .mode = .transcode, .has_video = true, .has_audio = true, .copy_video = false, .copy_audio = true, .height = 720, .video_kbps = 3000 };
    const b = try buildFfmpegArgs(&buf2, "ffmpeg", "/m/x.mp4", tc, .videotoolbox, 0);
    const j2 = try std.mem.join(t.allocator, " ", b);
    defer t.allocator.free(j2);
    try t.expect(std.mem.indexOf(u8, j2, "-ss") == null);
    try t.expect(std.mem.indexOf(u8, j2, "-c:v h264_videotoolbox") != null);
    try t.expect(std.mem.indexOf(u8, j2, "-b:v 3000k -bufsize 6000k -vf scale=-2:720,format=yuv420p") != null);
    try t.expect(std.mem.indexOf(u8, j2, "-force_key_frames expr:gte(t,n_forced*4)") != null);
    try t.expect(std.mem.indexOf(u8, j2, "-c:a copy") != null);

    var buf3: ArgBuf = .{};
    const v = try buildFfmpegArgs(&buf3, "ffmpeg", "/m/x.mkv", tc, .vaapi, 0);
    const j3 = try std.mem.join(t.allocator, " ", v);
    defer t.allocator.free(j3);
    try t.expect(std.mem.startsWith(u8, j3, "ffmpeg -hide_banner -nostdin -loglevel error -y -vaapi_device /dev/dri/renderD128"));
    try t.expect(std.mem.indexOf(u8, j3, "scale=-2:720,format=nv12,hwupload") != null);

    var buf4: ArgBuf = .{};
    try t.expectError(error.InputNotAbsolute, buildFfmpegArgs(&buf4, "ffmpeg", "rel.mkv", tc, .libx264, 0));
    try t.expectError(error.DirectNeedsNoFfmpeg, buildFfmpegArgs(&buf4, "ffmpeg", "/a.mp4", .{ .mode = .direct, .has_video = true, .has_audio = true, .copy_video = true, .copy_audio = true }, .libx264, 0));
}

test "stream names: allowlist only, no traversal" {
    for ([_][]const u8{ "index.m3u8", "init.mp4", "seg_00000.m4s", "seg_12345678.m4s", "direct", "progress", "stop" }) |n| try t.expect(validName(n));
    for ([_][]const u8{ "", "..", "../index.m3u8", "seg_1.m4s", "seg_00001.ts", "seg_0000a.m4s", "seg_00001.m4s/..", "index.m3u8\x00", "/etc/passwd", "seg_123456789.m4s", "INDEX.m3u8" }) |n| try t.expect(!validName(n));
    try t.expect(isFileName("seg_00001.m4s") and !isFileName("direct") and !isFileName("stop"));
}

test "stream path parsing: sid, optional path token, name" {
    const sid = "0123456789abcdef0123456789abcdef";
    const tok = "1700000000.0000000000000000000000000000000000000000000000000000000000000000";
    const a = parseStreamPath(sid ++ "/index.m3u8").?;
    try t.expectEqualStrings(sid, a.sid);
    try t.expect(a.token == null);
    const b = parseStreamPath(sid ++ "/" ++ tok ++ "/seg_00002.m4s").?;
    try t.expectEqualStrings(tok, b.token.?);
    try t.expectEqualStrings("seg_00002.m4s", b.name);
    try t.expect(parseStreamPath(sid ++ "/../index.m3u8") == null);
    try t.expect(parseStreamPath(sid ++ "/" ++ tok ++ "/../../x") == null);
    try t.expect(parseStreamPath("0123456789ABCDEF0123456789abcdef/index.m3u8") == null);
    try t.expect(parseStreamPath(sid) == null);
    try t.expect(parseStreamPath(sid ++ "/a/b/index.m3u8") == null);
    try t.expect(parseStreamPath(sid ++ "/notatoken/index.m3u8") == null);
    var idbuf: [SID_LEN]u8 = undefined;
    try t.expect(validSessionId(sessionIdFromBytes(.{0xab} ** 16, &idbuf)));
}

test "stream token: mint/verify, expiry, tamper, wrong session, wrong key" {
    const key: [KEY_LEN]u8 = .{7} ** KEY_LEN;
    const other_key: [KEY_LEN]u8 = .{8} ** KEY_LEN;
    const sid = "0123456789abcdef0123456789abcdef";
    var buf: [TOKEN_MAX]u8 = undefined;
    const tok = mintToken(&key, sid, 2_000, &buf);
    try t.expectEqual(Verdict.ok, verifyToken(&key, sid, tok, 1_999));
    try t.expectEqual(Verdict.expired, verifyToken(&key, sid, tok, 2_000));
    try t.expectEqual(Verdict.invalid, verifyToken(&key, "ffffffffffffffffffffffffffffffff", tok, 1_000));
    try t.expectEqual(Verdict.invalid, verifyToken(&other_key, sid, tok, 1_000));
    // Extending the expiry without the key must fail.
    var forged: [TOKEN_MAX]u8 = undefined;
    @memcpy(forged[0..tok.len], tok);
    forged[0] = '9';
    try t.expectEqual(Verdict.invalid, verifyToken(&key, sid, forged[0..tok.len], 1_000));
    // Flip one MAC nibble.
    @memcpy(forged[0..tok.len], tok);
    forged[tok.len - 1] = if (forged[tok.len - 1] == '0') '1' else '0';
    try t.expectEqual(Verdict.invalid, verifyToken(&key, sid, forged[0..tok.len], 1_000));
    try t.expectEqual(Verdict.invalid, verifyToken(&key, sid, "", 0));
    try t.expectEqual(Verdict.invalid, verifyToken(&key, sid, "x.y", 0));
}

test "handoff payload round-trips and refuses local paths" {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const src = "http://192.168.1.5:41595/api/stream/0123456789abcdef0123456789abcdef/1.ab/direct";
    try encodeHandoff(&w, src, "Movie & Co = 2", 1234.5, 5400);
    var h: Handoff = .{};
    try decodeHandoff(buf[0..w.end], &h);
    try t.expectEqualStrings(src, h.sourceText());
    try t.expectEqualStrings("Movie & Co = 2", h.titleText());
    try t.expectApproxEqAbs(@as(f64, 1234.5), h.position, 0.001);
    try t.expectApproxEqAbs(@as(f64, 5400), h.duration, 0.001);

    var m: Handoff = .{};
    try decodeHandoff("source=magnet%3A%3Fxt%3Durn%3Abtih%3Aabc&pos=10", &m);
    try t.expectEqualStrings("magnet:?xt=urn:btih:abc", m.sourceText());

    var bad: Handoff = .{};
    try t.expectError(error.BadSource, decodeHandoff("source=%2Fetc%2Fpasswd", &bad));
    try t.expectError(error.BadSource, decodeHandoff("source=file%3A%2F%2F%2Fetc%2Fpasswd", &bad));
    try t.expectError(error.BadSource, decodeHandoff("source=http%3A%2F%2F%2Fx", &bad));
    try t.expectError(error.BadSource, decodeHandoff("source=http%3A%2F%2Fa%20b", &bad));
    try t.expectError(error.MissingSource, decodeHandoff("title=x", &bad));
    try t.expectError(error.BadPosition, decodeHandoff("source=http%3A%2F%2Fa&pos=-1", &bad));
    try t.expectError(error.BadPosition, decodeHandoff("source=http%3A%2F%2Fa&pos=nan", &bad));
    try t.expectError(error.BadTitle, decodeHandoff("source=http%3A%2F%2Fa&title=%0A", &bad));
    try t.expectError(error.BadSource, decodeHandoff("source=%ZZ", &bad));
}

test "handoff advertises a host the peer can reach" {
    try t.expectEqualStrings("127.0.0.1", advertiseHost("http://127.0.0.1:42141", "192.168.1.9").?);
    try t.expectEqualStrings("127.0.0.1", advertiseHost("http://localhost:41595/", "").?);
    try t.expectEqualStrings("192.168.1.9", advertiseHost("http://192.168.1.20:41595", "192.168.1.9").?);
    try t.expect(advertiseHost("http://192.168.1.20:41595", "") == null);
    try t.expect(advertiseHost("not a url", "10.0.0.1") == null);
    try t.expectEqualStrings("[::1]", urlHost("http://[::1]:80/x").?);
    try t.expect(urlHost("http://user@host/") == null);
    try t.expectEqualStrings("192.168.1.9:41595", safeHostHeader(" 192.168.1.9:41595").?);
    try t.expect(safeHostHeader("evil.com/x") == null);
    try t.expect(safeHostHeader("a\r\nb") == null);
}

test "stream helpers: ffprobe sibling, percent, idle" {
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("/opt/homebrew/bin/ffprobe", siblingTool("/opt/homebrew/bin/ffmpeg", "ffprobe", &buf).?);
    try t.expectEqualStrings("ffprobe", siblingTool("ffmpeg", "ffprobe", &buf).?);
    try t.expectApproxEqAbs(@as(f64, 50), percentOf(10, 20), 0.001);
    try t.expectEqual(@as(f64, 0), percentOf(std.math.nan(f64), 20));
    try t.expect(idleExpired(0, 1001, 1000) and !idleExpired(0, 1000, 1000));
}

/// Mutex-protected lifetime shared by creation, requests and the reaper.
pub const SlotLifetime = struct {
    used: bool = false,
    pins: usize = 0,

    pub fn reserve(self: *SlotLifetime) bool {
        if (self.used) return false;
        self.* = .{ .used = true, .pins = 1 };
        return true;
    }
    pub fn acquire(self: *SlotLifetime) void {
        std.debug.assert(self.used);
        self.pins += 1;
    }
    pub fn release(self: *SlotLifetime) void {
        std.debug.assert(self.pins > 0);
        self.pins -= 1;
    }
    pub fn retire(self: *SlotLifetime) bool {
        if (self.pins != 0) return false;
        self.used = false;
        return true;
    }
};

test "stopped streaming slot cannot be reused until creation and requests release it" {
    var life: SlotLifetime = .{};
    try std.testing.expect(life.reserve());
    life.acquire(); // request A
    life.release(); // creator returns
    try std.testing.expect(!life.retire()); // stop/reaper races request A
    try std.testing.expect(!life.reserve()); // B must not overwrite A
    life.acquire(); // another already-admitted request
    life.release();
    try std.testing.expect(!life.retire());
    life.release();
    try std.testing.expect(life.retire());
    try std.testing.expect(life.reserve()); // B may now own the slot
    try std.testing.expectEqual(@as(usize, 1), life.pins);
}
