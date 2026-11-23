//! Pure DLNA / UPnP AV media-renderer control: SSDP discovery packets, device
//! description parsing, SOAP envelopes for AVTransport, SOAP response and
//! fault parsing, HH:MM:SS times, and the minimal HTTP/1.1 framing cast_net
//! uses to talk to a renderer. No I/O; cast_net.zig routes through these.
//!
//! References: UPnP Device Architecture 1.1 (SSDP M-SEARCH, description XML,
//! SOAP control) and UPnP AV AVTransport:1 (SetAVTransportURI, Play, Pause,
//! Stop, Seek REL_TIME, GetPositionInfo, GetTransportInfo).

const std = @import("std");

pub const ssdp_group = "239.255.255.250";
pub const ssdp_port: u16 = 1900;
pub const av_transport = "urn:schemas-upnp-org:service:AVTransport:1";
pub const media_renderer = "urn:schemas-upnp-org:device:MediaRenderer:1";

// ── SSDP ───────────────────────────────────────────────────────────────────

pub fn buildMsearch(buf: []u8, host: []const u8, port: u16, st: []const u8, mx: u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "M-SEARCH * HTTP/1.1\r\nHOST: {s}:{d}\r\nMAN: \"ssdp:discover\"\r\nMX: {d}\r\nST: {s}\r\nUSER-AGENT: Opal/1 UPnP/1.1 Opal/1\r\n\r\n", .{ host, port, mx, st }) catch null;
}

/// Value of header `name` (case-insensitive) in an HTTP-style head.
pub fn header(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\n");
    _ = lines.next();
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name))
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

pub const SsdpHit = struct {
    location: []const u8,
    usn: []const u8,
    st: []const u8,
};

/// An M-SEARCH answer ("HTTP/1.1 200 OK" with LOCATION). NOTIFY packets and
/// other noise return null.
pub fn parseSsdpResponse(text: []const u8) ?SsdpHit {
    if (!std.mem.startsWith(u8, text, "HTTP/1.1 200") and !std.mem.startsWith(u8, text, "HTTP/1.0 200")) return null;
    const loc = header(text, "location") orelse return null;
    if (!std.mem.startsWith(u8, loc, "http://")) return null;
    return .{ .location = loc, .usn = header(text, "usn") orelse "", .st = header(text, "st") orelse "" };
}

// ── URLs ───────────────────────────────────────────────────────────────────

pub const HttpUrl = struct {
    host: []const u8,
    port: u16,
    /// Path + query, always starting with '/'.
    path: []const u8,
};

/// Split a plain http:// URL. IPv6 literals are not supported (renderers on
/// a home LAN announce IPv4 locations).
pub fn parseHttpUrl(url: []const u8) ?HttpUrl {
    if (!std.mem.startsWith(u8, url, "http://")) return null;
    const rest = url["http://".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return null;
    var host = authority;
    var port: u16 = 80;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |c| {
        host = authority[0..c];
        port = std.fmt.parseInt(u16, authority[c + 1 ..], 10) catch return null;
    }
    if (host.len == 0) return null;
    return .{ .host = host, .port = port, .path = if (slash < rest.len) rest[slash..] else "/" };
}

/// Absolute URL for `ref` found in the description at `base` (URLBase or the
/// LOCATION). Absolute refs pass through.
pub fn resolveUrl(base: []const u8, ref: []const u8, out: []u8) ?[]const u8 {
    if (std.mem.startsWith(u8, ref, "http://")) {
        if (ref.len > out.len) return null;
        @memcpy(out[0..ref.len], ref);
        return out[0..ref.len];
    }
    const b = parseHttpUrl(base) orelse return null;
    if (ref.len > 0 and ref[0] == '/')
        return std.fmt.bufPrint(out, "http://{s}:{d}{s}", .{ b.host, b.port, ref }) catch null;
    const dir_end = (std.mem.lastIndexOfScalar(u8, b.path, '/') orelse 0) + 1;
    return std.fmt.bufPrint(out, "http://{s}:{d}{s}{s}", .{ b.host, b.port, b.path[0..dir_end], ref }) catch null;
}

// ── XML ────────────────────────────────────────────────────────────────────

pub fn writeXmlEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&apos;"),
        else => try w.writeByte(ch),
    };
}

