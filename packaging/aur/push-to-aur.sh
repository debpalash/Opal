#!/usr/bin/env bash
# Publish/refresh the AUR packages (opal, opal-bin).
#
# Two modes:
#
# 1) Local Arch box (interactive, for first-time bootstrap):
#      ./push-to-aur.sh                # both packages
#      ./push-to-aur.sh opal-bin       # just one
#    Requires: an AUR account with your SSH key registered, `pacman-contrib`
#    (for updpkgsums), `pkgconf`. Run on an Arch host so `makepkg -f` proves
#    the build actually works before pushing.
#
# 2) CI (GitHub Actions release.yml, non-interactive): set
#      AUR_SSH_PRIVATE_KEY  — ed25519 private key whose pubkey is registered
#                            on the AUR account
#      AUR_USERNAME         — AUR username (used for git commit identity only)
#      AUR_EMAIL            — AUR email   (used for git commit identity only)
#      AUR_SKIP_MAKEPKG=1   — skip the `makepkg -f` build-verification step
#                            (CI runners for the release job are Ubuntu; the
#                            Arch-only deps would have to be installed there.
#                            The native Arch job in ci.yml covers build-proof
#                            separately; AUR publish just needs the metadata.)
#    Then:
#      AUR_SSH_PRIVATE_KEY=… AUR_USERNAME=… AUR_EMAIL=… \
#        AUR_SKIP_MAKEPKG=1 ./push-to-aur.sh
set -euo pipefail
cd "$(dirname "$0")"

# NOT `PKGS=("${@:-opal opal-bin}")` — with no args that expands to a SINGLE
# element "opal opal-bin", and the loop below then tries to clone
# aur:"opal opal-bin".git. That is exactly what the v0.5.0 release job did.
if [[ $# -gt 0 ]]; then
  PKGS=("$@")
else
  PKGS=(opal opal-bin)
fi

# ─── CI mode: materialise the SSH key + identity into a sandbox ──────────
if [[ -n "${AUR_SSH_PRIVATE_KEY:-}" ]]; then
  : "${AUR_USERNAME:?AUR_USERNAME required in CI mode}"
  : "${AUR_EMAIL:?AUR_EMAIL required in CI mode}"
  if [[ -z "${AUR_SSH_PRIVATE_KEY// }" ]]; then
    echo "::notice::AUR_SSH_PRIVATE_KEY is empty — AUR publish is a no-op. Register a deploy key on your AUR account and set the repository secret."
    exit 0
  fi
  export GIT_SSH_COMMAND="ssh -i $HOME/.aur_id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  printf '%s\n' "$AUR_SSH_PRIVATE_KEY" > "$HOME/.aur_id_ed25519"
  chmod 600 "$HOME/.aur_id_ed25519"
  ssh-keyscan -t ed25519 aur.archlinux.org >> "$HOME/.aur_known_hosts" 2>/dev/null || true
  export GIT_SSH_COMMAND="ssh -i $HOME/.aur_id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=$HOME/.aur_known_hosts"
  export GIT_AUTHOR_NAME="$AUR_USERNAME"  GIT_AUTHOR_EMAIL="$AUR_EMAIL"
  export GIT_COMMITTER_NAME="$AUR_USERNAME" GIT_COMMITTER_EMAIL="$AUR_EMAIL"
fi

skip_makepkg=0
[[ "${AUR_SKIP_MAKEPKG:-0}" == "1" ]] && skip_makepkg=1

for pkg in "${PKGS[@]}"; do
  echo "── $pkg ──"
  workdir=$(mktemp -d)
  # AUR repo (empty on first publish — pushing creates the package).
  if ! git clone "ssh://aur@aur.archlinux.org/${pkg}.git" "$workdir"; then
    # First-time publish: the repo doesn't exist yet on AUR. `git clone`
    # against an empty AUR namespace returns an empty repo with exit 0;
    # if it actually failed (e.g. permission denied), surface that clearly.
    echo "error: clone of aur:${pkg} failed."
    echo "  A brand-new package name is NOT an error — AUR returns an empty repo"
    echo "  with exit 0 for those. 'Permission denied (publickey)' means the"
    echo "  public key matching AUR_SSH_PRIVATE_KEY is not registered on the"
    echo "  '${AUR_USERNAME:-<AUR_USERNAME>}' account: add it at"
    echo "  https://aur.archlinux.org/account/ → 'SSH Public Key'."
    rm -rf "$workdir"
    exit 1
  fi
  cp "$pkg/PKGBUILD" "$workdir/"
  pushd "$workdir" >/dev/null
  # Fill sha256sums from the live URLs (now that the tag is public). On an
  # Arch host this Just Works; on the CI Ubuntu runner we skip (sources
  # aren't downloadable until the release artifacts are uploaded, and we
  # don't want to require Arch toolchain there).
  if command -v updpkgsums >/dev/null 2>&1; then
    updpkgsums
  else
    echo "warn: updpkgsums missing — keeping 'SKIP' checksums (AUR will reject if URL hashes mismatch)"
  fi
  # AUR REJECTS a push whose .SRCINFO is missing or out of sync with PKGBUILD,
  # and only makepkg can generate it (a PKGBUILD is bash, not a data file). The
  # CI job therefore runs in an Arch container — a plain Ubuntu runner has no
  # makepkg and this line would abort under `set -e` right after the clone.
  if ! command -v makepkg >/dev/null 2>&1; then
    echo "error: makepkg not found — cannot generate .SRCINFO, and AUR requires it."
    echo "  Run this on an Arch host, or in an archlinux container (see release.yml)."
    exit 1
  fi
  makepkg --printsrcinfo > .SRCINFO             # AUR requires .SRCINFO in sync
  if [[ "$skip_makepkg" -eq 0 ]] && command -v makepkg >/dev/null 2>&1; then
    makepkg -f --noconfirm                        # prove it builds before pushing
  fi
  git add PKGBUILD .SRCINFO
  # Empty git tree (first publish) — git refuses to commit "nothing changed"
  # when the index equals HEAD. Explicitly allow empty.
  git commit --allow-empty -m "$(grep -oP '^pkgver=\K.*' PKGBUILD)-$(grep -oP '^pkgrel=\K.*' PKGBUILD) [ci publish]"
  git push origin master
  popd >/dev/null
  rm -rf "$workdir"
  echo "✓ $pkg pushed"
done
echo "Done. yay -S opal (or opal-bin) should now resolve."