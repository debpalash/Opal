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


@test("Plugins has its own nav-bar menu and route", "UI Standards")
def test_plugins_navbar_menu():
    """Plugins moved out of the combined "Logs & Plugins" system page into a
    dedicated nav-bar dropdown + `.plugins` route with its own sub-tabs."""
    sh = _src("src/ui/shell.zig")
    rt = _src("src/core/router.zig")
    st = _src("src/core/state.zig")
    pl = _src("src/services/plugins.zig")

    checks = {
        # Route + tab vocabulary live in the pure, unit-tested router module.
        "plugins route": "    plugins,\n" in rt,
        "PluginTab enum": "pub const PluginTab = enum" in rt,
        "tab order table": "pub const PLUGIN_TABS" in rt,
        "tab labels": "pub fn pluginTabLabel" in rt,
        "tab hints": "pub fn pluginTabHint" in rt,
        # Router unit tests cover the split and the tab table.
        "route unit test": "plugins is a first-class route" in rt,
        "tab unit test": "every plugin tab is listed exactly once" in rt,
        # State holds the sub-tab.
        "plugin_tab state": "plugin_tab: @import(\"router.zig\").PluginTab" in st,
        "drawer tab routes to it": ".Plugins => app.router.navigate(.plugins)" in st,
        # Nav bar: a real dropdown menu, not a sub-tab behind the Logs icon.
        "menu fn": "fn pluginsMenu()" in sh,
        "menu mounted": "    pluginsMenu();" in sh,
        "menu iterates table": "router.PLUGIN_TABS" in sh and "router.pluginTabLabel(" in sh,
        "menu shows hints": "router.pluginTabHint(" in sh,
        "menu sets tab + navigates": "state.app.plugin_tab = t;" in sh,
        "puzzle icon": "icons.tvg.lucide.puzzle" in sh,
        # The old combined button is gone; Logs stands alone. (Match the call
        # site, not the string — the comment above it still names the old page.)
        "logs button renamed": 'icons.tvg.lucide.@"scroll-text", "Logs",' in sh
                               and 'icons.tvg.lucide.@"scroll-text", "Logs & Plugins"' not in sh,
        "no logs/plugins subtab strip": "&.{ .Logs, .Plugins }" not in sh,
        # Page renders one section at a time, sharing the generic tab strip.
        "plugins page case": ".plugins => {" in sh,
        "generic subtab strip": "fn subTabsOf(" in sh,
        "plugin subtabs reuse it": "fn pluginSubTabs()" in sh and "subTabsOf(router.PluginTab" in sh,
        # Sections split out of the single scroll, reusing the same renderers.
        "renderSection": "pub fn renderSection(" in pl,
        "content section extracted": "fn renderContentPlugins()" in pl,
        "legacy page still stacks all": "renderContentPlugins();" in pl,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "plugins nav-bar menu incomplete: " + ", ".join(missing)
    return "pass", ("Plugins is a top-level route with a nav-bar dropdown (5 sections, "
                    "labels+hints from router.PLUGIN_TABS) and an in-page tab strip "
                    "sharing subTabsOf; Logs is now its own button")


@test("Installed sources are not silently dropped by a full table", "UI Standards")
def test_source_table_capacity():
    """Reported as "some sources are not installing".

    Install writes `~/.config/opal/plugins/sources/<id>.json` — that part always
    worked. `reload()` then flattens EVERY key of EVERY file into one fixed
    table, so the table is sized in FIELDS, not sources: `{"base":…,"api":…}`
    costs two slots, torrentio costs three. The table held 64 slots and dropped
    the excess in silence.

    Measured on a live install: 56 source files, 77 fields, 13 dropped — 10
    sources (academictorrents, cyberflix, glotorrents, iptv-italia,
    iptv-org-index, m3upt, streamingcatalogs, tdtchannels, tubi-tv, yts) whose
    files existed but whose endpoints were never loaded. `has(id)` said "not
    installed", so the page kept offering Install; `get(id, field)` returned
    null, so the source was inert at runtime. Clicking Install changed nothing.

    Three parts to the fix: a table big enough, an overflow that is logged
    instead of swallowed, and an install indicator that reads the filesystem
    rather than the table."""
    sc = _src("src/core/source_config.zig")
    sp = _src("src/core/source_config_pure.zig")
    pr = _src("src/services/plugin_repo.zig")
    bz = _src("build.zig")

    checks = {
        "pure registered": "source_config_pure.zig" in bz,
        "capacity is a named constant": "pub const MAX_ENTRIES = 512" in sp,
        "table uses it": "const MAX_ENTRIES = pure.MAX_ENTRIES;" in sc,
        # Overflow must be counted and reported, not skipped.
        "counts every field": "fields_seen += 1;" in sc,
        "overflow pure": "pub fn overflowBy(" in sp,
        "overflow logged as error": 'logs.pushLog("error", "sources"' in sc and "inert" in sc,
        # Install state comes from the file, not the parsed table.
        "install state from disk": "io.cwdStatFile(fp) catch return false" in pr,
        "not from the table": "return source_config.has(id);" not in pr,
        # One filename rule, shared by install/uninstall/reload.
        "one id rule": "pub fn validId(" in sp,
        "install uses it": "if (!pure.validId(id)) return false;" in sc,
        "uninstall uses it": "if (!pure.validId(id)) return;" in sc,
        "reload uses it": "pure.idFromFileName(entry.name)" in sc,
        "no duplicated id loop": "ch == '/' or ch == '\\\\' or ch == '.' or ch == 0" not in sc,
        # Regression tests name the measurement.
        "capacity test": "the table holds every field a full install can produce" in sp,
        "measured numbers": "56" in sp and "77" in sp,
        "traversal still rejected": 'validId("..")' in sp,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "source table capacity fix incomplete: " + ", ".join(missing)
    return "pass", ("source endpoint table sized in fields (512, was 64) with a loud "
                    "error on overflow; install state reads the source file, not the "
                    "parsed table; one shared filename-safety rule")
