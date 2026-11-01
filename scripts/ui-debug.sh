#!/usr/bin/env bash
# Debug build + launch with dvui's widget inspector open (the UI debugger).
#
#   ./scripts/ui-debug.sh                build, then open the inspector
#   ./scripts/ui-debug.sh --no-inspector build and launch without it
#   ./scripts/ui-debug.sh -v             verbose build output
#   ./scripts/ui-debug.sh -- file.mkv    pass arguments through to the app
#
# What the inspector is: dvui's own debug window (OPAL_UI_DEBUG=1). It lists the
# widget tree with ids, rects and visibility, opens a per-widget options editor
# (edit padding/margin/color live), shows frame times, and can log every refresh
# and event with its source location. That is how you answer "why did this click
# land on the wrong widget" or "why is this box 2px tall" without guessing.
#
# Toggle it at runtime with Ctrl/Cmd+Shift+D (Debug builds only). Release builds
# never bind the key, so a viewer cannot trip over the debug outline.
#
# The debug binary is wrapped in dist/Opal-dev.app so macOS gives it a real
# bundle identity (name, Dock icon, About panel); CWD stays the repo root so
# checkout-relative resources (engines/, web/) still resolve.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSPECTOR=1
VERBOSE=0
PASSTHROUGH=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-inspector) INSPECTOR=0; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        --) shift; PASSTHROUGH=("$@"); break ;;
        -h|--help) awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; exit 0 ;;
        *) PASSTHROUGH+=("$1"); shift ;;
    esac
done

cd "$ROOT"

echo "[ui-debug] building Debug…"
if (( VERBOSE )); then
    "${ZIG:-zig}" build
else
    out=$("${ZIG:-zig}" build 2>&1) || {
        echo "$out" | grep -E "(error:|note:|\.zig:[0-9]+:[0-9]+:)" | head -30 | sed 's/^/  /'
        exit 1
    }
fi

EXE=$("$ROOT/scripts/dev-app.sh") || EXE="$ROOT/zig-out/bin/opal"

if (( INSPECTOR )); then
    export OPAL_UI_DEBUG=1
    echo "[ui-debug] inspector on (Ctrl/Cmd+Shift+D toggles it)"
else
    unset OPAL_UI_DEBUG
fi

if [[ ${#PASSTHROUGH[@]} -gt 0 ]]; then
    echo "[ui-debug] launch: $EXE ${PASSTHROUGH[*]}"
    exec "$EXE" "${PASSTHROUGH[@]}"
else
    echo "[ui-debug] launch: $EXE"
    exec "$EXE"
fi
