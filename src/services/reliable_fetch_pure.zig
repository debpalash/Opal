//! Pure curl / curl-impersonate argv construction for the unified reliable-fetch
//! seam — one place every source's HTTP argv is assembled, with browser TLS
//! impersonation + DPI-proxy chaining + first-class headers. The impure fetch()
//! routes through build() so the shipped command is the tested command.

const std = @import("std");

pub const Header = struct { name: []const u8, value: []const u8 };

/// One multipart/form-data field. `file` = upload the file at `value`
/// (`-F name=@path`); otherwise `value` is a literal (`--form-string`, so a
/// leading '@' / '<' is never treated as a file reference).
pub const FormField = struct { name: []const u8, value: []const u8, file: bool = false };

/// HTTP success policy shared by the typed request result and the convenience
/// `fetch` path. Redirects count because callers may deliberately disable
/// follow_redirects; client/server error documents never count as content.
pub fn successfulStatus(status: u16) bool {
    return status >= 200 and status < 400;
}

pub const Spec = struct {
    /// Resolved binary: a curl-impersonate wrapper (browser JA3/JA4) or "curl".
    bin: []const u8,
    /// curl-impersonate `--impersonate <token>` (e.g. "chrome131"); "" = plain.
    impersonate_token: []const u8 = "",
    url: []const u8,
    user_agent: ?[]const u8 = null,
    referer: ?[]const u8 = null,
    headers: []const Header = &.{},
    method_post_body: ?[]const u8 = null,
    range: ?[]const u8 = null, // "0-2047" for health probes
    timeout_secs: u32 = 15,
    connect_timeout_secs: u32 = 10,
    follow_redirects: bool = true,
    insecure: bool = false,
    capture_headers: bool = false,
    write_out: ?[]const u8 = null,
    /// Explicit HTTP method (`-X`), e.g. "POST" with no body, "DELETE".
    method: ?[]const u8 = null,
    /// Read extra directives (secret headers / basic auth / secret body) from
    /// stdin (`--config -`) so they never appear in argv / process listings.
    config_stdin: bool = false,
    /// Upload the request body from a file (`--data-binary @path`) — large or
    /// binary bodies (WAV, embeddings) stay off argv.
    post_body_file: ?[]const u8 = null,
    /// multipart/form-data fields (implies POST).
    form: []const FormField = &.{},
    /// Write the body to a file (`-o path`) instead of stdout (downloads).
    output_path: ?[]const u8 = null,
    /// Restrict the request and every redirect hop to https.
    https_only: bool = false,
    /// Abort (curl exit 63) when the advertised body exceeds this many bytes.
    max_filesize: ?u64 = null,
    /// Disable curl's output buffering (`-N`) so streamed (SSE) bytes reach
    /// the reader as soon as they arrive.
    no_buffer: bool = false,
};

