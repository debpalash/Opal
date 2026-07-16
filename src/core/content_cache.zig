//! Encrypted, persistent, on-disk content cache — the driver.
//!
//! Fetched content (search results, browse listings, catalog JSON, metadata) is
//! serialized to a compact blob by the caller and handed to `put`. We AEAD-
//! encrypt it with a per-install key and write it atomically to
//! `~/.cache/opal/content/<hash>.bin`. On the next cold start `get` returns the
//! cached copy INSTANTLY (so the view is never blank) plus a staleness verdict;
//! the caller shows it immediately and, if stale, kicks a background refresh
//! that rewrites the entry — classic stale-while-revalidate.
//!
//! Security / robustness:
//!  • Encrypted at rest with XChaCha20-Poly1305 under a random 32-byte key kept
//!    at `~/.config/opal/cache.key` (mode 0600). If the key can't be made or
//!    read, the cache DISABLES itself (never stores plaintext).
//!  • The AAD binds each entry to its key hash + header, so a tampered or
//!    relocated file fails authentication and is treated as a miss.
//!  • Writes are atomic (temp file + rename) — a crash never leaves a half
//!    entry.
//!  • Corrupt / undecryptable entries are deleted on read.
//!  • Total size is bounded (200 MB): the startup sweep evicts oldest-first.
//!
//! All parsing/policy routes through `content_cache_pure.zig`.

const std = @import("std");
const pure = @import("content_cache_pure.zig");
const io = @import("io_global.zig");
const paths = @import("paths.zig");
const alloc = @import("alloc.zig").allocator;
const state = @import("state.zig");
const logs = @import("logs.zig");

const sync = @import("sync.zig");

const XChaCha = std.crypto.aead.chacha_poly.XChaCha20Poly1305;

// Per-install key. Written once by init(); read by put/get under `key_ok`.
var install_key: [32]u8 = undefined;
var key_ok = std.atomic.Value(bool).init(false);
var disabled_logged = std.atomic.Value(bool).init(false);

// CSPRNG for the install key + per-entry nonces. Seeded once from /dev/urandom
// (0.16 removed std.crypto.random; this mirrors remote.zig's token CSPRNG). A
// failed seed leaves the cache disabled — we never fall back to a weak nonce.
var rng: std.Random.DefaultCsprng = undefined;
var rng_init = std.atomic.Value(bool).init(false);
var rng_mutex = sync.Mutex{};
var tmp_counter = std.atomic.Value(u64).init(0);

fn randomBytes(out: []u8) bool {
    rng_mutex.lock();
    defer rng_mutex.unlock();
    if (!rng_init.load(.acquire)) {
        var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
        var ok = false;
        if (io.openFileAbsolute("/dev/urandom", .{})) |f| {
            const n = io.readAll(f, &seed) catch 0;
            f.close(io.io());
            ok = (n == seed.len);
        } else |_| {}
        if (!ok) return false;
        rng = std.Random.DefaultCsprng.init(seed);
        rng_init.store(true, .release);
    }
    rng.fill(out);
    return true;
}

pub const Hit = struct {
    bytes: []u8, // slice of the caller's out_buf
    staleness: pure.Staleness,
};

/// True when the cache may be used: the user toggle is on AND a key is loaded.
fn active() bool {
    return state.app.content_cache_enabled and key_ok.load(.acquire);
}

// ──────────────────────────── paths ────────────────────────────

fn keyFilePath(buf: []u8) ?[]const u8 {
    var dir_buf: [512]u8 = undefined;
    const dir = paths.configDir(&dir_buf);
    return std.fmt.bufPrint(buf, "{s}/cache.key", .{dir}) catch null;
}

/// `~/.cache/opal/content` — the entry directory. Ensures it exists.
fn contentDir(buf: []u8) ?[]const u8 {
    const dir = paths.cacheFile(buf, "content");
    io.cwdMakePath(dir) catch return null;
    return dir;
}

fn entryPath(buf: []u8, key: []const u8) ?[]const u8 {
    var dir_buf: [512]u8 = undefined;
    const dir = contentDir(&dir_buf) orelse return null;
    const name = pure.keyToFilename(key);
    return std.fmt.bufPrint(buf, "{s}/{s}.bin", .{ dir, name }) catch null;
}

