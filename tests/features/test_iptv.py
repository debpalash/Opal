"""Video — Live TV / IPTV (iptv-org) tab tests.

Structural VIDEO twin of the Radio tab: keyless channel discovery via the
iptv-org public directory (streams.json), m3u8/HLS streams handed straight to
mpv. Opt-in via the source_config-gated "iptv-org" plugin, NSFW-filtered.

Verify the full wiring: the tested pure module is registered + routed
(tested logic == shipped logic), the service has the source_config gate +
NSFW check + renderContent/playChannel, the DrawerTab enum/nav/render/rail are
all wired, and the bundled manifest carries the iptv-org entry.

See tests/features/harness.py for the shared @test decorator."""
from .harness import *  # noqa: F401,F403

import json
import os


@test("Live TV (IPTV) tab", "Video")
def test_iptv_tab():
    svc = _src("src/services/iptv.zig")
    pure = _src("src/services/iptv_pure.zig")
    st = _src("src/core/state.zig")
    shell = _src("src/ui/shell.zig")
    drawer = _src("src/ui/drawer.zig")
    build = _src("build.zig")
    lhp = _src("src/services/link_health_pure.zig")
    lh = _src("src/services/link_health.zig")
    playback_load = _src("src/player/playback_load_pure.zig")

    checks = {
        # ── Pure module: URL builder, m3u8/NSFW/accept decisions, parser ──
        "pure module present": bool(pure),
        "pure IptvChannel record": "pub const IptvChannel = struct" in pure,
        "pure streams-url builder": "pub fn buildStreamsUrl" in pure,
        "pure m3u8 recognizer": "pub fn isM3u8" in lhp and "pub const isM3u8 = lh.isM3u8" in pure,
        "pure NSFW gate": "pub fn isNsfw" in pure,
        "pure accept decision": "pub fn acceptEntry" in pure,
        "pure streams iterator": "pub const StreamIter" in pure,
        "pure per-object parser": "pub fn parseStreamObj" in pure,
        # Accept gate is CALLED from the fill loop (drop unplayable/NSFW/filtered).
        "accept routed in fill": "acceptChannel(" in pure,
        # ── Thumbnail/metadata JOIN: streams -> logos.json + channels.json ──
        # streams.json has no logo; logos.json (thumbnails) + channels.json
        # (category/country/is_nsfw) join on the channel id. All tested pure.
        "pure captures channel id": "chan_id" in pure,
        "pure logos-url builder": "pub fn buildLogosUrl" in pure,
        "pure channels-url builder": "pub fn buildChannelsUrl" in pure,
        "pure ranked fill (id-first)": "pub fn fillRanked" in pure,
        "pure object iterator": "pub const ObjIter" in pure,
        "pure logo extractor": "pub fn logoUrlFromObj" in pure,
        "pure channel-meta extractor": "pub fn channelMetaFromObj" in pure,
        "pure precise is_nsfw flag": '"is_nsfw":true' in pure,
        # ── Browse FILTERS (category/country/quality/sort) — pure + tested ──
        "pure quality filter": "pub const QualityFilter" in pure,
        "pure sort comparator": "pub fn channelLessThan" in pure,
        "pure filters struct": "pub const Filters" in pure,
        "acceptChannel gates filters": "pub fn acceptChannel" in pure,
        # Filter/join happens DURING selection via the ctx hook (shipped loop ==
        # tested loop): the worker plugs a map-backed ctx into pure.fillRanked.
        "join is a fillRanked ctx": "MapCtx" in svc and "pub fn enrich(" in svc,
        "filter bar UI": "fn renderToolbar(" in svc and "themedSelect(" in svc,
        # Themed dropdown (dvui.dropdown's popup is white; we use a dark floatingMenu).
        "themed dropdown popup": "fn themedSelect(" in svc and "dvui.floatingMenu(" in svc,
        "filters re-run worker": "pub fn applyFilters(" in svc and "applyFilters();" in svc,
        "filter state fields": all(f in _src("src/core/state.zig") for f in ("filter_category", "filter_country", "filter_quality", "sort_mode")),

        # ── Favorites + Recents (quick-filter views, iptv_store-backed) ──
        "iptv_channels table": "CREATE TABLE IF NOT EXISTS iptv_channels" in _src("src/core/db.zig"),
        "store module present": bool(_src("src/services/iptv_store.zig")),
        "store CRUD": all(s in _src("src/services/iptv_store.zig") for s in (
            "pub fn toggleFavorite", "pub fn recordRecent", "pub fn loadInto", "pub fn loadFavHashes")),
        "store persists play hints": "user_agent" in _src("src/services/iptv_store.zig") and "referrer" in _src("src/services/iptv_store.zig"),
        "quick-filter chips": "fn renderToolbar(" in svc and "Favorites" in svc and "Recent" in svc,
        "quick view loads from db": "loadQuickView(" in svc and "iptv_store.loadInto(" in svc,
        "star toggles favorite": "iptv_store.toggleFavorite(" in svc,
        "records recents on play": "iptv_store.recordRecent(" in svc,
        "quick_filter state": "quick_filter" in _src("src/core/state.zig"),

        # ── Stream health testing (live / dead / slow) ──
        # The classifier + probe pool are now APP-WIDE (shared with Radio):
        # link_health_pure.zig (pure) + link_health.zig (pool/cache).
        "pure health classifier": "pub fn classify" in lhp and "pub const Status" in lhp,
        "pure playlist check": "pub fn looksLikePlaylist" in lhp,
        "iptv re-exports shared classifier": "pub const Health = lh.Status" in pure and "pub const classifyHealth = lh.classify" in pure,
        "link_health table": "CREATE TABLE IF NOT EXISTS link_health" in _src("src/core/db.zig"),
        "iptv_health table kept": "CREATE TABLE IF NOT EXISTS iptv_health" in _src("src/core/db.zig"),
        "health cache store/load": "pub fn put(" in lh and "pub fn loadMap(" in lh,
        "bounded probe pool": "PROBE_MAX" in lh and "probe_inflight" in lh and "fn probeWorker(" in lh,
        "probe routes through pure": "pure.classify(" in lh and "pure.looksLikePlaylist(" in lh,
        "status dot + lazy probe": "fn statusColor(" in svc and "maybeProbe(" in svc,
        "iptv routes through link_health": 'link_health.statusOf("iptv"' in svc.replace("IPTV_KIND", '"iptv"') or "link_health.statusOf(IPTV_KIND" in svc,
        "radio wired to link_health": "link_health.probe(RADIO_KIND" in _src("src/services/radio.zig"),
        "working-only filter": "working_only" in svc,
        "test-channels button": '"Check channel availability"' in svc,

        # ── Service: gate + async worker + thread-safety + play path ──
        # Production routes through the pure fns (tested logic == shipped logic).
        "service routes through pure": all(
            f"pure.{fn}(" in svc
            for fn in ("buildStreamsUrl", "fillRanked", "isM3u8",
                       "buildLogosUrl", "buildChannelsUrl", "logoUrlFromObj",
                       "channelMetaFromObj")
        ),
        # Thumbnails render via the SHARED poster daemon (same path as radio).
        "logo via poster daemon": 'poster.fetchAsync(' in svc and "fn renderLogo(" in svc,
        # Sibling directories fetched + disk-cached (no 17 MB re-download per search).
        "joins logos+channels feeds": "logos.json" in svc and "channels.json" in svc,
        "enrichment disk cache": "fn fetchCached(" in svc and "ENRICH_TTL_S" in svc,
        # Opt-in gate via source_config (plugin id "iptv-org").
        "source_config gate": 'source_config.get("iptv-org", "base")' in svc,
        "inert when uninstalled": "orelse return null" in svc,
        # Adult Live TV channels are governed by the NSFW setting: stored in the
        # catalog (flagged) and shown only when the filter is OFF.
        "nsfw tied to the setting": "nsfw_allowed = !state.app.nsfw_filter_enabled" in svc,
        # iptv-org streams.json endpoint.
        "streams.json endpoint": "streams.json" in svc or "streams.json" in pure,
        # Discovery + search + play.
        "popular one-shot": "pub fn loadPopularOnce" in svc,
        "search entry": "pub fn searchIptv" in svc,
        "infinite scroll": "fn ensureWindow(" in svc,
        "play hands url to mpv": "pub fn playChannel" in svc and "loadContentDirectMetaHeaders(" in svc,
        # Per-stream HTTP hints (user_agent/referrer) captured + sent to mpv, so
        # CDNs that 400/403 the default UA / need a Referer still play.
        "captures play hints": "user_agent" in pure and "referrer" in pure,
        "sends hints to mpv": ("loadContentDirectMetaHeaders(" in svc
                                and "playback_load.dispatch" in _src("src/player/player.zig")
                                and "user-agent" in playback_load),
        "render entry": "pub fn renderContent" in svc,
        # Thread discipline (mirrors radio.zig).
        "atomic loading flag": "is_loading.store" in svc,
        "publishes under mutex": "parse_mutex.lock()" in svc,
        "reliable fetch transport": (
            "std.http.Client" not in svc and "reliable_fetch.fetch(" in svc
        ),

        # ── Enum → state → nav → render dispatch → rail/shell ──
        # Assert MEMBERSHIP, not position (concurrent tab additions).
        "enum variant present": "Iptv" in st and "pub const DrawerTab" in st,
        "state struct": "iptv: struct {" in st,
        "results buffer (capped)": "]iptv_pure.IptvChannel" in st,
        "nav host page": ".Iptv => {" in st and "app.browse_source = .Iptv;" in st,
        "render dispatch": '.Iptv => @import("../services/iptv.zig").renderContent()' in drawer,
        "grouped under video": ".YouTube, .Iptv => .video" in drawer,
        "rail nav entry": "renderRailTab(.Iptv" in drawer,
        "shell label": '.Iptv => "Live TV"' in shell,
        "shell icon (exists in pack)": '.Iptv => icons.tvg.lucide.@"monitor-play"' in shell,
        "grouped sidebar source": ".Iptv" in shell and "sidebarSection(" in shell
            and "state.app.browse_source = source" in shell,

        # ── Pure module registered in the `zig build test` step ──
        "test registered": 'b.path("src/services/iptv_pure.zig")' in build,
    }

    # ── Bundled manifest carries the iptv-org plugin entry ──
    mpath = os.path.join(PROJECT_DIR, "data", "plugins-manifest.json")
    manifest_ok = False
    try:
        with open(mpath) as f:
            man = json.load(f)
        for p in man.get("plugins", []):
            if p.get("id") == "iptv-org" and p.get("type") == "iptv" \
                    and "iptv-org.github.io" in p.get("endpoints", {}).get("base", ""):
                manifest_ok = True
                break
    except Exception:
        manifest_ok = False
    checks["manifest iptv-org entry"] = manifest_ok

    missing = [k for k, ok in checks.items() if not ok]
    if not missing:
        return "pass", "IPTV wired: pure(url/m3u8/nsfw/parse) -> gated fetch -> enum/nav/rail; manifest present"
    return "fail", "IPTV wiring incomplete: " + ", ".join(missing)


