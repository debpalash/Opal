class Opal < Formula
  # The release app bundles its media and torrent dylibs; the bare CLI tarball
  # needs a matching Homebrew mpv/FFmpeg and cannot be installed independently.
  desc "Pure-Zig desktop media browser and AI copilot"
  homepage "https://github.com/debpalash/Opal"
  version "0.8.6"
  license "GPL-3.0-only"

  url "https://github.com/debpalash/Opal/releases/download/v0.8.6/Opal-0.8.6-macos-arm64.app.zip"
  sha256 "5e92c5211d7c3260a56225572ced0d35abad2d2e41eeb6906da8f78ee0a2c8cb"

  # The published binary is Apple-silicon only (GitHub retired the Intel runners).
  # Say so up front instead of installing something that cannot run.
  depends_on arch: :arm64
  depends_on :macos

  def install
    prefix.install "Opal.app"
    bin.write_exec_script prefix/"Opal.app/Contents/MacOS/Opal"
  end

  def caveats
    <<~EOS
      Launch Opal with `opal` or `open "#{prefix}/Opal.app"`.
      Config and models live in ~/.config/opal/.
      Voice capture and transcription need ffmpeg and whisper-cpp separately.
    EOS
  end
end
