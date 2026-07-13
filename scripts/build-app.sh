#!/usr/bin/env bash
# Build Opal.app macOS bundle from zig-out/bin/opal.
# Optional codesign + notarize if CODESIGN_IDENTITY + APPLE_ID env set.
# Optional DMG packaging via create-dmg (brew install create-dmg) if present.
set -euo pipefail

ZIG=${ZIG:-zig}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/dist/Opal.app"
BIN_PATH="$ROOT/zig-out/bin/opal"
# Version: explicit override → build.zig.zon's .version → fallback.
# (The release workflow builds from a tag whose version lives in the zon.)
ZON_VERSION=$(sed -n 's/^[[:space:]]*\.version = "\(.*\)",$/\1/p' "$(dirname "$0")/../build.zig.zon" 2>/dev/null | head -1)
VERSION="${OPAL_VERSION:-${ZON_VERSION:-0.1.0}}"

cd "$ROOT"

# ── 1. Build release binary ────────────────────────────────────
echo "[build-app] Compiling ReleaseFast…"
"$ZIG" build -Doptimize=ReleaseFast

[ -f "$BIN_PATH" ] || { echo "[build-app] ERROR: $BIN_PATH missing"; exit 1; }

# ── 2. Clean + lay out bundle ──────────────────────────────────
echo "[build-app] Building $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/Opal"
chmod +x "$APP_DIR/Contents/MacOS/Opal"

# ── 2b. Bundle runtime resources resolved relative to the resource root ────────
# The app spawns `python3 engines/nova2.py` (torrent search). From a /Applications
# launch the CWD is "/", so the binary locates these via SDL_GetBasePath() →
# Contents/Resources/. Copy the lightweight (Python) resource dirs in.
echo "[build-app] Bundling runtime resources (engines/)…"
if [ -d "$ROOT/engines" ]; then
    cp -R "$ROOT/engines" "$APP_DIR/Contents/Resources/engines"
    # Drop caches so the bundle stays lean + reproducible.
    find "$APP_DIR/Contents/Resources/engines" -name "__pycache__" -type d -prune -exec rm -rf {} + 2>/dev/null || true
fi

# Bundle the voice helper scripts. ai_voice spawns `python3 bin/opal-voice-server.py`
# (hands-free conversation: VAD + live partials + full-duplex barge-in), plus the
# STT/TTS sidecars. Without these in Resources, an installed .app finds no voice
# server (CWD is "/") and conversation mode silently degrades to the finals-only
# fallback loop — the full-duplex path would never run outside a dev checkout.
echo "[build-app] Bundling voice helpers (bin/*.py)…"
mkdir -p "$APP_DIR/Contents/Resources/bin"
for f in "$ROOT"/bin/opal-*.py "$ROOT"/bin/requirements.txt; do
    [ -f "$f" ] && cp "$f" "$APP_DIR/Contents/Resources/bin/"
done

# Bundle the source-plugin manifest so the Plugins page shows the full list
# instantly + offline (plugin_repo.loadLocalManifest reads it from Resources).
if [ -f "$ROOT/plugins-manifest.json" ]; then
    cp "$ROOT/plugins-manifest.json" "$APP_DIR/Contents/Resources/plugins-manifest.json"
fi

# Bundle the web companion (single self-contained page) — remote.zig serves
# it at / from Resources/web when Web Remote is enabled.
if [ -f "$ROOT/web/index.html" ]; then
    mkdir -p "$APP_DIR/Contents/Resources/web"
    cp "$ROOT/web/index.html" "$APP_DIR/Contents/Resources/web/index.html"
fi

