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
