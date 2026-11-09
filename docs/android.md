# Opal for Android — shared-code preview build

Android runs the desktop application, not a separate mobile app. An SDL3 host
(`src/android.zig`, `OpalActivity extends SDLActivity`) calls the same shared
frame as iOS (`src/ui/ios_frame.zig`): desktop `coreInit`, the shared service
ticks and the page shell inside the safe area. Target: arm64-v8a, Android 8.0+
(API 26).

Android-only pieces:

- JNI glue (`mobile/android/jni/opal_android.c`): environment, safe-area and
  keyboard insets, logcat logging, asset extraction (`cacert.pem`)
- Storage Access Framework picker plus "Open with" and `magnet:` intents, all
  routed into the desktop universal open (`browser.loadContent`)
- bionic DNS resolution (`getaddrinfo`) for `std.http`
- config/session save when the app goes to the background
- Back button: trapped (not closing the app). It leaves the player, then pops
  navigation history; at the home root the app moves to the background.
- Background transfers: when torrents or HTTP downloads are active as the app
  is paused, `OpalTorrentService` (foreground service, `dataSync`, partial
  wake lock) shows an ongoing low-importance "Opal is transferring"
  notification in the "Transfers" channel. It stops on resume or when nothing
  is active. `POST_NOTIFICATIONS` is requested once (API 33+) the first time a
  transfer is backgrounded; if denied, the service still runs without a
  visible notification entry.
- libmpv from the pinned mpv-android build scripts, libtorrent from source

Compiled out on mobile: managed helper processes (yt-dlp bootstrap, Python
engines, voice CLIs, Jackett, agents/PTY), the LAN web server/remote API, DPI
bypass, the native browser, system monitor and the OS file manager. Downloads
go to the app's external files directory (`Downloads`).

## Install

Each release attaches `Opal-X.Y.Z-android.apk`. Allow "Install unknown apps"
for your browser/file manager, then open the APK. Without release keystore
secrets the APK is debug-signed: uninstall a debug-signed preview before
installing the next one, because the signature differs from any
keystore-signed build.

## Building

Requirements: Zig 0.17, JDK 17 or 21, Android SDK with NDK 27.1.12297006
(`ANDROID_NDK_ROOT` or `ANDROID_HOME`), Gradle 9.8.1 (AGP 9.5.1), CMake, Ninja,
Meson, NASM, autotools.

```sh
python3 scripts/android-build.py --apk dist/Opal-X.Y.Z-android.apk
```

This builds the pinned native dependencies (`mobile/android/dependencies.json`,
cached in `.zig-cache/android-native`), then `libmain.so`
(`build-android.zig`), then runs Gradle. The dependency build is slow. Reuse
the CI `android-native-prefix` artifact instead:

```sh
tar -xzf android-native-prefix.tar.gz -C .zig-cache/android-native
python3 scripts/android-build.py --deps-prefix .zig-cache/android-native/prefix
```

Other flags: `--skip-zig`, `--stub-libs` (empty libs, packaging check only),
`--install`, `--launch`. Set `OPAL_ANDROID_KEYSTORE`, `_PASSWORD` and
`_KEY_ALIAS` to sign with your own key.

## Troubleshooting

- `adb logcat -s Opal` shows app logs and panics (tag `Opal`).
- `OPAL_ANDROID_UI_READY` in the log marks the first rendered frame.
- No network content: check that `cacert.pem` was extracted to the app's
  `resources` directory on launch.

## CI build cache

mpv-android's build script downloads its own SDK and NDK (NDK r30) under
`sources/mpv-android/<pin>/buildscripts/sdk`. That download dominates a cold
first build (many minutes), so CI caches it separately, keyed only on the
mpv-android pin in `mobile/android/dependencies.json`; edits to
`scripts/android-deps.py` do not invalidate it. The prefix cache
(`.zig-cache/android-native`) is kept as well.
