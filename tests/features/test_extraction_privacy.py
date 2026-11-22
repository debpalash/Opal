"""Private, predictable extraction and recoverable helper installs
(ROADMAP.md v2 section: private extraction, recoverable helper installs).
See tests/features/harness.py for the shared @test decorator and helpers."""
from .harness import *  # noqa: F401,F403
import hashlib
import os
import re
import shutil
import subprocess
import tempfile


# Calls that start or borrow a browser to fetch a page.
_BROWSER_CALLS = re.compile(
    r"\.fetchHtmlWithCancellation\(|\.fetchHtmlBlocking\(|\.fetchHtmlPostBlocking\("
    r"|browser_fetch\.fetchText\(|fetcher\.fetch\(|\.ensureBridge\(\)"
)
# Files that define those calls (the browser runtime itself) are not callers.
_DEFINERS = {"src/services/browser.zig", "src/services/browser_fetch.zig"}


def _strip_line_comments(text):
    return "\n".join(ln.split("//", 1)[0] for ln in text.splitlines())


def _browser_call_sites():
    sites = {}
    for base in ("src",):
        for root, _dirs, files in os.walk(os.path.join(PROJECT_DIR, base)):
            for fn in files:
                if not fn.endswith(".zig") or fn.endswith("_pure.zig") or fn.endswith("_test.zig"):
                    continue
                rel = os.path.relpath(os.path.join(root, fn), PROJECT_DIR)
                if rel in _DEFINERS:
                    continue
                code = _strip_line_comments(_src(rel))
                hits = [m.start() for m in _BROWSER_CALLS.finditer(code)]
                if hits:
                    sites[rel] = (code, hits)
    return sites


@test("Extraction: no browser is launched without the opt-in", "Privacy")
def test_no_browser_without_opt_in():
    state = _src("src/core/state.zig")
    cfg = _src("src/core/config.zig")
    policy = _src("src/services/extraction_policy_pure.zig")
    scrape = _src("src/services/scrape_fetch.zig")
    build = _src("build.zig")
    sap = _src("src/services/settings_api_pure.zig")
    remote = _src("src/services/remote.zig")

    checks = {
        "opt-in defaults off": "extraction_browser_opt_in: bool = false" in state,
        "legacy default-on key not read": 'eql(u8, key, "scrape_use_browser")' not in cfg
            and "scrape_use_browser" not in state,
        "opt-in persisted": 'setKey("extraction_browser_opt_in"' in cfg,
        "opt-in settable from settings API": '"extraction_browser_opt_in"' in sap
            and "state.app.extraction_browser_opt_in = v;" in remote,
        "policy registered": 'b.path("src/services/extraction_policy_pure.zig")' in build,
        "policy tests": 'test "no opt-in: no browser tier' in policy
            and 'test "opt-in order is paired browser then anti-detect engine"' in policy,
        "availability short-circuits on opt-in": re.search(
            r"fn availability\(\) policy\.Availability \{\s*if \(!state\.app\.extraction_browser_opt_in\) return \.\{\};",
            scrape) is not None,
        "typed outcome on /api/scrape": "scrapeFetchTyped(" in remote and "sf.errorJson(&err_buf, fetched.outcome)" in remote,
    }

    # Every browser-launching call outside the browser runtime must sit behind
    # the shared policy, or be an explicit per-request user prompt.
    sites = _browser_call_sites()
    gates = {
        # Fallback fetches only run inside the loop over policy.browserTiers.
        "src/services/scrape_fetch.zig": lambda code, at: code.rfind("for (plan.slice())", 0, at) != -1
            and code.rfind("policy.browserTiers(avail)", 0, at) != -1,
        # Pre-warm is the same decision as a fallback.
        "src/services/search.zig": lambda code, at: "policy.shouldPrewarm(" in code[max(0, at - 400):at],
        # POST /api/browser/fetch: the user is asked per request.
        "src/services/remote_browser_api.zig": lambda code, at: ".prompt = true" in code[at:at + 120],
    }
    ungated = []
    for rel, (code, hits) in sites.items():
        gate = gates.get(rel)
        for at in hits:
            if gate is None or not gate(code, at):
                line = code.count("\n", 0, at) + 1
                ungated.append(f"{rel}:{line}")
    checks["every browser call is gated"] = not ungated
    checks["scrape_fetch still has both tiers"] = "src/services/scrape_fetch.zig" in sites \
        and len(sites["src/services/scrape_fetch.zig"][1]) == 2

    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        detail = (" ungated: " + ", ".join(ungated)) if ungated else ""
        return "fail", "extraction privacy: " + ", ".join(missing) + detail
    return "pass", f"{sum(len(h) for _, h in sites.values())} browser call sites, all behind the opt-in policy or a per-request prompt"


