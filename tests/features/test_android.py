"""Android port: JNI/Zig contract, gating, Gradle/manifest, CI and pins."""
from .harness import *  # noqa: F401,F403
import os, re, sys, json, importlib.util, tempfile, tarfile, io  # noqa: F401


def _load(rel, name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(PROJECT_DIR, rel))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _exists(rel):
    return os.path.exists(os.path.join(PROJECT_DIR, rel))


def _fail(bad, ok_msg):
    return ("fail", "; ".join(bad)) if bad else ("pass", ok_msg)


@test("Android JNI contract: Java natives, C exports, Zig exports line up", "Android")
def test_android_jni_contract():
    c = _src("mobile/android/jni/opal_android.c")
    java = _src("mobile/android/app/src/main/java/com/debpalash/opal/OpalActivity.java")
    zig = _src("src/android.zig")
    if not (c and java and zig):
        return "fail", "missing opal_android.c / OpalActivity.java / src/android.zig"
    bad = []
    for fn in re.findall(r"Java_com_debpalash_opal_OpalActivity_(\w+)", c):
        if not re.search(r"native\s+[\w\[\]]+\s+" + fn + r"\s*\(", java):
            bad.append("no native decl for " + fn)
    for fn in ("nativeSetInsets", "nativeOpenMedia"):
        if "Java_com_debpalash_opal_OpalActivity_" + fn not in c:
            bad.append("C lacks " + fn)
    # Every opal_android_* extern used from Zig must be defined in the C glue.
    used = set()
    for root, _, files in os.walk(os.path.join(PROJECT_DIR, "src")):
        for f in files:
            if f.endswith(".zig"):
                used |= set(re.findall(r"extern\s+fn\s+(opal_android_\w+)", open(os.path.join(root, f), encoding="utf-8").read()))
    exported = set(re.findall(r"export\s+fn\s+(opal_android_\w+)", zig))
    for fn in sorted(used - exported):
        if not re.search(r"\b" + fn + r"\s*\(", c) or not re.search(r"^[^\n;]*\b" + fn + r"\s*\([^;]*\)\s*\{", c, re.M):
            bad.append("extern not defined in C: " + fn)
    for fn in ("opal_android_open_media", "opal_android_valid_media_url", "opal_android_player_probe"):
        if fn not in exported:
            bad.append("android.zig does not export " + fn)
    if not re.search(r"export\s+fn\s+SDL_main", zig):
        bad.append("android.zig does not export SDL_main")
    for fn in ("prepare_environment", "resource_dir", "safe_area", "pick_file", "log", "ready"):
        if not re.search(r"\bopal_android_" + fn + r"\s*\(", c):
            bad.append("C lacks opal_android_" + fn)
    return _fail(bad, "JNI natives, C glue and Zig exports match")


@test("Android gates: shared files use mobile/sdl3 predicates, DNS covers bionic", "Android")
def test_android_gates():
    bad = []
    for f in ("src/ui/grid.zig", "src/ui/media_preview.zig", "src/services/search_preview.zig"):
        if ".ios" in _src(f):
            bad.append(f + " still gates on .ios")
    if "isAndroid" not in _src("src/core/http_dns_native.zig"):
        bad.append("http_dns_native does not cover Android")
    if "mobile/host.zig" not in _src("src/ui/ios_frame.zig"):
        bad.append("ios_frame does not use mobile/host.zig")
    plat = _src("src/core/platform_pure.zig")
    for n in ("usesSdl3", "mobileSaveSubdir"):
        if n not in plat:
            bad.append("platform_pure lacks " + n)
    return _fail(bad, "gates cover Android")


@test("Android Gradle project and manifest", "Android")
def test_android_gradle_manifest():
    app = _src("mobile/android/app/build.gradle.kts")
    root = _src("mobile/android/settings.gradle.kts")
    man = _src("mobile/android/app/src/main/AndroidManifest.xml")
    checks = {
        "settings includes :app": ':app' in root,
        "reads build.zig.zon": "build.zig.zon" in app,
        "minSdk 26": "minSdk = 26" in app or "minSdk=26" in app.replace(" ", ""),
        "arm64-v8a only": "arm64-v8a" in app,
        "jniLibs from zig-out/android": "zig-out/android" in app.replace('"zig-out", "android"', "zig-out/android") and '"jniLibs"' in app or "zig-out/android/jniLibs" in app,
        "applicationId": "com.debpalash.opal" in app,
        "INTERNET permission": "android.permission.INTERNET" in man,
        "magnet intent filter": 'android:scheme="magnet"' in man,
        "adjustNothing": "adjustNothing" in man,
    }
    bad = [k for k, ok in checks.items() if not ok]
    return _fail(bad, "gradle + manifest wired")


