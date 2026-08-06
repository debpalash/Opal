"""Opal browser-extension (Opal Connector) integration test.

Validates the cross-browser MV3 extension under extension/ is wired correctly:
a valid MV3 manifest with the right permissions + localhost host_permissions, a
background service worker / content script / side panel / options declared, the
extension surfaced as a persistent SIDE PANEL (Chrome) / SIDEBAR (Firefox) rather
than a popup, the background worker targeting the real Opal endpoints (including
the new /api/source/add + /api/playpause) with a Bearer header, the content
script's manga/novel framework-detection heuristics, and the Zig side carrying
the /api/ingest + /api/source/add + /api/playpause handlers and source_config
install path it drives.

See tests/features/harness.py for the shared @test decorator + helpers."""
import json
import os

from .harness import *  # noqa: F401,F403


@test("Opal browser extension", "Integration")
def test_opal_browser_extension():
    problems = []
    ext_dir = os.path.join(PROJECT_DIR, "extension")

    # ── manifest.json: exists + valid JSON + MV3 shape ──
    manifest_path = os.path.join(ext_dir, "manifest.json")
    if not os.path.exists(manifest_path):
        return "fail", "extension/manifest.json missing"
    try:
        with open(manifest_path) as f:
            manifest = json.load(f)
    except Exception as e:
        return "fail", f"manifest.json is not valid JSON: {e}"

    if manifest.get("manifest_version") != 3:
        problems.append("manifest_version is not 3 (MV3 required)")

    perms = set(manifest.get("permissions", []))
    for need in ("contextMenus", "activeTab", "storage", "scripting", "notifications", "sidePanel"):
        if need not in perms:
            problems.append(f"permission '{need}' missing")

    host_perms = manifest.get("host_permissions", [])
    joined_hosts = " ".join(host_perms)
    if "127.0.0.1" not in joined_hosts or "localhost" not in joined_hosts:
        problems.append("host_permissions must cover 127.0.0.1 and localhost")

    # Background service worker declared (MV3).
    bg = manifest.get("background", {})
    if not bg.get("service_worker"):
        problems.append("background.service_worker not declared")

    # Content script declared.
    if not manifest.get("content_scripts"):
        problems.append("content_scripts not declared")

    # ── Surface: side panel (Chrome) + sidebar (Firefox), NOT a popup ──
    action = manifest.get("action", {})
    if action.get("default_popup"):
        problems.append("action.default_popup must be removed (side panel now)")
    side_panel = manifest.get("side_panel", {})
    if not side_panel.get("default_path"):
        problems.append("side_panel.default_path (Chrome side panel) not declared")
    sidebar = manifest.get("sidebar_action", {})
    if not sidebar.get("default_panel"):
        problems.append("sidebar_action.default_panel (Firefox sidebar) not declared")
    if not (manifest.get("options_ui") or manifest.get("options_page")):
        problems.append("options page not declared")

    # ── source files present ──
    for rel in (
        "src/background.ts",
        "src/content.ts",
        "src/sidepanel/index.html",
        "src/sidepanel/sidepanel.ts",
        "src/options/options.html",
    ):
        if not os.path.exists(os.path.join(ext_dir, rel)):
            problems.append(f"{rel} missing")

    # ── background worker targets the real endpoints + Bearer auth ──
    bg_path = os.path.join(ext_dir, "src/background.ts")
    bg_src = open(bg_path).read() if os.path.exists(bg_path) else ""
    for ep in ("/api/open", "/api/download/url", "/api/ingest", "/api/source/add", "/api/playpause"):
        if ep not in bg_src:
            problems.append(f"background.ts does not reference {ep}")
    if "Bearer" not in bg_src or "Authorization" not in bg_src:
        problems.append("background.ts missing Authorization: Bearer header")
    if "setPanelBehavior" not in bg_src:
        problems.append("background.ts does not open the side panel on action click")

    # ── content script: manga/novel framework-detection heuristics ──
    ct_path = os.path.join(ext_dir, "src/content.ts")
    ct_src = open(ct_path).read() if os.path.exists(ct_path) else ""
    if "detectFramework" not in ct_src:
        problems.append("content.ts missing detectFramework()")
    for marker in ("wp-manga", "readerarea", "series_slug", "epcontent", "chapter-content"):
        if marker not in ct_src:
            problems.append(f"content.ts missing framework marker '{marker}'")

    # ── Zig side: new endpoints + source_config install path ──
    remote = _src("src/services/remote.zig")
    if '"/ingest"' not in remote:
        problems.append("remote.zig missing the /api/ingest handler")
    if '"/source/add"' not in remote:
        problems.append("remote.zig missing the /api/source/add handler")
    if '"/playpause"' not in remote:
        problems.append("remote.zig missing the /api/playpause handler")
    # ingest routes the typed hint (queue vs play).
    if '"queue"' not in remote or '"manga"' not in remote:
        problems.append("remote.zig /api/ingest does not route the typed hints")

    src_cfg = _src("src/core/source_config.zig")
    if "pub fn install(" not in src_cfg:
        problems.append("source_config.zig missing an install() write path")

    if problems:
        return "fail", "; ".join(problems)
    return (
        "pass",
        "MV3 manifest valid (perms + sidePanel + localhost hosts; side_panel + "
        "sidebar_action, no popup); background.ts hits /api/open, /api/ingest, "
        "/api/source/add, /api/playpause with Bearer + opens the side panel; "
        "content.ts detects Madara/MangaThemesia/HeanCMS/LightNovelWP/ReadWN; "
        "remote.zig has /source/add + /playpause + typed ingest; source_config.install",
    )