/// Append the full argv for `spec` into `out` (allocating formatted args from
/// `arena`). `proxy_args` (e.g. dpi_bypass.proxyArgs() → `--socks5-hostname
/// 127.0.0.1:8881`, or `&.{}`) chains the DPI proxy — orthogonal to the TLS
/// impersonation, both can be on. URL is always last.
pub fn build(arena: std.mem.Allocator, spec: Spec, proxy_args: []const []const u8, out: *std.ArrayList([]const u8)) !void {
    // A URL (or file path) beginning with '-' would be parsed as a curl option.
    if (std.mem.startsWith(u8, spec.url, "-")) return error.InvalidUrl;
    if (spec.output_path) |p| if (std.mem.startsWith(u8, p, "-")) return error.InvalidUrl;
    try out.append(arena, spec.bin);
    try out.append(arena, "-sS"); // silent, but surface errors
    try out.append(arena, "--compressed"); // gzip/br — most hosts serve it
    if (spec.follow_redirects) try out.append(arena, "-L");
    if (spec.insecure) try out.append(arena, "-k");
    if (spec.no_buffer) try out.append(arena, "-N");

    // Browser TLS/HTTP2 impersonation (curl-impersonate). Omitted for plain curl.
    if (spec.impersonate_token.len > 0) {
        try out.append(arena, "--impersonate");
        try out.append(arena, spec.impersonate_token);
    }

    try out.append(arena, "--max-time");
    try out.append(arena, try std.fmt.allocPrint(arena, "{d}", .{spec.timeout_secs}));
    try out.append(arena, "--connect-timeout");
    try out.append(arena, try std.fmt.allocPrint(arena, "{d}", .{spec.connect_timeout_secs}));

    if (spec.https_only) {
        try out.append(arena, "--proto");
        try out.append(arena, "=https");
        try out.append(arena, "--proto-redir");
        try out.append(arena, "=https");
    }
    if (spec.max_filesize) |m| {
        try out.append(arena, "--max-filesize");
        try out.append(arena, try std.fmt.allocPrint(arena, "{d}", .{m}));
    }

    if (spec.range) |r| {
        try out.append(arena, "-r");
        try out.append(arena, r);
    }

    if (spec.capture_headers) {
        try out.append(arena, "--dump-header");
        try out.append(arena, "-");
    }
    if (spec.write_out) |format| {
        try out.append(arena, "--write-out");
        try out.append(arena, format);
    }

    // User-Agent: force it for plain curl; when impersonating, only if the caller
    // overrides (else curl-impersonate's authentic UA wins).
    if (spec.impersonate_token.len == 0) {
        try out.append(arena, "-A");
        try out.append(arena, spec.user_agent orelse "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
    } else if (spec.user_agent) |ua| {
        try out.append(arena, "-A");
        try out.append(arena, ua);
    }

    if (spec.referer) |ref| {
        try out.append(arena, "-H");
        try out.append(arena, try std.fmt.allocPrint(arena, "Referer: {s}", .{ref}));
    }
    for (spec.headers) |h| {
        try out.append(arena, "-H");
        try out.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ h.name, h.value }));
    }

    if (spec.method) |m| {
        try out.append(arena, "-X");
        try out.append(arena, m);
    }
    // Secret directives arrive on stdin. Ordered after the public headers so a
    // config-supplied header is additive, never replaced by argv.
    if (spec.config_stdin) {
        try out.append(arena, "--config");
        try out.append(arena, "-");
    }
    if (spec.method_post_body) |body| {
        try out.append(arena, "--data-binary");
        try out.append(arena, body);
    } else if (spec.post_body_file) |path| {
        try out.append(arena, "--data-binary");
        try out.append(arena, try std.fmt.allocPrint(arena, "@{s}", .{path}));
    }
    for (spec.form) |f| {
        if (f.name.len == 0 or std.mem.indexOfAny(u8, f.name, "=;\"") != null) return error.InvalidForm;
        if (f.file) {
            // curl -F parses ';' / ',' / '"' after @path as type/filename params.
            if (f.value.len == 0 or std.mem.indexOfAny(u8, f.value, ";,\"") != null) return error.InvalidForm;
            try out.append(arena, "-F");
            try out.append(arena, try std.fmt.allocPrint(arena, "{s}=@{s}", .{ f.name, f.value }));
        } else {
            try out.append(arena, "--form-string");
            try out.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ f.name, f.value }));
        }
    }
    if (spec.output_path) |path| {
        try out.append(arena, "-o");
        try out.append(arena, path);
    }

    // DPI proxy (SNI-fragmenting SOCKS5) — chained onto the impersonated request.
    for (proxy_args) |a| try out.append(arena, a);

    // An empty url means the URL travels in the stdin config (it carries a
    // key in its query string) — see ConfigSpec.url.
    if (spec.url.len > 0) try out.append(arena, spec.url);
}

// ── curl `--config -` text (secrets on stdin, never argv) ──

pub const ConfigSpec = struct {
    /// Headers whose values are credentials (Authorization, Api-Key, ...).
    headers: []const Header = &.{},
    /// "user:password" for HTTP basic auth (`user = ...`).
    basic_auth: ?[]const u8 = null,
    /// Request body carried in the config (`data-binary = ...`). Text only:
    /// curl's config syntax cannot represent NUL — use post_body_file for that.
    body: ?[]const u8 = null,
    /// URL whose query string carries a credential (`url = ...`); the argv
    /// then has no URL at all.
    url: ?[]const u8 = null,
};

pub const ConfigError = error{ InvalidHeader, InvalidValue, OutOfMemory };