# ── 3. Info.plist ──────────────────────────────────────────────
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>Opal</string>
    <key>CFBundleName</key>
    <string>Opal</string>
    <key>CFBundleIdentifier</key>
    <string>com.debpalash.opal</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Opal contributors — GPL-3.0. Play everything.</string>
    <key>CFBundleExecutable</key>
    <string>Opal</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSupportedPlatforms</key>
    <array><string>MacOSX</string></array>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Opal uses the microphone for voice chat with its AI copilot.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Opal transcribes your voice locally via whisper/sherpa — no cloud.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Opal opens Terminal to run installation commands you trigger from the setup modal.</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.entertainment</string>
    <key>NSCameraUsageDescription</key>
    <string>Not used — declared for future video features.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Video</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.movie</string>
                <string>public.video</string>
                <string>public.mpeg-4</string>
                <string>com.apple.quicktime-movie</string>
                <string>public.avi</string>
                <string>org.matroska.mkv</string>
                <string>public.mpeg</string>
                <string>public.mpeg-2-video</string>
            </array>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>mp4</string>
                <string>m4v</string>
                <string>mov</string>
                <string>avi</string>
                <string>mkv</string>
                <string>wmv</string>
                <string>flv</string>
                <string>webm</string>
                <string>mpg</string>
                <string>mpeg</string>
                <string>3gp</string>
                <string>ts</string>
                <string>mts</string>
                <string>m2ts</string>
                <string>vob</string>
                <string>ogv</string>
                <string>rmvb</string>
                <string>asf</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Audio</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.audio</string>
                <string>public.mp3</string>
                <string>public.mpeg-4-audio</string>
                <string>com.apple.m4a-audio</string>
                <string>org.xiph.flac</string>
            </array>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>mp3</string>
                <string>m4a</string>
                <string>aac</string>
                <string>flac</string>
                <string>ogg</string>
                <string>opus</string>
                <string>wav</string>
                <string>wma</string>
                <string>aiff</string>
                <string>mka</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Subtitle</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>srt</string>
                <string>ass</string>
                <string>ssa</string>
                <string>sub</string>
                <string>vtt</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Playlist</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>m3u</string>
                <string>m3u8</string>
                <string>pls</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Torrent</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>torrent</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Comic Archive</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>cbz</string>
                <string>cbr</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# ── 4. Optional icon (assets/opal_logo.png → .icns) ────────────
if [ -f "$ROOT/assets/opal_logo.png" ] && command -v sips >/dev/null && command -v iconutil >/dev/null; then
    echo "[build-app] Generating icon…"
    ICON_SET="$APP_DIR/Contents/Resources/opal.iconset"
    mkdir -p "$ICON_SET"
    for SIZE in 16 32 64 128 256 512; do
        sips -s format png -z $SIZE $SIZE "$ROOT/assets/opal_logo.png" \
            --out "$ICON_SET/icon_${SIZE}x${SIZE}.png" >/dev/null 2>&1 || true
        DOUBLE=$((SIZE * 2))
        sips -s format png -z $DOUBLE $DOUBLE "$ROOT/assets/opal_logo.png" \
            --out "$ICON_SET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null 2>&1 || true
    done
    iconutil -c icns "$ICON_SET" -o "$APP_DIR/Contents/Resources/opal.icns" 2>/dev/null || \
        echo "[build-app] (icon pack skipped — source PNG may not be valid)"
    rm -rf "$ICON_SET"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string opal" \
        "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
fi

# ── Credits.rtf — the standard macOS About panel (app menu → About Opal)
# renders this in its scrollable body, hyperlinks included. This is what
# turns the bare icon+version panel into a real About window. Shared source
# in assets/ so the dev-app skeleton (scripts/dev-app.sh) uses the same text.
if [ -f "$ROOT/assets/Credits.rtf" ]; then
    cp "$ROOT/assets/Credits.rtf" "$APP_DIR/Contents/Resources/Credits.rtf"
    echo "[build-app] Credits.rtf written (About panel body)"
fi

# ── 5. Bundle dylibs (mpv, libtorrent_wrapper, onnxruntime) ────
# Copy whatever the binary links so the app runs on systems without brew.
echo "[build-app] Bundling dylibs…"
DYLIB_DIR="$APP_DIR/Contents/Frameworks"
mkdir -p "$DYLIB_DIR"

for DEP in $(otool -L "$APP_DIR/Contents/MacOS/Opal" 2>/dev/null | awk 'NR>1 {print $1}' | grep -E "^/opt/homebrew|^/usr/local" || true); do
    NAME="$(basename "$DEP")"
    if [ -f "$DEP" ]; then
        cp -L "$DEP" "$DYLIB_DIR/$NAME"
        install_name_tool -change "$DEP" "@executable_path/../Frameworks/$NAME" \
            "$APP_DIR/Contents/MacOS/Opal"
    fi
done
# Also bundle the torrent wrapper shared lib if present.
# The binary links it with a bare install_name ("libtorrent_wrapper.so"), so
# launching via Finder/NSWorkspace (CWD=/) cannot find it. Rewrite the path.
if [ -f "$ROOT/libtorrent_wrapper.so" ]; then
    cp "$ROOT/libtorrent_wrapper.so" "$DYLIB_DIR/"
    install_name_tool -change "libtorrent_wrapper.so" \
        "@executable_path/../Frameworks/libtorrent_wrapper.so" \
        "$APP_DIR/Contents/MacOS/Opal" 2>/dev/null || true