@test("Android APK is built post-publish, attached, checksummed", "Android")
def test_android_release_workflow():
    release = _src(".github/workflows/release.yml")
    apk = _src(".github/workflows/android-apk.yml")
    checks = {
        "release calls the APK workflow": "uses: ./.github/workflows/android-apk.yml" in release,
        # setup-android@v3 defaults to the removed legacy `tools` package (sdkmanager exit 1).
        "SDK setup skips the legacy tools package": "android-actions/setup-android@v3\n        with:\n" in apk and "packages: ''" in apk,
        "android job waits for publish and ios": "needs: [publish, ios]" in release,
        "android job guards on publish success": "needs.publish.result == 'success'" in release,
        "APK built by the tested packager": "scripts/android-build.py --apk" in apk,
        "checksum appended to the manifest": "SHA256SUMS.txt --clobber" in apk and "sha256sum Opal-*-android.apk" in apk,
        "stale android line dropped first": "grep -v -- '-android\\.apk'" in apk,
        "tag must match the app version": "check-release-version.py" in apk,
        "PR builds never upload": "if: env.OPAL_RELEASE_TAG != ''" in apk,
        "NDK pinned": "27.1.12297006" in apk,
        "native prefix artifact": "android-native-prefix" in apk,
        "cache keyed on pins": "hashFiles('mobile/android/dependencies.json', 'scripts/android-deps.py')" in apk,
    }
    bad = [k for k, ok in checks.items() if not ok]
    return _fail(bad, "APK built post-publish, attached, and checksummed")


@test("Android scripts: version code, safe extraction, pinned checksums", "Android")
def test_android_scripts_and_pins():
    bad = []
    build = _load("scripts/android-build.py", "android_build")
    deps = _load("scripts/android-deps.py", "android_deps")
    if build.version_code("0.9.4") != 904:
        bad.append("version_code(0.9.4) != 904")
    if build.version_code("1.2.3") != 10203:
        bad.append("version_code(1.2.3) != 10203")
    if not re.fullmatch(r"\d+\.\d+\.\d+", build.app_version().split("-")[0].split("+")[0]):
        bad.append("app_version unparsable")
    # REGRESSION guard: path traversal members must be rejected.
    with tempfile.TemporaryDirectory() as tmp:
        tar_path = os.path.join(tmp, "evil.tar")
        with tarfile.open(tar_path, "w") as t:
            info = tarfile.TarInfo("../escape.txt")
            info.size = 1
            t.addfile(info, io.BytesIO(b"x"))
        dest = os.path.join(tmp, "out")
        os.mkdir(dest)
        try:
            deps.safe_extract_tar(tar_path, dest)
            bad.append("android-deps accepted ../ member")
        except ValueError:
            pass
    pins = json.loads(_src("mobile/android/dependencies.json"))
    items = [pins["ndk"]] + pins["sources"]
    names = {i.get("name", "ndk") for i in items}
    for need in ("sdl3", "mpv-android", "libtorrent", "openssl", "boost", "libwebp", "sqlite"):
        if need not in names:
            bad.append("missing pin " + need)
    for i in items:
        if not re.fullmatch(r"[0-9a-f]{64}", i.get("sha256", "")):
            bad.append("bad sha256: " + i.get("name", "ndk"))
        if not i.get("url", "").startswith("https://"):
            bad.append("non-https url: " + i.get("name", "ndk"))
    ios = json.loads(_src("mobile/ios/torrent-dependency.json"))
    lt = next(i for i in pins["sources"] if i["name"] == "libtorrent")
    if lt["sha256"] != ios["sha256"]:
        bad.append("libtorrent sha differs from iOS pin")
    return _fail(bad, "version_code, safe extraction and 64-hex pins verified")


@test("Android mpv build: fail-fast bash -e, meson gate, post-build asserts (fontconfig regression)", "Android")
def test_android_mpv_build_failfast():
    bad = []
    deps = _load("scripts/android-deps.py", "android_deps_mpv")
    src = _src("scripts/android-deps.py")
    body = src[src.index("def build_mpv"):src.index("def install_jnilibs")]
    # REGRESSION: `bash script` ignores the shebang's -e, so a failed fontconfig build was skipped.
    for s_ in ("download.sh", "buildall.sh"):
        if "'bash', '-e', '%s'" % s_ not in body:
            bad.append(s_ + " not run with bash -e")
    if "check=True" not in src[src.index("def run("):src.index("def ndk_root")]:
        bad.append("run() not check=True")
    if not (deps.meson_version_ok("1.11.0") and deps.meson_version_ok("1.12.1")):
        bad.append("meson >=1.11 rejected")
    if deps.meson_version_ok("1.3.2") or deps.meson_version_ok("garbage"):
        bad.append("old/garbage meson accepted")
    with tempfile.TemporaryDirectory() as tmp:
        if len(deps.missing_mpv_outputs(tmp)) != 2:
            bad.append("empty prefix not flagged")
        os.makedirs(os.path.join(tmp, "include/mpv"))
        os.makedirs(os.path.join(tmp, "lib"))
        open(os.path.join(tmp, "include/mpv/client.h"), "w").close()
        open(os.path.join(tmp, "lib/libmpv.so"), "w").close()
        if deps.missing_mpv_outputs(tmp):
            bad.append("complete prefix flagged")
    wf = _src(".github/workflows/android-apk.yml")
    if "meson>=1.11" not in wf:
        bad.append("workflow lacks meson>=1.11")
    return _fail(bad, "bash -e, meson gate and mpv output assertions verified")