/// Append `key = "value"\n` using curl's config quoting (tool_parsecfg.c
/// unslashquote): `\` and `"` are backslash-escaped, `\n` `\r` `\t` use their
/// escape letters so a raw newline can't end the line and inject a directive.
/// `allow_controls` = false (headers / auth) rejects every control byte — a
/// CR/LF in a header value would otherwise split the HTTP header on the wire.
pub fn appendConfigValue(arena: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, value: []const u8, allow_controls: bool) ConfigError!void {
    try out.appendSlice(arena, key);
    try out.appendSlice(arena, " = \"");
    for (value) |ch| switch (ch) {
        '\\' => try out.appendSlice(arena, "\\\\"),
        '"' => try out.appendSlice(arena, "\\\""),
        '\n', '\r', '\t' => {
            if (!allow_controls) return error.InvalidValue;
            try out.appendSlice(arena, switch (ch) {
                '\n' => "\\n",
                '\r' => "\\r",
                else => "\\t",
            });
        },
        0 => return error.InvalidValue, // curl's line reader stops at NUL
        else => {
            if (!allow_controls and (ch < 0x20 or ch == 0x7f)) return error.InvalidValue;
            try out.append(arena, ch);
        },
    };
    try out.appendSlice(arena, "\"\n");
}

/// Build the full stdin config text. Returns "" when there is nothing secret.
pub fn buildConfig(arena: std.mem.Allocator, spec: ConfigSpec) ConfigError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (spec.headers) |h| {
        if (h.name.len == 0 or std.mem.indexOfAny(u8, h.name, ": \t\r\n") != null) return error.InvalidHeader;
        const line = try std.fmt.allocPrint(arena, "{s}: {s}", .{ h.name, h.value });
        appendConfigValue(arena, &out, "header", line, false) catch |e| return if (e == error.InvalidValue) error.InvalidHeader else e;
    }
    if (spec.basic_auth) |ua| try appendConfigValue(arena, &out, "user", ua, false);
    // data-raw, not data-binary: a body beginning with '@' must never be
    // reinterpreted as "read this local file".
    if (spec.body) |b| try appendConfigValue(arena, &out, "data-raw", b, true);
    if (spec.url) |u| try appendConfigValue(arena, &out, "url", u, false);
    return out.items;
}

/// Body + final status from a response cut off mid-stream (no write-out
/// marker yet): skip the leading `--dump-header` blocks, read the last status
/// line. Null when the header section itself never completed.
pub fn parseHead(raw: []const u8) ?struct { body: []const u8, status: u16 } {
    var pos: usize = 0;
    var status: u16 = 0;
    while (std.mem.startsWith(u8, raw[pos..], "HTTP/")) {
        const rel_end = std.mem.indexOf(u8, raw[pos..], "\r\n\r\n") orelse return null;
        const line_end = std.mem.indexOf(u8, raw[pos..], "\r\n").?;
        var parts = std.mem.tokenizeScalar(u8, raw[pos .. pos + line_end], ' ');
        _ = parts.next();
        status = std.fmt.parseInt(u16, parts.next() orelse "0", 10) catch 0;
        pos += rel_end + 4;
    }
    if (status == 0) return null;
    return .{ .body = raw[pos..], .status = status };
}

/// Download write-out: the body goes to the temp file, stdout carries only
/// the final status code (parsed by parseStatus).
pub const download_write_out = "%{http_code}";

/// Temp sibling for an atomic download: `<dest>.part`. Same directory, so the
/// final rename never crosses a filesystem.
pub fn downloadTempPath(buf: []u8, dest: []const u8) ?[]const u8 {
    if (dest.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}.part", .{dest}) catch null;
}

/// Parse the `%{http_code}` write-out of a download (stdout carries only it).
pub fn parseStatus(raw: []const u8) u16 {
    return std.fmt.parseInt(u16, std.mem.trim(u8, raw, " \r\n\t"), 10) catch 0;
}

/// Byte-offset of the last complete UTF-8 boundary ≤ `n` — a kept head of an
/// oversized body is cut on a char boundary.
pub fn headPrefix(body: []const u8, keep: usize) []const u8 {
    var n = @min(body.len, keep);
    if (n == body.len) return body;
    while (n > 0 and (body[n] & 0xC0) == 0x80) n -= 1;
    return body[0..n];
}

// ── Streaming (line-at-a-time) decoding ──