// ──────────────────────────── init / key ────────────────────────────

/// Load the per-install key, generating it once if absent. On any failure the
/// cache stays disabled (never falls back to plaintext). Safe to call on a
/// background thread. Also runs the startup purge sweep.
pub fn init() void {
    if (loadOrCreateKey()) {
        key_ok.store(true, .release);
        logs.pushLog("info", "cache", "Encrypted content cache ready", false);
        purgeExpired();
    } else if (!disabled_logged.swap(true, .acq_rel)) {
        logs.pushLog("warn", "cache", "Content cache disabled (no key) — views load from network only", false);
    }
}

fn loadOrCreateKey() bool {
    var path_buf: [640]u8 = undefined;
    const path = keyFilePath(&path_buf) orelse return false;

    // Try to read an existing key.
    if (io.openFileAbsolute(path, .{})) |f| {
        defer f.close(io.io());
        var buf: [32]u8 = undefined;
        const n = io.readAll(f, &buf) catch 0;
        if (n == 32) {
            @memcpy(&install_key, &buf);
            return true;
        }
        // Wrong size → corrupt; fall through and regenerate.
    } else |_| {}

    // Generate a fresh key and persist it at mode 0600.
    var newkey: [32]u8 = undefined;
    if (!randomBytes(&newkey)) return false; // no entropy → stay disabled

    // Ensure the config dir exists.
    var cfg_buf: [512]u8 = undefined;
    const cfg_dir = paths.configDir(&cfg_buf);
    io.cwdMakePath(cfg_dir) catch {};

    const perms = if (@import("builtin").os.tag == .windows)
        std.Io.File.Permissions.default_file
    else
        std.Io.File.Permissions.fromMode(0o600);
    const f = io.createFileAbsolute(path, .{
        .read = false,
        .truncate = true,
        .permissions = perms,
    }) catch return false;
    defer f.close(io.io());
    io.writeAll(f, &newkey) catch return false;
    if (@import("builtin").os.tag != .windows)
        f.setPermissions(io.io(), std.Io.File.Permissions.fromMode(0o600)) catch {};
    @memcpy(&install_key, &newkey);
    return true;
}

// ──────────────────────────── AAD ────────────────────────────

/// Build the associated data authenticating an entry: header bytes ++ keyHash.
/// Returns the filled slice of `buf` (buf must be >= HEADER_LEN + 32).
fn buildAad(buf: []u8, header: []const u8, key: []const u8) []const u8 {
    @memcpy(buf[0..pure.HEADER_LEN], header[0..pure.HEADER_LEN]);
    const kh = pure.keyHash(key);
    @memcpy(buf[pure.HEADER_LEN .. pure.HEADER_LEN + 32], &kh);
    return buf[0 .. pure.HEADER_LEN + 32];
}

// ──────────────────────────── put ────────────────────────────

