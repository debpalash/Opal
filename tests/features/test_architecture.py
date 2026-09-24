"""Fast architecture and documentation wiring checks.

These checks are deliberately labelled as source-wiring tests. Runtime and
socket behavior belongs to the opt-in live test tier.
"""
import os

from .harness import *  # noqa: F401,F403


@test("Architecture boundaries are documented and enforced", "Architecture")
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
    return "pass", "dependency direction, headless seam, reference vertical, and lock order documented"




@test("Podcast and Jellyfin readers use immutable feature snapshots", "Architecture")
def test_feature_store_snapshots():
    podcasts = _src("src/services/podcasts.zig")
    podcasts_ui = _src("src/ui/podcasts_ui.zig")
    jellyfin = _src("src/services/jellyfin.zig")
    jellyfin_ui = _src("src/ui/jellyfin_ui.zig")
    remote = _src("src/services/remote.zig")
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
        "podcast remote snapshot": "podcasts_svc.snapshot()" in remote
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
        "socket writes after snapshots": remote.find("podcasts_svc.snapshot()") < remote.find(
            "sendJson(stream, json_buf[0..w.end])", remote.find("podcasts_svc.snapshot()")
        ),
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "feature snapshot regression(s): " + ", ".join(missing)
    return "pass", "generation-tagged Podcast/Jellyfin projections isolate UI and HTTP readers"