/// Incremental decoder for the `--dump-header - -N --write-out "\n<marker>…"`
/// stdout of a streamed request. Leading header blocks (redirects / 100
/// Continue) are consumed and set `status`; every body line is handed to the
/// sink without its `\n` (and trailing `\r`); the trailing write-out line is
/// held back and parsed by `finish`. Lines longer than `buf` are cut on a
/// UTF-8 boundary and counted in `truncated_lines` — memory stays bounded.
pub const LineDecoder = struct {
    buf: []u8,
    len: usize = 0,
    overlong: bool = false,
    phase: enum { headers, between_blocks, body } = .headers,
    status: u16 = 0,
    lines: usize = 0,
    truncated_lines: usize = 0,

    /// Feed raw stdout bytes. Returns false as soon as the sink returns false.
    pub fn feed(self: *LineDecoder, bytes: []const u8, ctx: anytype, comptime sink: fn (@TypeOf(ctx), []const u8) bool) bool {
        for (bytes) |b| {
            if (b == '\n') {
                if (!self.endLine(ctx, sink)) return false;
                continue;
            }
            if (self.len < self.buf.len) {
                self.buf[self.len] = b;
                self.len += 1;
            } else self.overlong = true;
        }
        return true;
    }

    fn endLine(self: *LineDecoder, ctx: anytype, comptime sink: fn (@TypeOf(ctx), []const u8) bool) bool {
        var line: []const u8 = self.buf[0..self.len];
        const overlong = self.overlong;
        self.len = 0;
        self.overlong = false;
        if (overlong) {
            line = line[0..trimPartialUtf8(line)]; // capped mid-line: don't split a char
        } else if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }
        switch (self.phase) {
            .headers => {
                if (line.len == 0) {
                    self.phase = .between_blocks;
                } else if (std.mem.startsWith(u8, line, "HTTP/")) {
                    self.status = statusOf(line);
                }
                return true;
            },
            .between_blocks => {
                if (std.mem.startsWith(u8, line, "HTTP/")) {
                    self.phase = .headers;
                    self.status = statusOf(line);
                    return true;
                }
                self.phase = .body;
            },
            .body => {},
        }
        self.lines += 1;
        if (overlong) self.truncated_lines += 1;
        return sink(ctx, line);
    }

    /// End of stream. Parses the held-back write-out line (`<marker>code:secs`);
    /// any other unterminated remainder is delivered to the sink unless
    /// `deliver_rest` is false (aborted streams).
    pub fn finish(self: *LineDecoder, marker: []const u8, deliver_rest: bool, ctx: anytype, comptime sink: fn (@TypeOf(ctx), []const u8) bool) struct { meta: bool, status: u16, latency_ms: u32 } {
        const rest = self.buf[0..self.len];
        if (!self.overlong and std.mem.startsWith(u8, rest, marker)) {
            var fields = std.mem.splitScalar(u8, std.mem.trim(u8, rest[marker.len..], " \r\n"), ':');
            const status = std.fmt.parseInt(u16, fields.next() orelse "", 10) catch 0;
            const seconds = std.fmt.parseFloat(f64, fields.next() orelse "0") catch 0;
            const latency_ms: u32 = if (seconds > 0) @intFromFloat(@min(seconds * 1000.0, @as(f64, std.math.maxInt(u32)))) else 0;
            self.len = 0;
            if (status != 0) self.status = status;
            return .{ .meta = status != 0, .status = self.status, .latency_ms = latency_ms };
        }
        if (deliver_rest and self.len > 0 and self.phase != .headers) _ = self.endLine(ctx, sink);
        self.len = 0;
        return .{ .meta = false, .status = self.status, .latency_ms = 0 };
    }
};

fn statusOf(line: []const u8) u16 {
    var parts = std.mem.tokenizeScalar(u8, line, ' ');
    _ = parts.next();
    return std.fmt.parseInt(u16, parts.next() orelse "0", 10) catch 0;
}

/// Length of `s` with any incomplete trailing UTF-8 sequence removed.
pub fn trimPartialUtf8(s: []const u8) usize {
    var i = s.len;
    var back: usize = 0;
    while (i > 0 and back < 4) {
        const c = s[i - 1];
        if ((c & 0xC0) != 0x80) {
            const need: usize = if (c < 0x80) 1 else if ((c & 0xE0) == 0xC0) 2 else if ((c & 0xF0) == 0xE0) 3 else if ((c & 0xF8) == 0xF0) 4 else 1;
            return if (back + 1 >= need) s.len else i - 1;
        }
        i -= 1;
        back += 1;
    }
    return s.len;
}

/// Server-Sent Events: the payload of a `data:` field line (one optional
/// leading space stripped, per the SSE spec), else null (comments, `event:`,
/// blank separators).
pub fn sseData(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "data:")) return null;
    const v = line[5..];
    return if (v.len > 0 and v[0] == ' ') v[1..] else v;
}

