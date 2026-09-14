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
import argparse


# The inventory reads the UTF-8 Zig/web tree from hundreds of small checks.
# Windows Python otherwise inherits the legacy ANSI codec and reports every
# non-ASCII source file as a product failure. Re-exec once in Python's native
# UTF-8 mode; the environment also makes spawned Python probes deterministic.
if os.name == "nt":
    os.environ["PYTHONUTF8"] = "1"
    if __name__ == "__main__" and not sys.flags.utf8_mode:
        os.execv(sys.executable, [sys.executable, *sys.argv])


def parse_args():
    parser = argparse.ArgumentParser(description="Opal feature checks (database diagnostics are read-only).")
    parser.add_argument("--database", help="Use an isolated SQLite fixture instead of the app database")
    parser.add_argument("--results", help="Write the JSON report to this path instead of tests/results.json")
    return parser.parse_args()


# Parse before importing/registering checks: --help and invalid arguments must
# not accidentally launch the full suite, build the app, or overwrite a report.
if __name__ == "__main__":
    args = parse_args()
    if args.database:
        os.environ["OPAL_TEST_DB"] = args.database
    if args.results:
        os.environ["OPAL_TEST_RESULTS"] = args.results

# Make the `features` package importable regardless of CWD.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from features import harness

# Importing each module runs its @test decorators, registering into
# harness.REGISTRY. Order here is the run/report order (results are grouped by
# category downstream, so it is not load-bearing).
from features import (  # noqa: F401
    test_architecture,
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
    test_anilist_sync,
    test_simkl_sync,
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
    test_jellyfin_state,
    test_allanime_gated,
    test_plugins_logs_ui,
    test_dpi_bypass,
    test_browse_rail_groups,
    test_iptv,
    test_suwayomi,
    test_mihon,
    test_music,
    test_universal_search,
    test_youtube_innertube,
    test_library,
    test_web_shell,
    test_web_ui,
    test_headless_auth,
    test_remote_stubs,
    test_headless_slim,
    test_aur_publish,
    test_web_parity2,
    test_windows_portability,
    test_trackers,
    test_source_layer,
    test_engine_health,
    test_parity,
)

if __name__ == "__main__":
    success = harness.run_all()
    sys.exit(0 if success else 1)
