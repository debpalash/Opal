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


@test("Android native compile gate (opt-in OPAL_ANDROID_CHECK=1)", "Android")
def test_android_zig_check():
    if os.environ.get("OPAL_ANDROID_CHECK") != "1":
        return "skip", "set OPAL_ANDROID_CHECK=1 (needs NDK + deps prefix)"
    ndk = os.environ.get("ANDROID_NDK_ROOT", "")
    r = subprocess.run(["zig", "build", "--build-file", "build-android.zig", "check", "-Dndk=" + ndk, "-fsys=sdl3"],
                       cwd=PROJECT_DIR, capture_output=True, text=True, timeout=900)
    return ("pass", "check ok") if r.returncode == 0 else ("fail", r.stderr[-400:])
