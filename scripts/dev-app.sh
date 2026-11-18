#!/usr/bin/env bash
# Wrap the *debug* binary (zig-out/bin/opal) in a lightweight .app skeleton so
# macOS gives the dev run a real bundle identity: "Opal" (uppercase) in the menu
# bar, the logo in the Dock + native About panel, and the Credits.rtf About body.
#
# Why this exists: a bare Mach-O binary has no bundle, so macOS names the app
# after the executable file ("opal", lowercase) and the "About" panel is the
# empty generic one with a folder icon. SDL's macOS backend reads the name from
# CFBundleName/CFBundleDisplayName (or the process name) — it never consults
# SDL_HINT_APP_NAME — so only a real bundle fixes this.
#
# The skeleton is static (Info.plist + icns + Credits.rtf); only the executable
# is copied each build before patching its bundle-local library path. Launching the
# binary from inside Contents/MacOS/ makes NSBundle.mainBundle resolve to this
# .app. Resource symlinks also support Finder launches with CWD=/ while
# keeping development edits to engines, scripts, and web assets live.
#
# Prints the path to launch on success (Contents/MacOS/Opal).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/zig-out/bin/opal"
APP="$ROOT/dist/Opal-dev.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
FRAMEWORKS="$APP/Contents/Frameworks"
EXE="$MACOS/Opal"

[ -f "$BIN" ] || { echo "[dev-app] ERROR: $BIN missing (build first)" >&2; exit 1; }

mkdir -p "$MACOS" "$RES" "$FRAMEWORKS"

# ── Info.plist (static) ────────────────────────────────────────
if [ ! -f "$APP/Contents/Info.plist" ]; then
    cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key><string>Opal</string>
    <key>CFBundleName</key><string>Opal</string>
    <key>CFBundleIdentifier</key><string>com.debpalash.opal.dev</string>
    <key>CFBundleExecutable</key><string>Opal</string>
    <key>CFBundleIconFile</key><string>opal</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>dev</string>
    <key>CFBundleVersion</key><string>dev</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Palash Deb — GPL-3.0. Play everything.</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Video</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Default</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>mp4</string><string>m4v</string><string>mov</string>
                <string>avi</string><string>mkv</string><string>webm</string>
                <string>mpg</string><string>mpeg</string><string>ts</string>
                <string>mts</string><string>m2ts</string><string>ogv</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Audio</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Default</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>mp3</string><string>m4a</string><string>aac</string>
                <string>flac</string><string>ogg</string><string>opus</string>
                <string>wav</string><string>mka</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Playlist</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Default</string>
            <key>CFBundleTypeExtensions</key>
            <array><string>m3u</string><string>m3u8</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Torrent</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Default</string>
            <key>CFBundleTypeExtensions</key>
            <array><string>torrent</string></array>
        </dict>
    </array>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>CFBundleURLName</key><string>Magnet Link</string>
            <key>CFBundleURLSchemes</key>
            <array><string>magnet</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST
fi

# ── Icon (reuse the release bundle's icns if present, else generate) ──
if [ ! -f "$RES/opal.icns" ]; then
    if [ -f "$ROOT/dist/Opal.app/Contents/Resources/opal.icns" ]; then
        cp "$ROOT/dist/Opal.app/Contents/Resources/opal.icns" "$RES/opal.icns"
    elif [ -f "$ROOT/assets/opal_logo.png" ] && command -v sips >/dev/null && command -v iconutil >/dev/null; then
        SET="$RES/opal.iconset"; mkdir -p "$SET"
        for S in 16 32 64 128 256 512; do
            sips -s format png -z "$S" "$S" "$ROOT/assets/opal_logo.png" --out "$SET/icon_${S}x${S}.png" >/dev/null 2>&1 || true
            D=$((S * 2))
            sips -s format png -z "$D" "$D" "$ROOT/assets/opal_logo.png" --out "$SET/icon_${S}x${S}@2x.png" >/dev/null 2>&1 || true
        done
        iconutil -c icns "$SET" -o "$RES/opal.icns" 2>/dev/null || true
        rm -rf "$SET"
    fi
fi

# ── Credits.rtf (About panel body) ─────────────────────────────
[ -f "$ROOT/assets/Credits.rtf" ] && cp "$ROOT/assets/Credits.rtf" "$RES/Credits.rtf"

# Finder starts with CWD=/, so provide the same resource paths as build-app.sh.
# Symlinks keep this development bundle lightweight and source edits live.
for resource in engines scripts bin web; do
    [ ! -d "$ROOT/$resource" ] || ln -sfn "$ROOT/$resource" "$RES/$resource"
done
for resource in plugins-manifest.json manga-sources-sfw.json; do
    [ ! -f "$ROOT/data/$resource" ] || ln -sfn "$ROOT/data/$resource" "$RES/$resource"
done
[ ! -d "$ROOT/assets/browser-integration" ] || ln -sfn "$ROOT/assets/browser-integration" "$RES/browser-integration"
[ ! -f "$ROOT/zig-out/bin/zig-bypassdpi" ] || ln -sfn "$ROOT/zig-out/bin/zig-bypassdpi" "$RES/zig-bypassdpi"
[ ! -f "$ROOT/zig-out/bin/opal-mcp" ] || ln -sfn "$ROOT/zig-out/bin/opal-mcp" "$MACOS/opal-mcp"

# Remove the previous executable first: older bundles hardlinked it to BIN.
# Patching or signing a hardlink would also mutate Zig's original build output.
rm -f "$EXE"
cp "$BIN" "$EXE"
chmod +x "$EXE"

# The local wrapper has a bare install name; Finder cannot resolve it from /.
WRAPPER="$ROOT/libtorrent_wrapper.so"
[ -f "$WRAPPER" ] || { echo "[dev-app] ERROR: $WRAPPER missing (build first)" >&2; exit 1; }
rm -f "$FRAMEWORKS/libtorrent_wrapper.so"
cp "$WRAPPER" "$FRAMEWORKS/libtorrent_wrapper.so"
install_name_tool -change "libtorrent_wrapper.so" \
    "@executable_path/../Frameworks/libtorrent_wrapper.so" "$EXE"
# install_name_tool invalidates the Mach-O signature. Sign the copied wrapper
# first, then the bundle (including its main executable and resource seal).
codesign --force --sign - "$FRAMEWORKS/libtorrent_wrapper.so" >&2
codesign --force --sign - "$APP" >&2

echo "$EXE"
