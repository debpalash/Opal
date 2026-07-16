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
