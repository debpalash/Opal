//! Actual loopback download workers; no providers, credentials or profile.
const std = @import("std");
const io = @import("core/io_global.zig");
const workers = @import("core/workers.zig");
const engine = @import("services/download_engine.zig");

fn clearJobs() void {
    var rows: [engine.MAX_DOWNLOADS]engine.Snap = undefined;
    const count = engine.snapshot(&rows);
    for (rows[0..count]) |row| {
        if (row.status == .done) _ = engine.dismiss(row.idx, row.token) else _ = engine.cancel(row.idx, row.token);
    }
    const deadline = io.monotonicMilliTimestamp() + 3500;
    for (0..engine.MAX_DOWNLOADS) |idx| {
        while (engine.coordinatorBusyForTest(idx) and io.monotonicMilliTimestamp() < deadline) io.sleep(5 * std.time.ns_per_ms);
    }
}

fn canceledProbe(tls: bool) !void {
    workers.init();
    defer workers.finishShutdown();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io.io(), .{ .reuse_address = true });
    defer server.deinit(io.io());
    var accepted: std.atomic.Value(bool) = .init(false);
    const Fixture = struct {
        fn serve(listener: *std.Io.net.Server, ready: *std.atomic.Value(bool)) void {
            const stream = listener.accept(io.io()) catch return;
            defer stream.close(io.io());
            ready.store(true, .release);
            // Bound the old implementation too, so red evidence cannot hang.
            io.sleep(2 * std.time.ns_per_s);
            stream.shutdown(io.io(), .both) catch {};
        }
    };
    var fixture = try io.io().concurrent(Fixture.serve, .{ &server, &accepted });
    defer _ = fixture.cancel(io.io());
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}://127.0.0.1:{d}/fixture", .{ if (tls) "https" else "http", server.socket.address.getPort() });
    // The probe never reaches file creation; cancellation owns this path only.
    var path_buf: [1024]u8 = undefined;
    var fixture_dir = std.testing.tmpDir(.{});
    defer fixture_dir.cleanup();
    var directory: [1024]u8 = undefined;
    const directory_len = try fixture_dir.dir.realPath(std.testing.io, &directory);
    const path = try std.fmt.bufPrint(&path_buf, "{s}{c}fixture.bin", .{ directory[0..directory_len], std.fs.path.sep });
    defer engine.removeArtifacts(path);
    try std.testing.expect(engine.start(url, path));
    defer clearJobs();
    const accepted_deadline = io.monotonicMilliTimestamp() + 2000;
    while (!accepted.load(.acquire) and io.monotonicMilliTimestamp() < accepted_deadline) io.sleep(5 * std.time.ns_per_ms);
    try std.testing.expect(accepted.load(.acquire));
    var rows: [engine.MAX_DOWNLOADS]engine.Snap = undefined;
    try std.testing.expectEqual(@as(usize, 1), engine.snapshot(&rows));
    const idx = rows[0].idx;
    const started = io.monotonicMilliTimestamp();
    try std.testing.expect(engine.cancel(rows[0].idx, rows[0].token));
    while (engine.coordinatorBusyForTest(idx) and io.monotonicMilliTimestamp() - started < 3000) io.sleep(5 * std.time.ns_per_ms);
    const elapsed = io.monotonicMilliTimestamp() - started;
    std.debug.print("Download {s} probe cancellation {d}ms\n", .{ if (tls) "TLS" else "head", elapsed });
    try std.testing.expect(!engine.coordinatorBusyForTest(idx));
    try std.testing.expect(elapsed < 700);
}

test "Native download stalled TLS probe cancellation joins worker" {
    try canceledProbe(true);
}
test "Native download stalled HTTP head cancellation joins worker" {
    try canceledProbe(false);
}

