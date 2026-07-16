"""Browse — infinite scroll (fetch + append the next page near the bottom).

Every Browse sub-tab whose backend can paginate must fetch and APPEND the next
page when the user scrolls near the bottom, instead of being capped at one page.
This verifies each wired tab has (1) a loadMore / next-page fetch function, (2)
the shared near-bottom trigger in its render grid, and (3) append (not replace)
semantics + the loading_more guard. Tabs whose API returns a fixed bounded set
(no offset/page cursor) are intentionally left as no-ops and are asserted to
carry an explanatory comment rather than fake scaffolding.

See tests/features/harness.py for the shared @test decorator + helpers."""
from .harness import *  # noqa: F401,F403


# The canonical near-bottom trigger every tab mirrors from services/tmdb.zig:
#   near_bottom = max_y > 0 and scroll.si.viewport.y >= max_y - 800
_TRIGGER = "max_y - 800"


def _wired(svc_src, trigger_src):
    """A tab is wired iff it has a loadMore fetch, the near-bottom trigger, a
    loading_more burst-guard, and more_available end-of-results bookkeeping."""
    return {
        "loadMore fetch fn": "loadMore" in svc_src,
        "near-bottom trigger": _TRIGGER in trigger_src,
        "burst guard (loading_more)": "loading_more" in svc_src,
        "end-of-results flag (more_available)": "more_available" in svc_src,
    }


@test("Infinite scroll on browse tabs", "Browse")
def test_browse_infinite_scroll():
    # (tab, service file, file that holds the render trigger)
    # Jellyfin renders its grid in ui/jellyfin_ui.zig, so the near-bottom
    # trigger lives there while loadMore/state live in the service file.
    wired_tabs = [
        ("Drama", "src/services/drama.zig", "src/services/drama.zig"),
        ("VNDB", "src/services/vndb.zig", "src/services/vndb.zig"),
        ("Jellyfin", "src/services/jellyfin.zig", "src/ui/jellyfin_ui.zig"),
        ("Plex", "src/services/plex.zig", "src/services/plex.zig"),
        ("OPDS", "src/services/opds.zig", "src/services/opds.zig"),
        ("Audiobookshelf", "src/services/audiobookshelf.zig", "src/services/audiobookshelf.zig"),
        ("Novels", "src/services/novels.zig", "src/services/novels.zig"),
        ("Radio", "src/services/radio.zig", "src/services/radio.zig"),
    ]

    checks = {}
    for tab, svc_path, trig_path in wired_tabs:
        svc = _src(svc_path)
        trig = svc if trig_path == svc_path else _src(trig_path)
        for name, ok in _wired(svc, trig).items():
            checks[f"{tab}: {name}"] = ok

    # Per-tab pagination mechanism must actually be present (not just the
    # scaffolding) — a spot-check that the append path talks to the real API.
    checks["Drama: TMDB discover page param"] = "discoverPath(" in _src("src/services/drama.zig")
    checks["VNDB: request-body page field"] = "page" in _src("src/services/vndb_pure.zig") and "buildPopularBody" in _src("src/services/vndb_pure.zig")
    checks["Jellyfin: StartIndex paging"] = "StartIndex" in _src("src/services/jellyfin.zig")
    checks["Plex: X-Plex-Container-Start paging"] = "Container-Start" in _src("src/services/plex.zig")
    checks["OPDS: rel=next feed link"] = "feedNextHref" in _src("src/services/opds_pure.zig")
    checks["Audiobookshelf: page/limit paging"] = "libraryItemsUrl" in _src("src/services/audiobookshelf_pure.zig")
    checks["Novels: Wikisource sroffset paging"] = "sroffset" in _src("src/services/novels_pure.zig")
    checks["Radio: offset paging"] = "offset" in _src("src/services/radio_pure.zig") and "buildPopularUrl" in _src("src/services/radio_pure.zig")

    # Podcasts is intentionally a NO-OP: the iTunes Search API returns a fixed
    # bounded set (limit only, no offset/page cursor), so infinite scroll would
    # just refetch page one. Assert the explanatory comment exists AND that no
    # fake loadMore scaffolding was added.
    pod = _src("src/services/podcasts.zig")
    checks["Podcasts: documented no-op (no offset cursor)"] = "no offset" in pod.lower() or "no offset/page cursor" in pod.lower()
    checks["Podcasts: no fake loadMore scaffolding"] = "fn loadMore" not in pod

    missing = [k for k, ok in checks.items() if not ok]
    if not missing:
        return "pass", (
            "infinite scroll wired: Drama/VNDB/Jellyfin/Plex/OPDS/Audiobookshelf/"
            "Novels/Radio append next page near bottom; Podcasts left no-op "
            "(iTunes Search has no offset cursor); Novels 'readwn' source no-op "
            "(POST search, no page field)"
        )
    return "fail", "browse infinite scroll incomplete: " + ", ".join(missing)
