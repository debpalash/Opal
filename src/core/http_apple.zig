//! Platform adapter used by the existing HTTP/source modules on iOS.
const std = @import("std");
const alloc = @import("alloc.zig").allocator;
const io = @import("io_global.zig");
const reliable = @import("../services/reliable_fetch.zig");
const Header = reliable.Header;
const NativeRequest = extern struct {
    url: [*:0]const u8,
    method: [*:0]const u8,
    headers_json: [*:0]const u8,
    payload: [*]const u8,
    payload_len: usize,
    body: [*]u8,
    body_capacity: usize,
    body_len: usize = 0,
    headers: [*]u8,
    header_capacity: usize,
    header_len: usize = 0,
    timeout_seconds: u32,
    status: u16 = 0,
    follow_redirects: bool,
    https_only: bool,
    cancelled: *const fn (?*anyopaque) callconv(.c) bool,
    cancel_context: ?*anyopaque,
};
extern fn opal_apple_http_request(request: *NativeRequest) c_int;
fn cancelled(context: ?*anyopaque) callconv(.c) bool {
    const options: *const reliable.Opts = @ptrCast(@alignCast(context.?));
    if (@import("workers.zig").isQuitting()) return true;
    if (options.abort_flag) |flag| if (flag.load(.acquire)) return true;
    return if (options.cancel_epoch) |epoch| epoch.fired() else false;
}
pub fn request(url: []const u8, body: []u8, response_headers: []u8, options: reliable.Opts) reliable.FetchResult {
    if (cancelled(@constCast(&options))) return .{ .failure = .cancelled };
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const allocator = arena.allocator();
    var headers: std.ArrayListUnmanaged(Header) = .empty;
    headers.appendSlice(allocator, options.headers) catch return .{ .failure = .transport };
    headers.appendSlice(allocator, options.secret_headers) catch return .{ .failure = .transport };
    if (options.user_agent) |value| headers.append(allocator, .{ .name = "User-Agent", .value = value }) catch return .{ .failure = .transport };
    if (options.referer) |value| headers.append(allocator, .{ .name = "Referer", .value = value }) catch return .{ .failure = .transport };
    if (options.range) |value| headers.append(allocator, .{ .name = "Range", .value = value }) catch return .{ .failure = .transport };
    if (options.secret_basic_auth) |value| {
        const encoder = std.base64.standard.Encoder;
        const encoded = allocator.alloc(u8, encoder.calcSize(value.len)) catch return .{ .failure = .transport };
        _ = encoder.encode(encoded, value);
        const authorization = std.fmt.allocPrint(allocator, "Basic {s}", .{encoded}) catch return .{ .failure = .transport };
        headers.append(allocator, .{ .name = "Authorization", .value = authorization }) catch return .{ .failure = .transport };
    }
    // Reject invalid header bytes before crossing to Foundation.
    for (headers.items) |header| if (header.name.len == 0 or std.mem.indexOfAny(u8, header.name, ":\r\n") != null or std.mem.indexOfAny(u8, header.value, "\r\n") != null) return .{ .failure = .invalid_input };
    const json = std.json.Stringify.valueAlloc(allocator, headers.items, .{}) catch return .{ .failure = .transport };
    const body_text = options.secret_post_body orelse options.post_body orelse "";
    var native: NativeRequest = .{
        .url = allocator.dupeSentinel(u8, url, 0) catch return .{ .failure = .transport },
        .method = allocator.dupeSentinel(u8, options.method orelse if (body_text.len > 0) "POST" else "GET", 0) catch return .{ .failure = .transport },
        .headers_json = allocator.dupeSentinel(u8, json, 0) catch return .{ .failure = .transport },
        .payload = body_text.ptr,
        .payload_len = body_text.len,
        .body = body.ptr,
        .body_capacity = @min(body.len, options.max_filesize orelse body.len),
        .headers = response_headers.ptr,
        .header_capacity = response_headers.len,
        .timeout_seconds = @min(30, @max(1, options.timeout_secs)),
        .follow_redirects = options.follow_redirects,
        .https_only = options.https_only,
        .cancelled = cancelled,
        .cancel_context = @constCast(&options),
    };
    const started = io.monotonicMilliTimestamp();
    const result = opal_apple_http_request(&native);
    if (result != 0 and result != 5 or native.status >= 400) logFailure(url, result, native.status);
    return .{ .body = body[0..native.body_len], .headers = response_headers[0..native.header_len], .status = native.status, .backend = .native, .latency_ms = @intCast(@max(0, io.monotonicMilliTimestamp() - started)), .failure = switch (result) {
        0 => .none,
        2 => .truncated,
        3 => .timed_out,
        5 => .cancelled,
        else => .transport,
    } };
}
pub fn fetch(url: []const u8, body: []u8, options: @import("http_transport.zig").Options) ?[]const u8 {
    var headers: std.ArrayListUnmanaged(Header) = .empty;
    defer headers.deinit(alloc);
    for (options.extra_headers) |header| headers.append(alloc, .{ .name = header.name, .value = header.value }) catch return null;
    if (options.auth_header) |line| if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
        headers.append(alloc, .{ .name = line[0..colon], .value = std.mem.trim(u8, line[colon + 1 ..], " \t") }) catch return null;
    };
    if (options.accept) |value| headers.append(alloc, .{ .name = "Accept", .value = value }) catch return null;
    if (options.content_type) |value| headers.append(alloc, .{ .name = "Content-Type", .value = value }) catch return null;
    var response_headers: [16384]u8 = undefined;
    const result = request(url, body[0..@min(body.len, options.max_response)], &response_headers, .{
        .headers = headers.items,
        .timeout_secs = options.timeout_secs,
        .user_agent = options.user_agent,
        .referer = options.referer,
        .method = @tagName(options.method),
        .post_body = options.payload,
        .cancel_epoch = options.cancel_epoch,
    });
    if (options.status_out) |out| out.* = if (result.status == 0) null else @fromBackingInt(@intCast(result.status));
    return if (result.ok()) result.body else null;
}