fn canceledBody(paused: bool, shutdown: bool) !void {
    workers.init();
    defer workers.finishShutdown();
    engine.cfg_segments.store(1, .release);
    defer engine.cfg_segments.store(4, .release);
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io.io(), .{ .reuse_address = true });
    defer server.deinit(io.io());
    var accepted: std.atomic.Value(bool) = .init(false);
    const Fixture = struct {
        fn head(stream: std.Io.net.Stream) void {
            var buf: [2048]u8 = undefined;
            var reader = stream.reader(io.io(), &buf);
            while (true) {
                const line = reader.interface.takeDelimiterInclusive('\n') catch return;
                if (std.mem.eql(u8, line, "\r\n")) return;
            }
        }
        fn serve(listener: *std.Io.net.Server, ready: *std.atomic.Value(bool)) void {
            const probe_stream = listener.accept(io.io()) catch return;
            head(probe_stream);
            var wb: [512]u8 = undefined;
            var pw = probe_stream.writer(io.io(), &wb);
            pw.interface.writeAll("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-0/8192\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx") catch {};
            pw.interface.flush() catch {};
            probe_stream.close(io.io());
            const stream = listener.accept(io.io()) catch return;
            defer stream.close(io.io());
            head(stream);
            var writer = stream.writer(io.io(), &wb);
            writer.interface.writeAll("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-8191/8192\r\nContent-Length: 8192\r\nConnection: close\r\n\r\nabc") catch return;
            writer.interface.flush() catch return;
            ready.store(true, .release);
            io.sleep(2 * std.time.ns_per_s);
            stream.shutdown(io.io(), .both) catch {};
        }
    };
    var fixture = try io.io().concurrent(Fixture.serve, .{ &server, &accepted });
    defer _ = fixture.cancel(io.io());
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/fixture", .{server.socket.address.getPort()});
    var path_buf: [1024]u8 = undefined;
    var fixture_dir = std.testing.tmpDir(.{});
    defer fixture_dir.cleanup();
    var directory: [1024]u8 = undefined;
    const directory_len = try fixture_dir.dir.realPath(std.testing.io, &directory);
    const path = try std.fmt.bufPrint(&path_buf, "{s}{c}fixture.bin", .{ directory[0..directory_len], std.fs.path.sep });
    defer engine.removeArtifacts(path);
    try std.testing.expect(engine.start(url, path));
    defer clearJobs();
    const deadline = io.monotonicMilliTimestamp() + 3000;
    while (!accepted.load(.acquire) and io.monotonicMilliTimestamp() < deadline) io.sleep(5 * std.time.ns_per_ms);
    try std.testing.expect(accepted.load(.acquire));
    io.sleep(30 * std.time.ns_per_ms); // let the reader enter its blocking call
    var rows: [engine.MAX_DOWNLOADS]engine.Snap = undefined;
    try std.testing.expectEqual(@as(usize, 1), engine.snapshot(&rows));
    // Partial bytes must publish before EOF, not wait to fill the 64KiB buffer.
    try std.testing.expectEqual(@as(u64, 3), rows[0].done);
    const idx = rows[0].idx;
    const started = io.monotonicMilliTimestamp();
    if (shutdown) workers.markQuitting() else if (paused) {
        try std.testing.expect(engine.pause(idx, rows[0].token));
    } else try std.testing.expect(engine.cancel(idx, rows[0].token));
    while (engine.coordinatorBusyForTest(idx) and io.monotonicMilliTimestamp() - started < 3000) io.sleep(5 * std.time.ns_per_ms);
    const elapsed = io.monotonicMilliTimestamp() - started;
    std.debug.print("Download body {s} cleanup {d}ms\n", .{ if (shutdown) "shutdown" else if (paused) "pause" else "cancel", elapsed });
    try std.testing.expect(!engine.coordinatorBusyForTest(idx));
    // Preserve resume state on pause; explicitly cancel our fixture afterward.
    if (engine.snapshot(&rows) > 0) _ = engine.cancel(rows[0].idx, rows[0].token);
    try std.testing.expect(elapsed < 700);
}

test "Native download body stall cancellation joins segment" {
    try canceledBody(false, false);
}
test "Native download body stall pause preserves owned cleanup" {
    try canceledBody(true, false);
}
test "Native download body stall shutdown joins segment" {
    try canceledBody(false, true);
}

