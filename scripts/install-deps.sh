#!/usr/bin/env bash
# Ensure the host has the system dependencies Opal/zigzag needs at build and
# runtime. Detects the distro family and installs the matching packages.
#
# Two modes (both can be used; "soft" + "hard" = user-installs + ship-bundled):
#   ./scripts/install-deps.sh            # install (asking for sudo if needed)
#   ./scripts/install-deps.sh --check     # exit 0 if all present, 1 if missing
#
# The package list mirrors PKGBUILD depends/makedepends/optdepends.
set -euo pipefail

check_only=0
[[ "${1:-}" == "--check" ]] && check_only=1

have() { command -v "$1" >/dev/null 2>&1; }

# ──────────────────────────────────────────────────────────────────────────
# Distribution detection
# ──────────────────────────────────────────────────────────────────────────
detect_distro() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}:${ID_LIKE:-}" in
      arch*)        echo arch ;;
      manjaro*)     echo arch ;;
      cachyos*)     echo arch ;;
      endeavouros*) echo arch ;;
      garuda*)     echo arch ;;
      *:arch*)     echo arch ;;
      debian*)     echo debian ;;
      ubuntu*)     echo debian ;;
      linuxmint*)   echo debian ;;
      pop*)        echo debian ;;
      *:debian*)   echo debian ;;
      fedora*)     echo fedora ;;
      rhel*)       echo fedora ;;
      rocky*)      echo fedora ;;
      alma*)       echo fedora ;;
      *:rhel*)     echo fedora ;;
      opensuse*|suse*) echo suse ;;
      *)
        case "${ID:-}" in
          nixos) echo nixos ;;
          alpine) echo alpine ;;
          void)  echo void ;;
          gentoo) echo gentoo ;;
          *)     echo unknown ;;
        esac ;;
    esac
  else
    echo unknown
  fi
}

# ──────────────────────────────────────────────────────────────────────────
# Per-distro package declarations
#   build_deps: needed to compile Opal/zigzag
#   runtime_deps: needed to run the built app
#   optional_deps: nice-to-have features (live stream, scraping, OCR)
# ──────────────────────────────────────────────────────────────────────────

declare_arch_build=("zig>=0.15.2" gcc git)
declare_arch_runtime=(mpv sdl2 sqlite libtorrent-rasterbar curl python python-pip ffmpeg yt-dlp)
declare_arch_optional=(streamlink python-camoufox onnxruntime)

declare_debian_build=(zig gcc git pkg-config)
declare_debian_runtime=(mpv libsdl2-2.0-0 libsqlite3-0 libtorrent-rasterbar curl python3 python3-pip ffmpeg yt-dlp)
declare_debian_optional=(streamlink)

declare_fedora_build=(zig gcc git pkg-config)
declare_fedora_runtime=(mpv SDL2 sqlite libtorrent-rasterbar curl python3 python3-pip ffmpeg yt-dlp)
declare_fedora_optional=()

declare_suse_build=(zig gcc git pkg-config)
declare_suse_runtime=(mpv libSDL2-2_0-0 libsqlite3-0 libtorrent-rasterbar curl python3 python3-pip ffmpeg yt-dlp)
declare_suse_optional=()

# System library presence checks ( SONAME -> existence test, distro-agnostic )
declare -A RUNTIME_SYSTEM_LIBS=(
  [libSDL2]="libSDL2-2.0.so.0"
  [libmpv]="libmpv.so.2"
  [libsqlite3]="libsqlite3.so.0"
  [libtorrent-rasterbar]="libtorrent-rasterbar.so.2.0"
)
declare -A RUNTIME_BINARIES=(
  [mpv]="mpv"
  [curl]="curl"
  [python]="python3"
  [pip]="pip3"
  [ffmpeg]="ffmpeg"
  [yt-dlp]="yt-dlp"
)
declare -A BUILD_BINARIES=(
  [zig]="zig"
  [gcc]="gcc"
  [git]="git"
)

list_missing_libs() {
  local missing=()
  # Capture ldconfig output once to avoid SIGPIPE (141) tripping `pipefail`
  # when grep -q closes the pipe early after a match.
  local ld_cache
  ld_cache="$(ldconfig -p 2>/dev/null || true)"
  for soname in "${RUNTIME_SYSTEM_LIBS[@]}"; do
    if [[ "$ld_cache" != *"$soname"* ]]; then
      missing+=("$soname")
    fi
  done
  printf '%s\n' "${missing[@]}"
}

list_missing_bins() {
  local missing=()
  for bin in "$@"; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      missing+=("$bin")
    fi
  done
  printf '%s\n' "${missing[@]}"
}

# ──────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────
distro="$(detect_distro)"

