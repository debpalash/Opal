//! Curated Live TV source registry — the "index" of installable playlist
//! sources, shipped in the binary and offered opt-in in the Live TV settings
//! page. Each entry becomes a source_config plugin when the user installs it;
//! the catalog ingest worker (iptv.zig) then fetches + parses + stores its
//! channels into the SQLite catalog.
//!
//! WHY THESE AND NOT EVERYTHING
//! ----------------------------
//! A survey of github.com/topics/m3u found ~100k channels across many repos, but
//! most aggregate repos redistribute PAID/subscription streams (CN/TR operator
//! panels, Xtream link farms) or are ISP-LAN-only. This list is the vetted
//! subset that looks like legitimate free-to-air / public-domain indexing.
//! Adult channels are NOT dropped: ingest stores them flagged (nsfw=1) and the
//! catalog query gates them behind the NSFW setting. The curation here is about
//! provenance (FTA vs paid-redistribution), not about upstream cleanliness.
//!
//! Two distinct classes of source live here:
//!   • directory mirrors — iptv-org and its per-country/-region/-language/
//!     -category m3u indexes all resolve to the SAME streams; we ship only the
//!     one global iptv-org (+ its full index, opt-in) and skip the rest as pure
//!     duplicates. Third-party "verified working" aggregators (e.g.
//!     Romaxa55/world_ip_tv) were also checked and rejected: their upstream is
//!     literally iptv-org's country lists, so they add zero distinct streams.
//!   • distinct catalogs — TDTChannels (official Spanish/PT DTT) and the FAST
//!     providers (Pluto TV, Samsung TV+, Plex, Roku, Tubi) carry their OWN
//!     streams, largely disjoint from iptv-org and from each other. These are
//!     the real coverage add and are all opt-in.
//!
//! Pure (no core imports) so the registry and its helpers are unit-testable.

const std = @import("std");

/// How the source's endpoint is fetched and parsed.
///   base = iptv-org style JSON API: <url>/streams.json + logos.json + channels.json
///   m3u  = a single direct .m3u/.m3u8 playlist at <url>
pub const Kind = enum { base, m3u };

pub const Source = struct {
    /// source_config id (also the on-disk `<id>.json` stem). ASCII, no dots.
    id: []const u8,
    name: []const u8,
    kind: Kind,
    /// Base API URL (kind=base) or the raw playlist URL (kind=m3u).
    url: []const u8,
    region: []const u8,
    /// Short caveat surfaced in settings (staleness, scope). Empty if none.
    note: []const u8 = "",
    /// Rough channel count for the settings blurb (0 = unknown/varies).
    approx: u32 = 0,
    /// Installed by the onboarding starter pack / on by default for a fresh user.
    default_on: bool = false,
};

