"""Browse — anime card posters survive an SWR revalidate.
See tests/features/harness.py for the shared @test decorator, helpers, and
run_all()."""
from .harness import *  # noqa: F401,F403


@test("Anime poster lifecycle", "Browse")
def test_anime_poster_lifecycle():
    # The anime grid rendered almost entirely blank film-icon placeholders even
    # though every cover downloaded and decoded fine. Cause: the poster fetch is
    # a per-row state machine over (fetching, attempted, failed, pixels, tex).
    # A successful load ends at tex=set, pixels=null (freed at upload). When the
    # stale-while-revalidate network parse came back, parseJikan reused the rows
    # and retired their textures — but cleared only the texture, not the
    # attempted/failed latch. The row was then attempted=true + pixels=null +
    # tex=null, which is precisely the latch's definition of "tried and failed",
    # so it set poster_failed and the card stayed blank forever, never
    # refetching and never logging.
    #
    # Verify the state machine is pure + routed (tested logic == shipped logic)
    # and that every parser that retires a row's texture resets the latch with
    # it. The visual outcome (posters actually painting) is GUI-only and was
    # confirmed by running the app; only the wiring is asserted here.
    pure = _src("src/services/anime_pure.zig")
    anime = _src("src/services/anime.zig")

    # The grid's per-frame decision lives in the pure module, with the
    # regression pinned by a unit test (zig build test).
    pure_checks = {
        "pure state machine": "pub fn posterAction" in pure,
        "row model": "pub const PosterRow" in pure,
        "actions cover the lifecycle": all(
            a in pure for a in ("mark_attempted", "latch_failed", "fetch", "none")
        ),
        "regression test present": "must not latch it dead" in pure,
        # The latch must still fire for a genuinely dead URL — the fix must not
        # turn it into an every-frame respawn loop.
        "real failures still latch": "a real failure still latches" in pure,
    }

    # Every render site routes through the pure fn rather than re-deriving the
    # branch inline (it was duplicated three times, which is how the bug hid).
    routed = anime.count("anime_pure.posterAction(")
    pure_checks["all 3 render sites routed"] = routed == 3
    pure_checks["no inline latch left"] = (
        "item.poster_attempted and item.poster_pixels == null" not in anime
    )

    # THE FIX: a parser retiring a row's texture must clear the latch with it.
    # Each of the three parsers (Lists / Jikan / scraper) pairs its
    # queueTexFree + poster_tex = null with attempted/failed resets.
    resets = anime.count("item.poster_attempted = false;")
    pure_checks["parsers reset the latch when retiring a texture"] = resets >= 2
    pure_checks["jikan parser resets latch (the bug)"] = (
        "item.poster_attempted = false;\n            item.poster_failed = false;" in anime
    )

    missing = [k for k, ok in pure_checks.items() if not ok]
    if not missing:
        return "pass", "anime poster lifecycle: pure posterAction routed at all 3 render sites; parsers reset the latch when retiring a texture"
    return "fail", "anime poster lifecycle incomplete: " + ", ".join(missing)
