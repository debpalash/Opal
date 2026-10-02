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
        "provider metadata survives cache": "search:v10:" in _src("src/services/search_content_pure.zig")
            and "content.cacheIdentity(" in resolver and "w.blob(it.provider.name())" in resolver
            and "search_view.Provider.init(r.blob()" in resolver,
        "actual torrent adapter providers": all(f'Provider.init("{name}")' in resolver for name in ("rss", "yts", "eztv"))
            and "Provider.init(eng_name)" in resolver and "Provider.init(src_id)" in resolver,
    }, "Owned resolver snapshots preserve stable actions, content policy and actual torrent metadata")


@test("Search v2 native view uses artwork shelves and owned snapshots", "Search")
def test_search_v2_native_view():
    search = _src("src/services/search.zig")
    shell = _src("src/ui/shell.zig")
    header = _between(search, "pub fn renderSearchContent()", "pub fn renderShellSearchControls(")
    controls = _between(search, "pub fn renderShellSearchControls(", "fn searchButton(")
    omnibox = _between(shell, "fn omnibox(", "fn openOmniboxTarget(")
    top = _between(shell, "fn renderTopNav(", "fn renderPlayerTopNav()")
    refresh = _between(search, "fn refreshSearchView()", "fn renderProviderFacet()")
    renderer = _between(search, "fn renderUniversalResults()", "fn showResult(")
    row = _between(search, "fn renderCompactRow(", "pub fn ")
    sources = _between(search, "fn renderSearchSources()", "fn renderUniversalResults()")
    filters = _between(search, "fn renderSearchFilters()", "fn filterChip(")
    return _checked({
        "one shell search field": omnibox.count("dvui.textEntry(") == 1 and top.count("omnibox(narrow);") == 1
            and "var search_row" not in shell and "navLink(.search" not in shell,
        "legacy input only outside page shell": "if (!state.app.page_shell_enabled)" in header
            and "submitSearchInput(" in header and "const modes" not in header,
        "one copied Enter and Search dispatch": "const entered = te.enter_pressed" in omnibox
            and 'chromeIconButton(@src(), icons.tvg.lucide.search, "Search"' in omnibox
            and "(!entered and !submitted)" in omnibox
            and omnibox.index("@memcpy(query_buf") < omnibox.index("switch (browser_pure.classifyOmnibox(text))"),
        "explicit assistant bypasses legacy memory mode": "search_mod.memory_mode = false" in omnibox
            and "defer search_mod.memory_mode = legacy_memory_mode" in omnibox,
        "shell owns Search controls": "search_mod.renderShellSearchControls(compact)" in top
            and "state.app.router.current == .search" in top,
        "facet panel separate from provider settings": "renderSearchFilters()" in header and "renderActiveSearchFilters()" in header
            and "view_filters: search_view.Filters" in search,
        "heap immutable snapshot": "allocator.alloc(resolver.ResolvedItem, resolver.MAX_RESULTS)" in refresh
            and "resolver.copySearchSnapshot(" in refresh and "resolver.results_mutex.lock()" not in renderer,
        "one match/sort policy": "search_view.matches(" in refresh and "search_view.lessThan(" in refresh
            and "resolver.sortResultsBy(" not in renderer,
        "sort popup closes on selection": "popup.close();" in _between(search, "fn searchSelectImpl(", "const CONTENT_LABELS"),
        "compact sort popup": "searchSelectImpl(91300, &SORT_LABELS, @intFromEnum(view_sort), dense)" in controls and "&SORT_LABELS" in controls
            and "components.segment(" not in controls and "searchSelect(91300" not in renderer,
        "filtered content totals": "{d} titles · {d} other releases" in renderer and "galleryGroupVisible(group)" in renderer,
        "visible artwork only": "art.data().visible()" in renderer and "components.galleryCoverArt(" in renderer,
        "keyboard details action retained": 'actionButton(@src(), "Details"' in renderer,
        "shared content grouping": "search_content.projectInto(" in renderer and "galleryGroupVisible(" in renderer,
        "global search regardless browse route": "browser.searchCurrentBrowse(text)" not in omnibox and "search_mod.submitQuery(text)" in omnibox,
        "snapshot-owned action": "view_cache.rows.?[action.idx]" in renderer and "resolver.playResolvedItem(item)" in renderer,
        "safe torrent queue": "torrent_risk_pure.zig" in renderer and "risk.risk == .block" in renderer and "addToQueue(" in renderer,
        "stable result widget identities": "resolver.actionKey(item)" in row and ".id_extra = row_key" in row,
        "progress cancellation and retry": '@import("resolver.zig").cancel()' in controls and '"Retry search"' in sources
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


@test("Search shell dense controls and mirrored query ownership", "Search")
def test_search_shell_dense_and_query_ownership():
    search = _src("src/services/search.zig")
    shell = _src("src/ui/shell.zig")
    submit = _between(search, "pub fn submitQuery(", "pub fn setUniversalQuery(")
    mirror = _between(search, "pub fn setUniversalQuery(", "fn cancelPendingMemorySearch()")
    clear = _between(search, "pub fn clearShellSearch()", "pub var memory_mode")
    controls = _between(search, "pub fn renderShellSearchControls(", "fn searchButton(")
    icons = _between(search, "fn searchIconButton(", "fn searchButton(")
    select = _between(search, "fn searchSelectImpl(", "const CONTENT_LABELS")
    omnibox = _between(shell, "fn omnibox(", "fn openOmniboxTarget(")
    return _checked({
        "dense named icon controls": all(token in controls for token in (
            "if (dense) searchIconButton", "filters_tip", '"Cancel search"', '"Retry search"')),
        "bounded icon target with tooltip": ".max_size_content = .{ .w = 16, .h = 16 }" in icons
            and ".padding = dvui.Rect.all(5)" in icons and "components.tip(" in icons,
        "dense Sort keeps full named choices": "if (icon_only) dvui.menuItemIcon" in select
            and "dvui.menuItemLabel(@src(), label" in select
            and "components.tip(@src(), data, current_label)" in select,
        "query owned before cancellation and mirrored writes": submit.index("@memcpy(owned") < submit.index("cancelPendingMemorySearch()")
            and "setUniversalQuery(owned[0..n])" in submit
            and mirror.index("@memcpy(owned") < mirror.index("@memset(&search_buf"),
        "both query fields mirrored": "@memcpy(search_buf[0..n], owned[0..n])" in mirror
            and "@memcpy(state.app.magnet_buf[0..n], owned[0..n])" in mirror,
        "Clear invalidates both worker pipelines and visible fields": all(token in clear for token in (
            "cancelPendingMemorySearch()", "search_abort.store(true", "search_generation.fetchAdd",
            "@memset(&search_buf", "@memset(&state.app.magnet_buf", 'resolver.zig").clearResults()', "view_dirty = true")),
        "every new submission cancels stale memory publication": omnibox.index("search_mod.cancelPendingMemorySearch()")
            < omnibox.index("switch (browser_pure.classifyOmnibox(text))"),
        "shell Clear reaches coherent service": "search_mod.clearShellSearch()" in omnibox,
        "retained query does not block player autohide": ".typing = false" in shell
            and ".typing = text_len > 0" not in shell,
        "compact input avoids inherited button and field margins": ".margin = dvui.Rect.all(0)" in icons
            and ".margin = dvui.Rect.all(0)" in omnibox,
    }, "Dense icons keep named menus; query aliases are owned and Clear cancels both pipelines")


@test("Visual search content grouping previews and stable artwork lifetimes", "Search")
def test_visual_search_gallery():
    search = _src("src/services/search.zig")
    grouping = _src("src/services/search_content_pure.zig")
    preview = _src("src/services/search_preview.zig")
    pure_preview = _src("src/services/search_preview_pure.zig")
    main = _src("src/main.zig")
    build = _src("build.zig")
    return _checked({
        "bounded grouped content projection": "pub fn projectInto(" in grouping and "pub fn evictionIndex(" in grouping,
        "artwork card detail and hero": all(name in search for name in ("renderGalleryCard", "renderGalleryHero", "galleryCategoryLabel", "Available sources")),
        "stable poster worker addresses": "gallery_covers: [196]GalleryCover" in search and "!entry.slot.fetching" in search,
        "progressive selection identity": "gallery_layout.retainSelection(" in search,
        "explicit isolated preview": "preview.start()" in search and "preview.select(" in search and "state.app.players.append" not in preview,
        "hidden or empty feature stops preview": 'view_cache.count == 0) @import("search_preview.zig").stop()' in search
            and 'else @import("search_preview.zig").stop()' in search,
        "filtered categories use wrapping native grid": "if (view_filters.content != .all)" in search
            and "var grid = dvui.flexbox" in search,
        "preview shares typed load transport": "loadDetached(handle" in preview and '"loadfile"' not in preview,
        "verified embed allowed by production CSP": "frame-src 'self' https://www.youtube-nocookie.com" in _src("src/services/remote_static.zig"),
        "preview stop before worker barrier": main.index("search.shutdown();") < main.index("workers.beginShutdownAndDrain(800)"),
        "artwork cleanup after worker barrier": main.index("workers.beginShutdownAndDrain(800)") < main.index("search.deinitGallery();"),
        "verified preview parser on production path": "pure.parseForId(" in preview and "pub fn parseForId(" in pure_preview,
        "ready artwork fetch decisions use tested policy": "shouldFetchCover(" in _src("src/ui/components.zig"),
        "saved titles reopen universal query": '.search =>' in _src("src/ui/home.zig") and 'submitQuery(query)' in _src("src/services/browser.zig"),
        "saved native title uses portable search link": '"opal://search/{s}"' in search
            and 'item.poster_url[0..item.poster_url_len], reopen)' in search,
        "regressions registered": all(f'b.path("{file}")' in build for file in ("src/ui/search_gallery_pure.zig", "src/services/search_content_pure.zig", "src/services/search_preview_pure.zig")),
    }, "Content shelves use stable artwork, explicit isolated previews and strict grouped sources")
