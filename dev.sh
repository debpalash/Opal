#!/usr/bin/env bash
# Opal Dev Server — HMR-style rebuild loop.
#
# Watches src/ tools/ build.zig. On change:
#   - Rebuild. On failure, keep old binary running (zero downtime).
#   - On success, kill old, launch new.
#   - Session restore preserves player state across restarts.
#   - OPAL_DEV_RELOAD=1 tells the app this is a dev reload, so it restores the
#     full UI position (page, search, Settings section, TV detail, scroll) no
#     matter how long the last run lasted (ui/ui_restore.zig).
#   - Rebuilds try Zig incremental compilation (-fincremental). If it bails
#     (unsupported linker/backend, C or build.zig changes), the same change is
#     rebuilt normally; a compiler panic turns incremental off for the session.
#
# Usage:  ./dev.sh              # Debug
#         ./dev.sh -r           # ReleaseFast
#         ./dev.sh -v           # Verbose (full build output)
#         ./dev.sh -n           # No incremental (plain `zig build` every time)
#         ./dev.sh -- <args>    # Pass args through to the binary

IFS=$'\n\t'

# ── Flags ──────────────────────────────────────────────────────
OPTIMIZE=""
VERBOSE=0
INCREMENTAL=1
PASSTHROUGH=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--release) OPTIMIZE="-Doptimize=fast"; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -n|--no-incremental) INCREMENTAL=0; shift ;;
        --) shift; PASSTHROUGH=("$@"); break ;;
        *) PASSTHROUGH+=("$1"); shift ;;
    esac
done

BIN="./zig-out/bin/opal"
WATCH_PATHS=(src tools build.${ZIG:-zig} build.zig.zon)
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
    # The DPI-bypass proxy only stops cleanly via main.zig's shutdown path, which
    # a SIGKILL above never reaches. It binds SO_REUSEPORT, so a survivor keeps
    # LISTENing alongside the next one instead of failing — 57 of them piled up
    # over two days, splitting traffic across stale --mode settings.
    pkill -f zig-bypassdpi        2>/dev/null || true
    PID=""
}

cleanup() {
    echo
    warn "Shutting down…"
    kill_running
    pkill -f opal-voice-server 2>/dev/null || true
    pkill -f opal-tts-server   2>/dev/null || true
    pkill -f opal-stt-server   2>/dev/null || true
    pkill -f Suwayomi-Server-  2>/dev/null || true
    pkill -f engines/nova2.py  2>/dev/null || true
    exit 0
}
trap cleanup INT TERM

# Marks every app launched from here as a dev reload (see header).
export OPAL_DEV_RELOAD=1

# ── Build ──────────────────────────────────────────────────────
# A real Zig compile error ("file.zig:L:C: error:") is the user's to fix — a
# plain rebuild would only fail again, slower. Any other incremental failure
# is the compiler/linker bailing, so retry the same change without it.
is_source_error() { grep -Eq '\.zig:[0-9]+:[0-9]+: error:' <<<"$1"; }

# Runs one build; sets `out` (captured output) and `rc`. Verbose streams it too.
zig_build() {
    if (( VERBOSE )); then
        echo
        local log
        log=$(mktemp "${TMPDIR:-/tmp}/opal-dev-build.XXXXXX")
        ${ZIG:-zig} build $OPTIMIZE "$@" 2>&1 | tee "$log"
        rc=${PIPESTATUS[0]}
        out=$(cat "$log"); rm -f "$log"
    else
        out=$(${ZIG:-zig} build $OPTIMIZE "$@" 2>&1)
        rc=$?
    fi
}

run_build() {
    if (( INCREMENTAL )); then
        zig_build -fincremental
        if [[ $rc -eq 0 ]] || is_source_error "$out"; then return; fi
        (( VERBOSE )) || echo
        if grep -q "panic" <<<"$out"; then
            INCREMENTAL=0
            warn "incremental compilation crashed the compiler here; plain builds for this session (-n skips the attempt)"
        else
            warn "incremental build bailed; rebuilding normally"
        fi
    fi
    zig_build
}

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

    run_build

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
        # Launch through a lightweight .app skeleton so macOS gives the dev run a
        # real bundle identity (name "Opal", logo in Dock + About, Credits body).
        # Falls back to the bare binary if the wrapper can't be built. CWD stays
        # the project root, so CWD-relative resource lookups still resolve.
        local launch_bin
        launch_bin=$(./scripts/dev-app.sh 2>/dev/null) || launch_bin="$BIN"
        if [[ ${#PASSTHROUGH[@]} -gt 0 ]]; then
            "$launch_bin" "${PASSTHROUGH[@]}" &
        else
            "$launch_bin" &
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
printf "%b║  Opal Dev Server                           ║%b\n" "$C_MAGENTA" "$C_RST"
printf "%b║  watcher: %-32s ║%b\n" "$C_MAGENTA" "$WATCHER" "$C_RST"
printf "%b║  mode:    %-32s ║%b\n" "$C_MAGENTA" "${OPTIMIZE:-Debug}" "$C_RST"
if (( INCREMENTAL )); then INCR_STR="on (auto fallback)"; else INCR_STR="off"; fi
printf "%b║  incr:    %-32s ║%b\n" "$C_MAGENTA" "$INCR_STR" "$C_RST"
OLD_IFS="$IFS"; IFS=' '; PATHS_STR="${WATCH_PATHS[*]}"; IFS="$OLD_IFS"
printf "%b║  paths:   %-32s ║%b\n" "$C_MAGENTA" "$PATHS_STR" "$C_RST"
printf "%b╚════════════════════════════════════════════╝%b\n" "$C_MAGENTA" "$C_RST"

build_and_launch

# ── Watch loop (per-watcher) ────────────────────────────────────
# Seconds, computed once. Single-quoted awk program and </dev/null on purpose:
# macOS /bin/bash 3.2 brace-expanded `{printf "%.3f", …}` inside the old
# double-quoted $(awk "…"), leaving awk a non-BEGIN program that read stdin —
# the fswatch pipe — so the loop hung after the first change and never rebuilt.
DEBOUNCE_S=$(awk -v ms="$DEBOUNCE_MS" 'BEGIN { printf "%.3f", ms / 1000 }' </dev/null)
debounce() { sleep "$DEBOUNCE_S"; }

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
        # Hand off process management to watchexec. Same incremental-first
        # policy as run_build: a bailed incremental build retries plainly.
        WATCH_BUILD="${ZIG:-zig} build $OPTIMIZE"
        (( INCREMENTAL )) && WATCH_BUILD="{ $WATCH_BUILD -fincremental || $WATCH_BUILD; }"
        kill_running
        log "watchexec will manage the child process"
        exec watchexec \
            --no-vcs-ignore \
            --ignore 'zig-cache/**' --ignore 'zig-out/**' --ignore '.zig-cache/**' \
            --ignore '*.swp' --ignore '*~' \
            --watch src --watch tools --watch build.zig --watch build.zig.zon \
            --on-busy-update restart --stop-signal SIGTERM \
            -- bash -c "$WATCH_BUILD && exec \"\$(./scripts/dev-app.sh 2>/dev/null || echo $BIN)\" ${PASSTHROUGH[*]:-}"
        ;;
esac
