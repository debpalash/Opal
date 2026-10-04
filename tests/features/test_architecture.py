"""Fast architecture and documentation wiring checks.

These checks are deliberately labelled as source-wiring tests. Runtime and
socket behavior belongs to the opt-in live test tier.
"""
import os
import subprocess
import sys
from pathlib import Path

from .harness import *  # noqa: F401,F403


@test("Architecture documentation and presentation import boundaries", "Architecture")
def test_architecture_boundaries():
    doc = _src("docs/architecture.md")
    checks = {
        "dependency direction": all(term in doc.lower() for term in (
            "domain", "store", "adapters", "application", "presentation",
        )),
        "headless boundary": "dvui" in doc.lower() and "headless" in doc.lower(),
        "lock order": "feature lock" in doc.lower() and "socket" in doc.lower(),
        "reference vertical": "Podcasts" in doc,
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "architecture documentation missing: " + ", ".join(missing)
    result = subprocess.run([sys.executable, "scripts/check_architecture.py"], cwd=PROJECT_DIR, capture_output=True, text=True)
    if result.returncode:
        return "fail", result.stdout + result.stderr
    tests = subprocess.run([sys.executable, "tests/test_architecture_boundaries.py"], cwd=PROJECT_DIR, capture_output=True, text=True)
    if tests.returncode:
        return "fail", tests.stdout + tests.stderr
    return "pass", "actual imports checked against explicit migration exceptions; gate regression tests pass"




@test("Podcast and Jellyfin readers use immutable feature snapshots", "Architecture")
def test_feature_store_snapshots():
    podcasts = _src("src/services/podcasts.zig")
    podcasts_ui = _src("src/ui/podcasts_ui.zig")
    jellyfin = _src("src/services/jellyfin.zig")
    jellyfin_ui = _src("src/ui/jellyfin_ui.zig")
    remote = _remote_api()
    stream = _src("src/services/remote_stream.zig")
    checks = {
        "podcast generation": "publication_gen" in podcasts and "pub const Snapshot" in podcasts,
        "podcast desktop snapshot": "const view = podcasts.snapshot();" in podcasts_ui
            and "renderResults(&view)" in podcasts_ui and "renderEpisodes(&view)" in podcasts_ui,
        "podcast service is UI-free": '@import("dvui")' not in podcasts
            and 'ui/' not in "\n".join(
                line for line in podcasts.splitlines() if line.lstrip().startswith("const ")
            )
            and '@import("podcasts_ui.zig").renderContent()' in _src("src/ui/drawer.zig"),
        "podcast remote snapshot": "podcasts_svc.copySnapshot(view)" in remote
            and 'podcasts.zig").copyArtwork' in stream,
        "Jellyfin projection excludes pointers": "pub const RemoteItem" in jellyfin
            and "poster_pixels" not in _between(jellyfin, "pub const RemoteItem", "pub const RemoteSnapshot"),
        "Jellyfin desktop snapshot": "jf.desktopSnapshot()" in jellyfin_ui
            and "frame_view.items" in jellyfin_ui and "state.app.jf.items" not in jellyfin_ui
            and "pub const DesktopSnapshot" in jellyfin,
        "Jellyfin remote snapshot": "jf.remoteSnapshot()" in remote
            and 'jellyfin.zig").connectionSnapshot' in stream,
        "commands own credential mutation": "pub fn configureLogin(" in jellyfin
            and "jf.configureLogin(" in remote,
        "socket writes after snapshots": remote.find("podcasts_svc.copySnapshot(view)") < remote.find(
            "sendJson(stream, json_buf[0..w.end])", remote.find("podcasts_svc.copySnapshot(view)")
        ),
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "feature snapshot regression(s): " + ", ".join(missing)
    return "pass", "generation-tagged Podcast/Jellyfin projections isolate UI and HTTP readers"


@test("Playback completion has a shared desktop and headless owner", "Architecture")
def test_playback_owner():
    call = '@import("application/playback_update.zig").tick();'
    for path in ("src/main.zig", "src/headless.zig"):
        if _src(path).count(call) != 1:
            return "fail", f"{path} must invoke the common playback owner exactly once"
    pump = _src("src/application/playback_update.zig")
    for operation in ("drainResolved", "drainTranscodeRecovery", "tickNowPlaying"):
        if operation not in pump:
            return "fail", "missing playback completion: " + operation
    return "pass", "both composition roots share playback completion and recovery"


@test("HLS upgrades escape old immutable browser caches", "Architecture")
def test_hls_cache_upgrade():
    import hashlib
    version = hashlib.sha256(Path(PROJECT_DIR, "web/vendor/hls.min.js").read_bytes()).hexdigest()[:12]
    asset = "/vendor/hls.min.js?v=" + version
    if asset not in _src("web/index.html") or asset not in _src("web/service-worker.js"):
        return "fail", "shell and offline cache must reference the current HLS content fingerprint"
    if ".cache = .immutable" in _src("src/services/remote_static.zig"):
        return "fail", "unversioned asset routes must revalidate"
    return "pass", "HLS content version changes its browser cache key; stable routes revalidate"
