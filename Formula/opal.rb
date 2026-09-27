class Opal < Formula
  # The release app bundles its media and torrent dylibs; the bare CLI tarball
  # needs a matching Homebrew mpv/FFmpeg and cannot be installed independently.
  desc "Pure-Zig desktop media browser and AI copilot"
  homepage "https://github.com/debpalash/Opal"
  url "https://github.com/debpalash/Opal/releases/download/v0.8.7/Opal-0.8.7-macos-arm64.app.zip"
  sha256 "055aeb52eeca077852b357e222e3c8675e30b32a6e2927a7c781513b0dc35e49"
  license "GPL-3.0-only"

  # The published binary is Apple-silicon only (GitHub retired the Intel runners).
  # Say so up front instead of installing something that cannot run.
  depends_on arch: :arm64
  depends_on :macos

  def install
    if (buildpath/"Opal.app").directory?
      prefix.install "Opal.app"
    else
      # Homebrew strips an archive's sole top-level directory. The release ZIP
      # contains only Opal.app, so its Contents directory can become buildpath.
      (prefix/"Opal.app").install buildpath.children
    end
    bin.write_exec_script prefix/"Opal.app/Contents/MacOS/Opal"
  end

  def caveats
    <<~EOS
      Launch Opal with `opal` or `open "#{prefix}/Opal.app"`.
      Config and models live in ~/.config/opal/.
      Voice capture and transcription need ffmpeg and whisper-cpp separately.
    EOS
  end

  test do
    assert_predicate prefix/"Opal.app/Contents/MacOS/Opal", :executable?
    assert_predicate bin/"opal", :executable?
  end
end
