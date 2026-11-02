#!/usr/bin/env bash
# Reproduce the checks on the experimental Zig 0.17 branch.
# ZIG=/path/to/zig ./scripts/check-zig17-upgrade.sh [--full]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIG="${ZIG:-zig}"
case "$("$ZIG" version)" in
    0.17.*) ;;
    *) echo 'This migration branch requires Zig 0.17.x' >&2; exit 2 ;;
esac
case "${1:-}" in
    ''|--full) ;;
    *) echo 'Usage: check-zig17-upgrade.sh [--full]' >&2; exit 2 ;;
esac
cd "$ROOT"
"$ZIG" build --help >/dev/null
"$ZIG" test src/player/container_pure.zig
"$ZIG" test src/player/av_device_pure.zig
"$ZIG" test src/core/event_loop_pure.zig
"$ZIG" test src/core/repeat_pure.zig
(
    cd vendor/zig-bypassdpi
    "$ZIG" build -Doptimize=fast
    "$ZIG" build test -Doptimize=fast
)
if [[ "${1:-}" == --full ]]; then
    # Full native application build; platform/fixture validation is separate.
    "$ZIG" build -Doptimize=fast
fi
