//! Real loopback stalls, no accounts, credentials, profiles, or provider network.
const std = @import("std");
const io = @import("io_global.zig");
const workers = @import("workers.zig");
const transport = @import("http_transport.zig");

test "Native HTTP connection deadline interrupts stalled TLS before request attachment" {
    workers.init();
    defer workers.finishShutdown();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io.io(), .{ .reuse_address = true });
    defer server.deinit(io.io());
    const Fixture = struct {
        fn run(listener: *std.Io.net.Server) void {
            const stream = listener.accept(io.io()) catch return;
            defer stream.close(io.io());
            // Accept TCP but send no TLS response. Bound the red test itself.
            io.sleep(3 * std.time.ns_per_s);
            stream.shutdown(io.io(), .both) catch {};
        }
    };
    var fixture = try io.io().concurrent(Fixture.run, .{&server});
    defer _ = fixture.cancel(io.io());
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = transport.nativeIo(io.io()) };
    defer client.deinit();
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/", .{server.socket.address.getPort()});
    var body: [1024]u8 = undefined;
    const started = io.monotonicMilliTimestamp();
    try std.testing.expect(transport.fetch(&client, url, &body, .{ .timeout_secs = 1 }) == null);
    const elapsed = io.monotonicMilliTimestamp() - started;
    std.debug.print("TLS deadline fixture elapsed {d}ms\n", .{elapsed});
    try std.testing.expect(elapsed < 1700);
}

fn interruptedTls(shutdown: bool) !void {
    workers.init();
    defer workers.finishShutdown();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io.io(), .{ .reuse_address = true });
    defer server.deinit(io.io());
    var epoch: std.atomic.Value(u32) = .init(1);
    const Fixture = struct {
        fn run(listener: *std.Io.net.Server, token: *std.atomic.Value(u32), stop: bool) void {
            const stream = listener.accept(io.io()) catch return;
            defer stream.close(io.io());
            io.sleep(150 * std.time.ns_per_ms);
            if (stop) workers.markQuitting() else token.store(2, .release);
            io.sleep(1500 * std.time.ns_per_ms);
            stream.shutdown(io.io(), .both) catch {};
        }
    };
    var fixture = try io.io().concurrent(Fixture.run, .{ &server, &epoch, shutdown });
    defer _ = fixture.cancel(io.io());
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = transport.nativeIo(io.io()) };
    defer client.deinit();
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/", .{server.socket.address.getPort()});
    var body: [1024]u8 = undefined;
    const started = io.monotonicMilliTimestamp();
    try std.testing.expect(transport.fetch(&client, url, &body, .{ .timeout_secs = 10, .cancel_epoch = .{ .epoch32 = .{ .value = &epoch, .expected = 1 } } }) == null);
    const elapsed = io.monotonicMilliTimestamp() - started;
    std.debug.print("TLS {s} fixture elapsed {d}ms\n", .{ if (shutdown) "shutdown" else "cancel", elapsed });
    try std.testing.expect(elapsed < 700);
}

test "Native HTTP connection epoch cancellation interrupts stalled TLS" {
    try interruptedTls(false);
}

test "Native HTTP connection shutdown interrupts stalled TLS" {
    try interruptedTls(true);
}

test "Native HTTP connection empty POST sends zero body without bodiless assertion" {
    workers.init();
    defer workers.finishShutdown();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io.io(), .{ .reuse_address = true });
    defer server.deinit(io.io());
    var valid: std.atomic.Value(bool) = .init(false);
    const Fixture = struct {
        fn run(listener: *std.Io.net.Server, result: *std.atomic.Value(bool)) void {
            const stream = listener.accept(io.io()) catch return;
            defer stream.close(io.io());
            var read_buf: [4096]u8 = undefined;
            var reader = stream.reader(io.io(), &read_buf);
            const head = reader.interface.takeDelimiterInclusive('\n') catch return;
            if (!std.mem.startsWith(u8, head, "POST /timeline ")) return;
            var zero = false;
            while (true) {
                const line = reader.interface.takeDelimiterInclusive('\n') catch return;
                if (std.mem.eql(u8, line, "\r\n")) break;
                if (std.ascii.eqlIgnoreCase(line, "content-length: 0\r\n")) zero = true;
            }
            result.store(zero, .release);
            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(io.io(), &write_buf);
            writer.interface.writeAll("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n") catch return;
            writer.interface.flush() catch {};
        }
    };
    var fixture = try io.io().concurrent(Fixture.run, .{ &server, &valid });
    defer _ = fixture.cancel(io.io());
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = transport.nativeIo(io.io()) };
    defer client.deinit();
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/timeline", .{server.socket.address.getPort()});
    var body: [1024]u8 = undefined;
    var status: ?std.http.Status = null;
    const result = transport.fetch(&client, url, &body, .{ .method = .POST, .timeout_secs = 1, .status_out = &status });
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?.len);
    try std.testing.expectEqual(std.http.Status.no_content, status.?);
    try std.testing.expect(valid.load(.acquire));
}