test "Native download partial progress pause resume range completes exact bytes" {
    workers.init();
    defer workers.finishShutdown();
    engine.cfg_segments.store(1, .release);
    defer engine.cfg_segments.store(4, .release);
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io.io(), .{ .reuse_address = true });
    defer server.deinit(io.io());
    var resume_ready: std.atomic.Value(bool) = .init(false);
    var resume_range: std.atomic.Value(bool) = .init(false);
    const Fixture = struct {
        fn requestHead(stream: std.Io.net.Stream) bool {
            var rb: [2048]u8 = undefined;
            var reader = stream.reader(io.io(), &rb);
            var resumed = false;
            while (true) {
                const line = reader.interface.takeDelimiterInclusive('\n') catch return false;
                if (std.ascii.eqlIgnoreCase(line, "range: bytes=32-63\r\n")) resumed = true;
                if (std.mem.eql(u8, line, "\r\n")) return resumed;
            }
        }
        fn send(stream: std.Io.net.Stream, text: []const u8) void {
            var wb: [1024]u8 = undefined;
            var writer = stream.writer(io.io(), &wb);
            writer.interface.writeAll(text) catch return;
            writer.interface.flush() catch {};
        }
        fn serve(listener: *std.Io.net.Server, proceed: *std.atomic.Value(bool), matched: *std.atomic.Value(bool)) void {
            for (0..4) |phase| {
                const stream = listener.accept(io.io()) catch return;
                const resumed = requestHead(stream);
                if (phase == 0 or phase == 2) {
                    send(stream, "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-0/64\r\nContent-Length: 1\r\nETag: fixture-v1\r\nConnection: close\r\n\r\na");
                } else if (phase == 1) {
                    send(stream, "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-63/64\r\nContent-Length: 64\r\nETag: fixture-v1\r\nConnection: close\r\n\r\naaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
                    const deadline = io.monotonicMilliTimestamp() + 4000;
                    while (!proceed.load(.acquire) and io.monotonicMilliTimestamp() < deadline) io.sleep(5 * std.time.ns_per_ms);
                } else {
                    matched.store(resumed, .release);
                    send(stream, "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 32-63/64\r\nContent-Length: 32\r\nETag: fixture-v1\r\nConnection: close\r\n\r\nbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
                }
                stream.close(io.io());
            }
        }
    };
    var fixture = try io.io().concurrent(Fixture.serve, .{ &server, &resume_ready, &resume_range });
    defer _ = fixture.cancel(io.io());
    var ub: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}/fixture", .{server.socket.address.getPort()});
    var pb: [1024]u8 = undefined;
    var fixture_dir = std.testing.tmpDir(.{});
    defer fixture_dir.cleanup();
    var directory: [1024]u8 = undefined;
    const directory_len = try fixture_dir.dir.realPath(std.testing.io, &directory);
    const path = try std.fmt.bufPrint(&pb, "{s}{c}fixture.bin", .{ directory[0..directory_len], std.fs.path.sep });
    defer engine.removeArtifacts(path);
    defer io.deleteFileAbsolute(path) catch {};
    try std.testing.expect(engine.start(url, path));
    defer clearJobs();
    var rows: [engine.MAX_DOWNLOADS]engine.Snap = undefined;
    var deadline = io.monotonicMilliTimestamp() + 2000;
    while (io.monotonicMilliTimestamp() < deadline) {
        if (engine.snapshot(&rows) == 1 and rows[0].done == 32) break;
        io.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(u64, 32), rows[0].done);
    const idx = rows[0].idx;
    try std.testing.expect(engine.pause(idx, rows[0].token));
    deadline = io.monotonicMilliTimestamp() + 700;
    while (engine.coordinatorBusyForTest(idx) and io.monotonicMilliTimestamp() < deadline) io.sleep(5 * std.time.ns_per_ms);
    try std.testing.expect(!engine.coordinatorBusyForTest(idx));
    resume_ready.store(true, .release);
    try std.testing.expectEqual(@as(usize, 1), engine.snapshot(&rows));
    try std.testing.expectEqual(engine.Status.paused, rows[0].status);
    try std.testing.expectEqual(@as(u64, 32), rows[0].done);
    try std.testing.expect(engine.resumeDl(idx, rows[0].token));
    deadline = io.monotonicMilliTimestamp() + 3000;
    while (io.monotonicMilliTimestamp() < deadline) {
        if (engine.snapshot(&rows) == 1 and rows[0].status == .done and !engine.coordinatorBusyForTest(idx)) break;
        io.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(engine.Status.done, rows[0].status);
    try std.testing.expectEqual(@as(u64, 64), rows[0].done);
    try std.testing.expect(resume_range.load(.acquire));
    const bytes = try io.cwdReadFileAlloc(path, std.testing.allocator, 128);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", bytes);
    try std.testing.expect(engine.dismiss(idx, rows[0].token));
}

test "Native download probe deadline includes stalled TLS opening" {
    workers.init();
    defer workers.finishShutdown();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io.io(), .{ .reuse_address = true });
    defer server.deinit(io.io());
    const Fixture = struct {
        fn serve(listener: *std.Io.net.Server) void {
            const stream = listener.accept(io.io()) catch return;
            defer stream.close(io.io());
            io.sleep(23 * std.time.ns_per_s);
            stream.shutdown(io.io(), .both) catch {};
        }
    };
    var fixture = try io.io().concurrent(Fixture.serve, .{&server});
    defer _ = fixture.cancel(io.io());
    var ub: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&ub, "https://127.0.0.1:{d}/fixture", .{server.socket.address.getPort()});
    var pb: [1024]u8 = undefined;
    var fixture_dir = std.testing.tmpDir(.{});
    defer fixture_dir.cleanup();
    var directory: [1024]u8 = undefined;
    const directory_len = try fixture_dir.dir.realPath(std.testing.io, &directory);
    const path = try std.fmt.bufPrint(&pb, "{s}{c}fixture.bin", .{ directory[0..directory_len], std.fs.path.sep });
    defer engine.removeArtifacts(path);
    const started = io.monotonicMilliTimestamp();
    try std.testing.expect(engine.start(url, path));
    defer clearJobs();
    var rows: [engine.MAX_DOWNLOADS]engine.Snap = undefined;
    while (io.monotonicMilliTimestamp() - started < 25_000) {
        if (engine.snapshot(&rows) == 1 and rows[0].status == .failed and !engine.coordinatorBusyForTest(rows[0].idx)) break;
        io.sleep(5 * std.time.ns_per_ms);
    }
    const elapsed = io.monotonicMilliTimestamp() - started;
    std.debug.print("Download TLS opening deadline {d}ms\n", .{elapsed});
    try std.testing.expectEqual(engine.Status.failed, rows[0].status);
    try std.testing.expect(elapsed >= 19_900 and elapsed < 21_000);
}