/// OpenAI-style end-of-stream sentinel (`data: [DONE]`).
pub fn sseDone(data: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, data, " \r"), "[DONE]");
}

pub fn buildAlloc(arena: std.mem.Allocator, spec: Spec, proxy_args: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try build(arena, spec, proxy_args, &out);
    return out.items;
}

// ── Tests ──
fn has(a: []const []const u8, s: []const u8) bool {
    for (a) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}
fn idx(a: []const []const u8, s: []const u8) ?usize {
    for (a, 0..) |x, i| if (std.mem.eql(u8, x, s)) return i;
    return null;
}

test "impersonated request carries the token + no forced UA + url last" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const argv = try buildAlloc(ar.allocator(), .{ .bin = "curl-impersonate-chrome", .impersonate_token = "chrome131", .url = "https://x.test" }, &.{});
    try std.testing.expectEqualStrings("curl-impersonate-chrome", argv[0]);
    try std.testing.expect(has(argv, "--impersonate") and has(argv, "chrome131"));
    try std.testing.expect(!has(argv, "-A")); // authentic UA wins
    try std.testing.expectEqualStrings("https://x.test", argv[argv.len - 1]);
}

test "plain curl forces a UA and omits --impersonate" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const argv = try buildAlloc(ar.allocator(), .{ .bin = "curl", .url = "https://x.test" }, &.{});
    try std.testing.expect(!has(argv, "--impersonate"));
    try std.testing.expect(has(argv, "-A"));
}

test "proxy args + referer + range chain in" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const proxy = [_][]const u8{ "--socks5-hostname", "127.0.0.1:8881" };
    const argv = try buildAlloc(ar.allocator(), .{ .bin = "curl", .url = "https://x/y.m3u8", .referer = "https://x/", .range = "0-2047" }, &proxy);
    const pi = idx(argv, "--socks5-hostname") orelse return error.NoProxy;
    try std.testing.expectEqualStrings("127.0.0.1:8881", argv[pi + 1]);
    try std.testing.expect(has(argv, "Referer: https://x/"));
    const ri = idx(argv, "-r") orelse return error.NoRange;
    try std.testing.expectEqualStrings("0-2047", argv[ri + 1]);
    // url still last, proxy before it.
    try std.testing.expectEqualStrings("https://x/y.m3u8", argv[argv.len - 1]);
    try std.testing.expect(pi < argv.len - 1);
}

test "metadata capture stays before the final URL" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const argv = try buildAlloc(ar.allocator(), .{
        .bin = "curl",
        .url = "https://x.test/a",
        .capture_headers = true,
        .write_out = "\\nOPAL:%{http_code}",
    }, &.{});
    try std.testing.expect(has(argv, "--dump-header"));
    try std.testing.expect(has(argv, "--write-out"));
    try std.testing.expectEqualStrings("https://x.test/a", argv[argv.len - 1]);
}

pub const ParsedOutput = struct {
    body: []const u8,
    headers: []const u8,
    status: u16,
    latency_ms: u32,
};

/// Split the single stdout stream emitted by `--dump-header -` plus the
/// write-out marker. Keeping metadata on the body pipe avoids the classic
/// stdout/stderr two-pipe deadlock. The returned slices alias `raw`.
pub fn parseCapturedOutput(raw: []const u8, marker: []const u8) ?ParsedOutput {
    const meta_pos = std.mem.lastIndexOf(u8, raw, marker) orelse return null;
    var body_end = meta_pos;
    if (body_end > 0 and raw[body_end - 1] == '\n') body_end -= 1;

    const meta = raw[meta_pos + marker.len ..];
    var fields = std.mem.splitScalar(u8, std.mem.trim(u8, meta, " \r\n"), ':');
    const status = std.fmt.parseInt(u16, fields.next() orelse return null, 10) catch return null;
    const seconds = std.fmt.parseFloat(f64, fields.next() orelse "0") catch 0;
    const latency_ms: u32 = if (seconds > 0) @intFromFloat(@min(seconds * 1000.0, @as(f64, std.math.maxInt(u32)))) else 0;

    var pos: usize = 0;
    var final_start: usize = 0;
    var final_end: usize = 0;
    while (pos < body_end and std.mem.startsWith(u8, raw[pos..body_end], "HTTP/")) {
        const rel_end = std.mem.indexOf(u8, raw[pos..body_end], "\r\n\r\n") orelse return null;
        final_start = pos;
        final_end = pos + rel_end + 4;
        pos = final_end;
    }
    return .{
        .body = raw[pos..body_end],
        .headers = raw[final_start..final_end],
        .status = status,
        .latency_ms = latency_ms,
    };
}