@test("Opal Connect wears the real logo", "Integration")
def test_extension_branding():
    """The toolbar button had NO icon at all — `action` declared only a
    `default_title`, so Chrome drew its generic grey puzzle piece next to a
    panel whose header was the text glyph "◆". Neither is the logo; the mark
    (assets/opal-connect-logo.png, shipped as images/icon-*.png) was already in
    the repo and simply unused outside the install listing."""
    ext_dir = os.path.join(PROJECT_DIR, "extension")
    problems = []

    with open(os.path.join(ext_dir, "manifest.json")) as f:
        manifest = json.load(f)

    icons = manifest.get("icons", {})
    action_icon = manifest.get("action", {}).get("default_icon", {})
    # The bug, verbatim: a toolbar entry point with no icon.
    if not action_icon:
        problems.append("action.default_icon missing — the toolbar shows a generic puzzle piece")

    for size, rel in list(icons.items()) + list(action_icon.items()):
        if not os.path.exists(os.path.join(ext_dir, rel)):
            problems.append(f"icon {size} points at missing file {rel}")

    # The panel, the settings page and the injected in-page button must show the
    # mark, not a glyph. Comments are stripped first — the code says WHY the
    # glyph is gone, and a test that greps prose tests nothing.
    import re as _re
    def _code(text):
        return _re.sub(r"<!--.*?-->", "", text, flags=_re.S)

    for rel in ("src/sidepanel/index.html", "src/options/options.html"):
        html = _code(open(os.path.join(ext_dir, rel)).read())
        if 'class="logo"' in html and "<img" not in html:
            problems.append(f"{rel} still renders the logo as text, not the image")
        if "◆" in html:
            problems.append(f"{rel} still contains the ◆ placeholder glyph")

    content = open(os.path.join(ext_dir, "src/content.ts")).read()
    code = "\n".join(l for l in content.splitlines() if not l.lstrip().startswith("//"))
    if "◆" in code:
        problems.append("content.ts floating button still labels itself with ◆")
    if "getURL(" not in code:
        problems.append("content.ts does not load the icon as a runtime resource")
    # getURL only resolves in a page if the file is web-accessible.
    war = " ".join(
        r for entry in manifest.get("web_accessible_resources", []) for r in entry.get("resources", [])
    )
    if "images" not in war:
        problems.append("images are not web_accessible_resources — the in-page icon would 404")

    if problems:
        return "fail", "; ".join(problems)
    return "pass", f"toolbar + panel + options all use images/icon-*.png ({len(icons)} sizes declared)"


