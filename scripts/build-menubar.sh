#!/usr/bin/env bash
# Build OpalMenubar.app — Swift menubar helper (LSUIElement, no dock icon).
# Talks to the Opal core over :41595 JSON API. Standalone .app output.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/helper/OpalMenubar/OpalMenubarApp.swift"
OUT_DIR="$ROOT/dist/OpalMenubar.app"
VERSION="${OPAL_VERSION:-0.0.1}"

command -v swiftc >/dev/null || { echo "[menubar] ERROR: swiftc missing (install Xcode CLT)"; exit 1; }
[ -f "$SRC" ] || { echo "[menubar] ERROR: $SRC missing"; exit 1; }

echo "[menubar] Building $OUT_DIR"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/Contents/MacOS" "$OUT_DIR/Contents/Resources"

# Compile — universal binary (arm64 + x86_64) when possible, else native.
SWIFTC_FLAGS=(-O -parse-as-library)
if [ "$(uname -m)" = "arm64" ]; then
    SWIFTC_FLAGS+=(-target arm64-apple-macos13.0)
fi
swiftc "${SWIFTC_FLAGS[@]}" "$SRC" -o "$OUT_DIR/Contents/MacOS/OpalMenubar"
chmod +x "$OUT_DIR/Contents/MacOS/OpalMenubar"

# Bundle resources (menubar icon png variants).
RES_SRC="$ROOT/helper/OpalMenubar/Resources"
if [ -d "$RES_SRC" ]; then
    cp "$RES_SRC"/*.png "$OUT_DIR/Contents/Resources/" 2>/dev/null || true
fi

cat > "$OUT_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>Opal Menubar</string>
    <key>CFBundleName</key>
    <string>OpalMenubar</string>
    <key>CFBundleIdentifier</key>
    <string>com.debpalash.opal.menubar</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>OpalMenubar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    echo "[menubar] Codesigning with: $CODESIGN_IDENTITY"
    codesign --force --sign "$CODESIGN_IDENTITY" --options runtime "$OUT_DIR"
fi

echo "[menubar] Done → $OUT_DIR"
echo "[menubar] Launch: open $OUT_DIR"
