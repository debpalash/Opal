# Opal for iPhone and iPad — shared-code development build

iPhone/iPad run the desktop application, not a separate mobile app. The iOS
host (`src/ios.zig`, `src/ui/ios_frame.zig`) calls the desktop `coreInit`, the
shared per-frame service ticks (`src/app_services.zig`, also used by
`main.zig`), and the desktop page shell (`ui/shell.zig`) inside the safe area.
The iOS-specific code is limited to these pieces:

- safe-area/keyboard insets (`shell.host_insets`) and touch-sized player chrome
- the UIKit document picker and link dialog. Both feed the desktop universal
  open (`browser.loadContent`), so files, URLs, magnets, `.torrent`, comics and
  playlists route the same way as a desktop drop.
- Foundation HTTP for `http.fetch` / `reliable_fetch`. `std.http` users load the
  bundled `cacert.pem`.
- the UIKit port of the WebKit browser (`mobile/ios/native_browser.m`), which
  implements the macOS `opal_browser_*` C API
- config/session save when the app enters the background

All pages share their implementation with desktop: Home shelves, Movies & TV
(catalog, TV seasons/episodes, Find sources), universal source search, torrent
playback through libtorrent, Downloads, readers, the browser and Settings.

These are compiled out on mobile: managed helper processes (yt-dlp bootstrap,
Python engines, voice CLIs, Jackett, agents/PTY), the LAN web server and DPI
bypass. Sources that need them report unavailable at runtime. Downloads go to
`Documents/Downloads`, which is visible in the Files app.

## Install a release IPA

Each release attaches `Opal-X.Y.Z-ios.ipa`. It is **unsigned** and carries no
provisioning profile: install it with a sideloading tool (AltStore, Sideloadly or
similar) that signs it with your own Apple ID. Build one yourself with
`python3 scripts/ios-device.py --ipa dist/Opal-X.Y.Z-ios.ipa`; the version comes
from `build.zig.zon`, and local signing material is left out.

## Requirements

- The repository's Zig 0.17 toolchain, Xcode, XcodeGen, CMake and FFmpeg.
- Boost headers (Homebrew's `boost` package).
- An installed iOS Simulator runtime for simulator testing.
- For physical devices: Developer Mode, pairing and an existing valid development
  profile covering the device and `com.debpalash.opal.ios`, with its private
  signing identity available locally.

Native media dependencies are downloaded with pinned checksums. The build
selects the appropriate arm64 device or Simulator slices and compiles libtorrent
and Opal's torrent wrapper from source. Downloaded artifacts remain in ignored
build caches. Device and Simulator outputs are separate.

## Simulator

```sh
python3 scripts/ios-device.py --simulator --install --launch
# Run the bounded playback check against the installed build:
python3 scripts/ios-device.py --simulator --skip-build --smoke
# Select a specific installed simulator:
python3 scripts/ios-device.py --simulator --device '<name or UDID>' --install --launch
```

`--simulator` never connects to a physical device. It reuses an installed runtime
and boots an available iPhone simulator. Outputs go to `zig-out/ios-simulator`,
`.zig-cache/ios-native-simulator` and `.zig-cache/ios-simulator-xcode`.

## Physical device

```sh
python3 scripts/ios-device.py --install --launch
python3 scripts/ios-device.py --device '<device name or UDID>' --install --launch
python3 scripts/ios-device.py --skip-build --smoke
```

The default selects only paired physical devices and requires explicit selection
when several are connected. It uses an existing development profile without
changing keychain permissions or committing identities. Outputs go to
`zig-out/ios`, `.zig-cache/ios-native` and `.zig-cache/ios-xcode`.

## Playback verification

The bundled test clip is generated locally. The smoke check requires
`OPAL_IOS_SHARED_PLAYER_OK`, emitted only after the shared player's clock advances
and SDL receives a video texture. A launch alone is not a pass. The host fails
after 30 seconds and always stops the test app, including on freezes. Launch
normally afterward to explore the app. No screenshots are required by this check.

## Headless UI/feature walk

```sh
python3 scripts/ios-device.py --simulator   # build
python3 scripts/ios-uitest.py               # headless walk + screenshots
```

The runner reinstalls the app, so every run starts from a clean container. It
launches the app with `--ui-test` and never opens Simulator.app. The in-app
driver (`src/ui/ios_uitest.zig`) drives the shared pages with the same state
calls their buttons make, and checks real outcomes:

- catalog rows
- TV seasons and episodes
- source results
- comic covers
- a decoded frame from the bundled clip
- a frame from a streaming public-domain torrent (Sintel)

Each step prints `OPAL_UITEST <step> pass|fail`. The runner saves
`zig-out/ios-uitest/<step>.png`, `report.json` and `console.log`. On iOS,
`pushLog` and native HTTP failures are mirrored to that console.

## Toolchain workaround

Zig 0.17 incorrectly advertises `std.process.can_replace` on iOS, which prevents
the Threaded I/O backend from compiling. The build creates a local standard
library overlay changing only that capability. The installed compiler is not
modified; an upstream version with the correct capability needs no overlay.
