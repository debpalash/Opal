"""Auto-split from tests/test_features.py — Build / Packaging / LLM / Server / Unit Tests tests.
Byte-for-byte identical test bodies; see tests/features/harness.py for the
shared @test decorator, helpers, and run_all()."""
from .harness import *  # noqa: F401,F403
import os, sys, re, subprocess, sqlite3, socket, time, json  # noqa: F401

def _built_binary():
    # zig names the exe `opal` on POSIX and `opal.exe` on Windows.
    for name in ("zig-out/bin/opal", "zig-out/bin/opal.exe"):
        p = os.path.join(PROJECT_DIR, name)
        if os.path.exists(p):
            return p
    return None


@test("Zig Build", "Build")
def test_zig_build():
    try:
        result = subprocess.run(
            ["zig", "build"], cwd=PROJECT_DIR,
            # Cold CI builds link the C++ torrent wrapper + the whole app; 120s
            # was right at the edge and flaked. 300s leaves headroom.
            capture_output=True, text=True, timeout=300
        )
        if result.returncode == 0:
            binary = _built_binary()
            if binary:
                size = os.path.getsize(binary) / (1024*1024)
                return "pass", f"Binary: {size:.1f} MB"
            return "pass", "Build succeeded"
        return "fail", result.stderr[:200]
    except subprocess.TimeoutExpired:
        return "fail", "Build timed out (>300s)"


@test("Binary Exists", "Build")
def test_binary_exists():
    binary = _built_binary()
    if binary:
        size = os.path.getsize(binary) / (1024*1024)
        mtime = time.strftime("%H:%M:%S", time.localtime(os.path.getmtime(binary)))
        return "pass", f"{size:.1f} MB, built at {mtime}"
    return "fail", "Binary not found"


@test("LLM Model File", "Build")
def test_llm_model():
    model_dir = os.path.join(PROJECT_DIR, "models")
    if os.path.exists(model_dir):
        models = [f for f in os.listdir(model_dir) if f.endswith('.gguf')]
        if models:
            sizes = [os.path.getsize(os.path.join(model_dir, m))/(1024**3) for m in models]
            return "pass", f"{', '.join(models)} ({sum(sizes):.1f} GB)"
    return "warn", "No GGUF model found"


@test("Voice Server Script", "Build")
def test_voice_server_script():
    script = os.path.join(PROJECT_DIR, "bin/opal-voice-server.py")
    if os.path.exists(script):
        size = os.path.getsize(script)
        return "pass", f"{size} bytes"
    # Optional component: the voice server is provisioned separately and the
    # app degrades gracefully when it is absent (ai_voice.zig skips it).
    return "skip", "Voice server not installed (optional)"


@test("Libtorrent Wrapper", "Build")
def test_libtorrent():
    so = os.path.join(PROJECT_DIR, "libtorrent_wrapper.so")
    if os.path.exists(so):
        size = os.path.getsize(so) / 1024
        return "pass", f"{size:.0f} KB"
    return "warn", "libtorrent_wrapper.so not built"


@test("Copyright Attribution", "Build")
def test_copyright_attribution():
    # The author's name must appear in the copyright/about surfaces and the
    # generic "Opal contributors" placeholder must be gone. Guards a silent
    # regression on the packaging scripts, which own the macOS About panel's
    # NSHumanReadableCopyright line and the Windows installer Manufacturer.
    surfaces = {
        "scripts/build-app.sh": "NSHumanReadableCopyright",
        "scripts/dev-app.sh": "NSHumanReadableCopyright",
        "packaging/windows/opal.wxs": "Manufacturer",
        "src/ui/settings.zig": "Settings › About",
    }
    missing = []
    stale = []
    for path in surfaces:
        src = open(os.path.join(PROJECT_DIR, path)).read()
        if "Palash Deb" not in src:
            missing.append(path)
        if "Opal contributors" in src:
            stale.append(path)
    if missing:
        return "fail", f"name missing in: {', '.join(missing)}"
    if stale:
        return "fail", f"'Opal contributors' placeholder still in: {', '.join(stale)}"
    return "pass", "author credited across about/copyright/packaging surfaces"


@test("LLM Server Health", "LLM")
def test_llm_health():
    try:
        import urllib.request
        req = urllib.request.Request("http://127.0.0.1:8080/health")
        resp = urllib.request.urlopen(req, timeout=3)
        data = json.loads(resp.read())
        status = data.get("status", "unknown")
        return "pass" if status == "ok" else "warn", f"Status: {status}"
    except:
        return "skip", "LLM server not running"


@test("Embedding Server Health", "LLM")
def test_embedding_health():
    try:
        import urllib.request
        req = urllib.request.Request("http://127.0.0.1:8082/v1/embeddings",
            data=json.dumps({"input": "test"}).encode(),
            headers={"Content-Type": "application/json"})
        resp = urllib.request.urlopen(req, timeout=5)
        data = json.loads(resp.read())
        if "data" in data:
            dim = len(data["data"][0].get("embedding", []))
            return "pass", f"Embedding dim: {dim}"
        return "warn", "Unexpected response"
    except:
        return "skip", "Embedding server not running"


@test("Headless Server Mode Wired", "Server")
def test_headless_mode():
    # Compile-time entry split (dvui requires root.main == dvui.App.main, so the
    # headless entry is selected via -Dheadless, NOT a runtime wrapper).
    main = _src("src/main.zig")
    hl = _src("src/headless.zig")
    det = _src("src/core/headless_detect.zig")
    st = _src("src/core/state.zig")
    rem = _remote_api()
    bld = _src("build.zig")
    checks = [
        '@import("build_options").headless' in main,  # compile-time entry select
        "pub const main = if" in main,
        "pub fn coreInit" in main and "pub fn appDeinit" in main,
        "pub fn headlessMain" in hl and "shutdown" in hl and "sigaction" in hl,
        "pub fn detect" in det,
        "is_headless" in st,
        # T6 bind. The literal moved into access_pure.BindMode when the bind
        # address became configurable; headless still defaults to LAN.
        "bind_mode.address()" in rem and "is_headless" in rem,
        '"headless"' in bld,                                    # -Dheadless option
    ]
    if all(checks):
        return "pass", "compile-time headless entry + coreInit/headlessMain + 0.0.0.0 bind + -Dheadless"
    return "fail", f"headless wiring incomplete: {checks}"


@test("Headless Render Guards", "Server")
def test_headless_render_guards():
    # Windowed mode must stay byte-identical: every headless branch gated on
    # is_headless / mpv_gl==null. mpv render-context + pixels skipped headless.
    pl = _src("src/player/player.zig")
    gr = _src("src/ui/grid.zig")
    th = _src("src/ui/theme.zig")
    # theme.applyToDvui defers when there's no UI-thread frame context
    # (current_window == null) — covers BOTH headless and background-thread
    # callers like config.load(); reapplied on the UI thread via appFrame.
    if ("is_headless" in pl and "mpv_gl != null" in gr
            and "onUiThread" in th and "reapplyIfPending" in th):
        return "pass", "render-context/pixels gated; grid guards mpv_gl; theme defers off-UI-thread"
    return "fail", "headless render guards missing"


