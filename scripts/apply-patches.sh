#!/usr/bin/env bash
# Apply vendored Zig-dependency patches after `zig fetch` / `zig build` re-extracts deps.
#
# Patches live in scripts/patches/*.patch and are applied relative to the
# matching dependency directory under zig-pkg/<dep-hash>/.
#
# Re-running this script is safe: already-applied patches are skipped (patch
# --forward exits non-zero on a previously applied hunk, which we treat as OK).
#
# Usage:
#   ./scripts/apply-patches.sh        # apply all patches
#   ./scripts/apply-patches.sh --check # exit 0 if all already applied, 1 if missing
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH_DIR="$ROOT/scripts/patches"
ZIG_PKG="$ROOT/zig-pkg"

# Map: patch filename prefix -> glob pattern matching the dep directory under zig-pkg/
# (Zig appends "-<version>-<hash>" so we glob on a prefix.)
declare -A PATCH_TARGETS=(
  ["dvui-sdl"]="dvui-*"
)

check_only=0
[[ "${1:-}" == "--check" ]] && check_only=1

applied=0
skipped=0
missing=0

for patch in "$PATCH_DIR"/*.patch; do
  [[ -f "$patch" ]] || continue
  base="$(basename "$patch")"
  prefix="${base%%-*}"
  glob="${PATCH_TARGETS[$base]:-}"
  # Fall back to deriving the dep name from the patch file's leading path component
  if [[ -z "$glob" ]]; then
    # If the patch file itself encodes the dep name as <dep>-... use prefix
    glob="${prefix}*"
  fi

  # Find matching dep directories (there may be several if hashes differ)
  dep_dirs=()
  while IFS= read -r d; do
    dep_dirs+=("$d")
  done < <(find "$ZIG_PKG" -maxdepth 1 -type d -name "$glob" 2>/dev/null)

  if [[ ${#dep_dirs[@]} -eq 0 ]]; then
    echo "warn: no zig-pkg match for $base (glob: $glob) — run 'zig build' first to fetch deps"
    missing=$((missing + 1))
    continue
  fi

  for dep_dir in "${dep_dirs[@]}"; do
    # Patches store paths relative to the dep root (e.g. 'src/backends/sdl.zig'),
    # so we apply with -p0 from inside the dep directory and force
    # --batch / --forward to avoid interactive prompts.
    if (cd "$dep_dir" && patch --dry-run -p0 --forward --batch < "$patch") >/dev/null 2>&1; then
      # Patch is missing — apply it
      if [[ "$check_only" -eq 0 ]]; then
        if (cd "$dep_dir" && patch -p0 --forward --batch < "$patch") >/dev/null 2>&1; then
          echo "applied: $base -> $(basename "$dep_dir")"
          applied=$((applied + 1))
        else
          echo "error: failed to apply $base -> $(basename "$dep_dir")"
          exit 1
        fi
      else
        echo "missing: $base -> $(basename "$dep_dir")"
        missing=$((missing + 1))
      fi
    else
      # dry-run failed: either already applied OR rejects — distinguish
      if (cd "$dep_dir" && patch --dry-run -p0 -R --forward --batch < "$patch") >/dev/null 2>&1; then
        echo "skip (already applied): $base -> $(basename "$dep_dir")"
        skipped=$((skipped + 1))
      else
        echo "error: $base does not apply cleanly to $(basename "$dep_dir")"
        exit 1
      fi
    fi
  done
done

if [[ "$check_only" -eq 1 && "$missing" -gt 0 ]]; then
  exit 1
fi

echo "patches: applied=$applied skipped=$skipped missing=$missing"