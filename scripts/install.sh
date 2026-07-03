#!/bin/sh
# Opal — official one-command installer / updater / version manager.
#
#   curl -fsSL https://raw.githubusercontent.com/debpalash/Opal/main/scripts/install.sh | sh
#
# Commands (pass after the script, or via `sh -s -- <cmd>` when piping):
#   install        install the latest release (default)
#   update         alias for install — always converges on the requested version
#   uninstall      remove an installation made by this script
#   list-versions  show available release tags
#
# Options / env:
#   OPAL_VERSION=v0.1.0   pin any released version (default: latest)
#   OPAL_PREFIX=~/.local  Linux install prefix for the AppImage (default)
#
# Per-platform behavior:
#   macOS (Apple silicon)  Opal.app → /Applications  (Homebrew tap once live:
#                          brew install debpalash/tap/opal)
#   Debian/Ubuntu          installs the official .deb via apt
#   Fedora/openSUSE        installs the official .rpm via dnf/zypper
#   Arch                   yay/paru -S opal-bin when available on AUR,
#                          otherwise falls through to the AppImage
#   any other Linux        AppImage → $OPAL_PREFIX/bin + desktop entry
#
# Every download is verified against the release's SHA256SUMS.txt.
set -eu

REPO="debpalash/Opal"
API="https://api.github.com/repos/$REPO"
DL="https://github.com/$REPO/releases/download"
STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opal"
RECEIPT="$STATE_DIR/.install-method"

say()  { printf '\033[35m◆ opal\033[0m %s\n' "$*"; }
die()  { printf '\033[31m✗ opal\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

need_curl() { have curl || die "curl is required"; }

resolve_version() {
    if [ -n "${OPAL_VERSION:-}" ]; then
        VERSION="$OPAL_VERSION"
    else
        need_curl
        # Capture first, parse second — `curl | grep -m1` makes curl die on
        # SIGPIPE and print a scary (harmless) error 56 when grep exits early.
        json=$(curl -fsL "$API/releases/latest") \
            || die "could not resolve the latest release (rate limit? private repo?)"
        VERSION=$(printf '%s' "$json" | grep -m1 '"tag_name"' | cut -d'"' -f4)
        [ -n "$VERSION" ] || die "could not parse the latest release tag"
    fi
    case "$VERSION" in v*) ;; *) VERSION="v$VERSION" ;; esac
    VER="${VERSION#v}"
    say "version: $VERSION"
}

sha_tool() {
    if have sha256sum; then echo "sha256sum"; elif have shasum; then echo "shasum -a 256"; else echo ""; fi
}

# fetch <asset-name> <dest-path> — download + verify against SHA256SUMS.txt
fetch() {
    asset="$1"; dest="$2"
    say "downloading $asset"
    curl -fL --progress-bar -o "$dest" "$DL/$VERSION/$asset" || die "download failed: $asset"
    tool=$(sha_tool)
    if [ -n "$tool" ] && curl -fsSL -o "$TMP/SHA256SUMS.txt" "$DL/$VERSION/SHA256SUMS.txt" 2>/dev/null; then
        want=$(grep " $asset\$" "$TMP/SHA256SUMS.txt" | cut -d' ' -f1)
        got=$($tool "$dest" | cut -d' ' -f1)
        [ -n "$want" ] || { say "warning: $asset not in SHA256SUMS.txt — skipping verification"; return; }
        [ "$want" = "$got" ] || die "checksum mismatch for $asset (expected $want, got $got)"
        say "sha256 verified"
    else
        say "warning: no checksum verification (SHA256SUMS.txt or sha tool missing)"
    fi
}

receipt() { mkdir -p "$STATE_DIR"; printf '%s %s\n' "$1" "$VERSION" > "$RECEIPT"; }

install_macos() {
    [ "$(uname -m)" = "arm64" ] || die \
        "no prebuilt Intel-mac binaries (GitHub retired Intel runners) — build from source:
  https://github.com/$REPO#get-it  (build.zig honors HOMEBREW_PREFIX=/usr/local)"
    # Prefer the Homebrew tap when it's live and brew is present.
    if have brew && brew tap-info debpalash/tap >/dev/null 2>&1; then
        say "installing via Homebrew tap"
        brew install debpalash/tap/opal
        receipt brew
        say "done — launch with: open -a Opal (or \`opal\`)"
        return
    fi
    fetch "Opal-$VER-macos-arm64.app.zip" "$TMP/opal.app.zip"
    target="/Applications"
    [ -w "$target" ] || target="$HOME/Applications"
    mkdir -p "$target"
    rm -rf "$target/Opal.app"
    ditto -xk "$TMP/opal.app.zip" "$target/"
    receipt "app:$target"
    say "installed → $target/Opal.app"
}

