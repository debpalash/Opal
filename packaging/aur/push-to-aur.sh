#!/usr/bin/env bash
# Publish/refresh the AUR packages (opal, opal-bin).
#
# Run ON AN ARCH BOX (needs makepkg + updpkgsums from pacman-contrib), with an
# AUR account whose SSH key is configured (https://wiki.archlinux.org/title/AUR).
# The repo must be PUBLIC first — the source/release URLs 404 while private.
#
#   ./push-to-aur.sh            # both packages
#   ./push-to-aur.sh opal-bin   # just one
set -euo pipefail
cd "$(dirname "$0")"

PKGS=("${@:-opal opal-bin}")

for pkg in ${PKGS[@]}; do
    echo "── $pkg ──"
    workdir=$(mktemp -d)
    # AUR repo (empty on first publish — pushing creates the package).
    git clone "ssh://aur@aur.archlinux.org/${pkg}.git" "$workdir"
    cp "$pkg/PKGBUILD" "$workdir/"
    pushd "$workdir" >/dev/null
    updpkgsums                                    # fill sha256sums from the live URLs
    makepkg --printsrcinfo > .SRCINFO             # AUR requires it in sync
    makepkg -f --noconfirm                        # prove it actually builds before pushing
    git add PKGBUILD .SRCINFO
    git commit -m "$(grep -oP '^pkgver=\K.*' PKGBUILD)-$(grep -oP '^pkgrel=\K.*' PKGBUILD)"
    git push origin master
    popd >/dev/null
    rm -rf "$workdir"
    echo "✓ $pkg pushed"
done
echo "Done. yay -S opal (or opal-bin) should now resolve."
