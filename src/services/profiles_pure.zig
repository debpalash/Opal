//! Household profiles — the pure rules (ROADMAP 7.3).
//!
//! Everything here is deterministic and allocation-free except the TMDB
//! certification parser: the registry text format, name/colour/id/PIN
//! validation, PIN hashing (PBKDF2-HMAC-SHA256, random salt supplied by the
//! caller) with constant-time verify, failed-attempt backoff, the "who must
//! enter a PIN" policy, and maturity gating (certification -> minimum age ->
//! allow/deny for a profile's cap). services/profiles.zig adds the clock,
//! entropy, files and the process restart.

const std = @import("std");

pub const MAX_PROFILES: usize = 8;
pub const ID_MAX: usize = 16;
pub const NAME_MAX: usize = 24;
pub const HASH_MAX: usize = 128;
pub const DEFAULT_ID = "default";
pub const DEFAULT_NAME = "Main";

/// No maturity cap (adult profile).
pub const NO_CAP: u8 = 255;
/// Cap a new kid profile starts with.
pub const KID_DEFAULT_CAP: u8 = 12;
/// Caps offered in Settings, in display order.
pub const CAP_CHOICES = [_]u8{ 7, 10, 12, 13, 16, 18 };

pub const PIN_MIN: usize = 4;
pub const PIN_MAX: usize = 8;
pub const PBKDF2_ROUNDS: u32 = 60_000;
pub const SALT_LEN: usize = 16;
const DK_LEN: usize = 32;

// ── Colours ──────────────────────────────────────────────────────────────────
// Stored by name; the UI maps each to a theme token (never an RGB literal), so
// avatars follow the active preset.
pub const Color = enum { accent, green, amber, red, slate };

pub fn colorName(c: Color) []const u8 {
    return @tagName(c);
}

pub fn parseColor(name: []const u8) ?Color {
    return std.meta.stringToEnum(Color, name);
}

// ── Profile + registry ───────────────────────────────────────────────────────

pub const Profile = struct {
    id: [ID_MAX]u8 = std.mem.zeroes([ID_MAX]u8),
    id_len: u8 = 0,
    name: [NAME_MAX]u8 = std.mem.zeroes([NAME_MAX]u8),
    name_len: u8 = 0,
    color: Color = .accent,
    kid: bool = false,
    /// Highest minimum-age a title may carry (NO_CAP = unrestricted).
    max_age: u8 = NO_CAP,
    /// Kid profiles only: whether a title with no known rating may play.
    allow_unrated: bool = false,
    pin_hash: [HASH_MAX]u8 = std.mem.zeroes([HASH_MAX]u8),
    pin_hash_len: u8 = 0,
    created: i64 = 0,

    pub fn idText(self: *const Profile) []const u8 {
        return self.id[0..self.id_len];
    }
    pub fn nameText(self: *const Profile) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn pinHash(self: *const Profile) []const u8 {
        return self.pin_hash[0..self.pin_hash_len];
    }
    pub fn hasPin(self: *const Profile) bool {
        return self.pin_hash_len > 0;
    }
    pub fn isDefault(self: *const Profile) bool {
        return std.mem.eql(u8, self.idText(), DEFAULT_ID);
    }
    /// The cap that is actually enforced: adults are never capped.
    pub fn effectiveCap(self: *const Profile) u8 {
        return if (self.kid) self.max_age else NO_CAP;
    }
    pub fn setId(self: *Profile, id: []const u8) void {
        const n = @min(id.len, ID_MAX);
        @memcpy(self.id[0..n], id[0..n]);
        self.id_len = @intCast(n);
    }
    pub fn setName(self: *Profile, name: []const u8) void {
        const n = @min(name.len, NAME_MAX);
        @memcpy(self.name[0..n], name[0..n]);
        self.name_len = @intCast(n);
    }
    pub fn setPinHash(self: *Profile, encoded: []const u8) void {
        const n = @min(encoded.len, HASH_MAX);
        @memcpy(self.pin_hash[0..n], encoded[0..n]);
        self.pin_hash_len = @intCast(n);
    }
};

