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
        "test-channels button": '"Test"' in svc,

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
        # Live TV excludes adult channels UNCONDITIONALLY — the gate is forced on
        # (heuristic drop at parse + precise is_nsfw drop after the join) and the
        # service never reads the global NSFW toggle.
        "nsfw always filtered": "nsfw_allowed = false" in svc,
        "nsfw not tied to global flag": "nsfw_filter_enabled" not in svc,
        # iptv-org streams.json endpoint.
        "streams.json endpoint": "streams.json" in svc or "streams.json" in pure,
        # Discovery + search + play.
        "popular one-shot": "pub fn loadPopularOnce" in svc,
        "search entry": "pub fn searchIptv" in svc,
        "infinite scroll": "pub fn loadMore" in svc,
        "play hands url to mpv": "pub fn playChannel" in svc and "loadContentDirectMetaHeaders(" in svc,
        # Per-stream HTTP hints (user_agent/referrer) captured + sent to mpv, so
        # CDNs that 400/403 the default UA / need a Referer still play.
        "captures play hints": "user_agent" in pure and "referrer" in pure,
        "sends hints to mpv": "loadStreamWithHttp(" in _src("src/player/player.zig")
            and "user-agent" in _src("src/player/player.zig"),
        "render entry": "pub fn renderContent" in svc,
        # Thread discipline (mirrors radio.zig).
        "atomic loading flag": "is_loading.store" in svc,
        "publishes under mutex": "parse_mutex.lock()" in svc,
        "generation guard": "search_gen" in svc,
        # curl only — std.http SEGVs on some ISP TLS resets (see comics.zig).
        "curl not std.http": "std.http.Client" not in svc and '"curl"' in svc,

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
        "browse subtab": ".Iptv" in shell and "subTabs(&.{" in shell,

        # ── Pure module registered in the `zig build test` step ──
        "test registered": 'b.path("src/services/iptv_pure.zig")' in build,
    }

    # ── Bundled manifest carries the iptv-org plugin entry ──
    mpath = os.path.join(PROJECT_DIR, "plugins-manifest.json")
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
