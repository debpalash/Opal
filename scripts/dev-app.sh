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
# is refreshed each build via a hardlink (same inode, zero copy). Launching the
# binary from inside Contents/MacOS/ makes NSBundle.mainBundle resolve to this
# .app. dev.sh keeps CWD at the project root, so CWD-relative resource lookups
# (engines/, web/, plugins-manifest.json) still win before SDL_GetBasePath.
#
# Prints the path to launch on success (Contents/MacOS/Opal).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/zig-out/bin/opal"
APP="$ROOT/dist/Opal-dev.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
EXE="$MACOS/Opal"

[ -f "$BIN" ] || { echo "[dev-app] ERROR: $BIN missing (build first)" >&2; exit 1; }

mkdir -p "$MACOS" "$RES"

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

# ── Refresh the executable each build. Hardlink = same inode, no copy; zig
#    replaces the build output with a new inode each rebuild, so re-link every
#    time. Fall back to copy if hardlink fails (e.g. cross-filesystem).
ln -f "$BIN" "$EXE" 2>/dev/null || cp -f "$BIN" "$EXE"
chmod +x "$EXE"

echo "$EXE"
