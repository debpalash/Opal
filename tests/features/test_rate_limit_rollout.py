"""Every outbound scraper/backend funnels through the shared rate limiter.
See tests/features/harness.py for the shared @test decorator, helpers, and
run_all()."""
from .harness import *  # noqa: F401,F403
import os
import re

# Outbound HTTP primitives. A module that calls any of these (directly via
# `@import("…http.zig").fetch(` or through a `const x = @import(…);` alias)
# makes network requests and must also call `rate_limit.acquire`.
_PRIMITIVES = {
    "http": r"(?:fetch|fetchAlloc|fetchDirect|fetchImage|newClient|directStreamingClient)",
    "reliable_fetch": r"(?:fetch|request|download|stream)",
    "scrape_fetch": r"scrapeFetch\w*",
}

# Modules that make outbound requests but are deliberately NOT token-bucketed.
# Every entry needs a reason; a stale entry (module gone, or it now calls
# acquire) fails the test so the list cannot rot.
_PRIMITIVE = "transport primitive; its callers acquire before calling it"
_LOOPBACK = "talks only to a loopback sidecar or local server Opal itself runs"
_ONE_SHOT = "single user-initiated download of a pinned asset, not a scraper"
EXEMPT = {
    "src/services/reliable_fetch.zig": _PRIMITIVE,
    "src/services/scrape_fetch.zig": _PRIMITIVE,
    "src/services/fetch_target.zig": "dial/pin helper for the transports; never issues a request itself",
    "src/services/ai_context.zig": _LOOPBACK + " (local LLM /health probe)",
    "src/services/ai_memory.zig": _LOOPBACK + " (127.0.0.1 embeddings)",
    "src/services/ai_voice.zig": _LOOPBACK + " (127.0.0.1 TTS)",
    "src/services/co_watch.zig": _LOOPBACK + " (local LLM chat completion)",
    "src/services/lang_learn.zig": _LOOPBACK + " (127.0.0.1 lang server)",
    "src/services/llm_oneshot.zig": _LOOPBACK + " (local LLM server)",
    "src/services/recall_embed.zig": _LOOPBACK + " (URL is forced to 127.0.0.1/localhost)",
    "src/services/voice_backend.zig": _LOOPBACK + " (local Speaches STT/TTS server)",
    "src/services/suwayomi_server.zig": _LOOPBACK + " (bundled Suwayomi on localhost) plus its one-time JAR download",
    "src/services/handoff.zig": "one request per user action to a paired LAN peer device",
    "src/services/library_sync.zig": "paired LAN peer sync, paged by the peer's own cursor",
    "src/services/offline.zig": "offline copies from the user's own paired Opal server, one transfer at a time (transfer_busy)",
    "src/services/download_engine.zig": "bulk transfer engine; bandwidth is governed by the download_rate_limit dial",
    "src/services/browser.zig": _ONE_SHOT + " (browser file download)",
    "src/services/browser_privacy.zig": _ONE_SHOT + " (pinned uBOL release)",
    "src/services/ai_server.zig": _ONE_SHOT + " (local model weights)",
    "src/services/voice_setup.zig": _ONE_SHOT + " (pinned sherpa-onnx models)",
    "src/services/scripts.zig": _ONE_SHOT + " (pinned mpv scripts)",
    "src/services/ytdlp.zig": _ONE_SHOT + " (yt-dlp binary update + checksum)",
    "src/services/updater.zig": "one release check per launch or click, then the chosen asset download",
    "src/services/wallpaper_desktop.zig": _ONE_SHOT + " (the wallpaper the user picked)",
    "src/services/remote_stream.zig": "artwork proxy for the web UI; concurrency is bounded by core/poster.zig slots",
    "src/player/youtube_range_proxy.zig": "playback byte-range proxy; throttling would stall the player",
}


def _outbound(src):
    hits = set()
    for mod, fns in _PRIMITIVES.items():
        if re.search(r'@import\("[./a-z_]*\b%s\.zig"\)\.%s\(' % (mod, fns), src):
            hits.add(mod)
        for m in re.finditer(r'const (\w+) = @import\("[./a-z_]*\b%s\.zig"\);' % mod, src):
            if re.search(r"\b%s\.%s\(" % (m.group(1), fns), src):
                hits.add(mod)
    if "std.http.Client" in src:
        hits.add("std.http")
    return hits


def _rate_limited(src):
    if re.search(r'@import\("[./a-z_]*rate_limit\.zig"\)\.acquire(?:Url)?\(', src):
        return True
    for m in re.finditer(r'const (\w+) = @import\("[./a-z_]*rate_limit\.zig"\);', src):
        if re.search(r"\b%s\.acquire(?:Url)?\(" % m.group(1), src):
            return True
    return False


def _scraper_modules():
    out = {}
    for d in ("src/services", "src/player"):
        base = os.path.join(PROJECT_DIR, d)
        for name in sorted(os.listdir(base)):
            if not name.endswith(".zig") or name.endswith("_pure.zig") or name.endswith("_test.zig"):
                continue
            rel = d + "/" + name
            src = _src(rel)
            if _outbound(src):
                out[rel] = src
    return out


@test("Every outbound scraper calls rate_limit.acquire (explicit exemptions)", "Network")
def test_rate_limit_rollout():
    mods = _scraper_modules()
    if len(mods) < 20:
        return "fail", "scanner found only %d outbound modules; detector broke" % len(mods)
    missing = [rel for rel, src in mods.items() if rel not in EXEMPT and not _rate_limited(src)]
    stale = [rel for rel in EXEMPT if rel not in mods or _rate_limited(mods[rel])]
    unexplained = [rel for rel, why in EXEMPT.items() if len(why.strip()) < 20]
    # The registry must hold every distinct origin key the rollout introduced;
    # an overflow degrades acquire() to a flat sleep on every call.
    rl = _src("src/core/rate_limit.zig")
    cap = re.search(r"const MAX_BUCKETS: usize = (\d+);", rl)
    keys = set()
    for src in mods.values():
        keys.update(re.findall(r'\.acquire\("([^"]+)"', src))
    problems = []
    if missing:
        problems.append("not rate-limited: " + ", ".join(missing))
    if stale:
        problems.append("stale exemptions: " + ", ".join(stale))
    if unexplained:
        problems.append("exemptions without a reason: " + ", ".join(unexplained))
    if not cap or int(cap.group(1)) < 2 * len(keys):
        problems.append("MAX_BUCKETS too small for %d static keys" % len(keys))
    if problems:
        return "fail", "; ".join(problems)
    return "pass", "%d outbound modules: %d rate-limited, %d exempt; %d static keys" % (
        len(mods), len(mods) - len(EXEMPT), len(EXEMPT), len(keys))
