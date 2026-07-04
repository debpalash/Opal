#!/usr/bin/env bash
# Opal / zigzag bootstrap & build wrapper.
#
# Runs the four steps needed to go from a fresh clone to a working binary:
#   1. ensure system deps are present (offer to install if missing)
#   2. fetch Zig dependencies (zig build — fails compile on first run, that's OK)
#   3. apply vendored dep patches (Zig 0.16 / dvui compat)
#   4. build the ReleaseSafe binary
#
# After this completes, zig-out/bin/zigzag is ready to run.
#
# Flags:
#   --release     Build ReleaseSafe (default). Adds -fsys=sdl2.
#   --debug       Build Debug instead.
#   --no-deps     Skip the deps check/install step.
#   --run         After building, launch the binary (with SDL_VIDEODRIVER=wayland).
#   --check-only  Only check deps + patches, don't build.
#
# Usage:
#   ./scripts/setup.sh
#   ./scripts/setup.sh --debug --run
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

mode="release"
do_deps=1
do_run=0
check_only=0
for arg in "$@"; do
  case "$arg" in
    --release)    mode="release" ;;
    --debug)      mode="debug" ;;
    --no-deps)    do_deps=0 ;;
    --run)        do_run=1 ;;
    --check-only) check_only=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }

# ─── 1. Ensure Zig is available ────────────────────────────────────────────
if ! have zig; then
  echo "error: zig not found on PATH. Install zig >= 0.15.2 (https://ziglang.org/download/) or run scripts/install-deps.sh"
  exit 1
fi
zig_version="$(zig version 2>/dev/null || echo 0)"
echo "==> zig $(zig version) at $(command -v zig)"

# ─── 2. Ensure system deps ────────────────────────────────────────────────
if [[ "$do_deps" -eq 1 ]]; then
  if ! ./scripts/install-deps.sh --check >/dev/null 2>&1; then
    echo "==> some system deps missing — offering to install"
    if [[ -t 0 ]]; then
      read -r -p "Install missing system deps now? [y/N] " yn < /dev/tty
      case "$yn" in
        y|Y) ./scripts/install-deps.sh || exit 1 ;;
        *) echo "skipping — build may fail if deps are missing" ;;
      esac
    else
      echo "==> non-interactive: attempting auto-install"
      ./scripts/install-deps.sh || echo "warn: auto-install returned non-zero — continuing"
    fi
  else
    echo "==> system deps OK"
  fi
fi

if [[ "$check_only" -eq 1 ]]; then
  # also check patches
  ./scripts/apply-patches.sh
  exit 0
fi

# ─── 3. Fetch Zig deps (first build is expected to fail) ──────────────────
# `zig build` lazily fetches dependencies under zig-pkg/. The first invocation
# compiles against unpatched dvui and fails; we then apply patches and rebuild.
if [[ ! -d zig-pkg ]] || [[ -z "$(ls -A zig-pkg 2>/dev/null)" ]]; then
  echo "==> fetching Zig dependencies (initial build may fail — that's OK)"
  zig_build_flags=(build -fsys=sdl2)
  [[ "$mode" == "release" ]] && zig_build_flags+=(-Doptimize=ReleaseSafe)
  zig "${zig_build_flags[@]}" 2>&1 | tail -3 || true
fi

# ─── 4. Apply vendored dep patches ─────────────────────────────────────────
echo "==> applying vendored patches"
./scripts/apply-patches.sh

# ─── 5. Build ──────────────────────────────────────────────────────────────
echo "==> building ($mode)"
zig_build_flags=(build -fsys=sdl2)
if [[ "$mode" == "release" ]]; then
  zig_build_flags+=(-Doptimize=ReleaseSafe)
fi
zig "${zig_build_flags[@]}"
echo "==> binary: $(ls -lh zig-out/bin/zigzag | awk '{print $5, $9}')"

# ─── 6. Optional run ───────────────────────────────────────────────────────
if [[ "$do_run" -eq 1 ]]; then
  echo "==> launching"
  if [[ -z "${WAYLAND_DISPLAY:-}" ]] && [[ -n "${DISPLAY:-}" ]]; then
    exec ./zig-out/bin/zigzag "$@"
  else
    SDL_VIDEODRIVER=wayland exec ./zig-out/bin/zigzag "$@"
  fi
fi