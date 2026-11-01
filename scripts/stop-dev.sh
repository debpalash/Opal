#!/usr/bin/env bash
# Stop every Opal process a dev run can leave behind.
#
#   ./scripts/stop-dev.sh            graceful quit, then SIGTERM, then SIGKILL
#   ./scripts/stop-dev.sh --force    skip the graceful quit (no session save)
#
# Why a script: the app spawns sidecars that outlive it — the DPI-bypass proxy
# binds SO_REUSEPORT and only stops cleanly through main.zig's shutdown path, so
# a stray copy keeps LISTENing next to the next one and splits traffic; the voice
# servers and the torrent search engine (engines/nova2.py) are plain python
# children that survive a SIGKILLed parent. Two days of that and `pgrep` shows
# dozens of stale daemons.
set -uo pipefail

FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        -h|--help) awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; exit 0 ;;
        *) echo "[stop] unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

# Ask the installed app to quit through AppKit so config/session save on the
# normal teardown path. Only the release bundle answers to this name.
if (( ! FORCE )) && pgrep -f "/Applications/Opal.app/Contents/MacOS/Opal" >/dev/null; then
    echo "[stop] asking /Applications/Opal.app to quit…"
    osascript -e 'quit app "Opal"' >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
        pgrep -f "/Applications/Opal.app/Contents/MacOS/Opal" >/dev/null || break
        sleep 0.2
    done
fi

# App binaries: installed bundle, release bundle, dev skeleton, bare build.
PATTERNS=(
    "/Applications/Opal.app/Contents/MacOS/Opal"
    "dist/Opal.app/Contents/MacOS/Opal"
    "dist/Opal-dev.app/Contents/MacOS/Opal"
    "zig-out/bin/opal"
)
# Sidecars spawned by the app / dev loop.
PATTERNS+=(
    "lang_server.py"
    # Anchored on the flag so a stray editor open on the sibling zig-bypassdpi
    # checkout is not matched by the bare project name.
    "zig-bypassdpi .*--listen( |$)"
    "opal-voice-server"
    "opal-tts-server"
    "opal-stt-server"
    "Suwayomi-Server-"
    "engines/nova2.py"
)

alive() {
    local p
    for p in "${PATTERNS[@]}"; do
        pgrep -f "$p" >/dev/null 2>&1 && return 0
    done
    return 1
}

for p in "${PATTERNS[@]}"; do
    pgrep -f "$p" >/dev/null 2>&1 || continue
    echo "[stop] SIGTERM $p"
    pkill -TERM -f "$p" 2>/dev/null || true
done

for _ in $(seq 1 25); do
    alive || break
    sleep 0.2
done

if alive; then
    for p in "${PATTERNS[@]}"; do
        pgrep -f "$p" >/dev/null 2>&1 || continue
        echo "[stop] SIGKILL $p"
        pkill -KILL -f "$p" 2>/dev/null || true
    done
    sleep 0.3
fi

if alive; then
    echo "[stop] some processes survived — check: pgrep -fl 'opal|zig-bypassdpi'" >&2
    exit 1
fi
echo "[stop] all Opal processes stopped"
