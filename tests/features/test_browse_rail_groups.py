"""Browse rail — collapsible media-type groups.

The Sources rail grew to ~15 stacked icons. They're now folded into 6
collapsible media-type groups (Movies & TV / Video / Anime / Reading / Audio /
Web); each group is a header icon that expands to reveal its sources, and the
group holding the active tab is force-expanded. This pins that structure so a
new source tab can't silently fall out of every group.

See tests/features/harness.py for the shared @test decorator."""
from .harness import *  # noqa: F401,F403

import re


# Every source tab that must live inside exactly one rail group.
SOURCE_TABS = [
    "TMDB", "Drama", "Jellyfin", "Plex", "YouTube", "Anime", "Comics",
    "Novels", "Vndb", "Opds", "Podcasts", "Radio", "Audiobooks", "Web", "RSS",
]


@test("Browse rail groups every source", "UI Standards")
def test_browse_rail_groups():
    dr = _src("src/ui/drawer.zig")

    checks = {
        "RailGroup enum (6 media groups)": (
            "const RailGroup = enum { movies_tv, video, anime, reading, audio, web }" in dr
        ),
        "accordion state": "group_expanded" in dr and "rail_group_count" in dr,
        "collapsible render": "fn renderGroup(" in dr and "renderGroup(g, gi)" in dr,
        "active group force-expanded": "if (contains_active) group_expanded[gi] = true;" in dr,
        "chevron open/closed cue": (
            'lucide.@"chevron-down"' in dr and 'lucide.@"chevron-right"' in dr
        ),
        "flat source list removed": '"Asian Drama"' not in dr and '"Reading (OPDS)"' not in dr,
        "compact labels": '"Drama"' in dr and '"Books"' in dr and '"Jellyfin"' in dr,
    }

    # Every source tab appears in the groupOf() switch (i.e. is grouped). We check
    # the switch body specifically so a stray mention elsewhere can't pass it.
    m = re.search(r"fn groupOf\(tab: state\.DrawerTab\) \?RailGroup \{.*?\n\}", dr, re.S)
    group_of = m.group(0) if m else ""
    for t in SOURCE_TABS:
        checks[f"{t} is grouped"] = bool(re.search(r"\." + t + r"\b", group_of))

    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "rail grouping incomplete: " + ", ".join(missing)
    return "pass", "15 sources folded into 6 collapsible groups; active group auto-expands"