def _fixture_tool(tmp):
    zig = shutil.which("zig")
    if not zig:
        return None, "zig not available"
    exe = os.path.join(tmp, "helper_install_fixture")
    r = subprocess.run(
        [zig, "build-exe", "--dep", "helper_install", "-Mroot=tests/tools/helper_install_fixture.zig",
         "-Mhelper_install=src/core/helper_install.zig", "-femit-bin=" + exe],
        cwd=PROJECT_DIR, capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        return None, "fixture tool failed to build: " + (r.stderr or r.stdout)[-300:]
    return exe, None


def _kv(out):
    return dict(part.split("=", 1) for part in out.split())


@test("Helper install: staged, verified, atomic, rollback, startup cleanup (local fixture)", "Network")
def test_helper_install_fixture():
    ytdlp = _src("src/services/ytdlp.zig")
    deps = _src("src/core/deps.zig")
    main = _src("src/main.zig")
    build = _src("build.zig")
    wiring = {
        "modules registered": 'b.path("src/core/helper_install_pure.zig")' in build
            and 'b.path("src/core/helper_install.zig")' in build,
        "yt-dlp installs through helper_install": "helper_install.install(" in ytdlp
            and ".sha256_hex = expected" in ytdlp and ".executable = true" in ytdlp,
        "yt-dlp no chmod subprocess": '"chmod"' not in ytdlp,
        "yt-dlp startup cleanup": "cleanupStaleOnce();" in ytdlp and "helper_install.cleanupStale(" in ytdlp,
        "yt-dlp rollback": "pub fn rollback() bool" in ytdlp and "helper_install.rollback(" in ytdlp,
        "whisper model through helper_install": "helper_install.install(" in deps
            and ".size = 77_704_715" in deps,
        "model partials cleaned at startup": "pub fn cleanupStaleDownloads()" in deps
            and "cleanupStaleDownloads();" in main,
    }
    missing = [k for k, ok in wiring.items() if not ok]
    if missing:
        return "fail", "helper install wiring: " + ", ".join(missing)

    with tempfile.TemporaryDirectory() as tmp:
        if not shutil.which("zig"):
            return "skip", "zig not available"
        exe, why = _fixture_tool(tmp)
        if not exe:
            return "fail", why
        d = os.path.join(tmp, "bin")
        os.mkdir(d)
        live = os.path.join(d, "tool")
        fixture = os.path.join(tmp, "release-asset")
        with open(fixture, "wb") as f:
            f.write(b"#!/bin/sh\necho 2026.11.01\n")
        good = hashlib.sha256(open(fixture, "rb").read()).hexdigest()

        def run(*a):
            r = subprocess.run([exe, *a], capture_output=True, text=True, timeout=30)
            return _kv(r.stdout) if r.returncode == 0 else {"error": r.stderr[-200:]}

        def read(p):
            with open(p, "rb") as f:
                return f.read()

        with open(live, "wb") as f:
            f.write(b"working")

        # A bad checksum, an HTTP failure and a failed probe keep the working copy.
        r = run("install", d, "tool", fixture, "0" * 64)
        if r.get("failure") != "checksum_mismatch" or read(live) != b"working":
            return "fail", f"checksum mismatch replaced the working copy: {r}"
        r = run("install", d, "tool", "-fail", "-")
        if r.get("failure") != "fetch_http" or read(live) != b"working":
            return "fail", f"HTTP failure replaced the working copy: {r}"
        r = run("install", d, "tool", fixture, good, "probe-fail")
        if r.get("failure") != "probe_failed" or read(live) != b"working":
            return "fail", f"failed probe replaced the working copy: {r}"
        leftovers = sorted(n for n in os.listdir(d) if n != "tool")
        if leftovers:
            return "fail", f"failed installs left files behind: {leftovers}"

        # A verified update publishes, is executable, and keeps the previous copy.
        r = run("install", d, "tool", fixture, good)
        if r.get("ok") != "1" or r.get("kept_previous") != "1" or read(live) != read(fixture):
            return "fail", f"verified update did not publish: {r}"
        if os.name != "nt" and not os.access(live, os.X_OK):
            return "fail", "published helper is not executable"
        if read(os.path.join(d, "tool.opal-prev")) != b"working":
            return "fail", "previous version not kept"
        if run("rollback", d, "tool").get("ok") != "1" or read(live) != b"working":
            return "fail", "rollback did not restore the previous version"

        # A crash: partial downloads beside the helper and the live file moved aside.
        for n in ("tool.opal-stage", "tool.opal-stage.part", "tool.new", "tool.part"):
            with open(os.path.join(d, n), "wb") as f:
                f.write(b"partial")
        os.replace(live, os.path.join(d, "tool.opal-prev"))
        r = run("cleanup", d, "tool")
        if r.get("removed") != "4" or r.get("restored") != "1" or read(live) != b"working":
            return "fail", f"startup cleanup did not recover: {r}"
        if sorted(os.listdir(d)) != ["tool"]:
            return "fail", f"cleanup left: {sorted(os.listdir(d))}"

    return "pass", "checksum/HTTP/probe failures keep the working copy; verified update is atomic, executable, keeps previous; rollback and crash cleanup work"
