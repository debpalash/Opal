"""Video — Live TV / IPTV (iptv-org) tab tests.

Structural VIDEO twin of the Radio tab: keyless channel discovery via the
iptv-org public directory (streams.json), m3u8/HLS streams handed straight to
mpv. Opt-in via the source_config-gated "iptv-org" plugin, NSFW-filtered.

Verify the full wiring: the tested pure module is registered + routed
(tested logic == shipped logic), the service has the source_config gate +
NSFW check + renderContent/playChannel, the DrawerTab enum/nav/render/rail are
all wired, and the bundled manifest carries the iptv-org entry.

See tests/features/harness.py for the shared @test decorator."""
from .harness import *  # noqa: F401,F403

import json
import os


@test("Live TV (IPTV) tab", "Video")
def test_iptv_tab():
    svc = _src("src/services/iptv.zig")
    pure = _src("src/services/iptv_pure.zig")
    st = _src("src/core/state.zig")
    shell = _src("src/ui/shell.zig")
    drawer = _src("src/ui/drawer.zig")
    build = _src("build.zig")

    checks = {
        # ── Pure module: URL builder, m3u8/NSFW/accept decisions, parser ──
        "pure module present": bool(pure),
        "pure IptvChannel record": "pub const IptvChannel = struct" in pure,
        "pure streams-url builder": "pub fn buildStreamsUrl" in pure,
        "pure m3u8 recognizer": "pub fn isM3u8" in pure,
        "pure NSFW gate": "pub fn isNsfw" in pure,
        "pure accept decision": "pub fn acceptEntry" in pure,
        "pure streams parser": "pub fn parseStreams" in pure,
        # Accept gate is CALLED from the parser (drop unplayable/NSFW at parse time).
        "accept routed in parseStreams": "acceptEntry(" in pure,

        # ── Service: gate + async worker + thread-safety + play path ──
        # Production routes through the pure fns (tested logic == shipped logic).
        "service routes through pure": all(
            f"pure.{fn}(" in svc
            for fn in ("buildStreamsUrl", "parseStreams", "isM3u8")
        ),
        # Opt-in gate via source_config (plugin id "iptv-org").
        "source_config gate": 'source_config.get("iptv-org", "base")' in svc,
        "inert when uninstalled": "orelse return null" in svc,
        # NSFW gating keyed on the app filter flag (inverse → nsfw_allowed).
        "nsfw filter check": "nsfw_filter_enabled" in svc,
        # iptv-org streams.json endpoint.
        "streams.json endpoint": "streams.json" in svc or "streams.json" in pure,
        # Discovery + search + play.
        "popular one-shot": "pub fn loadPopularOnce" in svc,
        "search entry": "pub fn searchIptv" in svc,
        "infinite scroll": "pub fn loadMore" in svc,
        "play hands url to mpv": "pub fn playChannel" in svc and "loadContentDirectMeta(" in svc,
        "render entry": "pub fn renderContent" in svc,
        # Thread discipline (mirrors radio.zig).
        "atomic loading flag": "is_loading.store" in svc,
        "publishes under mutex": "parse_mutex.lock()" in svc,
        "generation guard": "search_gen" in svc,
        # curl only — std.http SEGVs on some ISP TLS resets (see comics.zig).
        "curl not std.http": "std.http.Client" not in svc and '"curl"' in svc,

        # ── Enum → state → nav → render dispatch → rail/shell ──
        # Assert MEMBERSHIP, not position (concurrent tab additions).
        "enum variant present": "Iptv" in st and "pub const DrawerTab" in st,
        "state struct": "iptv: struct {" in st,
        "results buffer (capped)": "]iptv_pure.IptvChannel" in st,
        "nav host page": ".Iptv => {" in st and "app.browse_source = .Iptv;" in st,
        "render dispatch": '.Iptv => @import("../services/iptv.zig").renderContent()' in drawer,
        "grouped under video": ".YouTube, .Iptv => .video" in drawer,
        "rail nav entry": "renderRailTab(.Iptv" in drawer,
        "shell label": '.Iptv => "Live TV"' in shell,
        "shell icon (exists in pack)": '.Iptv => icons.tvg.lucide.@"monitor-play"' in shell,
        "browse subtab": ".Iptv" in shell and "subTabs(&.{" in shell,

        # ── Pure module registered in the `zig build test` step ──
        "test registered": 'b.path("src/services/iptv_pure.zig")' in build,
    }

    # ── Bundled manifest carries the iptv-org plugin entry ──
    mpath = os.path.join(PROJECT_DIR, "plugins-manifest.json")
    manifest_ok = False
    try:
        with open(mpath) as f:
            man = json.load(f)
        for p in man.get("plugins", []):
            if p.get("id") == "iptv-org" and p.get("type") == "iptv" \
                    and "iptv-org.github.io" in p.get("endpoints", {}).get("base", ""):
                manifest_ok = True
                break
    except Exception:
        manifest_ok = False
    checks["manifest iptv-org entry"] = manifest_ok

    missing = [k for k, ok in checks.items() if not ok]
    if not missing:
        return "pass", "IPTV wired: pure(url/m3u8/nsfw/parse) -> gated fetch -> enum/nav/rail; manifest present"
    return "fail", "IPTV wiring incomplete: " + ", ".join(missing)
