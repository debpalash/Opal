"""Source config layer — the three interlocking fixes from the tracker scan.

A4/A3  Torznab was hardcoded to Jackett's URL shape, so the source shipped as
       "Torznab / Prowlarr" could not reach Prowlarr or bitmagnet; and jackett.py
       read its own engines/engines/jackett.json while the Plugins page wrote
       ~/.config/opal/plugins/sources/jackett.json.
A1     The ~25 nova2 Python engines hardcoded their URLs and never opened the
       source files the Plugins page writes — install/uninstall controlled
       nothing for them.
E3     No source had a mirror/fallback domain; one blocked host = a silent dead
       source.

See tests/features/harness.py for the shared @test decorator + helpers."""
from .harness import *  # noqa: F401,F403

import json as _json
import os
import subprocess
import sys
import tempfile
import textwrap


def _run_py(script):
    """Run a snippet against a THROWAWAY config/cache root so the suite never
    reads or writes the developer's real installed sources."""
    tmp = tempfile.mkdtemp(prefix="opal-src-layer-")
    env = dict(os.environ)
    env["XDG_CONFIG_HOME"] = os.path.join(tmp, "cfg")
    env["XDG_CACHE_HOME"] = os.path.join(tmp, "cache")
    env.pop("APPDATA", None)
    env.pop("LOCALAPPDATA", None)
    path = os.path.join(tmp, "check.py")
    with open(path, "w") as fh:
        fh.write("import sys\nsys.path.insert(0, %r)\n" % os.path.join(PROJECT_DIR, "engines"))
        fh.write(textwrap.dedent(script))
    return subprocess.run([sys.executable, path], env=env, capture_output=True, text=True, timeout=120)


@test("Torznab endpoint path is a template (Jackett/Prowlarr/bitmagnet)", "Sources")
def test_torznab_path_template():
    problems = []
    pure = _src("src/services/torznab_pure.zig")
    resolver = _src("src/services/resolver.zig")

    # 1) The URL shape lives in the tested pure module, defaulting to Jackett's.
    for sym in ("pub const DEFAULT_PATH", "pub fn expandPath", "pub fn buildSearchUrl"):
        if sym not in pure:
            problems.append(f"torznab_pure missing {sym}")
    if "/api/v2.0/indexers/{indexer}/results/torznab/api" not in pure:
        problems.append("torznab_pure DEFAULT_PATH is not Jackett's shape")

    # 2) REGRESSION: the resolver must not rebuild the Jackett URL itself.
    if "results/torznab/api?apikey=" in resolver:
        problems.append("resolver.zig still hardcodes the Jackett torznab path")
    if "tz.buildSearchUrl(" not in resolver:
        problems.append("resolver.zig does not route through torznab_pure.buildSearchUrl")
    # The lookup used to be hardcoded to the "torznab" id. It is now per-id, so
    # a Prowlarr entry gets the same treatment -- see the TORZNAB_IDS test below.
    if 'get(src_id, "path")' not in resolver:
        problems.append("resolver.zig never reads the torznab path template")

    # 3) The misleading "Prowlarr works" claim is gone from the comments.
    block = _between(resolver, "// Backend: Torznab", "fn resolveTorznab")
    if "bitmagnet" not in block or "Prowlarr" not in block:
        problems.append("torznab comment block does not document the three server shapes")

    # 4) Manifest exposes the field so the user can set it.
    with open(os.path.join(PROJECT_DIR, "data", "plugins-manifest.json")) as fh:
        manifest = _json.load(fh)
    entry = next((p for p in manifest["plugins"] if p["id"] == "torznab"), None)
    if not entry:
        problems.append("manifest has no torznab entry")
    else:
        if "path" not in entry["endpoints"]:
            problems.append("manifest torznab entry has no path endpoint")
        if "bitmagnet" not in entry["name"]:
            problems.append("manifest torznab entry is still named Jackett-only")

    if problems:
        return "fail", "; ".join(problems)
    return "pass", "path template + pure URL builder wired"


