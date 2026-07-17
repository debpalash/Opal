"""Plugins page grouping/filter + compacted Logs view.

Two "so many sources now" upgrades:
1. The Plugins page groups the 45+ source catalog by category with a name/kind
   search + installed-only toggle, instead of a flat wall of identical rows.
2. The Logs view collapses consecutive identical lines into one ×N row and shows
   a level tag + source prefix, instead of a flat text-only dump.

Both route their decision logic through tested pure modules (plugins_pure /
logs_pure). See tests/features/harness.py for the shared @test decorator."""
from .harness import *  # noqa: F401,F403


@test("Plugins page groups + filters the source catalog", "UI Standards")
def test_plugins_grouped_filter():
    pl = _src("src/services/plugins.zig")
    pp = _src("src/services/plugins_pure.zig")
    bz = _src("build.zig")

    checks = {
        # Pure category/filter logic exists and is registered for `zig build test`.
        "pure categoryOf": "pub fn categoryOf" in pp and "ordered_categories" in pp,
        "pure matches filter": "pub fn matches(" in pp and "installed_only" in pp,
        "pure containsFold": "pub fn containsFold" in pp,
        "pure registered": "plugins_pure.zig" in bz,
        # Production routes through the pure module (no drift).
        "render uses categories": "pp.ordered_categories" in pl and "pp.categoryOf(" in pl,
        "render uses matches": "pp.matches(" in pl,
        # UI affordances: filter buffer, installed-only toggle, count summary.
        "filter state": "src_filter_buf" in pl and "src_installed_only" in pl,
        "count summary": "sources ·" in pl and "installed" in pl,
        "empty-filter message": "No sources match the filter." in pl,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "plugins page grouping/filter incomplete: " + ", ".join(missing)
    return "pass", ("plugins grouped by category with name/kind filter + "
                    "installed-only toggle + count summary, routed through plugins_pure")


@test("Logs view compacts duplicates + shows source", "UI Standards")
def test_logs_compacted():
    dr = _src("src/ui/drawer.zig")
    lp = _src("src/core/logs_pure.zig")
    bz = _src("build.zig")

    checks = {
        # Pure collapse + tag logic, registered.
        "pure sameLine": "pub fn sameLine" in lp,
        "pure levelTag": "pub fn levelTag" in lp,
        "pure registered": "logs_pure.zig" in bz,
        # Render collapses consecutive dups via the pure fn and shows a ×N badge.
        "render uses sameLine": "logs_pure.sameLine(" in dr,
        "render uses levelTag": "logs_pure.levelTag(" in dr,
        "run collapsing": "log_runs" in dr and ".count += 1" in dr,
        "dup badge": '"×{d}"' in dr,
        # Source prefix is now shown (was text-only before).
        "shows prefix": "l.prefix" in dr and "safeUtf8(l.prefix)" in dr,
        # Windowing preserved (last MAX_RENDER runs).
        "windowed": "MAX_RENDER" in dr and "first_run" in dr,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "logs compaction incomplete: " + ", ".join(missing)
    return "pass", ("logs collapse consecutive dups into ×N rows with level tag + "
                    "source prefix, routed through logs_pure, windowing preserved")