@test("Live TV SQLite catalog (100k channels)", "Video")
def test_iptv_catalog():
    """The Live TV directory moved from a fixed [300] array to a SQLite catalog,
    so it holds every channel from many playlists (100k+) with flat memory, is
    searchable across all of it, and ingests curated sources SWR (24h). Adult
    channels are stored flagged and gated by the NSFW setting at query time."""
    cat = _src("src/services/iptv_catalog.zig")
    cpure = _src("src/services/iptv_catalog_pure.zig")
    srcs = _src("src/services/iptv_sources.zig")
    svc = _src("src/services/iptv.zig")
    pure = _src("src/services/iptv_pure.zig")
    dbz = _src("src/core/db.zig")
    build = _src("build.zig")
    scfg = _src("src/core/source_config.zig")

    checks = {
        # ── Schema ──
        "catalog table": "CREATE TABLE IF NOT EXISTS iptv_catalog" in dbz,
        "dedupe key": "UNIQUE (source_id, url_hash)" in dbz,
        "name index for search": "idx_iptv_catalog_name ON iptv_catalog(name_lc)" in dbz,
        "per-source meta table": "CREATE TABLE IF NOT EXISTS iptv_source_meta" in dbz,

        # ── Pure query/gate ──
        "pure module present": bool(cpure),
        "LIKE escaper": "pub fn buildLikePattern" in cpure and "ESCAPE" in cat,
        "adult group denylist": "pub fn isAdultGroup" in cpure and "pub fn ingestIsAdult" in cpure,
        "pure has tests": cpure.count('test "') >= 5,

        # ── Store ──
        "paged query": "pub fn queryPage" in cat and "LIMIT" in cat and "OFFSET" in cat,
        "count across catalog": "pub fn count(" in cat,
        "atomic per-source ingest": "pub fn clearSource" in cat and "pub fn ingestChannels" in cat,
        # Adult channels stored flagged (not dropped) + gated by the setting at query.
        "ingest flags adult, keeps it": "cpure.ingestIsAdult(" in cat and "if (is_adult) 1 else 0" in cat,
        "query gates nsfw on setting": "nsfw_allowed: bool" in cat and '"nsfw = 0"' in cat,
        # A user can declare a custom playlist adult → every channel flagged nsfw
        # (for adult sources whose channels don't self-identify).
        "custom source can be flagged adult": "force_adult" in cat
            and "force_adult or ch.nsfw" in cat
            and "setCustomUrl(url: []const u8, adult: bool)" in svc
            and 'source_config.get(id, "adult")' in svc,
        "filter bar feeds nsfw setting": "nsfw_allowed = !state.app.nsfw_filter_enabled" in svc,
        "SWR bookkeeping": "pub fn markIngested" in cat and "pub fn lastIngest" in cat,

        # ── Registry (curated, opt-in) ──
        "source registry present": bool(srcs),
        "registry has curated sources": srcs.count(".id =") >= 5,
        "iptv-org default on": ".default_on = true" in srcs,
        "registry has tests": srcs.count('test "') >= 4,

        # ── Ingest worker + catalog-backed render ──
        "imports catalog + registry": 'iptv_catalog.zig' in svc and 'iptv_sources.zig' in svc,
        "SWR 24h ttl": "INGEST_TTL_S" in svc and "24 * 60 * 60" in svc,
        "ingest worker": "fn ingestWorker(" in svc and "fn ingestOne(" in svc,
        "base + m3u ingest paths": "fn ingestBase(" in svc and "fn ingestM3u(" in svc,
        "heap parse buffer": "alloc.alloc(pure.IptvChannel, INGEST_CAP)" in svc,
        "render fills from catalog": "fn refillWindow(" in svc and "catalog.queryPage(" in svc,
        "search covers whole catalog": "refillFromCatalog();" in svc,
        # Unbounded scroll: results[] is a SLIDING window over the catalog, keyed
        # off win_base; the render virtualizes over the whole match count and
        # ensureWindow re-queries when the viewport scrolls out of the slice.
        "sliding window over catalog": "var win_base" in svc and "ensureWindow(first_ch, last_ch)" in svc,
        "virtualizes over whole catalog": "total_rows = (grid_total" in svc,
        # Quality filter + sort now run IN the catalog query (were deferred).
        "quality tier stored": "quality_tier" in dbz and "qualityTier(" in cat,
        "quality bounds pure": "pub fn qualityBounds" in cpure and "pub fn qualityTier" in cpure,
        "query applies quality + sort": "qmin" in cat and "sort_country" in cat,
        "filter bar feeds quality/sort": "qualityBounds(state.app.iptv.filter_quality)" in svc,
        # Live incremental search: results track typing AND clearing, no Enter
        # needed; a clear (x) button restores the full directory dynamically.
        "live search poller": "fn pollLiveSearch(" in svc and "pollLiveSearch();" in svc,
        "clear button restores list": "iptvclear" in svc and "@memset(&state.app.iptv.search_buf, 0)" in svc,
        # Legacy public-directory fetch path removed (catalog is the only backing).
        "legacy fetch worker removed": "fn fetchWorker(" not in svc and "fn armFetch(" not in svc,
        "legacy m3u override removed": "fn saveM3u(" not in svc and "fn m3uUrl(" not in svc,
        # Regression: the directory showed only one page (~90) because the render
        # keyed off the materialized page, not the full catalog. The sliding
        # window now spans total_matches, so the heading + scrollbar reflect the
        # whole directory.
        "tracks full match count": "total_matches" in svc and "catalog.count(q)" in svc,
        "heading shows full count": "{d} channels" in svc and "grid_total," in svc,
        "default sources auto-enabled": "fn ensureDefaultSources(" in svc,

        # ── Render window bumped off the old 300 ──
        "render window constant": "pub const RENDER_WINDOW" in pure,
        "state uses render window": "iptv_pure.RENDER_WINDOW" in _src("src/core/state.zig"),
        "no stale 300 poster array": "[300]ChannelPoster" not in svc,

        # ── Settings-page API surface ──
        "install/uninstall api": "pub fn installSource(" in svc and "pub fn uninstallSource(" in svc,
        "custom url api": "pub fn setCustomUrl(" in svc,
        "counts api": "pub fn sourceChannelCount(" in svc and "pub fn catalogTotal(" in svc,
        "id-based uninstall helper": "pub fn uninstallById(" in scfg,

        # ── Tests registered ──
        "catalog pure test registered": 'b.path("src/services/iptv_catalog_pure.zig")' in build,
        "sources test registered": 'b.path("src/services/iptv_sources.zig")' in build,

        # ── Manifest carries the new m3u sources ──
        "manifest m3u sources": '"type": "iptv-m3u"' in _src("data/plugins-manifest.json"),
        # Distinct (non-iptv-org-mirror) catalogs added: TDTChannels DTT + FAST
        # providers, each with its own streams. Registered + mirrored in manifest.
        "distinct sources in registry": all(
            f'.id = "{i}"' in srcs
            for i in ("tdtchannels", "pluto-tv", "samsung-tvplus", "plex-tv", "roku-tv", "tubi-tv")
        ),
        "distinct sources in manifest": all(
            f'"id": "{i}"' in _src("data/plugins-manifest.json")
            for i in ("tdtchannels", "pluto-tv", "samsung-tvplus", "plex-tv", "roku-tv", "tubi-tv")
        ),
        "distinct sources stay opt-in": srcs.count(".default_on = true") <= 4,
    }

    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "Catalog wiring incomplete: " + ", ".join(missing)
    return "pass", "Live TV catalog: SQLite (100k) + curated opt-in sources + SWR 24h ingest + nsfw-gated adult"