@test("Jackett engine reads the config the Plugins page writes", "Sources")
def test_jackett_single_config():
    problems = []
    src = _src("engines/engines/jackett.py")

    if "import opal_sources" not in src:
        problems.append("jackett.py does not use the shared source config")
    if "opal_sources.sources_dir()" not in src:
        problems.append("jackett.py CONFIG_PATH is not the installed-source path")
    if "opal_sources.load(SOURCE_ID)" not in src:
        problems.append("jackett.py does not load the installed source file")
    # Both key spellings accepted, so install ({base, apikey}) works unchanged.
    if "'base'" not in src or "'apikey'" not in src:
        problems.append("jackett.py does not accept the base/apikey endpoint names")
    # REGRESSION: it must never create the user file (that would fake an install).
    if "def save_configuration" in src:
        problems.append("jackett.py still writes a config file back")
    # REGRESSION: errors must not be emitted as fake torrent result rows.
    err = _between(src, "def handle_error", "def pretty_printer_thread_safe")
    if "pretty_printer_thread_safe" in err or "prettyPrinter" in err:
        problems.append("jackett.py still prints errors as search results")
    if "sys.stderr" not in err:
        problems.append("jackett.py errors do not go to stderr")

    # The manifest supplies the api key slot the engine needs.
    with open(os.path.join(PROJECT_DIR, "data", "plugins-manifest.json")) as fh:
        manifest = _json.load(fh)
    entry = next((p for p in manifest["plugins"] if p["id"] == "jackett"), None)
    if not entry or "apikey" not in entry.get("endpoints", {}):
        problems.append("manifest jackett entry has no apikey endpoint")

    # Functional: an installed source file drives the engine's url + key.
    r = _run_py("""
        import json, os
        import opal_sources
        sd = opal_sources.sources_dir()
        os.makedirs(sd, exist_ok=True)
        json.dump({"base": "http://10.0.0.9:9117/", "apikey": "ABC123"},
                  open(os.path.join(sd, "jackett.json"), "w"))
        import engines.jackett as j
        assert j.jackett.url == "http://10.0.0.9:9117", j.jackett.url
        assert j.jackett.api_key == "ABC123", j.jackett.api_key
        assert "malformed" not in j.CONFIG_DATA, j.CONFIG_DATA
        print("OK")
    """)
    if "OK" not in r.stdout:
        problems.append("engine did not pick up the installed config: " + (r.stderr or r.stdout)[-300:])

    if problems:
        return "fail", "; ".join(problems)
    return "pass", "one config file, read by the engine"


@test("nova2 engines read the installed source config", "Sources")
def test_nova2_engines_read_source_config():
    problems = []

    helper = os.path.join(PROJECT_DIR, "engines", "opal_sources.py")
    if not os.path.exists(helper):
        return "fail", "engines/opal_sources.py missing"

    nova2 = _src("engines/nova2.py")
    if "import opal_sources" not in nova2:
        problems.append("nova2.py does not import the shared source config")
    if "opal_sources.search_with_failover" not in nova2:
        problems.append("nova2.py run_search does not apply the installed base")
    if "opal_sources.installed_ids()" not in nova2:
        problems.append("nova2.py keeps its own copy of the sources path")

    # Functional, end to end: an installed base overrides the engine's hardcoded
    # url; with nothing installed the hardcoded url still applies.
    r = _run_py("""
        import json, os
        import opal_sources, novaprinter, nova2

        sd = opal_sources.sources_dir()
        os.makedirs(sd, exist_ok=True)
        json.dump({"base": "https://installed.example"},
                  open(os.path.join(sd, "stubengine.json"), "w"))

        class stubengine:
            url = "https://hardcoded.example"
            name = "Stub"
            supported_categories = {"all": ""}
            def search(self, what, cat="all"):
                if self.url == "https://installed.example":
                    novaprinter.prettyPrinter({"link": "magnet:?xt=1", "name": "hit",
                                               "size": "1 MB", "seeds": 1, "leech": 0,
                                               "engine_url": self.url, "desc_link": ""})

        assert "stubengine" in nova2.installed_engines()
        assert nova2.run_search((stubengine, "q", nova2.Category.all, "stubengine"))
        assert novaprinter.printed_count() == 1, "installed base was not applied"
        # Not installed -> the engine keeps its own url (no behaviour change).
        assert opal_sources.candidates_for("nosuch", stubengine.url) == ["https://hardcoded.example"]
        print("OK")
    """)
    if "OK" not in r.stdout:
        problems.append("engine base override failed: " + (r.stderr or r.stdout)[-400:])

    if problems:
        return "fail", "; ".join(problems)
    return "pass", "installed base drives the nova2 engines"