pub const Registry = struct {
    profiles: [MAX_PROFILES]Profile = [_]Profile{.{}} ** MAX_PROFILES,
    count: usize = 0,
    /// The profile the NEXT launch opens (the running one is fixed per process).
    active: [ID_MAX]u8 = std.mem.zeroes([ID_MAX]u8),
    active_len: u8 = 0,

    pub fn activeId(self: *const Registry) []const u8 {
        return self.active[0..self.active_len];
    }
    pub fn setActive(self: *Registry, id: []const u8) void {
        const n = @min(id.len, ID_MAX);
        @memcpy(self.active[0..n], id[0..n]);
        self.active_len = @intCast(n);
    }
    pub fn find(self: *const Registry, id: []const u8) ?usize {
        for (self.profiles[0..self.count], 0..) |*p, i| {
            if (std.mem.eql(u8, p.idText(), id)) return i;
        }
        return null;
    }
    pub fn get(self: *Registry, id: []const u8) ?*Profile {
        const i = self.find(id) orelse return null;
        return &self.profiles[i];
    }
    pub fn defaultProfile(self: *const Registry) ?*const Profile {
        const i = self.find(DEFAULT_ID) orelse return null;
        return &self.profiles[i];
    }
    /// Case-insensitive name clash with any profile other than `except_id`.
    pub fn nameTaken(self: *const Registry, name: []const u8, except_id: []const u8) bool {
        const want = std.mem.trim(u8, name, " ");
        for (self.profiles[0..self.count]) |*p| {
            if (std.mem.eql(u8, p.idText(), except_id)) continue;
            if (std.ascii.eqlIgnoreCase(p.nameText(), want)) return true;
        }
        return false;
    }
    /// Profiles a picker must be shown for: more than one, or a PIN anywhere.
    pub fn needsPicker(self: *const Registry) bool {
        if (self.count > 1) return true;
        for (self.profiles[0..self.count]) |*p| if (p.hasPin()) return true;
        return false;
    }
    pub fn add(self: *Registry, p: Profile) error{Full}!void {
        if (self.count >= MAX_PROFILES) return error.Full;
        self.profiles[self.count] = p;
        self.count += 1;
    }
    /// Remove a non-default profile. If it was the next-launch profile, the
    /// default takes over.
    pub fn remove(self: *Registry, id: []const u8) error{ NotFound, Default }!void {
        if (std.mem.eql(u8, id, DEFAULT_ID)) return error.Default;
        const i = self.find(id) orelse return error.NotFound;
        var j = i;
        while (j + 1 < self.count) : (j += 1) self.profiles[j] = self.profiles[j + 1];
        self.count -= 1;
        self.profiles[self.count] = .{};
        if (std.mem.eql(u8, self.activeId(), id)) self.setActive(DEFAULT_ID);
    }
    /// The registry always holds the default profile, first.
    pub fn ensureDefault(self: *Registry) void {
        if (self.find(DEFAULT_ID)) |i| {
            if (i == 0) return;
            const d = self.profiles[i];
            var j = i;
            while (j > 0) : (j -= 1) self.profiles[j] = self.profiles[j - 1];
            self.profiles[0] = d;
            return;
        }
        if (self.count >= MAX_PROFILES) self.count = MAX_PROFILES - 1;
        var j = self.count;
        while (j > 0) : (j -= 1) self.profiles[j] = self.profiles[j - 1];
        var d: Profile = .{};
        d.setId(DEFAULT_ID);
        d.setName(DEFAULT_NAME);
        self.profiles[0] = d;
        self.count += 1;
    }
};

// ── Validation ───────────────────────────────────────────────────────────────

pub const NameError = error{ Empty, TooLong, BadCharacter };

/// Display names: 1..NAME_MAX bytes after trimming spaces, valid UTF-8, no
/// control characters (tabs/newlines would corrupt the registry format).
pub fn validateName(raw: []const u8) NameError![]const u8 {
    const name = std.mem.trim(u8, raw, " ");
    if (name.len == 0) return error.Empty;
    if (name.len > NAME_MAX) return error.TooLong;
    if (!std.unicode.utf8ValidateSlice(name)) return error.BadCharacter;
    for (name) |ch| if (ch < 0x20 or ch == 0x7f) return error.BadCharacter;
    return name;
}