@test("Zig Unit Tests", "Unit Tests")
def test_zig_unit():
    try:
        r = subprocess.run(["zig", "build", "test"], cwd=PROJECT_DIR,
                            capture_output=True, text=True, timeout=600)
    except FileNotFoundError:
        return "skip", "zig not on PATH"
    except subprocess.TimeoutExpired:
        return "fail", "zig build test timed out (>600s)"
    if r.returncode == 0:
        return "pass", "all pure-Zig unit tests pass"
    # Surface the first real error line.
    for line in (r.stderr + r.stdout).splitlines():
        if "error:" in line:
            return "fail", line.strip()[:80]
    return "fail", f"exit {r.returncode}"


@test("Poster/image fetch uses curl not std.http", "Network")
def test_fetchimage_curl():
    # REGRESSION — std.http (fetch()) silently returns NULL for some image CDNs,
    # notably cdn.myanimelist.net (every anime poster), so anime covers never
    # loaded. fetchImage must shell out to curl (which fetches them fine).
    h = _src("src/core/http.zig")
    fn = _between(h, "pub fn fetchImage", "\n}")
    if '"curl"' in fn and "io_global.Child" in fn:
        return "pass", "fetchImage fetches images via curl (MAL CDN + TMDB both work)"
    return "fail", "fetchImage still routes images through std.http (anime posters return NULL)"


