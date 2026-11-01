#!/usr/bin/env bash
# Build the ReleaseFast macOS bundle and install it to /Applications.
#
#   ./scripts/install.sh                 build + install + launch
#   ./scripts/install.sh --skip-build    reuse the existing dist/Opal.app
#   ./scripts/install.sh --no-launch     install without opening it
#   ./scripts/install.sh --dest DIR      install somewhere other than /Applications
#   ./scripts/install.sh --sign IDENTITY codesign with a real identity (default: ad-hoc)
#
# This is the "does the installed app behave like the dev build" step. It is not
# the same as `open dist/Opal.app`: launching from dist/ resolves resources
# against the checkout, while an installed bundle resolves them from
# Contents/Resources and runs with CWD=/ — which is where missing sidecars,
# unwritable paths and stale saved settings show up.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="/Applications"
DEST="$DEST_DIR/Opal.app"
BUILD=1
LAUNCH=1
SIGN="${CODESIGN_IDENTITY:-}"

for arg in "$@"; do
    case "$arg" in
        --skip-build) BUILD=0 ;;
        --no-launch) LAUNCH=0 ;;
        --dest) shift; DEST_DIR="${1:?--dest needs a directory}"; DEST="$DEST_DIR/Opal.app" ;;
        --dest=*) DEST_DIR="${arg#--dest=}"; DEST="$DEST_DIR/Opal.app" ;;
        --sign) shift; SIGN="${1:?--sign needs an identity}" ;;
        --sign=*) SIGN="${arg#--sign=}" ;;
        -h|--help) awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; exit 0 ;;
        *) echo "[install] unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

SRC="$ROOT/dist/Opal.app"

if (( BUILD )); then
    echo "[install] building the release bundle…"
    CODESIGN_IDENTITY="$SIGN" "$ROOT/scripts/build-app.sh"
fi
[ -d "$SRC" ] || { echo "[install] ERROR: $SRC missing (run without --skip-build)" >&2; exit 1; }

# Quit the running copy first: replacing the bundle under a live process leaves
# macOS running the old inode, and the next launch silently reopens the old code.
"$ROOT/scripts/stop-dev.sh" >/dev/null 2>&1 || true

echo "[install] installing → $DEST"
mkdir -p "$DEST_DIR"
rm -rf "$DEST"
# ditto keeps the bundle's symlinks/permissions intact; cp -R on a signed .app
# can drop xattrs that codesign validates against.
ditto "$SRC" "$DEST"
# Quarantine flags from a downloaded/zipped build would make Gatekeeper refuse
# the ad-hoc signature on first launch.
xattr -cr "$DEST" 2>/dev/null || true

if codesign --verify --deep --strict "$DEST" >/dev/null 2>&1; then
    echo "[install] signature ok"
else
    echo "[install] WARNING: signature check failed — re-signing ad-hoc"
    codesign --force --deep --sign - "$DEST"
fi

echo "[install] installed $(defaults read "$DEST/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"

if (( LAUNCH )); then
    echo "[install] launching…"
    open "$DEST"
    sleep 2
    pgrep -f "$DEST/Contents/MacOS/Opal" >/dev/null \
        && echo "[install] running (pid $(pgrep -f "$DEST/Contents/MacOS/Opal" | head -1))" \
        || { echo "[install] ERROR: app did not stay running" >&2; exit 1; }
fi