const dns = @import("http_dns_native.zig");
const builtin = @import("builtin");

fn pendingDns(mode: enum { deadline, epoch, shutdown }) !void {
    if (builtin.os.tag != .macos and builtin.os.tag != .windows) return error.SkipZigTest;
    workers.init();
    defer workers.finishShutdown();
    dns.pending_for_test = true;
    defer dns.pending_for_test = false;
    const clean_before = dns.cleaned_for_test.load(.acquire);
    var epoch: std.atomic.Value(u32) = .init(1);
    const Trigger = struct {
        fn run(token: *std.atomic.Value(u32), shutdown: bool) void {
            io.sleep(150 * std.time.ns_per_ms);
            if (shutdown) workers.markQuitting() else token.store(2, .release);
        }
    };
    var trigger: ?std.Thread = null;
    if (mode != .deadline) trigger = try std.Thread.spawn(.{}, Trigger.run, .{ &epoch, mode == .shutdown });
    defer if (trigger) |thread| thread.join();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = transport.nativeIo(io.io()) };
    defer client.deinit();
    var body: [1024]u8 = undefined;
    const started = io.monotonicMilliTimestamp();
    try std.testing.expect(transport.fetch(&client, "https://pending.opal.invalid/", &body, .{ .timeout_secs = if (mode == .deadline) 1 else 10, .cancel_epoch = .{ .epoch32 = .{ .value = &epoch, .expected = 1 } } }) == null);
    const elapsed = io.monotonicMilliTimestamp() - started;
    std.debug.print("DNS pending {s} elapsed {d}ms\n", .{ @tagName(mode), elapsed });
    try std.testing.expect(elapsed < if (mode == .deadline) @as(i64, 1700) else @as(i64, 700));
    try std.testing.expectEqual(clean_before + 1, dns.cleaned_for_test.load(.acquire));
}

test "Native HTTP connection DNS pending deadline releases native resolver context" {
    try pendingDns(.deadline);
}

test "Native HTTP connection DNS pending epoch cancellation releases native resolver context" {
    try pendingDns(.epoch);
}

test "Native HTTP connection DNS pending shutdown releases native resolver context" {
    try pendingDns(.shutdown);
}

test "Native HTTP connection real native localhost resolves IPv4 IPv6 and canonical result" {
    const native_io = transport.nativeIo(io.io());
    for ([_]?std.Io.net.IpAddress.Family{ .ip4, .ip6, null }) |family| {
        var storage: [64]std.Io.net.HostName.LookupResult = undefined;
        var queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&storage);
        var canon: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = try std.Io.net.HostName.init("localhost");
        try host.lookup(native_io, &queue, .{ .port = 12345, .family = family, .canonical_name_buffer = &canon });
        var addresses: usize = 0;
        var canonical = false;
        while (queue.getOne(native_io)) |row| {
            switch (row) {
                .address => |address| {
                    addresses += 1;
                    try std.testing.expectEqual(@as(u16, 12345), address.getPort());
                    if (family) |expected| try std.testing.expectEqual(expected, std.meta.activeTag(address));
                },
                .canonical_name => |name| canonical = name.bytes.len > 0,
            }
        } else |err| try std.testing.expectEqual(error.Closed, err);
        try std.testing.expect(addresses > 0);
        try std.testing.expect(canonical);
    }
}

