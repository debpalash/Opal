"""Verified private remote deployment: pinned images, correct mounts, a
scripted end-to-end validation, and Tailscale kept manual-only.

The runtime check drives scripts/validate-headless-deploy.py against a
headless binary (never the GUI build: it would open a window). Docker is not
required; the same script takes --image on a Docker host.

See tests/features/harness.py for the shared @test decorator + _src()."""
import json
import os
import re
import subprocess
import sys
import tempfile

from .harness import *  # noqa: F401,F403

DIGEST = re.compile(r"@sha256:[0-9a-f]{64}\b")
COMPOSE = ("deploy/docker-compose.yml", "deploy/docker-compose.tls.yml", "deploy/docker-compose.tailscale.yml")


@test("Deploy images pinned to reviewed digests", "Deploy")
def test_images_pinned():
    unpinned = []
    froms = [l for l in _src("Dockerfile").splitlines() if re.match(r"\s*FROM\s", l)]
    unpinned += [l.strip() for l in froms if not DIGEST.search(l)]
    for rel in COMPOSE:
        for line in _src(rel).splitlines():
            m = re.match(r"\s*image:\s*(\S+)", line)
            if m and m.group(1) != "opal:headless" and not DIGEST.search(line):
                unpinned.append(f"{rel}: {m.group(1)}")
    wf = _src(".github/workflows/docker.yml")
    checks = {
        "two FROM stages": len(froms) == 2,
        "no :latest": not any(re.match(r"\s*image:\s*\S+:latest\b", l)
                              for rel in COMPOSE for l in _src(rel).splitlines()),
        "CI refuses unpinned images": "Refuse unpinned images" in wf and "@sha256:[0-9a-f]" in wf,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if unpinned or missing:
        return "fail", "unpinned: " + ", ".join(unpinned) + ("; " + ", ".join(missing) if missing else "")
    return "pass", "Dockerfile + caddy + tailscale pinned by sha256; CI guard present"


@test("Deploy mounts: /media is the download root, host dirs never auto-created", "Deploy")
def test_mounts():
    df = _src("Dockerfile")
    paths = _src("src/core/paths.zig")
    problems = []
    # Regression: HOME=/config made downloads land on the config volume.
    if "OPAL_DOWNLOAD_DIR=/media" not in df:
        problems.append("Dockerfile does not set OPAL_DOWNLOAD_DIR=/media")
    if 'getenv("OPAL_DOWNLOAD_DIR")' not in paths or "downloadDirOverride" not in paths:
        problems.append("paths.defaultSavePath ignores OPAL_DOWNLOAD_DIR")
    if 'test "OPAL_DOWNLOAD_DIR' not in paths:
        problems.append("no unit test for the override")
    for rel in COMPOSE:
        text = _src(rel)
        for target in ("/config", "/cache", "/media"):
            block = re.search(r"source: \.\./data/(\w+)\n\s+target: " + re.escape(target) + r"\n\s+bind:\n\s+create_host_path: false", text)
            if not block:
                problems.append(f"{rel}: {target} not a create_host_path:false bind")
            elif block.group(1) != target.strip("/"):
                problems.append(f"{rel}: {target} mounted from data/{block.group(1)}")
        if re.search(r"-\s*\.\./data/(config|cache|media):", text):
            problems.append(f"{rel}: short-syntax data mount remains")
        if 'OPAL_DOWNLOAD_DIR: "/media"' not in text:
            problems.append(f"{rel}: OPAL_DOWNLOAD_DIR not explicit")
    if problems:
        return "fail", "; ".join(problems)
    return "pass", "3 profiles: /config,/cache,/media long-syntax binds; downloads on /media"


@test("Deploy docs: scripted validation + Tailscale manual-only", "Deploy")
def test_docs():
    doc = _src("docs/headless-deploy.md")
    script = _src("scripts/validate-headless-deploy.py")
    steps = ("startup", "bootstrap", "range", "identity", "sse", "reconnect", "restart", "https_proxy", "expiry")
    checks = {
        "validation documented": "scripts/validate-headless-deploy.py" in doc and all(f"| {s} |" in doc for s in steps),
        "script runs every step": all(f'run("{s}"' in script for s in steps),
        "manual-only Tailscale section": "## Tailscale: manual-only steps" in doc
            and all(w in doc for w in ("auth key", "ACL", "Funnel")),
        # The automation itself must never drive a tailnet.
        "script makes no Tailscale calls": not re.search(r"\btailscale\b\s+(up|login|funnel|serve)", script)
            and "TS_AUTHKEY" not in script,
        "isolated from the real config": "tempfile.mkdtemp" in script and "XDG_CONFIG_HOME" in script,
        "caddy never installs trust": "skip_install_trust" in script and "admin off" in script,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "deploy docs/script incomplete: " + ", ".join(missing)
    return "pass", "9 validation steps documented; Tailscale steps manual-only"


def _headless_binary():
    """A headless build only. The GUI binary links SDL and would open a window."""
    candidates = [os.environ.get("OPAL_HEADLESS_BIN", ""), os.path.join(PROJECT_DIR, "zig-out", "bin", "opal")]
    for path in candidates:
        if not path or not os.access(path, os.X_OK):
            continue
        with open(path, "rb") as f:
            blob = f.read()
        if b"headless: web UI + JSON API" in blob and b"SDL_CreateWindow" not in blob:
            return path
    return None


@test("Deploy validation passes against the headless binary", "Deploy")
def test_validation_run():
    binary = _headless_binary()
    if not binary:
        return "skip", "no headless build (zig build -Dheadless=true, or set OPAL_HEADLESS_BIN)"
    out = tempfile.NamedTemporaryFile(prefix="opal-deploy-", suffix=".json", delete=False)
    out.close()
    try:
        proc = subprocess.run([sys.executable, os.path.join(PROJECT_DIR, "scripts", "validate-headless-deploy.py"),
                               "--binary", binary, "--json", out.name],
                              capture_output=True, text=True, timeout=420)
        try:
            steps = json.load(open(out.name))
        except (OSError, ValueError):
            steps = []
    except subprocess.TimeoutExpired:
        return "fail", "validation timed out after 420s"
    finally:
        try:
            os.unlink(out.name)
        except OSError:
            pass
    summary = ", ".join(f"{s['step']}={s['status']}" for s in steps)
    failed = [s for s in steps if s["status"] == "FAIL"]
    if proc.returncode != 0 or failed or len(steps) < 9:
        detail = "; ".join(f"{s['step']}: {s['detail']}" for s in failed) or proc.stdout[-400:] + proc.stderr[-400:]
        return "fail", f"{summary or 'no steps'} | {detail}"
    return "pass", summary
