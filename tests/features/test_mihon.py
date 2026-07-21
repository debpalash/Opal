"""Mihon / Tachiyomi extension-repo support + ingest.

Layered on the Suwayomi engine: a pure module owns the curated repo table, the
index.min.json parser (extension/source ingest) and the Suwayomi
`/api/v1/extension/*` URL builders (list/install/uninstall/icon). It is
re-exported by manga_suwayomi_pure as `repo` so it joins the app module graph
through comics.zig's existing import.

Verify: tested pure module present + registered + re-exported (tested logic ==
shipped logic), the security gates + endpoint builders + index parser exist, and
the bundled manifest carries the curated Mihon repo URLs.

See tests/features/harness.py for the shared @test decorator."""
from .harness import *  # noqa: F401,F403

import json
import os


@test("Mihon extension repos + ingest", "Integration")
def test_mihon():
    pure = _src("src/services/mihon_repo_pure.zig")
    suwa = _src("src/services/manga_suwayomi_pure.zig")
    build = _src("build.zig")

    checks = {
        # ── Pure module: curated repos + gates + endpoint builders + parser ──
        "pure module present": bool(pure),
        "curated repo table": "pub const REPOS" in pure
            and "keiyoushi/extensions/repo/index.min.json" in pure,
        "index file const": 'INDEX_FILE = "index.min.json"' in pure,
        "security gates": "pub fn isValidBase" in pure and "pub fn isPkgName" in pure
            and "pub fn isApkName" in pure,
        "repo url normalize": "pub fn normalizeRepoIndexUrl" in pure
            and "pub fn isValidIndexUrl" in pure,
        # Suwayomi /api/v1/extension/* endpoints (shipped requests are these tested strings).
        "extension endpoint builders": all(
            f"pub fn {fn}" in pure for fn in (
                "buildExtensionListUrl", "buildInstallUrl", "buildUninstallUrl",
                "buildUpdateUrl", "buildIconUrl",
            )
        ),
        "rest extension paths": "/api/v1/extension/list" in pure
            and "/api/v1/extension/install/" in pure
            and "/api/v1/extension/icon/" in pure,
        # index.min.json ingest (extension/source catalog).
        "index parser": "pub const ExtIter" in pure and "pub fn parseExtension" in pure,
        "extension row fields": "pub const Extension = struct" in pure
            and "source_count" in pure and "source_base" in pure,

        # ── Routed into the Suwayomi engine graph (tested == shipped) ──
        "re-exported by suwayomi": 'pub const repo = @import("mihon_repo_pure.zig")' in suwa,

        # ── Registered in the zig-build-test step ──
        "test registered": 'b.path("src/services/mihon_repo_pure.zig")' in build,

        # ── Installed-state readers (Suwayomi extension/list) ──
        "installed-state readers": "pub fn listObjInstalled" in pure
            and "pub fn listObjPkg" in pure,

        # ── Server-side repo registration (GraphQL) so installs resolve ──
        "graphql url + repo bodies": "pub fn buildGraphqlUrl" in pure
            and "pub fn buildSetReposBody" in pure
            and "GQL_FETCH_EXTENSIONS" in pure,
        "repo merge helpers": "pub fn extractRepos" in pure and "pub fn reposContain" in pure,
    }

    # ── Service + panel: fetch/install/render wired into the Comics tab ──
    svc = _src("src/services/mihon.zig")
    comics = _src("src/services/comics.zig")
    checks.update({
        "service present": bool(svc),
        "fetches + parses a repo": "fn worker(" in svc and "repo.ExtIter" in svc
            and "repo.parseExtension(" in svc,
        "install/uninstall drives server": "fn setInstalled(" in svc
            and "repo.buildInstallUrl(" in svc and "repo.buildUninstallUrl(" in svc,
        "marks installed from server list": "repo.buildExtensionListUrl(" in svc
            and "repo.listObjInstalled(" in svc,
        "inert without a suwayomi server": "fn suwayomiBase(" in svc
            and "repo.isValidBase(" in svc,
        # Adult extensions gated by the global NSFW setting, like Live TV.
        "adult gated by nsfw setting": "state.app.nsfw_filter_enabled" in svc,
        # Curated repo URL persisted so the panel reopens on the same repo.
        "persists last repo": 'source_config.install("mihon"' in svc,
        # Registers the loaded repo on the server so installs of its pkgs resolve.
        "registers repo on server": "fn registerRepoOnServer(" in svc
            and "repo.buildSetReposBody(" in svc and "registerRepoOnServer(url)" in svc,
        "thread guards use @This()": svc.count("const Self = @This();") >= 2,
        # Opened from the Comics toolbar; panel takes over the tab.
        "comics opens the panel": "mihon.open()" in comics and "mihon.renderPanel()" in comics,
        # Server managed on the Plugins page (base URL + Test connection).
        "server config on plugins page": "fn renderSuwayomi(" in _src("src/services/plugins.zig")
            and 'sc.install("suwayomi"' in _src("src/services/plugins.zig")
            and "extension/list" in _src("src/services/plugins.zig"),
        # Opal runs the server itself: download jar + launch headless + stop.
        "embedded server manager": bool(_src("src/services/suwayomi_server.zig"))
            and "pub fn startEmbedded(" in _src("src/services/suwayomi_server.zig")
            and "pub fn stopEmbedded(" in _src("src/services/suwayomi_server.zig")
            and "Suwayomi-Server-" in _src("src/services/suwayomi_server.zig"),
        # Tray/WebUI disabled via server.conf (the -D props are ignored; forcing
        # awt.headless=true NPE-crashes the tray). Plain `java -jar` launch, no
        # -D headless flag in the argv.
        "server.conf disables tray+cef, seeds repos": "fn writeServerConf(" in _src("src/services/suwayomi_server.zig")
            and "server.systemTrayEnabled = false" in _src("src/services/suwayomi_server.zig")
            and "server.kcefEnabled = false" in _src("src/services/suwayomi_server.zig")
            and "server.extensionStores = [" in _src("src/services/suwayomi_server.zig")
            and 'io.Child.init(&.{ "java", "-jar", jar }' in _src("src/services/suwayomi_server.zig")
            and '"-Djava.awt.headless=true"' not in _src("src/services/suwayomi_server.zig"),
        "plugins page has Start/Stop": '"Start server"' in _src("src/services/plugins.zig")
            and "srv.startEmbedded()" in _src("src/services/plugins.zig")
            and "srv.stopEmbedded()" in _src("src/services/plugins.zig"),
        "killed on app shutdown": "suwayomi_server.zig" in _src("src/main.zig")
            and ".stopEmbedded()" in _src("src/main.zig"),
        # Content bridge: an installed extension's source can be browsed — the
        # panel writes suwayomi/source + selects the Suwayomi source in Comics.
        "browse bridge in comics": "pub fn browseSuwayomiSource(" in comics
            and 'sc.install("suwayomi"' in comics,
        "suwayomi source chip": 'renderSourceChip("Suwayomi", 6, .suwayomi)' in comics,
        "panel has a Browse button": "browseSuwayomiSource(r.source_id" in svc
            and "source_id" in svc,
    })

    # ── Bundled manifest carries the curated Mihon repo entry ──
    mpath = os.path.join(PROJECT_DIR, "data", "plugins-manifest.json")
    manifest_ok = False
    try:
        man = json.load(open(mpath))
        for p in man.get("plugins", []):
            if p.get("id") == "mihon" and p.get("type") == "mihon-repos":
                repos = p.get("repos", [])
                manifest_ok = len(repos) >= 4 and all(
                    r.get("url", "").endswith("index.min.json") for r in repos
                )
                break
    except Exception:
        manifest_ok = False
    checks["manifest mihon entry"] = manifest_ok

    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "Mihon extensions wiring incomplete: " + ", ".join(missing)
    return "pass", "Mihon: pure(repos/gates/parse/endpoints) + service (fetch/install/render) opened from Comics; nsfw-gated"