@test("Live TV supports multiple independently managed custom playlists", "Video")
def test_iptv_custom_source_crud():
    service = _src("src/services/iptv.zig")
    remote = _src("src/services/remote.zig")
    html = _src("web/index.html")
    web = _src("web/js/integrations.js")
    native = _src("src/ui/settings.zig")
    checks = {
        "bounded source slots": "MAX_CUSTOM_SOURCES: usize = 8" in service,
        "durable CRUD": all(marker in service for marker in (
            "pub fn setCustomSource", "pub fn removeCustomSource", "pub fn firstFreeCustomSlot",
        )),
        "every custom source ingested": "for (0..MAX_CUSTOM_SOURCES)" in service
            and "ingestOne(id, .m3u" in service,
        "adult false is not truthy": 'std.mem.eql(u8, value, "1")' in service,
        "typed API list and mutations": r'\"custom\":[' in remote
            and 'startsWith(u8, id, "iptv-custom-")' in remote,
        "URLs sent in POST body": "apiFormMutation('/livetv/sources'" in web,
        "web add edit remove": all(marker in html + web for marker in (
            'id="ltv-custom-name"', 'id="ltv-custom-adult"', "data-ltv-edit", "data-ltv-remove",
        )),
        "native add edit remove and legacy migration": all(marker in native for marker in (
            "livetv_edit_slot", "iptv.firstFreeCustomSlot()", "iptv.removeCustomSource(slot)",
            "livetv_migrate_legacy", 'iptv.setCustomUrl("", false)',
        )),
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "custom IPTV lifecycle incomplete: " + ", ".join(missing)
    return "pass", "up to eight custom playlists persist and can be added, edited, classified, refreshed, and removed independently"


@test("Live TV programme guide (XMLTV): import, match, now/next, search", "Video")
def test_iptv_programme_guide():
    """Opt-in XMLTV guide matched to playlist channels (tvg-id, then a
    normalised name, with user overrides), now/next + programme search,
    DST-safe time maths, stale/expired flagging, bounded memory, and the same
    surface on the native Live TV view, the remote API and the web UI."""
    pure = _src("src/services/epg_pure.zig")
    svc = _src("src/services/epg.zig")
    ui = _src("src/ui/live_tv_guide.zig")
    iptv = _src("src/services/iptv.zig")
    api = _src("src/services/remote_livetv_guide_api.zig")
    remote = _remote_api()
    access = _src("src/services/access_pure.zig")
    dbz = _src("src/core/db.zig")
    build = _src("build.zig")
    playlist = _src("src/services/iptv_playlist_pure.zig")
    cat = _src("src/services/iptv_catalog.zig")
    cpure = _src("src/services/iptv_catalog_pure.zig")
    store = _src("src/services/iptv_store.zig")
    fwd = _src("src/services/forwarded_open.zig")
    web = _web_app()
    main = _src("src/main.zig")

    checks = {
        # Pure module: registered, tested, and covers the brief's edge cases.
        "pure registered": 'b.path("src/services/epg_pure.zig")' in build and "test_epg_pure" in build,
        "pure time maths": "pub fn parseXmltvTime" in pure and "pub fn daysFromCivil" in pure,
        "DST fixture tests": pure.count('test "DST:') >= 3,
        "malformed + huge guide tests": 'test "malformed guide' in pure and 'test "huge guide' in pure,
        "gzip bomb bounded": "pub fn gunzipBounded" in pure and ".limited(cap)" in pure and "StreamTooLong" in pure,
        "bounded records": all(k in pure for k in ("MAX_PROGRAMMES", "MAX_CHANNELS", "MAX_XML_BYTES", "MAX_FETCH_BYTES")),
        "matching order": "pub fn matchChannel" in pure and all(k in pure for k in (".mapped", ".tvg_id", ".id_stem", ".name")),
        "stale verdict": "pub fn freshness" in pure and "expired" in pure and "STALE_COVERAGE_S" in pure,
        "source redaction": "pub fn redactSource" in pure and "password=hunter2" in pure,
        # Service routes through the pure functions (tested logic == shipped).
        "service uses pure": all(f"pure.{fn}(" in svc for fn in (
            "classifySource", "gunzipBounded", "looksLikeXmltv", "parse", "sortProgrammes",
            "matchChannel", "channelRange", "nowNext", "searchProgrammes", "freshness", "channelKey")),
        "opt-in: no source, no fetch": "!isEnabled()" in svc and "pub fn importSource" in svc,
        "fetch is capped + rate-limited": "pure.MAX_FETCH_BYTES" in svc and 'rate_limit.acquire("epg"' in svc,
        "per-instant local offset (DST)": "pub fn localOffsetAt" in svc and "'localtime'" in svc,
        "freed at shutdown": '@import("services/epg.zig").deinit()' in main,
        # Schema: opt-in source + user mappings; guide join key in the catalog.
        "epg tables": "CREATE TABLE IF NOT EXISTS iptv_epg_map" in dbz and "CREATE TABLE IF NOT EXISTS iptv_epg_meta" in dbz,
        "catalog keeps tvg-id": "chan_id" in cpure and "?14" in cat and "chan_id" in store,
        "playlist tvg-id parsed": 'attr(line, "tvg-id"' in playlist,
        # Per-channel request headers honoured from every play path.
        "EXTINF/EXTHTTP headers": "#EXTHTTP:" in playlist and '"http-referrer"' in playlist,
        "remote play re-reads catalog": "findByUrl(url)" in api and "pushLiveTv(" in api
            and "findByUrl(url)" in fwd and "playRecord(row)" in fwd,
        "native play keeps headers": "pub fn playRecord" in iptv and "loadContentDirectMetaHeaders(" in iptv,
        # Dead streams surfaced, not silently played.
        "dead stream feedback": "channel is offline" in api and '\\"health\\":\\"{s}\\"' in remote and "tv-dead" in web,
        # Native Live TV view (not settings.zig).
        "native Guide view": "GUIDE_VIEW" in iptv and 'live_tv_guide.zig").render' in _src("src/ui/drawer.zig") and "guide_view" in iptv and "epg.tick()" in ui,
        "native now on cards": 'epg.zig").nowNextFor(ch' in iptv,
        "native mapping editor": "epg.setMapping(" in ui and "epg.guideChannels(" in ui and "epg.removeMappingKey(" in ui,
        "native stale banner": "st.freshness.label()" in ui,
        "themed helpers only": "dvui.button(" not in ui and "components.actionButton(" in ui
            and "components.confirmDangerButton(" in ui,
        "settings.zig untouched by guide": "epg" not in _src("src/ui/settings.zig"),
        # Remote API.
        "api registered": 'remote_livetv_guide_api.zig").handle(' in remote,
        "api routes": all(r in api for r in ('"/livetv/guide"', '"/livetv/guide/import"', '"/livetv/programmes"',
                                             '"/livetv/map"', '"/livetv/favorite"', '"/livetv/play"')),
        "import is host-admin": '"/livetv/guide/import"' in access and "programme guide import is host-admin" in access,
        "livetv rows carry now/next": "writeNowNext(&w, epg.nowNextFor(&ch, now))" in remote and "view=favorites" in remote,
        # Web UI.
        "web guide panel": all(m in web for m in ('id="tv-guide"', "'/livetv/guide/import'", "'/livetv/map'",
                                                  "/livetv/programmes?q=")),
        "web now/next + favorites": "function tvNowNextHtml(" in web and "'/livetv/favorite'" in web
            and 'data-tv-view="favorites"' in web,
        "web plays through catalog": "'/livetv/play'" in web,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "programme guide incomplete: " + ", ".join(missing)
    return "pass", f"XMLTV guide: {len(checks)} checks (pure DST/huge/malformed tests, opt-in import, mapping, now/next, search, API + web + native)"


@test("Live TV guide fixtures: generated XMLTV parses with DST offsets", "Video")
def test_iptv_guide_fixture_shape():
    """Generate an XMLTV fixture with a London DST fallback programme and a
    gzip copy, and check that what the Zig tests pin (2h real duration, the
    gzip header) matches what Python's own XMLTV-style maths and gzip produce,
    so the embedded fixtures stay representative of real provider output."""
    import gzip, re, datetime
    xml = (
        '<?xml version="1.0" encoding="UTF-8"?>\n<tv>'
        '<channel id="BBCOne.uk"><display-name>BBC One HD</display-name></channel>'
        '<programme start="20261025003000 +0100" stop="20261025013000 +0000" channel="BBCOne.uk">'
        '<title>Straddle</title></programme></tv>'
    )

    def parse(stamp):
        m = re.match(r"(\d{14}) ([+-])(\d{2})(\d{2})", stamp)
        base = datetime.datetime.strptime(m.group(1), "%Y%m%d%H%M%S").replace(tzinfo=datetime.timezone.utc)
        off = (int(m.group(3)) * 3600 + int(m.group(4)) * 60) * (1 if m.group(2) == "+" else -1)
        return base.timestamp() - off

    start, stop = re.findall(r'start="([^"]+)" stop="([^"]+)"', xml)[0]
    payload = b'<tv><channel id="a"><display-name>A</display-name></channel></tv>'
    pure = _src("src/services/epg_pure.zig")
    # Compressed bytes differ between zlib builds (macOS vs Linux CI), so
    # compare what the Zig fixture *decompresses to*, not the deflate stream.
    def zig_gzip_payloads():
        out = []
        for lit in re.findall(r'"((?:\\x[0-9a-fA-F]{2})+)"', pure):
            raw = bytes(int(h, 16) for h in re.findall(r"\\x([0-9a-fA-F]{2})", lit))
            if raw[:2] == b"\x1f\x8b":
                try:
                    out.append(gzip.decompress(raw))
                except Exception:
                    out.append(None)
        return out
    checks = {
        "fallback show lasts two real hours": parse(stop) - parse(start) == 7200,
        "zig test pins the same instant pair": '"20261025003000 +0100"' in pure and '"20261025013000 +0000"' in pure,
        "gzip magic recognised": "pub fn isGzip" in pure,
        "zig gzip fixture decompresses to the expected XML": payload in zig_gzip_payloads(),
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "guide fixtures drifted: " + ", ".join(missing)
    return "pass", "generated XMLTV/DST and gzip fixtures agree with the Zig tests"