/// Text of the first `<tag>` element (any namespace prefix) after `from`.
/// Returns the raw (still escaped) inner text and the index after the close tag.
fn elementFrom(xml: []const u8, tag: []const u8, from: usize) ?struct { text: []const u8, end: usize } {
    var i = from;
    while (std.mem.indexOfScalarPos(u8, xml, i, '<')) |lt| {
        i = lt + 1;
        if (lt + 1 >= xml.len or xml[lt + 1] == '/' or xml[lt + 1] == '?' or xml[lt + 1] == '!') continue;
        const name_end = std.mem.indexOfAnyPos(u8, xml, lt + 1, " \t\r\n/>") orelse return null;
        const qname = xml[lt + 1 .. name_end];
        const local = if (std.mem.indexOfScalar(u8, qname, ':')) |c| qname[c + 1 ..] else qname;
        if (!std.mem.eql(u8, local, tag)) continue;
        const gt = std.mem.indexOfScalarPos(u8, xml, name_end, '>') orelse return null;
        if (xml[gt - 1] == '/') return .{ .text = "", .end = gt + 1 };
        // Close tag uses the same qualified name.
        var close_buf: [80]u8 = undefined;
        const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{qname}) catch return null;
        const ce = std.mem.indexOfPos(u8, xml, gt + 1, close) orelse return null;
        return .{ .text = xml[gt + 1 .. ce], .end = ce + close.len };
    }
    return null;
}

pub fn element(xml: []const u8, tag: []const u8) ?[]const u8 {
    const e = elementFrom(xml, tag, 0) orelse return null;
    return std.mem.trim(u8, e.text, " \t\r\n");
}

/// Decode the five predefined XML entities and numeric references into `out`.
pub fn xmlUnescape(s: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < out.len) {
        if (s[i] == '&') {
            if (std.mem.indexOfScalarPos(u8, s, i, ';')) |semi| if (semi - i <= 8) {
                const ent = s[i + 1 .. semi];
                const ch: ?u8 = if (std.mem.eql(u8, ent, "amp")) '&' else if (std.mem.eql(u8, ent, "lt")) '<' else if (std.mem.eql(u8, ent, "gt")) '>' else if (std.mem.eql(u8, ent, "quot")) '"' else if (std.mem.eql(u8, ent, "apos")) '\'' else if (ent.len > 1 and ent[0] == '#') blk: {
                    const v = if (ent[1] == 'x') std.fmt.parseInt(u8, ent[2..], 16) catch null else std.fmt.parseInt(u8, ent[1..], 10) catch null;
                    break :blk v;
                } else null;
                if (ch) |c| {
                    out[n] = c;
                    n += 1;
                    i = semi + 1;
                    continue;
                }
            };
        }
        out[n] = s[i];
        n += 1;
        i += 1;
    }
    return out[0..n];
}

pub const Renderer = struct {
    name: [96]u8 = std.mem.zeroes([96]u8),
    name_len: usize = 0,
    /// Absolute AVTransport control URL.
    control: [512]u8 = std.mem.zeroes([512]u8),
    control_len: usize = 0,
    udn: [96]u8 = std.mem.zeroes([96]u8),
    udn_len: usize = 0,

    pub fn nameSlice(self: *const Renderer) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn controlSlice(self: *const Renderer) []const u8 {
        return self.control[0..self.control_len];
    }
    pub fn udnSlice(self: *const Renderer) []const u8 {
        return self.udn[0..self.udn_len];
    }
};

/// Renderer from a device description, or null when it has no AVTransport
/// service. Embedded devices are searched too (the service list is scanned
/// across the whole document).
pub fn parseDescription(xml: []const u8, location: []const u8) ?Renderer {
    var r = Renderer{};
    const name = xmlUnescape(element(xml, "friendlyName") orelse "", &r.name);
    r.name_len = name.len;
    const udn = xmlUnescape(element(xml, "UDN") orelse "", &r.udn);
    r.udn_len = udn.len;
    const base = element(xml, "URLBase") orelse location;
    var pos: usize = 0;
    while (elementFrom(xml, "service", pos)) |svc| {
        pos = svc.end;
        const st = element(svc.text, "serviceType") orelse continue;
        if (!std.mem.startsWith(u8, st, "urn:schemas-upnp-org:service:AVTransport:")) continue;
        const ctrl_raw = element(svc.text, "controlURL") orelse continue;
        var ctrl_buf: [512]u8 = undefined;
        const ctrl = xmlUnescape(ctrl_raw, &ctrl_buf);
        const abs = resolveUrl(base, ctrl, &r.control) orelse continue;
        r.control_len = abs.len;
        if (r.name_len == 0) {
            const fallback = "DLNA renderer";
            @memcpy(r.name[0..fallback.len], fallback);
            r.name_len = fallback.len;
        }
        return r;
    }
    return null;
}

