"""Anti-block scrape fetch — Cloudflare/DDoS-Guard/captcha browser fallback.
See tests/features/harness.py for the shared @test decorator, helpers, and
run_all()."""
from .harness import *  # noqa: F401,F403
import os  # noqa: F401
import subprocess  # noqa: F401
import sys  # noqa: F401


@test("Anti-block scrape fetch", "Network")
def test_scrape_fetch():
    # A shared fetch layer: try a fast plain HTTP GET, and when the response is
    # a Cloudflare / DDoS-Guard / captcha interstitial, transparently re-fetch
    # the same URL through the anti-detect browser (which passes the challenge).
    #
    # Verify: the pure block detector is registered + routed (tested logic ==
    # shipped logic), scrape_fetch.zig uses needsBrowser/isBlocked, the bridge
    # gained a `fetchhtml` command on a DEDICATED page, the Cloudflare markers
    # are present, the config toggle is wired, and py_compile + bridge selftest
    # pass.
    pure = _src("src/services/scrape_fetch_pure.zig")
    svc = _src("src/services/scrape_fetch.zig")
    brow = _src("src/services/browser.zig")
    brow_pure = _src("src/services/browser_pure.zig")
    bridge = _src("scripts/camoufox_bridge.py")
    cfg = _src("src/core/config.zig")
    st = _src("src/core/state.zig")
    build = _src("build.zig")

    checks = {
        # ── Pure block detection: present, thorough, no false positives ──
        "pure module present": bool(pure),
        "isBlocked present": "pub fn isBlocked(" in pure,
        "looksLikeChallengePage present": "pub fn looksLikeChallengePage(" in pure,
        "needsBrowser composite present": "pub fn needsBrowser(" in pure,
        "parseStatus present": "pub fn parseStatus(" in pure,
        # Cloudflare / DDoS-Guard / captcha markers keyed on interstitials
        "cf just-a-moment marker": '"Just a moment"' in pure,
        "cf checking-browser marker": '"Checking your browser"' in pure,
        "cf chl marker": "__cf_chl" in pure,
        "cf attention-required marker": "Attention Required! | Cloudflare" in pure,
        "cf-ray header signal": '"cf-ray"' in pure,
        "cf-mitigated header signal": '"cf-mitigated"' in pure,
        "ddos-guard marker": "DDoS-Guard" in pure,
        "human-verify marker": "Please verify you are a human" in pure or "Verifying you are human" in pure,
        # False-positive guard: a footer that merely says "Cloudflare" is NOT a
        # block — the test module asserts this directly.
        "false-positive test present": "mentioning cloudflare in footer is NOT blocked" in pure,
        "empty-input test present": "empty / truncated inputs never crash" in pure,

        # ── Production routes through the pure detector (no drift) ──
        "service present": bool(svc),
        "service routes through needsBrowser": "pure.needsBrowser(" in svc,
        "service routes through parseStatus": "pure.parseStatus(" in svc,
        "public scrapeFetch api": "pub fn scrapeFetch(" in svc,
        "browser fallback gated on config": "state.app.scrape_use_browser" in svc,
        "browser fallback gated on engine": "browser.engineReady(" in svc,
        "calls browser fetchHtmlBlocking": "browser.fetchHtmlBlocking(" in svc,
        "one-time ready log": "Anti-block fetch ready" in svc,

        # ── Bridge: fetchhtml command on a DEDICATED page ──
        "bridge fetchhtml command": 'action == "fetchhtml"' in bridge,
        "bridge fetchapi command": 'action == "fetchapi"' in bridge,
        "bridge dedicated scrape page": "def get_scrape_page(" in bridge and "new_context()" in bridge,
        "bridge challenge-clear wait": "def wait_for_challenge_clear(" in bridge,
        "bridge challenge markers": "def looks_like_challenge(" in bridge,
        "bridge H-frame for payload": "def send_html_frame(" in bridge,
        "bridge caps payload": "MAX_SCRAPE_BYTES" in bridge,

        # ── Zig reader: H-frame handling + fetchhtml_err classification ──
        "browser H-frame handling": "tag[0] == 'H'" in brow,
        "browser scrape await mutex": "scrape_req_mutex" in brow,
        "browser fetchHtmlBlocking present": "pub fn fetchHtmlBlocking(" in brow,
        "classify fetchhtml_err": "fetchhtml_err" in brow_pure and 'event\\": \\"fetchhtml' in brow_pure,

        # ── Config toggle ──
        "config setKey": 'setKey("scrape_use_browser"' in cfg,
        "config apply": '"scrape_use_browser"' in cfg,
        "state field": "scrape_use_browser: bool = true" in st,

        # ── Pure module registered in `zig build test` ──
        "test registered": 'b.path("src/services/scrape_fetch_pure.zig")' in build,
    }

    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "scrape-fetch wiring incomplete: " + ", ".join(missing)

    # py_compile the bridge and run its selftest (new command's arg parsing +
    # H-frame framing + challenge detection).
    bridge_path = os.path.join(PROJECT_DIR, "scripts/camoufox_bridge.py")
    try:
        subprocess.run([sys.executable, "-m", "py_compile", bridge_path],
                       check=True, capture_output=True)
    except Exception as e:
        return "fail", "bridge py_compile failed: " + str(e)
    try:
        r = subprocess.run([sys.executable, bridge_path, "--selftest"],
                           capture_output=True, text=True, timeout=30)
    except Exception as e:
        return "fail", "bridge selftest error: " + str(e)
    if r.returncode != 0:
        return "fail", "bridge selftest failed: " + (r.stderr or r.stdout).strip()[:200]

    return "pass", "anti-block fetch wired: pure(isBlocked/needsBrowser, no false-pos) → scrape_fetch → bridge fetchhtml on dedicated page; selftest ok"