test "captured output parser keeps final redirect headers and binary-safe body" {
    const raw = "HTTP/1.1 302 Found\r\nLocation: /b\r\n\r\n" ++
        "HTTP/2 200 OK\r\nContent-Type: text/plain\r\n\r\nhello\x00world\n" ++
        "OPAL_FETCH_META:200:0.125";
    const parsed = parseCapturedOutput(raw, "OPAL_FETCH_META:").?;
    try std.testing.expectEqual(@as(u16, 200), parsed.status);
    try std.testing.expectEqual(@as(u32, 125), parsed.latency_ms);
    try std.testing.expectEqualStrings("HTTP/2 200 OK\r\nContent-Type: text/plain\r\n\r\n", parsed.headers);
    try std.testing.expectEqualSlices(u8, "hello\x00world", parsed.body);
}

test "HTTP success policy rejects non-empty error responses" {
    try std.testing.expect(successfulStatus(200));
    try std.testing.expect(successfulStatus(206));
    try std.testing.expect(successfulStatus(302));
    try std.testing.expect(!successfulStatus(0));
    try std.testing.expect(!successfulStatus(404));
    try std.testing.expect(!successfulStatus(429));
    try std.testing.expect(!successfulStatus(500));
}

test "secret config escapes quotes and backslashes and stays off argv" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const cfg = try buildConfig(a, .{ .headers = &.{.{ .name = "Authorization", .value = "Bearer a\"b\\c" }} });
    try std.testing.expectEqualStrings("header = \"Authorization: Bearer a\\\"b\\\\c\"\n", cfg);
    const argv = try buildAlloc(a, .{ .bin = "curl", .url = "https://x.test", .config_stdin = true }, &.{});
    const ci = idx(argv, "--config") orelse return error.NoConfig;
    try std.testing.expectEqualStrings("-", argv[ci + 1]);
    for (argv) |x| try std.testing.expect(std.mem.indexOf(u8, x, "Bearer") == null);
    try std.testing.expectEqualStrings("https://x.test", argv[argv.len - 1]);
}

test "secret config rejects header injection" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expectError(error.InvalidHeader, buildConfig(a, .{ .headers = &.{.{ .name = "Authorization", .value = "x\noutput = /tmp/pwn" }} }));
    try std.testing.expectError(error.InvalidHeader, buildConfig(a, .{ .headers = &.{.{ .name = "X\r\nY", .value = "v" }} }));
    try std.testing.expectError(error.InvalidValue, buildConfig(a, .{ .basic_auth = "u:p\r" }));
}

test "secret body escapes newlines, keeps @ literal, rejects NUL" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const cfg = try buildConfig(a, .{ .basic_auth = "me:pw", .body = "@etc\n{\"k\":\"v\\n\"}\t" });
    try std.testing.expectEqualStrings("user = \"me:pw\"\ndata-raw = \"@etc\\n{\\\"k\\\":\\\"v\\\\n\\\"}\\t\"\n", cfg);
    try std.testing.expectError(error.InvalidValue, buildConfig(a, .{ .body = "a\x00b" }));
    try std.testing.expectEqualStrings("", try buildConfig(a, .{}));
}

test "method, body file, output, https-only and max-filesize flags" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const argv = try buildAlloc(ar.allocator(), .{
        .bin = "curl",
        .url = "https://x.test/up",
        .method = "PUT",
        .post_body_file = "/tmp/a.wav",
        .output_path = "/tmp/out.part",
        .https_only = true,
        .max_filesize = 1024,
    }, &.{});
    try std.testing.expectEqualStrings("PUT", argv[(idx(argv, "-X") orelse return error.NoMethod) + 1]);
    try std.testing.expectEqualStrings("@/tmp/a.wav", argv[(idx(argv, "--data-binary") orelse return error.NoBody) + 1]);
    try std.testing.expectEqualStrings("/tmp/out.part", argv[(idx(argv, "-o") orelse return error.NoOut) + 1]);
    try std.testing.expectEqualStrings("=https", argv[(idx(argv, "--proto") orelse return error.NoProto) + 1]);
    try std.testing.expectEqualStrings("=https", argv[(idx(argv, "--proto-redir") orelse return error.NoRedir) + 1]);
    try std.testing.expectEqualStrings("1024", argv[(idx(argv, "--max-filesize") orelse return error.NoMax) + 1]);
    try std.testing.expectEqualStrings("https://x.test/up", argv[argv.len - 1]);
}

