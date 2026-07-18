#!/usr/bin/env python3
"""
Opal Feature Test Suite — entry point.

The suite was split from one ~3.9k-line file into per-category modules under
tests/features/ (see tests/features/harness.py for the shared @test decorator,
helpers, registry, and results.json writer). This shim simply imports every
category module so their @test functions register into the shared REGISTRY,
then runs them.

Invocation is unchanged:  `python3 tests/test_features.py`  (also `just test-all`).
Output is unchanged: tests/results.json (schema read by tests/dashboard.html).
"""

import os
import sys

# Make the `features` package importable regardless of CWD.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from features import harness

# Importing each module runs its @test decorators, registering into
# harness.REGISTRY. Order here is the run/report order (results are grouped by
# category downstream, so it is not load-bearing).
from features import (  # noqa: F401
    test_database,
    test_build,
    test_voice,
    test_ai,
    test_theming,
    test_player,
    test_stability,
    test_page_shell,
    test_page_shell2,
    test_page_shell3,
    test_audiobooks,
    test_reading,
    test_manga_madara,
    test_novels,
    test_novel_sources,
    test_gallerydl,
    test_vndb,
    test_drama,
    test_anime_schedule,
    test_anime_detail,
    test_anime_posters,
    test_manga_heancms,
    test_manga_themesia,
    test_manga_catalog,
    test_scrape_fetch,
    test_extension,
    test_anime_extractors,
    test_anime_sites,
    test_content_cache,
    test_browse_infinite_scroll,
    test_plex_restore,
    test_allanime_gated,
    test_plugins_logs_ui,
    test_dpi_bypass,
    test_browse_rail_groups,
)

if __name__ == "__main__":
    success = harness.run_all()
    sys.exit(0 if success else 1)
