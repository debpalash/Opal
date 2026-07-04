#!/usr/bin/env bash
# Ensure the host has the system dependencies Opal needs at build and runtime.
# Detects the distro family and installs the matching packages.
#
# Usage:
#   ./scripts/install-deps.sh             # install (asks for sudo if needed)
#   ./scripts/install-deps.sh --check      # exit 0 if all present, 1 if missing
#
# The package list mirrors PKGBUILD depends/makedepends/optdepends. Note that
# OCR (ONNX Runtime) is OPTIONAL — `zig build -Docr=true` enables it. Without
# -Docr, opal builds and runs without onnxruntime.
set -euo pipefail

check_only=0
[[ "${1:-}" == "--check" ]] && check_only=1

# ─── Distribution detection ───────────────────────────────────────────────
detect_distro() {
  [[ -r /etc/os-release ]] || { echo unknown; return; }
  . /etc/os-release
  case "${ID:-}:${ID_LIKE:-}" in
    arch*|manjaro*|cachyos*|endeavouros*|garuda*|*:arch*) echo arch ;;
    debian*|ubuntu*|linuxmint*|pop*|*:debian*)            echo debian ;;
    fedora*|rhel*|rocky*|alma*|*:rhel*)                   echo fedora ;;
    opensuse*|suse*)                                     echo suse ;;
    *) case "${ID:-}" in
         nixos)  echo nixos ;;
         alpine) echo alpine ;;
         void)   echo void ;;
         gentoo) echo gentoo ;;
         *)      echo unknown ;;
       esac ;;
  esac
}

# ─── Per-distro packages ──────────────────────────────────────────────────
# build: needed to compile; runtime: needed to run; optional: nice-to-have.
declare_arch_build=("zig>=0.15.2" gcc git)
declare_arch_runtime=(mpv sdl2 sqlite libtorrent-rasterbar curl python python-pip ffmpeg yt-dlp)
declare_arch_optional=(streamlink "onnxruntime-cpu: OCR (build with -Docr=true)")

declare_debian_build=(zig gcc git pkg-config)
declare_debian_runtime=(mpv libsdl2-2.0-0 libsqlite3-0 libtorrent-rasterbar curl python3 python3-pip ffmpeg yt-dlp)
declare_debian_optional=(streamlink)

declare_fedora_build=(zig gcc git pkg-config)
declare_fedora_runtime=(mpv SDL2 sqlite libtorrent-rasterbar curl python3 python3-pip ffmpeg yt-dlp)
declare_fedora_optional=()

declare_suse_build=(zig gcc git pkg-config)
declare_suse_runtime=(mpv libSDL2-2_0-0 libsqlite3-0 libtorrent-rasterbar curl python3 python3-pip ffmpeg yt-dlp)
declare_suse_optional=()

# Distro-agnostic runtime probes (ldconfig for .so, $PATH for binaries)
declare -A RUNTIME_LIBS=(
  [libSDL2]="libSDL2-2.0.so.0"
  [libmpv]="libmpv.so.2"
  [libsqlite3]="libsqlite3.so.0"
  [libtorrent-rasterbar]="libtorrent-rasterbar.so.2.0"
)
declare -a RUNTIME_BINS=(mpv curl python3 pip3 ffmpeg yt-dlp)
declare -a BUILD_BINS=(zig gcc git)

list_missing() {
  local missing=()
  local ld_cache
  ld_cache="$(ldconfig -p 2>/dev/null || true)"
  for soname in "${RUNTIME_LIBS[@]}"; do
    [[ "$ld_cache" != *"$soname"* ]] && missing+=("$soname")
  done
  for bin in "${RUNTIME_BINS[@]}" "${BUILD_BINS[@]}"; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
  printf '%s\n' "${missing[@]}"
}

distro="$(detect_distro)"

if [[ "$check_only" -eq 1 ]]; then
  rc=0
  missing=()
  while read -r m; do [[ -n "$m" ]] && missing+=("$m"); done < <(list_missing)
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "missing: ${missing[*]}"
    rc=1
  fi
  exit $rc
