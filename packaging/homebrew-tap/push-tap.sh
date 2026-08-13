#!/usr/bin/env bash
# Publish/refresh the Homebrew tap (debpalash/homebrew-tap).
#
# Run AFTER the Opal repo is public (the formula's tag tarball 404s while
# private). Needs `gh` authenticated as the repo owner.
#
#   ./push-tap.sh
#
# Users then install with:  brew install debpalash/tap/opal
# (scripts/install.sh prefers the tap automatically once it exists.)
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root

TAP_REPO="debpalash/homebrew-tap"
workdir=$(mktemp -d)

if ! gh repo view "$TAP_REPO" >/dev/null 2>&1; then
    echo "── creating $TAP_REPO ──"
    gh repo create "$TAP_REPO" --public \
        --description "Homebrew tap for Opal — the evolved media player"
fi

git clone "https://github.com/$TAP_REPO.git" "$workdir"
# Release runners and fresh developer machines may have no global Git identity.
# Keep publication self-contained instead of mutating the user's global config.
git -C "$workdir" config user.name "debpalash"
git -C "$workdir" config user.email "4178343+debpalash@users.noreply.github.com"
mkdir -p "$workdir/Formula"
cp Formula/opal.rb "$workdir/Formula/opal.rb"
cat > "$workdir/README.md" <<'EOF'
# debpalash/homebrew-tap

```sh
brew install debpalash/tap/opal
```

Formulae here track [Opal](https://github.com/debpalash/Opal) releases.
EOF

cd "$workdir"
git add -A
git diff --cached --quiet || {
    git commit -m "opal: sync formula from debpalash/Opal"
    git push origin HEAD
}
echo "✓ tap published — brew install debpalash/tap/opal"