test "inline post body wins over body file" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const argv = try buildAlloc(ar.allocator(), .{ .bin = "curl", .url = "u", .method_post_body = "{}", .post_body_file = "/f" }, &.{});
    try std.testing.expect(has(argv, "{}") and !has(argv, "@/f"));
}

test "download temp path, status parse, utf8-safe head" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/c/m.gguf.part", downloadTempPath(&b, "/c/m.gguf").?);
    try std.testing.expect(downloadTempPath(&b, "") == null);
    try std.testing.expectEqual(@as(u16, 200), parseStatus("200\n"));
    try std.testing.expectEqual(@as(u16, 0), parseStatus("x"));
    try std.testing.expectEqualStrings("ab", headPrefix("ab\xc3\xa9", 3)); // don't split é
    try std.testing.expectEqualStrings("ab\xc3\xa9", headPrefix("ab\xc3\xa9", 9));
}

test "parseHead keeps the prefix of a cut-off body past redirect headers" {
    const raw = "HTTP/1.1 301 Moved\r\nLocation: /x\r\n\r\nHTTP/2 200\r\nA: b\r\n\r\n<html>magnet:?xt=urn";
    const h = parseHead(raw).?;
    try std.testing.expectEqual(@as(u16, 200), h.status);
    try std.testing.expectEqualStrings("<html>magnet:?xt=urn", h.body);
    try std.testing.expect(parseHead("HTTP/2 200\r\nA: b") == null); // headers incomplete
    try std.testing.expect(parseHead("garbage") == null);
}

test "secret url moves into config and out of argv" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const cfg = try buildConfig(a, .{ .url = "https://api.x/v1?api_key=k\"1" });
    try std.testing.expectEqualStrings("url = \"https://api.x/v1?api_key=k\\\"1\"\n", cfg);
    const argv = try buildAlloc(a, .{ .bin = "curl", .url = "", .config_stdin = true }, &.{});
    for (argv) |x| try std.testing.expect(std.mem.indexOf(u8, x, "api_key") == null);
    try std.testing.expectEqualStrings("-", argv[argv.len - 1]); // `--config -` ends argv
    try std.testing.expectError(error.InvalidValue, buildConfig(a, .{ .url = "https://x/\nuser=a" }));
}

test "option-looking url is rejected, never passed to curl" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    try std.testing.expectError(error.InvalidUrl, buildAlloc(ar.allocator(), .{ .bin = "curl", .url = "--output=/etc/x" }, &.{}));
    try std.testing.expectError(error.InvalidUrl, buildAlloc(ar.allocator(), .{ .bin = "curl", .url = "https://x", .output_path = "-" }, &.{}));
}

test "multipart form: literal fields use --form-string, files -F name=@path" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const argv = try buildAlloc(ar.allocator(), .{ .bin = "curl", .url = "http://l/t", .form = &.{
        .{ .name = "model", .value = "@whisper-1" },
        .{ .name = "file", .value = "/tmp/a.wav", .file = true },
    } }, &.{});
    try std.testing.expectEqualStrings("model=@whisper-1", argv[(idx(argv, "--form-string") orelse return error.NoForm) + 1]);
    try std.testing.expectEqualStrings("file=@/tmp/a.wav", argv[(idx(argv, "-F") orelse return error.NoFile) + 1]);
    try std.testing.expectEqualStrings("http://l/t", argv[argv.len - 1]);
    try std.testing.expectError(error.InvalidForm, buildAlloc(ar.allocator(), .{ .bin = "curl", .url = "u", .form = &.{.{ .name = "f", .value = "/a;type=x", .file = true }} }, &.{}));
    try std.testing.expectError(error.InvalidForm, buildAlloc(ar.allocator(), .{ .bin = "curl", .url = "u", .form = &.{.{ .name = "a=b", .value = "v" }} }, &.{}));
}

