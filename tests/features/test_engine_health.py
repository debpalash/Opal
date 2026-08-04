"""nova2 engine catalog invariants (see .research/engine-health.md).

The 2026-07-30 audit found `versions.txt` recorded a version for only 13 of the
25 shipped engines, one of the 13 (`uindex`) had drifted from the plugin's own
header, and one shipped "engine" (`kickass.py`) was a 14-byte HTTP error page
that has never imported. Nothing in the repo reads `versions.txt`, so nothing
noticed. These checks are that missing reader.

Deliberately offline: liveness of a torrent site is not a property of this repo
and would make the suite flap. Health lives in .research/engine-health.md.
"""
from .harness import *  # noqa: F401,F403
import os  # noqa: F401
import subprocess  # noqa: F401
import sys  # noqa: F401

ENGINES_DIR = os.path.join(PROJECT_DIR, "engines", "engines")
VERSIONS_TXT = os.path.join(ENGINES_DIR, "versions.txt")

# `kickass.py` is NOT a plugin: a 14-byte file whose entire content is the
# string below — a failed download committed verbatim. It is quarantined by
# exact content rather than by name, so the moment anyone replaces it with real
# code the quarantine lapses and every rule below applies to it. Do not add a
# second entry here to silence a failure; fix or delete the file.
QUARANTINE = {"kickass": "404: Not Found"}


def _plugin_files():
    return sorted(f[:-3] for f in os.listdir(ENGINES_DIR)
                  if f.endswith(".py") and f != "__init__.py")


def _header_version(name):
    """The plugin's own `# VERSION: x.y` line (nova2 allows no space after #)."""
    with open(os.path.join(ENGINES_DIR, name + ".py"), encoding="utf-8",
              errors="replace") as fh:
        for line in fh:
            m = _re.match(r"#\s*VERSION:\s*(\S+)", line)
            if m:
                return m.group(1)
            if line.strip() and not line.startswith("#"):
                break  # header block is over
    return None


