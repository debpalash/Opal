#!/usr/bin/env bash
# Shared native dependencies for CI and release bundles. Runner images can
# contain openssl@1.1 symlinks without a corresponding installed formula.
set -euo pipefail
[ "$(uname -s)" = Darwin ] || { echo 'macOS required' >&2; exit 1; }
brew update
if ! brew install openssl@3; then
    # Homebrew installs the keg before linking. Recover only when the keg
    # exists, repair the stale links, then retry the actual install command.
    # Download, compilation and subsequent dependency failures still fail CI.
    brew list --versions openssl@3 >/dev/null
    brew link --overwrite openssl@3
    brew install openssl@3
fi
brew link --overwrite openssl@3
brew install sqlite webp sdl2 libtorrent-rasterbar libass libplacebo meson ninja pkgconf "$@"
