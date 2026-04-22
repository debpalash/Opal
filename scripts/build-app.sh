#!/usr/bin/env bash
# Build Opal.app macOS bundle from zig-out/bin/zigzag.
# Optional codesign + notarize if CODESIGN_IDENTITY + APPLE_ID env set.
# Optional DMG packaging via create-dmg (brew install create-dmg) if present.
set -euo pipefail

ZIG=/opt/homebrew/bin/zig
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/dist/Opal.app"
BIN_PATH="$ROOT/zig-out/bin/zigzag"
VERSION="${OPAL_VERSION:-0.0.1}"

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

# Rewrite any transitive homebrew links inside bundled dylibs so they also
# resolve via @executable_path instead of /opt/homebrew (required on hosts
# without the same brew layout).
for LIB in "$DYLIB_DIR"/*.dylib "$DYLIB_DIR"/*.so; do
    [ -f "$LIB" ] || continue
    for SUB in $(otool -L "$LIB" 2>/dev/null | awk 'NR>1 {print $1}' | grep -E "^/opt/homebrew|^/usr/local" || true); do
        SUB_NAME="$(basename "$SUB")"
        # Copy transitive dep if missing
        if [ ! -f "$DYLIB_DIR/$SUB_NAME" ] && [ -f "$SUB" ]; then
            cp -L "$SUB" "$DYLIB_DIR/$SUB_NAME"
        fi
        install_name_tool -change "$SUB" "@executable_path/../Frameworks/$SUB_NAME" "$LIB" 2>/dev/null || true
    done
done

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

# ── 6. Optional codesign ───────────────────────────────────────
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    echo "[build-app] Codesigning with identity: $CODESIGN_IDENTITY"
    codesign --deep --force --sign "$CODESIGN_IDENTITY" \
        --options runtime \
        --entitlements "$ROOT/scripts/opal.entitlements" \
        "$APP_DIR"
else
    echo "[build-app] (no CODESIGN_IDENTITY env — skipping codesign; app runs locally but won't pass Gatekeeper on other Macs)"
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