test "Native HTTP connection stalled body closes canceled socket and next request succeeds" {
    workers.init();
    defer workers.finishShutdown();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io.io(), .{ .reuse_address = true });
    defer server.deinit(io.io());
    const Fixture = struct {
        fn run(listener: *std.Io.net.Server) void {
            for (0..2) |i| {
                const stream = listener.accept(io.io()) catch return;
                defer stream.close(io.io());
                var read_buf: [4096]u8 = undefined;
                var reader = stream.reader(io.io(), &read_buf);
                while (true) {
                    const line = reader.interface.takeDelimiterInclusive('\n') catch return;
                    if (std.mem.eql(u8, line, "\r\n")) break;
                }
                var write_buf: [1024]u8 = undefined;
                var writer = stream.writer(io.io(), &write_buf);
                writer.interface.writeAll(if (i == 0) "HTTP/1.1 200 OK\r\nContent-Length: 20\r\nConnection: keep-alive\r\n\r\nab" else "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok") catch return;
                writer.interface.flush() catch return;
                if (i == 0) io.sleep(1500 * std.time.ns_per_ms);
            }
        }
    };
    var fixture = try io.io().concurrent(Fixture.run, .{&server});
    defer _ = fixture.cancel(io.io());
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = transport.nativeIo(io.io()) };
    defer client.deinit();
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
    var body: [1024]u8 = undefined;
    const started = io.monotonicMilliTimestamp();
    try std.testing.expect(transport.fetch(&client, url, &body, .{ .timeout_secs = 1 }) == null);
    try std.testing.expect(io.monotonicMilliTimestamp() - started < 1700);
    try std.testing.expectEqual(@as(usize, 0), client.connection_pool.free_len);
    const result = transport.fetch(&client, url, &body, .{ .timeout_secs = 2 });
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("ok", result.?);
}

test "Native HTTP connection concurrent native localhost lookups keep contexts independent" {
    const Lookup = struct {
        fn run(ok: *std.atomic.Value(bool)) void {
            const native_io = transport.nativeIo(io.io());
            var storage: [64]std.Io.net.HostName.LookupResult = undefined;
            var queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&storage);
            const host: std.Io.net.HostName = .{ .bytes = "localhost" };
            host.lookup(native_io, &queue, .{ .port = 54321 }) catch return;
            const first = queue.getOne(native_io) catch return;
            ok.store(first == .address and first.address.getPort() == 54321, .release);
        }
    };
    var successes: [4]std.atomic.Value(bool) = @splat(.init(false));
    var threads: [4]std.Thread = undefined;
    for (&threads, &successes) |*thread, *ok| thread.* = try std.Thread.spawn(.{}, Lookup.run, .{ok});
    for (threads) |thread| thread.join();
    for (&successes) |*ok| try std.testing.expect(ok.load(.acquire));
}

test "Native HTTP connection nonexistent native hostname fails within request budget" {
    workers.init();
    defer workers.finishShutdown();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = transport.nativeIo(io.io()) };
    defer client.deinit();
    var body: [1024]u8 = undefined;
    const started = io.monotonicMilliTimestamp();
    try std.testing.expect(transport.fetch(&client, "https://opal-native-transport-test.invalid/", &body, .{ .timeout_secs = 1 }) == null);
    try std.testing.expect(io.monotonicMilliTimestamp() - started < 1700);
}

test "Native HTTP connection canceled before connect cannot strand fixture accept" {
    workers.init();
    defer workers.finishShutdown();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io.io(), .{ .reuse_address = true });
    defer server.deinit(io.io());
    const Fixture = struct {
        fn run(listener: *std.Io.net.Server) void {
            const stream = listener.accept(io.io()) catch return;
            stream.close(io.io());
        }
    };
    var fixture = try io.io().concurrent(Fixture.run, .{&server});
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = transport.nativeIo(io.io()) };
    defer client.deinit();
    var epoch: std.atomic.Value(u32) = .init(2);
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/", .{server.socket.address.getPort()});
    var body: [1024]u8 = undefined;
    const started = io.monotonicMilliTimestamp();
    const result = transport.fetch(&client, url, &body, .{ .cancel_epoch = .{ .epoch32 = .{ .value = &epoch, .expected = 1 } } });
    _ = fixture.cancel(io.io());
    try std.testing.expect(result == null);
    try std.testing.expect(io.monotonicMilliTimestamp() - started < 700);
}