def _versions_txt():
    out = {}
    with open(VERSIONS_TXT, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            k, _, v = line.partition(":")
            out[k.strip()] = v.strip()
    return out


@test("nova2 engine catalog: versions.txt complete and matching", "Torrents")
def test_engine_versions_manifest():
    files = _plugin_files()
    recorded = _versions_txt()
    problems = []

    for name in files:
        path = os.path.join(ENGINES_DIR, name + ".py")
        body = open(path, encoding="utf-8", errors="replace").read().strip()

        if name in QUARANTINE:
            # Quarantined entries must still be exactly the known-bad artifact,
            # and must NOT be given a fake version to look healthy.
            if body != QUARANTINE[name]:
                problems.append(f"{name}: quarantined as a non-plugin but the file "
                                f"changed -- give it a # VERSION header and a "
                                f"versions.txt entry, or delete it")
            elif name in recorded:
                problems.append(f"{name}: is not a plugin (content is "
                                f"{QUARANTINE[name]!r}) yet versions.txt claims "
                                f"version {recorded[name]}")
            continue

        hv = _header_version(name)
        if hv is None:
            problems.append(f"{name}: no '# VERSION:' header")
        if name not in recorded:
            problems.append(f"{name}: missing from versions.txt")
        elif hv is not None and recorded[name] != hv:
            problems.append(f"{name}: versions.txt says {recorded[name]}, "
                            f"file header says {hv}")

    for name in recorded:
        if name not in files:
            problems.append(f"{name}: in versions.txt but engines/engines/{name}.py "
                            f"does not exist")

    if problems:
        return "fail", "; ".join(problems)
    live = [f for f in files if f not in QUARANTINE]
    return "pass", (f"{len(live)} plugins, every one versioned and matching its "
                    f"header ({len(QUARANTINE)} quarantined non-plugin)")


@test("nova2 engine catalog: every plugin satisfies the import contract", "Torrents")
def test_engine_import_contract():
    # nova2.import_engine() does getattr(module, module_name), so the class name
    # must equal the filename, and the class needs the attributes nova2's
    # capabilities XML and search dispatch read. `kickass.py` fails all of this,
    # which is how it shipped broken and unnoticed.
    files = _plugin_files()
    expected = sorted(f for f in files if f not in QUARANTINE)

    try:
        p = subprocess.run([sys.executable, "engines/nova2.py", "--capabilities", "--names"],
                           cwd=PROJECT_DIR, capture_output=True, text=True, timeout=90)
    except Exception as e:
        return "fail", f"nova2.py --capabilities --names did not run: {e}"
    if p.returncode != 0:
        return "fail", f"nova2.py exited {p.returncode}: {p.stderr.strip()[:300]}"

    got = sorted(n for n in (s.strip() for s in p.stdout.split(",")) if n)
    missing = [n for n in expected if n not in got]
    if missing:
        return "fail", ("these plugins do not import (class name must match the "
                        "filename): " + ", ".join(missing))
    unexpected = [n for n in got if n in QUARANTINE]
    if unexpected:
        return "fail", f"quarantined non-plugin now imports: {', '.join(unexpected)} "
    return "pass", f"{len(expected)} plugins import and expose their capabilities"


# nova2's get_capabilities() reads `name` / `url` / `supported_categories` off
# the CLASS. tokyotoshokan assigns them on `self` in __init__ instead, so
# `nova2.py --capabilities` dies with
#   AttributeError: type object 'tokyotoshokan' has no attribute 'name'
# and returns XML for NO engine at all. Opal never calls --capabilities (only
# qBittorrent proper does), so it is latent -- but it is one engine away from
# being the only thing standing between here and a working capabilities probe.
# Pinned by name so the defect is tracked: fix tokyotoshokan and this test tells
# you to delete the entry; add a second such engine and it fails.
INSTANCE_ATTR_ONLY = {"tokyotoshokan"}


@test("nova2 engine catalog: plugins declare url + name + categories", "Torrents")
def test_engine_declares_url_and_categories():
    # Every engine hardcodes exactly one `url` today (tracker-scan E3: no source
    # has a mirror/fallback). This asserts the attributes nova2 and the audit
    # both depend on are present and that `url` is a real absolute URL -- a
    # plugin whose `url` silently vanished would surface as "returns nothing"
    # and nowhere else.
    problems = []
    class_level_missing = set()

    for name in _plugin_files():
        if name in QUARANTINE:
            continue
        src = open(os.path.join(ENGINES_DIR, name + ".py"),
                   encoding="utf-8", errors="replace").read()

        for attr in ("name", "url", "supported_categories"):
            if name == "jackett" and attr == "url":
                continue  # built from jackett.json at import time
            at_class = _re.search(rf"^\s{{4}}{attr}\s*=", src, _re.M)
            at_self = _re.search(rf"^\s+self\.{attr}\s*=", src, _re.M)
            if not (at_class or at_self):
                problems.append(f"{name}: declares no `{attr}`")
            elif not at_class:
                class_level_missing.add(name)

        if name == "jackett":
            continue
        m = _re.search(r"^\s{4}url\s*=\s*['\"]([^'\"]+)['\"]", src, _re.M)
        if not m:
            problems.append(f"{name}: no literal `url =` class attribute")
        elif not m.group(1).startswith(("http://", "https://")):
            problems.append(f"{name}: url is not absolute ({m.group(1)!r})")

    if class_level_missing != INSTANCE_ATTR_ONLY:
        newly_broken = class_level_missing - INSTANCE_ATTR_ONLY
        newly_fixed = INSTANCE_ATTR_ONLY - class_level_missing
        if newly_broken:
            problems.append("sets nova2's capabilities attributes on `self` "
                            "instead of the class, which breaks "
                            "`nova2.py --capabilities` for every engine: "
                            + ", ".join(sorted(newly_broken)))
        if newly_fixed:
            problems.append("fixed -- remove from INSTANCE_ATTR_ONLY: "
                            + ", ".join(sorted(newly_fixed)))

    if problems:
        return "fail", "; ".join(problems)
    return "pass", ("every plugin declares an absolute url, name and "
                    "supported_categories; 1 known instance-attr-only engine")


@test("nova2 engine catalog: no engine is orphaned by the install gate", "Torrents")
def engine_reachable_from_manifest():
    """Every shipped engine must have a manifest id, or it can never run.

    nova2.py filters engines through `opal_sources.installed_ids()`. An engine
    with no manifest id gets no install entry, so the gate drops it silently --
    indistinguishable at the CLI from a dead site. `piratebay.py` sat in the
    repo in exactly that state: it parsed fine and returned a full result set
    when called directly, but had returned zero through nova2 for its whole
    life. It was deleted rather than wired up, because it scraped the same
    apibay.org endpoint as `apibay.py` and returned byte-identical rows.
    """
    import json
    with open(os.path.join(PROJECT_DIR, "data", "plugins-manifest.json"),
              encoding="utf-8") as fh:
        raw = json.load(fh)
    plugins = raw["plugins"] if isinstance(raw, dict) else raw
    ids = {p["id"] for p in plugins}

    orphans = [n for n in _plugin_files()
               if n not in ids and n not in QUARANTINE]
    if orphans:
        return "fail", ("shipped but unreachable through nova2's install gate "
                        "(no manifest id): " + ", ".join(orphans))
    return "pass", f"all {len(_plugin_files())} engines have a manifest id"


@test("therarbg: a dead detail fetch drops one row, not the page", "Torrents")
def therarbg_detail_fetch_is_isolated():
    """Regression: IndexError inside handle_starttag zeroed the whole search.

    therarbg resolves each magnet by fetching that row's detail page from
    inside an HTMLParser callback. `magnet_urls[0]` was unguarded, so a single
    unresolvable magnet raised IndexError out through feed() and discarded
    every row already parsed -- a 50-row page became zero results. The site was
    serving 153 KB of good rows throughout.
    """
    sys.path.insert(0, ENGINES_DIR)
    sys.path.insert(0, os.path.join(PROJECT_DIR, "engines"))
    try:
        import therarbg as m
    except Exception as exc:  # pragma: no cover
        return "skip", f"cannot import therarbg: {exc}"

    if m.detail_url("https://therarbg.com", "/post-detail/x/") != \
            "https://therarbg.com/post-detail/x/":
        return "fail", "detail_url doubles the slash on a rooted href"
    if m.first_magnet('<a href="magnet:?xt=urn:btih:ABC">x</a>') != \
            "magnet:?xt=urn:btih:ABC":
        return "fail", "first_magnet did not extract a plain magnet href"
    for empty in ("<p>nothing</p>", "", None):
        if m.first_magnet(empty) is not None:
            return "fail", f"first_magnet({empty!r}) should be None, not raise"

    # Every detail fetch fails; the feed must still complete.
    real = m.retrieve_url
    m.retrieve_url = lambda _u: (_ for _ in ()).throw(OSError("dead fetch"))
    try:
        parser = m.therarbg.MyHtmlParser("https://therarbg.com")
        parser.feed('<table><tbody><tr><td>c</td>'
                    '<td><a href="/post-detail/a/b/">Some Release</a></td>'
                    '<td><a href="/get-posts/category:Movies/">Movies</a></td>'
                    '<td>d</td><td>e</td><td>1.0 GB</td><td>9</td><td>2</td>'
                    '</tr></tbody></table>')
    except Exception as exc:
        return "fail", f"a failing detail fetch still escapes feed(): {exc!r}"
    finally:
        m.retrieve_url = real
    return "pass", "unresolvable magnets skip their row; feed() survives"


@test("nova2 engine catalog: nothing prints to stdout but results", "Torrents")
def engines_do_not_pollute_stdout():
    """stdout is the result channel; a stray print() becomes a malformed row.

    nova2 engines emit results by calling prettyPrinter(), which writes one
    pipe-delimited row per torrent to stdout. Opal's resolver parses that
    stream line by line, so any other print() injects a bogus row.
    `torrentfunk.py` shipped a debug `print(url)` in search(): every query
    prefixed the result set with a bare URL line. It survived because the
    engine's row count was never checked against its printed line count.

    download_torrent() legitimately prints the saved path -- that is nova2's
    documented contract for that entry point, and it never runs during search.
    """
    import ast
    problems = []
    for name in _plugin_files():
        if name in QUARANTINE:
            continue
        path = os.path.join(ENGINES_DIR, name + ".py")
        with open(path, encoding="utf-8", errors="replace") as fh:
            src = fh.read()
        try:
            tree = ast.parse(src)
        except SyntaxError as exc:
            problems.append(f"{name}: does not parse ({exc})")
            continue

        # Anything under `if __name__ == "__main__":` is a manual harness.
        allowed = set()
        for node in tree.body:
            if isinstance(node, ast.If):
                for sub in ast.walk(node):
                    allowed.add(id(sub))

        for fn in ast.walk(tree):
            if not isinstance(fn, ast.FunctionDef) or fn.name == "download_torrent":
                continue
            for node in ast.walk(fn):
                if not (isinstance(node, ast.Call)
                        and isinstance(node.func, ast.Name)
                        and node.func.id == "print"
                        and id(node) not in allowed):
                    continue
                # `print(..., file=sys.stderr)` is the correct way to report a
                # diagnostic -- it lands in the app log, not the result stream.
                redirected = any(kw.arg == "file" for kw in node.keywords)
                if not redirected:
                    problems.append(
                        f"{name}.{fn.name}() line {node.lineno}: print() to the "
                        "result stream")

    if problems:
        return "fail", "; ".join(problems)
    return "pass", (f"all {len(_plugin_files())} engines emit only via "
                    "prettyPrinter")


@test("The anti-block fallback does not depend on the Web Remote toggle", "Torrents")
def scrape_endpoint_is_always_reachable():
    """The wall fallback was off by default, behind an unrelated switch.

    nova2 engines reach Opal's anti-detect browser over HTTP because they are a
    child process. Hanging that on `remote.start()` tied it to Settings › Web
    Remote — off by default — so the fallback that gets `1337x` and `uindex` off
    zero was itself off by default, and the only way to enable it was to also
    expose the whole JSON API to the LAN. Two unrelated things behind one switch.

    `startLocal()` is a second listener bound to 127.0.0.1 only, always running,
    serving exactly one route. It must NOT reuse handleApi: this one exists
    whether or not the user opted in, so its surface stays one route, and it
    still requires the same bearer token.
    """
    rm = _src("src/services/remote.zig")
    mn = _src("src/main.zig")
    hp = _src("engines/helpers.py")

    checks = {
        "local listener exists": "pub fn startLocal(" in rm,
        "binds loopback only": 'parseIp4("127.0.0.1", local_port)' in rm,
        "started unconditionally at init": "startLocal();" in mn,
        # Not gated on the toggle the way remote.start() is.
        "not behind web_remote": "web_remote_enabled) @import(\"services/remote.zig\").startLocal"
                                 not in mn,
        "serves only /api/scrape": 'if (!std.mem.eql(u8, path, "/api/scrape"))' in rm,
        "still requires the token": "isAuthorized(presented)" in rm.split("fn handleLocalRequest")[1],
        "does not reuse handleApi": "handleApi(" not in rm.split("fn handleLocalRequest")[1].split("\n}")[0],
        # Client prefers the always-on port, falls back to the opt-in one.
        "client tries loopback port first": "OPAL_SCRAPE_PORT" in hp and
                                            hp.index("OPAL_SCRAPE_PORT") < hp.index("OPAL_REMOTE_PORT"),
        "client has both ports": "41596" in hp and "41595" in hp,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "scrape listener wiring incomplete: " + ", ".join(missing)
    return "pass", ("loopback-only /api/scrape runs regardless of Web Remote; "
                    "client prefers 41596 and falls back to 41595")


@test("The stall watchdog runs off the UI thread", "Torrents")
def stall_watchdog_is_not_frame_driven():
    """A watchdog gated on the window being drawn cannot rescue anything.

    `tick()` was called from appFrame, and dvui only runs a frame when the window
    has events. Measured 2026-08-01: a torrent pinned at 0 bytes for over two
    minutes, far past the 20s threshold, produced no watchdog activity at all
    while the window sat in the background — the sampler was simply not running.

    It now owns a thread. Two consequences the code has to respect: the toast can
    no longer be raised inline (state.showToastTyped writes the shared toast
    buffer with no lock), and the thread must be joined before the torrent
    session it samples is torn down.
    """
    ts = _src("src/services/torrent_stall.zig")
    mn = _src("src/main.zig")

    checks = {
        "has its own thread": "std.Thread.spawn(.{}, loop" in ts,
        "started at init": "torrent_stall.zig\").start();" in mn,
        "joined at shutdown": "torrent_stall.zig\").stop();" in mn,
        "stop joins the thread": "t.join();" in ts,
        # tick() must no longer be driven from the frame path.
        "frame no longer drives tick": "torrent_stall.zig\").tick();" not in mn,
        # Toast is handed to the UI thread, not written from the worker.
        "toast queued not raised": "queueToast(" in ts,
        "toast drained on UI thread": "drainToast()" in mn,
        "queue is lock-guarded": "toast_lock.lock();" in ts,
        "worker does not call showToast directly":
            "state.showToastTyped" not in ts.split("fn tick()")[1].split("fn report(")[0],
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "stall watchdog threading incomplete: " + ", ".join(missing)
    return "pass", ("watchdog samples on its own thread, joined at shutdown; "
                    "toast handed to the UI thread under a lock")


@test("nova2 engine catalog: every engine fetches through helpers", "Torrents")
def engines_do_not_hand_roll_their_own_fetch():
    """A private urlopen opts an engine out of every hardening there is.

    `helpers.retrieve_url` is the one choke point that carries the retry, the
    per-attempt socket deadline and the anti-block browser fallback. EIGHT
    engines had their own `urllib.request.urlopen` and so got none of it --
    including `one337x` and `uindex`, the exact two the browser fallback was
    built for. Every improvement to retrieve_url had been silently bypassed by
    the engines that needed it most.

    `eztv` was the sharpest case: its direct call sat in an `except TypeError`
    branch guarding against "older versions of retrieve_url did not support
    request_data", which ours has supported for years -- dead code that would
    have dropped to an unhardened fetch if it ever fired.
    """
    problems = []
    for name in _plugin_files():
        if name in QUARANTINE:
            continue
        src = open(os.path.join(ENGINES_DIR, name + ".py"),
                   encoding="utf-8", errors="replace").read()
        for m in _re.finditer(r"^(?!\s*#).*\burlopen\s*\(", src, _re.M):
            line = src[:m.start()].count("\n") + 1
            problems.append(f"{name}.py:{line} calls urlopen directly")
    if problems:
        return "fail", ("engines must fetch through helpers.retrieve_url: "
                        + "; ".join(problems))
    return "pass", (f"all {len(_plugin_files())} engines fetch through "
                    "helpers.retrieve_url — one choke point, no bypasses")


@test("one337x/uindex: the parsers match the markup the sites actually serve", "Torrents")
def walled_engine_parsers_match_real_markup():
    """Both engines were zero for two stacked reasons, not one.

    Getting past the bot wall exposed the second: their selectors no longer
    matched. Fixtures below are the real markup, taken from pages fetched
    through the anti-detect browser on 2026-08-01.

    - 1337x serves `class="coll-1 name"`. The parser required an exact
      `class="name"`, so every row was skipped on a page holding 20 good ones.
    - uindex serves `<a href="magnet:..." ... class="sr-magnet">` -- href FIRST.
      The parser required `class="sr-magnet"` then `href=`, so it matched none
      of 100 magnets. Its NAME pattern survived only because uindex happens to
      put class before title on that other tag, so the engine found every name
      and no link, and reported nothing.

    Attribute order and class-list position are not part of any contract; both
    patterns must be written so a reordering cannot silently zero the engine.
    """
    sys.path.insert(0, ENGINES_DIR)
    sys.path.insert(0, os.path.join(PROJECT_DIR, "engines"))
    import re as _re2

    row_1337x = (
        '<td class="coll-1 name" style="padding-right: 61px;">'
        '<a href="/sub/42/0/" class="icon"><i class="flaticon-hd"></i></a>'
        '<a href="/torrent/5093050/The-Matrix-4-Resurrections-2021-1080p-WEBRip-x264/">'
        'The.Matrix.4.Resurrections.2021.1080p.WEBRip.x264</a></td>'
        '<td class="coll-2 seeds">8688</td><td class="coll-3 leeches">957</td>'
        '<td class="coll-date">Dec. 22nd \'21</td>'
        '<td class="coll-4 size mob-user">2.8 GB<span class="seeds">8688</span></td>'
    )
    uindex_tags = (
        '<a href="magnet:?xt=urn:btih:B6C82DE149515B6000D1424044BD676724883F33'
        '&dn=Matrix%20Revolutions" class="sr-magnet">M</a>'
        '<a href="/details.php?id=25085251" class="sr-torrent-link" '
        'title="Matrix Revolutions (2003) WEBRip 1080p">x</a>'
    )

    problems = []
    try:
        import one337x as m1
    except Exception as exc:  # pragma: no cover
        return "skip", f"cannot import one337x: {exc}"

    src1 = open(os.path.join(ENGINES_DIR, "one337x.py"), encoding="utf-8").read()
    pat1 = _re2.search(r"name_m = re\.search\(r'([^']+)'", src1)
    if not pat1:
        problems.append("one337x: no name_m pattern found")
    elif not _re2.search(pat1.group(1), row_1337x, _re2.DOTALL):
        problems.append("one337x: name pattern misses class=\"coll-1 name\"")

    src2 = open(os.path.join(ENGINES_DIR, "uindex.py"), encoding="utf-8").read()
    # Comments quote the OLD broken pattern to explain the bug, so scan code only.
    code2 = "\n".join(l for l in src2.splitlines() if not l.lstrip().startswith("#"))
    if 'class="sr-magnet"\\s+href=' in code2:
        problems.append("uindex: magnet pattern is order-dependent again")
    found = []
    for tag in _re2.findall(r'<a\b[^>]*>', uindex_tags):
        if 'sr-magnet' not in tag:
            continue
        h = _re2.search(r'href="(magnet:\?xt=urn:btih:[^"]+)"', tag)
        if h:
            found.append(h.group(1))
    if len(found) != 1:
        problems.append(f"uindex: href-first magnet tag not matched ({found})")

    # Neither engine may go back to a private fetch.
    for n, s in (("one337x", src1), ("uindex", src2)):
        if "retrieve_url" not in s:
            problems.append(f"{n}: no longer routes through helpers")

    if problems:
        return "fail", "; ".join(problems)
    return "pass", ("both parsers match the markup the sites really serve "
                    "(class lists, href-before-class), and both fetch via helpers")


@test("nova2 spawn: the torrent search has a deadline of its own", "Torrents")
def resolve_torrents_has_a_watchdog():
    """The search could hang forever waiting on nova2, and did.

    `resolveTorrentsNova2` drains nova2's stdout to EOF and then `wait()`s, with
    no deadline anywhere. Before `helpers._FETCH_TIMEOUT` existed, a host that
    completed the handshake and then went silent held urlopen() open with no
    bound, so nova2 never exited, the drain loop never returned, and
    `status_torrent` never left `.searching` — the search simply never finished.

    Two properties matter, and both are structural rather than something a unit
    test can drive (this is a GUI/thread path — see CLAUDE.md's rule 3):

    1. The deadline must live on a SEPARATE thread. The read loop blocks inside
       takeDelimiter() waiting for a line that never arrives, so an in-loop
       elapsed-time check could never fire on the one case it exists for.
    2. It must signal by pid via terminateProcess (SIGTERM, no reap) rather than
       child.kill(). nova2 runs a multiprocessing pool; reaping it out from under
       the reader is what left workers writing into a dead pipe, spewing
       BrokenPipeError and leaking semaphores. The drain-then-wait() must still be
       the thing that observes the exit.
    """
    rv = open(os.path.join(PROJECT_DIR, "src/services/resolver.zig"),
              encoding="utf-8").read()
    block = rv[rv.index("fn resolveTorrentsNova2("):]
    block = block[:block.index("\nfn ", 10)]

    checks = {
        "watchdog exists": "Watchdog" in block,
        "runs on its own thread": "std.Thread.spawn(.{}, Watchdog.run" in block,
        # pid by value, not a pointer into the frame (CLAUDE.md thread rules).
        "signals by pid": "io_glob.terminateProcess(self.pid)" in block,
        "pid copied by value": "pid: io_glob.Child.Id" in block,
        # Must NOT reap the child itself — wait() below still owns that.
        "does not kill/reap": "child.kill()" not in block,
        "still drains then waits": "_ = child.wait() catch {};" in block,
        # Joined before the frame dies, or `&watchdog` dangles.
        "joined before return": "t.join();" in block,
        "has a stop flag": "watchdog.done.store(true, .release)" in block,
        # Why a thread and not an in-loop check — the trap this replaced.
        "explains the blocking read": "takeDelimiter" in block and "in-loop" in block,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "nova2 watchdog incomplete: " + ", ".join(missing)

    deadline = _re.search(r"\.deadline_ms = (\d+)\s*\*\s*1000", block)
    if not deadline:
        return "fail", "no deadline_ms literal — cannot tell what the bound is"
    secs = int(deadline.group(1))
    # Must exceed the bounded Python worst case (_FETCH_TIMEOUT * attempts +
    # backoff, ~46s) or it would fire on merely-slow searches, and stay finite.
    if not 60 <= secs <= 600:
        return "fail", (f"deadline is {secs}s — must clear the ~46s bounded Python "
                        "worst case without being effectively infinite")
    return "pass", (f"nova2 bounded at {secs}s by a separate watchdog thread that "
                    "SIGTERMs by pid; drain-then-wait still reaps")


@test("nova2 fetch: a bot wall falls back to the anti-detect browser", "Torrents")
def retrieve_url_routes_walls_to_the_browser():
    """A 403 is not retryable, so walled engines sat at a permanent zero.

    Measured 2026-07-30: `1337x.to` answered 403 to 7 of 10 requests, and
    `uindex` serves a Cloudflare interstitial on /search.php while its homepage
    returns 200. `_is_retryable` is right to refuse both — a bot wall is the
    server's considered answer — but that left no path at all for those engines.

    Opal already defeats exactly this for its Zig scrapers in
    `src/services/scrape_fetch.zig` (plain curl, then the anti-detect browser
    when the response is an interstitial). nova2 runs in a child process and
    cannot call it, so `GET /api/scrape` exposes it and `retrieve_url` falls back
    there. Two shapes must both route: a 403/503 status, and — the one that fails
    silently — a challenge page served under 200 OK, which an engine otherwise
    parses into zero rows on a fetch that looked like it worked.
    """
    sys.path.insert(0, os.path.join(PROJECT_DIR, "engines"))
    try:
        import helpers
        import urllib.error
    except Exception as exc:  # pragma: no cover
        return "skip", f"cannot import helpers: {exc}"

    for sym in ("_looks_walled", "_opal_scrape", "_opal_api_token"):
        if not hasattr(helpers, sym):
            return "fail", f"helpers.{sym} is gone; walled engines have no path"

    # Status walls, and the 200-interstitial bodies.
    if not helpers._looks_walled(403, ""):
        return "fail", "403 must be treated as a wall"
    if not helpers._looks_walled(503, ""):
        return "fail", "503 must be treated as a wall"
    for body in ("<title>Just a moment...</title>",
                 "Checking your browser before accessing",
                 "<div id='cf-browser-verification'>",
                 "Enable JavaScript and cookies to continue"):
        if not helpers._looks_walled(0, body):
            return "fail", f"challenge body not detected: {body!r}"
    # And the false positives that must NOT burn ~45s of browser time.
    if helpers._looks_walled(200, "<html>real rows</html>"):
        return "fail", "a normal 200 page was called a wall"
    if helpers._looks_walled(0, ""):
        return "fail", "an empty body is a dead host, not a wall"
    if helpers._looks_walled(429, ""):
        return "fail", ("429 is transient and _is_retryable already handles it — "
                        "sending it to the browser wastes ~45s on a 0.7s problem")

    # A 403 must reach _opal_scrape exactly once, and its body must be returned.
    calls = {"scrape": 0, "open": 0}

    def _walled(_req, **_kw):
        calls["open"] += 1
        raise urllib.error.HTTPError("u", 403, "Forbidden", {}, None)  # type: ignore[arg-type]

    def _fake_scrape(_url, post_body=None):
        calls["scrape"] += 1
        return "<html>unblocked rows</html>"

    real_open, real_sleep = helpers.urllib.request.urlopen, helpers.time.sleep
    real_scrape = helpers._opal_scrape
    helpers.urllib.request.urlopen = _walled
    helpers.time.sleep = lambda _s: None
    helpers._opal_scrape = _fake_scrape
    try:
        body = helpers.retrieve_url("https://walled.invalid/search")
        if "unblocked rows" not in body:
            return "fail", f"403 did not fall back to the browser (got {body!r})"
        if calls["scrape"] != 1:
            return "fail", f"expected 1 browser attempt, made {calls['scrape']}"
        if calls["open"] != 1:
            return "fail", f"403 was retried {calls['open']}x; a wall must not retry"

        # A dead host must NOT spend browser time.
        calls["scrape"] = 0
        def _dead(_req, **_kw):
            raise urllib.error.URLError(OSError("reset"))
        helpers.urllib.request.urlopen = _dead
        helpers.retrieve_url("https://dead.invalid/", attempts=2)
        if calls["scrape"] != 0:
            return "fail", "a connection reset went to the browser; only walls should"
    finally:
        helpers.urllib.request.urlopen = real_open
        helpers.time.sleep = real_sleep
        helpers._opal_scrape = real_scrape

    # A walled POST must be replayed as a POST, never downgraded to a GET.
    # EZTV gates its magnet links behind `layout=def_wlinks`; an unblocked GET
    # returns the rows and none of the links, which looks like success.
    if helpers._as_post_body(None) is not None:
        return "fail", "a GET must not be turned into a POST"
    if helpers._as_post_body(b"layout=def_wlinks") != b"layout=def_wlinks":
        return "fail", "a bytes body must survive the unblock path"
    if helpers._as_post_body("layout=def_wlinks") != b"layout=def_wlinks":
        return "fail", "a str body must be encoded, not dropped"

    seen_body = {}

    def _walled2(_req, **_kw):
        raise urllib.error.HTTPError("u", 403, "Forbidden", {}, None)  # type: ignore[arg-type]

    def _scrape_capture(_url, post_body=None):
        seen_body["b"] = post_body
        return "<html>unblocked</html>"

    helpers.urllib.request.urlopen = _walled2
    helpers.time.sleep = lambda _s: None
    helpers._opal_scrape = _scrape_capture
    try:
        helpers.retrieve_url("https://walled.invalid/s", request_data=b"layout=def_wlinks")
        if seen_body.get("b") != b"layout=def_wlinks":
            return "fail", f"POST body not forwarded to the unblock path ({seen_body})"
        seen_body.clear()
        helpers.retrieve_url("https://walled.invalid/s")
        if seen_body.get("b") is not None:
            return "fail", "a GET was sent to the unblock path with a body"
    finally:
        helpers.urllib.request.urlopen = real_open
        helpers.time.sleep = real_sleep
        helpers._opal_scrape = real_scrape

    # The server half must exist, and must not hold the API mutex while it blocks.
    rm = open(os.path.join(PROJECT_DIR, "src/services/remote.zig"),
              encoding="utf-8").read()
    if '"/api/scrape"' not in rm or "fn handleScrape(" not in rm:
        return "fail", "remote.zig exposes no /api/scrape for the engines to call"
    if "sf.scrapeFetch(url, buf)" not in rm:
        return "fail", "handleScrape does not route through scrape_fetch"
    # POST support all the way down: endpoint -> scrape_fetch -> browser bridge.
    for sym, where in (("scrapeFetchPost(url, p, buf)", "remote.zig"),
                       ("fetchHtmlPostBlocking", "scrape_fetch.zig")):
        src = rm if where == "remote.zig" else open(
            os.path.join(PROJECT_DIR, "src/services/scrape_fetch.zig"), encoding="utf-8").read()
        if sym not in src:
            return "fail", f"{where} lacks the POST path ({sym})"
    bridge = open(os.path.join(PROJECT_DIR, "scripts/camoufox_bridge.py"),
                  encoding="utf-8").read()
    if '"fetchpost"' not in bridge:
        return "fail", "camoufox_bridge.py has no fetchpost action"
    # The POST must happen AFTER the challenge clears, or it just re-hits the
    # interstitial with no cookies.
    if bridge.index("wait_for_challenge_clear(sp, wait_ms)\n                text = sp.evaluate") < 0:
        return "fail", "fetchpost posts before clearing the challenge"
    # Ordering: the route must be handled BEFORE the api_mutex block, or a 45s
    # browser fetch freezes every other endpoint including playback control.
    if rm.index('"/api/scrape"') > rm.index("api_mutex.lock();\n        defer api_mutex.unlock();\n        handleApi"):
        return "fail", ("/api/scrape is dispatched under api_mutex — a 45s browser "
                        "fetch would freeze the whole API")
    return "pass", ("403/503 and 200-interstitials fall back to /api/scrape once; "
                    "resets and 429 do not; route is off the api_mutex")


@test("nova2 fetch: every attempt carries a socket deadline", "Torrents")
def retrieve_url_bounds_every_attempt():
    """An unanswered fetch used to hang the whole torrent search forever.

    `urlopen()` with no `timeout=` uses the global default socket timeout, which
    is None, and nothing in nova2 calls `socket.setdefaulttimeout`. A host that
    completes the TCP handshake and then never answers therefore blocks its
    engine thread indefinitely -- and `resolver.zig::resolveTorrents` drains
    nova2's stdout to EOF then `wait()`s with no deadline of its own, so one such
    host holds the entire search open. Measured: a single retrieve_url call to
    `ilcorsaronero.link` ran past 20 minutes from this network.

    The deadline must be PER ATTEMPT, not per call: the retry loop added in 1.57
    multiplied an unbounded wait by `attempts`.
    """
    sys.path.insert(0, os.path.join(PROJECT_DIR, "engines"))
    try:
        import helpers
        import urllib.error
    except Exception as exc:  # pragma: no cover
        return "skip", f"cannot import helpers: {exc}"

    if not isinstance(getattr(helpers, "_FETCH_TIMEOUT", None), (int, float)):
        return "fail", "helpers._FETCH_TIMEOUT is gone; fetches are unbounded again"
    if not 0 < helpers._FETCH_TIMEOUT <= 30:
        return "fail", (f"_FETCH_TIMEOUT={helpers._FETCH_TIMEOUT} is not a usable "
                        "deadline (want 0 < t <= 30)")

    seen = []

    class _Resp:
        def read(self):
            return b"<html>ok</html>"

        def getheader(self, _name, _default=""):
            return "text/html"

    def _record(_req, **kw):
        seen.append(kw.get("timeout", "MISSING"))
        # Fail the first two so the retry path is the one under test.
        if len(seen) < 3:
            raise urllib.error.URLError(OSError("reset"))
        return _Resp()

    real_open, real_sleep = helpers.urllib.request.urlopen, helpers.time.sleep
    helpers.urllib.request.urlopen = _record
    helpers.time.sleep = lambda _s: None
    try:
        helpers.retrieve_url("https://example.invalid/")
    finally:
        helpers.urllib.request.urlopen = real_open
        helpers.time.sleep = real_sleep

    # download_file() shares the defect and the fix; catch a bare call there too.
    src = open(os.path.join(PROJECT_DIR, "engines", "helpers.py"),
               encoding="utf-8").read()
    # At least one argument, and no timeout= among them. Bare `urlopen()` in
    # prose does not match.
    bare = _re.findall(r"urlopen\((?![^)]*timeout=)[^)]+\)", src)
    if bare:
        return "fail", f"urlopen call with no timeout= remains: {bare}"

    if not seen:
        return "fail", "retrieve_url made no request at all"
    unbounded = [i for i, t in enumerate(seen) if t == "MISSING" or t is None]
    if unbounded:
        return "fail", (f"attempt(s) {unbounded} of {len(seen)} passed no timeout to "
                        "urlopen -- a hung host blocks the search forever")
    return "pass", (f"all {len(seen)} attempts bounded at "
                    f"{helpers._FETCH_TIMEOUT}s each")


@test("nova2 fetch: transient failures retry, 4xx does not", "Torrents")
def retrieve_url_retries_transient_failures():
    """A single reset used to zero a whole search.

    helpers.retrieve_url made exactly one attempt and returned "" on any
    URLError. Several torrent hosts answer only intermittently from a given
    network -- eztvx.to was measured returning 200 on the third try, 000 on the
    first two -- so every engine reported zero rows for a site that was up. A
    4xx must NOT be retried: 403 from a bot wall and 404 for a dead path are
    the server's considered answer, and retrying only burns time.
    """
    sys.path.insert(0, os.path.join(PROJECT_DIR, "engines"))
    try:
        import helpers
        import urllib.error
    except Exception as exc:  # pragma: no cover
        return "skip", f"cannot import helpers: {exc}"

    if not hasattr(helpers, "_is_retryable"):
        return "fail", "helpers._is_retryable is gone; retry policy lost"

    reset = urllib.error.URLError(OSError("Connection reset by peer"))
    if not helpers._is_retryable(reset):
        return "fail", "a connection reset must be retryable"
    for code in (400, 403, 404):
        err = urllib.error.HTTPError("u", code, "m", {}, None)  # type: ignore[arg-type]
        if helpers._is_retryable(err):
            return "fail", f"HTTP {code} must not be retried"
    for code in (429, 500, 503):
        err = urllib.error.HTTPError("u", code, "m", {}, None)  # type: ignore[arg-type]
        if not helpers._is_retryable(err):
            return "fail", f"HTTP {code} should be retried"

    # A host that fails twice then answers must yield its body, not "".
    calls = {"n": 0}

    class _Resp:
        def read(self):
            return b"<html>ok</html>"

        def getheader(self, _name, _default=""):
            return "text/html"

    def _flaky(_req, **_kw):
        calls["n"] += 1
        if calls["n"] < 3:
            raise urllib.error.URLError(OSError("reset"))
        return _Resp()

    real_open, real_sleep = helpers.urllib.request.urlopen, helpers.time.sleep
    helpers.urllib.request.urlopen = _flaky
    helpers.time.sleep = lambda _s: None
    try:
        body = helpers.retrieve_url("https://example.invalid/")
        if "ok" not in body:
            return "fail", f"3rd-attempt success not returned (got {body!r})"
        if calls["n"] != 3:
            return "fail", f"expected 3 attempts, made {calls['n']}"
        # attempts=1 must not retry -- therarbg's per-row fetch relies on this.
        calls["n"] = 0
        helpers.retrieve_url("https://example.invalid/", attempts=1)
        if calls["n"] != 1:
            return "fail", f"attempts=1 made {calls['n']} attempts"
    finally:
        helpers.urllib.request.urlopen = real_open
        helpers.time.sleep = real_sleep
    return "pass", "retries transient failures 3x, honours attempts=1, skips 4xx"


@test("academictorrents: a multi-word query means ALL the words", "Torrents")
def academictorrents_and_filter():
    """Found by using the app: 25 of 48 rows were noise.

    Searching "Spider-Man: Brand New Day" in the web UI returned Crossref data
    files, MIT lecture videos and Wikipedia dumps from academictorrents. The
    filter was an OR — one matching term was enough — and academic dataset
    descriptions are long prose, so common words like "new" and "day" appear
    somewhere in nearly every item and carried the entire catalogue.

    Also pins the empty-term case: `"" in title` is always True, so a query with
    a trailing or doubled space matched EVERY item even after switching to AND.
    """
    sys.path.insert(0, ENGINES_DIR)
    sys.path.insert(0, os.path.join(PROJECT_DIR, "engines"))
    try:
        import academictorrents as m
    except Exception as exc:  # pragma: no cover
        return "skip", f"cannot import academictorrents: {exc}"

    import xml.etree.ElementTree as ET

    def item(title, desc):
        e = ET.Element("item")
        ET.SubElement(e, "title").text = title
        ET.SubElement(e, "description").text = desc
        return e

    eng = m.academictorrents(output=False)
    # The exact row that leaked: matches "new"/"day" in prose, nothing else.
    noise = item("March 2026 Public Data File from Crossref",
                 "A new public data file released this day for research use.")
    real = item("Spider-Man Brand New Day 2026 1080p",
                "brand new day movie release")

    eng.filters = ["spider-man", "brand", "new", "day"]
    if eng._torrent_filter(noise):
        return "fail", ("OR filter is back: an unrelated dataset matched a "
                        "multi-word query on common words alone")
    if not eng._torrent_filter(real):
        return "fail", "AND filter rejected an item containing every term"

    # A single term still works — this is not an accidental exact-match filter.
    eng.filters = ["crossref"]
    if not eng._torrent_filter(noise):
        return "fail", "single-term search stopped matching"

    # Empty terms must not match everything.
    eng.filters = ["", ""]
    if eng._torrent_filter(noise):
        return "fail", 'empty query terms matched (`"" in title` is always True)'
    eng.filters = ["crossref", ""]
    if not eng._torrent_filter(noise):
        return "fail", "a stray empty term broke an otherwise valid query"

    # Missing title/description must not raise.
    bare = ET.Element("item")
    eng.filters = ["anything"]
    try:
        eng._torrent_filter(bare)
    except Exception as exc:
        return "fail", f"item with no title/description raised: {exc!r}"
    return "pass", "all terms required; empty terms dropped; single-term search intact"


@test("torrents: adding before the engine is up says so", "Torrents")
def test_torrent_session_not_ready_is_reported():
    # The session is built on a background thread at startup — the comment in
    # main.zig says DHT bootstrap takes 5-10s. Inside that window
    # torrent_add_magnet gets a NULL session, returns -1, and the -1 branch
    # reported "invalid or duplicate magnet". Observed 2026-08-04: a magnet
    # posted to /api/load right after launch vanished with no torrent and no
    # error, and re-posting the identical link seconds later worked. The message
    # sent you off checking a link that was never the problem.
    src = _src("src/services/search.zig")
    guards = src.count("if (state.torrentSession() == null) {")
    if guards < 2:
        return "fail", (f"only {guards} of the 2 add paths (magnet, .torrent) check for a "
                        "session — the other still reports a good link as invalid")
    if "still starting" not in src:
        return "fail", "the not-ready case has no user-facing message"
    return "pass", "both add paths report a not-yet-ready engine instead of blaming the link"