const TestSink = struct {
    got: [8][64]u8 = undefined,
    lens: [8]usize = undefined,
    n: usize = 0,
    stop_at: usize = 99,
    fn push(self: *TestSink, line: []const u8) bool {
        const k = @min(line.len, 64);
        @memcpy(self.got[self.n][0..k], line[0..k]);
        self.lens[self.n] = k;
        self.n += 1;
        return self.n < self.stop_at;
    }
    fn at(self: *const TestSink, i: usize) []const u8 {
        return self.got[i][0..self.lens[i]];
    }
};

test "line decoder skips redirect headers, splits chunked body lines, parses meta" {
    var buf: [64]u8 = undefined;
    var d = LineDecoder{ .buf = &buf };
    var sink = TestSink{};
    const raw = "HTTP/1.1 302 Found\r\nLocation: /b\r\n\r\nHTTP/2 200\r\ncontent-type: text/event-stream\r\n\r\n" ++
        "data: {\"a\":1}\n\ndata: [DONE]\n\nOPAL_FETCH_META:200:0.250";
    // Feed in awkward 3-byte chunks: lines must reassemble across reads.
    var i: usize = 0;
    while (i < raw.len) : (i += 3) try std.testing.expect(d.feed(raw[i..@min(i + 3, raw.len)], &sink, TestSink.push));
    const fin = d.finish("OPAL_FETCH_META:", true, &sink, TestSink.push);
    try std.testing.expect(fin.meta);
    try std.testing.expectEqual(@as(u16, 200), fin.status);
    try std.testing.expectEqual(@as(u32, 250), fin.latency_ms);
    try std.testing.expectEqual(@as(usize, 4), sink.n);
    try std.testing.expectEqualStrings("data: {\"a\":1}", sink.at(0));
    try std.testing.expectEqualStrings("", sink.at(1));
    try std.testing.expectEqualStrings("data: [DONE]", sink.at(2));
}

test "line decoder knows status before the body and honours sink abort" {
    var buf: [64]u8 = undefined;
    var d = LineDecoder{ .buf = &buf };
    var sink = TestSink{ .stop_at = 1 };
    try std.testing.expect(!d.feed("HTTP/1.1 401 Unauthorized\r\n\r\n{\"error\":1}\nmore\n", &sink, TestSink.push));
    try std.testing.expectEqual(@as(u16, 401), d.status);
    try std.testing.expectEqual(@as(usize, 1), sink.n);
}

test "line decoder bounds an overlong line on a UTF-8 boundary" {
    var buf: [5]u8 = undefined;
    var d = LineDecoder{ .buf = &buf, .phase = .body };
    var sink = TestSink{};
    // "abcd" + 2-byte é: the cap (5) lands mid-character.
    try std.testing.expect(d.feed("abcd\xc3\xa9xyz\nok\n", &sink, TestSink.push));
    try std.testing.expectEqualStrings("abcd", sink.at(0));
    try std.testing.expectEqualStrings("ok", sink.at(1));
    try std.testing.expectEqual(@as(usize, 1), d.truncated_lines);
}

test "line decoder delivers an unterminated tail only when not aborted" {
    var buf: [32]u8 = undefined;
    var d = LineDecoder{ .buf = &buf, .phase = .body };
    var sink = TestSink{};
    _ = d.feed("partial", &sink, TestSink.push);
    const fin = d.finish("OPAL_FETCH_META:", false, &sink, TestSink.push);
    try std.testing.expect(!fin.meta);
    try std.testing.expectEqual(@as(usize, 0), sink.n);
}

test "sse data field parsing follows the spec" {
    try std.testing.expectEqualStrings("{\"x\":1}", sseData("data: {\"x\":1}").?);
    try std.testing.expectEqualStrings("tight", sseData("data:tight").?);
    try std.testing.expectEqualStrings(" two", sseData("data:  two").?);
    try std.testing.expect(sseData(": keepalive") == null);
    try std.testing.expect(sseData("event: ping") == null);
    try std.testing.expect(sseDone("[DONE]"));
    try std.testing.expect(!sseDone("{}"));
}

test "streaming argv disables buffering" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const argv = try buildAlloc(ar.allocator(), .{ .bin = "curl", .url = "https://x.test", .no_buffer = true }, &.{});
    try std.testing.expect(has(argv, "-N"));
    const plain = try buildAlloc(ar.allocator(), .{ .bin = "curl", .url = "https://x.test" }, &.{});
    try std.testing.expect(!has(plain, "-N"));
}