/// "default", or exactly 16 lowercase hex characters. Ids name directories, so
/// nothing else (no dots, slashes or separators) is ever accepted.
pub fn validId(id: []const u8) bool {
    if (std.mem.eql(u8, id, DEFAULT_ID)) return true;
    if (id.len != ID_MAX) return false;
    for (id) |ch| if (!((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'))) return false;
    return true;
}

/// Hex-encode 8 random bytes into a profile id.
pub fn idFromBytes(bytes: [ID_MAX / 2]u8, out: *[ID_MAX]u8) []const u8 {
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out[0..];
}

pub fn validPin(pin: []const u8) bool {
    if (pin.len < PIN_MIN or pin.len > PIN_MAX) return false;
    for (pin) |ch| if (ch < '0' or ch > '9') return false;
    return true;
}

// ── PIN hashing ──────────────────────────────────────────────────────────────
// Encoded as `pbkdf2-sha256$<rounds>$<salt hex>$<dk hex>`. The salt is random
// per PIN (caller supplies CSPRNG bytes); verification re-derives with the
// stored rounds and compares in constant time.

const Prf = std.crypto.auth.hmac.sha2.HmacSha256;
const SCHEME = "pbkdf2-sha256";

pub fn hashPin(pin: []const u8, salt: [SALT_LEN]u8, rounds: u32, out: *[HASH_MAX]u8) ?[]const u8 {
    if (!validPin(pin) or rounds == 0) return null;
    var dk: [DK_LEN]u8 = undefined;
    std.crypto.pwhash.pbkdf2(&dk, pin, &salt, rounds, Prf) catch return null;
    const salt_hex = std.fmt.bytesToHex(salt, .lower);
    const dk_hex = std.fmt.bytesToHex(dk, .lower);
    return std.fmt.bufPrint(out, SCHEME ++ "${d}${s}${s}", .{ rounds, &salt_hex, &dk_hex }) catch null;
}

pub fn verifyPin(pin: []const u8, encoded: []const u8) bool {
    if (!validPin(pin)) return false;
    var it = std.mem.splitScalar(u8, encoded, '$');
    const scheme = it.next() orelse return false;
    if (!std.mem.eql(u8, scheme, SCHEME)) return false;
    const rounds = std.fmt.parseInt(u32, it.next() orelse return false, 10) catch return false;
    if (rounds == 0 or rounds > 10_000_000) return false;
    const salt_hex = it.next() orelse return false;
    const dk_hex = it.next() orelse return false;
    if (it.next() != null) return false;
    if (salt_hex.len != SALT_LEN * 2 or dk_hex.len != DK_LEN * 2) return false;
    var salt: [SALT_LEN]u8 = undefined;
    _ = std.fmt.hexToBytes(&salt, salt_hex) catch return false;
    var want: [DK_LEN]u8 = undefined;
    _ = std.fmt.hexToBytes(&want, dk_hex) catch return false;
    var got: [DK_LEN]u8 = undefined;
    std.crypto.pwhash.pbkdf2(&got, pin, &salt, rounds, Prf) catch return false;
    return std.crypto.timing_safe.eql([DK_LEN]u8, got, want);
}

// ── Attempt backoff ──────────────────────────────────────────────────────────
// Three free tries, then a lockout that doubles from 30 s up to 15 min. A
// four-digit PIN has only 10^4 values; the backoff, not the KDF, is what makes
// guessing at the keyboard or over the API impractical.

pub const FREE_ATTEMPTS: u8 = 3;
pub const BASE_LOCK_MS: i64 = 30_000;
pub const MAX_LOCK_MS: i64 = 15 * 60_000;

pub const Backoff = struct {
    failures: u8 = 0,
    locked_until_ms: i64 = 0,

    /// Milliseconds until another attempt is allowed (0 = now).
    pub fn retryAfterMs(self: *const Backoff, now_ms: i64) i64 {
        return @max(0, self.locked_until_ms - now_ms);
    }
    pub fn recordFailure(self: *Backoff, now_ms: i64) void {
        if (self.failures < 255) self.failures += 1;
        self.locked_until_ms = now_ms + lockMs(self.failures);
    }
    pub fn recordSuccess(self: *Backoff) void {
        self.* = .{};
    }
};

pub fn lockMs(failures: u8) i64 {
    if (failures < FREE_ATTEMPTS) return 0;
    const shift: u6 = @intCast(@min(failures - FREE_ATTEMPTS, 10));
    return @min(MAX_LOCK_MS, BASE_LOCK_MS << shift);
}

// ── Switching policy ─────────────────────────────────────────────────────────

pub const PinSource = enum { none, target, owner };

/// Whose PIN unlocks a switch to `target`. A profile with its own PIN always
/// asks for it. Leaving a kid profile for an unlocked grown-up profile asks for
/// the owner's (default profile's) PIN, so kid mode cannot be walked out of;
/// with no PIN anywhere the household chose not to lock it.
pub fn pinSourceFor(from_kid: bool, target: *const Profile, owner_has_pin: bool) PinSource {
    if (target.hasPin()) return .target;
    if (from_kid and !target.kid and owner_has_pin) return .owner;
    return .none;
}

/// Only the default (owner) profile manages the household: create, delete and
/// edit other profiles. Every grown-up profile may edit its own name, colour
/// and PIN. Kid profiles manage nothing (Settings is hidden for them).
pub fn canEdit(running: *const Profile, target_id: []const u8) bool {
    if (running.kid) return false;
    if (running.isDefault()) return true;
    return std.mem.eql(u8, running.idText(), target_id);
}

// ── Maturity ─────────────────────────────────────────────────────────────────

const AgeEntry = struct { cert: []const u8, age: u8 };

/// Certification -> minimum age. Case-insensitive, after trimming. Covers US
/// film (MPA) + TV parental guidelines, UK BBFC, DE FSK, FR CNC, IN CBFC, JP
/// Eirin, and MyAnimeList/Jikan anime ratings. Ambiguous short codes resolve to
/// the stricter reading (e.g. "R" -> 17).
const AGE_TABLE = [_]AgeEntry{
    // US film
    .{ .cert = "G", .age = 0 },         .{ .cert = "PG", .age = 8 },       .{ .cert = "PG-13", .age = 13 },
    .{ .cert = "R", .age = 17 },        .{ .cert = "NC-17", .age = 18 },   .{ .cert = "X", .age = 18 },
    // US TV
    .{ .cert = "TV-Y", .age = 0 },      .{ .cert = "TV-Y7", .age = 7 },    .{ .cert = "TV-Y7-FV", .age = 7 },
    .{ .cert = "TV-G", .age = 0 },      .{ .cert = "TV-PG", .age = 8 },    .{ .cert = "TV-14", .age = 14 },
    .{ .cert = "TV-MA", .age = 17 },
    // UK
    .{ .cert = "U", .age = 0 },         .{ .cert = "Uc", .age = 0 },       .{ .cert = "12A", .age = 12 },
    .{ .cert = "12", .age = 12 },       .{ .cert = "15", .age = 15 },      .{ .cert = "18", .age = 18 },
    .{ .cert = "R18", .age = 18 },
    // DE (FSK)
    .{ .cert = "0", .age = 0 },         .{ .cert = "6", .age = 6 },        .{ .cert = "16", .age = 16 },
    .{ .cert = "FSK 0", .age = 0 },     .{ .cert = "FSK 6", .age = 6 },    .{ .cert = "FSK 12", .age = 12 },
    .{ .cert = "FSK 16", .age = 16 },   .{ .cert = "FSK 18", .age = 18 },
    // FR
    .{ .cert = "TP", .age = 0 },        .{ .cert = "10", .age = 10 },      .{ .cert = "-10", .age = 10 },
    .{ .cert = "-12", .age = 12 },      .{ .cert = "-16", .age = 16 },     .{ .cert = "-18", .age = 18 },
    // IN (CBFC)
    .{ .cert = "UA", .age = 12 },       .{ .cert = "U/A", .age = 12 },     .{ .cert = "UA 7+", .age = 7 },
    .{ .cert = "UA 13+", .age = 13 },   .{ .cert = "UA 16+", .age = 16 },  .{ .cert = "A", .age = 18 },
    .{ .cert = "S", .age = 18 },
    // JP (Eirin)
    .{ .cert = "PG12", .age = 12 },     .{ .cert = "R15+", .age = 15 },    .{ .cert = "R18+", .age = 18 },
    // Generic numeric ages seen across TMDB regions
    .{ .cert = "7", .age = 7 },         .{ .cert = "13", .age = 13 },      .{ .cert = "14", .age = 14 },
    .{ .cert = "17", .age = 17 },
    // MyAnimeList / Jikan (full strings are matched by prefix below)
    .{ .cert = "R+", .age = 17 },       .{ .cert = "Rx", .age = 18 },
};

/// Minimum age for a certification string, or null when unknown/unrated
/// ("NR", "Unrated", empty, anything not in the table).
pub fn certAge(raw: []const u8) ?u8 {
    var cert = std.mem.trim(u8, raw, " \t\r\n");
    // Jikan: "PG-13 - Teens 13 or older", "R - 17+ (violence & profanity)".
    if (std.mem.indexOf(u8, cert, " - ")) |i| cert = cert[0..i];
    if (cert.len == 0) return null;
    for (AGE_TABLE) |e| {
        if (std.ascii.eqlIgnoreCase(e.cert, cert)) return e.age;
    }
    return null;
}

/// The allow/deny decision. `cap` NO_CAP admits everything; otherwise a known
/// age must be within the cap and an unknown one follows `allow_unrated`
/// (kid profiles default to deny).
pub fn maturityAllows(cap: u8, age: ?u8, allow_unrated: bool) bool {
    if (cap == NO_CAP) return true;
    const a = age orelse return allow_unrated;
    return a <= cap;
}

/// Minimum age from a TMDB `/movie/{id}/release_dates` or
/// `/tv/{id}/content_ratings` body. The preferred country's rating wins when
/// present; otherwise the strictest known rating across all countries.
pub fn tmdbAge(allocator: std.mem.Allocator, json: []const u8, country: []const u8) ?u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return null;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const results = switch (root.get("results") orelse return null) {
        .array => |a| a,
        else => return null,
    };
    var preferred: ?u8 = null;
    var strictest: ?u8 = null;
    for (results.items) |entry| {
        const obj = switch (entry) {
            .object => |o| o,
            else => continue,
        };
        const iso = switch (obj.get("iso_3166_1") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        var region_age: ?u8 = null;
        // TV content_ratings: {"rating":"TV-14"}
        if (obj.get("rating")) |r| switch (r) {
            .string => |s| region_age = certAge(s),
            else => {},
        };
        // Movie release_dates: {"release_dates":[{"certification":"PG-13"},...]}
        if (obj.get("release_dates")) |rd| switch (rd) {
            .array => |arr| for (arr.items) |d| {
                const dobj = switch (d) {
                    .object => |o| o,
                    else => continue,
                };
                const cert = switch (dobj.get("certification") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                if (certAge(cert)) |a| region_age = if (region_age) |cur| @max(cur, a) else a;
            },
            else => {},
        };
        const a = region_age orelse continue;
        if (std.ascii.eqlIgnoreCase(iso, country)) preferred = a;
        strictest = if (strictest) |cur| @max(cur, a) else a;
    }
    return preferred orelse strictest;
}

// ── New-profile config seed ──────────────────────────────────────────────────

/// Whether a household config row is copied into a newly created profile's
/// database. Shared setup (sources, keys, server logins, web remote, theme,
/// install id) carries over; per-person state does not: sync peers + cursors
/// (each profile has its own sync identity), the open-player session, usage.
pub fn seedsConfigKey(key: []const u8) bool {
    const skip_prefixes = [_][]const u8{ "lsync_", "session_" };
    for (skip_prefixes) |p| if (std.mem.startsWith(u8, key, p)) return false;
    return !std.mem.eql(u8, key, "usage_seconds");
}

// ── Registry text format ─────────────────────────────────────────────────────
//   opal-profiles\t1
//   active\t<id>
//   p\t<id>\t<name>\t<color>\t<kid 0|1>\t<max_age>\t<allow_unrated 0|1>\t<pin hash or empty>\t<created>
// Malformed or duplicate lines are skipped; the default profile is always
// present afterwards. Unknown keys are ignored (forward compatible).

pub const HEADER = "opal-profiles\t1";

pub fn parse(text: []const u8, reg: *Registry) void {
    reg.* = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        var f = std.mem.splitScalar(u8, line, '\t');
        const tag = f.next() orelse continue;
        if (std.mem.eql(u8, tag, "active")) {
            const id = f.next() orelse continue;
            if (validId(id)) reg.setActive(id);
            continue;
        }
        if (!std.mem.eql(u8, tag, "p")) continue;
        const id = f.next() orelse continue;
        const name_raw = f.next() orelse continue;
        const color_raw = f.next() orelse continue;
        const kid_raw = f.next() orelse continue;
        const age_raw = f.next() orelse continue;
        const unrated_raw = f.next() orelse continue;
        const pin_raw = f.next() orelse continue;
        const created_raw = f.next() orelse "0";
        if (!validId(id) or reg.find(id) != null) continue;
        const name = validateName(name_raw) catch continue;
        if (reg.nameTaken(name, id)) continue;
        if (pin_raw.len > HASH_MAX) continue;
        var p: Profile = .{};
        p.setId(id);
        p.setName(name);
        p.color = parseColor(color_raw) orelse .accent;
        p.kid = std.mem.eql(u8, kid_raw, "1");
        p.max_age = std.fmt.parseInt(u8, age_raw, 10) catch (if (p.kid) KID_DEFAULT_CAP else NO_CAP);
        p.allow_unrated = std.mem.eql(u8, unrated_raw, "1");
        p.setPinHash(pin_raw);
        p.created = std.fmt.parseInt(i64, created_raw, 10) catch 0;
        // The owner profile is never a kid profile.
        if (p.isDefault()) p.kid = false;
        reg.add(p) catch break;
    }
    reg.ensureDefault();
    if (reg.active_len == 0 or reg.find(reg.activeId()) == null) reg.setActive(DEFAULT_ID);
}

pub fn serialize(reg: *const Registry, out: []u8) ?[]const u8 {
    var w = std.Io.Writer.fixed(out);
    w.print(HEADER ++ "\nactive\t{s}\n", .{reg.activeId()}) catch return null;
    for (reg.profiles[0..reg.count]) |*p| {
        w.print("p\t{s}\t{s}\t{s}\t{d}\t{d}\t{d}\t{s}\t{d}\n", .{
            p.idText(),        p.nameText(),                      colorName(p.color),
            @intFromBool(p.kid), p.max_age,                       @intFromBool(p.allow_unrated),
            p.pinHash(),       p.created,
        }) catch return null;
    }
    return w.buffered();
}

/// Upper bound for a serialized registry.
pub const SERIALIZED_MAX: usize = 64 + MAX_PROFILES * (ID_MAX + NAME_MAX + HASH_MAX + 64);

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

const T = std.testing;

test "names: trimmed, bounded, no control characters" {
    try T.expectEqualStrings("Ana", try validateName("  Ana "));
    try T.expectError(error.Empty, validateName("   "));
    try T.expectError(error.TooLong, validateName("abcdefghijklmnopqrstuvwxyz"));
    try T.expectError(error.BadCharacter, validateName("a\tb"));
    try T.expectError(error.BadCharacter, validateName("a\nb"));
    try T.expectError(error.BadCharacter, validateName("\xff\xfe"));
    _ = try validateName("Zoë");
}

test "ids name directories: default or 16 lowercase hex only" {
    try T.expect(validId("default"));
    try T.expect(validId("0123456789abcdef"));
    try T.expect(!validId("0123456789ABCDEF"));
    try T.expect(!validId("../../etc/passwd"));
    try T.expect(!validId("0123456789abcde"));
    try T.expect(!validId(""));
    var buf: [ID_MAX]u8 = undefined;
    try T.expectEqualStrings("00ff10a0deadbeef", idFromBytes(.{ 0x00, 0xff, 0x10, 0xa0, 0xde, 0xad, 0xbe, 0xef }, &buf));
}

test "colours parse by name only" {
    try T.expectEqual(Color.green, parseColor("green").?);
    try T.expect(parseColor("#ff0000") == null);
    try T.expect(parseColor("") == null);
}

test "pin: digits only, 4-8 long" {
    try T.expect(validPin("1234"));
    try T.expect(validPin("12345678"));
    try T.expect(!validPin("123"));
    try T.expect(!validPin("123456789"));
    try T.expect(!validPin("12a4"));
}

test "pin hash round-trips, salts differ, wrong pin and tampering fail" {
    var a_buf: [HASH_MAX]u8 = undefined;
    var b_buf: [HASH_MAX]u8 = undefined;
    const a = hashPin("2468", [_]u8{1} ** SALT_LEN, 1000, &a_buf).?;
    const b = hashPin("2468", [_]u8{2} ** SALT_LEN, 1000, &b_buf).?;
    try T.expect(std.mem.startsWith(u8, a, "pbkdf2-sha256$1000$"));
    try T.expect(!std.mem.eql(u8, a, b)); // per-PIN random salt
    try T.expect(verifyPin("2468", a));
    try T.expect(verifyPin("2468", b));
    try T.expect(!verifyPin("2469", a));
    try T.expect(!verifyPin("", a));
    // Tampered digest / scheme / shape never verify.
    var t_buf: [HASH_MAX]u8 = undefined;
    @memcpy(t_buf[0..a.len], a);
    t_buf[a.len - 1] = if (a[a.len - 1] == '0') '1' else '0';
    try T.expect(!verifyPin("2468", t_buf[0..a.len]));
    try T.expect(!verifyPin("2468", "bcrypt$1000$aa$bb"));
    try T.expect(!verifyPin("2468", "pbkdf2-sha256$0$00$00"));
    try T.expect(!verifyPin("2468", ""));
    try T.expect(hashPin("12", [_]u8{1} ** SALT_LEN, 1000, &a_buf) == null);
}

test "backoff: three free attempts then doubling lockout, capped" {
    var b: Backoff = .{};
    b.recordFailure(1000);
    b.recordFailure(1000);
    try T.expectEqual(@as(i64, 0), b.retryAfterMs(1000));
    b.recordFailure(1000);
    try T.expectEqual(@as(i64, 30_000), b.retryAfterMs(1000));
    try T.expectEqual(@as(i64, 0), b.retryAfterMs(31_000));
    b.recordFailure(31_000);
    try T.expectEqual(@as(i64, 60_000), b.retryAfterMs(31_000));
    var i: usize = 0;
    while (i < 40) : (i += 1) b.recordFailure(0);
    try T.expectEqual(MAX_LOCK_MS, b.retryAfterMs(0));
    b.recordSuccess();
    try T.expectEqual(@as(i64, 0), b.retryAfterMs(0));
}

test "pin source: own pin, kid exit needs owner pin, unlocked household" {
    var adult: Profile = .{};
    adult.setId("0123456789abcdef");
    var locked = adult;
    locked.setPinHash("pbkdf2-sha256$1$00$00");
    var kid2 = adult;
    kid2.kid = true;
    try T.expectEqual(PinSource.target, pinSourceFor(false, &locked, false));
    try T.expectEqual(PinSource.target, pinSourceFor(true, &locked, true));
    try T.expectEqual(PinSource.owner, pinSourceFor(true, &adult, true));
    try T.expectEqual(PinSource.none, pinSourceFor(true, &adult, false));
    try T.expectEqual(PinSource.none, pinSourceFor(false, &adult, true));
    try T.expectEqual(PinSource.none, pinSourceFor(true, &kid2, true)); // kid -> kid
}

test "edit rights: owner manages all, adults themselves, kids nothing" {
    var owner: Profile = .{};
    owner.setId(DEFAULT_ID);
    var adult: Profile = .{};
    adult.setId("0123456789abcdef");
    var kid: Profile = adult;
    kid.kid = true;
    try T.expect(canEdit(&owner, "0123456789abcdef"));
    try T.expect(canEdit(&adult, "0123456789abcdef"));
    try T.expect(!canEdit(&adult, DEFAULT_ID));
    try T.expect(!canEdit(&kid, "0123456789abcdef"));
}

test "certifications map to minimum ages across regions" {
    try T.expectEqual(@as(?u8, 0), certAge("G"));
    try T.expectEqual(@as(?u8, 13), certAge("PG-13"));
    try T.expectEqual(@as(?u8, 17), certAge(" r "));
    try T.expectEqual(@as(?u8, 18), certAge("NC-17"));
    try T.expectEqual(@as(?u8, 7), certAge("TV-Y7"));
    try T.expectEqual(@as(?u8, 17), certAge("TV-MA"));
    try T.expectEqual(@as(?u8, 12), certAge("12A")); // UK
    try T.expectEqual(@as(?u8, 16), certAge("FSK 16")); // DE
    try T.expectEqual(@as(?u8, 16), certAge("16"));
    try T.expectEqual(@as(?u8, 10), certAge("-10")); // FR
    try T.expectEqual(@as(?u8, 18), certAge("A")); // IN
    try T.expectEqual(@as(?u8, 13), certAge("UA 13+"));
    try T.expectEqual(@as(?u8, 15), certAge("R15+")); // JP
    try T.expectEqual(@as(?u8, 13), certAge("PG-13 - Teens 13 or older")); // Jikan
    try T.expectEqual(@as(?u8, 18), certAge("Rx - Hentai"));
    try T.expectEqual(@as(?u8, null), certAge("NR"));
    try T.expectEqual(@as(?u8, null), certAge("Unrated"));
    try T.expectEqual(@as(?u8, null), certAge(""));
}

test "maturity decision: cap, unknown policy, adults unrestricted" {
    try T.expect(maturityAllows(NO_CAP, 18, false));
    try T.expect(maturityAllows(NO_CAP, null, false));
    try T.expect(maturityAllows(12, 12, false));
    try T.expect(!maturityAllows(12, 13, false));
    try T.expect(!maturityAllows(12, null, false)); // kids: unknown denied by default
    try T.expect(maturityAllows(12, null, true));
}

test "tmdb certification: preferred country, else strictest" {
    const movie =
        \\{"id":1,"results":[{"iso_3166_1":"DE","release_dates":[{"certification":"16"}]},
        \\{"iso_3166_1":"US","release_dates":[{"certification":""},{"certification":"PG-13"}]}]}
    ;
    try T.expectEqual(@as(?u8, 13), tmdbAge(T.allocator, movie, "US"));
    try T.expectEqual(@as(?u8, 16), tmdbAge(T.allocator, movie, "FR"));
    const tv =
        \\{"results":[{"iso_3166_1":"US","rating":"TV-Y7"},{"iso_3166_1":"GB","rating":"12"}]}
    ;
    try T.expectEqual(@as(?u8, 7), tmdbAge(T.allocator, tv, "us"));
    try T.expectEqual(@as(?u8, null), tmdbAge(T.allocator, "{\"results\":[]}", "US"));
    try T.expectEqual(@as(?u8, null), tmdbAge(T.allocator, "not json", "US"));
    try T.expectEqual(@as(?u8, null), tmdbAge(T.allocator, "{\"status_code\":34}", "US"));
}

test "registry round-trips and always holds the default first" {
    var reg: Registry = .{};
    parse("", &reg);
    try T.expectEqual(@as(usize, 1), reg.count);
    try T.expectEqualStrings(DEFAULT_ID, reg.activeId());
    var kid: Profile = .{};
    kid.setId("00000000000000aa");
    kid.setName("Kiddo");
    kid.kid = true;
    kid.max_age = 10;
    kid.color = .green;
    kid.created = 42;
    try reg.add(kid);
    reg.profiles[0].setPinHash("pbkdf2-sha256$1$aa$bb");
    reg.setActive("00000000000000aa");
    var buf: [SERIALIZED_MAX]u8 = undefined;
    const text = serialize(&reg, &buf).?;
    var back: Registry = .{};
    parse(text, &back);
    try T.expectEqual(@as(usize, 2), back.count);
    try T.expectEqualStrings("00000000000000aa", back.activeId());
    const k = back.get("00000000000000aa").?;
    try T.expect(k.kid);
    try T.expectEqual(@as(u8, 10), k.max_age);
    try T.expectEqual(Color.green, k.color);
    try T.expectEqual(@as(i64, 42), k.created);
    try T.expectEqualStrings("pbkdf2-sha256$1$aa$bb", back.profiles[0].pinHash());
    try T.expect(back.needsPicker());
}

test "registry parse rejects bad ids, dup names, path tricks; default never kid" {
    const text =
        "opal-profiles\t1\nactive\t../x\n" ++
        "p\tdefault\tMain\taccent\t1\t7\t0\t\t0\n" ++
        "p\t../../../../tmp\tEvil\tred\t0\t255\t0\t\t0\n" ++
        "p\t00000000000000bb\tmain\tred\t0\t255\t0\t\t0\n" ++
        "p\t00000000000000cc\tBob\tnope\t0\t255\t0\t\t0\n" ++
        "garbage line\n";
    var reg: Registry = .{};
    parse(text, &reg);
    try T.expectEqual(@as(usize, 2), reg.count);
    try T.expect(!reg.profiles[0].kid);
    try T.expectEqualStrings(DEFAULT_ID, reg.activeId());
    try T.expectEqual(Color.accent, reg.get("00000000000000cc").?.color);
    try T.expect(reg.find("00000000000000bb") == null);
    try T.expect(reg.nameTaken("BOB", DEFAULT_ID));
    try T.expect(!reg.nameTaken("Bob", "00000000000000cc"));
}

test "config seed: shared setup copies, sync identity + session do not" {
    try T.expect(seedsConfigKey("tmdb_api_key"));
    try T.expect(seedsConfigKey("web_port"));
    try T.expect(seedsConfigKey("onboarded"));
    try T.expect(!seedsConfigKey("lsync_p0_token"));
    try T.expect(!seedsConfigKey("lsync_peers"));
    try T.expect(!seedsConfigKey("session_url_0"));
    try T.expect(!seedsConfigKey("usage_seconds"));
}

test "remove: never the default; removing the next-launch profile falls back" {
    var reg: Registry = .{};
    parse("", &reg);
    var p: Profile = .{};
    p.setId("00000000000000dd");
    p.setName("Dee");
    try reg.add(p);
    reg.setActive("00000000000000dd");
    try T.expectError(error.Default, reg.remove(DEFAULT_ID));
    try T.expectError(error.NotFound, reg.remove("00000000000000ee"));
    try reg.remove("00000000000000dd");
    try T.expectEqual(@as(usize, 1), reg.count);
    try T.expectEqualStrings(DEFAULT_ID, reg.activeId());
    try T.expect(!reg.needsPicker());
}