fi

# Rewrite transitive homebrew links inside bundled dylibs. Libraries can have
# deep dependency chains (e.g. libavdevice→libavfilter→libavutil→libssl), so
# we loop until no new dependencies are discovered (max 10 passes).
PASS=0
while [ $PASS -lt 10 ]; do
    PASS=$((PASS + 1))
    FOUND_NEW=0
    for LIB in "$DYLIB_DIR"/*.dylib "$DYLIB_DIR"/*.so; do
        [ -f "$LIB" ] || continue
        for SUB in $(otool -L "$LIB" 2>/dev/null | awk 'NR>1 {print $1}' | grep -E "^/opt/homebrew|^/usr/local" || true); do
            SUB_NAME="$(basename "$SUB")"
            # Copy transitive dep if missing
            if [ ! -f "$DYLIB_DIR/$SUB_NAME" ] && [ -f "$SUB" ]; then
                cp -L "$SUB" "$DYLIB_DIR/$SUB_NAME"
                FOUND_NEW=1
            fi
            install_name_tool -change "$SUB" "@executable_path/../Frameworks/$SUB_NAME" "$LIB" 2>/dev/null || true
        done
        # Also fix the library's own install name if it points to homebrew
        OWN_ID=$(otool -D "$LIB" 2>/dev/null | tail -1)
        case "$OWN_ID" in /opt/homebrew*|/usr/local*)
            install_name_tool -id "@executable_path/../Frameworks/$(basename "$LIB")" "$LIB" 2>/dev/null || true
        ;; esac
    done
    [ $FOUND_NEW -eq 0 ] && break
    echo "[build-app]   dylib pass $PASS — found new deps, continuing…"
done
echo "[build-app]   dylib resolution done after $PASS pass(es)"

# ── 5b. Embed OpalMenubar helper (LSUIElement) ────────────────
# Built separately by scripts/build-menubar.sh. Embedded as LoginItem
# so macOS 13+ SMAppService can register it for auto-launch later.
HELPER_SRC="$ROOT/dist/OpalMenubar.app"
if [ ! -d "$HELPER_SRC" ] && [ -x "$ROOT/scripts/build-menubar.sh" ]; then
    echo "[build-app] Helper missing — building it now…"
    "$ROOT/scripts/build-menubar.sh" || echo "[build-app] (menubar build failed — continuing without helper)"
fi
if [ -d "$HELPER_SRC" ]; then
    echo "[build-app] Embedding OpalMenubar helper…"
    LOGIN_ITEMS="$APP_DIR/Contents/Library/LoginItems"
    mkdir -p "$LOGIN_ITEMS"
    cp -R "$HELPER_SRC" "$LOGIN_ITEMS/"
fi

# Dylibs copied from Homebrew's Cellar arrive mode 444 and the zip/dmg
# preserves that — users then can't `xattr -cr` the installed bundle without
# sudo (Gatekeeper-workaround UX). Normalize to owner-writable before signing.
chmod -R u+w "$APP_DIR"

# ── 6. Optional codesign ───────────────────────────────────────
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    echo "[build-app] Codesigning with identity: $CODESIGN_IDENTITY"
    codesign --deep --force --sign "$CODESIGN_IDENTITY" \
        --options runtime \
        --entitlements "$ROOT/scripts/opal.entitlements" \
        "$APP_DIR"
else
    echo "[build-app] No CODESIGN_IDENTITY — ad-hoc signing (required after install_name_tool)"
    codesign --force --deep --sign - "$APP_DIR"
fi

# ── 7. Optional DMG ────────────────────────────────────────────
if command -v create-dmg >/dev/null; then
    DMG_PATH="$ROOT/dist/Opal-$VERSION.dmg"
    rm -f "$DMG_PATH"
    echo "[build-app] Creating DMG…"
    create-dmg \
        --volname "Opal $VERSION" \
        --window-size 500 320 \
        --icon-size 100 \
        --app-drop-link 370 160 \
        --icon Opal.app 130 160 \
        "$DMG_PATH" \
        "$APP_DIR" >/dev/null || echo "[build-app] create-dmg failed (non-fatal)"
    echo "[build-app] DMG: $DMG_PATH"
fi

echo "[build-app] Done → $APP_DIR"
echo "[build-app] Launch: open $APP_DIR"