@test("Android docs and README advertise the preview", "Android")
def test_android_docs():
    readme = _src("README.md")
    bad = []
    if "Android (preview)" not in readme:
        bad.append('README lacks "Android (preview)"')
    if "Android (planned)" in readme:
        bad.append("README still says planned")
    if "docs/android.md" not in readme:
        bad.append("README install row does not link docs/android.md")
    if not _exists("docs/android.md"):
        bad.append("docs/android.md missing")
    return _fail(bad, "README and docs/android.md present")


@test("Android libmain links NDK system libs from explicit library paths", "Android")
def test_android_ndk_lib_paths():
    # Regression: addSearchPrefix(<ndk>/usr/lib/aarch64-linux-android/<api>) looked in
    # .../<api>/lib, so log/android/m/dl were "unable to find dynamic system library".
    src = _src("build-android.zig")
    checks = {
        "per-API NDK lib dir": 'addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib/aarch64-linux-android/{d}", .{ sysroot, api }) })' in src,
        "unversioned NDK lib dir (libc++_shared)": 'addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib/aarch64-linux-android", .{sysroot}) })' in src,
        "no search prefix on the NDK lib dir": 'addSearchPrefix(b.fmt("{s}/usr/lib/aarch64-linux-android' not in src,
    }
    missing = [k for k, v in checks.items() if not v]
    return ("fail", f"missing: {missing}") if missing else ("pass", "libmain.so finds log/android/m/dl/c++_shared in the NDK sysroot")


@test("Android libmain.so links libunwind and is checked for unresolved symbols", "Android")
def test_android_libmain_resolves():
    # Regression: the first CI APK's libmain.so had a strong undefined
    # _Unwind_Resume that no bundled or system library provides -> dlopen fails.
    src = _src("build-android.zig")
    spec = importlib.util.spec_from_file_location("android_build", os.path.join(PROJECT_DIR, "scripts/android-build.py"))
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    checks = {
        "build links libunwind.a": 'b.option([]const u8, "unwind"' in src and "so.root_module.addObjectFile(.{ .cwd_relative = path })" in src,
        "script passes -Dunwind": "'-Dunwind=' + str(find_unwind(ndk))" in _src("scripts/android-build.py"),
        "script verifies before gradle": "verify_libmain(ndk)" in _src("scripts/android-build.py"),
        "missing symbol is reported": mod.unresolved_symbols(["_Unwind_Resume", "SDL_Init"], ["SDL_Init@@SDL3_0.0.0"]) == ["_Unwind_Resume"],
        "versioned providers resolve": mod.unresolved_symbols(["SDL_Init", "malloc@LIBC"], ["SDL_Init@@SDL3_0.0.0", "malloc"]) == [],
    }
    missing = [k for k, v in checks.items() if not v]
    return ("fail", f"missing: {missing}") if missing else ("pass", "libunwind linked; unresolved imports fail the build")


@test("Android deps merge into a cached prefix with existing symlinks", "Android")
def test_android_merge_tree_cached_prefix():
    # Regression: a cache-restored prefix already held liblinebreak.a -> libunibreak.a;
    # copytree(symlinks=True, dirs_exist_ok=True) raised FileExistsError.
    spec = importlib.util.spec_from_file_location("android_deps", os.path.join(PROJECT_DIR, "scripts/android-deps.py"))
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    with tempfile.TemporaryDirectory() as d:
        src, dst = os.path.join(d, "src"), os.path.join(d, "dst")
        os.makedirs(os.path.join(src, "lib"))
        open(os.path.join(src, "lib", "libunibreak.a"), "w").write("v2")
        os.symlink("libunibreak.a", os.path.join(src, "lib", "liblinebreak.a"))
        mod.merge_tree(src, dst)
        try:
            mod.merge_tree(src, dst)
        except FileExistsError as e:
            return "fail", f"second merge raised: {e}"
        link = os.path.join(dst, "lib", "liblinebreak.a")
        ok = os.path.islink(link) and os.readlink(link) == "libunibreak.a" and open(link).read() == "v2"
    return ("pass", "re-merging over a cached prefix keeps symlinks") if ok else ("fail", "symlink not preserved")


