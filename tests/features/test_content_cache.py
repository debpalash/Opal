"""Auto-split companion — Encrypted persistent content cache tests.
See tests/features/harness.py for the shared @test decorator + helpers."""
from .harness import *  # noqa: F401,F403


@test("Encrypted content cache", "Storage")
def test_content_cache():
    pure = _src("src/core/content_cache_pure.zig")
    drv = _src("src/core/content_cache.zig")
    build = _src("build.zig")
    cfg = _src("src/core/config.zig")
    st = _src("src/core/state.zig")
    settings = _src("src/ui/settings.zig")
    resolver = _src("src/services/resolver.zig")
    tmdb_api = _src("src/services/tmdb_api.zig")
    tmdb = _src("src/services/tmdb.zig")
    main = _src("src/main.zig")

    checks = {
        # ── Pure format + policy module, registered in the zig test gate ──
        "pure module exists": bool(pure),
        "pure registered in build.zig test step": "content_cache_pure.zig" in build,
        "header codec present": ("pub fn encodeHeader" in pure
                                 and "pub fn decodeHeader" in pure
                                 and "MAGIC" in pure),
        "key->filename hashing": "pub fn keyToFilename" in pure and "Sha256" in pure,
        "staleness fresh/stale/expired": ("pub fn staleness" in pure
                                          and "fresh" in pure and "stale" in pure and "expired" in pure
                                          and "HARD_MAX_S" in pure),
        "purge + eviction policy pure": ("pub fn shouldPurge" in pure
                                         and "pub fn evictionCount" in pure),
        "tested serializer primitive": ("pub const Writer" in pure and "pub const Reader" in pure),
        # ── Driver: AEAD + key file + atomic write + decrypt-fail-as-miss ──
        "driver uses an AEAD": ("XChaCha20Poly1305" in drv or "Aes256Gcm" in drv),
        "per-install key file (0600)": ("cache.key" in drv and "0o600" in drv),
        "key failure disables (no plaintext)": ("key_ok" in drv
                                                and "disabled" in drv.lower()),
        "atomic write (temp + rename)": (".tmp" in drv and "renameAbsolute" in drv),
        "decrypt failure => miss + delete": (".decrypt(" in drv
                                             and "deleteFileAbsolute" in drv),
        "aad binds key hash + header": ("buildAad" in drv and "keyHash" in drv),
        "put/get/purge/clear/size api": ("pub fn put" in drv and "pub fn get" in drv
                                         and "pub fn purgeExpired" in drv
                                         and "pub fn clearAll" in drv
                                         and "pub fn sizeBytes" in drv),
        "policy routes through pure": "content_cache_pure.zig" in drv,
        # ── SWR wiring: search + tmdb read AND write through the cache ──
        "search seeds from cache (get)": ("content_cache" in resolver
                                          and "populateFromCache" in resolver),
        "search writes back (put)": ("storeToCache" in resolver
                                     and "content_cache.put" in resolver),
        "tmdb seeds browse grid (get)": ("seedBrowseFromCache" in tmdb_api
                                         and "seedBrowseFromCache" in tmdb),
        "tmdb writes browse grid (put)": ("putBrowseCache" in tmdb_api
                                          and "content_cache.put" in tmdb_api),
        # ── Config toggle + settings + startup ──
        "config toggle persisted": ('"content_cache_enabled"' in cfg
                                     and "content_cache_enabled" in st),
        "settings clear-cache + size + toggle": ("renderCacheSection" in settings
                                                 and "clearAll" in settings
                                                 and "sizeBytes" in settings
                                                 and "content_cache_enabled" in settings),
        "startup init + purge on bg thread": ("content_cache.zig\").init()" in main
                                              or "content_cache.zig\").init(" in main),
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing: " + ", ".join(bad)
    return "pass", "pure+driver+SWR wiring (search/tmdb) + config/settings/startup wired"


@test("Cache SWR on browse listings", "Storage")
def test_content_cache_browse_listings():
    """Comics / anime / podcasts / radio browse grids must seed (get) + store
    (put) through the encrypted content cache, route serialization through the
    tested content_cache_pure Writer/Reader, and gate on content_cache_enabled —
    so each paints INSTANTLY from disk on cold start instead of a blank grid."""
    podcasts = _src("src/services/podcasts.zig")
    radio = _src("src/services/radio.zig")
    anime = _src("src/services/anime.zig")
    comics = _src("src/services/comics.zig")

    def wired(src, key):
        return {
            "imports content_cache": 'content_cache = @import("../core/content_cache.zig")' in src,
            "routes through pure Writer/Reader": ("ccp.Writer.init" in src and "ccp.Reader.init" in src),
            "seeds from cache (get)": "content_cache.get(" in src,
            "stores to cache (put)": "content_cache.put(" in src,
            "gated on content_cache_enabled": "state.app.content_cache_enabled" in src,
            "reuses browse TTL": 'browse_cache.zig").TTL_S' in src,
            "stable browse key": key in src,
        }

    services = {
        "podcasts": wired(podcasts, '"podcasts:popular"'),
        "radio": wired(radio, '"radio:popular"'),
        "anime": wired(anime, '"anime:trending'),  # key carries the trend_filter selector
        "comics": wired(comics, '"comics:browse'),
    }

    bad = []
    for svc, checks in services.items():
        for k, v in checks.items():
            if not v:
                bad.append(f"{svc}: {k}")
    if bad:
        return "fail", "missing: " + ", ".join(bad)
    return "pass", "comics/anime/podcasts/radio browse grids seed+store via content_cache (pure-serialized, gated)"
