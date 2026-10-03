"""Production ownership contracts; native renderer/state fixtures test behavior."""
from .harness import test, _src


def section(source, begin, end):
    return source[source.index(begin):source.index(end, source.index(begin))]


@test("Browse jobs own selection and cancellation before network work", "Browse")
def test_owned_browse_catalog_jobs():
    anime = _src("src/services/anime.zig")
    youtube = _src("src/services/youtube.zig")
    drama = _src("src/services/drama.zig")
    vndb = _src("src/services/vndb.zig")
    for name in ("trendingThread", "seasonalThread", "calendarThread"):
        worker = section(anime, "fn " + name + "(", "\n}\n")
        assert "job: GridJob" in worker and "job.url[0..job.url_len]" in worker
        for mutable in ("state.app.anime.cal_day", "state.app.anime.season_sel", "state.app.anime.season_year"):
            assert mutable not in worker, (name, mutable)
    assert "boundedSearchCurl" in anime and "searchEpoch(my_gen)" in anime
    assert "const key = job.key[0..job.key_len]" in drama
    assert "tmdbApiIntoExpected" in drama and "fetch_request.generation" in drama
    inner = section(youtube, "fn innertubePost(", "\nconst RowSource")
    assert ".cancel_epoch" in inner and "search_request.generation" in inner
    continuation = section(youtube, "fn rememberContinuation(", "\n}\n")
    assert continuation.index("yt_mutex.lock()") < continuation.index("if (!isCurrent(generation)) return") < continuation.index("cont_is_browse =")
    assert "search_request.generation" in vndb and "identity_request.generation" in vndb
    assert 'Browse regression YouTube stale response' in youtube
    return "pass", "Copied Anime URLs and Drama key; epoch-canceled catalogs; stale cursors rejected under publication lock"


@test("Anime related metadata owns jobs and publishes on the owner thread", "Browse")
def test_anime_independent_relation_publication():
    anime = _src("src/services/anime.zig")
    relation = section(anime, "pub fn loadRelations(", "/// Relation types worth surfacing")
    assert "const row = resultRow(idx)" in relation and "RelationsJob" in relation
    assert "var mal_id_buf" not in relation and "relations_busy.swap" not in relation
    assert "relations_request.begin(&relations_busy)" in relation
    assert "relations_request.generation" in relation
    worker = section(relation, "fn relationsWorker(", "fn applyPendingRelations(")
    assert "relations_pending_generation = job.generation" in worker
    assert "state.app.anime.relation_count =" not in worker
    assert "applyPendingRelations();" in anime
    assert 'Browse regression anime relation parser publishes owned records only' in anime
    return "pass", "Relations and episodes run independently; newer identity cancels old transport; owned records drain before rendering"


@test("Browse loading retains useful results and reaches themed skeletons", "Browse")
def test_browse_loading_and_failure_retention():
    anime = _src("src/services/anime.zig")
    drama = _src("src/services/drama.zig")
    anilist = _src("src/services/anilist.zig")
    for name in ("anime", "youtube", "drama", "vndb"):
        source = _src("src/services/" + name + ".zig")
        assert "pub fn setLoadingFixtureForTest(enabled: bool)" in source, name
        assert "Browse loading fixture is test-only" in source, name
        assert "coverSkeletonGrid" in source, name
    content = section(anime, "pub fn renderContent()", "\n}\n")
    assert 'dvui.label(@src(), "Loading..."' not in content
    page = section(drama, "fn fetchPage(", "/// Drain worker-staged results")
    assert page.index("catalogDocumentUsable") < page.index("pending_count = n")
    assert "Keep useful old rows" in page
    assert "Drama catalog unavailable" in drama and "Refresh unavailable" in drama
    keyless = section(anilist, "const CancelEpoch", "/// Search AniList for an anime by title")
    assert "io_global.Child" not in keyless and "reliable_fetch.zig" in keyless
    for name in ("fetchMetaByMalIds", "fetchSearch", "fetchBrowse"):
        assert "pub fn " + name + "WithCancellation" in keyless
    return "pass", "Initial grids render real skeletons; failed Drama refresh cannot erase cards; keyless AniList requests are bounded"


@test("Native sidebar retains destinations without a duplicate query row", "Browse")
def test_native_sidebar_navigation_contract():
    shell = _src("src/ui/shell.zig")
    toolbar = section(shell, "fn renderTopNav(", "/// Playback-only header")
    assert "browseSourcePicker(" not in toolbar
    assert toolbar.count("omnibox(narrow)") == 1
    sidebar = section(shell, "fn renderSidebar(", "/// Browse is one task")
    for group in ("WATCH_SOURCES", "LISTEN_SOURCES", "READ_SOURCES", "CONNECTED_SOURCES"):
        assert group in sidebar
    for route in (".home", ".search", ".watching", ".downloads", ".queue", ".history", ".plugins", ".settings", ".system"):
        assert route in sidebar
    assert "button.processEvents()" in sidebar and "button.drawFocus()" in sidebar
    assert "sidebar_user_expanded = !sidebar_expanded" in toolbar
    assert 'sidebarButton("Toggle sidebar"' not in sidebar
    overflow = section(shell, "fn renderSecondaryDestinations(", "fn renderOverflowItems(")
    for duplicate in ("Downloads", "History", "Queue", "Plugins", "Settings"):
        assert 'menuItemLabel(@src(), "' + duplicate + '"' not in overflow
    assert "setSidebarFixtureForTest" in shell and "sidebarBoundsForTest" in shell
    assert "sidebar_layout.layout(live_width" in shell
    anime = _src("src/services/anime.zig")
    for name in ("loadTrendingAnime", "loadSeasonal", "loadCalendar"):
        worker = section(anime, "pub fn " + name + "(", "\n}\n")
        assert "if (state.app.anime.is_loading.load(.acquire)) return" not in worker
    assert "stale and !busy" in anime
    return "pass", "Grouped focusable sidebar, bounded viewport, single query, and superseding Anime selections"
