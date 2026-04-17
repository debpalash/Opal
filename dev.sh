#!/usr/bin/env bash
# ZigZag Dev Server — HMR-style rebuild loop.
#
# Watches src/ tools/ build.zig. On change:
#   - Rebuild. On failure, keep old binary running (zero downtime).
#   - On success, kill old, launch new.
#   - Session restore preserves player state across restarts.
#
# Usage:  ./dev.sh              # Debug
#         ./dev.sh -r           # ReleaseFast
#         ./dev.sh -v           # Verbose (full build output)
#         ./dev.sh -- <args>    # Pass args through to the binary

IFS=$'\n\t'

# ── Flags ──────────────────────────────────────────────────────
OPTIMIZE=""
VERBOSE=0
PASSTHROUGH=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--release) OPTIMIZE="-Doptimize=ReleaseFast"; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        --) shift; PASSTHROUGH=("$@"); break ;;
        *) PASSTHROUGH+=("$1"); shift ;;
    esac
done

BIN="./zig-out/bin/zigzag"
WATCH_PATHS=(src tools build./opt/homebrew/bin/zig build.zig.zon)
PID=""
BUILD_N=0
DEBOUNCE_MS=150

# ── Colors ─────────────────────────────────────────────────────
C_DIM="\033[2m"; C_RST="\033[0m"
C_CYAN="\033[36m"; C_GREEN="\033[32m"; C_RED="\033[31m"
C_YELLOW="\033[33m"; C_MAGENTA="\033[1;35m"

log()  { printf "%b[%s]%b %b\n" "$C_DIM" "$(date +%H:%M:%S)" "$C_RST" "$*"; }
ok()   { printf "%b[%s]%b %b✓%b %b\n" "$C_DIM" "$(date +%H:%M:%S)" "$C_RST" "$C_GREEN" "$C_RST" "$*"; }
warn() { printf "%b[%s]%b %b⚠%b %b\n" "$C_DIM" "$(date +%H:%M:%S)" "$C_RST" "$C_YELLOW" "$C_RST" "$*"; }
err()  { printf "%b[%s]%b %b✗%b %b\n" "$C_DIM" "$(date +%H:%M:%S)" "$C_RST" "$C_RED" "$C_RST" "$*"; }

# ── Watcher picker ─────────────────────────────────────────────
pick_watcher() {
    command -v fswatch     >/dev/null 2>&1 && { echo "fswatch";     return; }
    command -v inotifywait >/dev/null 2>&1 && { echo "inotifywait"; return; }
    command -v watchexec   >/dev/null 2>&1 && { echo "watchexec";   return; }
    echo ""
}
WATCHER="$(pick_watcher)"
if [[ -z "$WATCHER" ]]; then
    err "No file watcher found."
    echo "  macOS:   brew install fswatch   (or watchexec)"
    echo "  Linux:   apt install inotify-tools (or cargo install watchexec-cli)"
    exit 1
fi

# ── Cleanup ────────────────────────────────────────────────────
kill_running() {
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        kill -TERM "$PID" 2>/dev/null || true
        for _ in 1 2 3 4 5; do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -KILL "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    pkill -f lang_server.py       2>/dev/null || true
    PID=""
}

cleanup() {
    echo
    warn "Shutting down…"
    kill_running
    pkill -f zigzag-voice-server 2>/dev/null || true
    pkill -f zigzag-tts-server   2>/dev/null || true
    pkill -f zigzag-stt-server   2>/dev/null || true
    exit 0
}
trap cleanup INT TERM

