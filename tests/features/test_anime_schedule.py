"""Browse — anime airing-schedule view + Anime News Network RSS feed.
See tests/features/harness.py for the shared @test decorator, helpers, and
run_all()."""
from .harness import *  # noqa: F401,F403


@test("Anime airing schedule + ANN feed", "Browse")
def test_anime_schedule():
    # Two anime-enrichment additions, neither of which adds a DrawerTab:
    #   1. "Airing this week" — a VIEW inside the Anime tab that renders AniList's
    #      Page.airingSchedules grouped by weekday; clicking a show kicks a
    #      universal search for a stream.
    #   2. Anime News Network registered as a built-in RSS feed.
    #
    # Verify the pure module is registered + routed (tested logic == shipped
    # logic), the AniList airingSchedules query is present, week-bucketing is
    # routed into the render, the Anime tab has the view-mode toggle + schedule
    # render branch (no new DrawerTab), the ANN feed URL is registered, and the
    # schedule click routes to submitQuery.
    pure = _src("src/services/anime_schedule_pure.zig")
    svc = _src("src/services/anime_schedule.zig")
    anime = _src("src/services/anime.zig")
    st = _src("src/core/state.zig")
    rss = _src("src/services/rss.zig")
    build = _src("build.zig")

    checks = {
        # ── Pure module: query build, parse, bucketing, formatting ──
        "pure module present": bool(pure),
        "pure week window": "pub fn weekWindow" in pure,
        "pure graphql builder": "pub fn buildQuery" in pure,
        "airingSchedules query": "airingSchedules(airingAt_greater" in pure and "airingAt_lesser" in pure,
        "pure parse into fixed buffers": "pub fn parseInto" in pure and "pub const Slot" in pure,
        "pure weekday bucketing": "pub fn dayIndexOf" in pure and "pub fn weekdayMon0" in pure,
        "pure time formatting": "pub fn fmtTime" in pure,
        # Zig-0.16 signed-zero-pad workaround: cast to unsigned before {d:0>2}.
        "unsigned cast before zero-pad": ": u32 = @intCast" in pure and "{d:0>2}:{d:0>2}" in pure,
        "pure has tests": pure.count('test "') >= 6,
        # ── Production routes through the pure fns (no drift) ──
        "service routes through pure": all(
            f"pure.{fn}(" in svc
            for fn in ("weekWindow", "buildQuery", "parseInto")
        ),
        "render routes through pure": all(
            f in anime
            for f in ("asp.dayIndexOf(", "asp.weekdayMon0(", "asp.fmtTime(", "asp.weekdayName(")
        ),
        # ── Service: off-thread fetch, mutex publish, atomic loading flag ──
        "async worker": "fn worker()" in svc and "std.Thread.spawn" in svc and ".detach()" in svc,
        "atomic loading flag": "sched_loading.store(true, .release)" in svc,
        "publishes under mutex": "parse_mutex.lock()" in svc,
        "heap fetch buffer": "alloc.alloc(u8," in svc,
        "curl to anilist": '"curl"' in svc and "graphql.anilist.co" in svc,
        "unix window from io_global": "io.timestamp()" in svc,
        # Click a scheduled show → universal search (navigate + submitQuery).
        "click routes to submitQuery": "clickSlot" in svc and 'submitQuery(' in svc and "navigateToTab(.Search)" in svc,
        # ── State: additive fields inside the existing anime struct, NO new tab ──
        "state view flag": "sched_view: bool" in st,
        "state schedule buffers": "sched: [60]anime_schedule_pure.Slot" in st and "sched_count: usize" in st,
        "state loading atomic": "sched_loading: std.atomic.Value(bool)" in st,
        "no new DrawerTab value": "AiringSchedule" not in st and "AnimeSchedule" not in st,
        # ── Anime tab: view-mode toggle + schedule render branch (no DrawerTab) ──
        "view toggle button": '"Airing this week"' in anime,
        "toggle flips sched_view": "state.app.anime.sched_view = !airing" in anime,
        "schedule render branch": "fn renderScheduleView" in anime and "renderScheduleView();" in anime,
        "schedule kicks its own fetch": "anime_schedule.loadSchedule()" in anime,
        "click wired in render": "anime_schedule.clickSlot(i)" in anime,
        # ── ANN RSS feed registered as a built-in default ──
        "ANN feed url": "https://www.animenewsnetwork.com/all/rss.xml" in rss,
        "ANN feed named": '"Anime News Network"' in rss,
        "ANN via addFeed": 'addFeed("Anime News Network"' in rss,
        # ── Pure module registered in the `zig build test` step ──
        "test registered": 'b.path("src/services/anime_schedule_pure.zig")' in build,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if not missing:
        return "pass", "airing schedule (AniList airingSchedules → weekday grid → submitQuery) + ANN feed wired"
    return "fail", "anime schedule wiring incomplete: " + ", ".join(missing)
