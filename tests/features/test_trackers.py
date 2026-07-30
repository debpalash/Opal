"""Torrent tracker/peer layer: live public tracker list + stalled-torrent reannounce.
See tests/features/harness.py for the shared @test decorator and helpers."""
from .harness import *  # noqa: F401,F403
import os  # noqa: F401


@test("Live public tracker list fetched, cached and injected", "Torrents")
def test_live_tracker_list():
    # The wrapper used to hard-code 8 trackers in TWO places (torrent_add_magnet
    # and torrent_add_file, verbatim duplicates) with a dead `int tier` counter.
    # Now: one injection helper in C++, one runtime-fetched list in Zig, parsed
    # by a pure tested module, cached under ~/.cache/opal.
    cpp = _src("src/torrent_wrapper.cpp")
    hdr = _src("src/torrent_wrapper.h")
    svc = _src("src/services/trackers.zig")
    pure = _src("src/services/trackers_pure.zig")
    main = _src("src/main.zig")
    bld = _src("build.zig")

    checks = {
        # 1. The duplicated literal list is GONE — exactly one copy remains, and
        #    both add paths go through one helper.
        "single tracker literal in C++": cpp.count("udp://tracker.opentrackr.org:1337/announce") == 1,
        "one injection helper": cpp.count("add_extra_trackers(ctx, node)") == 2
                                and "static void add_extra_trackers(" in cpp,
        # 2. The dead `int tier = 10; ... tier++` is gone (never assigned to ae.tier).
        "dead tier counter removed": "int tier = 10;" not in cpp,
        # 3. Runtime list replaces the baked-in one through a new C entry point.
        "C++ exposes set_extra_trackers": "void torrent_set_extra_trackers(" in cpp
                                          and "torrent_set_extra_trackers(TorrentSession" in hdr,
        "empty list restores fallback": "if (parsed.empty())" in cpp and "DEFAULT_TRACKERS" in cpp,
        # 4. Both upstream sources, fetched at RUNTIME (GPL-2.0 list, GPL-3.0 app
        #    — the list is never vendored into the repo).
        "primary source (ngosang)": "ngosang/trackerslist/master/trackers_best.txt" in svc,
        "secondary source (cf)": "cf.trackerslist.com/best.txt" in svc,
        "_ip variant as DNS-blocklist fallback": "trackers_best_ip.txt" in svc,
        "list not vendored": not os.path.exists(os.path.join(PROJECT_DIR, "data", "trackers.txt")),
        # 5. Cached daily under ~/.cache/opal via paths.zig + io_global wrappers.
        "cache via paths.cacheFile": "paths.cacheFile(" in svc and '"trackers.txt"' in svc,
        "cache write via io_global": "io_g.cwdWriteFile(" in svc,
        "daily TTL decision is pure": "pure.needsRefresh(" in svc and "pub fn needsRefresh(" in pure,
        # 6. Parsing/validation is pure and PRODUCTION ROUTES THROUGH IT.
        "service parses via pure": "pure.parseInto(" in svc,
        "service serializes via pure": "pure.serializeZ(" in svc,
        "offline fallback via pure": "pure.appendFallback(" in svc and "pub const FALLBACK" in pure,
        "both separator styles handled": "BLANK LINE" in pure and "FIXTURE_PLAIN" in pure,
        "scheme filter": "VALID_SCHEMES" in pure and '"wss"' in pure,
        "host dedupe": "pub fn hasHost(" in pure and "hostOf(" in pure,
        "count cap": "MAX_TRACKERS" in pure and "list.count >= MAX_TRACKERS" in pure,
        "rejects non-announce URLs": "pub fn isAnnounceUrl(" in pure,
        "rejects DNS sinkhole 0.0.0.0": '"0.0.0.0"' in pure,
        # 7. Fallback stays in sync with the C++ default set (8 entries).
        "fallback still 8 trackers": pure.count('"udp://') >= 8,
        # 8. Wired into the frame loop, and the pure tests are registered.
        "ticked from appFrame": 'services/trackers.zig").tick()' in main,
        "pure test registered in build.zig": "trackers_pure.zig" in bld,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing: " + ", ".join(bad)
    return "pass", "one C++ injection point, runtime-fetched list, pure parser, daily cache"


@test("Stalled torrents detected and reannounced", "Torrents")
def test_stall_reannounce():
    # Before this, `grep -rn reannounce src/` returned nothing: Opal could not
    # detect or recover from a wedged torrent. A stalled download is an
    # inconvenience; a stalled stream is a frozen film.
    cpp = _src("src/torrent_wrapper.cpp")
    hdr = _src("src/torrent_wrapper.h")
    svc = _src("src/services/torrent_stall.zig")
    pure = _src("src/services/torrent_stall_pure.zig")
    main = _src("src/main.zig")
    bld = _src("build.zig")

    checks = {
        # 1. libtorrent's force_reannounce is finally exposed (+ DHT).
        "C++ force_reannounce": "handle.force_reannounce(" in cpp
                                and "torrent_force_reannounce(TorrentSession" in hdr,
        "ignores tracker min interval": "ignore_min_interval" in cpp,
        "also announces to DHT": "force_dht_announce()" in cpp,
        # 2. Progress is sampled in BYTES, not the coarse float progress.
        "downloaded-bytes accessor": "torrent_get_downloaded(" in cpp
                                     and "torrent_get_downloaded(TorrentSession" in hdr
                                     and "status().total_done" in cpp,
        # 3. The policy is pure and tested — not buried in C++ or a UI callback.
        "pure thresholds": "pub const Thresholds" in pure and "stall_secs" in pure
                           and "peer_floor" in pure,
        "pure min interval + backoff": "min_interval_secs" in pure
                                       and "pub fn backoffSecs(" in pure,
        "pure attempt cap / give up": "max_attempts" in pure and "give_up" in pure,
        "pure decision fn": "pub fn evaluate(" in pure,
        # 4. Production routes through the pure decision.
        "watchdog calls pure.evaluate": "pure.evaluate(" in svc,
        "watchdog uses pure thresholds": "pure.Thresholds{}" in svc,
        "watchdog calls force_reannounce": "torrent_force_reannounce(ses" in svc,
        "watchdog samples bytes+peers": "torrent_get_downloaded(ses" in svc
                                        and "torrent_get_num_peers(ses" in svc,
        # 5. Surfaced to the user, not a silent freeze.
        "logs the stall": "logs.pushLog(" in svc,
        "toasts on give-up": "showToastTyped(" in svc,
        # User-facing strings stay plain ASCII (no emoji, no em-dashes).
        "no emoji in surfaced strings": all(
            all(ord(ch) < 128 for ch in s)
            for s in _re.findall(r'"([^"\n]*)"', svc)
        ),
        # 6. Wired into the frame loop + registered for unit tests.
        "ticked from appFrame": 'services/torrent_stall.zig").tick()' in main,
        "pure test registered in build.zig": "torrent_stall_pure.zig" in bld,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing: " + ", ".join(bad)
    return "pass", "force_reannounce exposed, byte-based stall detection, backoff+cap in a pure module"