/// iOS `reliable_fetch.download`: Foundation transfer into a bounded heap
/// buffer, then the same atomic `<dest>.part` → `dest` rename as desktop curl.
/// Mobile callers fetch catalogs/subtitles/art, not multi-GB models.
pub fn download(url: []const u8, dest_path: []const u8, options: reliable.Opts) reliable.DownloadResult {
    const pure = @import("../services/reliable_fetch_pure.zig");
    var tmp_buf: [1100]u8 = undefined;
    const tmp = pure.downloadTempPath(&tmp_buf, dest_path) orelse return .{ .failure = .invalid_input };
    const cap: usize = @intCast(@min(options.max_filesize orelse 64 * 1024 * 1024, 64 * 1024 * 1024));
    const body = alloc.alloc(u8, cap) catch return .{ .failure = .transport };
    defer alloc.free(body);
    var headers: [16 * 1024]u8 = undefined;
    const result = request(url, body, &headers, options);
    if (!result.ok()) return .{ .status = result.status, .failure = if (result.failure == .none) .transport else result.failure };
    const dir = std.Io.Dir.cwd();
    dir.writeFile(io.io(), .{ .sub_path = tmp, .data = result.body }) catch return .{ .status = result.status, .failure = .transport };
    std.Io.Dir.rename(dir, tmp, dir, dest_path, io.io()) catch {
        io.cwdDeleteFile(tmp) catch {};
        return .{ .status = result.status, .failure = .transport };
    };
    return .{ .status = result.status };
}

/// Host + failure code only: query strings may carry tokens.
fn logFailure(url: []const u8, code: c_int, status: u16) void {
    var line: [320]u8 = undefined;
    const host_end = if (std.mem.indexOf(u8, url, "://")) |i| (std.mem.indexOfScalarPos(u8, url, i + 3, '/') orelse url.len) else @min(url.len, 80);
    const text = std.fmt.bufPrint(&line, "{s} failed: code={d} status={d}", .{ url[0..@min(host_end, 200)], code, status }) catch "request failed";
    @import("logs.zig").pushLog("warn", "http", text, false);
}
