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


@test("http: newClient prewarms TLS state", "Windows")
def test_new_client_helper_seeds():
    src = _read("src/core/http.zig")
    if not src:
        return "fail", "src/core/http.zig missing"
    m = _re.search(r"pub fn newClient\(\)[^{]*\{(.*?)\n\}", src, _re.S)
    if not m:
        return "fail", "core/http.zig has no pub fn newClient()"
    if "prewarmTls(" not in m.group(1):
        return "fail", "newClient() does not prewarm TLS — the null unwrap is back"
    return "pass", "newClient() prewarms CA bundle + now"


@test("http: shared client prewarms TLS state", "Windows")
def test_shared_client_seeds():
    src = _read("src/core/http.zig")
    m = _re.search(r"fn sharedClient\(\)[^{]*\{(.*?)\n\}", src, _re.S)
    if not m:
        return "fail", "core/http.zig has no fn sharedClient()"
    if "prewarmTls(" not in m.group(1):
        return "fail", "sharedClient() no longer prewarms g_client's TLS state"
    return "pass", "sharedClient() prewarms g_client TLS state"


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


# ── 5. runtime option correctness ───────────────────────────────────────────

@test("mpv: reconnect_on_http_error is set once, not twice", "Windows")
def test_reconnect_option_single_key():
    # stream-lavf-o is a KEY-VALUE list. The option used to appear twice —
    # "…reconnect_on_http_error=4xx,reconnect_on_http_error=5xx" — so ffmpeg
    # kept only the LAST write and 4xx reconnects were silently off: one 403/404
    # on an IPTV segment ended the stream instead of retrying ("IPTV barely
    # works, lots of buffering", issue #21). A comma inside a value needs mpv's
    # %<len>% escape. Verified against mpv 0.41: a wrong length is a hard parse
    # error ("Invalid length 99 for 'stream-lavf-o'"), so the escape is checked.
    src = _read("src/player/player.zig")
    lines = [ln for ln in src.splitlines()
             if "stream-lavf-o" in ln and not ln.lstrip().startswith("//")]
    if not lines:
        return "fail", "player.zig no longer sets stream-lavf-o"
    for ln in lines:
        if ln.count("reconnect_on_http_error=") > 1:
            return "fail", "reconnect_on_http_error set twice — ffmpeg keeps only the last"
        if "reconnect_on_http_error=" in ln and "%7%4xx,5xx" not in ln:
            return "fail", "reconnect_on_http_error must use the %7%4xx,5xx escape"
    return "pass", "reconnect_on_http_error set once, comma-escaped as %7%4xx,5xx"


@test("docker: S1 gate reads DT_NEEDED, not ldd", "Windows")
def test_elf_needed_probe():
    import subprocess
    script = _os.path.join(PROJECT_DIR, "scripts", "elf-needed.py")
    if not _os.path.exists(script):
        return "fail", "scripts/elf-needed.py missing — the S1 gate has no probe"
    # It must FAIL on a non-ELF input rather than print nothing and exit 0,
    # which is what would make the CI gate pass vacuously.
    r = subprocess.run(["python3", script, __file__], capture_output=True, text=True)
    if r.returncode == 0:
        return "fail", "elf-needed.py exits 0 on a non-ELF file — gate would pass vacuously"
    if r.stdout.strip():
        return "fail", "elf-needed.py printed libraries for a non-ELF file"
    return "pass", "elf-needed.py fails closed on unreadable input"


# ── 6. cross-platform process/paths (Suwayomi + sidecars) ───────────────────

@test("portability: no hardcoded /dev/null in spawned argv", "Windows")
def test_no_hardcoded_devnull():
    # Windows has no /dev/null: curl resolves it against the CWD, fails to
    # create dev\null and exits non-zero — so `curl -o /dev/null -w %{http_code}`
    # reports FAILURE for a healthy server. That is how the embedded Suwayomi
    # server could never be detected as running on Windows.
    offenders = []
    for rel, text in _zig_sources():
        if rel.endswith("core/io_global.zig"):
            continue  # defines devNull()
        for i, ln in enumerate(_strip_comments(text).splitlines(), 1):
            if '"/dev/null"' in ln:
                offenders.append(f"{rel}:{i}")
    if offenders:
        return "fail", ("hardcoded /dev/null in argv (breaks on Windows): "
                        + ", ".join(offenders) + " — use io_global.devNull()")
    return "pass", "every spawned argv uses io_global.devNull()"


@test("portability: no raw pkill outside io_global", "Windows")
def test_no_raw_pkill():
    # pkill does not exist on Windows, so every cleanup path using it was a
    # silent no-op there — orphaning the Suwayomi JVM (166 MB), the nova2
    # workers, and the voice sidecars on exit.
    offenders = []
    for rel, text in _zig_sources():
        if rel.endswith("core/io_global.zig"):
            continue  # the one sanctioned implementation
        for i, ln in enumerate(_strip_comments(text).splitlines(), 1):
            if '"pkill"' in ln or '"killall"' in ln:
                offenders.append(f"{rel}:{i}")
    if offenders:
        return "fail", ("raw pkill/killall (no-op on Windows, orphans the child): "
                        + ", ".join(offenders)
                        + " — use io_global.killByCommandLine()/killByName()")
    return "pass", "all process kills route through the portable helpers"


@test("portability: kill helpers cover all three platforms", "Windows")
def test_kill_helpers_shape():
    src = _read("src/core/io_global.zig")
    m = _re.search(r"pub fn killByCommandLine\(.*?\n\}", src, _re.S)
    if not m:
        return "fail", "io_global has no killByCommandLine()"
    body = m.group(0)
    if "Win32_Process" not in body or "CommandLine" not in body:
        return "fail", "killByCommandLine has no Windows path (taskkill cannot filter on command line)"
    if "pkill" not in body:
        return "fail", "killByCommandLine lost its POSIX path"
    if '"-9"' not in body:
        return "fail", "killByCommandLine dropped force/SIGKILL — llama-server needs it"
    n = _re.search(r"pub fn killByName\(.*?\n\}", src, _re.S)
    if not n or "taskkill" not in n.group(0):
        return "fail", "killByName has no Windows path"
    return "pass", "killByCommandLine + killByName both cover Windows and POSIX"


@test("suwayomi: Java hint is per-platform", "Windows")
def test_suwayomi_java_hint():
    src = _read("src/services/suwayomi_server.zig")
    m = _re.search(r"if \(!hasJava\(\)\) \{(.*?)\n    \}", src, _re.S)
    if not m:
        return "fail", "suwayomi_server has no hasJava() guard"
    body = m.group(1)
    if "brew" in body and ".macos" not in body:
        return "fail", "Java hint tells every platform to use brew"
    for tag in (".macos", ".windows"):
        if tag not in body:
            return "fail", f"Java hint has no {tag} branch"
    return "pass", "Java install hint branches per platform"


@test("suwayomi: data dir resolves on all three platforms", "Windows")
def test_suwayomi_data_dir():
    src = _read("src/services/suwayomi_server.zig")
    m = _re.search(r"fn dataDir\(.*?\n\}", src, _re.S)
    if not m:
        return "fail", "suwayomi_server has no dataDir()"
    body = m.group(0)
    checks = {
        "macOS Application Support": "Library/Application Support" in body,
        "Windows APPDATA": "APPDATA" in body,
        "Linux XDG/.local": "XDG_DATA_HOME" in body and ".local/share" in body,
        "USERPROFILE fallback": "USERPROFILE" in body,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "dataDir missing: " + ", ".join(bad)
    return "pass", "dataDir covers macOS, Windows and Linux"