@test("Scrapers routed through anti-block fetch", "Network")
def test_scrapers_routed_through_scrapefetch():
    # The HTML-scraper source engines fetch their pages through the anti-block
    # scrapeFetch layer (fast plain GET, browser fallback on a Cloudflare/DDoS-
    # Guard/captcha challenge) instead of a bare curl. Verify the wiring per
    # call-site AND the deliberate exceptions:
    #   - comics.zig: Madara + MangaThemesia framework fetches + the generic
    #     scraper route through the `fetchMaybeUnblocked` → scrapeFetch wrapper;
    #     MangaDex's api.mangadex.org JSON chain stays on `fetchUrl` with its
    #     per-host UA (a browser UA 400s MangaDex), and HeanCms JSON likewise.
    #   - anime_extractors.zig: the embed-page fetches route through scrapeFetch.
    #   - novels.zig: the scraper engines' HTML GETs route through the
    #     `scrapeHtml` → scrapeFetch wrapper; Wikisource's keyless JSON API stays
    #     on plain curl and the POST paths stay on curlPost (scrapeFetch is GET-only).
    comics = _src("src/services/comics.zig")
    anime = _src("src/services/anime_extractors.zig")
    novels = _src("src/services/novels.zig")

    checks = {
        # ── comics.zig: framework fetches routed; MangaDex/HeanCms JSON left ──
        "comics imports scrape_fetch": 'const scrape = @import("scrape_fetch.zig")' in comics,
        "comics wrapper present": "fn fetchMaybeUnblocked(" in comics,
        "comics wrapper calls scrapeFetch": "scrape.scrapeFetch(" in comics,
        "themesia detail routed": "fetchMaybeUnblocked(detail_url, detail_html)" in comics,
        "themesia chapter routed": "fetchMaybeUnblocked(chap_url, chap_html)" in comics,
        "madara details routed": "fetchMaybeUnblocked(manga_url, details_buf)" in comics,
        "madara chapter routed": "fetchMaybeUnblocked(chapter_url, chap_buf)" in comics,
        "generic scraper routed": "fetchMaybeUnblocked(url, html_buf)" in comics,
        # MangaDex's api.mangadex.org chain is NOT routed through the browser — it
        # keeps its per-host UA fetchUrl (a browser UA 400s MangaDex).
        "mangadex feed on fetchUrl": "fetchUrl(feed_url, feed_buf)" in comics,
        "mangadex at-home on fetchUrl": "fetchUrl(ah_url, ah_buf)" in comics,
        "mangadex not browser-routed": "fetchMaybeUnblocked(feed_url" not in comics
            and "fetchMaybeUnblocked(ah_url" not in comics,
        "per-host UA preserved": "pure.userAgentFor(url)" in comics,
        # HeanCms JSON API likewise stays on fetchUrl.
        "heancms detail on fetchUrl": "fetchUrl(detail_url, detail_buf)" in comics,

        # ── anime_extractors.zig: embed fetches routed through scrapeFetch ──
        "anime imports scrape_fetch": 'const scrape = @import("scrape_fetch.zig")' in anime,
        "anime embed routed": "scrape.scrapeFetch(embed_url, html_buf)" in anime,

        # ── novels.zig: scraper HTML GETs routed; Wikisource/POST left ──
        "novels imports scrape_fetch": 'const scrape = @import("scrape_fetch.zig")' in novels,
        "novels wrapper present": "fn scrapeHtml(" in novels,
        "novels wrapper calls scrapeFetch": "scrape.scrapeFetch(" in novels,
        "novels search routed": "scrapeHtml(url, 512 * 1024)" in novels,
        "novels chapters routed": "scrapeHtml(murl, 1024 * 1024)" in novels,
        "novels text routed": "scrapeHtml(chapter_url, 2 * 1024 * 1024)" in novels,
        # Wikisource stays on plain curl (keyless JSON, never challenged); the
        # POST paths stay on curlPost (scrapeFetch is GET-only).
        "wikisource stays on curl": "curl(url, 512 * 1024)" in novels,
        "post paths stay on curlPost": "curlPost(" in novels,
    }

    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "scraper routing incomplete: " + ", ".join(missing)
    return "pass", ("comics(Madara/MangaThemesia/generic)→fetchMaybeUnblocked, "
                    "anime embeds→scrapeFetch, novels(scraper engines)→scrapeHtml; "
                    "MangaDex/HeanCms JSON + Wikisource + POST paths left on curl")
