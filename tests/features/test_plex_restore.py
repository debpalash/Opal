"""Plex — a restored session must actually load its library.

Regression for the blank-tab-on-restart bug: init() restored the persisted token
and stamped conn_state = .connected, so renderContent() skipped the sign-in panel
and drew the "Plex · <server>" header — but the ONLY caller of the section fetch
was connect(), the first-run PIN flow. fetchSections() itself had ZERO callers, so
section_count stayed 0 and every relaunch showed a connected-looking, permanently
empty library.

A pure unit test can't catch "this function is never called" — that's a wiring
property of the whole tree, so it's asserted here.

See tests/features/harness.py for the shared @test decorator + helpers."""
from .harness import *  # noqa: F401,F403

import re


def _callers(src, fn):
    """Count call sites of `fn` outside its own declaration.

    Matches `fn(` but not `fn fn(` (the decl) and not `.fn(` (a method on
    something else). A detached-thread spawn passes the bare name with no
    parens — `Thread.spawn(.{}, fn, .{})` — so that form counts too.
    """
    calls = len([
        m for m in re.finditer(r"(?<![.\w])" + re.escape(fn) + r"\s*\(", src)
        if not src[:m.start()].rstrip().endswith("fn")
    ])
    spawns = len(re.findall(r"spawn\([^)]*?,\s*" + re.escape(fn) + r"\s*,", src))
    return calls + spawns


@test("Plex restored session loads its library", "Plex")
def test_plex_restored_session_loads_library():
    svc = _src("src/services/plex.zig")
    pure = _src("src/services/plex_pure.zig")

    checks = {}

    # The bug itself: the section fetch must be reachable from the render path,
    # not only from the first-run PIN flow.
    checks["fetchSections has a caller"] = _callers(svc, "fetchSections") > 0
    checks["renderContent triggers the section load"] = (
        "shouldFetchSections" in svc and "fetchSections()" in svc
    )

    # It must NOT be a latch set before the fetch succeeds — that turns one
    # transient failure at launch into a blank tab for the whole run.
    checks["retry is backed off, not latched"] = "SECTIONS_RETRY_S" in pure
    checks["attempt timestamp is stamped"] = "sections_last_attempt_s" in svc
    checks["in-flight guard prevents a fetch per frame"] = "sections_loading" in svc

    # ...and it must latch on the fetch SUCCEEDING, not on "we got sections".
    # A server with zero libraries loads successfully and empty; a count-based
    # latch would re-curl /library/sections every retry window forever.
    checks["latches on success, not on section_count"] = "sections_loaded_once" in svc
    checks["empty library still counts as loaded"] = (
        "sections_loaded_once.store(true" in svc
    )
    # Signing out must clear it, or a different account lands on a blank library.
    checks["disconnect clears the load latch"] = (
        "sections_loaded_once.store(false" in svc
    )
    checks["a failed load is surfaced to the user"] = (
        'pushLog("warn", "plex"' in svc or "pushLog(\"warn\", \"plex\"" in svc
    )

    # Production must route through the tested predicate (no drift).
    checks["render path uses the pure predicate"] = "plex_pure.shouldFetchSections(" in svc

    # Stale-append guard: a section index alone can't distinguish "same fetch"
    # from "same section re-opened" (the A -> B -> A case).
    checks["generation counter exists"] = "view_gen" in svc
    checks["worker publish routes through the pure guard"] = "plex_pure.workerMayPublish(" in svc
    checks["generation is bumped on section switch"] = "view_gen.fetchAdd" in svc
    checks["bare index compare no longer gates the append"] = (
        "if (section_idx != active_section) return;" not in svc
    )

    # The generation guard alone does NOT cover the same-frame case: loadMore()
    # reads view_gen after fetchItems() bumped it, so a stale append inherits the
    # current generation and passes. fetchItems must therefore claim is_loading
    # and reset the cursor on the UI thread BEFORE spawning, or the same frame's
    # infinite-scroll block appends the new section at the old section's offset.
    fetch_items = svc.split("pub fn fetchItems(")[1].split("\npub fn ")[0] if "pub fn fetchItems(" in svc else ""
    checks["fetchItems resets before spawning (not in the worker)"] = (
        "beginSectionLoad()" in fetch_items
        and fetch_items.index("beginSectionLoad()") < fetch_items.index("Thread.spawn")
    )
    checks["reset claims is_loading synchronously"] = "is_loading.store(true" in svc.split("fn beginSectionLoad()")[1][:200]
    checks["a failed spawn doesn't strand the tab loading"] = (
        "is_loading.store(false, .release); // never strand" in svc
    )

    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "plex restored-session load incomplete: " + ", ".join(missing)
    return "pass", (
        "restored token loads the library: fetchSections reachable from the render "
        "path, backed-off retry (not a pre-success latch), failure surfaced; "
        "stale-append guarded by a generation counter (A->B->A safe)"
    )