test "Native download content changed repairs through new probe despite soft stop" {
    workers.init();
    defer workers.finishShutdown();
    engine.cfg_segments.store(1, .release);
    defer engine.cfg_segments.store(4, .release);
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io.io(), .{ .reuse_address = true });
    defer server.deinit(io.io());
    const Fixture = struct {
        fn serve(listener: *std.Io.net.Server) void {
            for (0..4) |phase| {
                const stream = listener.accept(io.io()) catch return;
                var rb: [2048]u8 = undefined;
                var reader = stream.reader(io.io(), &rb);
                while (true) {
                    const line = reader.interface.takeDelimiterInclusive('\n') catch {
                        stream.close(io.io());
                        return;
                    };
                    if (std.mem.eql(u8, line, "\r\n")) break;
                }
                var wb: [1024]u8 = undefined;
                var writer = stream.writer(io.io(), &wb);
                if (phase == 0) {
                    writer.interface.writeAll("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-0/8\r\nContent-Length: 1\r\nETag: old\r\nConnection: close\r\n\r\no") catch {};
                } else {
                    // Changed representation stops honoring Range. The repair
                    // probe sees 200 and replans a single non-range transfer.
                    writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 8\r\nETag: new\r\nConnection: close\r\n\r\nnew-data") catch {};
                }
                writer.interface.flush() catch {};
                stream.close(io.io());
            }
        }
    };
    var fixture = try io.io().concurrent(Fixture.serve, .{&server});
    defer _ = fixture.cancel(io.io());
    var ub: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}/fixture", .{server.socket.address.getPort()});
    var pb: [1024]u8 = undefined;
    var fixture_dir = std.testing.tmpDir(.{});
    defer fixture_dir.cleanup();
    var directory: [1024]u8 = undefined;
    const directory_len = try fixture_dir.dir.realPath(std.testing.io, &directory);
    const path = try std.fmt.bufPrint(&pb, "{s}{c}fixture.bin", .{ directory[0..directory_len], std.fs.path.sep });
    defer engine.removeArtifacts(path);
    defer io.deleteFileAbsolute(path) catch {};
    try std.testing.expect(engine.start(url, path));
    defer clearJobs();
    var rows: [engine.MAX_DOWNLOADS]engine.Snap = undefined;
    const deadline = io.monotonicMilliTimestamp() + 3000;
    while (io.monotonicMilliTimestamp() < deadline) {
        if (engine.snapshot(&rows) == 1 and rows[0].status == .done and !engine.coordinatorBusyForTest(rows[0].idx)) break;
        io.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(engine.Status.done, rows[0].status);
    const bytes = try io.cwdReadFileAlloc(path, std.testing.allocator, 32);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("new-data", bytes);
}