install_linux() {
    arch=$(uname -m)
    [ "$arch" = "x86_64" ] || die "no prebuilt $arch Linux binaries yet — build from source: https://github.com/$REPO#get-it"

    if have apt-get; then
        fetch "opal_${VER}_amd64.deb" "$TMP/opal.deb"
        say "installing .deb (sudo required)"
        sudo apt-get install -y "$TMP/opal.deb"
        receipt deb; say "done — run: opal"; return
    fi
    if have dnf; then
        fetch "opal-$VER-1.x86_64.rpm" "$TMP/opal.rpm"
        say "installing .rpm (sudo required)"
        sudo dnf install -y "$TMP/opal.rpm"
        receipt rpm; say "done — run: opal"; return
    fi
    if have zypper; then
        fetch "opal-$VER-1.x86_64.rpm" "$TMP/opal.rpm"
        say "installing .rpm (sudo required)"
        sudo zypper --non-interactive install --allow-unsigned-rpm "$TMP/opal.rpm"
        receipt rpm; say "done — run: opal"; return
    fi
    if have pacman; then
        for helper in yay paru; do
            if have "$helper" && "$helper" -Si opal-bin >/dev/null 2>&1; then
                say "installing from the AUR via $helper"
                "$helper" -S --noconfirm opal-bin
                receipt aur; say "done — run: opal"; return
            fi
        done
        say "AUR package not reachable — falling back to the AppImage"
    fi

    # Universal fallback: AppImage into the user prefix, no root needed.
    prefix="${OPAL_PREFIX:-$HOME/.local}"
    bindir="$prefix/bin"; appdir="$prefix/share/applications"
    mkdir -p "$bindir" "$appdir"
    fetch "Opal-$VER-x86_64.AppImage" "$bindir/opal"
    chmod +x "$bindir/opal"
    cat > "$appdir/opal.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Opal
GenericName=Media Suite
Comment=Play everything — the evolved media player
Exec=$bindir/opal
Terminal=false
Categories=AudioVideo;Video;Player;
EOF
    receipt "appimage:$bindir"
    case ":$PATH:" in *":$bindir:"*) ;; *) say "note: add $bindir to your PATH" ;; esac
    say "installed → $bindir/opal (AppImage)"
}

do_install() {
    resolve_version
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    case "$(uname -s)" in
        Darwin) install_macos ;;
        Linux)  install_linux ;;
        *) die "unsupported OS: $(uname -s) — see https://github.com/$REPO#get-it" ;;
    esac
}

do_uninstall() {
    [ -f "$RECEIPT" ] || die "no install receipt at $RECEIPT — was Opal installed by this script?"
    method=$(cut -d' ' -f1 "$RECEIPT")
    case "$method" in
        brew)        brew uninstall opal ;;
        deb)         sudo apt-get remove -y opal ;;
        rpm)         { have dnf && sudo dnf remove -y opal; } || sudo zypper --non-interactive remove opal ;;
        aur)         sudo pacman -R --noconfirm opal-bin ;;
        app:*)       rm -rf "${method#app:}/Opal.app" ;;
        appimage:*)  rm -f "${method#appimage:}/opal" \
                           "${XDG_DATA_HOME:-$HOME/.local/share}/applications/opal.desktop" ;;
        *) die "unknown install method: $method" ;;
    esac
    rm -f "$RECEIPT"
    say "uninstalled. Config/history in ~/.config/opal is preserved — delete it yourself if you want a clean slate."
}

do_list() {
    need_curl
    say "released versions:"
    curl -fsSL "$API/releases?per_page=20" | grep '"tag_name"' | cut -d'"' -f4 | sed 's/^/  /'
}

case "${1:-install}" in
    install|update) do_install ;;
    uninstall)      do_uninstall ;;
    list-versions)  do_list ;;
    -h|--help|help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) die "unknown command: $1 (install | update | uninstall | list-versions)" ;;
esac