# ── Build + launch ─────────────────────────────────────────────
build_and_launch() {
    BUILD_N=$((BUILD_N + 1))
    local t0 t1 elapsed out rc

    if date +%s%N 2>/dev/null | grep -q N; then
        # BSD date (macOS) — no %N support; fall back to seconds.
        t0=$(date +%s)
    else
        t0=$(date +%s%N)
    fi

    printf "%b[%s]%b %b◆%b build #%d … " \
        "$C_DIM" "$(date +%H:%M:%S)" "$C_RST" "$C_CYAN" "$C_RST" "$BUILD_N"

    if (( VERBOSE )); then
        echo
        /opt/homebrew/bin/zig build $OPTIMIZE
        rc=$?
        out=""
    else
        out=$(/opt/homebrew/bin/zig build $OPTIMIZE 2>&1)
        rc=$?
    fi

    if date +%s%N 2>/dev/null | grep -q N; then
        t1=$(date +%s)
        elapsed="$(( t1 - t0 ))s"
    else
        t1=$(date +%s%N)
        elapsed="$(( (t1 - t0) / 1000000 ))ms"
    fi

    if [[ $rc -eq 0 ]]; then
        (( VERBOSE )) || printf "%bok%b %s\n" "$C_GREEN" "$C_RST" "$elapsed"
        kill_running
        if [[ ${#PASSTHROUGH[@]} -gt 0 ]]; then
            "$BIN" "${PASSTHROUGH[@]}" &
        else
            "$BIN" &
        fi
        PID=$!
        ok "launched pid=$PID  ${C_DIM}(Ctrl+C to stop)${C_RST}"
    else
        (( VERBOSE )) || printf "%bFAIL%b %s\n" "$C_RED" "$C_RST" "$elapsed"
        if (( ! VERBOSE )); then
            echo "$out" \
                | grep -v "warning(link)" \
                | grep -E "(error:|note:|\.zig:[0-9]+:[0-9]+:)" \
                | head -20 \
                | sed "s/^/  /"
        fi
        if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
            warn "Keeping previous build running (pid=$PID)"
        fi
    fi
}

# ── Banner ─────────────────────────────────────────────────────
printf "%b╔════════════════════════════════════════════╗%b\n" "$C_MAGENTA" "$C_RST"
printf "%b║  ZigZag Dev Server                         ║%b\n" "$C_MAGENTA" "$C_RST"
printf "%b║  watcher: %-32s ║%b\n" "$C_MAGENTA" "$WATCHER" "$C_RST"
printf "%b║  mode:    %-32s ║%b\n" "$C_MAGENTA" "${OPTIMIZE:-Debug}" "$C_RST"
OLD_IFS="$IFS"; IFS=' '; PATHS_STR="${WATCH_PATHS[*]}"; IFS="$OLD_IFS"
printf "%b║  paths:   %-32s ║%b\n" "$C_MAGENTA" "$PATHS_STR" "$C_RST"
printf "%b╚════════════════════════════════════════════╝%b\n" "$C_MAGENTA" "$C_RST"

build_and_launch

# ── Watch loop (per-watcher) ────────────────────────────────────
debounce() { sleep "$(awk "BEGIN{printf \"%.3f\", $DEBOUNCE_MS/1000}")"; }

case "$WATCHER" in
    fswatch)
        fswatch -0 -o -r \
            --exclude 'zig-cache' --exclude 'zig-out' --exclude '\.zig-cache' \
            --exclude '\.swp$' --exclude '~$' --exclude '\.git' \
            "${WATCH_PATHS[@]}" \
        | while IFS= read -r -d '' _ ; do
            debounce
            log "change detected"
            build_and_launch
        done
        ;;
    inotifywait)
        while true; do
            inotifywait -qq -r -e modify,create,delete,move \
                --exclude '(\.git|zig-cache|zig-out|\.swp|~$)' \
                "${WATCH_PATHS[@]}"
            debounce
            log "change detected"
            build_and_launch
        done
        ;;
    watchexec)
        # Hand off process management to watchexec.
        kill_running
        log "watchexec will manage the child process"
        exec watchexec \
            --no-vcs-ignore \
            --ignore 'zig-cache/**' --ignore 'zig-out/**' --ignore '.zig-cache/**' \
            --ignore '*.swp' --ignore '*~' \
            --watch src --watch tools --watch build.zig --watch build.zig.zon \
            --on-busy-update restart --stop-signal SIGTERM \
            -- bash -c "/opt/homebrew/bin/zig build $OPTIMIZE && exec $BIN ${PASSTHROUGH[*]:-}"
        ;;
esac