/// Encrypt `bytes` under `key` and write it atomically with the given TTL.
/// No-op when the cache is disabled or the entry exceeds the size cap. Callers
/// already run on worker threads, so this is synchronous-on-caller.
pub fn put(key: []const u8, bytes: []const u8, ttl_s: i64) void {
    if (!active()) return;
    if (bytes.len == 0 or bytes.len > pure.MAX_ENTRY_BYTES) return;

    // Header.
    var nonce: [pure.NONCE_LEN]u8 = undefined;
    if (!randomBytes(&nonce)) return; // no entropy → skip (never a weak nonce)
    var header_buf: [pure.HEADER_LEN]u8 = undefined;
    const header = pure.encodeHeader(&header_buf, .{
        .created_ts = io.timestamp(),
        .ttl_s = ttl_s,
        .nonce = nonce,
        .plaintext_len = @intCast(bytes.len),
    }) orelse return;

    // out = header ++ ciphertext ++ tag.
    const total = pure.HEADER_LEN + bytes.len + pure.TAG_LEN;
    const out = alloc.alloc(u8, total) catch return;
    defer alloc.free(out);
    @memcpy(out[0..pure.HEADER_LEN], header);

    var aad_buf: [pure.HEADER_LEN + 32]u8 = undefined;
    const aad = buildAad(&aad_buf, header, key);

    const c = out[pure.HEADER_LEN .. pure.HEADER_LEN + bytes.len];
    const tag = out[pure.HEADER_LEN + bytes.len ..][0..pure.TAG_LEN];
    XChaCha.encrypt(c, tag, bytes, aad, nonce, install_key);

    // Atomic write: temp file + rename.
    var path_buf: [700]u8 = undefined;
    const final = entryPath(&path_buf, key) orelse return;
    var tmp_buf: [740]u8 = undefined;
    const uniq = tmp_counter.fetchAdd(1, .monotonic);
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp{x}_{x}", .{ final, io.milliTimestamp(), uniq }) catch return;

    {
        const f = io.createFileAbsolute(tmp, .{ .truncate = true }) catch return;
        var write_ok = true;
        io.writeAll(f, out) catch {
            write_ok = false;
        };
        f.close(io.io());
        if (!write_ok) {
            io.deleteFileAbsolute(tmp) catch {};
            return;
        }
    }
    io.renameAbsolute(tmp, final) catch {
        io.deleteFileAbsolute(tmp) catch {};
    };
}

// ──────────────────────────── get ────────────────────────────

/// Read + decrypt + verify the entry for `key` into `out_buf`. Returns the
/// plaintext slice plus its staleness, or null on miss (absent / disabled /
/// out_buf too small / corrupt / expired). Corrupt or expired files are
/// deleted. Never crashes.
pub fn get(key: []const u8, out_buf: []u8) ?Hit {
    if (!active()) return null;

    var path_buf: [700]u8 = undefined;
    const path = entryPath(&path_buf, key) orelse return null;

    const f = io.openFileAbsolute(path, .{}) catch return null;
    const raw = io.readToEndAlloc(f, alloc, pure.HEADER_LEN + pure.MAX_ENTRY_BYTES + pure.TAG_LEN) catch {
        f.close(io.io());
        return null;
    };
    f.close(io.io());
    defer alloc.free(raw);

    const header = pure.decodeHeader(raw) orelse {
        // Corrupt / unknown format → drop it.
        io.deleteFileAbsolute(path) catch {};
        return null;
    };

    const plen = header.plaintext_len;
    if (out_buf.len < plen) return null; // caller buffer too small — treat as miss

    var aad_buf: [pure.HEADER_LEN + 32]u8 = undefined;
    const aad = buildAad(&aad_buf, raw[0..pure.HEADER_LEN], key);

    const c = raw[pure.HEADER_LEN..][0..plen];
    const tag: [pure.TAG_LEN]u8 = raw[pure.HEADER_LEN + plen ..][0..pure.TAG_LEN].*;
    XChaCha.decrypt(out_buf[0..plen], c, tag, aad, header.nonce, install_key) catch {
        // Wrong key / tampered → drop it, miss.
        io.deleteFileAbsolute(path) catch {};
        return null;
    };

    const st = pure.staleness(header.created_ts, header.ttl_s, io.timestamp());
    if (st == .expired) {
        io.deleteFileAbsolute(path) catch {};
        return null;
    }
    return .{ .bytes = out_buf[0..plen], .staleness = st };
}

// ──────────────────────────── sweep / maintenance ────────────────────────────

const EntryMeta = struct { created_ts: i64, size: u64, name_hash: [pure.FILENAME_HEX_LEN]u8 };

