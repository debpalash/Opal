"""Opal browser-extension (Opal Connector) integration test.

Validates the cross-browser MV3 extension under extension/ is wired correctly:
a valid MV3 manifest with the right permissions + localhost host_permissions, a
background service worker / content script / popup / options declared, the
background worker targeting the real Opal endpoints with a Bearer header, and
the Zig side carrying the /api/ingest handler it scrapes into.

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
    for need in ("contextMenus", "activeTab", "storage", "scripting", "notifications"):
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

    # Content script + popup + options declared.
    if not manifest.get("content_scripts"):
        problems.append("content_scripts not declared")
    action = manifest.get("action", {})
    if not action.get("default_popup"):
        problems.append("action.default_popup (popup) not declared")
    if not (manifest.get("options_ui") or manifest.get("options_page")):
        problems.append("options page not declared")

    # ── source files present ──
    for rel in (
        "src/background.ts",
        "src/content.ts",
        "src/popup/popup.html",
        "src/options/options.html",
    ):
        if not os.path.exists(os.path.join(ext_dir, rel)):
            problems.append(f"{rel} missing")

    # ── background worker targets the real endpoints + Bearer auth ──
    bg_path = os.path.join(ext_dir, "src/background.ts")
    bg_src = open(bg_path).read() if os.path.exists(bg_path) else ""
    if "/api/open" not in bg_src:
        problems.append("background.ts does not reference /api/open")
    if "/api/download/url" not in bg_src:
        problems.append("background.ts does not reference /api/download/url")
    if "/api/ingest" not in bg_src:
        problems.append("background.ts does not reference /api/ingest")
    if "Bearer" not in bg_src or "Authorization" not in bg_src:
        problems.append("background.ts missing Authorization: Bearer header")

    # ── Zig side: /api/ingest handler exists in remote.zig ──
    remote = _src("src/services/remote.zig")
    if '"/ingest"' not in remote:
        problems.append("remote.zig missing the /api/ingest handler")

    if problems:
        return "fail", "; ".join(problems)
    return (
        "pass",
        "MV3 manifest valid (perms + localhost host_permissions, SW + content "
        "+ popup + options); background.ts hits /api/open, /api/download/url, "
        "/api/ingest with Bearer auth; remote.zig has /api/ingest",
    )
