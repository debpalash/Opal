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
