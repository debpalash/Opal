"""Windows portability regressions — GitHub issue #21 ("Crashes on almost anything").

Every check here is a source-level guard rather than a runtime assertion: the
bugs are all Windows-only, and CI runs this suite on macOS/Linux, so the only
way to keep them fixed is to assert the *shape* of the code that fixes them.

The four root causes, all invisible on a mac dev box:

1. std.http.Client.now left null. Client.request() only seeds `now` when the
   INITIAL url is https; an http->https redirect reaches Tls.create via
   Request.redirect() -> client.connect() and does `client.now.?`. That is a
   null unwrap: a panic in ReleaseSafe (Linux + Windows releases) and silent UB
   in ReleaseFast (the macOS release). Hence "crashes on almost anything" on
   Windows while macOS looked fine.
2. CSPRNG seeded by reading "/dev/urandom", which does not exist on Windows —
   so the remote API token, the content-cache key and the auth-store salt could
   never be generated there, and stream_proxy silently fell back to a guessable
   time/pid seed.
3. mpv `sub-add "<path>"` via mpv_command_string: backslashes in a Windows path
   are parsed as string escapes ("Broken string escapes" in the user's log), so
   subtitles never loaded.
4. Release packages shipped the binary + DLLs but none of the runtime resource
   payload (engines/, scripts/, web/, plugins-manifest.json), so torrent search
   returned nothing and the Plugins tab was empty.

See tests/features/harness.py for the shared @test decorator + PROJECT_DIR."""
import os as _os
import re as _re

from .harness import *  # noqa: F401,F403


def _read(rel):
    fp = _os.path.join(PROJECT_DIR, rel)
    return open(fp, encoding="utf-8", errors="replace").read() if _os.path.exists(fp) else ""


def _zig_sources():
    """Every .zig file under src/, as (relpath, text)."""
    out = []
    src = _os.path.join(PROJECT_DIR, "src")
    for root, _dirs, files in _os.walk(src):
        for fn in files:
            if not fn.endswith(".zig"):
                continue
            fp = _os.path.join(root, fn)
            rel = _os.path.relpath(fp, PROJECT_DIR)
            out.append((rel, open(fp, encoding="utf-8", errors="replace").read()))
    return out


def _strip_comments(text):
    return "\n".join(ln for ln in text.splitlines() if not ln.lstrip().startswith("//"))


# ── 1. the crash ────────────────────────────────────────────────────────────

@test("http: no unseeded std.http.Client construction", "Windows")
def test_http_client_now_seeded():
    # THE issue #21 CRASH. A bare `std.http.Client{ … }` leaves `now` null.
    # core/http.zig::newClient is the only sanctioned constructor.
    offenders = []
    for rel, text in _zig_sources():
        for i, ln in enumerate(_strip_comments(text).splitlines(), 1):
            if "std.http.Client{" in ln:
                offenders.append(f"{rel}:{i}")
    if offenders:
        return "fail", (
            "unseeded http.Client (null `now` -> panic on http->https redirect in "
            "ReleaseSafe): " + ", ".join(offenders) + " — use core/http.zig newClient()"
        )
    return "pass", "all http.Client construction routes through newClient()"


@test("http: newClient seeds .now", "Windows")
def test_new_client_helper_seeds():
    src = _read("src/core/http.zig")
    if not src:
        return "fail", "src/core/http.zig missing"
    m = _re.search(r"pub fn newClient\(\)[^{]*\{(.*?)\n\}", src, _re.S)
    if not m:
        return "fail", "core/http.zig has no pub fn newClient()"
    body = m.group(1)
    if ".now" not in body or "Timestamp.now" not in body:
        return "fail", "newClient() does not seed client.now — the null unwrap is back"
    return "pass", "newClient() seeds .now from the realtime clock"


@test("http: shared client still seeds .now", "Windows")
def test_shared_client_seeds():
    src = _read("src/core/http.zig")
    m = _re.search(r"fn sharedClient\(\)[^{]*\{(.*?)\n\}", src, _re.S)
    if not m:
        return "fail", "core/http.zig has no fn sharedClient()"
    if "now" not in m.group(1):
        return "fail", "sharedClient() no longer seeds g_client.now"
    return "pass", "sharedClient() seeds g_client.now"


# ── 2. entropy ──────────────────────────────────────────────────────────────

@test("csprng: no direct /dev/urandom reads", "Windows")
def test_no_dev_urandom():
    offenders = []
    for rel, text in _zig_sources():
        for i, ln in enumerate(_strip_comments(text).splitlines(), 1):
            if "/dev/urandom" in ln:
                offenders.append(f"{rel}:{i}")
    if offenders:
        return "fail", (
            "/dev/urandom read in code (absent on Windows -> no api token, no cache "
            "key): " + ", ".join(offenders) + " — use io_global.randomSecure()"
        )
    return "pass", "entropy comes from io_global.randomSecure() everywhere"


@test("csprng: io_global.randomSecure exists and is fail-closed", "Windows")
def test_random_secure_helper():
    src = _read("src/core/io_global.zig")
    m = _re.search(r"pub fn randomSecure\(buf: \[\]u8\) bool \{(.*?)\n\}", src, _re.S)
    if not m:
        return "fail", "io_global has no pub fn randomSecure(buf: []u8) bool"
    body = m.group(1)
    if "randomSecure" not in body:
        return "fail", "randomSecure() does not delegate to std.Io randomSecure"
    if "return false" not in body:
        return "fail", "randomSecure() must report failure rather than a weak seed"
    return "pass", "randomSecure() delegates to std.Io and fails closed"