@test("Opal Connect sets itself up without a token hunt", "Integration")
def test_extension_setup_flow():
    """Setup used to be: find api.token in a config directory whose path differs
    per OS, on the machine Opal runs on, and paste it. On a headless box that
    file is not even on the same computer. Nothing in the extension told you
    that, either — an unconfigured install just failed every action with
    "No API token set".

    The server already serves /health and /api/auth/* before the Bearer gate,
    exactly so a browser can bootstrap. This asserts the extension uses them:
    discover, then sign in with the account the user already has."""
    ext_dir = os.path.join(PROJECT_DIR, "extension")
    bg = open(os.path.join(ext_dir, "src/background.ts")).read()
    shared = open(os.path.join(ext_dir, "src/shared.ts")).read()
    opts_ts = open(os.path.join(ext_dir, "src/options/options.ts")).read()
    opts_html = open(os.path.join(ext_dir, "src/options/options.html")).read()
    panel_ts = open(os.path.join(ext_dir, "src/sidepanel/sidepanel.ts")).read()

    checks = {
        "discovery probes /health": '"/health"' in bg,
        "asks whether an account exists": "/api/auth/status" in bg,
        "signs in for a token": "/api/auth/login" in bg,
        "can create the first account": "/api/auth/register" in bg,
        # Credentials in a URL land in logs and history; the server reads them
        # from the body via credParam for the same reason.
        "credentials travel in the body": "URLSearchParams" in bg and "init.body" in bg,
        "setup does not need saved settings": "host?: string" in shared,
        "candidate addresses are probed": "DISCOVERY_TARGETS" in shared,
        "options runs discovery": "discover" in opts_ts and "probe" in opts_ts,
        "options offers sign-in": "signin" in opts_html and "username" in opts_html,
        # The token path stays for automation, but one disclosure down.
        "token entry demoted to advanced": "Use an API token instead" in opts_html,
        # An unconfigured panel must offer the fix, not an unactionable error.
        "panel surfaces setup": "setup-card" in panel_ts and "openOptionsPage" in panel_ts,
        "not-connected is distinguished from broken": "needsSetup" in panel_ts,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "setup flow incomplete: " + ", ".join(missing)

    # Server side: these four must stay reachable without a Bearer token, or the
    # whole flow deadlocks (you need a token to get a token).
    remote = _src("src/services/remote.zig")
    gate = remote.index("All other endpoints require Bearer auth")
    before = remote[:gate]
    for ep in ('"/health"', '"/api/auth/"'):
        if ep not in before:
            return "fail", f"{ep} is no longer served before the Bearer gate — setup cannot bootstrap"
    return "pass", "discover /health → /api/auth/status → login|register; token entry kept for automation"


@test("Opal Connect exposes what Opal is doing", "Integration")
def test_extension_feature_coverage():
    """The panel could START things it could not then observe: a magnet sent
    from a page reported "Sent ✓" and nothing else — no progress, no seed count,
    no way to tell a stalled torrent from a fast one. Downloads and history had
    background actions wired with no UI at all, and a watch party you hosted
    could not be inspected or left."""
    ext_dir = os.path.join(PROJECT_DIR, "extension")
    bg = open(os.path.join(ext_dir, "src/background.ts")).read()
    panel_ts = open(os.path.join(ext_dir, "src/sidepanel/sidepanel.ts")).read()
    panel_html = open(os.path.join(ext_dir, "src/sidepanel/index.html")).read()
    remote = _src("src/services/remote.zig")

    # Each row: (label, endpoint the worker must call, id the panel must render)
    features = [
        ("torrent progress", "/api/torrents", "torrents-list"),
        ("downloads browser", "/api/downloads", "downloads-list"),
        ("recent searches", "/api/history", "history-list"),
        ("stop casting", "/api/cast/stop", "cast-stop"),
        ("leave a party", "/api/party/leave", "party-leave"),
        ("party status", "/api/party/status", "party-status"),
    ]
    problems = []
    for label, endpoint, element in features:
        if endpoint not in bg:
            problems.append(f"{label}: background.ts never calls {endpoint}")
        if element not in panel_html:
            problems.append(f"{label}: no #{element} in the panel")
        if element.split("-")[0] not in panel_ts:
            problems.append(f"{label}: panel has no code for it")
        # Every endpoint the extension calls must actually exist server-side.
        api = endpoint[len("/api"):]
        if f'api_path, "{api}"' not in remote:
            problems.append(f"{label}: remote.zig has no {endpoint} handler")

    # Shortcuts: a send that does not need the panel open.
    with open(os.path.join(ext_dir, "manifest.json")) as f:
        manifest = json.load(f)
    cmds = manifest.get("commands", {})
    if "opal-send-page" not in cmds or "opal-playpause" not in cmds:
        problems.append("keyboard commands not declared in the manifest")
    if "onCommand" not in bg:
        problems.append("background.ts does not handle chrome.commands")

    if problems:
        return "fail", "; ".join(problems)
    return "pass", f"{len(features)} panel surfaces wired to real endpoints; 2 keyboard shortcuts"


@test("Opal Connect version has one source of truth", "Integration")
def test_extension_version():
    """manifest.json said 0.3.0, package.json 0.1.0, and the About box a
    hardcoded "v0.2.0" — three numbers for one extension, and the one users
    read was the most wrong. The release job names the zip from manifest.json,
    so that is the number that ships."""
    ext_dir = os.path.join(PROJECT_DIR, "extension")
    with open(os.path.join(ext_dir, "manifest.json")) as f:
        mver = json.load(f).get("version")
    with open(os.path.join(ext_dir, "package.json")) as f:
        pver = json.load(f).get("version")
    opts = open(os.path.join(ext_dir, "src/options/options.html")).read()
    ots = open(os.path.join(ext_dir, "src/options/options.ts")).read()

    if mver != pver:
        return "fail", f"manifest.json {mver} != package.json {pver}"
    import re as _re
    if _re.search(r"v\d+\.\d+\.\d+", opts):
        return "fail", "options.html hardcodes a version again — read getManifest().version"
    if "getManifest().version" not in ots:
        return "fail", "options.ts does not read the version from the manifest"
    return "pass", f"manifest == package.json == {mver}; About reads getManifest()"
