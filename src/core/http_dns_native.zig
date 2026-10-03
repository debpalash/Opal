//! Cancellable native hostname resolution without subprocesses or detached jobs.
const std = @import("std");
const builtin = @import("builtin");
const sync = @import("sync.zig");
const Host = std.Io.net.HostName;
var lock: sync.Mutex = .{};
var wrapped: std.Io.VTable = undefined;
var original: ?*const std.Io.VTable = null;
// Hermetic test seam: create real native resolver resources but hold completion
// pending; no external DNS and no production environment hook.
pub var pending_for_test: bool = false;
pub var cleaned_for_test: std.atomic.Value(u32) = .init(0);

/// Install once during client initialization; never mutate a live shared client.
/// All operations retain the original Io backend and userdata.
pub fn nativeIo(base: std.Io) std.Io {
    if (builtin.os.tag != .macos and builtin.os.tag != .windows) return base;
    lock.lock();
    defer lock.unlock();
    if (base.vtable == &wrapped) return base;
    if (original == null) {
        original = base.vtable;
        wrapped = base.vtable.*;
        wrapped.netLookup = lookup;
    }
    std.debug.assert(original.? == base.vtable);
    return .{ .userdata = base.userdata, .vtable = &wrapped };
}

fn lookup(userdata: ?*anyopaque, host: Host, queue: *std.Io.Queue(Host.LookupResult), opts: Host.LookupOptions) Host.LookupError!void {
    const base: std.Io = .{ .userdata = userdata, .vtable = original.? };
    defer queue.close(base);
    return if (builtin.os.tag == .windows) Windows.resolve(base, host, queue, opts) else Darwin.resolve(base, host, queue, opts);
}