if [[ "$check_only" -eq 1 ]]; then
  rc=0
  bin_missing=()
  while read -r b; do [[ -n "$b" ]] && bin_missing+=("$b"); done \
    < <(list_missing_bins "${BUILD_BINARIES[@]}" "${RUNTIME_BINARIES[@]}")
  lib_missing=()
  while read -r l; do [[ -n "$l" ]] && lib_missing+=("$l"); done \
    < <(list_missing_libs)

  if [[ ${#bin_missing[@]} -gt 0 ]]; then
    echo "missing binaries: ${bin_missing[*]}"
    rc=1
  fi
  if [[ ${#lib_missing[@]} -gt 0 ]]; then
    echo "missing libs: ${lib_missing[*]}"
    rc=1
  fi
  exit $rc
fi

# ─── helpers ───
_sudo() {
  if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

install_arch() {
  local aur_helper=""
  for h in yay paru; do command -v "$h" >/dev/null 2>&1 && aur_helper="$h" && break; done

  echo "==> [arch] installing build deps: ${declare_arch_build[*]}"
  _sudo pacman -S --needed --noconfirm "${declare_arch_build[@]}" || echo "warn: pacman install failed for some build deps"

  echo "==> [arch] installing runtime deps: ${declare_arch_runtime[*]}"
  _sudo pacman -S --needed --noconfirm "${declare_arch_runtime[@]}" || echo "warn: pacman install failed for some runtime deps"

  # OCR is packaged in AUR/community: onnxruntime is a community package; fall back to AUR.
  echo "==> [arch] optional deps: ${declare_arch_optional[*]}"
  if pacman -Si onnxruntime >/dev/null 2>&1; then
    _sudo pacman -S --needed --noconfirm onnxruntime || true
  elif [[ -n "$aur_helper" ]]; then
    $aur_helper -S --needed --noconfirm onnxruntime || true
  fi

  # camoufox isn't packaged — install via pip
  if command -v pip3 >/dev/null 2>&1; then
    pip3 install --user --break-system-packages camoufox 2>/dev/null || true
  fi
  pacman -S --needed --noconfirm streamlink 2>/dev/null || true
}

install_debian() {
  echo "==> [debian] installing build deps: ${declare_debian_build[*]}"
  _sudo apt-get update -y
  _sudo apt-get install -y --no-install-recommends "${declare_debian_build[@]}" || echo "warn: apt install failed for some build deps"

  echo "==> [debian] installing runtime deps: ${declare_debian_runtime[*]}"
  _sudo apt-get install -y --no-install-recommends "${declare_debian_runtime[@]}" || echo "warn: apt install failed for some runtime deps"

  echo "==> [debian] optional deps"
  _sudo apt-get install -y --no-install-recommends "${declare_debian_optional[@]}" || true
  pip3 install --user --break-system-packages camoufox 2>/dev/null || true

  # Install yt-dlp via pip if apt version is too old/missing (Ubuntu < 22.04 etc.)
  if ! command -v yt-dlp >/dev/null 2>&1; then
    pip3 install --user --break-system-packages yt-dlp 2>/dev/null || true
  fi
}

install_fedora() {
  echo "==> [fedora] installing build deps: ${declare_fedora_build[*]}"
  _sudo dnf install -y "${declare_fedora_build[@]}" || _sudo dnf install -y "${declare_fedora_build[@]}" || true
  echo "==> [fedora] runtime deps"
  _sudo dnf install -y "${declare_fedora_runtime[@]}" || true
  # Enable RPM Fusion for mpv/ffmpeg if missing
  if ! rpm -q mpv ffmpeg >/dev/null 2>&1; then
    _sudo dnf install -y "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" 2>/dev/null || true
    _sudo dnf install -y mpv ffmpeg 2>/dev/null || true
  fi
}

install_suse() {
  echo "==> [suse] installing: ${declare_suse_build[*]} + ${declare_suse_runtime[*]}"
  _sudo zypper install -y "${declare_suse_build[@]}" "${declare_suse_runtime[@]}" || true
}

install_unknown() {
  cat >&2 <<EOF
warn: unknown distribution. Please install these manually:
  build:        zig>=0.15.2  gcc  git  pkg-config
  runtime:      mpv  SDL2  sqlite3  libtorrent-rasterbar  curl  python3  python3-pip  ffmpeg  yt-dlp
  optional:     streamlink  camoufox (pip)  onnxruntime
EOF
}

case "$distro" in
  arch)    install_arch ;;
  debian)  install_debian ;;
  fedora)  install_fedora ;;
  suse)    install_suse ;;
  nixos)   echo "NixOS detected — please use the devShell/flake.nix.nix"; ;;
  alpine)  echo "Alpine detected — please use: apk add zig gcc git musl-dev sdl2-dev mpv-dev sqlite-dev libtorrent-rasterbar curl python3 py3-pip ffmpeg yt-dlp"; _sudo apk add zig gcc git sdl2-dev mpv-dev sqlite-dev libtorrent-rasterbar curl python3 py3-pip ffmpeg yt-dlp 2>/dev/null || true ;;
  void)    _sudo xbps-install -Sy zig gcc git SDL2-devel mpv-devel sqlite-devel libtorrent-rasterbar curl python3 python3-pip ffmpeg yt-dlp 2>/dev/null || true ;;
  gentoo)  _sudo emerge -av dev-lang/zig sys-devel/gcc dev-vcs/git media-libs/libsdl2 media-video/mpv dev-db/sqlite net-libs/libtorrent-rasterbar net-misc/curl dev-lang/python dev-python/pip media-video/ffmpeg media-video/yt-dlp 2>/dev/null || true ;;
  *)       install_unknown ;;
esac

echo "==> deps install done. Re-run with --check to verify."