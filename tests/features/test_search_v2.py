"""Search v2 wiring contracts. These checks do not claim pixel/layout proof.

Behavioral facet/sort/viewport regressions live in search_view_pure.zig; this
module verifies that production consumers use that policy and retain actions.
"""
from .harness import *  # noqa: F401,F403


def _checked(checks, success):
    missing = [name for name, passed in checks.items() if not passed]
    return ("fail", ", ".join(missing)) if missing else ("pass", success)


@test("Search v2 independent facets and deterministic view policy", "Search")
def test_search_v2_policy():
    pure = _src("src/services/search_view_pure.zig")
    build = _src("build.zig")
    return _checked({
        "typed content and availability": "pub const ContentKind = enum" in pure
            and "pub const Availability = enum" in pure,
        "content coverage": all(kind in pure.split("pub const ContentKind", 1)[-1].split(";", 1)[0]
            for kind in ("movies", "shows", "anime", "comics", "books", "music", "podcasts", "radio", "live_tv", "visual_novels")),
        "torrent facets": all(field in pure for field in ("min_quality:", "min_seeds:", "min_size_bytes:", "max_size_bytes:", "provider:")),
        "pure view has no persisted provider mask": "source_mask" not in pure and "config.zig" not in pure,
        "shared match/count/sort/viewport functions": all(f"pub fn {name}(" in pure for name in ("matches", "activeCount", "lessThan", "visibleRange")),
        "stable ordering tie break": "return a.key < b.key" in pure,
        "finite viewport guards": "std.math.isFinite" in pure,
        "behavioral regressions retained": all(name in pure for name in (
            "facets are independent owned values", "all streamed sorts tie break by stable identity", "viewport clamps")),
        "pure tests registered": 'b.path("src/services/search_view_pure.zig")' in build,
    }, "Independent facets, deterministic ordering and bounded viewport policy are registered")


@test("Search v2 immutable resolver projection retains provider metadata", "Search")
def test_search_v2_resolver_projection():
    resolver = _src("src/services/resolver.zig")
    pure = _src("src/services/search_view_pure.zig")
    snapshot = _between(resolver, "pub fn copySearchSnapshot(", "pub fn searchView(")
    projection = resolver.split("pub fn searchView(", 1)[-1].split("\n}\n", 1)[0]
    return _checked({
        "owned snapshot API": "out: []ResolvedItem" in snapshot and "known_revision: u64" in snapshot,
        "snapshot guarded": "lockRemoteSnapshot()" in snapshot and "defer unlockRemoteSnapshot()" in snapshot,
        "revision and loading copied": "results_revision" in snapshot and "is_resolving.load(.acquire)" in snapshot,
        "metadata projection uses stable action identity": "actionKey(item)" in projection,
        "real torrent properties retained": all(field in projection for field in (".quality", ".seeds", ".leech", ".size_bytes", ".provider")),
        "personal library sources": all(source in projection for source in (".local", ".jellyfin", ".plex")),
        "catalog and reader classifications": "search_view.kindFor(source" in projection and all(source in pure for source in (".tmdb", ".anime", ".comics", ".novels", ".opds", ".vndb", ".audiobooks")),
        "provider metadata survives cache": "search:v8:" in resolver and "w.blob(it.provider.name())" in resolver
            and "search_view.Provider.init(r.blob()" in resolver,
        "actual torrent adapter providers": all(f'Provider.init("{name}")' in resolver for name in ("rss", "yts", "eztv"))
            and "Provider.init(eng_name)" in resolver and "Provider.init(src_id)" in resolver,
    }, "Owned resolver snapshots preserve stable actions, content policy and actual torrent metadata")