const compression_plain = "\x7b\x22\x74\x69\x74\x6c\x65\x22\x3a\x22\x4f\x77\x6e\x65\x64\x20\x6d\x65\x74\x61\x64\x61\x74\x61\x20\x66\x69\x78\x74\x75\x72\x65\x22\x2c\x22\x63\x6f\x75\x6e\x74\x22\x3a\x33\x7d";
const compression_gzip = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xab\x56\x2a\xc9\x2c\xc9\x49\x55\xb2\x52\xf2\x2f\xcf\x4b\x4d\x51\xc8\x4d\x2d\x49\x4c\x49\x2c\x49\x54\x48\xcb\xac\x28\x29\x2d\x4a\x55\xd2\x51\x4a\xce\x2f\xcd\x2b\x51\xb2\x32\xae\x05\x00\xce\x33\x94\x27\x2c\x00\x00\x00";
const compression_deflate = "\x78\x9c\xab\x56\x2a\xc9\x2c\xc9\x49\x55\xb2\x52\xf2\x2f\xcf\x4b\x4d\x51\xc8\x4d\x2d\x49\x4c\x49\x2c\x49\x54\x48\xcb\xac\x28\x29\x2d\x4a\x55\xd2\x51\x4a\xce\x2f\xcd\x2b\x51\xb2\x32\xae\x05\x00\x5e\x03\x0f\x68";
const compression_expansion = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xab\xa8\x18\x05\xa3\x60\x14\x8c\x54\x00\x00\x63\xf0\xd7\x48\x00\x04\x00\x00";

fn compressedFixture(encoding: []const u8, encoded: []const u8, cap: usize, oversized: bool) !void {
    workers.init();
    defer workers.finishShutdown();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io.io(), .{ .reuse_address = true });
    defer server.deinit(io.io());
    var negotiated: std.atomic.Value(bool) = .init(false);
    const Fixture = struct {
        fn run(listener: *std.Io.net.Server, codec: []const u8, bytes: []const u8, negotiation: *std.atomic.Value(bool), twice: bool) void {
            const attempts: usize = if (twice) 2 else 1;
            for (0..attempts) |index| {
                const stream = listener.accept(io.io()) catch return;
                defer stream.close(io.io());
                var read_buf: [4096]u8 = undefined;
                var reader = stream.reader(io.io(), &read_buf);
                while (true) {
                    const line = reader.interface.takeDelimiterInclusive('\n') catch return;
                    if (std.mem.eql(u8, line, "\r\n")) break;
                    if (line.len > 16 and std.ascii.eqlIgnoreCase(line[0..16], "accept-encoding:")) {
                        negotiation.store(std.mem.indexOf(u8, line, "gzip") != null and std.mem.indexOf(u8, line, "deflate") != null, .release);
                    }
                }
                var write_buf: [4096]u8 = undefined;
                var writer = stream.writer(io.io(), &write_buf);
                if (index == 0) {
                    writer.interface.print("HTTP/1.1 200 OK\r\nContent-Encoding: {s}\r\nContent-Length: {d}\r\nConnection: {s}\r\n\r\n", .{ codec, bytes.len, if (twice) "keep-alive" else "close" }) catch return;
                    writer.interface.writeAll(bytes) catch return;
                } else {
                    writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok") catch return;
                }
                writer.interface.flush() catch return;
                if (twice and index == 0) {
                    // Any pool attempt on an unfinished expanded body is unsafe.
                    // The caller must close its stream before issuing request2.
                    var drain: [32]u8 = undefined;
                    _ = reader.interface.readSliceShort(&drain) catch 0;
                }
            }
        }
    };
    var fixture = try io.io().concurrent(Fixture.run, .{ &server, encoding, encoded, &negotiated, oversized });
    defer _ = fixture.cancel(io.io());
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = transport.nativeIo(io.io()) };
    defer client.deinit();
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/metadata", .{server.socket.address.getPort()});
    var body: [2048]u8 = undefined;
    const response = transport.fetch(&client, url, &body, .{ .timeout_secs = 1, .max_response = cap });
    try std.testing.expect(negotiated.load(.acquire));
    if (oversized) {
        try std.testing.expect(response == null);
        try std.testing.expectEqual(@as(usize, 0), client.connection_pool.free_len);
        const next = transport.fetch(&client, url, &body, .{ .timeout_secs = 1 });
        try std.testing.expect(next != null);
        try std.testing.expectEqualStrings("ok", next.?);
    } else {
        try std.testing.expect(response != null);
        try std.testing.expectEqualStrings(compression_plain, response.?);
    }
}

test "Native HTTP compressed gzip metadata returns decoded exact bytes" {
    try compressedFixture("gzip", compression_gzip, 2048, false);
}

test "Native HTTP compressed deflate metadata returns decoded exact bytes" {
    try compressedFixture("deflate", compression_deflate, 2048, false);
}

test "Native HTTP compressed expansion respects decoded cap and closes unsafe pool socket" {
    try compressedFixture("gzip", compression_expansion, 64, true);
}