@test("csprng: token generation refuses a weak fallback", "Windows")
def test_token_fail_closed():
    src = _read("src/services/remote.zig")
    m = _re.search(r"fn seedCsprng\(\) bool \{(.*?)\n\}", src, _re.S)
    if not m:
        return "fail", "remote.zig has no fn seedCsprng() bool"
    body = m.group(1)
    if "randomSecure" not in body:
        return "fail", "seedCsprng() does not use the portable entropy source"
    if "timestamp" in body.lower():
        return "fail", "seedCsprng() mixes in a timestamp — bearer tokens must not be guessable"
    return "pass", "seedCsprng() uses randomSecure() and never falls back to a clock"


# ── 3. mpv sub-add ──────────────────────────────────────────────────────────

@test("mpv: sub-add uses argv, not string escaping", "Windows")
def test_sub_add_argv():
    # `sub-add "C:\Users\…"` -> mpv parses \U, \A, … as escapes and rejects the
    # command, so subtitles never load on Windows.
    offenders = []
    for rel, text in _zig_sources():
        for i, ln in enumerate(_strip_comments(text).splitlines(), 1):
            if "sub-add" in ln and "mpvSubAdd" not in ln and '\\"' in ln:
                offenders.append(f"{rel}:{i}")
    if offenders:
        return "fail", (
            "sub-add built as a quoted command string (backslash paths break on "
            "Windows): " + ", ".join(offenders) + " — use c.mpvSubAdd()"
        )
    return "pass", "every sub-add goes through the argv helper"


@test("mpv: mpvSubAdd helper uses mpv_command argv form", "Windows")
def test_sub_add_helper():
    src = _read("src/core/c.zig")
    m = _re.search(r"pub fn mpvSubAdd\(.*?\n\}", src, _re.S)
    if not m:
        return "fail", "core/c.zig has no pub fn mpvSubAdd()"
    body = m.group(0)
    if "mpv_command_string" in body:
        return "fail", "mpvSubAdd uses mpv_command_string — that is the escaping bug"
    if "mpv_command(" not in body or "argv" not in body:
        return "fail", "mpvSubAdd does not use the mpv_command argv form"
    return "pass", "mpvSubAdd passes a pre-split argv (no unescaping)"


# ── 4. packaging ────────────────────────────────────────────────────────────

_RESOURCES = ["engines", "camoufox_bridge.py", "plugins-manifest.json", "web/index.html"]


@test("packaging: Windows staging ships the resource payload", "Windows")
def test_windows_stages_resources():
    yml = _read(".github/workflows/release.yml")
    if not yml:
        return "fail", ".github/workflows/release.yml missing"
    m = _re.search(r"Stage portable payload.*?(?=\n      - name:)", yml, _re.S)
    if not m:
        return "fail", "could not locate the Windows staging step"
    step = m.group(0)
    missing = [r for r in _RESOURCES if r not in step]
    if missing:
        return "fail", (
            "Windows package ships no " + ", ".join(missing) +
            " — torrent search returns nothing and the Plugins tab is empty"
        )
    if "staging/engines/nova2.py" not in step:
        return "fail", "staging step does not assert engines/nova2.py landed"
    return "pass", "Windows staging ships engines/, scripts/, web/ + manifest (asserted)"


@test("packaging: Linux package ships the resource payload", "Windows")
def test_linux_ships_resources():
    yml = _read("packaging/nfpm.yaml")
    if not yml:
        return "fail", "packaging/nfpm.yaml missing"
    missing = [r for r in _RESOURCES if r not in yml]
    if missing:
        return "fail", "Linux .deb/.rpm ships no " + ", ".join(missing)
    if "/usr/lib/opal/engines" not in yml:
        return "fail", "engines/ must install where detectResourceRoot probes (/usr/lib/opal)"
    return "pass", "nfpm ships the resource payload under /usr/lib/opal"


@test("packaging: macOS bundle ships the browser bridge", "Windows")
def test_macos_ships_bridge():
    sh = _read("scripts/build-app.sh")
    if "camoufox_bridge.py" not in sh:
        return "fail", ".app bundle omits camoufox_bridge.py — scraper sources are dead"
    return "pass", ".app bundles scripts/camoufox_bridge.py"


@test("resources: detectResourceRoot probes the install prefix", "Windows")
def test_resource_root_probes_prefix():
    src = _read("src/main.zig")
    m = _re.search(r"fn detectResourceRoot\(\) void \{(.*?)\n\}", src, _re.S)
    if not m:
        return "fail", "main.zig has no fn detectResourceRoot()"
    body = m.group(1)
    if "/usr/lib/opal/" not in body:
        return "fail", "detectResourceRoot does not probe /usr/lib/opal (distro install)"
    return "pass", "detectResourceRoot falls back to the distro install prefix"


@test("paths: bridge lookup is Windows-aware", "Windows")
def test_bridge_path_windows_aware():
    src = _read("src/services/browser.zig")
    m = _re.search(r"fn getBridgePath\(\) \?\[\]const u8 \{(.*?)\n\}", src, _re.S)
    if not m:
        return "fail", "browser.zig has no fn getBridgePath()"
    body = _strip_comments(m.group(1))
    if '.config/opal' in body:
        return "fail", "getBridgePath hardcodes ~/.config/opal — wrong on Windows"
    if 'getenv("HOME")' in body:
        return "fail", 'getBridgePath uses getenv("HOME") — unset on Windows'
    if "configDir" not in body:
        return "fail", "getBridgePath does not use paths.configDir()"
    return "pass", "getBridgePath uses paths.configDir() + the resource root"