@test("Android Back trap, background service, notification permission, CI SDK cache", "Android")
def test_android_back_and_background():
    bad = []
    c = _src("mobile/android/jni/opal_android.c") or ""
    java = _src("mobile/android/app/src/main/java/com/debpalash/opal/OpalActivity.java") or ""
    svc = _src("mobile/android/app/src/main/java/com/debpalash/opal/OpalTorrentService.java") or ""
    man = _src("mobile/android/app/src/main/AndroidManifest.xml") or ""
    zig = _src("src/android.zig") or ""
    wf = _src(".github/workflows/android-apk.yml") or ""
    if not re.search(r'SDL_HINT_ANDROID_TRAP_BACK_BUTTON,\s*"1"', c):
        bad.append("back button not trapped")
    if not re.search(r"^[^\n;]*opal_android_move_task_to_back\s*\([^;]*\)\s*\{", c, re.M) or "moveTaskToBack" not in c:
        bad.append("C lacks move_task_to_back")
    if "SDLK_AC_BACK" not in zig:
        bad.append("android.zig ignores SDLK_AC_BACK")
    if not re.search(r"native\s+boolean\s+nativeHasActiveTransfers\s*\(", java) or "Java_com_debpalash_opal_OpalActivity_nativeHasActiveTransfers" not in c:
        bad.append("nativeHasActiveTransfers Java/C mismatch")
    if not re.search(r"export\s+fn\s+opal_android_active_transfers", zig) or "opal_android_active_transfers()" not in c:
        bad.append("active_transfers Zig export/C call missing")
    for perm in ("FOREGROUND_SERVICE", "FOREGROUND_SERVICE_DATA_SYNC", "POST_NOTIFICATIONS", "WAKE_LOCK"):
        if 'android.permission.%s"' % perm not in man:
            bad.append("manifest lacks " + perm)
    if not re.search(r'<service[^>]*\.OpalTorrentService[^>]*foregroundServiceType="dataSync"', man, re.S):
        bad.append("service decl missing dataSync")
    if "extends Service" not in svc or "PARTIAL_WAKE_LOCK" not in svc or "Opal is transferring" not in svc or '"Transfers"' not in svc:
        bad.append("service lacks wake lock/notification/channel")
    if "onPause" not in java or "onResume" not in java or "POST_NOTIFICATIONS" not in java:
        bad.append("activity lifecycle/permission wiring missing")
    if "android-mpv-sdk-" not in wf or "buildscripts/sdk" not in wf or "steps.mpvpin.outputs.pin" not in wf or "android-native-${{ hashFiles" not in wf:
        bad.append("workflow SDK cache / prefix cache missing")
    return _fail(bad, "Back, background service, permissions, CI cache wired")


@test("Android release APK is signed with the stable key when secrets exist", "Android")
def test_android_release_signing():
    apk = _src(".github/workflows/android-apk.yml")
    release = _src(".github/workflows/release.yml")
    gradle = _src("mobile/android/app/build.gradle.kts")
    andro = release[release.index("  android:"):]
    andro = andro[:andro.index("\n\n")]
    checks = {
        "secrets decoded to a keystore": "secrets.OPAL_ANDROID_KEYSTORE_B64" in apk and 'base64 -d > "$RUNNER_TEMP/opal-release.jks"' in apk,
        "keystore exported before the build": apk.index("name: Release signing key") < apk.index("name: Build APK")
            and "OPAL_ANDROID_KEYSTORE=$RUNNER_TEMP/opal-release.jks" in apk,
        "missing secrets fall back to debug": 'if [ -z "$KS_B64" ]' in apk,
        "release passes secrets to the APK job": "secrets: inherit" in andro,
        "gradle reads the same env": all(v in gradle for v in ("OPAL_ANDROID_KEYSTORE", "OPAL_ANDROID_KEYSTORE_PASSWORD", "OPAL_ANDROID_KEY_ALIAS")),
    }
    missing = [k for k, v in checks.items() if not v]
    return ("fail", f"missing: {missing}") if missing else ("pass", "stable release key wired from secrets; debug fallback")


@test("Android native compile gate (opt-in OPAL_ANDROID_CHECK=1)", "Android")
def test_android_zig_check():
    if os.environ.get("OPAL_ANDROID_CHECK") != "1":
        return "skip", "set OPAL_ANDROID_CHECK=1 (needs NDK + deps prefix)"
    ndk = os.environ.get("ANDROID_NDK_ROOT", "")
    r = subprocess.run(["zig", "build", "--build-file", "build-android.zig", "check", "-Dndk=" + ndk, "-fsys=sdl3"],
                       cwd=PROJECT_DIR, capture_output=True, text=True, timeout=900)
    return ("pass", "check ok") if r.returncode == 0 else ("fail", r.stderr[-400:])