/// The curated index. Ordered best-first; the settings page renders them in this
/// order. iptv-org stays the default (it is the app's original Live TV source);
/// the rest are opt-in.
pub const SOURCES = [_]Source{
    .{
        .id = "iptv-org",
        .name = "iptv-org (global)",
        .kind = .base,
        .url = "https://iptv-org.github.io/api",
        .region = "Global",
        .approx = 13000,
        .default_on = true,
    },
    .{
        .id = "iptv-org-index",
        .name = "iptv-org — full index",
        .kind = .m3u,
        .url = "https://iptv-org.github.io/iptv/index.m3u",
        .region = "Global",
        .note = "The complete iptv-org playlist (more than the API window).",
        .approx = 13398,
    },
    .{
        .id = "free-tv",
        .name = "Free-TV",
        .kind = .m3u,
        .url = "https://raw.githubusercontent.com/Free-TV/IPTV/master/playlist.m3u8",
        .region = "Global",
        .note = "Curated free-to-air, actively maintained.",
        .approx = 1930,
        // A second globally-useful, maintained, adult-free index — on by default
        // so the catalog spans more of the world out of the box. Regional and
        // stale sources stay opt-in.
        .default_on = true,
    },
    .{
        .id = "m3upt",
        .name = "M3UPT (Portugal)",
        .kind = .m3u,
        .url = "https://raw.githubusercontent.com/LITUATUI/M3UPT/main/M3U/M3UPT.m3u",
        .region = "Portugal",
        .note = "Portuguese public/official TV, updated daily.",
        .approx = 1136,
        // Small, clean, actively maintained — on by default to widen coverage.
        .default_on = true,
    },
    .{
        .id = "iptv-italia",
        .name = "IPTV Italia",
        .kind = .m3u,
        .url = "https://raw.githubusercontent.com/Tundrak/IPTV-Italia/main/iptvita.m3u",
        .region = "Italy",
        .note = "Italian free-to-air. Frozen since 2024 — links may rot.",
        .approx = 71,
    },
    .{
        .id = "youtube-live",
        .name = "YouTube Live channels",
        .kind = .m3u,
        .url = "https://raw.githubusercontent.com/benmoose39/YouTube_to_m3u/main/youtube.m3u",
        .region = "Global",
        .note = "YouTube live streams as HLS. Stale since 2025 — some may be dead.",
        .approx = 259,
    },
    // ── Distinct catalogs (own streams, not iptv-org mirrors) ──
    .{
        .id = "tdtchannels",
        .name = "TDTChannels (Spain/Portugal)",
        .kind = .m3u,
        .url = "https://www.tdtchannels.com/lists/tv.m3u8",
        .region = "Spain/Portugal",
        .note = "Official Spanish/Portuguese/Andorran DTT (RTVE, etc.), maintained.",
        .approx = 547,
    },
    // FAST providers via BuddyChewChew/app-m3u-generator (GitHub Actions –
    // regenerated regularly). Each is a legal free ad-supported streaming
    // catalog with its OWN HLS streams; spot-checked live 2026-07. Community
    // build, so opt-in.
    .{
        .id = "pluto-tv",
        .name = "Pluto TV (FAST, all regions)",
        .kind = .m3u,
        .url = "https://raw.githubusercontent.com/BuddyChewChew/app-m3u-generator/main/playlists/plutotv_all.m3u",
        .region = "Global",
        .note = "Pluto TV free ad-supported channels, all regions.",
        .approx = 2819,
    },
    .{
        .id = "samsung-tvplus",
        .name = "Samsung TV Plus (FAST)",
        .kind = .m3u,
        .url = "https://raw.githubusercontent.com/BuddyChewChew/app-m3u-generator/main/playlists/samsungtvplus_all.m3u",
        .region = "Global",
        .note = "Samsung TV Plus free channels. A few regions geo-block.",
        .approx = 2573,
    },
    .{
        .id = "plex-tv",
        .name = "Plex (FAST)",
        .kind = .m3u,
        .url = "https://raw.githubusercontent.com/BuddyChewChew/app-m3u-generator/main/playlists/plex_all.m3u",
        .region = "Global",
        .note = "Plex free ad-supported live channels.",
        .approx = 2880,
    },
    .{
        .id = "roku-tv",
        .name = "The Roku Channel (FAST)",
        .kind = .m3u,
        .url = "https://raw.githubusercontent.com/BuddyChewChew/app-m3u-generator/main/playlists/roku_all.m3u",
        .region = "Global",
        .note = "The Roku Channel free live TV.",
        .approx = 353,
    },
    .{
        .id = "tubi-tv",
        .name = "Tubi (FAST)",
        .kind = .m3u,
        .url = "https://raw.githubusercontent.com/BuddyChewChew/app-m3u-generator/main/playlists/tubi_all.m3u",
        .region = "Global",
        .note = "Tubi free ad-supported live channels.",
        .approx = 179,
    },
};

/// The special id under which a user-pasted playlist URL is stored (Live TV
/// settings "custom URL" box). Not in SOURCES — it has no fixed URL.
pub const CUSTOM_ID = "iptv-custom";

/// Per-source ingest parse-buffer capacity, in rows. iptv.zig heap-allocates this
/// many IptvChannel records to parse ONE source, then frees them after inserting
/// into the catalog (the catalog itself is 100k-scale across all sources). Must
/// sit well above the largest single source or that source is silently truncated
/// at ingest: iptv-org's streams.json is the biggest (~17.5k stream objects and
/// growing; the old 20k cap left almost no slack), the full-index m3u ~13.4k.
/// ~1.7KB/row → ~100MB transient at 60k, freed immediately (heap, never the
/// worker stack, per CLAUDE.md). Kept here (pure) so the shipped cap is tested.
pub const INGEST_CAP: usize = 60000;

/// Look up a registry source by id (null if not a known curated source).
pub fn byId(id: []const u8) ?Source {
    for (SOURCES) |s| {
        if (std.mem.eql(u8, s.id, id)) return s;
    }
    return null;
}

/// The JSON body install() writes for a source, e.g. {"url":"https://…"} for an
/// m3u source or {"base":"https://…"} for a base source. The field name matters:
/// iptv.zig's iptvBase() reads "base", the catalog ingest reads "url".
pub fn installBody(s: Source, out: []u8) ?[]const u8 {
    const field = switch (s.kind) {
        .base => "base",
        .m3u => "url",
    };
    return std.fmt.bufPrint(out, "{{\"{s}\":\"{s}\"}}", .{ field, s.url }) catch null;
}