test "Native download requests identity and rejects compressed range body" {
    workers.init();
    defer workers.finishShutdown();
    engine.cfg_segments.store(1, .release);
    defer engine.cfg_segments.store(4, .release);
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io.io(), .{ .reuse_address = true });
    defer server.deinit(io.io());
    var identity: std.atomic.Value(bool) = .init(true);
    const Fixture = struct {
        fn serve(listener: *std.Io.net.Server, valid: *std.atomic.Value(bool)) void {
            for (0..2) |phase| {
                const stream = listener.accept(io.io()) catch return;
                var rb: [2048]u8 = undefined;
                var reader = stream.reader(io.io(), &rb);
                var found = false;
                while (true) {
                    const line = reader.interface.takeDelimiterInclusive('\n') catch {
                        stream.close(io.io());
                        return;
                    };
                    if (std.ascii.eqlIgnoreCase(line, "accept-encoding: identity\r\n")) found = true;
                    if (std.mem.eql(u8, line, "\r\n")) break;
                }
                if (!found) valid.store(false, .release);
                var wb: [1024]u8 = undefined;
                var writer = stream.writer(io.io(), &wb);
                if (phase == 0) {
                    writer.interface.writeAll("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-0/8\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx") catch {};
                } else {
                    // An origin ignoring identity must not corrupt byte ranges.
                    writer.interface.writeAll("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-7/8\r\nContent-Length: 8\r\nContent-Encoding: gzip\r\nConnection: close\r\n\r\nnotgzip!") catch {};
                }
                writer.interface.flush() catch {};
                stream.close(io.io());
            }
        }
    };
    var fixture = try io.io().concurrent(Fixture.serve, .{ &server, &identity });
    defer _ = fixture.cancel(io.io());
    var ub: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}/fixture", .{server.socket.address.getPort()});
    var pb: [1024]u8 = undefined;
    var fixture_dir = std.testing.tmpDir(.{});
    defer fixture_dir.cleanup();
    var directory: [1024]u8 = undefined;
    const directory_len = try fixture_dir.dir.realPath(std.testing.io, &directory);
    const path = try std.fmt.bufPrint(&pb, "{s}{c}fixture.bin", .{ directory[0..directory_len], std.fs.path.sep });
    defer engine.removeArtifacts(path);
    defer io.deleteFileAbsolute(path) catch {};
    try std.testing.expect(engine.start(url, path));
    defer clearJobs();
    var rows: [engine.MAX_DOWNLOADS]engine.Snap = undefined;
    const deadline = io.monotonicMilliTimestamp() + 3000;
    while (io.monotonicMilliTimestamp() < deadline) {
        if (engine.snapshot(&rows) == 1 and (rows[0].status == .failed or rows[0].status == .done) and !engine.coordinatorBusyForTest(rows[0].idx)) break;
        io.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expect(identity.load(.acquire));
    try std.testing.expectEqual(engine.Status.failed, rows[0].status);
    try std.testing.expectEqual(@as(u64, 0), rows[0].done);
    try std.testing.expectError(error.FileNotFound, io.openFileAbsolute(path, .{}));
}