const Darwin = struct {
    const Ref = *const anyopaque;
    const StreamError = extern struct { domain: isize, err: i32 };
    const Context = extern struct { version: isize = 0, info: ?*anyopaque, retain: ?*const anyopaque = null, release: ?*const anyopaque = null, description: ?*const anyopaque = null };
    extern "CoreFoundation" fn CFStringCreateWithBytes(?Ref, [*]const u8, isize, u32, u8) ?Ref;
    extern "CoreFoundation" fn CFRelease(Ref) void;
    extern "CoreFoundation" fn CFRunLoopGetCurrent() Ref;
    extern "CoreFoundation" fn CFRunLoopRunInMode(Ref, f64, u8) i32;
    extern "CoreFoundation" var kCFRunLoopDefaultMode: Ref;
    extern "CoreFoundation" fn CFArrayGetCount(Ref) isize;
    extern "CoreFoundation" fn CFArrayGetValueAtIndex(Ref, isize) ?Ref;
    extern "CoreFoundation" fn CFDataGetLength(Ref) isize;
    extern "CoreFoundation" fn CFDataGetBytePtr(Ref) [*]const u8;
    extern "CFNetwork" fn CFHostCreateWithName(?Ref, Ref) ?Ref;
    extern "CFNetwork" fn CFHostSetClient(Ref, ?*const fn (Ref, i32, ?*const StreamError, ?*anyopaque) callconv(.c) void, ?*Context) u8;
    extern "CFNetwork" fn CFHostScheduleWithRunLoop(Ref, Ref, Ref) void;
    extern "CFNetwork" fn CFHostUnscheduleFromRunLoop(Ref, Ref, Ref) void;
    extern "CFNetwork" fn CFHostStartInfoResolution(Ref, i32, ?*StreamError) u8;
    extern "CFNetwork" fn CFHostCancelInfoResolution(Ref, i32) void;
    extern "CFNetwork" fn CFHostGetAddressing(Ref, *u8) ?Ref;
    const Completion = struct { done: bool = false, failed: bool = false };
    fn complete(_: Ref, _: i32, err: ?*const StreamError, ctx: ?*anyopaque) callconv(.c) void {
        const result: *Completion = @ptrCast(@alignCast(ctx.?));
        result.failed = if (err) |e| e.err != 0 else false;
        result.done = true;
    }
    fn resolve(base: std.Io, host: Host, queue: *std.Io.Queue(Host.LookupResult), opts: Host.LookupOptions) Host.LookupError!void {
        try base.checkCancel();
        if (std.Io.net.IpAddress.parse(host.bytes, opts.port)) |ip| {
            if (opts.family == null or opts.family.? == std.meta.activeTag(ip)) queue.putOne(base, .{ .address = ip }) catch return error.Canceled;
            if (opts.canonical_name_buffer) |buf| {
                @memcpy(buf[0..host.bytes.len], host.bytes);
                queue.putOne(base, .{ .canonical_name = .{ .bytes = buf[0..host.bytes.len] } }) catch return error.Canceled;
            }
            return;
        } else |_| {}
        const name = CFStringCreateWithBytes(null, host.bytes.ptr, @intCast(host.bytes.len), 0x08000100, 0) orelse return error.SystemResources;
        defer CFRelease(name);
        const cfhost = CFHostCreateWithName(null, name) orelse return error.SystemResources;
        defer CFRelease(cfhost);
        var completion: Completion = .{};
        var context: Context = .{ .info = &completion };
        if (CFHostSetClient(cfhost, complete, &context) == 0) return error.SystemResources;
        defer _ = CFHostSetClient(cfhost, null, null);
        const runloop = CFRunLoopGetCurrent();
        CFHostScheduleWithRunLoop(cfhost, runloop, kCFRunLoopDefaultMode);
        defer CFHostUnscheduleFromRunLoop(cfhost, runloop, kCFRunLoopDefaultMode);
        defer {
            CFHostCancelInfoResolution(cfhost, 0);
            if (builtin.is_test) _ = cleaned_for_test.fetchAdd(1, .release);
        }
        var failure: StreamError = .{ .domain = 0, .err = 0 };
        if (!(builtin.is_test and pending_for_test) and CFHostStartInfoResolution(cfhost, 0, &failure) == 0) return error.UnknownHostName;
        while (!completion.done) {
            try base.checkCancel();
            _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, 1);
        }
        try base.checkCancel();
        if (completion.failed) return error.UnknownHostName;
        var resolved: u8 = 0;
        const addresses = CFHostGetAddressing(cfhost, &resolved) orelse return error.NoAddressReturned;
        if (resolved == 0) return error.NoAddressReturned;
        var count: usize = 0;
        const total = CFArrayGetCount(addresses);
        var index: isize = 0;
        while (index < total) : (index += 1) {
            const data = CFArrayGetValueAtIndex(addresses, index) orelse continue;
            const len = CFDataGetLength(data);
            const bytes = CFDataGetBytePtr(data);
            if (len < @sizeOf(std.posix.sockaddr)) continue;
            const sa: *align(1) const std.posix.sockaddr = @ptrCast(bytes);
            const ip: std.Io.net.IpAddress = switch (sa.family) {
                std.posix.AF.INET => blk: {
                    if (len < @sizeOf(std.posix.sockaddr.in)) continue;
                    const v: *align(1) const std.posix.sockaddr.in = @ptrCast(bytes);
                    break :blk .{ .ip4 = .{ .bytes = @bitCast(v.addr), .port = opts.port } };
                },
                std.posix.AF.INET6 => blk: {
                    if (len < @sizeOf(std.posix.sockaddr.in6)) continue;
                    const v: *align(1) const std.posix.sockaddr.in6 = @ptrCast(bytes);
                    break :blk .{ .ip6 = .{ .bytes = v.addr, .port = opts.port, .flow = v.flowinfo, .interface = .{ .index = v.scope_id } } };
                },
                else => continue,
            };
            if (opts.family != null and opts.family.? != std.meta.activeTag(ip)) continue;
            queue.putOne(base, .{ .address = ip }) catch return error.Canceled;
            count += 1;
        }
        if (count == 0) return error.NoAddressReturned;
        if (opts.canonical_name_buffer) |buf| {
            @memcpy(buf[0..host.bytes.len], host.bytes);
            queue.putOne(base, .{ .canonical_name = .{ .bytes = buf[0..host.bytes.len] } }) catch return error.Canceled;
        }
    }
};

