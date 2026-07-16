"""Opt-in SFW manga source catalog tests.
See tests/features/harness.py for the shared @test decorator + helpers.

`manga-sources-sfw.json` is a CATALOG (curated {name,base,framework,lang} for
Madara/MangaThemesia/HeanCms sites classified from the keiyoushi index), NOT an
auto-loaded source list — consistent with Opal's source-neutral design (the binary
ships no scraper URL; a source only goes live when the user installs it, which
writes source_config). This test asserts: the catalog file exists + is valid JSON;
every entry has framework ∈ {madara,mangathemesia,heancms}, an http(s) base, a
name and a lang; no entry carries an obvious NSFW token; and the opt-in install
path exists and routes through source_config.install (plugin_repo.installMangaSource
+ the remote /source/catalog and /source/add endpoints)."""
import json
import os
from .harness import *  # noqa: F401,F403

_FRAMEWORKS = {"madara", "mangathemesia", "heancms"}
_NSFW_TOKENS = ("hentai", "xxx", "r18", "18+", "porn", "nsfw")


@test("SFW manga source catalog", "Integration")
def test_manga_source_catalog():
    problems = []

    # 1) Catalog file exists at the project root (bundled into Resources by
    #    scripts/build-app.sh alongside plugins-manifest.json).
    path = os.path.join(PROJECT_DIR, "manga-sources-sfw.json")
    if not os.path.exists(path):
        return "fail", "manga-sources-sfw.json missing from project root"

    # 2) Valid JSON array.
    try:
        catalog = json.load(open(path, encoding="utf-8"))
    except Exception as e:
        return "fail", f"catalog not valid JSON: {e}"
    if not isinstance(catalog, list) or not catalog:
        return "fail", "catalog is not a non-empty JSON array"

    # 3) Every entry: framework in the whitelist, http(s) base, name + lang,
    #    and no obvious NSFW token (belt-and-suspenders SFW guard).
    per_fw = {}
    for e in catalog:
        fw = e.get("framework", "")
        base = e.get("base", "")
        name = e.get("name", "")
        lang = e.get("lang", "")
        if fw not in _FRAMEWORKS:
            problems.append(f"bad framework {fw!r} for {name!r}")
        else:
            per_fw[fw] = per_fw.get(fw, 0) + 1
        if not (base.startswith("https://") or base.startswith("http://")):
            problems.append(f"non-http base for {name!r}: {base!r}")
        if not name or not lang:
            problems.append(f"missing name/lang for entry {e!r}")
        blob = (name + " " + base).lower()
        if any(tok in blob for tok in _NSFW_TOKENS):
            problems.append(f"NSFW token in SFW catalog entry: {name!r} {base!r}")
        if len(problems) > 8:
            break

    # 4) Opt-in install path: plugin_repo exposes installMangaSource, which routes
    #    through source_config.install (the same neutral write the extension uses),
    #    and only accepts the three framework engines.
    repo = _src("src/services/plugin_repo.zig")
    if "pub fn installMangaSource" not in repo:
        problems.append("plugin_repo.installMangaSource install path missing")
    if "source_config.install(framework" not in repo:
        problems.append("installMangaSource does not route through source_config.install")
    if "pub fn isMangaFramework" not in repo or "pub fn readMangaCatalog" not in repo:
        problems.append("plugin_repo missing isMangaFramework/readMangaCatalog helpers")

    # 5) Remote API exposes the catalog (GET /source/catalog) + install path
    #    reuses the existing /source/add (which calls source_config.install).
    remote = _src("src/services/remote.zig")
    if '"/source/catalog"' not in remote or "readMangaCatalog()" not in remote:
        problems.append("remote /source/catalog endpoint missing")
    if '"/source/add"' not in remote or "source_config.zig\").install(framework" not in remote:
        problems.append("remote /source/add install (source_config.install) missing")

    if problems:
        return "fail", "; ".join(problems)
    tally = ", ".join(f"{k}={per_fw.get(k,0)}" for k in sorted(_FRAMEWORKS))
    return ("pass", f"{len(catalog)} SFW sources ({tally}); opt-in via "
            "installMangaSource + /source/catalog, all route through source_config.install")