@test("Search v2 native view is compact virtualized and snapshot-owned", "Search")
def test_search_v2_native_view():
    search = _src("src/services/search.zig")
    header = _between(search, "pub fn renderSearchContent()", "fn searchButton(")
    refresh = _between(search, "fn refreshSearchView()", "fn renderProviderFacet()")
    renderer = _between(search, "fn renderUniversalResults()", "fn showResult(")
    row = _between(search, "fn renderCompactRow(", "pub fn ")
    sources = _between(search, "fn renderSearchSources()", "fn renderUniversalResults()")
    filters = _between(search, "fn renderSearchFilters()", "fn filterChip(")
    return _checked({
        "one search header": "submitSearchInput(" in header and "const modes" not in header and '"Universal"' not in header,
        "facet panel separate from provider settings": "renderSearchFilters()" in header and "renderActiveSearchFilters()" in header
            and "view_filters: search_view.Filters" in search,
        "heap immutable snapshot": "allocator.alloc(resolver.ResolvedItem, resolver.MAX_RESULTS)" in refresh
            and "resolver.copySearchSnapshot(" in refresh and "resolver.results_mutex.lock()" not in renderer,
        "one match/sort policy": "search_view.matches(" in refresh and "search_view.lessThan(" in refresh
            and "resolver.sortResultsBy(" not in renderer,
        "compact sort popup": "searchSelect(91300, &SORT_LABELS" in renderer and "components.segment(" not in renderer,
        "filtered totals": "shown of {d} loaded" in renderer and "view_cache.count" in renderer and "view_cache.loaded" in renderer,
        "visible range only": "search_view.visibleRange(" in renderer and "for (range.start..range.end)" in renderer,
        "keyboard traversal retained": "keyboardLayoutMode(" in renderer and ".tab" in renderer,
        "snapshot-owned action": "view_cache.rows.?[action.idx]" in renderer and "resolver.playResolvedItem(item)" in renderer,
        "safe torrent queue": "torrent_risk_pure.zig" in renderer and "risk.risk == .block" in renderer and "addToQueue(" in renderer,
        "stable result widget identities": "resolver.actionKey(item)" in row and ".id_extra = row_key" in row,
        "progress cancellation and retry": "resolver.cancel()" in renderer and '"Retry search"' in sources
            and "resolver.resolve(view_cache.query" in sources,
        "real torrent row metadata": "meta_pure.metaLine(" in row and all(field in row for field in (".quality = item.quality", ".size_bytes = item.size_bytes", ".seeds = item.seeds", ".leech = item.leech")),
        "reader/details actions retained": all(label in row for label in ('"read"', '"details"', '"open audio"', '"play"')),
        "native queue follows shared action policy": "const queueable = item.source == .torrent and resolver.isRemoteQueueable(item)" in search and "if (!resolver.isRemoteQueueable(item))" in renderer,
        "source settings are disclosed": "if (sources_open) renderSearchSources()" in filters and "renderSourceStatusCluster()" in sources,
        "filtered empty state": '"No matches for these filters"' in renderer,
        "themed popup": "fn searchSelect(" in search and "theme.colors.bg_surface" in search and "theme.colors.text_primary" in search,
    }, "Single Search uses copied rows, shared facets, compact sorting and viewport rendering")


@test("Search v2 web projection keeps opaque actions and useful torrent fields", "Search")
def test_search_v2_web_projection():
    remote = _src("src/services/remote.zig")
    web = _src("web/index.html")
    catalog = _src("web/js/search.js")
    static = _src("src/services/remote_static.zig")
    api = remote.split("fn apiUnifiedSearch(", 1)[-1].split("fn apiUnifiedSearchAction(", 1)[0]
    return _checked({
        "actual shared projection": "resolver.searchView(item)" in api,
        "additive typed metadata": all(field in api for field in ("content_kind", "playable", "torrent", "library", "quality", "seeds", "leech", "size_bytes", "score", "provider")),
        "opaque action key retained": "resolver.actionKey(item)" in api and "resolver.isRemoteQueueable(item)" in api,
        "web no duplicate Universal/Torrents modes": 'id="page-search"' in web and "search-mode" not in web,
        "web facet controls": all(f'id="search-{name}"' in web for name in ("content", "availability", "quality", "seeds", "size", "provider", "sort")),
        "Search bundle served": '.route = "/js/search.js"' in static and 'src="/js/search.js"' in web,
        "web applies independent facets": "matchesSearchFilters(" in catalog and "unifiedResultRows(" in catalog,
        "web actions use opaque identity": "apiMutation('/unified_search/' + action" in catalog and "encodeURIComponent(r.key)" in catalog and "?generation=" in catalog,
    }, "Additive shared search metadata retains generation-scoped opaque actions")