fi

_sudo() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

install_arch() {
  local aur=""
  for h in yay paru; do command -v "$h" >/dev/null 2>&1 && aur="$h" && break; done
  echo "==> [arch] build deps: ${declare_arch_build[*]}"
  _sudo pacman -S --needed --noconfirm "${declare_arch_build[@]}" || echo "warn: some build deps failed to install"
  echo "==> [arch] runtime deps: ${declare_arch_runtime[*]}"
  _sudo pacman -S --needed --noconfirm "${declare_arch_runtime[@]}" || echo "warn: some runtime deps failed to install"
  # Optional: streamlink is in community
  pacman -S --needed --noconfirm streamlink 2>/dev/null || true
  # Optional: OCR via onnxruntime-cpu (only needed for `zig build -Docr=true`)
  pacman -S --needed --noconfirm onnxruntime-cpu 2>/dev/null || true
  # camoufox isn't packaged — pip install
  pip3 install --user --break-system-packages camoufox 2>/dev/null || true
}

install_debian() {
  echo "==> [debian] build deps"
  _sudo apt-get update -y
  _sudo apt-get install -y --no-install-recommends "${declare_debian_build[@]}" || echo "warn: some build deps failed"
  echo "==> [debian] runtime deps"
  _sudo apt-get install -y --no-install-recommends "${declare_debian_runtime[@]}" || echo "warn: some runtime deps failed"
  _sudo apt-get install -y --no-install-recommends streamlink 2>/dev/null || true
  command -v yt-dlp >/dev/null 2>&1 || pip3 install --user --break-system-packages yt-dlp 2>/dev/null || true
  pip3 install --user --break-system-packages camoufox 2>/dev/null || true
}

install_fedora() {
  echo "==> [fedora] build + runtime"
  _sudo dnf install -y "${declare_fedora_build[@]}" "${declare_fedora_runtime[@]}" 2>/dev/null \
    || _sudo dnf install -y "${declare_fedora_build[@]}" "${declare_fedora_runtime[@]}" || true
  if ! rpm -q mpv ffmpeg >/dev/null 2>&1; then
    _sudo dnf install -y "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" 2>/dev/null || true
    _sudo dnf install -y mpv ffmpeg 2>/dev/null || true
  fi
}

install_suse() {
  echo "==> [suse] build + runtime"
  _sudo zypper install -y "${declare_suse_build[@]}" "${declare_suse_runtime[@]}" 2>/dev/null || true
}

install_unknown() {
  cat >&2 <<EOF
warn: unknown distribution. Please install manually:
  build:    zig>=0.15.2  gcc  git  pkg-config
  runtime:  mpv  SDL2  sqlite3  libtorrent-rasterbar  curl  python3  python3-pip  ffmpeg  yt-dlp
  optional: streamlink  onnxruntime  camoufox (pip install camoufox)
EOF
}

case "$distro" in
  arch)   install_arch ;;
  debian) install_debian ;;
  fedora) install_fedora ;;
  suse)   install_suse ;;
  alpine) _sudo apk add zig gcc git sdl2-dev mpv-dev sqlite-dev libtorrent-rasterbar curl python3 py3-pip ffmpeg yt-dlp 2>/dev/null || true ;;
  void)   _sudo xbps-install -Sy zig gcc git SDL2-devel mpv-devel sqlite-devel libtorrent-rasterbar curl python3 python3-pip ffmpeg yt-dlp 2>/dev/null || true ;;
  gentoo) _sudo emerge -av dev-lang/zig sys-devel/gcc dev-vcs/git media-libs/libsdl2 media-video/mpv dev-db/sqlite net-libs/libtorrent-rasterbar net-misc/curl dev-lang/python dev-python/pip media-video/ffmpeg media-video/yt-dlp 2>/dev/null || true ;;
  nixos)  echo "NixOS detected — please use the project flake/devShell" ;;
  *)      install_unknown ;;
esac

echo "==> deps install done. Re-run with --check to verify."