// ── SOAP ───────────────────────────────────────────────────────────────────

pub const Arg = struct { name: []const u8, value: []const u8 };

/// AVTransport SOAP request body for `action` with already-plain `args`
/// (values are XML-escaped here).
pub fn soapEnvelope(buf: []u8, action: []const u8, args: []const Arg) ?[]const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.print("<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:{s} xmlns:u=\"{s}\">", .{ action, av_transport }) catch return null;
    for (args) |a| {
        w.print("<{s}>", .{a.name}) catch return null;
        writeXmlEscaped(&w, a.value) catch return null;
        w.print("</{s}>", .{a.name}) catch return null;
    }
    w.print("</u:{s}></s:Body></s:Envelope>", .{action}) catch return null;
    return w.buffered();
}

/// `"urn:...:AVTransport:1#Action"` for the SOAPACTION header.
pub fn soapActionHeader(buf: []u8, action: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "\"{s}#{s}\"", .{ av_transport, action }) catch null;
}

/// DIDL-Lite metadata for SetAVTransportURI (many TVs refuse an empty one).
pub fn didlLite(buf: []u8, title: []const u8, url: []const u8, mime: []const u8) ?[]const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.writeAll("<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\"><item id=\"0\" parentID=\"-1\" restricted=\"1\"><dc:title>") catch return null;
    writeXmlEscaped(&w, if (title.len > 0) title else "Opal") catch return null;
    w.print("</dc:title><upnp:class>{s}</upnp:class><res protocolInfo=\"http-get:*:", .{if (std.mem.startsWith(u8, mime, "audio/")) "object.item.audioItem.musicTrack" else "object.item.videoItem"}) catch return null;
    writeXmlEscaped(&w, mime) catch return null;
    w.writeAll(":*\">") catch return null;
    writeXmlEscaped(&w, url) catch return null;
    w.writeAll("</res></item></DIDL-Lite>") catch return null;
    return w.buffered();
}

/// "H:MM:SS" as AVTransport REL_TIME wants it.
pub fn formatHms(secs_f: f64, buf: []u8) []const u8 {
    const total: u64 = if (std.math.isFinite(secs_f) and secs_f > 0 and secs_f < 360000) @intFromFloat(secs_f) else 0;
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ total / 3600, (total % 3600) / 60, total % 60 }) catch "0:00:00";
}

/// Seconds from "H+:MM:SS[.F+]" (or "MM:SS"); null for NOT_IMPLEMENTED etc.
pub fn parseHms(text: []const u8) ?f64 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    var parts: [3]f64 = .{ 0, 0, 0 };
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, t, ':');
    while (it.next()) |p| {
        if (n >= 3 or p.len == 0) return null;
        parts[n] = std.fmt.parseFloat(f64, p) catch return null;
        if (parts[n] < 0) return null;
        n += 1;
    }
    return switch (n) {
        2 => parts[0] * 60 + parts[1],
        3 => parts[0] * 3600 + parts[1] * 60 + parts[2],
        else => null,
    };
}

pub const TransportState = enum {
    unknown,
    stopped,
    playing,
    paused,
    transitioning,
    no_media,

    pub fn parse(s: []const u8) TransportState {
        if (std.mem.eql(u8, s, "PLAYING")) return .playing;
        if (std.mem.eql(u8, s, "PAUSED_PLAYBACK") or std.mem.eql(u8, s, "PAUSED_RECORDING")) return .paused;
        if (std.mem.eql(u8, s, "STOPPED")) return .stopped;
        if (std.mem.eql(u8, s, "TRANSITIONING")) return .transitioning;
        if (std.mem.eql(u8, s, "NO_MEDIA_PRESENT")) return .no_media;
        return .unknown;
    }
};