const Windows = struct {
    // MinGW headers omit this Windows 8+ symbol; ws2_32 exports it.
    extern "ws2_32" fn GetAddrInfoExCancel(*?*anyopaque) callconv(.winapi) i32;
    extern "ws2_32" fn GetAddrInfoExOverlappedResult(*anyopaque) callconv(.winapi) i32;
    const Address4 = extern struct { family: u16, port: u16, bytes: [4]u8, padding: [8]u8 };
    const Address6 = extern struct { family: u16, port: u16, flow: u32, bytes: [16]u8, scope: u32 };
    const c = if (builtin.os.tag == .windows) @cImport({
        @cDefine("_WIN32_WINNT", "0x0602");
        @cInclude("winsock2.h");
        @cInclude("ws2tcpip.h");
    }) else struct {};
    fn resolve(base: std.Io, host: Host, queue: *std.Io.Queue(Host.LookupResult), opts: Host.LookupOptions) Host.LookupError!void {
        try base.checkCancel();
        var wsa: c.WSADATA = undefined;
        if (c.WSAStartup(0x0202, &wsa) != 0) return error.NetworkDown;
        defer _ = c.WSACleanup();
        var name: [Host.max_len + 1]u16 = undefined;
        const name_len = std.unicode.utf8ToUtf16Le(&name, host.bytes) catch return error.UnknownHostName;
        name[name_len] = 0;
        const event = c.CreateEventW(null, c.TRUE, c.FALSE, null) orelse return error.SystemResources;
        defer _ = c.CloseHandle(event);
        var overlapped: c.OVERLAPPED = std.mem.zeroes(c.OVERLAPPED);
        overlapped.hEvent = event;
        var hints: c.ADDRINFOEXW = std.mem.zeroes(c.ADDRINFOEXW);
        hints.ai_family = if (opts.family) |family| (if (family == .ip4) c.AF_INET else c.AF_INET6) else c.AF_UNSPEC;
        hints.ai_socktype = c.SOCK_STREAM;
        hints.ai_protocol = c.IPPROTO_TCP;
        if (opts.canonical_name_buffer != null) hints.ai_flags = c.AI_CANONNAME;
        var result: [*c]c.ADDRINFOEXW = null;
        defer if (result != null) c.FreeAddrInfoExW(result);
        var handle: c.HANDLE = null;
        var status = if (builtin.is_test and pending_for_test) c.WSA_IO_PENDING else c.GetAddrInfoExW(&name, null, c.NS_DNS, null, &hints, &result, null, &overlapped, null, &handle);
        if (status == c.WSA_IO_PENDING) {
            // Cancellation is a request, not completion. Retain every borrowed
            // OVERLAPPED/name/result pointer until its event has been signalled.
            var canceled = false;
            while (c.WaitForSingleObject(event, 5) == c.WAIT_TIMEOUT) {
                if (!canceled) base.checkCancel() catch {
                    canceled = true;
                    if (builtin.is_test and pending_for_test) {
                        _ = c.SetEvent(event);
                    } else _ = GetAddrInfoExCancel(&handle);
                };
            }
            status = if (builtin.is_test and pending_for_test) c.WSA_E_CANCELLED else GetAddrInfoExOverlappedResult(&overlapped);
            if (builtin.is_test) _ = cleaned_for_test.fetchAdd(1, .release);
            if (canceled) return error.Canceled;
        }
        try base.checkCancel();
        if (status != 0) return error.UnknownHostName;
        var current = result;
        var count: usize = 0;
        while (current != null) : (current = current.*.ai_next) {
            const row = current.*;
            if (row.ai_addr == null) continue;
            const ip: std.Io.net.IpAddress = switch (row.ai_family) {
                c.AF_INET => blk: {
                    if (row.ai_addrlen < @sizeOf(Address4)) continue;
                    const v: *align(1) const Address4 = @ptrCast(row.ai_addr);
                    break :blk .{ .ip4 = .{ .bytes = v.bytes, .port = opts.port } };
                },
                c.AF_INET6 => blk: {
                    if (row.ai_addrlen < @sizeOf(Address6)) continue;
                    const v: *align(1) const Address6 = @ptrCast(row.ai_addr);
                    break :blk .{ .ip6 = .{ .bytes = v.bytes, .port = opts.port, .flow = v.flow, .interface = .{ .index = v.scope } } };
                },
                else => continue,
            };
            queue.putOne(base, .{ .address = ip }) catch return error.Canceled;
            count += 1;
        }
        if (count == 0) return error.NoAddressReturned;
        if (opts.canonical_name_buffer) |buf| {
            const length = if (result.*.ai_canonname != null)
                std.unicode.utf16LeToUtf8(buf, std.mem.span(result.*.ai_canonname)) catch return error.UnknownHostName
            else blk: {
                @memcpy(buf[0..host.bytes.len], host.bytes);
                break :blk host.bytes.len;
            };
            queue.putOne(base, .{ .canonical_name = .{ .bytes = buf[0..length] } }) catch return error.Canceled;
        }
    }
};