@test("Sources fail over to mirror domains", "Sources")
def test_source_mirrors():
    problems = []

    # 1) Selection logic is pure + registered for `zig build test`.
    if not os.path.exists(os.path.join(PROJECT_DIR, "src/core/mirrors_pure.zig")):
        return "fail", "src/core/mirrors_pure.zig missing"
    pure = _src("src/core/mirrors_pure.zig")
    for sym in ("pub fn candidates", "pub fn attemptIndex", "pub fn looksBlocked", "pub fn shouldFailover"):
        if sym not in pure:
            problems.append(f"mirrors_pure missing {sym}")
    if "mirrors_pure.zig" not in _src("build.zig"):
        problems.append("mirrors_pure.zig not registered in the build.zig test step")

    drv = _src("src/core/mirrors.zig")
    if 'source_config.get(id, "mirrors")' not in drv:
        problems.append("mirrors.zig does not read the mirrors endpoint field")
    if "pure.attemptIndex" not in drv or "pure.shouldFailover" not in drv:
        problems.append("mirrors.zig does not route through the pure selection logic")

    # 2) A mirrors LIST in the manifest survives install (it used to be dropped:
    #    both the manifest serializer and the parser took strings only).
    if ".array" not in _src("src/services/plugin_repo.zig"):
        problems.append("plugin_repo drops list-valued endpoints on install")
    if ".array" not in _src("src/core/source_config.zig"):
        problems.append("source_config drops list-valued endpoint fields")

    # 3) Wired into the Zig sources that own a base.
    resolver = _src("src/services/resolver.zig")
    if resolver.count('mirrors.zig").fetch(') < 2:
        problems.append("resolver.zig sources do not fetch through mirror failover")

    # 4) Python side: ordered failover + last-good memory, end to end.
    r = _run_py("""
        import json, os
        import opal_sources, novaprinter, nova2

        sd = opal_sources.sources_dir()
        os.makedirs(sd, exist_ok=True)
        json.dump({"base": "https://dead.example",
                   "mirrors": ["https://live.example", "https://other.example"]},
                  open(os.path.join(sd, "stubengine.json"), "w"))

        class stubengine:
            url = "https://hardcoded.example"
            name = "Stub"
            supported_categories = {"all": ""}
            def search(self, what, cat="all"):
                if self.url == "https://live.example":
                    novaprinter.prettyPrinter({"link": "magnet:?xt=1", "name": "hit",
                                               "size": "1 MB", "seeds": 1, "leech": 0,
                                               "engine_url": self.url, "desc_link": ""})

        assert opal_sources.candidates_for("stubengine", stubengine.url) == [
            "https://dead.example", "https://live.example", "https://other.example"]
        assert nova2.run_search((stubengine, "q", nova2.Category.all, "stubengine"))
        assert novaprinter.printed_count() == 1, "dead base did not fail over"
        # Last-good is remembered and tried first next time.
        assert opal_sources.last_good("stubengine") == "https://live.example"
        assert opal_sources.candidates_for("stubengine", stubengine.url)[0] == "https://live.example"
        # A comma-separated string is the same list as a JSON array.
        assert opal_sources.parse_mirrors("a, b;c\\nd") == ["a", "b", "c", "d"]
        # Trailing-slash shape follows the engine's own url (404s otherwise).
        assert opal_sources.normalize_base("https://a/", "https://b/") == "https://a/"
        assert opal_sources.normalize_base("https://a/", "https://b") == "https://a"
        print("OK")
    """)
    if "OK" not in r.stdout:
        problems.append("python mirror failover failed: " + (r.stderr or r.stdout)[-400:])

    if problems:
        return "fail", "; ".join(problems)
    return "pass", "ordered failover + last-good memory, both layers"