pub const Fault = struct { code: []const u8, description: []const u8 };

/// UPnP error from a SOAP fault body, or null when it is not a fault.
pub fn soapFault(xml: []const u8) ?Fault {
    if (element(xml, "Fault") == null) return null;
    return .{ .code = element(xml, "errorCode") orelse "", .description = element(xml, "errorDescription") orelse (element(xml, "faultstring") orelse "") };
}

/// The sequence of SOAP actions that starts playback at `start_secs`.
pub const LoadStep = enum { set_uri, play, seek };
pub fn loadPlan(start_secs: f64) []const LoadStep {
    const with_seek = [_]LoadStep{ .set_uri, .play, .seek };
    return if (std.math.isFinite(start_secs) and start_secs >= 1) &with_seek else with_seek[0..2];
}

// ── HTTP/1.1 framing ───────────────────────────────────────────────────────

pub fn buildRequest(buf: []u8, method: []const u8, u: HttpUrl, extra_headers: []const u8, body: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s} {s} HTTP/1.1\r\nHost: {s}:{d}\r\nUser-Agent: Opal/1 UPnP/1.1\r\nConnection: close\r\n{s}Content-Length: {d}\r\n\r\n{s}", .{ method, u.path, u.host, u.port, extra_headers, body.len, body }) catch null;
}

pub const Response = struct { status: u16, body: []const u8 };

