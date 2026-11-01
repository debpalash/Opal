#!/usr/bin/env bash
# Remove Opal build artifacts.
#
#   ./scripts/clean.sh             local build outputs (fast rebuild, deps kept)
#   ./scripts/clean.sh --bundle    + the packaged .app bundles in dist/
#   ./scripts/clean.sh --all       + zig-pkg and the whole global Zig cache
#
# --all is the heavy one: ~/.cache/zig holds every compiled dependency, so a
# normal rebuild never needs it. Reach for it after a Zig upgrade, or when a
# build dies on a corrupt cache entry:
#   error: failed to open ~/.cache/zig/o/<hash>/libcompiler_rt.a: FileNotFound
#   error: failed to parse archive: FileNotFound
# The whole root goes, not just o/ and p/: h/ holds the manifests that record
# which artifacts exist, so leaving it behind reproduces the exact failure the
# clean was meant to fix (the manifests point at deleted objects). zig-pkg is
# regenerated from build.zig.zon on the next build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ALL=0
BUNDLES=0

for arg in "$@"; do
    case "$arg" in
        --all) ALL=1; BUNDLES=1 ;;
        --bundle) BUNDLES=1 ;;
        -h|--help) awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; exit 0 ;;
        *) echo "[clean] unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

cd "$ROOT"

removed=0
drop() {
    local path="$1"
    [ -e "$path" ] || return 0
    local size
    size=$(du -sh "$path" 2>/dev/null | cut -f1)
    rm -rf "$path"
    echo "[clean] removed $path (${size:-?})"
    removed=$((removed + 1))
}

drop .zig-cache
drop zig-out

if (( BUNDLES )); then
    drop dist/Opal.app
    drop dist/Opal-dev.app
    drop dist/OpalMenubar.app
    for dmg in dist/*.dmg; do
        [ -e "$dmg" ] || continue
        drop "$dmg"
    done
fi

if (( ALL )); then
    drop zig-pkg
    drop "${XDG_CACHE_HOME:-$HOME/.cache}/zig"
fi

if (( removed == 0 )); then
    echo "[clean] nothing to remove"
else
    echo "[clean] done — next build is a cold one for whatever was removed"
fi