@test("Installed sources are migrated when the manifest corrects an endpoint", "Sources")
def test_source_version_migration():
    """A source installed once kept its endpoints forever.

    The installed file at ~/.config/opal/plugins/sources/<id>.json overrides both
    the manifest AND the engine's own hardcoded default, and nothing ever compared
    the manifest's per-plugin `version` against what was on disk. So a corrected
    endpoint could never reach anyone who had already installed the source.

    That is not theoretical. `yts.mx` lost its NS delegation at the .mx registry
    (dig returns no NS and no A), and `limetorrent.in` began serving a TheRarBg
    page under a 200 OK — so it failed while looking alive. Both were corrected in
    the manifest; every existing install carried on querying the dead host.

    The installed file now carries the manifest version it was written from, and
    startup rewrites any source the manifest has since bumped."""
    pr = _src("src/services/plugin_repo.zig")
    sp = _src("src/core/source_config_pure.zig")
    mn = _src("src/main.zig")
    mf = _json.loads(_src("data/plugins-manifest.json"))

    by_id = {p["id"]: p for p in mf["plugins"]}

    checks = {
        # Pure, tested version comparison — not a string compare.
        "versionNewer exists": "pub fn versionNewer(" in sp,
        "version key named": 'pub const VERSION_KEY = "_v"' in sp,
        "numeric-order test": "1.10.0" in sp and "not string order" in sp,
        "pre-versioning upgrade test": "predating versioning" in sp,
        # Writer stamps the version; migration reads it back.
        "writer stamps version": "fn writeSourceVersioned(" in pr,
        "install stamps": "writeSourceVersioned(pl.idSlice()" in pr,
        "starter pack stamps": "writeSourceVersioned(id, pl.endpoints" in pr,
        "migration exists": "pub fn migrateStaleSources(" in pr,
        "migration routes through pure": "pure.versionNewer(manifest_v, installed_v)" in pr,
        "only migrates installed": "if (!source_config.has(id)) continue;" in pr,
        # Runs at startup, not only when the Plugins page is opened.
        "wired at startup": "migrateStaleSources()" in mn,
        # The two corrected sources must carry a bumped version, or existing
        # installs never pick the fix up — the bug this whole test exists for.
        "yts bumped": by_id["yts"]["version"] != "1.0.0",
        "limetorrents bumped": by_id["limetorrents"]["version"] != "1.0.0",
        # And they must point somewhere that is not the known-dead host.
        "yts off yts.mx": "yts.mx" not in _json.dumps(by_id["yts"]["endpoints"]),
        "limetorrents off limetorrent.in": "limetorrent.in" not in _json.dumps(
            by_id["limetorrents"]["endpoints"]),
        # kickass was 14 bytes of "404: Not Found" — must not come back.
        "kickass gone from manifest": "kickass" not in by_id,
        "kickass engine deleted": _src("engines/engines/kickass.py") == "",
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "source version migration incomplete: " + ", ".join(missing)
    return "pass", ("installed sources carry the manifest version they came from; "
                    "startup rewrites any the manifest has since corrected "
                    "(yts.mx / limetorrent.in both dead), routed through "
                    "source_config_pure.versionNewer")


@test("A source dropped from the shipped code is uninstalled, not just unlisted", "Sources")
def test_dead_sources_are_retired():
    """Removing a dead source from the code only stops OFFERING it.

    migrateStaleSources walks the manifest, so a source *removed* from the
    manifest is precisely the one it cannot reach — the install file stays, and
    the file is what the loaders read. `stremio.loadInstalledAddons()` scans
    ~/.config/opal/plugins/sources itself and accepts any file with a "stremio"
    field, so `cyberflix` and `knightcrawler` were still live add-ons in an
    existing profile after both were deleted from `addKnownAddons` — measured
    2026-07-30: cyberflix's manifest returns 404 and knightcrawler serves a page
    titled "KnightCrawler is deprecated" under a 200 OK, which the resolver would
    parse as a manifest. `kickass` was the same shape: engine file deleted,
    install left behind.

    The retirement must be keyed on the dead host, not on the id alone: the same
    id re-pointed at a self-hosted instance is working user config.
    """
    pr = _src("src/services/plugin_repo.zig")
    sp = _src("src/core/source_config_pure.zig")
    mn = _src("src/main.zig")
    st = _src("src/services/stremio.zig")
    mf = _json.loads(_src("data/plugins-manifest.json"))
    by_id = {p["id"]: p for p in mf["plugins"]}

    checks = {
        # Pure, tested decision — and the table lives next to it.
        "shouldRetire exists": "pub fn shouldRetire(" in sp,
        "retirement table exists": "pub const RETIRED = [_]Retired{" in sp,
        "host-keyed test": "re-pointed the id at their own instance" in sp,
        "table well-formed test": "the retirement table is well-formed" in sp,
        # Caller routes through the pure rule and gates on being installed.
        "retirement exists": "pub fn retireDeadSources(" in pr,
        "routes through pure": "pure.shouldRetire(r.host, installed_val)" in pr,
        "only retires installed": "if (!source_config.has(r.id)) continue;" in pr,
        "deletes the file": "source_config.uninstallById(r.id)" in pr,
        # Runs at startup, after the manifest migration.
        "wired at startup": "retireDeadSources()" in mn,
        "runs after migration": mn.index("migrateStaleSources()") < mn.index(
            "retireDeadSources()"),
        # Every retired id must be gone from the shipped surfaces too, or startup
        # deletes a file the app then re-offers.
        "kickass gone from manifest": "kickass" not in by_id,
        "cyberflix gone from manifest": "cyberflix" not in by_id,
        "knightcrawler gone from manifest": "knightcrawler" not in by_id,
        "cyberflix not offered": '.url = "https://cyberflix' not in st,
        "knightcrawler not offered": '.name = "KnightCrawler"' not in st,
    }

    # The three retired ids in the pure table must be exactly what the docs and
    # the manifest agree are gone — a silent 4th entry would delete user config.
    ids = _re.findall(r'\.id = "([^"]+)", \.field', sp)
    if sorted(ids) != ["cyberflix", "kickass", "knightcrawler"]:
        return "fail", f"unexpected RETIRED ids {ids} — each deletes a user's file"

    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "dead-source retirement incomplete: " + ", ".join(missing)
    return "pass", (f"{len(ids)} retired sources uninstalled at startup, each only "
                    "while it still points at the host that died")


@test("No manifest base overrides a working engine default with a dead host", "Sources")
def test_manifest_base_matches_engine_default():
    """A regression the source-config unification introduced.

    Before engines read the installed config, a nova2 engine used its own
    hardcoded `url` and a stale manifest entry was harmless. Now the installed
    file wins, so a manifest base pointing somewhere dead actively DISABLES an
    engine that would otherwise have worked.

    That happened: `torrentproject`'s manifest base was `torrentproject2.net`
    (curl http=000, connection refused) while the engine's own default
    `torrentproject.com.se` answered 200. Unifying the config made the source
    worse than leaving it alone.

    This test does not check reachability (no network in the suite, and these
    hosts are flaky by nature). It checks the invariant that CAUSED the bug: a
    manifest base and its engine's default must not disagree. When they must
    diverge, record it here with the reason so the divergence is deliberate."""
    import os as _os
    import re as _re2

    manifest = _json.loads(_src("data/plugins-manifest.json"))
    bases = {p["id"]: p["endpoints"]["base"]
             for p in manifest["plugins"]
             if isinstance(p.get("endpoints"), dict) and "base" in p["endpoints"]}

    # Divergences that are intentional. Empty today — keep it that way, or
    # justify each entry inline.
    ALLOWED = {}

    eng_dir = _os.path.join(PROJECT_DIR, "engines", "engines")
    if not _os.path.isdir(eng_dir):
        return "skip", "engines/engines not present"

    mismatches = []
    for fn in sorted(_os.listdir(eng_dir)):
        if not fn.endswith(".py") or fn == "__init__.py":
            continue
        eid = fn[:-3]
        if eid not in bases:
            continue
        src = _src(_os.path.join("engines", "engines", fn))
        m = _re2.search(r"^\s*url\s*=\s*['\"]([^'\"]+)['\"]", src, _re2.M)
        if not m:
            continue
        engine_url = m.group(1).rstrip("/")
        manifest_url = bases[eid].rstrip("/")
        if engine_url != manifest_url and ALLOWED.get(eid) != manifest_url:
            mismatches.append(f"{eid}: manifest={manifest_url} engine={engine_url}")

    if mismatches:
        return "fail", ("manifest base disagrees with the engine default (the "
                        "manifest wins at runtime, so a dead value here disables a "
                        "working engine): " + "; ".join(mismatches))
    return "pass", (f"all {len(bases)} manifest bases agree with their engine's own "
                    "default, so unifying the config cannot disable a working host")


@test("Every Torznab-compatible source id is actually queried", "Sources")
def test_torznab_ids_are_read():
    """Adding a manifest entry nobody reads is the session's recurring bug.

    `resolveTorznab` used to read exactly one hardcoded source id, "torznab".
    Shipping a separate "prowlarr" entry — with the path template verified from
    Prowlarr's own NewznabController, [HttpGet("/api/v1/indexer/{id:int}/newznab")]
    — would have produced yet another install button that changed nothing.

    So: every manifest entry carrying a Torznab `path` must be in TORZNAB_IDS,
    and every id in TORZNAB_IDS must exist in the manifest. And `jackett` must
    NOT be there: nova2's jackett.py already queries it, so listing it would hit
    the user's Jackett twice per search — the double-scrape that made the native
    1337x resolver worth deleting rather than repairing."""
    rv = _src("src/services/resolver.zig")
    manifest = _json.loads(_src("data/plugins-manifest.json"))

    block = _between(rv, "const TORZNAB_IDS", ";")
    listed = set(_re.findall(r'"([a-z0-9_-]+)"', block))

    path_sources = {p["id"] for p in manifest["plugins"]
                    if isinstance(p.get("endpoints"), dict) and "path" in p["endpoints"]}
    manifest_ids = {p["id"] for p in manifest["plugins"]}

    checks = {
        "TORZNAB_IDS exists": bool(listed),
        "resolver loops the table": "for (TORZNAB_IDS) |id| resolveTorznabId(" in rv,
        "per-id fn reads the id": 'sc.get(src_id, "base")' in rv,
        "no hardcoded torznab lookup": 'sc.get("torznab"' not in rv,
        # Every source shipping a path template must be queried.
        "all path-sources queried": path_sources <= listed,
        # And nothing listed may be missing from the manifest.
        "no phantom ids": listed <= manifest_ids,
        # jackett is covered by nova2 — listing it double-queries.
        "jackett excluded": "jackett" not in listed,
        "exclusion explained": "jackett.py" in _between(rv, "/// `jackett` is deliberately NOT here",
                                                        "const TORZNAB_IDS"),
        # Prowlarr's verified path must be what ships.
        "prowlarr path verified": any(
            p["id"] == "prowlarr" and p["endpoints"].get("path") == "/api/v1/indexer/{indexer}/newznab"
            for p in manifest["plugins"]),
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", ("torznab id wiring incomplete: " + ", ".join(missing) +
                        f" (listed={sorted(listed)}, path_sources={sorted(path_sources)})")
    return "pass", (f"all {len(listed)} Torznab ids ({', '.join(sorted(listed))}) are read by "
                    "the resolver; jackett excluded to avoid double-querying via nova2")


@test("Prowlarr: the shipped URL resolves on a server that answers", "Sources")
def test_prowlarr_url_against_live_server():
    """Every Prowlarr check so far was static — nothing ever answered.

    The path template was read out of Prowlarr's own source, but a template that
    is *quoted* correctly and a template that a running Prowlarr actually routes
    are different claims, and only the first had ever been tested. So: stand up a
    server implementing Prowlarr's real routing and drive the shipped URL at it.

    Prowlarr's NewznabController carries BOTH routes on one handler (verified
    against develop):

        [HttpGet("/api/v1/indexer/{id:int}/newznab")]
        [HttpGet("{id:int}/api")]

    which is why this repo documents two different-looking Prowlarr paths — they
    are aliases, not a contradiction. Note `{id:int}`: the indexer segment must be
    NUMERIC, so `resolveTorznabId`'s "all" fallback (fine for Jackett) cannot work
    against Prowlarr. The manifest ships "1" for exactly that reason.

    The URL under test is not re-derived here; it is the expected string pinned by
    torznab_pure's own `buildSearchUrl` test, so this cannot drift from the
    builder. A wrong-shape URL must 404 — otherwise the test would pass no matter
    what the template said.
    """
    import http.server
    import threading
    import urllib.error
    import urllib.parse
    import urllib.request

    APIKEY = "KEY"
    FEED = ('<?xml version="1.0" encoding="UTF-8"?>'
            '<rss version="2.0" xmlns:torznab="http://torznab.com/schemas/2015/feed">'
            '<channel><title>Prowlarr</title>'
            '<item><title>Dune 2021 1080p BluRay x264</title>'
            '<guid>abc</guid>'
            '<enclosure url="magnet:?xt=urn:btih:AAAABBBBCCCCDDDDEEEE" '
            'length="2147483648" type="application/x-bittorrent" />'
            '<torznab:attr name="seeders" value="42" />'
            '<torznab:attr name="size" value="2147483648" />'
            '</item></channel></rss>')

    hits = []

    class Handler(http.server.BaseHTTPRequestHandler):
        # Prowlarr's routes: /{id:int}/api and /api/v1/indexer/{id:int}/newznab.
        ROUTES = (_re.compile(r"^/(\d+)/api$"),
                  _re.compile(r"^/api/v1/indexer/(\d+)/newznab$"))

        def do_GET(self):  # noqa: N802
            path, _, qs = self.path.partition("?")
            params = urllib.parse.parse_qs(qs)
            hits.append(self.path)
            if not any(r.match(path) for r in self.ROUTES):
                self.send_error(404, "no route")
                return
            if params.get("apikey", [""])[0] != APIKEY:
                self.send_error(401, "bad apikey")
                return
            if params.get("t", [""])[0] != "search":
                self.send_error(400, "unsupported t")
                return
            body = FEED.encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/rss+xml")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_a):
            pass  # keep the suite output clean

    srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        pure = _src("src/services/torznab_pure.zig")
        # The Prowlarr URL the builder is pinned to produce, taken from its own
        # test so the two cannot disagree.
        pinned = _re.search(r'"(http://127\.0\.0\.1:9696/\d+/api\?[^"]+)"', pure)
        if not pinned:
            return "fail", ("torznab_pure's buildSearchUrl test no longer pins a "
                            "Prowlarr URL — nothing to drive")
        built = pinned.group(1).replace("127.0.0.1:9696", f"127.0.0.1:{port}")

        def get(url):
            try:
                with urllib.request.urlopen(url, timeout=10) as r:
                    return r.status, r.read().decode()
            except urllib.error.HTTPError as e:
                return e.code, ""
            except Exception as e:  # pragma: no cover
                return 0, str(e)

        status, body = get(built)
        if status != 200:
            return "fail", f"shipped Prowlarr URL got {status}, not 200: {built}"

        # The feed must carry what the resolver reads off each <item>.
        for needle in ("<item>", "<title>", "magnet:?xt=urn:btih:",
                       'name="seeders"'):
            if needle not in body:
                return "fail", f"Prowlarr feed missing {needle!r}"

        # The manifest's own template must expand to a route this server serves.
        mf = _json.loads(_src("data/plugins-manifest.json"))
        pl = next(p for p in mf["plugins"] if p["id"] == "prowlarr")
        tmpl = pl["endpoints"]["path"].replace("{indexer}", pl["endpoints"]["indexer"])
        m_status, _ = get(f"http://127.0.0.1:{port}{tmpl}?apikey={APIKEY}&t=search&q=dune")
        if m_status != 200:
            return "fail", (f"manifest prowlarr path {tmpl!r} got {m_status} on a "
                            "server implementing Prowlarr's real routes")

        # Negative control: Jackett's shape must NOT resolve here, or this test
        # would pass for any template at all.
        j_status, _ = get(f"http://127.0.0.1:{port}"
                          f"/api/v2.0/indexers/1/results/torznab/api?apikey={APIKEY}&t=search&q=dune")
        if j_status == 200:
            return "fail", "Jackett's path also answered — the mock is not route-strict"

        # And a non-numeric indexer must fail, which is why "all" cannot be the
        # Prowlarr default.
        a_status, _ = get(f"http://127.0.0.1:{port}/all/api?apikey={APIKEY}&t=search&q=dune")
        if a_status == 200:
            return "fail", "a non-numeric indexer answered — mock ignores {id:int}"
    finally:
        srv.shutdown()
        srv.server_close()

    return "pass", (f"shipped Prowlarr URL returns a parseable torznab feed over HTTP "
                    f"({len(hits)} requests); Jackett's path and a non-numeric "
                    "indexer both 404 as Prowlarr would")


@test("EZTV: JSON API backend, sharing the Stremio IMDb lookup", "Sources")
def test_eztv_api_backend():
    """EZTV's HTML search is unusable and no amount of scraping fixes it.

    Measured 2026-08-01: eztvx.to resets ~90% of connections, and its live
    mirror is Cloudflare-walled AND lists rows linking to `/ep/<id>/` detail
    pages instead of embedding magnets — 50 browser fetches per search. The JSON
    API answers the same question in ONE request with magnet, seeds, peers and
    byte size inline, unwalled.

    It is IMDb-keyed rather than text-searchable, which is why this waited on
    resolveImdbId being extracted from resolveStremio: the query→IMDb step is
    shared, not duplicated. Two lookups that drifted would send the two backends
    after different titles for the same query.
    """
    rv = _src("src/services/resolver.zig")
    ez = _src("src/services/eztv_api_pure.zig")
    bld = _src("build.zig")
    mf = _json.loads(_src("data/plugins-manifest.json"))
    eztv = next((p for p in mf["plugins"] if p["id"] == "eztv"), None)

    checks = {
        "backend exists": "fn resolveEztv(" in rv,
        "shares the IMDb lookup": "resolveImdbId(query_buf[0..qlen], api_key" in rv,
        "no duplicate lookup": rv.count("fn resolveImdbId(") == 1,
        # Fan-out: a status nobody waits on means the search reports done early.
        "status declared": "pub var status_eztv" in rv,
        "pre-set before the wave": "Pre.set(&status_eztv" in rv,
        "spawned": "Spawn.go(resolveEztv, &status_eztv)" in rv,
        "awaited in checkAllDone": "status_eztv.load(.acquire) != .searching" in rv,
        # Neutral-ship: inert until the user installs the source.
        "inert without the source": ('sc.get("eztv", "base") orelse {' in rv and
                                      "noteWorkerOutcome(.unavailable)" in rv),
        # Carries the fields the result row now shows.
        "fills size and leech": "item.size_bytes = it.size_bytes;" in rv and "item.leech = it.peers;" in rv,
        # Heap, not a spawned worker's stack (CLAUDE.md thread rules).
        "page buffer on the heap": "alloc.alloc(u8, 512 * 1024)" in rv,
        # Pure parsing, tested.
        "parser is pure": "pub fn parseItems(" in ez,
        "tt-prefix guarded": "pub fn stripTtPrefix(" in ez,
        "id validated before the URL": "pub fn isNumericId(" in ez,
        "unit tests registered": "eztv_api_pure.zig" in bld,
        # The quoted-number case: size_bytes arrives as a STRING.
        "quoted numbers tested": "arrives QUOTED" in ez,
        # The mirror is justified: the API answers there, the HTML page does not.
        "api mirror shipped": eztv is not None and
                              "https://eztv1.xyz" in _json.dumps(eztv["endpoints"].get("mirrors", [])),
        "eztv version bumped": eztv is not None and eztv["version"] != "1.0.0",
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "eztv api backend incomplete: " + ", ".join(missing)
    return "pass", ("EZTV served from its JSON API in one request, reusing the "
                    "Stremio IMDb lookup; inert until the source is installed")


@test("Resolver: results go to a sink, so a warm cannot clobber a search", "Sources")
def test_resolver_sink():
    """pushResult wrote straight into the global results array.

    That is what made a background warm impossible: filling the cache for the
    next episode of a show would have overwritten the list the user was looking
    at. The destination is now a property of the WORKER, not the module — the
    live sink is still the globals the UI renders, so the search path is
    unchanged, and only a worker that opts in writes elsewhere.

    Both halves had to be de-globalised, not just one: the insert (pushInto) AND
    the encoder (serializeRows). A warm that wrote a different blob shape than
    the live path would poison the cache the live path reads back.
    """
    rv = _src("src/services/resolver.zig")
    lib = _src("src/services/tv_library.zig")

    checks = {
        "sink type exists": "pub const Sink = struct" in rv,
        "sink is per-thread": "threadlocal var thread_sink" in rv,
        "insert takes the destination": "fn pushInto(" in rv,
        "live path still the globals": "pushInto(&results, &result_count, &results_from_cache" in rv,
        "encoder takes explicit rows": "fn serializeRows(" in rv,
        "live encoder delegates": "return serializeRows(results[0.." in rv,
        # Ranking must be shared, or the cache disagrees with the search.
        "one insert path": rv.count("fn pushInto(") == 1,
        # A warm scores against its OWN query; the live query would match 0%.
        "scores against the sink query": "computeMatchAgainst(scored_item, query)" in rv,
        "sink carries a query": "query: []const u8 = \"\"," in rv,
        # Real consumer — the sink is not a speculative abstraction.
        "warm exists": "pub fn warmQuery(" in rv,
        "warm writes to the cache": "content_cache.put(cacheKey(&key_buf, query)" in rv,
        # Narrow on purpose: speculative work must not cost a full search.
        "warm is narrow": "resolveEztv(qbuf, query.len)" in rv and "resolveTorznab(qbuf" in rv,
        # Superseded-wave guard applies to the live path only; a warm has no wave.
        "wave guard is live-only": "if (thread_sink == null and worker_gen != run_gen" in rv,
        # Speculative adapters run on arbitrary worker threads. Their failures /
        # publication flag must not leak into a live worker's terminal outcome.
        "warm preserves outcome context": all(s in rv for s in (
            "const prev_gen = worker_gen", "const prev_reported = worker_reported",
            "const prev_produced = worker_produced", "worker_reported = prev_reported",
            "worker_produced = prev_produced")),
        # Both result and terminal-status publication reject superseded waves.
        "terminal status has the generation gate": "lifecycle.mayMutateLive(.live, worker_gen, active_run)" in rv,
        # Trigger, bounded.
        "triggered from Watching": "warmNextUp();" in lib,
        "one show, once": "if (S.done or S.busy) return;" in lib,
        "off the UI thread": "std.Thread.spawn(.{}, S.run" in lib,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "resolver sink incomplete: " + ", ".join(missing)
    return "pass", ("results routed through a per-thread sink; warm fills the "
                    "cache with the same ranking and encoder, never the live list")