/// Status and body of a complete response read to EOF. Chunked bodies are
/// de-chunked into `scratch`.
pub fn parseResponse(raw: []const u8, scratch: []u8) ?Response {
    if (!std.mem.startsWith(u8, raw, "HTTP/1.")) return null;
    const sp = std.mem.indexOfScalar(u8, raw, ' ') orelse return null;
    if (sp + 4 > raw.len) return null;
    const status = std.fmt.parseInt(u16, raw[sp + 1 .. sp + 4], 10) catch return null;
    const head_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return null;
    const head = raw[0..head_end];
    var body = raw[head_end + 4 ..];
    if (header(head, "transfer-encoding")) |te| if (std.ascii.findIgnoreCase(te, "chunked") != null) {
        var n: usize = 0;
        var rest = body;
        while (true) {
            const eol = std.mem.indexOf(u8, rest, "\r\n") orelse break;
            const line = rest[0..eol];
            const semi = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
            const size = std.fmt.parseInt(usize, std.mem.trim(u8, line[0..semi], " "), 16) catch return null;
            rest = rest[eol + 2 ..];
            if (size == 0) break;
            if (size > rest.len or n + size > scratch.len) return null;
            @memcpy(scratch[n .. n + size], rest[0..size]);
            n += size;
            rest = rest[size..];
            if (std.mem.startsWith(u8, rest, "\r\n")) rest = rest[2..];
        }
        return .{ .status = status, .body = scratch[0..n] };
    };
    if (header(head, "content-length")) |cl| {
        const len = std.fmt.parseInt(usize, cl, 10) catch return null;
        if (len < body.len) body = body[0..len];
    }
    return .{ .status = status, .body = body };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "M-SEARCH packet" {
    var buf: [256]u8 = undefined;
    const p = buildMsearch(&buf, ssdp_group, ssdp_port, av_transport, 2).?;
    try testing.expect(std.mem.startsWith(u8, p, "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n"));
    try testing.expect(std.mem.indexOf(u8, p, "MAN: \"ssdp:discover\"\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, p, "ST: urn:schemas-upnp-org:service:AVTransport:1\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, p, "\r\n\r\n"));
}

test "SSDP response parsing is case-insensitive and ignores NOTIFY" {
    const r = parseSsdpResponse("HTTP/1.1 200 OK\r\nCache-Control: max-age=1800\r\nlocation: http://192.168.1.7:49152/desc.xml\r\nST: urn:schemas-upnp-org:service:AVTransport:1\r\nUSN: uuid:abc::urn:x\r\n\r\n").?;
    try testing.expectEqualStrings("http://192.168.1.7:49152/desc.xml", r.location);
    try testing.expectEqualStrings("uuid:abc::urn:x", r.usn);
    try testing.expect(parseSsdpResponse("NOTIFY * HTTP/1.1\r\nLOCATION: http://x/\r\n\r\n") == null);
    try testing.expect(parseSsdpResponse("HTTP/1.1 200 OK\r\nLOCATION: ftp://x/\r\n\r\n") == null);
}

test "parseHttpUrl and resolveUrl" {
    const u = parseHttpUrl("http://10.0.0.4:8200/rootDesc.xml").?;
    try testing.expectEqualStrings("10.0.0.4", u.host);
    try testing.expectEqual(@as(u16, 8200), u.port);
    try testing.expectEqualStrings("/rootDesc.xml", u.path);
    try testing.expectEqual(@as(u16, 80), parseHttpUrl("http://tv.lan").?.port);
    try testing.expect(parseHttpUrl("https://x/") == null);
    try testing.expect(parseHttpUrl("http://u:p@x/") == null);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("http://10.0.0.4:8200/ctl/AVT", resolveUrl("http://10.0.0.4:8200/rootDesc.xml", "/ctl/AVT", &buf).?);
    try testing.expectEqualStrings("http://10.0.0.4:8200/dev/AVT/control", resolveUrl("http://10.0.0.4:8200/dev/desc.xml", "AVT/control", &buf).?);
    try testing.expectEqualStrings("http://other:1/x", resolveUrl("http://10.0.0.4/", "http://other:1/x", &buf).?);
}

const sample_description =
    \\<?xml version="1.0"?>
    \\<root xmlns="urn:schemas-upnp-org:device-1-0">
    \\ <specVersion><major>1</major><minor>0</minor></specVersion>
    \\ <device>
    \\  <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    \\  <friendlyName>Living Room &amp; Den TV</friendlyName>
    \\  <UDN>uuid:1234-abcd</UDN>
    \\  <serviceList>
    \\   <service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><controlURL>/RC/control</controlURL></service>
    \\   <service>
    \\    <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
    \\    <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
    \\    <controlURL>AVTransport/control</controlURL>
    \\    <eventSubURL/>
    \\   </service>
    \\  </serviceList>
    \\ </device>
    \\</root>
;

test "parseDescription finds AVTransport and resolves a relative controlURL" {
    const r = parseDescription(sample_description, "http://192.168.1.7:49152/upnp/desc.xml").?;
    try testing.expectEqualStrings("Living Room & Den TV", r.nameSlice());
    try testing.expectEqualStrings("http://192.168.1.7:49152/upnp/AVTransport/control", r.controlSlice());
    try testing.expectEqualStrings("uuid:1234-abcd", r.udnSlice());
}

test "parseDescription: URLBase wins, missing AVTransport is not a renderer" {
    const with_base = "<root><URLBase>http://10.1.1.1:9000/</URLBase><device><friendlyName>X</friendlyName><serviceList><service><serviceType>urn:schemas-upnp-org:service:AVTransport:2</serviceType><controlURL>/avt</controlURL></service></serviceList></device></root>";
    const r = parseDescription(with_base, "http://10.1.1.1:5000/d.xml").?;
    try testing.expectEqualStrings("http://10.1.1.1:9000/avt", r.controlSlice());
    try testing.expect(parseDescription("<root><device><friendlyName>NAS</friendlyName><serviceList><service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType><controlURL>/cd</controlURL></service></serviceList></device></root>", "http://x/") == null);
}

test "soapEnvelope escapes argument values" {
    var buf: [1024]u8 = undefined;
    const env = soapEnvelope(&buf, "SetAVTransportURI", &.{
        .{ .name = "InstanceID", .value = "0" },
        .{ .name = "CurrentURI", .value = "http://h/a?x=1&y=<2>" },
    }).?;
    try testing.expect(std.mem.indexOf(u8, env, "<u:SetAVTransportURI xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\"><InstanceID>0</InstanceID>") != null);
    try testing.expect(std.mem.indexOf(u8, env, "<CurrentURI>http://h/a?x=1&amp;y=&lt;2&gt;</CurrentURI>") != null);
    try testing.expect(std.mem.endsWith(u8, env, "</u:SetAVTransportURI></s:Body></s:Envelope>"));
    var hb: [96]u8 = undefined;
    try testing.expectEqualStrings("\"urn:schemas-upnp-org:service:AVTransport:1#Play\"", soapActionHeader(&hb, "Play").?);
}

test "didlLite carries title, mime and URL, escaped" {
    var buf: [1024]u8 = undefined;
    const d = didlLite(&buf, "A & B", "http://h/x.mkv?t=1&s=2", "video/x-matroska").?;
    try testing.expect(std.mem.indexOf(u8, d, "<dc:title>A &amp; B</dc:title>") != null);
    try testing.expect(std.mem.indexOf(u8, d, "protocolInfo=\"http-get:*:video/x-matroska:*\">http://h/x.mkv?t=1&amp;s=2</res>") != null);
    try testing.expect(std.mem.indexOf(u8, d, "object.item.videoItem") != null);
    try testing.expect(std.mem.indexOf(u8, didlLite(&buf, "", "u", "audio/mpeg").?, "musicTrack") != null);
}

test "formatHms / parseHms" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("1:02:03", formatHms(3723.9, &buf));
    try testing.expectEqualStrings("0:00:00", formatHms(-5, &buf));
    try testing.expectEqual(@as(?f64, 3723), parseHms("01:02:03"));
    try testing.expectEqual(@as(?f64, 3723.5), parseHms("1:02:03.500"));
    try testing.expectEqual(@as(?f64, 75), parseHms("01:15"));
    try testing.expect(parseHms("NOT_IMPLEMENTED") == null);
    try testing.expect(parseHms("") == null);
}