/// Drop expired entries (older than the hard-max) and corrupt files, then, if
/// still over the size cap, evict oldest-first until back under. Call once at
/// launch on a background thread.
pub fn purgeExpired() void {
    if (!key_ok.load(.acquire)) return; // key required to read headers meaningfully
    var dir_buf: [512]u8 = undefined;
    const dir_path = contentDir(&dir_buf) orelse return;
    var dir = io.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io.io());

    const now = io.timestamp();
    var metas: std.ArrayListUnmanaged(EntryMeta) = .empty;
    defer metas.deinit(alloc);
    var total: u64 = 0;

    var it = dir.iterate();
    while (it.next(io.io()) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".bin")) {
            // Sweep stale temp files from crashed writes.
            if (std.mem.indexOf(u8, entry.name, ".tmp") != null) {
                var tp: [700]u8 = undefined;
                const p = std.fmt.bufPrint(&tp, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
                io.deleteFileAbsolute(p) catch {};
            }
            continue;
        }
        var fp: [700]u8 = undefined;
        const p = std.fmt.bufPrint(&fp, "{s}/{s}", .{ dir_path, entry.name }) catch continue;

        // Read just the header to classify.
        const f = io.openFileAbsolute(p, .{}) catch continue;
        var hbuf: [pure.HEADER_LEN]u8 = undefined;
        const n = io.readAll(f, &hbuf) catch 0;
        const size = f.length(io.io()) catch 0;
        f.close(io.io());

        // Bounds-tolerant decode: append a dummy trailer sizer by checking only
        // the fixed header. decodeHeader needs the full-file length check, so
        // classify from a header-only parse of the fields.
        if (n < pure.HEADER_LEN) {
            io.deleteFileAbsolute(p) catch {};
            continue;
        }
        // Validate magic/version cheaply; anything else is corrupt → delete.
        if (!std.mem.eql(u8, hbuf[0..4], &pure.MAGIC) or hbuf[4] != pure.VERSION) {
            io.deleteFileAbsolute(p) catch {};
            continue;
        }
        const created_ts = std.mem.readInt(i64, hbuf[5..][0..8], .little);
        if (pure.shouldPurge(created_ts, now, pure.HARD_MAX_S)) {
            io.deleteFileAbsolute(p) catch {};
            continue;
        }
        var m = EntryMeta{ .created_ts = created_ts, .size = size, .name_hash = undefined };
        const copy_len = @min(entry.name.len, pure.FILENAME_HEX_LEN);
        @memcpy(m.name_hash[0..copy_len], entry.name[0..copy_len]);
        metas.append(alloc, m) catch {};
        total += size;
    }

    // Size cap: evict oldest-first.
    if (total > pure.SIZE_CAP_BYTES and metas.items.len > 0) {
        std.mem.sort(EntryMeta, metas.items, {}, struct {
            fn lt(_: void, a: EntryMeta, b: EntryMeta) bool {
                return a.created_ts < b.created_ts;
            }
        }.lt);
        var sizes = alloc.alloc(u64, metas.items.len) catch return;
        defer alloc.free(sizes);
        for (metas.items, 0..) |m, i| sizes[i] = m.size;
        const n_evict = pure.evictionCount(sizes, total, pure.SIZE_CAP_BYTES);
        var i: usize = 0;
        while (i < n_evict) : (i += 1) {
            var fp: [700]u8 = undefined;
            const p = std.fmt.bufPrint(&fp, "{s}/{s}.bin", .{ dir_path, metas.items[i].name_hash }) catch continue;
            io.deleteFileAbsolute(p) catch {};
        }
    }
}

/// Delete every cached entry (settings "Clear cache"). Leaves the key intact.
pub fn clearAll() void {
    var dir_buf: [512]u8 = undefined;
    const dir_path = paths.cacheFile(&dir_buf, "content");
    io.cwdDeleteTree(dir_path) catch {};
    logs.pushLog("info", "cache", "Content cache cleared", false);
}

/// Total on-disk size (bytes) of all cached entries — for the settings label.
pub fn sizeBytes() u64 {
    var dir_buf: [512]u8 = undefined;
    const dir_path = paths.cacheFile(&dir_buf, "content");
    var dir = io.openDirAbsolute(dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close(io.io());
    var total: u64 = 0;
    var it = dir.iterate();
    while (it.next(io.io()) catch null) |entry| {
        if (entry.kind != .file) continue;
        var fp: [700]u8 = undefined;
        const p = std.fmt.bufPrint(&fp, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        const f = io.openFileAbsolute(p, .{}) catch continue;
        total += f.length(io.io()) catch 0;
        f.close(io.io());
    }
    return total;
}
