#!/usr/bin/env bash
# Build the ReleaseFast macOS bundle and install it to /Applications.
#
#   ./scripts/install-app.sh                 build + install + launch
#   ./scripts/install-app.sh --skip-build    reuse the existing dist/Opal.app
#   ./scripts/install-app.sh --no-launch     install without opening it
#   ./scripts/install-app.sh --dest DIR      install somewhere other than /Applications
#   ./scripts/install-app.sh --sign IDENTITY codesign with a real identity (default: ad-hoc)
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

while (( $# > 0 )); do
    case "$1" in
        --skip-build) BUILD=0 ;;
        --no-launch) LAUNCH=0 ;;
        --dest) shift; DEST_DIR="${1:?--dest needs a directory}"; DEST="$DEST_DIR/Opal.app" ;;
        --dest=*) DEST_DIR="${1#--dest=}"; DEST="$DEST_DIR/Opal.app" ;;
        --sign) shift; SIGN="${1:?--sign needs an identity}" ;;
        --sign=*) SIGN="${1#--sign=}" ;;
        -h|--help) awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; exit 0 ;;
        *) echo "[install] unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
done

SRC="$ROOT/dist/Opal.app"

if (( BUILD )); then
    echo "[install] building the release bundle…"
    CODESIGN_IDENTITY="$SIGN" "$ROOT/scripts/build-app.sh"
fi
[ -d "$SRC" ] || { echo "[install] ERROR: $SRC missing (run without --skip-build)" >&2; exit 1; }

# Copy and validate before touching the working installation. Keep staging on
# the destination filesystem so the final moves do not copy a partial bundle.
mkdir -p "$DEST_DIR"
if [ "$SRC" -ef "$DEST" ]; then
    echo "[install] ERROR: destination is the source bundle" >&2
    exit 1
fi
STAGING=$(mktemp -d "$DEST_DIR/.opal-install.XXXXXX")
cleanup() {
    if [ -d "$STAGING/previous.app" ] && [ ! -e "$DEST" ]; then
        mv "$STAGING/previous.app" "$DEST"
    fi
    rm -rf "$STAGING"
}
trap cleanup EXIT

echo "[install] staging → $DEST"
ditto "$SRC" "$STAGING/Opal.app"
xattr -cr "$STAGING/Opal.app" 2>/dev/null || true
if ! codesign --verify --deep --strict "$STAGING/Opal.app" >/dev/null 2>&1; then
    echo "[install] WARNING: signature check failed — re-signing ad-hoc"
    codesign --force --deep --sign - "$STAGING/Opal.app"
    codesign --verify --deep --strict "$STAGING/Opal.app"
fi

# Do not replace a bundle if its process could not be stopped.
"$ROOT/scripts/stop-dev.sh"
if [ -e "$DEST" ]; then
    mv "$DEST" "$STAGING/previous.app"
fi
mv "$STAGING/Opal.app" "$DEST"
echo "[install] signature ok"

echo "[install] installed $(defaults read "$DEST/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"

if (( LAUNCH )); then
    echo "[install] launching…"
    open "$DEST"
    sleep 2
    pgrep -f "$DEST/Contents/MacOS/Opal" >/dev/null \
        && echo "[install] running (pid $(pgrep -f "$DEST/Contents/MacOS/Opal" | head -1))" \
        || { echo "[install] ERROR: app did not stay running" >&2; exit 1; }
fi