test "SOAP responses: position, transport state and faults" {
    const pos = "<s:Envelope><s:Body><u:GetPositionInfoResponse xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\"><Track>1</Track><TrackDuration>0:42:10</TrackDuration><RelTime>0:01:05</RelTime></u:GetPositionInfoResponse></s:Body></s:Envelope>";
    try testing.expectEqual(@as(?f64, 65), parseHms(element(pos, "RelTime").?));
    try testing.expectEqual(@as(?f64, 2530), parseHms(element(pos, "TrackDuration").?));
    try testing.expect(soapFault(pos) == null);
    const ti = "<s:Envelope><s:Body><u:GetTransportInfoResponse><CurrentTransportState>PAUSED_PLAYBACK</CurrentTransportState></u:GetTransportInfoResponse></s:Body></s:Envelope>";
    try testing.expectEqual(TransportState.paused, TransportState.parse(element(ti, "CurrentTransportState").?));
    const fault = "<s:Envelope><s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail><UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\"><errorCode>716</errorCode><errorDescription>Resource not found</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>";
    const f = soapFault(fault).?;
    try testing.expectEqualStrings("716", f.code);
    try testing.expectEqualStrings("Resource not found", f.description);
}

test "loadPlan seeks only when starting past the first second" {
    try testing.expectEqualSlices(LoadStep, &.{ .set_uri, .play }, loadPlan(0));
    try testing.expectEqualSlices(LoadStep, &.{ .set_uri, .play, .seek }, loadPlan(90));
    try testing.expectEqualSlices(LoadStep, &.{ .set_uri, .play }, loadPlan(std.math.nan(f64)));
}

test "buildRequest and parseResponse (content-length and chunked)" {
    var buf: [512]u8 = undefined;
    const req = buildRequest(&buf, "POST", parseHttpUrl("http://10.0.0.2:1400/AVT").?, "SOAPACTION: \"x#Play\"\r\n", "<b/>").?;
    try testing.expect(std.mem.startsWith(u8, req, "POST /AVT HTTP/1.1\r\nHost: 10.0.0.2:1400\r\n"));
    try testing.expect(std.mem.indexOf(u8, req, "Content-Length: 4\r\n\r\n<b/>") != null);
    var scratch: [64]u8 = undefined;
    const r = parseResponse("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello-extra", &scratch).?;
    try testing.expectEqual(@as(u16, 200), r.status);
    try testing.expectEqualStrings("hello", r.body);
    const c = parseResponse("HTTP/1.1 500 Internal Server Error\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5;ext=1\r\npedia\r\n0\r\n\r\n", &scratch).?;
    try testing.expectEqual(@as(u16, 500), c.status);
    try testing.expectEqualStrings("Wikipedia", c.body);
    try testing.expect(parseResponse("garbage", &scratch) == null);
}

test "xmlUnescape" {
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("a&b<c>\"d' e", xmlUnescape("a&amp;b&lt;c&gt;&quot;d&apos;&#32;e", &out));
    try testing.expectEqualStrings("& alone", xmlUnescape("& alone", &out));
}