/// Detect the kind of an arbitrary user-supplied URL for the custom box: a
/// direct playlist link is m3u; anything else is treated as a base API root.
/// (In practice the custom box only accepts playlists, but this keeps the
/// classification in one tested place.)
pub fn kindOfUrl(url: []const u8) Kind {
    if (std.mem.endsWith(u8, url, ".m3u") or
        std.mem.endsWith(u8, url, ".m3u8") or
        std.mem.indexOf(u8, url, ".m3u?") != null)
    {
        return .m3u;
    }
    // A path ending in /api or a bare host → base; default to m3u otherwise
    // since the overwhelming majority of pasted Live TV links are playlists.
    if (std.mem.endsWith(u8, url, "/api")) return .base;
    return .m3u;
}

// ── Tests ──

test "registry ids are unique, safe filenames, and short enough" {
    for (SOURCES, 0..) |s, i| {
        try std.testing.expect(s.id.len > 0 and s.id.len <= 32);
        for (s.id) |ch| {
            // Must survive source_config.install's id validation.
            try std.testing.expect(ch != '/' and ch != '\\' and ch != '.' and ch != 0);
        }
        try std.testing.expect(s.url.len > 0);
        for (SOURCES, 0..) |t, j| {
            if (i != j) try std.testing.expect(!std.mem.eql(u8, s.id, t.id));
        }
    }
}

test "defaults are a small clean set incl. iptv-org, no stale or duplicate sources" {
    var defaults: usize = 0;
    var has_iptv_org = false;
    for (SOURCES) |s| {
        if (!s.default_on) continue;
        defaults += 1;
        if (std.mem.eql(u8, s.id, "iptv-org")) has_iptv_org = true;
        // A default source must be actively maintained: no staleness caveat.
        try std.testing.expect(std.mem.indexOf(u8, s.note, "tale") == null); // stale
        try std.testing.expect(std.mem.indexOf(u8, s.note, "rozen") == null); // frozen
        // iptv-org-index duplicates iptv-org's channels — never both on by
        // default (the catalog dedupes only within a source, not across).
        try std.testing.expect(!std.mem.eql(u8, s.id, "iptv-org-index"));
    }
    try std.testing.expect(has_iptv_org); // the original source is always on
    try std.testing.expect(defaults >= 2 and defaults <= 4); // a handful, not everything
}

test "INGEST_CAP clears every source's volume with headroom (no silent truncation)" {
    // The parse buffer must hold a whole source; a source whose stream count
    // reaches the cap would be truncated at ingest. iptv-org's live streams.json
    // is the largest single source (~17.5k stream objects as of 2026-07 and
    // growing). Assert >=2x headroom over that live volume AND over every
    // registry `approx`, so ordinary iptv-org growth can never clip the feed.
    const IPTV_ORG_STREAMS_LIVE: usize = 17520;
    try std.testing.expect(INGEST_CAP > IPTV_ORG_STREAMS_LIVE * 2);
    for (SOURCES) |s| {
        try std.testing.expect(INGEST_CAP > @as(usize, s.approx) * 2);
    }
}

test "distinct catalog sources present, opt-in, https m3u" {
    // The non-iptv-org additions must stay in the registry, be m3u playlists on
    // https, and default OFF (curation keeps the default set small + clean).
    const distinct = [_][]const u8{
        "tdtchannels", "pluto-tv", "samsung-tvplus", "plex-tv", "roku-tv", "tubi-tv",
    };
    for (distinct) |id| {
        const s = byId(id) orelse return error.MissingDistinctSource;
        try std.testing.expect(s.kind == .m3u);
        try std.testing.expect(std.mem.startsWith(u8, s.url, "https://"));
        try std.testing.expect(!s.default_on); // opt-in, never a default
        try std.testing.expect(s.approx > 0);
    }
}

test "byId finds and misses" {
    try std.testing.expect(byId("free-tv") != null);
    try std.testing.expect(byId("free-tv").?.kind == .m3u);
    try std.testing.expect(byId("nope") == null);
}

test "installBody uses the right field per kind" {
    var b: [256]u8 = undefined;
    const base = byId("iptv-org").?;
    try std.testing.expectEqualStrings(
        "{\"base\":\"https://iptv-org.github.io/api\"}",
        installBody(base, &b).?,
    );
    const m3u = byId("free-tv").?;
    try std.testing.expect(std.mem.startsWith(u8, installBody(m3u, &b).?, "{\"url\":"));
}

test "kindOfUrl classifies playlists vs api roots" {
    try std.testing.expect(kindOfUrl("https://x/playlist.m3u8") == .m3u);
    try std.testing.expect(kindOfUrl("https://x/list.m3u") == .m3u);
    try std.testing.expect(kindOfUrl("https://x/p.m3u?token=1") == .m3u);
    try std.testing.expect(kindOfUrl("https://iptv-org.github.io/api") == .base);
    try std.testing.expect(kindOfUrl("https://x/whatever") == .m3u);
}