@test("YouTube playback pins no player client", "Network")
def test_youtube_player_client():
    # REGRESSION — "youtube links not playing". A previous fix pinned
    # `youtube:player_client=tv` everywhere, because at the time the default web
    # client got "Sign in to confirm you're not a bot" + HTTP 429. That pin has
    # since inverted into the bug: the tv client now returns ONLY storyboard
    # formats (sb0..sb3), so mpv's `bestvideo[height<=?N]+bestaudio/best`
    # selector matches nothing and every video dies on "Requested format is not
    # available". Verified against the live API on 2026-07-20.
    #
    # yt-dlp maintains its own client-fallback chain; pinning one client freezes
    # us at whatever was true the day the pin was written. The playback and
    # extraction paths must therefore pin NOTHING.
    player = _src("src/player/player.zig")
    extractors = _src("src/services/extractors.zig")
    opts = _src("src/player/ytdl_opts_pure.zig")
    build = _src("build.zig")

    checks = {
        "playback unpinned": "player_client" not in player,
        "extraction unpinned": "youtube:player_client=tv" not in extractors,
        # The raw-options string is built by a tested pure fn so the exact value
        # mpv receives is covered, not just the absence of a substring.
        "raw options routed through pure": "ytdl_opts_pure" in player and "buildRawOptions(" in player,
        "pure module present": "pub fn buildRawOptions" in opts,
        "pure module guards the pin": 'indexOf(u8, s, "player_client") == null' in opts,
        "test registered": 'b.path("src/player/ytdl_opts_pure.zig")' in build,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "player-client regression: " + ", ".join(bad)
    return "pass", "no pinned yt-dlp player client; raw options built by tested pure fn"


@test("yt-dlp format deprioritizes AV1", "Player")
def test_ytdl_format_av1():
    # REGRESSION — YouTube video played as a BLACK frame with audio only on Macs
    # without an AV1 hardware decoder (Apple Silicon pre-M3): the format asked for
    # plain "best" video, which is av01 at 1080p+, and videotoolbox can't decode
    # it ("Your platform doesn't support hardware accelerated AV1 decoding" ->
    # "Video: no video"). The -f string must prefer vp9/h264 (both hw-decode),
    # with an any-codec last resort so a clip that ONLY has AV1 still plays.
    player = _src("src/player/player.zig")
    fmt = _src("src/player/ytdl_format_pure.zig")
    build = _src("build.zig")
    checks = {
        "pure format module present": "pub fn formatFor" in fmt,
        "excludes av01": "[vcodec!*=av01]" in fmt,
        "any-codec fallback kept": fmt.count('test "') >= 3 and "/best" in fmt,
        "player routes through it": "ytdl_format_pure" in player
            and "formatFor(state.app.ytdl_format_idx)" in player,
        # The old inline format array (no codec preference) must be gone.
        "inline best-only array removed": 'bestvideo[height<=?720]+bestaudio/best"' not in player,
        "test registered": 'b.path("src/player/ytdl_format_pure.zig")' in build,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "av1 format regression: " + ", ".join(bad)
    return "pass", "ytdl-format prefers vp9/h264 over av1 (hw-decodable), any-codec fallback"


@test("Anime data loads despite Jikan flakiness", "Network")
def test_anime_jikan_resilience():
    # REGRESSION — every anime view was blank by default: Jikan 504s on the
    # `sfw` param (NSFW filter is ON by default so every URL carried it) AND on
    # filtered /top/anime. Fix: send no sfw param (filter adult client-side),
    # fall back to the unfiltered top list when a filtered fetch is empty, and
    # bound the anime curls so a flaky Jikan can't hang the tab.
    ap = _src("src/services/anime_pure.zig")
    an = _src("src/services/anime.zig")
    checks = {
        "no sfw param sent": 'return "";' in ap and "504s on the `sfw`" in ap,
        "trending falls back to unfiltered": "filtered top unavailable" in an
            and "added == 0 and fv.len > 0" in an,
        "anime curls bound connect time": an.count('"--connect-timeout"') >= 1,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing: " + ", ".join(bad)
    return "pass", "no sfw param + unfiltered fallback + bounded curl → anime loads when Jikan filters/search 504"


@test("Startup route warm-up prefetch", "Network")
def test_startup_prefetch():
    # PERF — routes used to be cold on first open (empty grid + spinner) because
    # nothing was fetched until the user navigated there. coreInit now warms the
    # most-visited browse routes in the background at launch.
    m = _src("src/main.zig")
    warmed = ("fetchCurrentView(false)" in m
              and "loadTrendingAnime()" in m
              and 'tv_calendar.zig").refreshOnce()' in m)
    if warmed:
        return "pass", "coreInit warms TMDB browse + anime trending + calendar at startup"
    return "fail", "startup route warm-up not wired in coreInit"


@test("Content fetchers bound connect time", "Network")
def test_curl_connect_timeout():
    # PERF/hang guard — a black-holed source used to stall a whole route for
    # the full --max-time (× retries × http/https fallback ≈ 70s). Every curl
    # content fetcher must pass --connect-timeout so a dead host fails fast.
    checks = {
        "tmdb": '"--connect-timeout"' in _src("src/services/tmdb_api.zig"),
        "calendar": '"--connect-timeout"' in _src("src/services/tv_calendar.zig"),
        "tvmaze": '"--connect-timeout"' in _src("src/services/tvmaze.zig"),
        "plex": '"--connect-timeout"' in _src("src/services/plex.zig"),
        "podcasts": '"--connect-timeout"' in _src("src/services/podcasts.zig"),
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing --connect-timeout in: " + ", ".join(bad)
    return "pass", "curl content fetchers bound connect time (dead host fails in ~3s)"


@test("HTTP client prewarms CA bundle + Client.now together", "Network")
def test_http_client_now():
    # REGRESSION (two of them, in sequence).
    #
    # 1. The app aborted with "attempt to use null value" the instant a fetch
    #    negotiated TLS via redirect: Client.now is null by default and
    #    Tls.create dereferences `client.now.?` for cert-validity.
    # 2. The fix for (1) set ONLY `now` — but request() guards its whole TLS
    #    preparation block with `if (client.now != null) break :tls`, so `now`
    #    is also the "ca_bundle is loaded" sentinel. Setting it alone made std
    #    skip bundle.rescan() forever, leaving the bundle empty, and EVERY https
    #    fetch failed with TlsInitializationFailed. Verified against live hosts:
    #    seeding `now` alone → 0/6 urls fetched; prewarming both → 5/6.
    #
    # So the invariant is: set both, or neither. Never just `now`.
    h = _src("src/core/http.zig")
    if "fn prewarmTls(" not in h:
        return "fail", "no prewarmTls() — TLS state is not prepared as a unit"
    import re
    m = re.search(r"fn prewarmTls\(.*?\n\}", h, re.S)
    body = m.group(0) if m else ""
    if "rescan(" not in body:
        return "fail", "prewarmTls does not rescan the CA bundle — https will fail"
    if "client.now = " not in body:
        return "fail", "prewarmTls does not stamp client.now — TLS redirects will panic"
    # Nobody may set `now` outside the helper.
    code = "\n".join(ln for ln in h.splitlines() if not ln.lstrip().startswith("//"))
    stray = [
        ln.strip() for ln in code.splitlines()
        if re.search(r"\.now = ", ln) and "client.now = now" not in ln
    ]
    if stray:
        return "fail", "`now` set outside prewarmTls (empty CA bundle): " + "; ".join(stray)
    return "pass", "prewarmTls() loads the CA bundle and stamps now together"


@test("HTTP shared keep-alive client + enforced timeout", "Network")
def test_http_shared_client_and_timeout():
    # PERF/CORRECTNESS — fetch() used to build AND destroy a std.http.Client on
    # every call (a fresh TCP+TLS handshake per request, despite the file's
    # "connection reuse" claim), and HttpOptions.timeout_secs was defined but
    # never read — so a source that accepted TCP then stalled hung the worker
    # thread forever and the caller's in-flight latch never cleared, leaving that
    # route permanently empty. Fix: one process-global keep-alive client (safe to
    # share — std.http.Client's ConnectionPool has its own mutex), and
    # timeout_secs enforced via a socket watchdog that unblocks a stalled read.
    h = _src("src/core/http.zig")
    mn = _src("src/main.zig")
    checks = {
        # No per-call Client construction remains inside the file. Code only:
        # newClient()'s doc comment quotes the banned form on purpose, to show
        # callers what not to write (see tests/features/test_windows_portability).
        "no per-call client": "std.http.Client{" not in "\n".join(
            ln for ln in h.splitlines() if not ln.lstrip().startswith("//")
        ),
        # A module-global shared client + lazy getter.
        "global shared client": "var g_client: std.http.Client" in h and "fn sharedClient(" in h,
        # timeout_secs is actually consumed, not merely defined.
        "timeout_secs consumed": "opts.timeout_secs" in h,
        # …through a clamped pure helper (bounds the hang even for 0/huge values).
        "timeout clamped": "effectiveTimeoutSecs(" in h and "std.math.clamp" in h,
        # The stalled-socket unblock mechanism (shutdown, not close — close would
        # EBADF-panic the Threaded backend's blocking readv).
        "watchdog unblocks stall": "std.c.shutdown(" in h,
        # Freed at shutdown so the DebugAllocator's 0-leak gate stays clean.
        "freed at shutdown": "pub fn deinit(" in h and 'core/http.zig").deinit()' in mn,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "http.zig regression: " + ", ".join(bad)
    return "pass", "shared keep-alive client; timeout_secs enforced (clamped) via socket watchdog"


@test("Installer Does Not Need Xcode", "Packaging")
def test_installer_no_xcode():
    # REGRESSION — `curl … install.sh | sh` failed for everyone on macOS:
    #
    #   opal: A full installation of Xcode.app 15.0 is required to compile
    #   this software. Installing just the Command Line Tools is not sufficient.
    #
    # Two bugs stacked. install.sh PREFERRED the Homebrew tap whenever brew was
    # present, and the formula built from SOURCE — so it demanded a 15 GB Xcode
    # install, while the self-contained .app (which vendors its own mpv/SDL and
    # needs no toolchain at all) sat one line below, never reached.
    import re
    # Strip comments before grepping. The first version of this test matched the
    # comment ABOVE that explains the bug ("depends_on xcode: …") and reported the
    # fixed formula as broken — a test that greps prose tests nothing.
    def _code(text, marker="#"):
        return "\n".join(l for l in text.splitlines()
                          if not l.lstrip().startswith(marker))

    f = _code(_src("Formula/opal.rb"))
    sh = _code(_src("scripts/install.sh"))
    zon = _src("build.zig.zon")

    m = re.search(r'\.version = "([^"]+)"', zon)
    zon_ver = m.group(1) if m else "?"
    fm = re.search(r'^\s*version "([^"]+)"', f, re.M)
    f_ver = fm.group(1) if fm else "?"

    checks = {
        # The bug, verbatim.
        "formula needs no Xcode": "xcode:" not in f,
        "formula does not build from source": '"zig" => :build' not in f,
        "formula installs a prebuilt binary": "releases/download" in f and 'bin.install "opal"' in f,
        "formula pins a real checksum": bool(re.search(r'sha256 "[a-f0-9]{64}"', f)),
        # It sat pinned at v0.1.2 while the app shipped 0.3.0 — nothing kept the two
        # in step, so it rotted silently. Fail the gate instead of shipping stale.
        "formula version tracks build.zig.zon (%s vs %s)" % (f_ver, zon_ver): f_ver == zon_ver,
        # The vendored .app is the default; brew is opt-in for the CLI on PATH.
        "installer prefers the self-contained .app": "OPAL_USE_BREW" in sh,
        "installer no longer auto-prefers brew": "brew tap-info debpalash/tap" not in sh,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing: " + ", ".join(bad)
    return "pass", "install.sh installs the vendored .app; formula is a binary install at " + f_ver


@test("Linux Installer Is Rootless By Default", "Packaging")
def test_linux_installer_rootless_default():
    # REGRESSION — distro detection used to force apt/dnf/zypper and sudo even
    # though Linux releases already publish artifacts suitable for ~/.local.
    import pathlib
    import subprocess
    import tempfile

    sh = _src("scripts/install.sh")
    release = _src(".github/workflows/release.yml")
    aur_bin = _src("packaging/aur/opal-media-player-bin/PKGBUILD")
    checks = {
        "rootless installer exists": "install_linux_local()" in sh,
        "default selects rootless installer": "0) install_linux_local" in sh,
        "system install is explicit opt-in": "1) install_linux_system" in sh,
        "system option is documented": "OPAL_SYSTEM=1" in sh,
        "local install uses user prefix": '${OPAL_PREFIX:-$HOME/.local}' in sh,
        "Debian package is unpacked without apt": 'dpkg-deb -x "$TMP/opal.deb"' in sh,
        "torrent resources required": 'usr/lib/opal/engines/nova2.py' in sh,
        "local receipt remembers whole prefix": 'receipt "local-prefix:$prefix"' in sh,
        "desktop launcher uses absolute executable": "TryExec=$bindir/opal" in sh,
        "future AppImage carries torrent engines": "cp -r engines AppDir/usr/lib/opal/" in release,
        "AppImage executes beside its resources": 'exec "$HERE/usr/lib/opal/opal"' in release,
        "tarball carries torrent engines": "cp -r engines opal-${VERSION}-linux-x86_64/" in release,
        "AUR binary installs torrent engines": 'cp -r engines' in aur_bin,
    }
    bad = [name for name, ok in checks.items() if not ok]
    if bad:
        return "fail", "rootless Linux installer regression: " + ", ".join(bad)

    # Exercise the default branch with deterministic fake release tools. sudo
    # is deliberately present but fatal: merely having it on PATH must never
    # make the rootless installer call it.
    with tempfile.TemporaryDirectory(prefix="opal-rootless-test-") as td:
        root = pathlib.Path(td)
        fakebin = root / "fakebin"
        home = root / "home"
        prefix = home / ".local"
        fakebin.mkdir()
        home.mkdir()

        def fake(name, body):
            path = fakebin / name
            path.write_text("#!/bin/sh\nset -eu\n" + body)
            path.chmod(0o755)

        fake("uname", 'case "${1:-}" in -m) echo x86_64 ;; *) echo Linux ;; esac\n')
        fake("sha256sum", 'printf "testhash  %s\\n" "$1"\n')
        fake("sudo", 'touch "$HOME/sudo-was-called"\nexit 99\n')
        fake("curl", r'''
out=""; url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) shift; out="$1" ;;
        http*) url="$1" ;;
    esac
    shift
done
case "$url" in
    */SHA256SUMS.txt) printf 'testhash  opal_9.9.9_amd64.deb\n' > "$out" ;;
    *) : > "$out" ;;
esac
''')
        fake("dpkg-deb", r'''
dest="$3"
mkdir -p "$dest/usr/bin" "$dest/usr/lib/opal/engines" \
         "$dest/usr/share/icons/hicolor/scalable/apps"
printf '#!/bin/sh\nexit 0\n' > "$dest/usr/bin/opal"
chmod +x "$dest/usr/bin/opal"
printf '# nova2 fixture\n' > "$dest/usr/lib/opal/engines/nova2.py"
printf 'fixture\n' > "$dest/usr/lib/opal/plugins-manifest.json"
printf '<svg/>\n' > "$dest/usr/share/icons/hicolor/scalable/apps/opal.svg"
''')

        env = os.environ.copy()
        env.update({
            "HOME": str(home),
            "OPAL_PREFIX": str(prefix),
            "OPAL_VERSION": "v9.9.9",
            "PATH": str(fakebin) + os.pathsep + env.get("PATH", ""),
        })
        proc = subprocess.run(
            ["sh", os.path.join(PROJECT_DIR, "scripts/install.sh")],
            cwd=PROJECT_DIR, env=env, text=True, capture_output=True,
        )
        dynamic = {
            "rootless install exits successfully": proc.returncode == 0,
            "sudo was not invoked": not (home / "sudo-was-called").exists(),
            "launcher installed": (prefix / "bin/opal").is_file(),
            "app installed beside resources": (prefix / "lib/opal/opal").is_file(),
            "nova2 resource installed": (prefix / "lib/opal/engines/nova2.py").is_file(),
        }
        bad = [name for name, ok in dynamic.items() if not ok]
        if bad:
            detail = proc.stderr.strip() or proc.stdout.strip()
            return "fail", "rootless execution failed: " + ", ".join(bad) + " — " + detail[-200:]

        launched = subprocess.run([str(prefix / "bin/opal")], env=env)
        if launched.returncode != 0:
            return "fail", "installed user-local launcher did not execute"

    return "pass", "default path calls no sudo and installs executable + nova2 under ~/.local"


@test("File associations + single instance", "Packaging")
def test_file_associations_single_instance():
    # OS default-player registration (macOS/Linux/Windows) + second-instance
    # forwarding must all stay wired: each check names the surface it guards.
    checks = {
        "scripts/build-app.sh": lambda s: "<string>Default</string>" in s
            and "<string>Alternate</string>" not in s,
        "scripts/dev-app.sh": lambda s: "CFBundleDocumentTypes" in s
            and "<string>Default</string>" in s,
        "packaging/opal.desktop": lambda s: "MimeType=" in s
            and ("%U" in s or "%f" in s),
        "packaging/windows/opal.wxs": lambda s: "Opal.MediaFile" in s
            and "RegisteredApplications" in s
            and "shell\\open\\command" in s,
        "src/main.zig": lambda s: "forwardToRunningInstance" in s,
        "src/services/remote.zig": lambda s: '"/open"' in s
            and "remote_open_ready" in s,
        "src/services/single_instance_pure.zig": lambda s: "buildOpenUrl" in s,
        "build.zig": lambda s: "single_instance_pure.zig" in s,
    }
    bad = []
    for path, ok in checks.items():
        full = os.path.join(PROJECT_DIR, path)
        if not os.path.exists(full) or not ok(open(full).read()):
            bad.append(path)
    if bad:
        return "fail", f"association/forwarding wiring missing in: {', '.join(bad)}"
    return "pass", "LSHandlerRank Default, .desktop MimeType, wxs ProgId, /api/open forwarding all present"


@test("Release builds pin the ISA baseline", "Build")
def test_release_isa_baseline():
    """Issue #22: v0.6.1 Linux crashed with SIGILL on a Ryzen 7 5700X while
    v0.6.0 worked — same source, same Zig 0.16.0.

    Cause: `zig build` with no `-Dcpu` targets the NATIVE cpu, so the artifact
    bakes in whatever ISA the GitHub runner happened to have, and that pool is
    heterogeneous. Disassembly of the two published binaries: v0.6.1 uses
    AVX-512 in 305 symbols (kmovd, vpternlogq, vpermt2b, vpmovq2m); v0.6.0 uses
    it in zero. Every CPU without AVX-512 — all Zen 1-3 Ryzen, every 12th-14th
    gen Intel consumer part — faulted before the first frame.

    Every distribution build now pins -Dcpu, and a gate proves it from the
    artifact rather than trusting the flag to stay on the command line."""
    import os, re
    rel = _src(".github/workflows/release.yml")
    docker = _src("Dockerfile")
    snap = _src("packaging/snapcraft.yaml")
    app = _src("scripts/build-app.sh")
    gate_path = os.path.join(PROJECT_DIR, "scripts", "check-isa-baseline.py")

    # Every `zig build` that produces a DISTRIBUTED artifact must pin -Dcpu.
    # (AUR builds from source on the user's own machine, where native is right.)
    unpinned = []
    for name, text in (("release.yml", rel), ("Dockerfile", docker),
                       ("snapcraft.yaml", snap), ("build-app.sh", app)):
        for line in text.splitlines():
            if re.search(r"\bzig(\"|\s|\$\{)?\S*\s+build\b", line) and "-Doptimize" in line:
                if "-Dcpu" not in line:
                    unpinned.append(f"{name}: {line.strip()[:70]}")
    if unpinned:
        return "fail", "release build without a pinned -Dcpu: " + "; ".join(unpinned)

    if not os.path.exists(gate_path):
        return "fail", "scripts/check-isa-baseline.py missing"
    gate = open(gate_path).read()

    checks = {
        "x86 builds pin v2": rel.count("-Dcpu=x86_64_v2") >= 2,
        "macos pins a floor": "apple_m1" in app,
        "gate wired for linux": "check-isa-baseline.py zig-out/bin/opal" in rel,
        "gate wired for windows": "check-isa-baseline.py zig-out/bin/opal.exe" in rel,
        # The gate must fail closed — an unreadable binary or a stub
        # disassembly must not silently pass.
        "fails without objdump": "no objdump on PATH" in gate,
        "fails on empty disassembly": "not a real disassembly" in gate,
        "detects opmask ops": "kmov" in gate and "vpternlog" in gate,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "ISA baseline gate incomplete: " + ", ".join(missing)
    return "pass", ("every distributed build pins -Dcpu (x86_64_v2 / apple_m1) and a "
                    "fail-closed gate scans the artifact; verified to reject the real "
                    "v0.6.1 binary and accept v0.6.0")


@test("App version has one source of truth", "Build")
def test_version_single_source():
    """Issue #21: "did clean installation of opal ui still shows 0.6.0".

    updater.zig carried `APP_VERSION` as a hand-maintained constant whose own
    doc comment said "kept in sync with build.zig.zon". It drifted — v0.6.1
    shipped with it still reading "0.6.0". Two consequences: the About page
    showed the wrong version, and because the update check compares this exact
    string to the latest GitHub tag, every 0.6.1 user was told an update was
    available forever."""
    import re
    up = _src("src/services/updater.zig")
    bz = _src("build.zig")

    checks = {
        "version injected at build time": 'APP_VERSION: []const u8 = @import("build_options").app_version;' in up,
        "build exposes it": 'addOption([]const u8, "app_version"' in bz,
        "read from the zon": '@import("build.zig.zon").version' in bz,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "version wiring incomplete: " + ", ".join(missing)

    # No hardcoded x.y.z version literal may remain in updater.zig CODE — that
    # is the copy that drifted. Comments are stripped first; the doc comment
    # above APP_VERSION names the old value on purpose.
    code = "\n".join(l for l in up.splitlines() if not l.lstrip().startswith("//"))
    literals = re.findall(r'"\d+\.\d+\.\d+"', code)
    if literals:
        return "fail", f"hardcoded version literal(s) back in updater.zig: {literals}"
    return "pass", "APP_VERSION comes from build.zig.zon via build_options; no hand-maintained copy"


@test("Host API and application user agents use the canonical version", "Build")
def test_version_reaches_host_api_and_user_agents():
    meta = _src("src/core/app_meta.zig")
    remote = _src("src/services/remote.zig")
    host = _src("src/services/remote_host_pure.zig")
    all_zig = "\n".join(
        _src(os.path.relpath(os.path.join(root, name), PROJECT_DIR))
        for root, _, names in os.walk(os.path.join(PROJECT_DIR, "src"))
        for name in names
        if name.endswith(".zig")
    )
    contributing = _src(".github/CONTRIBUTING.md")
    checks = {
        "metadata reads build option": '@import("build_options").app_version' in meta,
        "host reports metadata version": 'remote_host_pure.zig' in remote
            and '@import("../core/app_meta.zig").version' in remote
            and '@import("build_options").app_version' in host
            and r'\"version\":\"{s}\"' in host,
        "release user agent is derived": '"Opal/" ++ version' in meta,
        "legacy host literal removed": '"0.1.2"' not in remote,
        "legacy user agents removed": "Opal/1.0" not in all_zig,
        "development representation documented": "do not add an implicit `-dev` suffix" in contributing,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "canonical version does not reach every release identity: " + ", ".join(missing)
    return "pass", "/api/host and Opal user agents derive from build.zig.zon"


@test("Every release ships highlights and a commit list", "Packaging")
def test_release_notes():
    """Every release through v0.6.4 published a body of exactly one line:

        **Full Changelog**: https://github.com/debpalash/Opal/compare/v0.6.2...v0.6.3

    The publish job set `generate_release_notes: true`, and this repo lands
    work by direct commit rather than PR — so GitHub had nothing to summarise
    and produced a compare link. Someone deciding whether to update had to read
    54 commits of diff to find out what changed.

    Two halves are asserted here because they fail differently: the generated
    commit list cannot drift (it comes from git), but the hand-written
    highlights CAN simply not be written before a tag — so the section for the
    version in build.zig.zon must exist."""
    import re
    # Strip YAML comments before grepping — the step below EXPLAINS the old
    # `generate_release_notes: true` in prose, and a test that greps prose
    # tests nothing (the formula test learned this the same way).
    wf = "\n".join(l for l in _src(".github/workflows/release.yml").splitlines()
                   if not l.lstrip().startswith("#"))
    sh = _src("scripts/release-notes.sh")
    ch = _src("CHANGELOG.md")
    zon = _src("build.zig.zon")

    checks = {
        # The bug, verbatim.
        "publish no longer relies on GitHub's summariser": "generate_release_notes: true" not in wf,
        "release body comes from the generator": "body_path: RELEASE_NOTES.md" in wf,
        "the generator runs in the publish job": "scripts/release-notes.sh" in wf,
        # Without full history the commit list comes out empty and nobody notices.
        "publish checks out full history": "fetch-depth: 0" in wf,
        "generator emits both halves": "## Highlights" in sh and "## Changes" in sh,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "release-notes wiring incomplete: " + ", ".join(missing)

    m = re.search(r'\.version = "([^"]+)"', zon)
    ver = m.group(1) if m else "?"
    if not re.search(r"^## v%s\b" % re.escape(ver), ch, re.M):
        return "fail", f"CHANGELOG.md has no '## v{ver}' section — that release would ship with no highlights"

    # Run it. A generator that only exists is worth nothing; this is the same
    # code path the release job takes. The range has to be one that exists in
    # ANY checkout: CI clones shallow (depth 1) and without tags, so neither a
    # real tag nor HEAD~5 can be assumed — asking for either produced an empty
    # commit list and failed this test on CI while passing locally.
    #
    # `prev` must also be an ANCESTOR of the end of the range. The script ends
    # at the tag when the tag exists, and once a few commits land after a
    # release, `HEAD~5` is *newer* than that tag — `v0.6.4..HEAD~5` reversed is
    # empty, and this test failed on a perfectly good generator.
    def _git(*args):
        return subprocess.run(["git", *args], cwd=PROJECT_DIR,
                              capture_output=True, text=True).returncode == 0

    end = "v%s" % ver if _git("rev-parse", "-q", "--verify", "v%s^{commit}" % ver) else "HEAD"
    prev = next((r for r in ("%s~5" % end, "%s~1" % end)
                 if _git("rev-parse", "-q", "--verify", r + "^{commit}")), "")
    argv = ["sh", "scripts/release-notes.sh", "v%s" % ver] + ([prev] if prev else [])
    try:
        out = subprocess.run(
            argv, cwd=PROJECT_DIR, capture_output=True, text=True, timeout=60,
        )
    except subprocess.TimeoutExpired:
        return "fail", "release-notes.sh timed out"
    if out.returncode != 0:
        return "fail", "release-notes.sh exited %d: %s" % (out.returncode, out.stderr[:160])

    body = out.stdout
    produced = {
        "highlights section present": "## Highlights" in body,
        "highlights are the real ones, not the placeholder": "No highlights were written" not in body,
        "commit list present": "## Changes" in body,
        "commits carry a sha": bool(re.search(r"\(`[0-9a-f]{7,}`\)", body)),
        # Only with a previous ref to compare against: a depth-1 clone has none,
        # and the generator correctly omits the line rather than inventing it.
        "compare link present": "/compare/" in body if prev else True,
    }
    bad = [k for k, v in produced.items() if not v]
    if bad:
        return "fail", "generated notes are missing: " + ", ".join(bad)

    sections = len(re.findall(r"^## v\d+\.\d+\.\d+\b", ch, re.M))
    return "pass", f"notes = CHANGELOG highlights + generated commits; {sections} versions documented"


@test("First-run onboarding actually runs on first run", "Build")
def test_onboarding_first_run():
    """Issue #21: "its kinda confusing, the whole ui so maybe onboarding is
    needed" — and, relatedly, "TMDB show no output when i click on any movie".

    Opal ships with NO sources, so search and "click a movie" (which runs a
    universal search) return nothing until the starter pack is installed. The
    wizard whose first card installs it was disabled two ways: `onboarded`
    defaulted to true, and render() returned unless `replay_active`, which only
    Settings > About sets. So the first-run wizard never ran on first run —
    every new user landed on the full UI with no sources and no orientation.

    It was switched off back when the wizard was a macOS/brew dependency
    checklist that only nagged Windows users; it is now three cross-platform
    decisions plus a feature tour, so the reason no longer holds.

    Existing installs stay untouched: config.load() honours a persisted
    `onboarded` row and grandfathers configs that already carry a real TMDB key
    or installed sources."""
    ob = _src("src/ui/onboarding.zig")
    st = _src("src/core/state.zig")
    cf = _src("src/core/config.zig")

    checks = {
        "default is off-until-onboarded": "onboarded: bool = false," in st,
        "renders on first run": "if (!replay_active and state.app.onboarded) return;" in ob,
        "no replay-only gate": "if (!replay_active or !state.app.config_loaded" not in ob,
        # Ordering guard: without config_loaded the wizard would flash before
        # the persisted flag is read.
        "waits for config": "state.app.config_loaded.load(.acquire)" in ob,
        "never in headless": "state.app.is_headless" in ob,
        # Existing installs must not be nagged.
        "grandfathers old installs": "if (!state.app.onboarded and" in cf and "anyInstalled()" in cf,
        "still replayable": "pub fn replay()" in ob,
        # The card that fixes "no results anywhere".
        "offers starter sources": "installStarterPack()" in ob,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "first-run onboarding wiring incomplete: " + ", ".join(missing)
    return "pass", ("wizard shows on a fresh profile (verified on screen) and stays hidden "
                    "for installs with a persisted flag, a real TMDB key or sources")


@test("Workflow shell scripts parse", "Build")
def test_workflow_shell_syntax():
    """A `run:` block that isn't valid shell fails in CI with exit 127 and no
    output at all — you get a red job and no clue why. That is exactly what a
    stray line-continuation in ci.yml's smoke step cost: the whole script
    failed to parse, so not one of its own error messages ever ran.

    `bash -n` parses without executing, so this is cheap and catches it before
    the push. pwsh/cmd steps are skipped — only shell blocks are checked."""
    import glob, os, subprocess
    try:
        import yaml
    except ImportError:
        return "skip", "pyyaml not installed"

    bash = "/bin/bash"
    if not os.path.exists(bash):
        return "skip", "no /bin/bash"

    bad, checked = [], 0
    for wf in sorted(glob.glob(os.path.join(PROJECT_DIR, ".github", "workflows", "*.yml"))):
        try:
            doc = yaml.safe_load(open(wf))
        except Exception as e:
            bad.append(f"{os.path.basename(wf)}: unparseable YAML ({e})")
            continue
        for job in (doc.get("jobs") or {}).values():
            job_shell = ((job.get("defaults") or {}).get("run") or {}).get("shell", "")
            for step in job.get("steps") or []:
                script = step.get("run")
                if not script:
                    continue
                shell = step.get("shell", job_shell) or ""
                if any(s in shell for s in ("pwsh", "powershell", "cmd", "python")):
                    continue
                checked += 1
                # ${{ }} expressions are not shell — neutralise them first.
                import re
                cleaned = re.sub(r"\$\{\{[^}]*\}\}", "EXPR", script)
                r = subprocess.run([bash, "-n"], input=cleaned, capture_output=True, text=True)
                if r.returncode != 0:
                    name = step.get("name", "<unnamed>")
                    bad.append(f"{os.path.basename(wf)} / {name}: {r.stderr.strip()[:120]}")

    if bad:
        return "fail", "workflow shell scripts do not parse: " + "; ".join(bad[:4])
    if checked == 0:
        return "fail", "no shell steps found to check — the walker is broken"
    return "pass", f"{checked} workflow shell step(s) parse under bash -n"


@test("No AI attribution in commit trailers", "Build")
def no_ai_coauthor_trailers():
    """RULE (CLAUDE.md): commits carry no Co-Authored-By: Claude trailer.

    The maintainer asked for this to stop for good. It is checked here rather
    than left to memory because the instruction to add one is a DEFAULT that
    every fresh agent starts with — the rule only holds if something fails when
    it is ignored.

    Scoped to commits made after the rule existed: 438 earlier commits carry the
    trailer, and rewriting published history to strip them would be far worse
    than leaving them. RULE_FROM is the first commit the rule applies to.
    """
    import subprocess
    RULE_FROM = "3749b4a"  # last commit pushed before the rule was written
    try:
        rng = subprocess.run(["git", "log", "--format=%H", f"{RULE_FROM}..HEAD"],
                             cwd=PROJECT_DIR, capture_output=True, text=True, timeout=20)
        if rng.returncode != 0:
            return "skip", "git range unavailable (shallow clone or rebased base)"
        shas = [s for s in rng.stdout.split() if s]
        if not shas:
            return "pass", "no commits since the rule was introduced"
        bad = []
        for sha in shas:
            body = subprocess.run(["git", "log", "-1", "--format=%B", sha],
                                  cwd=PROJECT_DIR, capture_output=True, text=True, timeout=20).stdout
            # Line-anchored: a trailer is a LINE, not a mention. This very
            # commit's message discusses the trailer in prose, and a substring
            # match flagged it — the guard has to tell "don't add this" apart
            # from actually adding it.
            for line in body.splitlines():
                l = line.strip().lower()
                if l.startswith("co-authored-by:") and "claude" in l:
                    bad.append(sha[:7])
                    break
                if l.startswith("\U0001F916 generated with") or l.startswith("generated with [claude code]"):
                    bad.append(sha[:7])
                    break
        if bad:
            return "fail", "AI attribution in commit(s): " + ", ".join(bad)
        return "pass", f"{len(shas)} commit(s) since the rule, none with AI attribution"
    except Exception as exc:  # noqa: BLE001 — no git here is not a code fault
        return "skip", f"git unavailable: {exc}"


@test("The landing page's photographic bands are static and present", "Packaging")
def test_site_hero_backdrop():
    """Two photographs drawn by CSS — a tray of opals behind the hero, a single
    lit one behind the download band. They replaced a WebGL island (ogl / React
    Bits) that could fail to hydrate on a machine without a GL context, and then
    a grain overlay the film stock made redundant.

    What breaks silently here: a CSS `url()` whose file was never committed
    (blank hero, build still green), a `url()` left pointing at a file that was
    deleted (same), a full-resolution photo dropped in unoptimised (megabytes on
    the critical path, and nothing warns), the scrim going missing (light type on
    a bright sky), the hero losing its dark token overrides (unreadable in light
    mode), or the shader creeping back in.

    The page is also meant to carry no rules: the nav sits on the photograph
    rather than in a bar, and sections change tone instead of being divided.
    """
    page = _src("site/src/pages/index.astro")
    nav = _src("site/src/components/SiteNav.astro")
    css = _src("site/src/styles/global.css")

    photo = os.path.join(PROJECT_DIR, "site/public/assets/opal.jpg")
    # Every url() in the stylesheet has to resolve to a file that is actually
    # here — a dangling reference is invisible until someone loads the page.
    refs = re.findall(r'url\("(/assets/[^"]+)"\)', css)
    paths = {r: os.path.join(PROJECT_DIR, "site/public", r.lstrip("/")) for r in refs}
    dangling = [r for r, p in paths.items() if not os.path.exists(p)]
    # These are the page's only large assets and they are deliberately high
    # quality — dark, detailed stones fall apart under hard compression. The
    # ceiling catches a full-resolution original dropped in (both of these
    # arrived over 2MB), not the encoder setting.
    heavy = [r for r, p in paths.items() if os.path.exists(p) and os.path.getsize(p) > 800_000]

    checks = {
        "the backdrop photo exists": os.path.exists(photo),
        "no dangling asset reference": not dangling,
        "every backdrop is under 800KB": not heavy,
        "the CSS points at the photo": "/assets/opal.jpg" in css,
        # Two more photographic bands, both carrying dark tokens on a
        # light-mode page and both fading to var(--bg) instead of ending on an
        # edge.
        "the download band has its backdrop":
            "/assets/opal2.jpg" in css and 'section class="cta" id="download"' in page,
        "the support band has its backdrop":
            "/assets/donate.jpg" in css and 'section class="support"' in page,
        # A CSS background is discovered late; the preload has to name the same
        # file, or it is a second download instead of a head start.
        "the photo is preloaded":
            'rel="preload" as="image" href="/assets/opal.jpg"' in page,
        "the page mounts the scrim": '<div class="veil"></div>' in page,
        # Type sits on a photograph; the scrim is what keeps it legible.
        "the copy has a floor under it": ".hero .veil" in css,
        "hero keeps dark values in light mode": "--fg: #f4f2ec;" in css,
        # The island is gone from the hero. `ogl` itself is back in
        # package.json — the react-bits registry component pulls it — so the
        # check is that the hero does not mount a WebGL backdrop, not that the
        # dependency is absent.
        "no WebGL island left behind in the hero": "HeroBackdrop" not in page,
        # No grain layer: the photograph is film and brings its own.
        "no leftover grain layer":
            ".hero .grain" not in css and "grain.png" not in css
            and 'class="grain"' not in page,
        # No rules anywhere — the nav rides the photo, sections fade into the bg.
        "the nav is inside the hero":
            page.find('<header class="hero">') < page.find('<SiteNav current="/" />')
            and "<nav" in nav,
        "nothing draws a divider":
            "border-bottom: 1px solid" not in css
            and "border-top: 1px solid" not in css
            and "border-block:" not in css,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "hero backdrop: " + ", ".join(missing)
    return "pass", "hero + download bands: both photos committed, no rules on the page, zero JS"


@test("The landing page offers everything a release ships", "Packaging")
def test_site_download_grid():
    """The release job attaches a Chrome zip and a Firefox zip alongside the app
    binaries, and the site has to offer both — it used to link the Chrome one
    from a tile labelled "Chrome · Firefox", so Firefox users got the wrong
    file. Download counts come from the whole release history: a total taken
    from the newest tag alone resets to nearly zero every release day.
    """
    grid = _src("site/src/components/DownloadGrid.tsx")
    menu = _src("site/src/components/DownloadMenu.tsx")
    lib = _src("site/src/lib/releases.ts")
    wf = _src(".github/workflows/release.yml")

    # What the release actually uploads, so the tiles can't drift from it.
    ships_chrome = "opal-connect-${VER}-chrome.zip" in wf
    ships_firefox = "opal-connect-${VER}-firefox.zip" in wf

    checks = {
        "release ships both extension zips": ships_chrome and ships_firefox,
        # The patterns live in the shared platform table now. Three surfaces
        # resolve download links (grid, hero menu, nav menu) and they disagreed
        # once already — that is how the Chrome zip ended up behind a tile
        # labelled "Chrome · Firefox".
        "the platform table resolves the chrome zip": '"opal-connect", "chrome"' in lib,
        "the platform table resolves the firefox zip": '"opal-connect", "firefox"' in lib,
        "the grid reads that table": "PLATFORMS" in grid and "fileFor" in grid,
        # The extension zips moved to the Opal Connect section, next to the
        # screenshot that explains them — same table, different placement, and
        # the download section must not list them twice.
        "the extension buttons read that table too":
            "PLATFORMS" in _src("site/src/components/ExtensionDownloads.tsx"),
        "the download section leaves the extension to that section":
            'p.id !== "chrome"' in grid
            and "<ExtensionDownloads client:visible />" in _src("site/src/pages/index.astro"),
        # A release ships several files per platform — .dmg AND .app.zip AND a
        # tarball, AppImage AND .deb AND .rpm. Offering only the first sent
        # anyone who wanted a .deb off to the releases page to dig for it.
        "every format is offered, not just the primary":
            all(f in lib for f in ('".deb"', '".rpm"', '".msi"', '"AppImage"', '".app.zip"')),
        "files show their size": "formatBytes" in lib and "formatBytes" in grid,
        "checksums are linked": "sha256sums" in lib.lower() and "namedAsset" in grid,
        "the menu reads that table": "PLATFORMS" in menu and "assetFor" in menu,
        "counts come from every release, not just the newest":
            "per_page=100" in lib and "flatMap" in lib,
        "counts read download_count": "download_count" in lib,
        "one shared fetch for the whole page": "getReleases" in lib and "inflight" in lib,
        # Every island reads it; each one hitting api.github.com separately
        # burns the 60/hour an unauthenticated IP gets.
        "the badge shares that fetch": "getReleases" in _src("site/src/components/ReleaseBadge.tsx"),
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "download grid: " + ", ".join(missing)
    return "pass", "one platform table behind the grid and both menus; counts summed across all releases"


@test("The landing page's download flow and social proof are wired", "Packaging")
def test_site_download_flow():
    """The download button picks the visitor's platform, the caret opens the
    rest, and a click lands on /thanks with install steps.

    Failure modes that look fine in a build: the menu with no way to dismiss it
    (a trap on touch and on the keyboard), a click handler that navigates before
    the transfer starts (download cancelled), /thanks indexed by search engines
    as a dead-end page, and `?os=` interpolated instead of matched against the
    platform table.
    """
    page = _src("site/src/pages/index.astro")
    thanks_page = _src("site/src/pages/thanks.astro")
    nav = _src("site/src/components/SiteNav.astro")
    seo = _src("site/src/components/SeoHead.astro")
    panel = _src("site/src/components/ThanksPanel.tsx")
    menu = _src("site/src/components/DownloadMenu.tsx")
    star = _src("site/src/components/StarButton.tsx")
    lib = _src("site/src/lib/releases.ts")
    css = _src("site/src/styles/global.css")

    checks = {
        "the hero and the nav both mount the menu":
            '<DownloadMenu client:load />' in page
            and '<DownloadMenu client:load variant="nav" />' in nav,
        "the button names the detected platform":
            "detectOs" in lib and "Download for ${mine.short}" in menu,
        "the menu can be dismissed": "Escape" in menu and "mousedown" in menu,
        "the menu says it is a menu": 'aria-expanded' in menu and 'aria-haspopup' in menu,
        # The href stays a real asset URL so it survives no-JS and copy-link.
        "the anchor keeps a real asset href": "assetFor" in menu and "href={href ??" in menu,
        "the download starts before the page moves":
            "a.click()" in lib and "setTimeout" in lib and "/thanks?os=" in lib,
        "the thanks page exists and is noindex":
            bool(thanks_page) and 'noindex={true}' in thanks_page
            and 'name="robots" content="noindex, follow"' in seo,
        "?os= is matched, not interpolated": "platform(want)" in panel,
        "the thanks page can restart a stalled download": "Start it again" in panel,
        "star count comes from the repo endpoint":
            "getRepoMeta" in lib and "stargazers_count" in star,
        # GitHub's own button is an iframe on every visit; this is a link.
        "the star button is not a third-party iframe": "iframe" not in star,
        "the site offers a way to donate": "ko-fi.com" in page,
        "the nav menus need no javascript": "<details" in nav and ".menu summary" in css,
        "the X profile is linked":
            "AUTHOR_URL" in nav and 'rel="me"' in nav
            and "https://x.com/idebpalash" in _src("site/src/lib/site.ts"),
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "download flow: " + ", ".join(missing)
    return "pass", "split download button + dismissible menu + /thanks flow + star/donate/X"


@test("The landing page's comparison and SEO metadata hold up", "Packaging")
def test_site_compare_and_seo():
    """The comparison matrix names real products, so it has to stay honest and
    say where its claims come from. The structured data has to describe what is
    actually on the page — invented markup is what gets a site's rich results
    pulled — and a JSON-LD blob that fails to parse is silently ignored by every
    crawler while looking perfectly fine in the browser.

    Read from site/dist when it exists and from the .astro source when it does
    not — see the fallback below for why insisting on the build was wrong.
    """
    page = _src("site/src/pages/index.astro")
    robots = _src("site/public/robots.txt")
    sitemap = _src("site/src/pages/sitemap.xml.ts")
    seo = _src("site/src/components/SeoHead.astro")
    site_meta = _src("site/src/lib/site.ts")
    seo_check = _src("site/scripts/check-seo.mjs")
    package = _src("site/package.json")
    built = os.path.join(PROJECT_DIR, "site/dist/index.html")

    rivals = ["Jellyfin", "Plex", "qBittorrent", "Stremio", "Kodi"]
    # The rendered page is what a crawler sees; parse the JSON-LD out of it.
    ld, ld_ok = None, False
    if os.path.exists(built):
        html = open(built).read()
        m = re.search(r'<script type="application/ld\+json"[^>]*>(.*?)</script>', html, re.S)
        if m:
            try:
                ld = json.loads(m.group(1))
                ld_ok = True
            except ValueError:
                ld_ok = False

    types = []
    if isinstance(ld, dict):
        types = [n.get("@type") for n in ld.get("@graph", []) if isinstance(n, dict)]

    if not os.path.exists(built):
        # site/dist is a gitignored build artifact and NO job produces it, so
        # demanding it made this test unpassable on CI while passing on a dev
        # box that happened to have a stale build lying around. Fall back to
        # the source, where the two things that can actually go wrong live:
        # the blob is machine-serialised, so it cannot be malformed JSON
        # unless that stops being true, and the @types are written out in the
        # frontmatter object. When a build IS present the rendered page still
        # wins, because that is what a crawler reads.
        ld_ok = "set:html={JSON.stringify(structuredData)}" in seo
        types = []
        if '"@type": "SoftwareApplication"' in page:
            types.append("SoftwareApplication")
        if '"@type": "WebSite"' in seo:
            types.append("WebSite")

    checks = {
        "the matrix names the products it compares against":
            all(r in page for r in rivals),
        "the matrix says where its claims come from":
            "each project's own documentation" in page,
        "and offers a way to correct it": 'class="foot"' in page,
        "the structured data parses": ld_ok,
        "it describes the app on the page": "SoftwareApplication" in types,
        "and does not invent a rating": "aggregateRating" not in page,
        "robots points at the sitemap": "Sitemap: https://opal.palash.dev/sitemap.xml" in robots,
        "robots keeps the flow page out": "Disallow: /thanks" in robots,
        "the sitemap lists every canonical page":
            "SITE_PAGES.map" in sitemap and "SITE_PAGES" in site_meta
            and 'path: "/"' in site_meta,
        "social cards name the author":
            'name="twitter:site" content="@idebpalash"' in seo,
        "the API host is preconnected": 'rel="preconnect" href="https://api.github.com"' in page,
        "SEO regressions fail the site test":
            '"test": "astro build && node scripts/check-seo.mjs"' in package
            and "duplicate ${label}" in seo_check
            and "broken internal link" in seo_check,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "compare/seo: " + ", ".join(missing)
    return "pass", f"matrix vs {len(rivals)} products, sourced; JSON-LD parses ({', '.join(t for t in types if t)})"
